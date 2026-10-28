"""VT-vs-VF temporal-stability feature engineering experiment.

Standalone, hardware-oriented feature study built on top of the existing
Python VT/VF track (`vt_vf_morphology_pt_05_40_autocorrelation_experiment.py`
and `vt_vf_expanded_cohort_feature_ranking_experiment.py`): same 250 Hz
sampling, same 0.5-40 Hz zero-phase Butterworth filter, same 2.0 s window /
1.0 s stride, same VT vs VF/VFIB/VFL family label policy, same VFDB+CUDB
cohort (CUDB VT never used, per `2026-08-23_exclude_cudb_vt_policy_v1.md`),
same CUDB quality screening (invalid samples, annotated noise, post-shock,
unclosed episodes). No database beat annotations and no manual QRS
annotations are used anywhere in this file.

Motivation (see change records from 2026-09-26/27): manual review of CUDB's
"VF" episodes found genuine heterogeneity -- low-amplitude periodic, fully
disorganized, high-amplitude organized (visually VT-like), and episodes that
change organization within seconds. The features here test a specific
reframing: not "organized VT vs chaotic VF" but "temporally stable vs
temporally unstable ventricular activity", via short-timescale stability of
autocorrelation strength, dominant period, and amplitude envelope, layered on
top of the existing morphology baseline.

Dataset note: no single canonical 48-train/16-test record split with the
window counts sometimes quoted for this project was found anywhere in the
repository (checked the MATLAB `vt_vs_vf_single_channel_six_feature_grouped_
lsvm.mat` six-feature track: 66 records, 5-fold CV, ~53/13 records per fold,
13,595 windows -- a different split shape entirely). This script instead
builds ONE fixed record-grouped train/test split from the VFDB+CUDB cohort
using the same `StratifiedGroupKFold` search already used for nested folds
elsewhere in this project, and prints the resulting real record and window
counts before running anything, rather than assuming a number.

Run:
    python vt_vf_temporal_stability_feature_experiment.py \\
        --databases-root E:/Thesis/databases \\
        --output-dir final_high_power_design/temporal_stability_features_2026_09_27
"""

from __future__ import annotations

import argparse
import json
import time
import warnings
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from scipy.signal import find_peaks
from sklearn.exceptions import ConvergenceWarning
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
    roc_curve,
)
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC, LinearSVC

import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base

# ---------------------------------------------------------------------------
# Confirmed, reused settings (printed again at run time from these constants)
# ---------------------------------------------------------------------------
ANALYSIS_FS = base.ANALYSIS_FS          # 250.0 Hz
WINDOW_SECONDS = base.WINDOW_SECONDS    # 2.0 s
STRIDE_SECONDS = base.STRIDE_SECONDS    # 1.0 s
VT_LABEL = base.VT_LABEL
VF_LABEL = base.VF_LABEL
RANDOM_STATE = base.RANDOM_STATE

SCREEN = ("has_invalid", "in_noisy_interval", "post_shock", "unclosed_episode")

SUB_LEN_S = 0.5
SUB_STRIDE_S = 0.25
SUB_LEN_S_FALLBACK = 1.0
SUB_STRIDE_S_FALLBACK = 0.5
BLOCK_LEN_S = 0.25
LINEAR_C_GRID = (0.01, 0.1, 1.0, 10.0, 100.0)
RBF_GRID = tuple((c, g) for c in (1.0, 10.0) for g in ("scale", 0.1))
HIGH_ORG_PERCENTILES = (80, 90)

NEW_FEATURE_NAMES = [
    "ac_max", "ac_lag_ms",
    "ac_strength_mean", "ac_strength_std", "ac_strength_range",
    "lag_mean_ms", "lag_std_ms", "lag_range_ms", "lag_cv",
    "local_amp_mean", "local_amp_std", "local_amp_range", "amp_transition",
    "spectral_concentration",
]
OLD_FEATURE_NAMES = ["mean_abs_amp", "line_length", "derivative_zero_crossings", "threshold_crossings"]
ALL_FEATURE_NAMES = OLD_FEATURE_NAMES + NEW_FEATURE_NAMES

EXPERIMENTS = {
    "A_morphology_baseline": OLD_FEATURE_NAMES,
    "B_autocorrelation_only": ["ac_max", "ac_lag_ms"],
    "C_stability_only": ["ac_strength_range", "lag_range_ms", "amp_transition"],
    "C2_stability_std_variant": ["ac_strength_std", "lag_std_ms", "amp_transition"],
    "D_autocorr_plus_stability": ["ac_max", "ac_lag_ms", "ac_strength_range", "lag_range_ms", "amp_transition"],
    "E_hardware_friendly_proposed": [
        "ac_max", "ac_lag_ms", "ac_strength_range", "lag_range_ms", "amp_transition",
        "line_length", "derivative_zero_crossings",
    ],
    "F_full_statistical": [
        "ac_max", "ac_lag_ms", "ac_strength_range", "lag_range_ms", "amp_transition",
        "line_length", "derivative_zero_crossings",
        "ac_strength_std", "lag_std_ms", "lag_cv", "local_amp_std", "local_amp_range",
    ],
    "G_plus_spectral": [
        "ac_max", "ac_lag_ms", "ac_strength_range", "lag_range_ms", "amp_transition",
        "line_length", "derivative_zero_crossings", "spectral_concentration",
    ],
}

