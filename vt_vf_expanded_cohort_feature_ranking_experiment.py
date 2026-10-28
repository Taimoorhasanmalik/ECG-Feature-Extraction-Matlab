"""Expanded-cohort VT-vs-VF feature ranking.

The previous high-power ranking (`vt_vf_filtered_feature_ablation_experiment.py`)
drew its cohort from VFDB alone and excluded ventricular flutter, which left only
four records containing VF/VFIB. This experiment widens the cohort under the
existing CUDB policy and re-ranks the same fourteen features.

Cohort sources, single channel (channel 0) throughout:

- VFDB rhythm notes provide VT and the VF/VFIB/VFL family.
- CUDB provides VF only, from explicit `[` to `]` intervals. CUDB VT is never
  used, per `change_records/2026-08-23_exclude_cudb_vt_policy_v1.md`.
- MITDB rhythm notes provide VT, and VFL when the label policy includes it.

Signal processing, Pan-Tompkins detection, artifact screening and the fourteen
feature definitions are imported unchanged from the original root experiment so
that results stay comparable. No existing file is modified.

Ranking uses four independent views, all nested inside record-grouped folds:

1. per-fold standardized SVM coefficients and sign stability
2. permutation importance measured on held-out records
3. record-level bootstrap stability selection with an L1 linear SVM
4. single-feature and leave-one-feature-out balanced-accuracy deltas, with
   paired record-bootstrap confidence intervals

Database-confound controls are reported alongside: per-database accuracy,
leave-one-database-out generalization, and a database-identity probe.
"""

from __future__ import annotations

import argparse
import json
import time
import warnings
from collections import Counter
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly
from sklearn.exceptions import ConvergenceWarning
from sklearn.metrics import balanced_accuracy_score
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import LinearSVC

try:
    import wfdb
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Install the Python 'wfdb' package before running this experiment.") from exc

import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base


ANALYSIS_FS = base.ANALYSIS_FS
WINDOW_SECONDS = base.WINDOW_SECONDS
STRIDE_SECONDS = base.STRIDE_SECONDS
ARTIFACT_PAD_SECONDS = base.ARTIFACT_PAD_SECONDS
FEATURE_NAMES = base.FEATURE_NAMES
VT_LABEL = base.VT_LABEL
VF_LABEL = base.VF_LABEL
RANDOM_STATE = base.RANDOM_STATE
C_VALUES = base.C_VALUES

MAX_OUTER_FOLDS = 5
PERMUTATION_REPEATS = 10
STABILITY_RESAMPLES = 200
BOOTSTRAP_RESAMPLES = 2000
L1_C_VALUES = (0.01, 0.1, 1.0)

DB_FOLDERS = {
    "vfdb": "mit-bih-malignant-ventricular-ectopy-database-1.0.0",
    "cudb": "cu-ventricular-tachyarrhythmia-database-1.0.0",
    "mitdb": "mit-bih-arrhythmia-database-1.0.0",
}

RAW_VT = "VT"
RAW_VF = "VF"
RAW_VFIB = "VFIB"
RAW_VFL = "VFL"
RAW_CUDB = "CUDB_BRACKET"

VF_STRICT = frozenset({RAW_VF, RAW_VFIB})
VF_STRICT_CUDB = frozenset({RAW_VF, RAW_VFIB, RAW_CUDB})
VF_FAMILY = frozenset({RAW_VF, RAW_VFIB, RAW_VFL, RAW_CUDB})

# Each variant names the databases it draws from and which raw rhythms map to VF.
# VT always comes from the RAW_VT notes of the listed databases except CUDB,
# whose VT is excluded by policy at load time.
VARIANTS: dict[str, dict[str, object]] = {
    "A_vfdb_strict": {
        "databases": ("vfdb",),
        "vf_rhythms": VF_STRICT,
        "note": "Reproduces the original four-VF-record cohort.",
    },
    "B_vfdb_cudb_strict": {
        "databases": ("vfdb", "cudb"),
        "vf_rhythms": VF_STRICT_CUDB,
        "note": "Adds CUDB VF. VFDB VFL still excluded, so the VF definition is mixed.",
    },
    "C_vfdb_cudb_family": {
        "databases": ("vfdb", "cudb"),
        "vf_rhythms": VF_FAMILY,
        "note": "Consistent fibrillation/flutter family on both databases.",
    },
    "D_all_family": {
        "databases": ("vfdb", "cudb", "mitdb"),
        "vf_rhythms": VF_FAMILY,
        "note": "Adds MITDB VT. Largest cohort, strongest database confound risk.",
    },
}


