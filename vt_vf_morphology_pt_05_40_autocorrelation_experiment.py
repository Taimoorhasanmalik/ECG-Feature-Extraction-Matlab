"""Strict VFDB VT-vs-VF morphology/PT/RR/autocorrelation experiment.

This standalone experiment uses only direct waveform morphology, detections
from a Pan-Tompkins-like detector driven by the continuously filtered
0.5-40 Hz ECG, RR timing derived from those detections, and normalized
autocorrelation of each 2-second window. Database beat labels are never used.
"""

from __future__ import annotations

import argparse
import csv
import math
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Sequence

import numpy as np
from scipy.signal import butter, find_peaks, resample_poly, sosfiltfilt
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
    roc_auc_score,
)
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import LinearSVC

try:
    import wfdb
except ImportError as exc:
    raise SystemExit("Install the Python 'wfdb' package before running this experiment.") from exc


ANALYSIS_FS = 250.0
WINDOW_SECONDS = 2.0
STRIDE_SECONDS = 1.0
RANDOM_STATE = 42
N_OUTER_FOLDS = 5
ARTIFACT_PAD_SECONDS = 1.5
EPS = np.finfo(np.float64).eps
C_VALUES = (0.01, 0.1, 1.0, 10.0, 100.0)

VT_LABEL = 0
VF_LABEL = 1
VT_RHYTHMS = {"(VT", "VT"}
VF_RHYTHMS = {"(VF", "VF", "(VFIB", "VFIB"}
EXCLUDED_RHYTHMS = {"(VFL", "VFL"}

FEATURE_NAMES = [
    "mean_abs_amp",
    "line_length",
    "derivative_zero_crossings",
    "threshold_crossings",
    "n_pt_detections",
    "mean_pt_rr",
    "pt_rr_range",
    "pt_rr_std",
    "estimated_pt_rate",
    "pt_rr_available",
    "has_pt_detection",
    "has_three_pt_detections",
    "autocorrelation_max",
    "autocorrelation_peak_lag_seconds",
]

MODEL_NAME = "MORPHOLOGY_PT_05_40_RR_AUTOCORR"
OUTPUT_PREFIX = "vt_vf_morphology_pt_05_40_autocorrelation"


@dataclass(frozen=True)
class RhythmInterval:
    record_id: str
    episode_id: str
    start: int
    end: int
    label: int
    raw_label: str


@dataclass(frozen=True)
class Window:
    record_id: str
    episode_id: str
    start: int
    end: int
    label: int
    raw_label: str


@dataclass
class ChannelRecord:
    filtered_signal: np.ndarray
    pt_samples: np.ndarray


def clean_aux(note: str) -> str:
    return str(note).replace("\x00", "").strip().upper()


def target_label(note: str) -> int | None:
    value = clean_aux(note)
    if value in VT_RHYTHMS:
        return VT_LABEL
    if value in VF_RHYTHMS:
        return VF_LABEL
    return None


def is_rhythm_note(note: str) -> bool:
    value = clean_aux(note)
    return value.startswith("(") or value in {"VT", "VF", "VFIB", "VFL"}


def locate_vfdb(script_path: Path, requested: Path | None) -> Path:
    if requested is not None:
        folder = requested.resolve()
        if not folder.is_dir():
            raise FileNotFoundError(folder)
        return folder
    folder_name = "mit-bih-malignant-ventricular-ectopy-database-1.0.0"
    candidates = [
        script_path.parent / "databases" / folder_name,
        script_path.parent.parent / "databases" / folder_name,
    ]
    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()
    raise FileNotFoundError("Could not locate the local VFDB folder")


def record_bases(folder: Path) -> list[Path]:
    records_file = folder / "RECORDS"
    if records_file.exists():
        names = [line.strip() for line in records_file.read_text().splitlines() if line.strip()]
        return [folder / name for name in names]
    return [path.with_suffix("") for path in sorted(folder.glob("*.hea"))]


def interpolate_nonfinite(signal: np.ndarray) -> np.ndarray:
    signal = np.asarray(signal, dtype=np.float64)
    finite = np.isfinite(signal)
    if finite.all():
        return signal
    if not finite.any():
        raise ValueError("Signal contains no finite samples")
    result = signal.copy()
    indices = np.arange(signal.size)
    result[~finite] = np.interp(indices[~finite], indices[finite], signal[finite])
    return result