HARDWARE_COMPLEXITY = {
    "mean_abs_amp": ("VERY LOW", "abs, accumulate, one divide by fixed window length (or shift if power-of-two)."),
    "line_length": ("VERY LOW", "subtract, abs, accumulate."),
    "derivative_zero_crossings": ("VERY LOW", "subtract, sign compare, counter."),
    "threshold_crossings": ("LOW", "running max/abs, one compare against a fraction of that max, counter."),
    "ac_max": ("HIGH", "multiply-accumulate per lag over a lag range, delay-line storage for the window, a normalizing divide (or approximated) per lag, then a max search."),
    "ac_lag_ms": ("LOW once ac_max exists", "the lag is already the index of the max found while computing ac_max; storing it is free."),
    "ac_strength_mean": ("HIGH", "same MAC/delay-line cost as ac_max, repeated per subwindow, plus an accumulator and one divide."),
    "ac_strength_std": ("HIGH", "same as ac_strength_mean plus a second pass (or Welford accumulator) for variance and a square root."),
    "ac_strength_range": ("HIGH (autocorrelation) + VERY LOW (range)", "same MAC/delay-line cost per subwindow as ac_max; the range itself is only a running min/max, no extra multiply."),
    "lag_mean_ms": ("LOW given the per-subwindow lags", "accumulate the already-computed lags, one divide."),
    "lag_std_ms": ("LOW-MODERATE given the lags", "accumulate lags and squared lags (or Welford), one divide, one square root."),
    "lag_range_ms": ("VERY LOW given the lags", "running min/max over the per-subwindow lags already produced by the autocorrelation stage."),
    "lag_cv": ("LOW-MODERATE", "lag_std_ms divided by lag_mean_ms -- needs a divider, which the project has generally avoided in the low-power path."),
    "local_amp_mean": ("VERY LOW", "abs, block accumulator, one divide by block length."),
    "local_amp_std": ("LOW-MODERATE", "accumulate block means and their squares (or Welford), one divide, one square root."),
    "local_amp_range": ("VERY LOW", "running min/max over the per-block means."),
    "amp_transition": ("VERY LOW", "subtract successive block means, abs, accumulate, one divide by block count -- no multiply at all."),
    "spectral_concentration": ("HIGH", "a small Goertzel resonator bank (one multiply-accumulate per bin per sample) plus a divide for the concentration ratio."),
}

# ---------------------------------------------------------------------------
# New feature computation
# ---------------------------------------------------------------------------


def autocorr_max_lag(signal: np.ndarray) -> tuple[float, float]:
    """Reuses the project's existing normalized-autocorrelation search
    unchanged (100-250 bpm equivalent lag range), converting lag to ms."""
    value, lag_seconds = base.normalized_autocorrelation_features(signal)
    return value, lag_seconds * 1000.0


def subwindow_stability(signal: np.ndarray, fs: float) -> dict:
    """Short-timescale autocorrelation-strength and dominant-period
    stability, computed over overlapping subwindows inside the 2 s window."""
    def run(sub_len_s: float, sub_stride_s: float):
        sub_len = int(round(sub_len_s * fs))
        sub_stride = int(round(sub_stride_s * fs))
        if signal.size < sub_len:
            return None
        n_sub = (signal.size - sub_len) // sub_stride + 1
        if n_sub < 3:
            return None
        strengths = np.zeros(n_sub)
        lags_ms = np.zeros(n_sub)
        for i in range(n_sub):
            start = i * sub_stride
            piece = signal[start : start + sub_len]
            value, lag_seconds = base.normalized_autocorrelation_features(piece)
            strengths[i] = value
            lags_ms[i] = lag_seconds * 1000.0
        return strengths, lags_ms

    result = run(SUB_LEN_S, SUB_STRIDE_S)
    used_fallback = False
    if result is None:
        result = run(SUB_LEN_S_FALLBACK, SUB_STRIDE_S_FALLBACK)
        used_fallback = True
    if result is None:
        # Degenerate (should not happen at 250 Hz / 2 s windows); return zeros.
        return {
            "ac_strength_mean": 0.0, "ac_strength_std": 0.0, "ac_strength_range": 0.0,
            "lag_mean_ms": 0.0, "lag_std_ms": 0.0, "lag_range_ms": 0.0, "lag_cv": 0.0,
            "used_fallback_subwindow": True,
        }
    strengths, lags_ms = result
    lag_mean = float(np.mean(lags_ms))
    lag_std = float(np.std(lags_ms))
    return {
        "ac_strength_mean": float(np.mean(strengths)),
        "ac_strength_std": float(np.std(strengths)),
        "ac_strength_range": float(np.ptp(strengths)),
        "lag_mean_ms": lag_mean,
        "lag_std_ms": lag_std,
        "lag_range_ms": float(np.ptp(lags_ms)),
        "lag_cv": (lag_std / lag_mean) if lag_mean > 1e-9 else 0.0,
        "used_fallback_subwindow": used_fallback,
    }


