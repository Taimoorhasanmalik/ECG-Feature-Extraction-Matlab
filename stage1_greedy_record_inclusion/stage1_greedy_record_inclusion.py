"""Forward greedy record-inclusion diagnostic for Stage 1's normal-vs-
abnormal task, mirroring `greedy_record_inclusion/vt_vf_greedy_record_
inclusion_window_holdout.py` (built for Stage 2's VT-vs-VF task) applied
fresh to Stage 1 instead, per explicit request, starting from a small seed
pool rather than reusing Stage 1's existing 84-record training pool.

Starts from a small seed of records (mix of records with and without
abnormal windows), then adds the remaining candidate records ONE AT A TIME
in a fixed random order. After each addition, refits a fresh linear SVM on
the pool's own within-record-chronological-70% and scores it on the pool's
own within-record held-out 30% (never a genuinely unseen record -- same
"internal consistency" question Stage 2's version asks, not cross-patient
generalization). A candidate is rejected (and left out of the pool for
every later step too) if adding it drops the pool's held-out accuracy by
more than --tolerance, or (with --floor set) if the resulting accuracy
would fall below an absolute floor.

Per-record chronological 70/30 split logic (episode detection via gaps in
window start index, MIN_EPISODE_WINDOWS/BUFFER_WINDOWS/TRAIN_FRACTION) is
copied unchanged from the Stage 2 script -- it only depends on each row's
`start` field and the window stride, not on the feature set or task.

vfdb/610 and cudb/cu18 (the two records already flagged and dropped from
Stage 2's own training pool for being too small / a consistent poor
performer) are excluded from the candidate pool before extraction even
starts (see stage1_feature_extraction.py's EXCLUDED_RECORDS), per explicit
request to apply the same exclusion to Stage 1.

Modifies no existing file.
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np
from sklearn.metrics import accuracy_score, balanced_accuracy_score, precision_score, recall_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import LinearSVC

NORMAL_LABEL, ABNORMAL_LABEL = 0, 1
STRIDE_SECONDS = 1.0
ANALYSIS_FS = 120.0
MIN_EPISODE_WINDOWS = 10
BUFFER_WINDOWS = 1
TRAIN_FRACTION = 0.7
DEFAULT_C = 1.0
ORDER_SEED = 42


def make_model(c_value: float) -> Pipeline:
    return Pipeline([
        ("scaler", StandardScaler()),
        ("svm", LinearSVC(C=c_value, class_weight="balanced", random_state=42, dual="auto", max_iter=20_000)),
    ])


def build_within_record_split(rows: list[dict]) -> tuple[dict, dict]:
    stride_samples = int(round(STRIDE_SECONDS * ANALYSIS_FS))

    by_record: dict[str, list[int]] = {}
    for idx, row in enumerate(rows):
        by_record.setdefault(row["record_id"], []).append(idx)

    record_train: dict[str, list[int]] = {}
    record_test: dict[str, list[int]] = {}

    for record_id, indices in by_record.items():
        ordered = sorted(indices, key=lambda i: rows[i]["start"])
        record_train[record_id] = []
        record_test[record_id] = []

        episode: list[int] = []
        episodes: list[list[int]] = []
        previous_start = None
        for idx in ordered:
            start = rows[idx]["start"]
            if previous_start is not None and start - previous_start != stride_samples:
                episodes.append(episode)
                episode = []
            episode.append(idx)
            previous_start = start
        if episode:
            episodes.append(episode)

        for segment in episodes:
            n = len(segment)
            if n < MIN_EPISODE_WINDOWS:
                record_train[record_id].extend(segment)
                continue
            split_point = int(round(TRAIN_FRACTION * n))
            train_part = segment[: max(0, split_point - BUFFER_WINDOWS)]
            test_part = segment[split_point + BUFFER_WINDOWS:]
            if not train_part or not test_part:
                record_train[record_id].extend(segment)
                continue
            record_train[record_id].extend(train_part)
            record_test[record_id].extend(test_part)

    record_train = {k: np.array(v, dtype=np.int64) for k, v in record_train.items() if v}
    record_test = {k: np.array(v, dtype=np.int64) for k, v in record_test.items() if v}
    return record_train, record_test


def fit_and_score(included: list[str], features: np.ndarray, labels: np.ndarray,
                   record_train: dict, record_test: dict, c_value: float) -> dict | None:
    train_idx = np.concatenate([record_train[r] for r in included if r in record_train])
    test_idx = np.concatenate([record_test[r] for r in included if r in record_test])
    if train_idx.size == 0 or test_idx.size == 0:
        return None
    y_train = labels[train_idx]
    if np.unique(y_train).size < 2:
        return None
    y_test = labels[test_idx]

    model = make_model(c_value)
    model.fit(features[train_idx], y_train)
    predictions = model.predict(features[test_idx])

    result = {
        "n_train_windows": int(train_idx.size),
        "n_test_windows": int(test_idx.size),
        "accuracy": float(accuracy_score(y_test, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(y_test, predictions)),
        "abnormal_recall": float(recall_score(y_test, predictions, pos_label=ABNORMAL_LABEL, zero_division=0)),
        "normal_recall": float(recall_score(y_test, predictions, pos_label=NORMAL_LABEL, zero_division=0)),
        "abnormal_precision": float(precision_score(y_test, predictions, pos_label=ABNORMAL_LABEL, zero_division=0)),
        "normal_precision": float(precision_score(y_test, predictions, pos_label=NORMAL_LABEL, zero_division=0)),
    }
    return result


def pick_seed_records(candidates: list[str], has_abnormal: dict, rng: np.random.Generator, count_per_class: int = 2) -> list[str]:
    abnormal_pool = [r for r in candidates if has_abnormal[r]]
    normal_only_pool = [r for r in candidates if not has_abnormal[r]]
    seed = list(rng.choice(abnormal_pool, size=min(count_per_class, len(abnormal_pool)), replace=False))
    seed += list(rng.choice(normal_only_pool, size=min(count_per_class, len(normal_only_pool)), replace=False))
    return seed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=Path, default=Path("stage1_greedy_record_inclusion/results/stage1_features_full_cache.npz"))
    parser.add_argument("--output-dir", type=Path, default=Path("stage1_greedy_record_inclusion/results"))
    parser.add_argument("--c-value", type=float, default=DEFAULT_C)
    parser.add_argument("--acceptance-metric", choices=["accuracy", "balanced_accuracy"], default="balanced_accuracy")
    parser.add_argument("--tolerance", type=float, default=0.0)
    parser.add_argument("--floor", type=float, default=None)
    parser.add_argument("--order-seed", type=int, default=ORDER_SEED)
    parser.add_argument("--seed-per-class", type=int, default=2)
    arguments = parser.parse_args()

    output = arguments.output_dir
    output.mkdir(parents=True, exist_ok=True)

    payload = np.load(arguments.cache, allow_pickle=True)
    rows = list(payload["rows"])
    features = payload["features"]
    labels = np.array([row["label"] for row in rows], dtype=np.int64)
    print(f"Loaded {len(rows)} windows across {len({r['record_id'] for r in rows})} records, "
          f"{features.shape[1]} feature columns: {list(payload['feature_names'])}")
    print(f"Abnormal windows: {int((labels == ABNORMAL_LABEL).sum())} | Normal windows: {int((labels == NORMAL_LABEL).sum())}")

    record_train, record_test = build_within_record_split(rows)
    all_records = sorted(set(record_train) | set(record_test))
    trainable_records = [r for r in all_records if r in record_train]
    testable_records = set(record_test)
    print(f"{len(trainable_records)} records have trainable windows; {len(testable_records)} of those also have held-out windows")

    has_abnormal: dict[str, bool] = {}
    for row in rows:
        has_abnormal.setdefault(row["record_id"], False)
        if row["label"] == ABNORMAL_LABEL:
            has_abnormal[row["record_id"]] = True

    rng = np.random.default_rng(arguments.order_seed)
    candidates_with_test = [r for r in trainable_records if r in testable_records]
    seed_records = pick_seed_records(candidates_with_test, has_abnormal, rng, arguments.seed_per_class)
    remaining = [r for r in trainable_records if r not in seed_records]
    rng.shuffle(remaining)

    included: list[str] = list(seed_records)
    baseline = fit_and_score(included, features, labels, record_train, record_test, arguments.c_value)
    if baseline is None:
        raise SystemExit("Seed set does not yield both classes in train and test -- rerun with a different --order-seed")

    log_rows = [{
        "step": 0, "record_id": "+".join(seed_records), "action": "seed",
        "n_included_records": len(included), **baseline, "metric_before": None, "delta": None,
    }]
    print(f"\nSeed pool ({len(seed_records)} records: {seed_records}): "
          f"{arguments.acceptance_metric}={baseline[arguments.acceptance_metric]:.4f} "
          f"abnormal_recall={baseline['abnormal_recall']:.4f} abnormal_precision={baseline['abnormal_precision']:.4f} "
          f"(train={baseline['n_train_windows']}, test={baseline['n_test_windows']})")

    for step, candidate in enumerate(remaining, start=1):
        tentative = included + [candidate]
        metric_before = baseline[arguments.acceptance_metric]
        result = fit_and_score(tentative, features, labels, record_train, record_test, arguments.c_value)
        if result is None:
            log_rows.append({
                "step": step, "record_id": candidate, "action": "skipped_no_test_windows",
                "n_included_records": len(included), "n_train_windows": None, "n_test_windows": None,
                "accuracy": None, "balanced_accuracy": None, "abnormal_recall": None, "normal_recall": None,
                "abnormal_precision": None, "normal_precision": None,
                "metric_before": metric_before, "delta": None,
            })
            included = tentative
            print(f"  [{step}] {candidate}: no held-out windows of its own -- added as train-only, pool metric unchanged")
            continue

        delta = result[arguments.acceptance_metric] - metric_before
        if arguments.floor is not None:
            reject = result[arguments.acceptance_metric] < arguments.floor
        else:
            reject = delta < -arguments.tolerance

        if reject:
            action = "rejected"
        else:
            action = "accepted"
            included = tentative
            baseline = result

        log_rows.append({
            "step": step, "record_id": candidate, "action": action,
            "n_included_records": len(included), **result,
            "metric_before": metric_before, "delta": delta,
        })
        marker = "REJECTED" if action == "rejected" else "accepted"
        print(f"  [{step}] {candidate}: {arguments.acceptance_metric} {metric_before:.4f} -> "
              f"{result[arguments.acceptance_metric]:.4f} (delta {delta:+.4f})  {marker}  "
              f"abn_recall={result['abnormal_recall']:.4f} abn_precision={result['abnormal_precision']:.4f}  "
              f"(train={result['n_train_windows']}, test={result['n_test_windows']})")

    csv_path = output / "stage1_greedy_inclusion_log.csv"
    fieldnames = ["step", "record_id", "action", "n_included_records", "n_train_windows", "n_test_windows",
                  "accuracy", "balanced_accuracy", "abnormal_recall", "normal_recall",
                  "abnormal_precision", "normal_precision", "metric_before", "delta"]
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in log_rows:
            writer.writerow({k: row.get(k) for k in fieldnames})
    print(f"\nWrote {csv_path}")

    accepted = [r["record_id"] for r in log_rows if r["action"] in ("seed", "accepted", "skipped_no_test_windows")]
    rejected = [r["record_id"] for r in log_rows if r["action"] == "rejected"]
    final_metrics = baseline
    print(f"\nFinal pool: {len(included)} records accepted, {len(rejected)} rejected")
    print(f"Final held-out metrics: accuracy={final_metrics['accuracy']:.4f} "
          f"balanced_accuracy={final_metrics['balanced_accuracy']:.4f} "
          f"abnormal_recall={final_metrics['abnormal_recall']:.4f} abnormal_precision={final_metrics['abnormal_precision']:.4f} "
          f"normal_recall={final_metrics['normal_recall']:.4f} normal_precision={final_metrics['normal_precision']:.4f}")
    print(f"Rejected records ({len(rejected)}): {rejected}")


if __name__ == "__main__":
    main()
