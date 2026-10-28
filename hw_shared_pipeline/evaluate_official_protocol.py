"""Python replica of the official Stage 1 evaluation protocol in
`final_low_power_design/code/eval_pthighpass_seq_120hz.m`, applied to the
shared-hardware candidates so they can be compared on the same footing as the
deployed numbers (95.32% / precision 0.8596 / recall 0.9806).

Protocol replicated:
  - MIT-BIH normal windows randomly thinned to 25% per record BEFORE the
    train/test split (mitdbNormalKeepFraction = 0.25).
  - record-level split: 20% of records with abnormal windows and 20% of
    records without, held out (split_records_for_holdout).
  - balanced linear SVM; decision threshold = max training accuracy subject
    to training recall >= 0.98 (accuracy_recall_floor objective).
  - test sequences = runs of 3 CONSECUTIVE surviving windows (window index
    step of exactly 1), truth = abnormal if >= 1 window abnormal, predicted
    abnormal if >= 2 of 3 window decisions are abnormal.
MATLAB's random split cannot be reproduced exactly, so results are averaged
over several split seeds.

Also reports an "honest" variant: identical training, but the test records
are NOT thinned, so every real normal-rhythm sequence stays in the test set.

Modifies no existing file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp

SIX = ["mean_abs", "zero_crossings", "line_length", "threshold_crossings", "local_amp_range", "amp_transition"]
FOUR = SIX[:4]


def thin_mask(y, record_ids, keep=0.25, seed=31):
    mask = np.ones(y.size, dtype=bool)
    for i, r in enumerate(np.unique(record_ids)):
        if not r.startswith("mitdb/"):
            continue
        normal = np.flatnonzero((record_ids == r) & (y == 0))
        rng = np.random.default_rng(seed + i)
        drop = rng.permutation(normal)[int(round(keep * normal.size)):]
        mask[drop] = False
    return mask


def split_records(y, record_ids, seed, test_fraction=0.20):
    records = np.unique(record_ids)
    has_abnormal = np.array([np.any(y[record_ids == r] == 1) for r in records])
    rng = np.random.default_rng(seed)
    test = []
    for cls in (False, True):
        pool = records[has_abnormal == cls]
        n = min(max(1, int(round(test_fraction * pool.size))), pool.size - 1)
        test.extend(rng.permutation(pool)[:n].tolist())
    return np.isin(record_ids, test)


def recall_floor_threshold(scores, y, min_recall=0.98):
    candidates = np.unique(np.quantile(scores, np.linspace(0, 1, 250)))
    best_acc, best_thr = -1.0, np.median(candidates)
    for t in candidates:
        pred = scores >= t
        tp = np.sum(pred & (y == 1))
        if tp / max(1, np.sum(y == 1)) < min_recall:
            continue
        acc = np.mean(pred == (y == 1))
        if acc > best_acc:
            best_acc, best_thr = acc, t
    return best_thr


def sequence_metrics(window_pred, y, record_ids, starts):
    truth, pred = [], []
    for r in np.unique(record_ids):
        idx = np.flatnonzero(record_ids == r)
        idx = idx[np.argsort(starts[idx])]
        w = starts[idx] // 120
        for k in range(idx.size - 2):
            if w[k + 1] - w[k] != 1 or w[k + 2] - w[k + 1] != 1:
                continue
            trio = idx[k:k + 3]
            truth.append(int(np.any(y[trio] == 1)))
            pred.append(int(np.sum(window_pred[trio]) >= 2))
    truth, pred = np.array(truth), np.array(pred)
    tp = np.sum((pred == 1) & (truth == 1)); fp = np.sum((pred == 1) & (truth == 0))
    fn = np.sum((pred == 0) & (truth == 1)); tn = np.sum((pred == 0) & (truth == 0))
    precision = tp / max(1, tp + fp); recall = tp / max(1, tp + fn)
    return dict(acc=(tp + tn) / truth.size, precision=precision, recall=recall,
                f1=2 * precision * recall / max(1e-12, precision + recall),
                specificity=tn / max(1, tn + fp), n_normal_seq=int(tn + fp), n_abnormal_seq=int(tp + fn))


def evaluate(x, y, record_ids, starts, seeds):
    keep = thin_mask(y, record_ids)
    out = {"official": [], "honest": []}
    for seed in seeds:
        test = split_records(y[keep], record_ids[keep], seed)
        test_records = np.unique(record_ids[keep][test])
        train_rows = keep & ~np.isin(record_ids, test_records)
        model = exp.make_model(1.0).fit(x[train_rows], y[train_rows])
        threshold = recall_floor_threshold(model.decision_function(x[train_rows]), y[train_rows])
        for variant, rows in (("official", keep & np.isin(record_ids, test_records)),
                              ("honest", np.isin(record_ids, test_records))):
            window_pred = (model.decision_function(x[rows]) >= threshold).astype(int)
            out[variant].append(sequence_metrics(window_pred, y[rows], record_ids[rows], starts[rows]))
    return {v: {k: float(np.mean([m[k] for m in ms])) for k in ms[0]} for v, ms in out.items()}


def main() -> None:
    seeds = range(17, 27)
    results = HERE / "results"

    def load(kind, name):
        return np.load(results / f"{kind}_{name}.npz")

    base = load("shared", "hp5_o3")
    names = list(base["feature_names"])
    y, rid, st = base["s1_label"], base["s1_record_id"], base["s1_start"]
    cols = lambda d, c: d["s1_features"][:, [names.index(n) for n in c]].astype(np.float64)

    configs = {
        "BASELINE 5Hz HP, 4 features": cols(base, FOUR),
        "5Hz HP, 6 features": cols(base, SIX),
        "SHARED 1Hz HP, x6 + diff6 (12)": np.hstack([cols(load("shared", "hp1_o3"), SIX), cols(load("diff", "hp1_o3"), SIX)]),
        "SHARED 1Hz HP, diff6 only": cols(load("diff", "hp1_o3"), SIX),
        "SHARED 2Hz HP, x6 + diff6 (12)": np.hstack([cols(load("shared", "hp2_o3"), SIX), cols(load("diff", "hp2_o3"), SIX)]),
    }
    for label, x in configs.items():
        r = evaluate(x, y, rid, st, seeds)
        for variant in ("official", "honest"):
            m = r[variant]
            print(f"{label:<32} {variant:<8} acc={m['acc']:.4f} P={m['precision']:.4f} R={m['recall']:.4f} "
                  f"F1={m['f1']:.4f} spec={m['specificity']:.4f} (normal seq={m['n_normal_seq']:.0f}, "
                  f"abnormal seq={m['n_abnormal_seq']:.0f})", flush=True)


if __name__ == "__main__":
    main()