def local_amplitude_stability(signal: np.ndarray, fs: float) -> dict:
    """Block-wise mean-abs-amplitude envelope stability. Hardware-friendly by
    construction: abs, block accumulate, subtract, abs, accumulate -- no
    Hilbert transform, no multiply beyond the fixed 1/block_length divide."""
    block_len = int(round(BLOCK_LEN_S * fs))
    n_blocks = max(1, signal.size // block_len)
    means = np.array([
        float(np.mean(np.abs(signal[k * block_len : (k + 1) * block_len])))
        for k in range(n_blocks)
    ])
    transitions = np.abs(np.diff(means)) if means.size >= 2 else np.array([0.0])
    return {
        "local_amp_mean": float(np.mean(means)),
        "local_amp_std": float(np.std(means)),
        "local_amp_range": float(np.ptp(means)),
        "amp_transition": float(np.mean(transitions)),
    }


def new_feature_row(signal: np.ndarray, fs: float) -> dict:
    centered = signal - np.mean(signal)
    ac_max, ac_lag_ms = autocorr_max_lag(centered)
    stability = subwindow_stability(centered, fs)
    amplitude = local_amplitude_stability(centered, fs)
    spectral = spectral_concentration(centered, fs)
    row = {"ac_max": ac_max, "ac_lag_ms": ac_lag_ms}
    row.update(stability)
    row.update(amplitude)
    row["spectral_concentration"] = spectral
    return row


def spectral_concentration(signal: np.ndarray, fs: float, freqs=(3.0, 5.0, 7.0, 10.0, 15.0)) -> float:
    """Optional spectral-organization feature (experiment G only): peak
    Goertzel-bin power over total power across a small fixed bin set."""
    from scipy.signal import lfilter

    powers = []
    for f in freqs:
        omega = 2.0 * np.pi * f / fs
        coeff = 2.0 * np.cos(omega)
        state = lfilter([1.0], [1.0, -coeff, 1.0], signal)
        s1, s2 = float(state[-1]), float(state[-2]) if state.size >= 2 else 0.0
        powers.append(max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0.0))
    powers = np.array(powers)
    total = float(np.sum(powers))
    return float(np.max(powers) / total) if total > 1e-12 else 0.0


# ---------------------------------------------------------------------------
# Dataset construction (reuses existing extraction machinery)
# ---------------------------------------------------------------------------


def extract_dataset(databases_root: Path) -> tuple[list[dict], np.ndarray]:
    """Builds the VFDB+CUDB VT-vs-VF/VFIB/VFL window set, computing the old
    4 morphology features (via the existing `base.feature_matrix`, reused
    unchanged) and the new temporal-stability features per window."""
    all_rows: list[dict] = []
    all_old_features: list[np.ndarray] = []
    all_new_features: list[list[float]] = []

    for db in ("vfdb", "cudb"):
        folder = databases_root / exp.DB_FOLDERS[db]
        for record_path in exp.record_bases(folder):
            import wfdb
            from fractions import Fraction

            name = record_path.name
            header = wfdb.rdheader(str(record_path))
            annotation = wfdb.rdann(str(record_path), "atr")
            record = wfdb.rdrecord(str(record_path))
            n = int(header.sig_len)
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
            signal -= np.median(signal)
            signal_length = signal.size

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

            filtered = base.filter_05_40(signal, ANALYSIS_FS)
            channel_record = base.ChannelRecord(filtered, np.zeros(0, dtype=np.int64))
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
                    window_signal = filtered[start:end]
                    new_feats = new_feature_row(window_signal - np.mean(window_signal), ANALYSIS_FS)
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


# ---------------------------------------------------------------------------
# Split, model, metrics
# ---------------------------------------------------------------------------


def build_single_split(y: np.ndarray, groups: np.ndarray):
    folds, n_splits, seed = exp.grouped_outer_folds(y, groups)
    test_idx = folds[0][1]
    train_idx = np.setdiff1d(np.arange(y.size), test_idx)
    return train_idx, test_idx, n_splits, seed


def inner_split(y, groups, train_idx, seed_offset=1):
    return exp.base.grouped_inner_split(y, groups, train_idx, seed_offset)


