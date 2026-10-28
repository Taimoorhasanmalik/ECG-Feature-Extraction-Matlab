"""Fixed version of
`vt_vf_causal_filter_extraction_120hz_v3_single_bandpass_shared_window.py`.

The previous "shared window" script re-filtered each window's raw samples
from a cold (zero) filter state, simulating a design that no real streaming
hardware would use. This version keeps the filter running CONTINUOUSLY over
the whole raw Q3.8 buffer (exactly like a real always-on biquad with
persistent state registers), and only uses the "window" as a read-out of the
most recent 240 already-filtered samples -- i.e., windowing is just a view
into a continuously-running filter's output, not a filter-reset boundary.

This is expected to reproduce
`vt_vf_causal_filter_extraction_120hz_v3_single_bandpass.py`'s accuracy
(0.9559) exactly, since "filter the whole stream once, then window" and
"filter continuously while windowing is just a buffer read" are the same
computation -- this script exists to demonstrate that identity concretely
rather than just assert it.

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
    all_old_features: list[np.ndarray] = []

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

            # Shared raw buffer: Q3.8 quantize once.
            raw_q38 = quantize_signed_q_format(signal, 3, 8)

            # Filter runs CONTINUOUSLY over the whole raw buffer -- persistent
            # state, never reset. "Windowing" below is only a read-out of
            # this already-filtered array, never a re-filtering operation.
            filtered_raw = filter_01_40_causal(raw_q38, ANALYSIS_FS)
            filtered = quantize_signed_q_format(filtered_raw, 5, 8)
            signal_length = filtered.size
            channel_record = base.ChannelRecord(filtered, np.zeros(0, dtype=np.int64))

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
            record_windows: list[base.Window] = []
            record_rows: list[dict] = []
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
                    # Window = read-out only, no filtering happens here.
                    window_signal = filtered[start:end]
                    new_feats = tsf.new_feature_row(window_signal - np.mean(window_signal), ANALYSIS_FS)
                    record_windows.append(base.Window(record_id, interval.episode_id, start, end, label, interval.raw_rhythm))
                    record_rows.append({
                        "record_id": record_id, "db": db, "start": start, "end": end,
                        "label": label, "raw_rhythm": interval.raw_rhythm,
                        **{k: new_feats[k] for k in NEW_FEATURE_NAMES},
                    })

            if record_windows:
                old_feats = base.feature_matrix(record_windows, {record_id: channel_record})[:, :4]
                all_old_features.append(old_feats)
                all_rows.extend(record_rows)
            print(f"    {record_id}: {len(record_windows)} windows", flush=True)

    old_features = np.vstack(all_old_features) if all_old_features else np.zeros((0, 4))
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
