"""Compare deployable fixed Stage 2 variants with their held-out rows.

Uses the existing databases in-place; writes no new database or result files.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
from pathlib import Path

import numpy as np
import scipy.io
from scipy.signal import resample_poly
import wfdb

from fixed_stage2 import (SHARED_FRONTEND_BIAS_Q13, SHARED_FRONTEND_WEIGHTS_Q13,
                          features, filter_samples, score, shared_raw_q16_16)

ROOT = Path(__file__).resolve().parents[3]
ARTIFACT = ROOT / "final_two_stage_design/stage2/models/stage2_matlab_validation_artifacts_120hz_v3.mat"
SHARED_ARTIFACT = ROOT / "shared_frontend_validation/stage2_matlab_validation_artifacts_120hz_shared_frontend.mat"
DB_DIRS = {
    "vfdb": "mit-bih-malignant-ventricular-ectopy-database-1.0.0",
    "cudb": "cu-ventricular-tachyarrhythmia-database-1.0.0",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shared-frontend", action="store_true")
    args = parser.parse_args()
    dbroot = ROOT / "databases"
    if not dbroot.is_dir():
        dbroot = ROOT.parent / "databases"
    artifact = scipy.io.loadmat(SHARED_ARTIFACT if args.shared_frontend else ARTIFACT)
    if args.shared_frontend:
        folded = artifact["svm_coef"] / artifact["scaler_scale"]
        exported_weights = np.trunc(folded * 8192).astype(int).ravel().tolist()
        exported_bias = int(np.trunc((artifact["svm_intercept"] -
                                      np.sum(folded * artifact["scaler_mean"])) * 8192).item())
        assert exported_weights == SHARED_FRONTEND_WEIGHTS_Q13
        assert exported_bias == SHARED_FRONTEND_BIAS_Q13
    ids = [str(v.item()) for v in artifact["test_record_id"].ravel()]
    starts = artifact["test_start_sample"].ravel().astype(int)
    ends = artifact["test_end_sample"].ravel().astype(int)
    expected_features = artifact["test_features_python"]
    expected_pred = artifact["test_python_predicted_label"].ravel().astype(int)
    truth = artifact["test_true_label"].ravel().astype(int)
    feature_mismatch = decision_mismatch = correct = 0
    max_diff = np.zeros(7, dtype=float)
    for record_id in sorted(set(ids)):
        db, name = record_id.split("/", 1)
        record = wfdb.rdrecord(str(dbroot / DB_DIRS[db] / name))
        source = np.asarray(record.p_signal[:, 0], dtype=float)
        good = np.isfinite(source)
        if not np.all(good):
            indices = np.arange(len(source))
            source = np.interp(indices, indices[good], source[good])
        ratio = Fraction(120 / float(record.fs)).limit_denominator(10000)
        resampled = resample_poly(source, ratio.numerator, ratio.denominator)
        input_q16 = np.rint(resampled * 65536).astype(np.int64).tolist()
        filtered = filter_samples(shared_raw_q16_16(input_q16) if args.shared_frontend else input_q16)
        for i in (j for j, value in enumerate(ids) if value == record_id):
            actual = np.asarray(features(filtered[starts[i]:ends[i]]), dtype=float)
            delta = np.abs(actual / np.array([256,256,1,1,256,256,256]) - expected_features[i])
            max_diff = np.maximum(max_diff, delta)
            feature_mismatch += int(np.any(delta != 0))
            predicted = int(score(actual.astype(int).tolist(), args.shared_frontend) > 0)
            decision_mismatch += int(predicted != expected_pred[i])
            correct += int(predicted == truth[i])
        print(f"checked {record_id}")
    print(f"held-out rows: {len(ids)}")
    variant = "shared-front-end" if args.shared_frontend else "v3"
    print(f"feature rows differing from float {variant}: {feature_mismatch}")
    print(f"decision differences from float {variant}: {decision_mismatch}")
    print(f"fixed-point held-out accuracy: {correct / len(ids):.6f}")
    print(f"maximum feature differences: {max_diff.tolist()}")


if __name__ == "__main__":
    main()