def fit_best_linear(x, y, groups, train_idx):
    inner_train, inner_val = inner_split(y, groups, train_idx)
    best = None
    for c in LINEAR_C_GRID:
        pipe = Pipeline([("scaler", StandardScaler()), ("svm", LinearSVC(
            C=c, class_weight="balanced", random_state=RANDOM_STATE, dual="auto", max_iter=20000))])
        pipe.fit(x[inner_train], y[inner_train])
        score = pipe.decision_function(x[inner_val])
        ba = balanced_accuracy_score(y[inner_val], (score >= 0).astype(int))
        if best is None or ba > best[0]:
            best = (ba, c)
    final = Pipeline([("scaler", StandardScaler()), ("svm", LinearSVC(
        C=best[1], class_weight="balanced", random_state=RANDOM_STATE, dual="auto", max_iter=20000))])
    final.fit(x[train_idx], y[train_idx])
    return final, {"C": best[1]}


def fit_best_rbf(x, y, groups, train_idx):
    inner_train, inner_val = inner_split(y, groups, train_idx)
    best = None
    for c, g in RBF_GRID:
        pipe = Pipeline([("scaler", StandardScaler()), ("svm", SVC(
            C=c, gamma=g, kernel="rbf", class_weight="balanced", random_state=RANDOM_STATE))])
        pipe.fit(x[inner_train], y[inner_train])
        score = pipe.decision_function(x[inner_val])
        ba = balanced_accuracy_score(y[inner_val], (score >= 0).astype(int))
        if best is None or ba > best[0]:
            best = (ba, c, g)
    final = Pipeline([("scaler", StandardScaler()), ("svm", SVC(
        C=best[1], gamma=best[2], kernel="rbf", class_weight="balanced", random_state=RANDOM_STATE))])
    final.fit(x[train_idx], y[train_idx])
    return final, {"C": best[1], "gamma": best[2]}