@dataclass(frozen=True)
class Interval:
    db: str
    record_id: str
    episode_id: str
    start: int
    end: int
    raw_rhythm: str
    closed: bool = True


def clean_aux(note: str) -> str:
    return str(note).replace("\x00", "").strip().upper()


def raw_rhythm_of(note: str) -> str | None:
    value = clean_aux(note)
    if value in {"(VT", "VT"}:
        return RAW_VT
    if value in {"(VF", "VF"}:
        return RAW_VF
    if value in {"(VFIB", "VFIB"}:
        return RAW_VFIB
    if value in {"(VFL", "VFL"}:
        return RAW_VFL
    return None


def is_rhythm_note(note: str) -> bool:
    value = clean_aux(note)
    return value.startswith("(") or value in {"VT", "VF", "VFIB", "VFL"}


def note_intervals(
    db: str, record_id: str, samples: np.ndarray, symbols, notes, signal_length: int
) -> list[Interval]:
    """Rhythm-note driven intervals, each running to the next rhythm note."""
    points = [
        (int(sample), str(note))
        for sample, symbol, note in zip(samples, symbols, notes)
        if symbol == "+" and is_rhythm_note(note)
    ]
    result: list[Interval] = []
    for index, (start, note) in enumerate(points):
        end = points[index + 1][0] if index + 1 < len(points) else signal_length
        rhythm = raw_rhythm_of(note)
        if rhythm is None or end <= start:
            continue
        episode_id = f"{record_id}:{start}:{end}:{rhythm}"
        result.append(Interval(db, record_id, episode_id, start, end, rhythm))
    return result


def bracket_intervals(
    db: str, record_id: str, samples: np.ndarray, symbols, signal_length: int
) -> list[Interval]:
    """CUDB `[` to `]` ventricular fibrillation intervals.

    Eight of the 47 `[` markers have no closing `]`; those run to end of record.
    """
    result: list[Interval] = []
    open_at: int | None = None
    for sample, symbol in zip(samples, symbols):
        if symbol == "[":
            if open_at is None:
                open_at = int(sample)
        elif symbol == "]" and open_at is not None:
            end = int(sample)
            if end > open_at:
                episode_id = f"{record_id}:{open_at}:{end}:{RAW_CUDB}"
                result.append(Interval(db, record_id, episode_id, open_at, end, RAW_CUDB))
            open_at = None
    if open_at is not None and signal_length > open_at:
        episode_id = f"{record_id}:{open_at}:{signal_length}:{RAW_CUDB}"
        result.append(
            Interval(db, record_id, episode_id, open_at, signal_length, RAW_CUDB, closed=False)
        )
    return result


def noisy_interval_mask(samples, symbols, subtypes, signal_length: int) -> np.ndarray:
    """Signal-quality state from paired `~` annotations.

    A `~` with subtype -1 opens an annotated-noisy segment and subtype +1
    closes it. The segment persists between markers, so masking only a fixed
    pad around each marker leaves most annotated noise unscreened.
    """
    mask = np.zeros(signal_length, dtype=bool)
    start: int | None = None
    for sample, symbol, subtype in zip(samples, symbols, subtypes):
        if symbol != "~":
            continue
        if int(subtype) == -1 and start is None:
            start = int(sample)
        elif int(subtype) == 1 and start is not None:
            mask[start : int(sample)] = True
            start = None
    if start is not None:
        mask[start:] = True
    return mask


def dropout_runs(invalid: np.ndarray, minimum_samples: int) -> list[tuple[int, int]]:
    """Contiguous invalid-sample runs, the recorded signature of a shock."""
    edges = np.diff(np.concatenate(([0], invalid.view(np.int8), [0])))
    starts = np.flatnonzero(edges == 1)
    ends = np.flatnonzero(edges == -1)
    return [(int(a), int(b)) for a, b in zip(starts, ends) if b - a >= minimum_samples]


def record_bases(folder: Path) -> list[Path]:
    records_file = folder / "RECORDS"
    if records_file.exists():
        names = [line.strip() for line in records_file.read_text().splitlines() if line.strip()]
        return [folder / name for name in names]
    return [path.with_suffix("") for path in sorted(folder.glob("*.hea"))]


