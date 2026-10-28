"""Compare deployable Stage 1 decisions with the saved float model on test records.

The input stream uses the same linear 120 Hz interpolation as the MATLAB
combined-system script. No database or result files are written.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import scipy.io
from scipy.signal import butter, lfilter
import wfdb

from fixed_stage1 import features, filter_samples, score

ROOT = Path(__file__).resolve().parents[3]
ARTIFACT = ROOT / "final_two_stage_design/stage1/models/stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_pthighpass_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude_robust_range.mat"
CPU = ROOT / "final_two_stage_design/stage1/models/pthighpass_svm_cpu_export.mat"
DB_DIRS = [
    "mit-bih-arrhythmia-database-1.0.0",
    "mit-bih-malignant-ventricular-ectopy-database-1.0.0",
    "cu-ventricular-tachyarrhythmia-database-1.0.0",
]


def quant_q3_8(values: np.ndarray) -> np.ndarray:
    return np.clip(np.trunc(values * 256), -2048, 2047).astype(np.int64)


def float_features(q: np.ndarray) -> list[float]:
    mean = np.trunc(float(q.sum()) / 240)
    centered = q - mean
    diff = np.diff(q)
    sign = np.sign(diff)
    sign = sign[sign != 0]
    zc = int(np.count_nonzero(sign[1:] != sign[:-1]))
    peak = np.max(np.abs(centered))
    above = 5 * np.abs(centered) >= peak if peak else np.zeros(240, bool)
    return [float(np.trunc(np.abs(centered).sum() / 240) / 256),
            zc / 2, float(np.abs(diff).sum() / 512),
            int(np.count_nonzero(above[1:] != above[:-1]))]


def main() -> None:
    dbroot = ROOT / "databases"
    if not dbroot.is_dir():
        dbroot = ROOT.parent / "databases"
    records = [p.with_suffix("") for folder in DB_DIRS
               for p in sorted((dbroot / folder).glob("*.hea"))]
    artifact = scipy.io.loadmat(ARTIFACT, variable_names=["testRecordIds"])
    test_indices = artifact["testRecordIds"].ravel().astype(int) - 1
    cpu = scipy.io.loadmat(CPU)
    weights = cpu["W"].ravel().astype(float)
    bias = float(cpu["Bhw"].item())
    b, a = butter(3, 5, btype="highpass", fs=120)
    total = differences = sequence_total = sequence_differences = 0
    for index in test_indices:
        path = records[index]
        record = wfdb.rdrecord(str(path))
        source = np.asarray(record.p_signal[:, 0], dtype=float)
        good = np.isfinite(source)
        if not np.all(good):
            points = np.arange(len(source))
            source = np.interp(points, points[good], source[good])
        fs = float(record.fs)
        target_count = int(np.floor(((len(source) - 1) / fs) * 120)) + 1
        raw = np.interp(np.arange(target_count) / 120,
                        np.arange(len(source)) / fs, source)
        raw_q16 = np.rint(raw * 65536).astype(np.int64)
        fixed_filtered = filter_samples(raw_q16.tolist())
        float_filtered = quant_q3_8(lfilter(b, a, quant_q3_8(raw) / 256))
        fixed_votes = []
        float_votes = []
        for start in range(0, len(raw) - 239, 120):
            fixed_score = score(features(fixed_filtered[start:start + 240]))
            float_score = float(np.dot(float_features(float_filtered[start:start + 240]), weights) + bias)
            fixed_votes.append(fixed_score >= 0)
            float_votes.append(float_score >= 0)
            differences += int(fixed_votes[-1] != float_votes[-1])
            total += 1
        for i in range(2, len(fixed_votes)):
            sequence_total += 1
            sequence_differences += int((sum(fixed_votes[i-2:i+1]) >= 2) !=
                                        (sum(float_votes[i-2:i+1]) >= 2))
        print(f"checked {path.parent.name}/{path.name}")
    print(f"test records: {len(test_indices)}, windows: {total}")
    print(f"Stage 1 base-decision differences from float model: {differences}")
    print(f"Stage 1 2-of-3 differences: {sequence_differences}/{sequence_total}")


if __name__ == "__main__":
    main()