def filter_05_40(signal: np.ndarray, fs: float) -> np.ndarray:
    """Apply the shared continuous-record 0.5-40 Hz morphology/PT filter."""
    sos = butter(4, [0.5, 40.0], btype="bandpass", fs=fs, output="sos")
    return sosfiltfilt(sos, signal)


def pan_tompkins_from_05_40(filtered_signal: np.ndarray, fs: float) -> np.ndarray:
    """Detect QRS-like events from an already filtered 0.5-40 Hz record.

    This retains the derivative, squaring, moving-window integration, adaptive
    threshold, refractory spacing, and local-extremum refinement stages of the
    existing annotation-free detector. It intentionally does not apply the
    former internal 5-35 Hz filter.
    """
    derivative = np.diff(filtered_signal, prepend=filtered_signal[0])
    energy = derivative * derivative
    width = max(1, int(round(0.120 * fs)))
    integrated = np.convolve(energy, np.ones(width) / width, mode="same")
    median = float(np.median(integrated))
    mad = float(np.median(np.abs(integrated - median)))
    threshold = median + 2.0 * max(mad, EPS)
    candidates, _ = find_peaks(
        integrated,
        height=threshold,
        prominence=max(mad, EPS),
        distance=max(1, int(round(0.200 * fs))),
    )
    radius = max(1, int(round(0.080 * fs)))
    refined: list[int] = []
    for candidate in candidates:
        left = max(0, int(candidate) - radius)
        right = min(filtered_signal.size, int(candidate) + radius + 1)
        refined.append(left + int(np.argmax(np.abs(filtered_signal[left:right]))))
    return np.unique(np.asarray(refined, dtype=np.int64))


def robust_scale(values: np.ndarray) -> float:
    values = values[np.isfinite(values)]
    if values.size == 0:
        return 0.0
    center = float(np.median(values))
    scale = 1.4826 * float(np.median(np.abs(values - center)))
    if not np.isfinite(scale) or scale <= EPS:
        scale = float(np.std(values))
    return scale if np.isfinite(scale) else 0.0


def dilate_sparse_mask(mask: np.ndarray, radius: int) -> np.ndarray:
    if radius <= 0 or not mask.any():
        return mask
    changes = np.zeros(mask.size + 1, dtype=np.int32)
    for sample in np.flatnonzero(mask):
        left = max(0, int(sample) - radius)
        right = min(mask.size, int(sample) + radius + 1)
        changes[left] += 1
        changes[right] -= 1
    return np.cumsum(changes[:-1]) > 0


def signal_artifact_mask(signal: np.ndarray, fs: float) -> np.ndarray:
    finite = signal[np.isfinite(signal)]
    mask = ~np.isfinite(signal)
    if finite.size < 3:
        return mask
    center = float(np.median(finite))
    scale = robust_scale(finite)
    if scale <= 0:
        return mask
    centered = signal - center
    magnitude = np.abs(centered)
    upper = float(np.percentile(magnitude[np.isfinite(magnitude)], 99.9))
    typical = float(np.percentile(magnitude[np.isfinite(magnitude)], 75.0))
    amplitude_limit = max(upper, 18.0 * scale, 12.0 * typical)
    mask |= magnitude > amplitude_limit
    difference = np.diff(centered, prepend=centered[0])
    difference_scale = robust_scale(difference)
    if difference_scale > 0:
        difference_limit = max(
            float(np.percentile(np.abs(difference), 99.95)), 35.0 * difference_scale
        )
        mask |= (np.abs(difference) > difference_limit) & (magnitude > 6.0 * typical)
    return dilate_sparse_mask(mask, int(round(ARTIFACT_PAD_SECONDS * fs)))


def rhythm_intervals(
    record_id: str,
    samples: np.ndarray,
    symbols: Sequence[str],
    notes: Sequence[str],
    signal_length: int,
) -> list[RhythmInterval]:
    points = [
        (int(sample), str(note))
        for sample, symbol, note in zip(samples, symbols, notes)
        if symbol == "+" and is_rhythm_note(note)
    ]
    result: list[RhythmInterval] = []
    for index, (start, note) in enumerate(points):
        end = points[index + 1][0] if index + 1 < len(points) else signal_length
        label = target_label(note)
        if label is None or clean_aux(note) in EXCLUDED_RHYTHMS or end <= start:
            continue
        episode_id = f"{record_id}:{start}:{end}:{clean_aux(note)}"
        result.append(RhythmInterval(record_id, episode_id, start, end, label, note))
    return result