def extract_database(db: str, folder: Path) -> tuple[list[dict], np.ndarray, Counter]:
    """Return per-window metadata rows and the matching feature matrix."""
    width = int(round(WINDOW_SECONDS * ANALYSIS_FS))
    stride = int(round(STRIDE_SECONDS * ANALYSIS_FS))
    rows: list[dict] = []
    blocks: list[np.ndarray] = []
    audit: Counter = Counter()

    for path in record_bases(folder):
        header = wfdb.rdheader(str(path))
        annotation = wfdb.rdann(str(path), "atr")
        record = wfdb.rdrecord(str(path))
        record_id = f"{db}/{path.name}"
        source_fs = float(header.fs)
        ratio = Fraction(ANALYSIS_FS / source_fs).limit_denominator(10_000)
        scale = ANALYSIS_FS / source_fs
        ann_samples = np.rint(np.asarray(annotation.sample) * scale).astype(np.int64)
        symbols = list(annotation.symbol)
        subtypes = list(annotation.subtype)
        notes = [str(item) for item in annotation.aux_note]

        # Capture the WFDB invalid-sample markers BEFORE interpolation. The
        # shared artifact mask tests ~isfinite, but interpolation runs first, so
        # that test can never fire. VFDB and MITDB have no invalid samples, so
        # this only matters once CUDB is in the cohort.
        raw_signal = np.asarray(record.p_signal[:, 0], dtype=np.float64)
        raw_invalid = ~np.isfinite(raw_signal)
        source = base.interpolate_nonfinite(raw_signal)
        signal = (
            resample_poly(source, ratio.numerator, ratio.denominator)
            if abs(source_fs - ANALYSIS_FS) > 1e-9
            else source.copy()
        )
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
                invalid = np.concatenate(
                    [invalid, np.zeros(signal_length - invalid.size, dtype=bool)]
                )
        invalid_prefix = np.concatenate(([0], np.cumsum(invalid, dtype=np.int64)))
        noisy = noisy_interval_mask(ann_samples, symbols, subtypes, signal_length)
        noisy_prefix = np.concatenate(([0], np.cumsum(noisy, dtype=np.int64)))
        shocks = [start for start, _ in dropout_runs(invalid, int(round(0.2 * ANALYSIS_FS)))]
        filtered = base.filter_05_40(signal, ANALYSIS_FS)
        pt_samples = base.pan_tompkins_from_05_40(filtered, ANALYSIS_FS)
        channel_record = base.ChannelRecord(filtered, pt_samples)

        artifact = base.signal_artifact_mask(signal, ANALYSIS_FS)
        pad = int(round(ARTIFACT_PAD_SECONDS * ANALYSIS_FS))
        for sample, symbol in zip(ann_samples, symbols):
            if symbol in {"~", "|"}:
                lo = max(0, int(sample) - pad)
                hi = min(signal_length, int(sample) + pad + 1)
                artifact[lo:hi] = True
        artifact_prefix = np.concatenate(([0], np.cumsum(artifact, dtype=np.int64)))

        if db == "cudb":
            # Policy: CUDB contributes VF only, never VT.
            intervals = bracket_intervals(db, record_id, ann_samples, symbols, signal_length)
        else:
            intervals = note_intervals(db, record_id, ann_samples, symbols, notes, signal_length)
            if db == "mitdb":
                # MITDB 207 carries both (VFL notes and duplicate bracket markers.
                intervals = [item for item in intervals if item.raw_rhythm != RAW_CUDB]

        record_windows: list[base.Window] = []
        record_rows: list[dict] = []
        for interval in intervals:
            audit[f"episodes_{interval.raw_rhythm}"] += 1
            if interval.end - interval.start < width:
                audit[f"short_episodes_{interval.raw_rhythm}"] += 1
                continue
            end_limit = min(interval.end, signal_length)
            episode_shocks = [s for s in shocks if interval.start <= s < end_limit]
            first_shock = min(episode_shocks) if episode_shocks else None
            if first_shock is not None:
                audit[f"episodes_with_shock_{interval.raw_rhythm}"] += 1
            for start in range(interval.start, end_limit - width + 1, stride):
                end = start + width
                if artifact_prefix[end] - artifact_prefix[start] > 0:
                    audit["artifact_rejected_windows"] += 1
                    continue
                has_invalid = invalid_prefix[end] - invalid_prefix[start] > 0
                in_noisy = noisy_prefix[end] - noisy_prefix[start] > 0
                post_shock = first_shock is not None and start >= first_shock
                record_windows.append(
                    base.Window(record_id, interval.episode_id, start, end, 0, interval.raw_rhythm)
                )
                record_rows.append(
                    {
                        "db": db,
                        "record_id": record_id,
                        "episode_id": interval.episode_id,
                        "start": start,
                        "end": end,
                        "raw_rhythm": interval.raw_rhythm,
                        "has_invalid": bool(has_invalid),
                        "in_noisy_interval": bool(in_noisy),
                        "post_shock": bool(post_shock),
                        "unclosed_episode": bool(not interval.closed),
                    }
                )
                audit[f"windows_{interval.raw_rhythm}"] += 1
                if has_invalid:
                    audit["windows_with_interpolated_samples"] += 1
                if in_noisy:
                    audit["windows_in_annotated_noise"] += 1
                if post_shock:
                    audit["windows_after_shock"] += 1
                if not interval.closed:
                    audit["windows_from_unclosed_episode"] += 1

        if record_windows:
            blocks.append(base.feature_matrix(record_windows, {record_id: channel_record}))
            rows.extend(record_rows)
        audit["records_read"] += 1
        print(f"    {record_id}: {len(record_windows)} windows", flush=True)

    features = np.vstack(blocks) if blocks else np.zeros((0, len(FEATURE_NAMES)))
    return rows, features, audit


