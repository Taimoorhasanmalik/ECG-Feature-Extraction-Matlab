"""Stage 2 verifier: lets Stage 2 reject Stage 1 false alarms.

Stage 2 only answers VT or VF, so every normal window on which Stage 1's
2-of-3 gate fires becomes a VT/VF error in the combined system. The verifier
is a small linear SVM trained on exactly the windows Stage 2 receives (gate
on), separating real VT/VF from false alarms. Combined output:
    gate off                      -> Normal
    gate on, verifier rejects     -> Normal
    gate on, verifier accepts     -> Stage 2 VT/VF classifier (unchanged)

Feature sets (no new feature hardware; the shared engine already produces
both): Stage 2's 6 features, Stage 1's 4 features, or all 10.
Threshold: the highest score threshold that still accepts >= `floor` of the
real VT/VF windows in the TRAINING data (recall-floor guard, like Stage 1).

Honest evaluation: record-grouped 5-fold CV over all 105 records (out-of-fold
decisions), plus a dedicated model trained on Stage 1's 84 train records and
scored on its 21 test records. Data: hw_shared_pipeline/results/
whole_database_windows.mat (per-window features from evaluate_whole_database.m).

Modifies no existing file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import scipy.io
from sklearn.model_selection import GroupKFold

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))
sys.path.insert(0, str(HERE.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
from report_train_test_metrics import binary, matlab_record_names

FLOORS = (0.90, 0.95, 0.98)
LABELS = ["Normal", "VT", "VF"]


def load():
    d = scipy.io.loadmat(HERE.parent / "results" / "whole_database_windows.mat")
    R = d["results"]
    names = matlab_record_names()
    rec = names[R[:, 0].astype(int) - 1]
    feats = {
        "S2 features (6)": d["allStage2Features"],
        "S1 features (4)": d["allStage1Features"],
        "S1 + S2 features (10)": np.hstack([d["allStage1Features"], d["allStage2Features"]]),
    }
    return R, rec, feats, int(np.min(R[:, 6]))


def floor_threshold(scores, truth, floor):
    pos = np.sort(scores[truth])
    return pos[int(np.floor((1 - floor) * pos.size))] if pos.size else 0.0


def fit_predict(x_tr, y_tr, x_te, floor):
    model = exp.make_model(1.0).fit(x_tr, y_tr)
    thr = floor_threshold(model.decision_function(x_tr), y_tr == 1, floor)
    return model.decision_function(x_te) >= thr


def combined_metrics(truth, gate, accept, s2, vt):
    pred = np.where(gate & accept, np.where(s2 == vt, 1, 2), 0)
    out = {"acc": float(np.mean(pred == truth)), "classes": {}}
    f1s = []
    for c in range(3):
        m = binary(truth == c, pred == c)
        out["classes"][LABELS[c]] = m
        f1s.append(m["f1"])
    out["macro_f1"] = float(np.mean(f1s))
    out["detection"] = binary(truth >= 1, pred >= 1)
    return out


def line(label, m):
    vt, vf, det = m["classes"]["VT"], m["classes"]["VF"], m["detection"]
    return (f"  {label:<40} acc {m['acc']:.4f} | det sens {det['recall']:.4f} spec {det['specificity']:.4f} | "
            f"VT P/R/F1 {vt['precision']:.3f}/{vt['recall']:.3f}/{vt['f1']:.3f} | "
            f"VF P/R/F1 {vf['precision']:.3f}/{vf['recall']:.3f}/{vf['f1']:.3f} | macro F1 {m['macro_f1']:.4f}")


def main():
    R, rec, feats, vt = load()
    valid = (R[:, 3] >= 0) & (R[:, 3] <= 2)
    gate = R[:, 5] == 1
    truth = R[:, 3].astype(int)
    pool38 = R[:, 2] == 1
    s1_test = R[:, 1] == 1
    s2 = R[:, 6].astype(int)          # deployed Stage 2 VT/VF decision
    train_rows = gate & valid           # windows Stage 2 actually receives
    views = {"38-record pool (train+test)": valid & pool38 & (R[:, 8] == 0),
             "all 105 records": valid,
             "Stage 1 test records (21)": valid & s1_test}

    print("Gated windows available for training: "
          f"{int(train_rows.sum())} ({int((train_rows & (truth >= 1)).sum())} real VT/VF, "
          f"{int((train_rows & (truth == 0)).sum())} false alarms)")
    summary = {}
    print("\n==== BASELINE: no verifier (current combined system) ====")
    for vname, vmask in views.items():
        print(line(vname, combined_metrics(truth[vmask], gate[vmask], np.ones(vmask.sum(), bool), s2[vmask], vt)))

    for fname, X in feats.items():
        for floor in FLOORS:
            # record-grouped 5-fold out-of-fold verifier decisions
            accept = np.ones(len(R), bool)
            idx = np.flatnonzero(train_rows)
            for tr, te in GroupKFold(n_splits=5).split(idx, groups=rec[idx]):
                accept[idx[te]] = fit_predict(X[idx[tr]], (truth[idx[tr]] >= 1).astype(int), X[idx[te]], floor)
            print(f"\n==== VERIFIER [{fname}], recall floor {floor:.2f}, record-grouped 5-fold out-of-fold ====")
            for vname, vmask in views.items():
                m = combined_metrics(truth[vmask], gate[vmask], accept[vmask], s2[vmask], vt)
                summary[f"{fname}|{floor}|cv|{vname}"] = m
                print(line(vname, m))
            # dedicated model: Stage 1 train records -> Stage 1 test records
            tr_rows = train_rows & ~s1_test
            te_rows = valid & s1_test
            accept2 = np.ones(len(R), bool)
            accept2[te_rows] = fit_predict(X[tr_rows], (truth[tr_rows] >= 1).astype(int), X[te_rows], floor)
            m = combined_metrics(truth[te_rows], gate[te_rows], accept2[te_rows], s2[te_rows], vt)
            summary[f"{fname}|{floor}|split|Stage 1 test records (21)"] = m
            print(line("Stage 1 test records, trained on its 84", m))

    out = HERE / "results" / "stage2_verifier_summary.json"
    out.write_text(json.dumps(summary, indent=1))
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
