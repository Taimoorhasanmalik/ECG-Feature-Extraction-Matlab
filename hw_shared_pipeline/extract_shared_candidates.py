"""Shared-hardware candidate extractor for a two-stage design that uses ONE
filter, ONE window buffer and ONE feature engine for both stages.

For every record (MITDB, VFDB, CUDB) the signal is read and resampled to
120 Hz once, quantized to Q3.8 once, and then each candidate shared filter is
run continuously over the whole record (causal, persistent state, never reset
per window) followed by Q5.8. Every window of that single filtered stream goes
through the same feature engine, and the resulting feature pool is stored for
both tasks:

  Stage 1 rows: global 240-sample grid with 120-sample stride (what the
                always-on hardware sees), labelled abnormal if >=80% of its
                samples are in a VT/VF interval, normal if <=20%, ambiguous
                windows dropped, windows with >1% annotated noise dropped.
                vfdb/610 and cudb/cu18 excluded, as in the Stage 1 Python track.
  Stage 2 rows: VT / VF-family interval windows with the same validity,
                noise, shock and closed-interval rules as the validated Stage 2
                extraction scripts.

Feature engine (one pass over the stored window plus one threshold pass):
  mean_abs                 mean |x - m|, m = window mean quantized to Q5.8
  line_length              sum |x[n] - x[n-1]|
  zero_crossings           sign changes of the first difference, zero-hold
  zero_crossings_db        same with a 5% of mean|diff| deadband (Stage 2 def)
  threshold_crossings      transitions of |x - m| >= 0.2 * max|x - m|
  local_amp_range          max - min of the 8 block (30-sample) means of |x - m|
  amp_transition           mean |difference| of successive block means
  local_amp_mean           mean of block means (identical to mean_abs, kept as
                           a check only)

Modifies no existing file.
"""

from __future__ import annotations

import argparse
import sys
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.signal import butter, resample_poly, sosfilt

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base

FS = 120.0
WIDTH = 240
STRIDE = 120
BLOCK = 30
MIN_CLASS_FRACTION = 0.80
STAGE1_EXCLUDED = {"vfdb/610", "cudb/cu18"}

FEATURE_NAMES = [
    "mean_abs", "line_length", "zero_crossings", "zero_crossings_db",
    "threshold_crossings", "local_amp_range", "amp_transition", "local_amp_mean",
]

CANDIDATES = {
    "hp5_o3": dict(order=3, band=5.0, btype="high"),
    "hp3_o3": dict(order=3, band=3.0, btype="high"),
    "hp2_o3": dict(order=3, band=2.0, btype="high"),
    "hp1_o3": dict(order=3, band=1.0, btype="high"),
    "bp01_40_o4": dict(order=4, band=[0.1, 40.0], btype="bandpass"),
    "bp05_40_o4": dict(order=4, band=[0.5, 40.0], btype="bandpass"),
    "bp1_40_o4": dict(order=4, band=[1.0, 40.0], btype="bandpass"),
    "bp2_40_o4": dict(order=4, band=[2.0, 40.0], btype="bandpass"),
    "bp3_40_o4": dict(order=4, band=[3.0, 40.0], btype="bandpass"),
    "bp5_40_o4": dict(order=4, band=[5.0, 40.0], btype="bandpass"),
}


def quantize(x, integer_bits, fraction_bits):
    scale = 2 ** fraction_bits
    return np.clip(np.trunc(x * scale) / scale, -(2 ** integer_bits), 2 ** integer_bits - 1.0 / scale)


def sign_changes(d: np.ndarray, deadband: np.ndarray) -> np.ndarray:
    s = np.sign(d) * (np.abs(d) > deadband[:, None])
    idx = np.where(s != 0, np.arange(s.shape[1])[None, :], 0)
    idx = np.maximum.accumulate(idx, axis=1)
    filled = np.take_along_axis(s, idx, axis=1)
    prev, cur = filled[:, :-1], filled[:, 1:]
    return np.sum((prev != 0) & (cur != 0) & (prev != cur), axis=1).astype(np.float64)