def build_cache(root: Path, cache_path: Path) -> tuple[list[dict], np.ndarray]:
    if cache_path.exists():
        print(f"Loading cached features from {cache_path}")
        payload = np.load(cache_path, allow_pickle=True)
        return list(payload["rows"]), payload["features"]

    all_rows: list[dict] = []
    all_features: list[np.ndarray] = []
    for db, folder_name in DB_FOLDERS.items():
        folder = root / folder_name
        if not folder.is_dir():
            raise FileNotFoundError(folder)
        print(f"  extracting {db} from {folder}", flush=True)
        rows, features, audit = extract_database(db, folder)
        print(f"  {db}: {len(rows)} windows  audit={dict(sorted(audit.items()))}", flush=True)
        all_rows.extend(rows)
        if features.size:
            all_features.append(features)

    features = np.vstack(all_features)
    if features.shape[0] != len(all_rows):
        raise AssertionError("Feature/metadata length mismatch")
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache_path, rows=np.array(all_rows, dtype=object), features=features)
    print(f"Cached {features.shape[0]} windows to {cache_path}")
    return all_rows, features


SCREEN_FLAGS = ("has_invalid", "in_noisy_interval", "post_shock", "unclosed_episode")


def assemble_variant(
    rows: list[dict],
    features: np.ndarray,
    spec: dict[str, object],
    screen: tuple[str, ...] = (),
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    databases = set(spec["databases"])  # type: ignore[arg-type]
    vf_rhythms = spec["vf_rhythms"]  # type: ignore[assignment]
    keep: list[int] = []
    labels: list[int] = []
    for index, row in enumerate(rows):
        if row["db"] not in databases:
            continue
        if any(row.get(flag, False) for flag in screen):
            continue
        rhythm = row["raw_rhythm"]
        if rhythm == RAW_VT:
            labels.append(VT_LABEL)
        elif rhythm in vf_rhythms:
            labels.append(VF_LABEL)
        else:
            continue
        keep.append(index)
    index_array = np.asarray(keep, dtype=np.int64)
    x = features[index_array]
    y = np.asarray(labels, dtype=np.int64)
    groups = np.asarray([rows[i]["record_id"] for i in keep])
    dbs = np.asarray([rows[i]["db"] for i in keep])
    episodes = np.asarray([rows[i]["episode_id"] for i in keep])
    return x, y, groups, dbs, episodes


def class_complete(y: np.ndarray, indices: np.ndarray) -> bool:
    return set(np.unique(y[indices]).tolist()) == {VT_LABEL, VF_LABEL}


def grouped_outer_folds(
    y: np.ndarray, groups: np.ndarray
) -> tuple[list[tuple[np.ndarray, np.ndarray]], int, int]:
    """Largest feasible number of class-complete record-grouped folds."""
    overall = float(np.mean(y))
    for n_splits in range(MAX_OUTER_FOLDS, 1, -1):
        best = None
        for offset in range(1024):
            seed = RANDOM_STATE + offset
            splitter = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=seed)
            folds = list(splitter.split(np.zeros(y.size), y, groups))
            if any(
                not class_complete(y, train) or not class_complete(y, test) for train, test in folds
            ):
                continue
            score = sum(
                abs(test.size / y.size - 1.0 / n_splits)
                + abs(float(np.mean(y[test])) - overall)
                for _, test in folds
            )
            if best is None or score < best[0]:
                best = (score, seed, folds)
        if best is not None:
            return best[2], n_splits, best[1]
    raise RuntimeError("No class-complete record-grouped outer folds")


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