def load_vfdb(
    folder: Path,
) -> tuple[list[Window], dict[int, dict[str, ChannelRecord]], list[RhythmInterval], dict[str, int]]:
    records: dict[int, dict[str, ChannelRecord]] = {0: {}, 1: {}}
    windows: list[Window] = []
    episodes: list[RhythmInterval] = []
    audit = Counter()
    width = int(round(WINDOW_SECONDS * ANALYSIS_FS))
    stride = int(round(STRIDE_SECONDS * ANALYSIS_FS))

    for base_path in record_bases(folder):
        header = wfdb.rdheader(str(base_path))
        annotation = wfdb.rdann(str(base_path), "atr")
        wfdb_record = wfdb.rdrecord(str(base_path))
        if int(header.n_sig) < 2:
            raise RuntimeError(f"VFDB/{base_path.name} has fewer than two channels")
        record_id = f"vfdb/{base_path.name}"
        source_fs = float(header.fs)
        ratio = Fraction(ANALYSIS_FS / source_fs).limit_denominator(10_000)
        scale = ANALYSIS_FS / source_fs
        ann_samples = np.rint(np.asarray(annotation.sample) * scale).astype(np.int64)
        notes = [str(item) for item in annotation.aux_note]
        symbols = list(annotation.symbol)

        channel_artifacts: list[np.ndarray] = []
        signal_length = 0
        for channel in (0, 1):
            source = interpolate_nonfinite(np.asarray(wfdb_record.p_signal[:, channel]))
            signal = (
                resample_poly(source, ratio.numerator, ratio.denominator)
                if not math.isclose(source_fs, ANALYSIS_FS)
                else source.copy()
            )
            signal = np.asarray(signal, dtype=np.float64)
            signal -= np.median(signal)
            signal_length = signal.size
            filtered = filter_05_40(signal, ANALYSIS_FS)
            pt_samples = pan_tompkins_from_05_40(filtered, ANALYSIS_FS)
            records[channel][record_id] = ChannelRecord(filtered, pt_samples)
            channel_artifacts.append(signal_artifact_mask(signal, ANALYSIS_FS))

        intervals = rhythm_intervals(record_id, ann_samples, symbols, notes, signal_length)
        episodes.extend(intervals)
        annotation_artifact = np.zeros(signal_length, dtype=bool)
        pad = int(round(ARTIFACT_PAD_SECONDS * ANALYSIS_FS))
        for sample, symbol in zip(ann_samples, symbols):
            if symbol in {"~", "|"}:
                annotation_artifact[
                    max(0, sample - pad) : min(signal_length, sample + pad + 1)
                ] = True
        combined_artifact = annotation_artifact | channel_artifacts[0] | channel_artifacts[1]
        artifact_prefix = np.concatenate(([0], np.cumsum(combined_artifact, dtype=np.int64)))

        for interval in intervals:
            audit[f"episodes_{'VT' if interval.label == VT_LABEL else 'VF'}"] += 1
            if interval.end - interval.start < width:
                continue
            for start in range(interval.start, interval.end - width + 1, stride):
                end = start + width
                if artifact_prefix[end] - artifact_prefix[start] > 0:
                    audit["artifact_rejected_windows"] += 1
                    continue
                windows.append(
                    Window(record_id, interval.episode_id, start, end, interval.label, interval.raw_label)
                )
                audit[f"windows_{'VT' if interval.label == VT_LABEL else 'VF'}"] += 1
        audit["records_read"] += 1

    active_episode_ids = {window.episode_id for window in windows}
    episodes = [episode for episode in episodes if episode.episode_id in active_episode_ids]
    return windows, records, episodes, dict(audit)


def derivative_zero_crossings(derivative: np.ndarray) -> int:
    if derivative.size < 2:
        return 0
    deadband = 0.05 * float(np.mean(np.abs(derivative)))
    retained = derivative[np.abs(derivative) > deadband]
    if retained.size < 2:
        return 0
    return int(np.sum(np.signbit(retained[:-1]) != np.signbit(retained[1:])))


