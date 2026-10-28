"""Read-only record check of the candidate Stage 2 fixed-point arithmetic.

Requires the existing PhysioNet databases and the shared-pipeline MAT export.
It creates no result files or database copies.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import scipy.io
import wfdb

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "hw_shared_pipeline" / "stage2"))
sys.path.insert(0, str(ROOT / "hw_shared_pipeline"))
sys.path.insert(0, str(ROOT))
import build_stage2_shared as model
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
from fixed_shared_hp1 import features, filter_samples, score


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all-records", action="store_true",
                        help="also evaluate all 38 records with independent LORO weights")
    args = parser.parse_args()
    result_dir = ROOT / "hw_shared_pipeline" / "stage2" / "results"
    model_file = result_dir / "stage2_shared_alldata.mat"
    exported = scipy.io.loadmat(model_file, squeeze_me=True)
    holdout_export = scipy.io.loadmat(result_dir / "stage2_shared_holdout.mat", squeeze_me=True)
    record_ids = np.asarray(exported["test_record_id"], dtype=str)
    holdout = np.isin(record_ids, model.HOLDOUT)
    starts = np.asarray(exported["test_start_sample"], dtype=int)
    expected_features = np.asarray(exported["test_features_python"], dtype=float)
    expected_pred = np.asarray(exported["test_python_fixed_point_label"], dtype=int)
    truth = np.asarray(exported["test_true_label"], dtype=int)
    selected = np.arange(len(record_ids)) if args.all_records else np.flatnonzero(holdout)
    actual_features = np.zeros((len(selected), 6), dtype=float)
    actual_pred = np.zeros(len(selected), dtype=int)
    database_root = ROOT / "databases"
    if not database_root.is_dir():
        database_root = ROOT.parent / "databases"
    for rid in sorted(set(record_ids[selected])):
        positions = np.flatnonzero(record_ids[selected] == rid)
        row_indices = selected[positions]
        db, name = rid.split("/")
        path = database_root / exp.DB_FOLDERS[db] / name
        record = wfdb.rdrecord(str(path), channels=[0])
        raw = model.base.interpolate_nonfinite(np.asarray(record.p_signal[:, 0], dtype=float))
        if abs(record.fs - model.FS) > 1e-6:
            raw = model.linear_resample_like_matlab(raw, record.fs)
        raw_q8 = np.rint(model.q(raw, 3, 8) * 256).astype(np.int64)
        stop = int(starts[row_indices].max()) + 240
        filtered = filter_samples([int(value) << 8 for value in raw_q8[:stop]])
        for pos, row_idx in zip(positions, row_indices):
            values = features(filtered[starts[row_idx]:starts[row_idx] + 240])
            actual_features[pos] = [values[0] / 256, values[1] / 2,
                                    values[2] / 256, values[3],
                                    values[4] / 256, values[5] / 256]
            actual_pred[pos] = int(score(values) > 0)
        print(f"{rid}: {len(row_indices)} windows checked", flush=True)
    expected = expected_features[selected]
    delta = np.abs(actual_features - expected)
    print("feature max abs differences:", delta.max(axis=0).tolist())
    print("feature-exact windows:", int(np.all(delta == 0, axis=1).sum()), "/", len(selected))
    print("prediction mismatch vs deployed all-data fixed export:",
          int(np.sum(actual_pred != expected_pred[selected])))
    print("all-data model accuracy on these training-included records:",
          float(np.mean(actual_pred == truth[selected])))
    if args.all_records:
        loro = scipy.io.loadmat(result_dir / "stage2_shared_loro_weights.mat", squeeze_me=True)
        weights_by_record = {
            str(rid): (np.asarray(weight, dtype=float), float(bias))
            for rid, weight, bias in zip(loro["record_id"], loro["weight_q"], loro["bias_q"])
        }
        loro_pred = np.array([
            int(np.dot(feature, weights_by_record[rid][0]) +
                weights_by_record[rid][1] > 0)
            for feature, rid in zip(actual_features, record_ids[selected])
        ])
        print("independent LORO-model accuracy with hardware features:",
              float(np.mean(loro_pred == truth[selected])))
    else:
        holdout_weights = np.asarray(holdout_export["combined_weight_q"], dtype=float)
        holdout_bias = float(holdout_export["combined_bias_q"])
        heldout_pred = (actual_features @ holdout_weights + holdout_bias > 0).astype(int)
        holdout_expected = np.asarray(holdout_export["test_python_fixed_point_label"], dtype=int)
        holdout_keys = list(zip(np.asarray(holdout_export["test_record_id"], dtype=str),
                                np.asarray(holdout_export["test_start_sample"], dtype=int)))
        actual_keys = list(zip(record_ids[selected], starts[selected]))
        expected_by_key = dict(zip(holdout_keys, holdout_expected))
        expected_aligned = np.array([expected_by_key[key] for key in actual_keys], dtype=int)
        print("independent holdout-model prediction mismatches:",
              int(np.sum(heldout_pred != expected_aligned)))
        print("independent holdout-model accuracy with hardware features:",
              float(np.mean(heldout_pred == truth[selected])))


if __name__ == "__main__":
    main()