def tune_c(x: np.ndarray, y: np.ndarray, train: np.ndarray, validation: np.ndarray) -> float:
    best: tuple[float, float] | None = None
    selected = C_VALUES[0]
    for c_value in C_VALUES:
        model = make_model(c_value)
        model.fit(x[train], y[train])
        score = model.decision_function(x[validation])
        accuracy = balanced_accuracy_score(y[validation], (score >= 0).astype(np.int64))
        key = (float(accuracy), -c_value)
        if best is None or key > best:
            best = key
            selected = c_value
    return float(selected)


def nested_cv(
    x: np.ndarray,
    y: np.ndarray,
    groups: np.ndarray,
    folds: list[tuple[np.ndarray, np.ndarray]],
    collect_models: bool = False,
) -> dict[str, object]:
    """Out-of-fold predictions with C selected on inner records only."""
    oof_score = np.full(y.size, np.nan)
    per_fold: list[dict[str, object]] = []
    for fold_index, (train, test) in enumerate(folds, start=1):
        inner_train, inner_validation = base.grouped_inner_split(y, groups, train, fold_index)
        selected_c = tune_c(x, y, inner_train, inner_validation)
        model = make_model(selected_c)
        model.fit(x[train], y[train])
        score = model.decision_function(x[test])
        oof_score[test] = score
        entry: dict[str, object] = {
            "fold": fold_index,
            "selected_c": selected_c,
            "n_train": int(train.size),
            "n_test": int(test.size),
            "balanced_accuracy": float(
                balanced_accuracy_score(y[test], (score >= 0).astype(np.int64))
            ),
            "test_records": "|".join(sorted(set(groups[test].tolist()))),
        }
        if collect_models:
            entry["model"] = model
            entry["train"] = train
            entry["test"] = test
        per_fold.append(entry)
    if not np.isfinite(oof_score).all():
        raise AssertionError("Every window must receive an out-of-fold score")
    oof_prediction = (oof_score >= 0).astype(np.int64)
    return {
        "oof_score": oof_score,
        "oof_prediction": oof_prediction,
        "balanced_accuracy": float(balanced_accuracy_score(y, oof_prediction)),
        "per_fold": per_fold,
    }


def permutation_importance(
    x: np.ndarray, y: np.ndarray, per_fold: list[dict[str, object]]
) -> dict[str, tuple[float, float]]:
    """Balanced-accuracy drop when each feature is shuffled inside held-out records."""
    drops: dict[str, list[float]] = {name: [] for name in FEATURE_NAMES}
    for entry in per_fold:
        model = entry["model"]
        test = entry["test"]
        baseline = balanced_accuracy_score(
            y[test], (model.decision_function(x[test]) >= 0).astype(np.int64)
        )
        for column, name in enumerate(FEATURE_NAMES):
            generator = np.random.default_rng(RANDOM_STATE + 13 * column + int(entry["fold"]))
            for _ in range(PERMUTATION_REPEATS):
                shuffled = x[test].copy()
                shuffled[:, column] = generator.permutation(shuffled[:, column])
                accuracy = balanced_accuracy_score(
                    y[test], (model.decision_function(shuffled) >= 0).astype(np.int64)
                )
                drops[name].append(float(baseline - accuracy))
    return {
        name: (float(np.mean(values)), float(np.std(values)))
        for name, values in drops.items()
    }