def normalized_autocorrelation_features(signal: np.ndarray) -> tuple[float, float]:
    """Return strongest normalized correlation and its lag over 100-250 bpm."""
    centered = signal - np.mean(signal)
    minimum_lag = int(math.ceil(60.0 * ANALYSIS_FS / 250.0))
    maximum_lag = min(centered.size - 2, int(math.floor(60.0 * ANALYSIS_FS / 100.0)))
    best_value = -1.0
    best_lag = 0
    for lag in range(minimum_lag, maximum_lag + 1):
        left = centered[:-lag]
        right = centered[lag:]
        denominator = math.sqrt(float(np.dot(left, left) * np.dot(right, right)))
        value = float(np.dot(left, right) / denominator) if denominator > EPS else 0.0
        if value > best_value:
            best_value = value
            best_lag = lag
    return max(best_value, 0.0), best_lag / ANALYSIS_FS if best_lag else 0.0


def feature_matrix(windows: Sequence[Window], records: dict[str, ChannelRecord]) -> np.ndarray:
    rows: list[list[float]] = []
    for window in windows:
        record = records[window.record_id]
        signal = record.filtered_signal[window.start : window.end]
        centered = signal - np.mean(signal)
        derivative = np.diff(centered)
        threshold = 0.20 * float(np.max(np.abs(centered)))
        above = np.abs(centered) >= threshold if threshold > 0 else np.zeros(centered.size, bool)

        detections = record.pt_samples
        inside = detections[(detections >= window.start) & (detections < window.end)] - window.start
        rr = np.diff(inside) / ANALYSIS_FS if inside.size >= 2 else np.empty(0)
        mean_rr = float(np.mean(rr)) if rr.size else 0.0
        autocorrelation_max, autocorrelation_lag = normalized_autocorrelation_features(centered)
        rows.append(
            [
                float(np.mean(np.abs(centered))),
                float(np.sum(np.abs(derivative))),
                float(derivative_zero_crossings(derivative)),
                float(np.sum(above[:-1] != above[1:])),
                float(inside.size),
                mean_rr,
                float(np.ptp(rr)) if rr.size else 0.0,
                float(np.std(rr)) if rr.size else 0.0,
                60.0 / mean_rr if mean_rr > 0 else 0.0,
                float(rr.size > 0),
                float(inside.size > 0),
                float(inside.size >= 3),
                autocorrelation_max,
                autocorrelation_lag,
            ]
        )
    matrix = np.asarray(rows, dtype=np.float64)
    if matrix.shape[1] != len(FEATURE_NAMES) or not np.isfinite(matrix).all():
        raise AssertionError("Invalid feature matrix")
    return matrix


def class_complete(y: np.ndarray, indices: np.ndarray) -> bool:
    return set(np.unique(y[indices]).tolist()) == {VT_LABEL, VF_LABEL}


def grouped_outer_folds(
    y: np.ndarray, groups: np.ndarray
) -> tuple[list[tuple[np.ndarray, np.ndarray]], int, int]:
    best: tuple[float, int, list[tuple[np.ndarray, np.ndarray]]] | None = None
    overall_fraction = float(np.mean(y))
    selected_splits = N_OUTER_FOLDS
    for n_splits in range(N_OUTER_FOLDS, 1, -1):
        best = None
        for offset in range(1024):
            seed = RANDOM_STATE + offset
            splitter = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=seed)
            folds = list(splitter.split(np.zeros(y.size), y, groups))
            if any(not class_complete(y, train) or not class_complete(y, test) for train, test in folds):
                continue
            score = sum(
                abs(test.size / y.size - 1.0 / n_splits)
                + abs(float(np.mean(y[test])) - overall_fraction)
                for _, test in folds
            )
            if best is None or score < best[0]:
                best = (score, seed, folds)
        if best is not None:
            selected_splits = n_splits
            break
    if best is None:
        raise RuntimeError("No deterministic class-complete record-grouped outer folds")
    _, seed, folds = best
    tested = [record for _, test in folds for record in set(groups[test].tolist())]
    if Counter(tested) != Counter(set(groups.tolist())):
        raise AssertionError("Every record must occur in exactly one outer test fold")
    return folds, seed, selected_splits