def compute_metrics(y_true, y_pred, y_score) -> dict:
    cm = confusion_matrix(y_true, y_pred, labels=[VT_LABEL, VF_LABEL])
    tn, fp, fn, tp = cm.ravel()
    try:
        auc = float(roc_auc_score(y_true, y_score))
    except ValueError:
        auc = float("nan")
    return {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "balanced_accuracy": float(balanced_accuracy_score(y_true, y_pred)),
        "vt_sensitivity_recall": float(tn / max(tn + fp, 1)),
        "vf_sensitivity_recall": float(tp / max(tp + fn, 1)),
        "vt_specificity": float(tp / max(tp + fn, 1)),  # specificity for VT = VF recall
        "vf_specificity": float(tn / max(tn + fp, 1)),  # specificity for VF = VT recall
        "precision_vf": float(precision_score(y_true, y_pred, pos_label=VF_LABEL, zero_division=0)),
        "precision_vt": float(precision_score(y_true, y_pred, pos_label=VT_LABEL, zero_division=0)),
        "f1_macro": float(f1_score(y_true, y_pred, average="macro")),
        "roc_auc": auc,
        "tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp),
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=None)
    arguments = parser.parse_args()
    warnings.filterwarnings("ignore", category=ConvergenceWarning)
    started = time.perf_counter()

    output = arguments.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "plots").mkdir()

    print("=" * 78)
    print("CONFIRMED SETTINGS (reused unchanged from the existing project)")
    print("=" * 78)
    print(f"  sample rate:      {ANALYSIS_FS} Hz")
    print(f"  filter:           4th-order Butterworth bandpass 0.5-40 Hz, zero-phase (sosfiltfilt)")
    print(f"  window length:    {WINDOW_SECONDS} s")
    print(f"  stride:           {STRIDE_SECONDS} s")
    print(f"  databases:        VFDB + CUDB (CUDB VT excluded by policy)")
    print(f"  label policy:     VT vs VF/VFIB/VFL family")
    print(f"  quality screen:   {SCREEN}")
    print()

    cache = arguments.cache or (output.parent / "temporal_stability_raw_cache.npz")
    if cache.exists():
        print(f"Loading cached extraction from {cache}")
        payload = np.load(cache, allow_pickle=True)
        rows = list(payload["rows"])
        features = payload["features"]
    else:
        print("Extracting dataset (this re-reads and re-filters every VFDB+CUDB record)...")
        rows, features = extract_dataset(arguments.databases_root)
        np.savez_compressed(cache, rows=np.array(rows, dtype=object), features=features)
        print(f"Cached to {cache}")

    y = np.array([r["label"] for r in rows])
    groups = np.array([r["record_id"] for r in rows])
    dbs = np.array([r["db"] for r in rows])
    n_vt, n_vf = int(np.sum(y == VT_LABEL)), int(np.sum(y == VF_LABEL))
    print(f"\nTotal windows: {y.size}  (VT={n_vt}, VF/VFIB/VFL={n_vf})")
    print(f"Total records: {np.unique(groups).size}  (VT-bearing={np.unique(groups[y==VT_LABEL]).size}, "
          f"VF-bearing={np.unique(groups[y==VF_LABEL]).size})")

    train_idx, test_idx, n_splits, seed = build_single_split(y, groups)
    train_records = np.unique(groups[train_idx])
    test_records = np.unique(groups[test_idx])
    print("\n" + "=" * 78)
    print("SINGLE FIXED RECORD-WISE TRAIN/TEST SPLIT (fold 1 of "
          f"{n_splits}-fold record-grouped search, seed={seed}; not k-fold-averaged)")
    print("=" * 78)
    print(f"  train records: {train_records.size}   test records: {test_records.size}")
    print(f"  train VT windows: {int(np.sum(y[train_idx]==VT_LABEL))}   "
          f"train VF windows: {int(np.sum(y[train_idx]==VF_LABEL))}")
    print(f"  test  VT windows: {int(np.sum(y[test_idx]==VT_LABEL))}   "
          f"test  VF windows: {int(np.sum(y[test_idx]==VF_LABEL))}")
    print("  (these are the real, verified numbers for this cohort -- they do not match any\n"
          "   48-train/16-test figure because no such split exists anywhere in this project;\n"
          "   see the module docstring.)")

    name_to_col = {name: i for i, name in enumerate(ALL_FEATURE_NAMES)}

    # ---- ablation experiments ----
    print("\n" + "=" * 78)
    print("ABLATION EXPERIMENTS")
    print("=" * 78)
    model_rows = []
    fitted_models = {}
    for exp_name, feature_list in EXPERIMENTS.items():
        cols = [name_to_col[f] for f in feature_list]
        x = features[:, cols]
        for kind, fitter in (("linear_svm", fit_best_linear), ("rbf_svm", fit_best_rbf)):
            model, params = fitter(x, y, groups, train_idx)
            score = model.decision_function(x[test_idx])
            pred = (score >= 0).astype(int)
            metrics = compute_metrics(y[test_idx], pred, score)
            row = {"experiment": exp_name, "classifier": kind, "n_features": len(cols),
                   "features": "|".join(feature_list), "params": json.dumps(params), **metrics}
            model_rows.append(row)
            fitted_models[(exp_name, kind)] = (model, cols)
            print(f"  {exp_name:<30} {kind:<10} BalAcc={metrics['balanced_accuracy']:.4f} "
                  f"VT_sens={metrics['vt_sensitivity_recall']:.4f} VF_sens={metrics['vf_sensitivity_recall']:.4f} "
                  f"F1={metrics['f1_macro']:.4f} AUC={metrics['roc_auc']:.4f}")
    base.write_csv(output / "model_metrics.csv", model_rows)

    # ---- per-window feature CSV ----
    feature_csv_rows = []
    train_idx_set = set(train_idx.tolist())
    for i, r in enumerate(rows):
        row = {"record_id": r["record_id"], "db": r["db"], "label": "VT" if r["label"] == VT_LABEL else "VF",
               "raw_rhythm": r["raw_rhythm"], "start": r["start"], "end": r["end"], "split": "train" if i in train_idx_set else "test"}
        for j, name in enumerate(ALL_FEATURE_NAMES):
            row[name] = float(features[i, j])
        feature_csv_rows.append(row)
    base.write_csv(output / "window_features.csv", feature_csv_rows)

    # ---- per-feature distribution stats + individual AUC ----
    print("\n" + "=" * 78)
    print("INDIVIDUAL FEATURE ANALYSIS")
    print("=" * 78)
    feature_stats_rows = []
    for j, name in enumerate(ALL_FEATURE_NAMES):
        col = features[:, j]
        vt_vals, vf_vals = col[y == VT_LABEL], col[y == VF_LABEL]
        try:
            auc_raw = roc_auc_score(y, col)
        except ValueError:
            auc_raw = float("nan")
        auc_oriented = max(auc_raw, 1 - auc_raw)
        feature_stats_rows.append({
            "feature": name,
            "vt_mean": float(np.mean(vt_vals)), "vt_median": float(np.median(vt_vals)), "vt_std": float(np.std(vt_vals)),
            "vt_p25": float(np.percentile(vt_vals, 25)), "vt_p75": float(np.percentile(vt_vals, 75)),
            "vf_mean": float(np.mean(vf_vals)), "vf_median": float(np.median(vf_vals)), "vf_std": float(np.std(vf_vals)),
            "vf_p25": float(np.percentile(vf_vals, 25)), "vf_p75": float(np.percentile(vf_vals, 75)),
            "auc_raw_vf_high": float(auc_raw), "auc_oriented": float(auc_oriented),
        })
    feature_stats_rows.sort(key=lambda r: -r["auc_oriented"])
    base.write_csv(output / "feature_statistics.csv", feature_stats_rows)
    for r in feature_stats_rows:
        print(f"  {r['feature']:<26} AUC(oriented)={r['auc_oriented']:.4f}  "
              f"VT median={r['vt_median']:.4g}  VF median={r['vf_median']:.4g}")

    # ---- correlation matrix ----
    corr = np.corrcoef(features.T)
    corr_rows = [{"feature": ALL_FEATURE_NAMES[i], **{ALL_FEATURE_NAMES[j]: float(corr[i, j]) for j in range(len(ALL_FEATURE_NAMES))}} for i in range(len(ALL_FEATURE_NAMES))]
    base.write_csv(output / "feature_correlation_matrix.csv", corr_rows)

    # ---- ROC curves for the primary comparison ----
    fig, ax = plt.subplots(figsize=(6.5, 6), dpi=140)
    for exp_name in ("A_morphology_baseline", "E_hardware_friendly_proposed", "F_full_statistical"):
        for kind, style in (("linear_svm", "-"), ("rbf_svm", "--")):
            model, cols = fitted_models[(exp_name, kind)]
            score = model.decision_function(features[test_idx][:, cols])
            fpr, tpr, _ = roc_curve(y[test_idx], score)
            auc = roc_auc_score(y[test_idx], score)
            ax.plot(fpr, tpr, style, label=f"{exp_name} / {kind} (AUC={auc:.3f})", linewidth=1.3)
    ax.plot([0, 1], [0, 1], color="#999999", linewidth=0.8, linestyle=":")
    ax.set_xlabel("False positive rate (VT called VF)"); ax.set_ylabel("True positive rate (VF sensitivity)")
    ax.set_title("ROC curves, held-out test records"); ax.legend(fontsize=7.5, loc="lower right")
    fig.tight_layout(); fig.savefig(output / "plots" / "roc_curves.png"); plt.close(fig)

    # ---- confusion matrices for E (hardware-friendly) ----
    for kind in ("linear_svm", "rbf_svm"):
        model, cols = fitted_models[("E_hardware_friendly_proposed", kind)]
        pred = (model.decision_function(features[test_idx][:, cols]) >= 0).astype(int)
        cm = confusion_matrix(y[test_idx], pred, labels=[VT_LABEL, VF_LABEL])
        fig, ax = plt.subplots(figsize=(4, 3.6), dpi=140)
        im = ax.imshow(cm, cmap="Blues")
        for i in range(2):
            for j in range(2):
                ax.text(j, i, str(cm[i, j]), ha="center", va="center", fontsize=13,
                        color="white" if cm[i, j] > cm.max() / 2 else "black")
        ax.set_xticks([0, 1]); ax.set_xticklabels(["VT", "VF"]); ax.set_yticks([0, 1]); ax.set_yticklabels(["VT", "VF"])
        ax.set_xlabel("predicted"); ax.set_ylabel("true")
        ax.set_title(f"E hardware-friendly / {kind}")
        fig.tight_layout(); fig.savefig(output / "plots" / f"confusion_matrix_E_{kind}.png"); plt.close(fig)

    # ---- VT vs VF feature-distribution plots (top features) ----
    top_features = [r["feature"] for r in feature_stats_rows[:6]]
    fig, axes = plt.subplots(2, 3, figsize=(15, 8), dpi=130)
    for axis, name in zip(axes.ravel(), top_features):
        j = name_to_col[name]
        col = features[:, j]
        vt_vals, vf_vals = col[y == VT_LABEL], col[y == VF_LABEL]
        lo, hi = np.percentile(col, [0.5, 99.5])
        bins = np.linspace(lo, hi, 50)
        axis.hist(vt_vals, bins=bins, alpha=0.55, density=True, color="#3b6fa8", label="VT")
        axis.hist(vf_vals, bins=bins, alpha=0.55, density=True, color="#c0463c", label="VF")
        axis.set_title(f"{name}  AUC={next(r['auc_oriented'] for r in feature_stats_rows if r['feature']==name):.3f}", fontsize=10)
        axis.legend(fontsize=8)
    fig.suptitle("VT vs VF distributions, top-ranked new/old features", fontsize=13, fontweight="bold")
    fig.tight_layout(rect=(0, 0, 1, 0.95)); fig.savefig(output / "plots" / "feature_distributions_top6.png"); plt.close(fig)

    # ---- organized-VF analysis ----
    print("\n" + "=" * 78)
    print("ORGANIZED-VF ANALYSIS (top ac_max within VF)")
    print("=" * 78)
    ac_max_col = name_to_col["ac_max"]
    test_mask = np.zeros(y.size, dtype=bool); test_mask[test_idx] = True
    vf_test_mask = test_mask & (y == VF_LABEL)
    vf_ac_values = features[vf_test_mask, ac_max_col]
    org_rows = []
    for pct in HIGH_ORG_PERCENTILES:
        threshold = np.percentile(vf_ac_values, pct)
        high_org_mask = test_mask & (y == VF_LABEL) & (features[:, ac_max_col] >= threshold)
        print(f"\n  top {100-pct}% VF by ac_max (threshold={threshold:.3f}, n={int(high_org_mask.sum())}):")
        for exp_name in ("A_morphology_baseline", "B_autocorrelation_only", "C_stability_only", "E_hardware_friendly_proposed"):
            for kind in ("linear_svm", "rbf_svm"):
                model, cols = fitted_models[(exp_name, kind)]
                pred_all = (model.decision_function(features[:, cols]) >= 0).astype(int)
                overall_vf_sens = float(np.mean(pred_all[vf_test_mask] == VF_LABEL))
                high_org_sens = float(np.mean(pred_all[high_org_mask] == VF_LABEL)) if high_org_mask.any() else float("nan")
                org_rows.append({"percentile": pct, "experiment": exp_name, "classifier": kind,
                                  "threshold": threshold, "n_high_org": int(high_org_mask.sum()),
                                  "overall_vf_sensitivity": overall_vf_sens, "high_org_vf_sensitivity": high_org_sens})
                print(f"    {exp_name:<30} {kind:<10} overall_VF_sens={overall_vf_sens:.4f}  high_org_VF_sens={high_org_sens:.4f}")
    base.write_csv(output / "organized_vf_analysis.csv", org_rows)

    # ---- representative waveform plots ----
    plot_representative_examples(rows, features, y, test_idx, fitted_models, name_to_col, output / "plots")
    plot_nonstationary_examples(rows, features, y, test_mask, name_to_col, output / "plots")

    # ---- final summary table + markdown ----
    write_markdown_summary(output, model_rows, feature_stats_rows, org_rows, n_vt, n_vf,
                            train_records.size, test_records.size,
                            int(np.sum(y[train_idx]==VT_LABEL)), int(np.sum(y[train_idx]==VF_LABEL)),
                            int(np.sum(y[test_idx]==VT_LABEL)), int(np.sum(y[test_idx]==VF_LABEL)))

    print(f"\nElapsed seconds: {time.perf_counter()-started:.1f}")
    print(f"Outputs in {output}")