def stability_selection(
    x: np.ndarray, y: np.ndarray, groups: np.ndarray
) -> dict[str, float]:
    """Selection frequency of each feature under record-level bootstrap with L1."""
    unique_records = np.unique(groups)
    record_label = {
        record: int(round(float(np.mean(y[groups == record])))) for record in unique_records
    }
    vt_records = np.array([r for r in unique_records if record_label[r] == VT_LABEL])
    vf_records = np.array([r for r in unique_records if record_label[r] == VF_LABEL])
    index_by_record = {record: np.flatnonzero(groups == record) for record in unique_records}
    counts = {name: 0 for name in FEATURE_NAMES}
    attempts = 0
    generator = np.random.default_rng(RANDOM_STATE)
    for index in range(STABILITY_RESAMPLES):
        drawn = np.concatenate(
            [
                generator.choice(vt_records, size=vt_records.size, replace=True),
                generator.choice(vf_records, size=vf_records.size, replace=True),
            ]
        )
        rows = np.concatenate([index_by_record[record] for record in drawn])
        if not class_complete(y, rows):
            continue
        c_value = L1_C_VALUES[index % len(L1_C_VALUES)]
        model = Pipeline(
            [
                ("scaler", StandardScaler()),
                (
                    "svm",
                    LinearSVC(
                        C=c_value,
                        penalty="l1",
                        loss="squared_hinge",
                        dual=False,
                        class_weight="balanced",
                        random_state=RANDOM_STATE,
                        max_iter=20_000,
                    ),
                ),
            ]
        )
        model.fit(x[rows], y[rows])
        coefficients = model.named_steps["svm"].coef_.ravel()
        attempts += 1
        for name, value in zip(FEATURE_NAMES, coefficients):
            if abs(value) > 1e-8:
                counts[name] += 1
    if attempts == 0:
        raise RuntimeError("No usable bootstrap resamples for stability selection")
    return {name: counts[name] / attempts for name in FEATURE_NAMES}


def paired_record_bootstrap(
    y: np.ndarray,
    groups: np.ndarray,
    prediction_a: np.ndarray,
    prediction_b: np.ndarray,
) -> tuple[float, float]:
    """Percentile interval for BA(a) - BA(b) resampling whole records.

    Balanced accuracy decomposes into per-class totals, so each record is
    reduced to four counts once and every resample is a sum over those counts.
    That keeps the interval exact while staying independent of window count.
    """
    unique_records = np.unique(groups)
    n_vt = np.zeros(unique_records.size)
    n_vf = np.zeros(unique_records.size)
    ok_vt = np.zeros((2, unique_records.size))
    ok_vf = np.zeros((2, unique_records.size))
    for position, record in enumerate(unique_records):
        rows = np.flatnonzero(groups == record)
        target = y[rows]
        is_vt = target == VT_LABEL
        is_vf = target == VF_LABEL
        n_vt[position] = is_vt.sum()
        n_vf[position] = is_vf.sum()
        for slot, prediction in enumerate((prediction_a, prediction_b)):
            correct = prediction[rows] == target
            ok_vt[slot, position] = np.sum(correct & is_vt)
            ok_vf[slot, position] = np.sum(correct & is_vf)

    generator = np.random.default_rng(RANDOM_STATE)
    draws = generator.integers(0, unique_records.size, size=(BOOTSTRAP_RESAMPLES, unique_records.size))
    total_vt = n_vt[draws].sum(axis=1)
    total_vf = n_vf[draws].sum(axis=1)
    usable = (total_vt > 0) & (total_vf > 0)
    if not usable.any():
        return float("nan"), float("nan")

    accuracies = []
    for slot in range(2):
        vt_rate = ok_vt[slot][draws].sum(axis=1)[usable] / total_vt[usable]
        vf_rate = ok_vf[slot][draws].sum(axis=1)[usable] / total_vf[usable]
        accuracies.append(0.5 * (vt_rate + vf_rate))
    deltas = accuracies[0] - accuracies[1]
    return float(np.percentile(deltas, 2.5)), float(np.percentile(deltas, 97.5))


def database_probe(
    x: np.ndarray, dbs: np.ndarray, groups: np.ndarray
) -> float:
    """Balanced accuracy of predicting the source database from the features.

    A high value means the feature vector carries recording identity, so a
    cohort whose classes are split across databases can be separated without
    learning anything about rhythm.
    """
    unique = np.unique(dbs)
    if unique.size < 2:
        return float("nan")
    target = (dbs == unique[0]).astype(np.int64)
    folds, _, _ = grouped_outer_folds(target, groups)
    result = nested_cv(x, target, groups, folds)
    return float(result["balanced_accuracy"])