def grouped_inner_split(
    y: np.ndarray, groups: np.ndarray, outer_train: np.ndarray, outer_fold: int
) -> tuple[np.ndarray, np.ndarray]:
    local_y = y[outer_train]
    local_groups = groups[outer_train]
    requested = min(4, len(set(local_groups.tolist())))
    for offset in range(64):
        splitter = StratifiedGroupKFold(
            n_splits=requested,
            shuffle=True,
            random_state=RANDOM_STATE + 100 * outer_fold + offset,
        )
        candidates = list(splitter.split(np.zeros(local_y.size), local_y, local_groups))
        candidates.sort(key=lambda pair: abs(float(np.mean(local_y[pair[1]])) - float(np.mean(local_y))))
        for train_local, validation_local in candidates:
            train = outer_train[train_local]
            validation = outer_train[validation_local]
            if class_complete(y, train) and class_complete(y, validation):
                if set(groups[train]).isdisjoint(set(groups[validation])):
                    return train, validation
    raise RuntimeError(f"No class-complete grouped inner split for outer fold {outer_fold}")


def metric_bundle(y: np.ndarray, prediction: np.ndarray, score: np.ndarray) -> dict[str, object]:
    cm = confusion_matrix(y, prediction, labels=[VT_LABEL, VF_LABEL])
    try:
        auc = float(roc_auc_score(y, score))
    except ValueError:
        auc = float("nan")
    return {
        "accuracy": float(accuracy_score(y, prediction)),
        "balanced_accuracy": float(balanced_accuracy_score(y, prediction)),
        "vt_sensitivity": float(cm[0, 0] / max(cm[0].sum(), 1)),
        "vf_sensitivity": float(cm[1, 1] / max(cm[1].sum(), 1)),
        "macro_f1": float(f1_score(y, prediction, average="macro", zero_division=0)),
        "roc_auc": auc,
        "tn_vt": int(cm[0, 0]),
        "fp_vt_as_vf": int(cm[0, 1]),
        "fn_vf_as_vt": int(cm[1, 0]),
        "tp_vf": int(cm[1, 1]),
    }


def make_model(c_value: float) -> Pipeline:
    return Pipeline(
        [
            ("scaler", StandardScaler()),
            (
                "svm",
                LinearSVC(
                    C=c_value,
                    class_weight="balanced",
                    random_state=RANDOM_STATE,
                    dual="auto",
                    max_iter=20_000,
                ),
            ),
        ]
    )


def tune_c(
    x: np.ndarray, y: np.ndarray, train: np.ndarray, validation: np.ndarray
) -> tuple[float, float]:
    best: tuple[float, float, float] | None = None
    selected_c = C_VALUES[0]
    for c_value in C_VALUES:
        model = make_model(c_value)
        model.fit(x[train], y[train])
        score = model.decision_function(x[validation])
        metrics = metric_bundle(y[validation], (score >= 0).astype(np.int64), score)
        key = (float(metrics["balanced_accuracy"]), float(metrics["macro_f1"]), -c_value)
        if best is None or key > best:
            best = key
            selected_c = c_value
    assert best is not None
    return float(selected_c), best[0]