def plot_representative_examples(rows, features, y, test_idx, fitted_models, name_to_col, plot_dir: Path):
    model, cols = fitted_models[("E_hardware_friendly_proposed", "linear_svm")]
    score = model.decision_function(features[test_idx][:, cols])
    pred = (score >= 0).astype(int)
    y_test = y[test_idx]
    ac_col = name_to_col["ac_max"]
    ac_test = features[test_idx, ac_col]

    def pick(mask, extreme=None):
        idxs = np.flatnonzero(mask)
        if idxs.size == 0:
            return None
        if extreme == "max_ac":
            return test_idx[idxs[np.argmax(ac_test[idxs])]]
        if extreme == "min_ac":
            return test_idx[idxs[np.argmin(ac_test[idxs])]]
        return test_idx[idxs[0]]

    correct = pred == y_test
    picks = {
        "correctly_classified_VT": pick(correct & (y_test == VT_LABEL)),
        "correctly_classified_disorganized_VF": pick(correct & (y_test == VF_LABEL), "min_ac"),
        "correctly_classified_organized_VF": pick(correct & (y_test == VF_LABEL), "max_ac"),
        "organized_VF_misclassified_as_VT": pick((~correct) & (y_test == VF_LABEL), "max_ac"),
        "VT_misclassified_as_VF": pick((~correct) & (y_test == VT_LABEL)),
    }

    from vt_vf_line_length_confound_example_plot import read_filtered_signal

    fig, axes = plt.subplots(len(picks), 1, figsize=(9, 2.3 * len(picks)), dpi=140)
    for axis, (label, idx) in zip(axes, picks.items()):
        if idx is None:
            axis.set_title(f"{label}: none found"); axis.axis("off"); continue
        r = rows[idx]
        filtered = read_filtered_signal(Path("E:/Thesis/databases"), r["record_id"])
        segment = filtered[r["start"]:r["end"]]
        segment = segment - np.mean(segment)
        t = np.arange(segment.size) / ANALYSIS_FS
        axis.plot(t, segment, color="#8b2e2e" if "VF" in label and "VT" not in label.split("_")[0] else "#3b6fa8", linewidth=0.8)
        axis.set_title(f"{label}: {r['record_id']} [{r['start']}:{r['end']}]  "
                        f"ac_max={features[idx, name_to_col['ac_max']]:.3f}  "
                        f"ac_strength_range={features[idx, name_to_col['ac_strength_range']]:.3f}  "
                        f"amp_transition={features[idx, name_to_col['amp_transition']]:.4f}", fontsize=8.5)
    fig.tight_layout(); fig.savefig(plot_dir / "representative_examples.png"); plt.close(fig)