def leave_one_database_out(
    x: np.ndarray, y: np.ndarray, groups: np.ndarray, dbs: np.ndarray
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for held_out in sorted(set(dbs.tolist())):
        test = np.flatnonzero(dbs == held_out)
        train = np.flatnonzero(dbs != held_out)
        if not class_complete(y, train) or np.unique(y[test]).size < 2:
            rows.append(
                {
                    "held_out_database": held_out,
                    "n_test": int(test.size),
                    "balanced_accuracy": float("nan"),
                    "note": "held-out or training side lacks both classes",
                }
            )
            continue
        inner_train, inner_validation = base.grouped_inner_split(y, groups, train, 1)
        selected_c = tune_c(x, y, inner_train, inner_validation)
        model = make_model(selected_c)
        model.fit(x[train], y[train])
        score = model.decision_function(x[test])
        rows.append(
            {
                "held_out_database": held_out,
                "n_test": int(test.size),
                "balanced_accuracy": float(
                    balanced_accuracy_score(y[test], (score >= 0).astype(np.int64))
                ),
                "note": "",
            }
        )
    return rows


def run_variant(
    name: str,
    spec: dict[str, object],
    rows: list[dict],
    features: np.ndarray,
    output: Path,
    screen: tuple[str, ...] = (),
) -> dict[str, object]:
    print(f"\n{'=' * 78}\nVARIANT {name}\n{spec['note']}\n{'=' * 78}", flush=True)
    if screen:
        print(f"quality screen: {', '.join(screen)}", flush=True)
    x, y, groups, dbs, episodes = assemble_variant(rows, features, spec, screen)
    vt_records = sorted({g for g, label in zip(groups, y) if label == VT_LABEL})
    vf_records = sorted({g for g, label in zip(groups, y) if label == VF_LABEL})
    print(
        f"windows={y.size} (VT={int(np.sum(y == VT_LABEL))}, VF={int(np.sum(y == VF_LABEL))})  "
        f"records={np.unique(groups).size} (VT-bearing={len(vt_records)}, VF-bearing={len(vf_records)})  "
        f"episodes={np.unique(episodes).size}",
        flush=True,
    )

    folds, n_splits, seed = grouped_outer_folds(y, groups)
    print(f"outer folds={n_splits} seed={seed}", flush=True)

    full = nested_cv(x, y, groups, folds, collect_models=True)
    print(f"full 14-feature out-of-fold BA = {full['balanced_accuracy']:.4f}", flush=True)

    # 1. coefficients and sign stability
    coefficient_rows: list[dict[str, object]] = []
    signs: dict[str, list[str]] = {name: [] for name in FEATURE_NAMES}
    magnitudes: dict[str, list[float]] = {name: [] for name in FEATURE_NAMES}
    for entry in full["per_fold"]:
        coefficients = entry["model"].named_steps["svm"].coef_.ravel()
        for feature, value in zip(FEATURE_NAMES, coefficients):
            signs[feature].append("+" if value >= 0 else "-")
            magnitudes[feature].append(abs(float(value)))
            coefficient_rows.append(
                {
                    "variant": name,
                    "row_type": "fold",
                    "fold": entry["fold"],
                    "feature": feature,
                    "standardized_coefficient": float(value),
                    "selected_c": entry["selected_c"],
                }
            )

    # 2. permutation importance
    permutation = permutation_importance(x, y, full["per_fold"])

    # 3. stability selection
    stability = stability_selection(x, y, groups)

    # 4. single-feature and leave-one-out deltas
    ranking_rows: list[dict[str, object]] = []
    for column, feature in enumerate(FEATURE_NAMES):
        single = nested_cv(x[:, [column]], y, groups, folds)
        remaining = [i for i in range(len(FEATURE_NAMES)) if i != column]
        lofo = nested_cv(x[:, remaining], y, groups, folds)
        delta = full["balanced_accuracy"] - lofo["balanced_accuracy"]
        low, high = paired_record_bootstrap(
            y, groups, full["oof_prediction"], lofo["oof_prediction"]
        )
        sign_changes = sum(
            1 for a, b in zip(signs[feature][:-1], signs[feature][1:]) if a != b
        )
        ranking_rows.append(
            {
                "variant": name,
                "feature": feature,
                "single_feature_ba": single["balanced_accuracy"],
                "leave_one_out_ba": lofo["balanced_accuracy"],
                "lofo_delta": delta,
                "lofo_delta_ci_low": low,
                "lofo_delta_ci_high": high,
                "delta_excludes_zero": int(np.isfinite(low) and np.isfinite(high) and low * high > 0),
                "permutation_ba_drop": permutation[feature][0],
                "permutation_ba_drop_std": permutation[feature][1],
                "stability_selection_frequency": stability[feature],
                "mean_absolute_coefficient": float(np.mean(magnitudes[feature])),
                "sign_by_fold": "|".join(signs[feature]),
                "sign_change_count": sign_changes,
                "sign_stable": int(sign_changes == 0),
            }
        )
        print(
            f"  {feature:<34} single={single['balanced_accuracy']:.4f} "
            f"lofo_delta={delta:+.4f} [{low:+.4f},{high:+.4f}] "
            f"perm={permutation[feature][0]:+.4f} stab={stability[feature]:.2f} "
            f"signs={''.join(signs[feature])}",
            flush=True,
        )

    # database controls
    control_rows = leave_one_database_out(x, y, groups, dbs)
    for row in control_rows:
        row["variant"] = name
    probe = database_probe(x, dbs, groups) if np.unique(dbs).size > 1 else float("nan")

    per_database_rows: list[dict[str, object]] = []
    for db in sorted(set(dbs.tolist())):
        mask = dbs == db
        target = y[mask]
        prediction = full["oof_prediction"][mask]
        per_database_rows.append(
            {
                "variant": name,
                "database": db,
                "n_windows": int(mask.sum()),
                "n_vt": int(np.sum(target == VT_LABEL)),
                "n_vf": int(np.sum(target == VF_LABEL)),
                "balanced_accuracy": float(balanced_accuracy_score(target, prediction))
                if np.unique(target).size > 1
                else float("nan"),
                "accuracy": float(np.mean(target == prediction)),
            }
        )

    fold_rows = [
        {k: v for k, v in entry.items() if k not in {"model", "train", "test"}} | {"variant": name}
        for entry in full["per_fold"]
    ]

    base.write_csv(output / f"{name}_feature_ranking.csv", ranking_rows)
    base.write_csv(output / f"{name}_coefficients.csv", coefficient_rows)
    base.write_csv(output / f"{name}_folds.csv", fold_rows)
    base.write_csv(output / f"{name}_per_database.csv", per_database_rows)
    base.write_csv(output / f"{name}_leave_one_database_out.csv", control_rows)

    print(f"  database-identity probe BA = {probe:.4f}", flush=True)
    for row in control_rows:
        print(
            f"  leave-out {row['held_out_database']:<6} BA={row['balanced_accuracy']} {row['note']}",
            flush=True,
        )

    return {
        "variant": name,
        "screen": "|".join(screen) if screen else "none",
        "note": spec["note"],
        "databases": list(spec["databases"]),  # type: ignore[arg-type]
        "n_windows": int(y.size),
        "n_vt_windows": int(np.sum(y == VT_LABEL)),
        "n_vf_windows": int(np.sum(y == VF_LABEL)),
        "n_records": int(np.unique(groups).size),
        "n_vt_records": len(vt_records),
        "n_vf_records": len(vf_records),
        "n_episodes": int(np.unique(episodes).size),
        "outer_folds": n_splits,
        "fold_seed": seed,
        "full_model_ba": full["balanced_accuracy"],
        "database_probe_ba": probe,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=None)
    parser.add_argument("--variants", type=str, default=",".join(VARIANTS))
    parser.add_argument(
        "--screen",
        type=str,
        default="",
        help=(
            "Comma-separated window quality screens to apply: "
            + ", ".join(SCREEN_FLAGS)
            + ". Empty keeps every window."
        ),
    )
    arguments = parser.parse_args()
    screen = tuple(item.strip() for item in arguments.screen.split(",") if item.strip())
    for flag in screen:
        if flag not in SCREEN_FLAGS:
            raise SystemExit(f"Unknown screen flag {flag!r}; choose from {SCREEN_FLAGS}")

    warnings.filterwarnings("ignore", category=ConvergenceWarning)
    started = time.perf_counter()

    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    cache = arguments.cache or (output.parent / "expanded_cohort_features_ch0.npz")

    rows, features = build_cache(arguments.databases_root.resolve(), cache.resolve())
    print(f"Total extracted windows: {features.shape[0]}")

    summary: list[dict[str, object]] = []
    for name in [item.strip() for item in arguments.variants.split(",") if item.strip()]:
        summary.append(run_variant(name, VARIANTS[name], rows, features, output, screen))

    base.write_csv(output / "variant_summary.csv", summary)
    (output / "manifest.json").write_text(
        json.dumps(
            {
                "script": Path(__file__).name,
                "databases_root": str(arguments.databases_root),
                "channel": 0,
                "screen": list(screen),
                "feature_names": FEATURE_NAMES,
                "permutation_repeats": PERMUTATION_REPEATS,
                "stability_resamples": STABILITY_RESAMPLES,
                "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
                "variants": summary,
                "elapsed_seconds": time.perf_counter() - started,
            },
            indent=2,
        ),
        encoding="ascii",
    )
    print(f"\nElapsed seconds: {time.perf_counter() - started:.1f}")
    print(f"Outputs in {output}")


if __name__ == "__main__":
    main()
