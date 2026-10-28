"""Scores both stages on every shared-filter candidate produced by
`extract_shared_candidates.py`, so a single filter/window/feature engine can
be chosen for the whole two-stage system.

Stage 1 (normal vs abnormal, all 103 records):
  - record-grouped 5-fold CV (GroupKFold): pooled AUC, plus metrics at a
    per-fold "recall90" threshold chosen on the TRAINING fold scores (the
    highest threshold that still gives >= 90% abnormal recall on train),
    mirroring the deployed recall-floor threshold selection.
  - within-record chronological 70/30 split (same split code as
    stage1_greedy_record_inclusion.py) for comparison with earlier numbers.
Stage 2 (VT vs VF, 38-record SEED96 pool minus vfdb/610, cudb/cu18):
  - the standard 4-record holdout (vfdb/615, vfdb/429, cudb/cu13, cudb/cu32)
  - record-grouped stratified 5-fold CV over the full pool (more stable than
    the 204-window holdout).

Modifies no existing file.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import numpy as np
from sklearn.metrics import accuracy_score, balanced_accuracy_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import GroupKFold, StratifiedGroupKFold

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "greedy_record_inclusion"))
sys.path.insert(0, str(ROOT / "stage1_greedy_record_inclusion"))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import stage1_greedy_record_inclusion as s1g
from vt_vf_seed96_record_holdout_validation import SEED96_ORDER

HOLDOUT = ["vfdb/615", "vfdb/429", "cudb/cu13", "cudb/cu32"]
DROPPED = ["vfdb/610", "cudb/cu18"]

CANDIDATES = ["hp5_o3", "hp3_o3", "hp2_o3", "hp1_o3", "bp01_40_o4", "bp05_40_o4",
              "bp1_40_o4", "bp2_40_o4", "bp3_40_o4", "bp5_40_o4"]

S1_SETS = {
    "base4": ["mean_abs", "zero_crossings", "line_length", "threshold_crossings"],
    "shared6": ["mean_abs", "zero_crossings", "line_length", "threshold_crossings", "local_amp_range", "amp_transition"],
    "shared6db": ["mean_abs", "zero_crossings_db", "line_length", "threshold_crossings", "local_amp_range", "amp_transition"],
}
S2_SETS = {
    "orig7": ["mean_abs", "line_length", "zero_crossings_db", "threshold_crossings", "local_amp_mean", "local_amp_range", "amp_transition"],
    "shared6db": ["mean_abs", "line_length", "zero_crossings_db", "threshold_crossings", "local_amp_range", "amp_transition"],
    "shared6": ["mean_abs", "line_length", "zero_crossings", "threshold_crossings", "local_amp_range", "amp_transition"],
}


def make_model():
    return exp.make_model(1.0)


def stage1_scores(x, y, groups):
    cv_scores = np.zeros(y.size)
    cv_pred90 = np.zeros(y.size, dtype=np.int64)
    for train, test in GroupKFold(n_splits=5).split(x, y, groups):
        model = make_model().fit(x[train], y[train])
        train_scores = model.decision_function(x[train])
        abnormal_scores = np.sort(train_scores[y[train] == 1])
        threshold = abnormal_scores[int(np.floor(0.10 * abnormal_scores.size))]
        test_scores = model.decision_function(x[test])
        cv_scores[test] = test_scores
        cv_pred90[test] = (test_scores >= threshold).astype(np.int64)
    return {
        "s1_cv_auc": roc_auc_score(y, cv_scores),
        "s1_cv_r90_recall": recall_score(y, cv_pred90, zero_division=0),
        "s1_cv_r90_precision": precision_score(y, cv_pred90, zero_division=0),
        "s1_cv_r90_specificity": recall_score(y, cv_pred90, pos_label=0, zero_division=0),
        "s1_cv_r90_bal_acc": balanced_accuracy_score(y, cv_pred90),
    }


def stage1_within_record(x, y, rows):
    record_train, record_test = s1g.build_within_record_split(rows)
    testable = [r for r in record_train if r in record_test]
    train_idx = np.concatenate([record_train[r] for r in testable])
    test_idx = np.concatenate([record_test[r] for r in testable])
    model = make_model().fit(x[train_idx], y[train_idx])
    pred = model.predict(x[test_idx])
    return {
        "s1_wr_bal_acc": balanced_accuracy_score(y[test_idx], pred),
        "s1_wr_recall": recall_score(y[test_idx], pred, zero_division=0),
        "s1_wr_precision": precision_score(y[test_idx], pred, zero_division=0),
    }


def stage2_metrics(x, y, record_ids):
    pool = [r for r in SEED96_ORDER if r not in DROPPED]
    in_pool = np.isin(record_ids, pool)
    x, y, record_ids = x[in_pool], y[in_pool], record_ids[in_pool]
    vt = int(np.unique(y).min())

    test_mask = np.isin(record_ids, HOLDOUT)
    model = make_model().fit(x[~test_mask], y[~test_mask])
    pred = model.predict(x[test_mask])
    out = {
        "s2_ho_acc": accuracy_score(y[test_mask], pred),
        "s2_ho_vt_precision": precision_score(y[test_mask], pred, pos_label=vt, zero_division=0),
        "s2_ho_vt_recall": recall_score(y[test_mask], pred, pos_label=vt, zero_division=0),
    }

    cv_pred = np.zeros(y.size, dtype=np.int64)
    for train, test in StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=7).split(x, y, record_ids):
        cv_pred[test] = make_model().fit(x[train], y[train]).predict(x[test])
    out.update({
        "s2_cv_acc": accuracy_score(y, cv_pred),
        "s2_cv_bal_acc": balanced_accuracy_score(y, cv_pred),
        "s2_cv_vt_recall": recall_score(y, cv_pred, pos_label=vt, zero_division=0),
        "s2_cv_vt_precision": precision_score(y, cv_pred, pos_label=vt, zero_division=0),
    })
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", type=Path, default=Path(__file__).resolve().parent / "results")
    arguments = parser.parse_args()

    s1_rows_out, s2_rows_out = [], []
    for name in CANDIDATES:
        data = np.load(arguments.results_dir / f"shared_{name}.npz")
        names = list(data["feature_names"])
        same = np.allclose(data["s1_features"][:, names.index("mean_abs")],
                           data["s1_features"][:, names.index("local_amp_mean")], atol=1e-4)

        x1_all = data["s1_features"].astype(np.float64)
        y1 = data["s1_label"]
        g1 = data["s1_record_id"]
        rows1 = [{"record_id": r, "start": int(s)} for r, s in zip(g1, data["s1_start"])]
        for set_name, cols in S1_SETS.items():
            x1 = x1_all[:, [names.index(c) for c in cols]]
            result = {"filter": name, "s1_set": set_name}
            result.update(stage1_scores(x1, y1, g1))
            result.update(stage1_within_record(x1, y1, rows1))
            s1_rows_out.append(result)
            print(f"[S1] {name:<11} {set_name:<10} AUC={result['s1_cv_auc']:.4f} "
                  f"r90: rec={result['s1_cv_r90_recall']:.4f} prec={result['s1_cv_r90_precision']:.4f} "
                  f"spec={result['s1_cv_r90_specificity']:.4f} | within-rec bal={result['s1_wr_bal_acc']:.4f} "
                  f"rec={result['s1_wr_recall']:.4f}", flush=True)

        x2_all = data["s2_features"].astype(np.float64)
        y2 = data["s2_label"]
        g2 = data["s2_record_id"]
        for set_name, cols in S2_SETS.items():
            x2 = x2_all[:, [names.index(c) for c in cols]]
            result = {"filter": name, "s2_set": set_name}
            result.update(stage2_metrics(x2, y2, g2))
            s2_rows_out.append(result)
            print(f"[S2] {name:<11} {set_name:<10} holdout acc={result['s2_ho_acc']:.4f} "
                  f"VT P/R={result['s2_ho_vt_precision']:.3f}/{result['s2_ho_vt_recall']:.3f} | "
                  f"CV acc={result['s2_cv_acc']:.4f} bal={result['s2_cv_bal_acc']:.4f} "
                  f"VT P/R={result['s2_cv_vt_precision']:.3f}/{result['s2_cv_vt_recall']:.3f}", flush=True)
        print(f"     (local_amp_mean == mean_abs: {same})")

    for filename, rows in (("stage1_candidates.csv", s1_rows_out), ("stage2_candidates.csv", s2_rows_out)):
        with (arguments.results_dir / filename).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
    print(f"Wrote {arguments.results_dir / 'stage1_candidates.csv'} and stage2_candidates.csv")


if __name__ == "__main__":
    main()