def plot_nonstationary_examples(rows, features, y, test_mask, name_to_col, plot_dir: Path):
    from vt_vf_line_length_confound_example_plot import read_filtered_signal

    vf_mask = test_mask & (y == VF_LABEL)
    picks = {}
    for feat in ("ac_strength_range", "lag_range_ms", "amp_transition"):
        col = name_to_col[feat]
        idxs = np.flatnonzero(vf_mask)
        top_idx = idxs[np.argmax(features[idxs, col])]
        picks[f"highest_{feat}"] = top_idx

    fig, axes = plt.subplots(len(picks), 1, figsize=(9, 2.3 * len(picks)), dpi=140)
    for axis, (label, idx) in zip(axes, picks.items()):
        r = rows[idx]
        filtered = read_filtered_signal(Path("E:/Thesis/databases"), r["record_id"])
        segment = filtered[r["start"]:r["end"]]
        segment = segment - np.mean(segment)
        t = np.arange(segment.size) / ANALYSIS_FS
        axis.plot(t, segment, color="#8b2e2e", linewidth=0.8)
        axis.set_title(f"{label}: {r['record_id']} [{r['start']}:{r['end']}]  "
                        f"ac_strength_range={features[idx, name_to_col['ac_strength_range']]:.3f}  "
                        f"lag_range_ms={features[idx, name_to_col['lag_range_ms']]:.1f}  "
                        f"amp_transition={features[idx, name_to_col['amp_transition']]:.4f}", fontsize=8.5)
    fig.tight_layout(); fig.savefig(plot_dir / "nonstationary_vf_examples.png"); plt.close(fig)


