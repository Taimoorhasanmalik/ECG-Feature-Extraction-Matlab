"""Honest record-grouped validation of the seed=96, 40-record pool finalized
from `vt_vf_greedy_order_seed_sweep.py`.

Every metric produced by the greedy-inclusion method (and its seed sweep) is
measured on held-out WINDOWS from records already in the training pool --
never on a genuinely unseen record. This script closes that gap: it takes
the last N records in seed=96's exact acceptance order (the records added
last, i.e. the ones the greedy pass was least sure about) out of the pool
entirely, trains on ALL windows of the remaining records (no within-record
70/30 split needed here -- these held-out records share no windows with the
training records at all, so there is no overlap to guard against), and tests
on ALL windows of the held-out records. This is the same record-grouped
generalization check used everywhere else in this project.

Uses the 7-feature ultra-light set by default (mean_abs_amp, line_length,
derivative_zero_crossings, threshold_crossings, local_amp_mean,
local_amp_range, amp_transition) -- the set already selected for seed=96.
Modifies no existing file.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from sklearn.metrics import accuracy_score, balanced_accuracy_score, precision_score, recall_score

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_greedy_record_inclusion_window_holdout as greedy

SEED96_ORDER = [
    "vfdb/611", "vfdb/607", "cudb/cu27", "cudb/cu08", "vfdb/426", "cudb/cu05", "vfdb/428",
    "cudb/cu03", "cudb/cu01", "vfdb/605", "cudb/cu21", "cudb/cu22", "vfdb/614", "cudb/cu23",
    "cudb/cu12", "cudb/cu26", "vfdb/425", "cudb/cu11", "vfdb/424", "cudb/cu25", "cudb/cu33",
    "cudb/cu17", "vfdb/610", "cudb/cu07", "cudb/cu16", "cudb/cu34", "cudb/cu04", "vfdb/419",
    "vfdb/609", "cudb/cu06", "vfdb/615", "cudb/cu10", "cudb/cu09", "vfdb/418", "vfdb/429",
    "cudb/cu24", "cudb/cu19", "cudb/cu13", "cudb/cu18", "cudb/cu32",
]

DEFAULT_FEATURES = [
    "mean_abs_amp", "line_length", "derivative_zero_crossings", "threshold_crossings",
    "local_amp_mean", "local_amp_range", "amp_transition",
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--cache", type=Path, default=None)
    parser.add_argument("--c-value", type=float, default=1.0)
    parser.add_argument("--n-holdout", type=int, default=5, help="how many of the last-accepted records to hold out entirely")
    parser.add_argument("--holdout-records", type=str, default=None,
                         help="comma-separated explicit record list to hold out instead of the flat last-N")
    parser.add_argument("--drop-records", type=str, default=None,
                         help="comma-separated record list to remove entirely from the pool (neither train nor test)")
    parser.add_argument("--features", type=str, default=",".join(DEFAULT_FEATURES))
    arguments = parser.parse_args()

    cache = arguments.cache or (Path("final_high_power_design") / "temporal_stability_raw_cache.npz")
    rows, features = greedy.load_dataset(arguments.databases_root, cache)
    labels = np.array([row["label"] for row in rows], dtype=np.int64)

    feature_names = [name.strip() for name in arguments.features.split(",")]
    columns = [greedy.ALL_FEATURE_NAMES.index(name) for name in feature_names]
    features = features[:, columns]
    print(f"Using {len(feature_names)} features: {feature_names}\n")

    pool = SEED96_ORDER
    dropped_records: list[str] = []
    if arguments.drop_records:
        dropped_records = [name.strip() for name in arguments.drop_records.split(",")]
        pool = [r for r in pool if r not in dropped_records]

    if arguments.holdout_records:
        holdout_records = [name.strip() for name in arguments.holdout_records.split(",")]
        train_records = [r for r in pool if r not in holdout_records]
    else:
        holdout_records = pool[-arguments.n_holdout:]
        train_records = pool[: len(pool) - arguments.n_holdout]

    if dropped_records:
        print(f"Dropped entirely from the pool: {dropped_records}")
    print(f"Pool: {len(pool)} records (seed=96 finalized order, after any drops)")
    print(f"Train on: {len(train_records)} records (all windows, full record)")
    print(f"Held out entirely: {len(holdout_records)} records -> {holdout_records}\n")

    record_id_array = np.array([row["record_id"] for row in rows])
    train_mask = np.isin(record_id_array, train_records)
    test_mask = np.isin(record_id_array, holdout_records)

    x_train, y_train = features[train_mask], labels[train_mask]
    x_test, y_test = features[test_mask], labels[test_mask]
    print(f"Train windows: {x_train.size and x_train.shape[0]}  (VT={int((y_train==greedy.VT_LABEL).sum())}, "
          f"VF={int((y_train==greedy.VF_LABEL).sum())})")
    print(f"Test windows:  {x_test.shape[0]}  (VT={int((y_test==greedy.VT_LABEL).sum())}, "
          f"VF={int((y_test==greedy.VF_LABEL).sum())})\n")

    model = exp.make_model(arguments.c_value)
    model.fit(x_train, y_train)
    predictions = model.predict(x_test)

    accuracy = accuracy_score(y_test, predictions)
    balanced = balanced_accuracy_score(y_test, predictions)
    vt_precision = precision_score(y_test, predictions, pos_label=greedy.VT_LABEL, zero_division=0)
    vt_recall = recall_score(y_test, predictions, pos_label=greedy.VT_LABEL, zero_division=0)
    vf_precision = precision_score(y_test, predictions, pos_label=greedy.VF_LABEL, zero_division=0)
    vf_recall = recall_score(y_test, predictions, pos_label=greedy.VF_LABEL, zero_division=0)

    print(f"Held-out-RECORD accuracy:          {accuracy:.4f}")
    print(f"Held-out-RECORD balanced accuracy: {balanced:.4f}")
    print(f"VT precision/recall: {vt_precision:.4f} / {vt_recall:.4f}")
    print(f"VF precision/recall: {vf_precision:.4f} / {vf_recall:.4f}\n")

    print("Per-held-out-record breakdown:")
    for record_id in holdout_records:
        idx = record_id_array == record_id
        if not idx.any():
            continue
        record_acc = accuracy_score(labels[idx], model.predict(features[idx]))
        label = "VT" if labels[idx][0] == greedy.VT_LABEL else "VF_FAMILY"
        print(f"  {record_id:<12} label={label:<10} n_windows={int(idx.sum()):<5} accuracy={record_acc:.4f}")


if __name__ == "__main__":
    main()