def feature_engine(windows: np.ndarray) -> np.ndarray:
    if windows.shape[0] == 0:
        return np.zeros((0, len(FEATURE_NAMES)))
    m = quantize(windows.sum(axis=1) / WIDTH, 5, 8)
    c = windows - m[:, None]
    a = np.abs(c)
    d = np.diff(c, axis=1)
    ad = np.abs(d)
    mean_abs = a.mean(axis=1)
    line_length = ad.sum(axis=1)
    zc = sign_changes(d, np.zeros(d.shape[0]))
    zc_db = sign_changes(d, 0.05 * ad.mean(axis=1))
    thr = 0.2 * a.max(axis=1)
    above = (a >= thr[:, None]) & (thr[:, None] > 0)
    thr_cross = np.sum(above[:, 1:] != above[:, :-1], axis=1).astype(np.float64)
    blocks = a[:, : (WIDTH // BLOCK) * BLOCK].reshape(a.shape[0], WIDTH // BLOCK, BLOCK).mean(axis=2)
    local_range = np.ptp(blocks, axis=1)
    transition = np.abs(np.diff(blocks, axis=1)).mean(axis=1)
    local_mean = blocks.mean(axis=1)
    return np.column_stack([mean_abs, line_length, zc, zc_db, thr_cross, local_range, transition, local_mean])


def window_matrix(signal: np.ndarray, starts: np.ndarray) -> np.ndarray:
    if starts.size == 0:
        return np.zeros((0, WIDTH))
    return signal[starts[:, None] + np.arange(WIDTH)[None, :]]


def stage1_windows(db, record_id, ann, n_native, source_fs, n120):
    samples = np.asarray(ann.sample)
    symbols = list(ann.symbol)
    subtypes = list(ann.subtype)
    notes = [str(item) for item in ann.aux_note]
    intervals = exp.note_intervals(db, record_id, samples, symbols, notes, n_native)
    if db == "cudb":
        intervals += exp.bracket_intervals(db, record_id, samples, symbols, n_native)
    abnormal = np.zeros(n_native, dtype=bool)
    for interval in intervals:
        abnormal[interval.start:interval.end] = True
    noisy = exp.noisy_interval_mask(samples, symbols, subtypes, n_native)
    pos = np.minimum(np.rint(np.arange(n120) * source_fs / FS).astype(np.int64), n_native - 1)
    abnormal120, noisy120 = abnormal[pos], noisy[pos]

    if n120 < WIDTH:
        return np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int64)
    starts = np.arange(0, n120 - WIDTH + 1, STRIDE, dtype=np.int64)
    ab_prefix = np.concatenate(([0], np.cumsum(abnormal120, dtype=np.int64)))
    no_prefix = np.concatenate(([0], np.cumsum(noisy120, dtype=np.int64)))
    ab_frac = (ab_prefix[starts + WIDTH] - ab_prefix[starts]) / WIDTH
    no_frac = (no_prefix[starts + WIDTH] - no_prefix[starts]) / WIDTH
    keep = no_frac <= 0.01
    label = np.full(starts.size, -1, dtype=np.int64)
    label[ab_frac >= MIN_CLASS_FRACTION] = 1
    label[ab_frac <= 1 - MIN_CLASS_FRACTION] = 0
    keep &= label >= 0
    return starts[keep], label[keep]


def stage2_windows(db, record_id, ann, raw_invalid, source_fs, n120):
    positions = np.minimum((np.arange(n120) * source_fs / FS).astype(np.int64), raw_invalid.size - 1)
    invalid = raw_invalid[positions]
    invalid_prefix = np.concatenate(([0], np.cumsum(invalid, dtype=np.int64)))
    symbols = list(ann.symbol)
    subtypes = list(ann.subtype)
    ann120 = np.rint(np.asarray(ann.sample) * (FS / source_fs)).astype(np.int64)
    noisy = exp.noisy_interval_mask(ann120, symbols, subtypes, n120)
    noisy_prefix = np.concatenate(([0], np.cumsum(noisy, dtype=np.int64)))
    shocks = [s for s, _ in exp.dropout_runs(invalid, int(round(0.2 * FS)))]
    if db == "cudb":
        intervals = exp.bracket_intervals(db, record_id, ann120, symbols, n120)
    else:
        notes = [str(item) for item in ann.aux_note]
        intervals = exp.note_intervals(db, record_id, ann120, symbols, notes, n120)

    starts, labels = [], []
    for interval in intervals:
        if interval.raw_rhythm == exp.RAW_VT:
            label = base.VT_LABEL
        elif interval.raw_rhythm in exp.VF_FAMILY:
            label = base.VF_LABEL
        else:
            continue
        end_limit = min(interval.end, n120)
        if end_limit - interval.start < WIDTH or not interval.closed:
            continue
        episode_shocks = [s for s in shocks if interval.start <= s < end_limit]
        first_shock = min(episode_shocks) if episode_shocks else None
        for start in range(interval.start, end_limit - WIDTH + 1, STRIDE):
            end = start + WIDTH
            if invalid_prefix[end] - invalid_prefix[start] > 0:
                continue
            if noisy_prefix[end] - noisy_prefix[start] > 0:
                continue
            if first_shock is not None and start >= first_shock:
                continue
            starts.append(start)
            labels.append(label)
    return np.asarray(starts, dtype=np.int64), np.asarray(labels, dtype=np.int64)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "results")
    arguments = parser.parse_args()

    import wfdb

    sos = {name: butter(cfg["order"], cfg["band"], btype=cfg["btype"], fs=FS, output="sos")
           for name, cfg in CANDIDATES.items()}
    store = {name: {"s1": [], "s2": []} for name in CANDIDATES}
    meta = {"s1": {"record_id": [], "start": [], "label": []}, "s2": {"record_id": [], "start": [], "label": []}}
    worst_peak = {name: 0.0 for name in CANDIDATES}

    for db in ("mitdb", "vfdb", "cudb"):
        folder = arguments.databases_root / exp.DB_FOLDERS[db]
        for record_path in exp.record_bases(folder):
            record_id = f"{db}/{record_path.name}"
            header = wfdb.rdheader(str(record_path))
            ann = wfdb.rdann(str(record_path), "atr")
            record = wfdb.rdrecord(str(record_path))
            source_fs = float(header.fs)
            raw = np.asarray(record.p_signal[:, 0], dtype=np.float64)
            raw_invalid = ~np.isfinite(raw)
            source = base.interpolate_nonfinite(raw)
            ratio = Fraction(FS / source_fs).limit_denominator(10_000)
            signal = resample_poly(source, ratio.numerator, ratio.denominator)
            signal = quantize(np.asarray(signal, dtype=np.float64), 3, 8)
            n120 = signal.size

            s1_starts, s1_labels = (np.zeros(0, np.int64), np.zeros(0, np.int64))
            if record_id not in STAGE1_EXCLUDED:
                s1_starts, s1_labels = stage1_windows(db, record_id, ann, raw.size, source_fs, n120)
            s2_starts, s2_labels = (np.zeros(0, np.int64), np.zeros(0, np.int64))
            if db in ("vfdb", "cudb"):
                s2_starts, s2_labels = stage2_windows(db, record_id, ann, raw_invalid, source_fs, n120)

            for task, starts, labels in (("s1", s1_starts, s1_labels), ("s2", s2_starts, s2_labels)):
                meta[task]["record_id"].extend([record_id] * starts.size)
                meta[task]["start"].extend(starts.tolist())
                meta[task]["label"].extend(labels.tolist())

            for name in CANDIDATES:
                filtered_raw = sosfilt(sos[name], signal)
                worst_peak[name] = max(worst_peak[name], float(np.max(np.abs(filtered_raw))))
                filtered = quantize(filtered_raw, 5, 8)
                store[name]["s1"].append(feature_engine(window_matrix(filtered, s1_starts)))
                store[name]["s2"].append(feature_engine(window_matrix(filtered, s2_starts)))

            print(f"    {record_id}: stage1={s1_starts.size} (abn={int(s1_labels.sum())}) stage2={s2_starts.size}", flush=True)

    out = arguments.output_dir
    out.mkdir(parents=True, exist_ok=True)
    for name in CANDIDATES:
        np.savez_compressed(
            out / f"shared_{name}.npz",
            feature_names=np.array(FEATURE_NAMES),
            s1_features=np.vstack(store[name]["s1"]).astype(np.float32),
            s1_record_id=np.array(meta["s1"]["record_id"]),
            s1_start=np.array(meta["s1"]["start"], dtype=np.int64),
            s1_label=np.array(meta["s1"]["label"], dtype=np.int64),
            s2_features=np.vstack(store[name]["s2"]).astype(np.float32),
            s2_record_id=np.array(meta["s2"]["record_id"]),
            s2_start=np.array(meta["s2"]["start"], dtype=np.int64),
            s2_label=np.array(meta["s2"]["label"], dtype=np.int64),
            worst_peak=np.float64(worst_peak[name]),
        )
        print(f"Wrote shared_{name}.npz (worst |filtered| peak {worst_peak[name]:.2f}, Q5.8 limit 32)")
    print(f"Stage 1 windows: {len(meta['s1']['label'])}, Stage 2 windows: {len(meta['s2']['label'])}")


if __name__ == "__main__":
    main()