def write_markdown_summary(output, model_rows, feature_stats_rows, org_rows, n_vt, n_vf,
                            n_train_rec, n_test_rec, train_vt, train_vf, test_vt, test_vf):
    def get(exp_name, kind, key):
        return next(r[key] for r in model_rows if r["experiment"] == exp_name and r["classifier"] == kind)

    lines = []
    lines.append("# VT-vs-VF Temporal Stability Feature Experiment\n")
    lines.append("## Dataset (verified, not assumed)\n")
    lines.append(f"- Total windows: {n_vt+n_vf} (VT={n_vt}, VF/VFIB/VFL={n_vf})\n")
    lines.append(f"- Train records: {n_train_rec}, Test records: {n_test_rec}\n")
    lines.append(f"- Train VT={train_vt}, VF={train_vf}; Test VT={test_vt}, VF={test_vf}\n")
    lines.append("- These do not match any 48-train/16-test figure quoted informally; no such split "
                 "exists in the repository (checked). Preprocessing (250 Hz, 0.5-40 Hz, 2 s/1 s) is unchanged.\n")

    lines.append("\n## Final summary table (Linear SVM, primary comparison)\n\n")
    lines.append("| Feature set | BalAcc | VT Sens | VF Sens | F1 | AUC |\n|---|---:|---:|---:|---:|---:|\n")
    for exp_name in EXPERIMENTS:
        lines.append(f"| {exp_name} | {get(exp_name,'linear_svm','balanced_accuracy'):.4f} | "
                      f"{get(exp_name,'linear_svm','vt_sensitivity_recall'):.4f} | "
                      f"{get(exp_name,'linear_svm','vf_sensitivity_recall'):.4f} | "
                      f"{get(exp_name,'linear_svm','f1_macro'):.4f} | {get(exp_name,'linear_svm','roc_auc'):.4f} |\n")

    lines.append("\n## Same table, RBF SVM\n\n")
    lines.append("| Feature set | BalAcc | VT Sens | VF Sens | F1 | AUC |\n|---|---:|---:|---:|---:|---:|\n")
    for exp_name in EXPERIMENTS:
        lines.append(f"| {exp_name} | {get(exp_name,'rbf_svm','balanced_accuracy'):.4f} | "
                      f"{get(exp_name,'rbf_svm','vt_sensitivity_recall'):.4f} | "
                      f"{get(exp_name,'rbf_svm','vf_sensitivity_recall'):.4f} | "
                      f"{get(exp_name,'rbf_svm','f1_macro'):.4f} | {get(exp_name,'rbf_svm','roc_auc'):.4f} |\n")

    lines.append("\n## Individual feature ranking (oriented AUC)\n\n")
    lines.append("| Feature | AUC | VT median | VF median |\n|---|---:|---:|---:|\n")
    for r in feature_stats_rows:
        lines.append(f"| {r['feature']} | {r['auc_oriented']:.4f} | {r['vt_median']:.4g} | {r['vf_median']:.4g} |\n")

    lines.append("\n## Hardware complexity, per feature\n\n")
    lines.append("| Feature | Complexity | Operations |\n|---|---|---|\n")
    for name in ALL_FEATURE_NAMES:
        level, ops = HARDWARE_COMPLEXITY[name]
        lines.append(f"| {name} | {level} | {ops} |\n")

    (output / "SUMMARY.md").write_text("".join(lines), encoding="ascii", errors="replace")
    print(f"\nWrote {output/'SUMMARY.md'}")


if __name__ == "__main__":
    main()