def aggregate_episode_scores(
    scores: np.ndarray, labels: np.ndarray, episode_ids: np.ndarray
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    grouped: dict[str, list[int]] = defaultdict(list)
    for index, episode_id in enumerate(episode_ids.tolist()):
        grouped[str(episode_id)].append(index)
    output_scores: list[float] = []
    output_labels: list[int] = []
    output_ids: list[str] = []
    for episode_id in sorted(grouped):
        indices = np.asarray(grouped[episode_id], dtype=np.int64)
        unique_labels = np.unique(labels[indices])
        if unique_labels.size != 1:
            raise AssertionError("Episode contains multiple class labels")
        output_scores.append(float(np.mean(scores[indices])))
        output_labels.append(int(unique_labels[0]))
        output_ids.append(episode_id)
    return np.asarray(output_scores), np.asarray(output_labels), np.asarray(output_ids, dtype=object)


def select_episode_threshold(scores: np.ndarray, labels: np.ndarray) -> float:
    unique = np.unique(scores)
    if unique.size == 1:
        return float(unique[0])
    candidates = np.concatenate(
        ([unique[0] - EPS], (unique[:-1] + unique[1:]) / 2.0, [unique[-1] + EPS])
    )
    best: tuple[float, float, float] | None = None
    selected = 0.0
    for threshold in candidates:
        prediction = (scores >= threshold).astype(np.int64)
        metrics = metric_bundle(labels, prediction, scores)
        key = (
            float(metrics["balanced_accuracy"]),
            float(metrics["macro_f1"]),
            -abs(float(threshold)),
        )
        if best is None or key > best:
            best = key
            selected = float(threshold)
    return selected


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        raise ValueError(f"No rows for {path}")
    with path.open("x", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vfdb", type=Path, default=None, help="Optional local VFDB folder")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    started = time.perf_counter()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    vfdb = locate_vfdb(Path(__file__).resolve(), args.vfdb)

    print(f"VFDB: {vfdb}")
    print("Loading strict VT vs VF/VFIB windows; VFL is excluded...")
    windows, records_by_channel, episodes, audit = load_vfdb(vfdb)
    y = np.asarray([window.label for window in windows], dtype=np.int64)
    groups = np.asarray([window.record_id for window in windows], dtype=object)
    episode_ids = np.asarray([window.episode_id for window in windows], dtype=object)
    folds, fold_seed, n_folds = grouped_outer_folds(y, groups)

    print(f"Records read: {audit.get('records_read', 0)}")
    print(f"Active records: {len(set(groups.tolist()))}")
    print(f"Windows: {y.size} (VT={int(np.sum(y == VT_LABEL))}, VF={int(np.sum(y == VF_LABEL))})")
    print(f"Episodes: VT={sum(e.label == VT_LABEL for e in episodes)}, VF={sum(e.label == VF_LABEL for e in episodes)}")
    print(f"Outer folds: {n_folds}, deterministic seed={fold_seed}")
    print("Features:", ", ".join(FEATURE_NAMES))

    result_rows: list[dict[str, object]] = []
    fold_rows: list[dict[str, object]] = []
    episode_result_rows: list[dict[str, object]] = []
    distribution_rows: list[dict[str, object]] = []

    for channel in (0, 1):
        print(f"\nCH{channel}: extracting features...")
        x = feature_matrix(windows, records_by_channel[channel])
        all_test_scores = np.full(y.size, np.nan)
        all_test_predictions = np.full(y.size, -1, dtype=np.int64)
        episode_score_parts: list[np.ndarray] = []
        episode_label_parts: list[np.ndarray] = []

        for label, class_name in ((VT_LABEL, "VT"), (VF_LABEL, "VF")):
            mask = y == label
            for column, feature_name in enumerate(FEATURE_NAMES):
                values = x[mask, column]
                distribution_rows.append(
                    {
                        "channel": channel,
                        "class": class_name,
                        "feature": feature_name,
                        "n_windows": values.size,
                        "median": float(np.median(values)),
                        "q1": float(np.percentile(values, 25)),
                        "q3": float(np.percentile(values, 75)),
                        "iqr": float(np.percentile(values, 75) - np.percentile(values, 25)),
                    }
                )

        for fold_number, (outer_train, outer_test) in enumerate(folds, start=1):
            inner_train, inner_validation = grouped_inner_split(y, groups, outer_train, fold_number)
            selected_c, inner_ba = tune_c(x, y, inner_train, inner_validation)

            inner_model = make_model(selected_c)
            inner_model.fit(x[inner_train], y[inner_train])
            inner_scores = inner_model.decision_function(x[inner_validation])
            validation_episode_scores, validation_episode_labels, _ = aggregate_episode_scores(
                inner_scores, y[inner_validation], episode_ids[inner_validation]
            )
            episode_threshold = select_episode_threshold(
                validation_episode_scores, validation_episode_labels
            )

            model = make_model(selected_c)
            model.fit(x[outer_train], y[outer_train])
            test_scores = model.decision_function(x[outer_test])
            test_predictions = (test_scores >= 0).astype(np.int64)
            all_test_scores[outer_test] = test_scores
            all_test_predictions[outer_test] = test_predictions
            fold_metrics = metric_bundle(y[outer_test], test_predictions, test_scores)

            test_episode_scores, test_episode_labels, _ = aggregate_episode_scores(
                test_scores, y[outer_test], episode_ids[outer_test]
            )
            test_episode_predictions = (test_episode_scores >= episode_threshold).astype(np.int64)
            episode_score_parts.append(test_episode_scores - episode_threshold)
            episode_label_parts.append(test_episode_labels)

            fold_rows.append(
                {
                    "channel": channel,
                    "fold": fold_number,
                    "model": MODEL_NAME,
                    "selected_c": selected_c,
                    "inner_validation_balanced_accuracy": inner_ba,
                    "episode_threshold": episode_threshold,
                    "train_records": "|".join(sorted(set(groups[outer_train].tolist()))),
                    "test_records": "|".join(sorted(set(groups[outer_test].tolist()))),
                    "n_train_windows": outer_train.size,
                    "n_test_windows": outer_test.size,
                    "test_vt_windows": int(np.sum(y[outer_test] == VT_LABEL)),
                    "test_vf_windows": int(np.sum(y[outer_test] == VF_LABEL)),
                    "balanced_accuracy": fold_metrics["balanced_accuracy"],
                    "vt_sensitivity": fold_metrics["vt_sensitivity"],
                    "vf_sensitivity": fold_metrics["vf_sensitivity"],
                    "roc_auc": fold_metrics["roc_auc"],
                    "episode_balanced_accuracy": balanced_accuracy_score(
                        test_episode_labels, test_episode_predictions
                    ),
                }
            )
            print(
                f"  fold {fold_number}: C={selected_c:g}, "
                f"window BA={float(fold_metrics['balanced_accuracy']):.4f}, "
                f"episode threshold={episode_threshold:.5f}"
            )

        if np.isnan(all_test_scores).any() or np.any(all_test_predictions < 0):
            raise AssertionError("Some windows did not receive an outer-test prediction")
        metrics = metric_bundle(y, all_test_predictions, all_test_scores)
        result_rows.append({"channel": channel, "model": MODEL_NAME, **metrics})

        combined_episode_scores = np.concatenate(episode_score_parts)
        combined_episode_labels = np.concatenate(episode_label_parts)
        combined_episode_predictions = (combined_episode_scores >= 0).astype(np.int64)
        episode_metrics = metric_bundle(
            combined_episode_labels, combined_episode_predictions, combined_episode_scores
        )
        episode_result_rows.append(
            {
                "channel": channel,
                "model": MODEL_NAME,
                "n_episodes": combined_episode_labels.size,
                "n_vt_episodes": int(np.sum(combined_episode_labels == VT_LABEL)),
                "n_vf_episodes": int(np.sum(combined_episode_labels == VF_LABEL)),
                **episode_metrics,
            }
        )

        print(
            f"  CH{channel} window: BA={float(metrics['balanced_accuracy']):.4f}, "
            f"VT={float(metrics['vt_sensitivity']):.4f}, "
            f"VF={float(metrics['vf_sensitivity']):.4f}, AUC={float(metrics['roc_auc']):.4f}"
        )
        print(
            f"  CH{channel} episode: BA={float(episode_metrics['balanced_accuracy']):.4f}, "
            f"VT={float(episode_metrics['vt_sensitivity']):.4f}, "
            f"VF={float(episode_metrics['vf_sensitivity']):.4f}"
        )

    output_paths = {
        "results": output_dir / f"{OUTPUT_PREFIX}_results.csv",
        "folds": output_dir / f"{OUTPUT_PREFIX}_folds.csv",
        "episodes": output_dir / f"{OUTPUT_PREFIX}_episode_results.csv",
        "distributions": output_dir / f"{OUTPUT_PREFIX}_feature_distributions.csv",
    }
    write_csv(output_paths["results"], result_rows)
    write_csv(output_paths["folds"], fold_rows)
    write_csv(output_paths["episodes"], episode_result_rows)
    write_csv(output_paths["distributions"], distribution_rows)

    print("\nSTRICT VFDB VT vs VF/VFIB - WINDOW LEVEL")
    print("Channel  BalAcc  VT Sens  VF Sens  Macro F1  AUC")
    for row in result_rows:
        print(
            f"CH{row['channel']}     {float(row['balanced_accuracy']):.4f}  "
            f"{float(row['vt_sensitivity']):.4f}   {float(row['vf_sensitivity']):.4f}   "
            f"{float(row['macro_f1']):.4f}    {float(row['roc_auc']):.4f}"
        )
    print("\nCreated new outputs:")
    for path in output_paths.values():
        print(f"  {path}")
    print(f"Elapsed seconds: {time.perf_counter() - started:.1f}")


if __name__ == "__main__":
    main()
