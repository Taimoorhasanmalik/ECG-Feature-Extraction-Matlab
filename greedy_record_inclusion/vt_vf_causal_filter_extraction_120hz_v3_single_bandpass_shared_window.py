"""Tests the literal "shared window" architecture (raw Q3.8 buffer windowed
FIRST, each stage's filter then runs independently PER WINDOW from zero
state) using Stage 2's NEW single 4th-order 0.1-40 Hz causal bandpass
(replacing the old two-filter cascade tested in
`vt_vf_causal_filter_extraction_120hz_v3_shared_window.py`).

Purpose: the single bandpass still has a 0.1 Hz low corner, so it likely
still has a multi-second settling time -- this measures whether the simpler
single-filter design changes the per-window-reset accuracy cost measured
before (0.9510 continuous baseline -> 0.8922 per-window-reset with the old
cascade).

Modifies no existing file. Does not touch Stage 1 in any way.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base
import vt_vf_temporal_stability_feature_experiment as tsf

ANALYSIS_FS = 120.0
WINDOW_SECONDS = 2.0
STRIDE_SECONDS = 1.0
VT_LABEL = tsf.VT_LABEL
VF_LABEL = tsf.VF_LABEL
NEW_FEATURE_NAMES = tsf.NEW_FEATURE_NAMES


def quantize_signed_q_format(x, integer_bits, fraction_bits):
    scale = 2 ** fraction_bits
    qmin = -(2 ** integer_bits)
    qmax = 2 ** integer_bits - 1.0 / scale
    return np.clip(np.trunc(x * scale) / scale, qmin, qmax)


def filter_01_40_causal(signal: np.ndarray, fs: float) -> np.ndarray:
    sos = butter(4, [0.1, 40.0], btype="bandpass", fs=fs, output="sos")
    return sosfilt(sos, signal)


def extract_dataset_causal_240hz(databases_root: Path) -> tuple[list[dict], np.ndarray]:
    all_rows: list[dict] = []
    all_old_features: list[list[float]] = []

    for db in ("vfdb", "cudb"):
        folder = databases_root / exp.DB_FOLDERS[db]
        for record_path in exp.record_bases(folder):
            import wfdb
            from fractions import Fraction

            name = record_path.name
            header = wfdb.rdheader(str(record_path))
            annotation = wfdb.rdann(str(record_path), "atr")
            record = wfdb.rdrecord(str(record_path))
            source_fs = float(header.fs)

            raw_signal = np.asarray(record.p_signal[:, 0], dtype=np.float64)
            raw_invalid = ~np.isfinite(raw_signal)
            source = base.interpolate_nonfinite(raw_signal)
            if abs(source_fs - ANALYSIS_FS) > 1e-9:
                from scipy.signal import resample_poly

                ratio = Fraction(ANALYSIS_FS / source_fs).limit_denominator(10_000)
                signal = resample_poly(source, ratio.numerator, ratio.denominator)
            else:
                signal = source.copy()
            signal = np.asarray(signal, dtype=np.float64)
            raw_q38 = quantize_signed_q_format(signal, 3, 8)  # shared raw window buffer
            signal_length = raw_q38.size

            if abs(source_fs - ANALYSIS_FS) > 1e-9:
                positions = np.minimum(
                    (np.arange(signal_length) * source_fs / ANALYSIS_FS).astype(np.int64),
                    raw_signal.size - 1,
                )
                invalid = raw_invalid[positions]
            else:
                invalid = raw_invalid[:signal_length]
                if invalid.size < signal_length:
                    invalid = np.concatenate([invalid, np.zeros(signal_length - invalid.size, dtype=bool)])
            invalid_prefix = np.concatenate(([0], np.cumsum(invalid, dtype=np.int64)))
            symbols = list(annotation.symbol)
            subtypes = list(annotation.subtype)
            noisy = exp.noisy_interval_mask(
                np.rint(np.asarray(annotation.sample) * (ANALYSIS_FS / source_fs)).astype(np.int64),
                symbols, subtypes, signal_length,
            )
            noisy_prefix = np.concatenate(([0], np.cumsum(noisy, dtype=np.int64)))
            shocks = [s for s, _ in exp.dropout_runs(invalid, int(round(0.2 * ANALYSIS_FS)))]

            record_id = f"{db}/{name}"

            ann_samples = np.rint(np.asarray(annotation.sample) * (ANALYSIS_FS / source_fs)).astype(np.int64)
            if db == "cudb":
                intervals = exp.bracket_intervals(db, record_id, ann_samples, symbols, signal_length)
            else:
                notes = [str(item) for item in annotation.aux_note]
                intervals = exp.note_intervals(db, record_id, ann_samples, symbols, notes, signal_length)
                if db == "mitdb":
                    intervals = [item for item in intervals if item.raw_rhythm != exp.RAW_CUDB]

            width = int(round(WINDOW_SECONDS * ANALYSIS_FS))
            stride = int(round(STRIDE_SECONDS * ANALYSIS_FS))
            record_windows_count = 0
            record_rows: list[dict] = []
            record_old_features: list[list[float]] = []
            for interval in intervals:
                if interval.raw_rhythm == exp.RAW_VT:
                    label = VT_LABEL
                elif interval.raw_rhythm in exp.VF_FAMILY:
                    label = VF_LABEL
                else:
                    continue
                end_limit = min(interval.end, signal_length)
                if end_limit - interval.start < width:
                    continue
                episode_shocks = [s for s in shocks if interval.start <= s < end_limit]
                first_shock = min(episode_shocks) if episode_shocks else None
                for start in range(interval.start, end_limit - width + 1, stride):
                    end = start + width
                    if invalid_prefix[end] - invalid_prefix[start] > 0:
                        continue
                    if noisy_prefix[end] - noisy_prefix[start] > 0:
                        continue
                    if first_shock is not None and start >= first_shock:
                        continue
                    if not interval.closed:
                        continue

                    raw_window = raw_q38[start:end]
                    window_bp = filter_01_40_causal(raw_window, ANALYSIS_FS)  # reset state per window
                    window_signal = quantize_signed_q_format(window_bp, 5, 8)

                    centered = window_signal - np.mean(window_signal)
                    new_feats = tsf.new_feature_row(centered, ANALYSIS_FS)

                    derivative = np.diff(centered)
                    threshold = 0.20 * float(np.max(np.abs(centered)))
                    above = np.abs(centered) >= threshold if threshold > 0 else np.zeros(centered.size, bool)
                    mean_abs_amp = float(np.mean(np.abs(centered)))
                    line_length = float(np.sum(np.abs(derivative)))
                    zero_crossings = float(base.derivative_zero_crossings(derivative))
                    threshold_crossings = float(np.sum(above[:-1] != above[1:]))

                    record_windows_count += 1
                    record_old_features.append([mean_abs_amp, line_length, zero_crossings, threshold_crossings])
                    record_rows.append({
                        "record_id": record_id, "db": db, "start": start, "end": end,
                        "label": label, "raw_rhythm": interval.raw_rhythm,
                        **{k: new_feats[k] for k in NEW_FEATURE_NAMES},
                    })

            if record_rows:
                all_old_features.extend(record_old_features)
                all_rows.extend(record_rows)
            print(f"    {record_id}: {record_windows_count} windows", flush=True)

    old_features = np.asarray(all_old_features, dtype=np.float64) if all_old_features else np.zeros((0, 4))
    new_features = np.array([[r[name] for name in NEW_FEATURE_NAMES] for r in all_rows])
    features = np.hstack([old_features, new_features])
    return all_rows, features


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    rows, features = extract_dataset_causal_240hz(arguments.databases_root)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(arguments.output, rows=np.array(rows, dtype=object), features=features)
    print(f"\n{len(rows)} windows across {len({r['record_id'] for r in rows})} records")
    print(f"Wrote {arguments.output}")


if __name__ == "__main__":
    main()
