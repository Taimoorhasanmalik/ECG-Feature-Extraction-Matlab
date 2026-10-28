"""Greedy record-by-record training-pool growth, scored on held-out windows
from the SAME records already in the pool (not on brand-new unseen records).

This is a deliberately different question from every other experiment in
this project's Python track. Everywhere else, evaluation is on entirely
held-out RECORDS (record-grouped k-fold or a single fixed record split) to
measure honest cross-patient generalization. Here the goal is narrower and
diagnostic: starting from a small seed set of records, add candidate records
into the training pool one at a time; after each addition, retrain and check
accuracy on windows drawn from every record CURRENTLY in the pool that were
never used to fit the model. If accuracy dips, the candidate is rejected and
the pool continues without it. The resulting number answers "does adding
this record's windows make the model worse at describing the records already
in the pool" -- i.e. whether a record is internally inconsistent with the
rest of the cohort under this feature set, not whether the pool generalizes
to unseen patients. Do not read the final accuracy here as a substitute for
the project's record-grouped honest metrics -- it is a different, narrower
measurement, and it is expected to look better than cross-record numbers
because windows from an already-seen record share that record's amplitude
scale, equipment, and local dynamics with its own held-out windows.

Per-record window split (fixed once, never touched by the search): windows
are grouped back into contiguous chronological episodes (a gap in `start`
larger than the window stride marks a new episode -- episode ids are not
carried into the cached rows, so this reconstructs them). Each episode with
at least MIN_EPISODE_WINDOWS windows is split chronologically 70% train /
30% held-out, with BUFFER_WINDOWS windows dropped on each side of the cut so
that no train window and no held-out window ever overlap in time (windows
are 2.0s wide on a 1.0s stride, so adjacent windows share 1.0s of signal;
dropping 1 window on each side removes every overlapping pair). Episodes
shorter than the minimum contribute training windows only.

Reuses the exact feature bank and extraction already verified in
`vt_vf_temporal_stability_feature_experiment.py` (18 features: the old 4
morphology features plus the 14 new temporal-stability features), loading
its cache file if present rather than re-extracting from the raw databases.
Modifies no existing file.

Run:
    python vt_vf_greedy_record_inclusion_window_holdout.py \\
        --databases-root E:/Thesis/databases \\
        --output-dir final_high_power_design/greedy_record_inclusion_2026_09_27
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from sklearn.metrics import accuracy_score, balanced_accuracy_score, precision_score, recall_score

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_temporal_stability_feature_experiment as tsf

VT_LABEL = tsf.VT_LABEL
VF_LABEL = tsf.VF_LABEL
ALL_FEATURE_NAMES = tsf.ALL_FEATURE_NAMES

MIN_EPISODE_WINDOWS = 10
BUFFER_WINDOWS = 1
TRAIN_FRACTION = 0.7
DEFAULT_C = 1.0
ORDER_SEED = tsf.RANDOM_STATE


def load_dataset(databases_root: Path, cache_path: Path) -> tuple[list[dict], np.ndarray]:
    if cache_path.exists():
        print(f"Loading cached extraction from {cache_path}")
        payload = np.load(cache_path, allow_pickle=True)
        return list(payload["rows"]), payload["features"]
    print("No cache found -- extracting from raw databases (shared with the temporal-stability script)")
    rows, features = tsf.extract_dataset(databases_root)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(cache_path, rows=np.array(rows, dtype=object), features=features)
    print(f"Cached to {cache_path}")
    return rows, features


def build_within_record_split(rows: list[dict]) -> tuple[dict, dict]:
    """Returns (record_to_train_idx, record_to_test_idx), both {record_id: np.ndarray of row indices}."""
    stride_samples = int(round(tsf.STRIDE_SECONDS * tsf.ANALYSIS_FS))

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
            test_part = segment[split_point + BUFFER_WINDOWS :]
            if not train_part or not test_part:
                record_train[record_id].extend(segment)
                continue
            record_train[record_id].extend(train_part)
            record_test[record_id].extend(test_part)

    record_train = {k: np.array(v, dtype=np.int64) for k, v in record_train.items() if v}
    record_test = {k: np.array(v, dtype=np.int64) for k, v in record_test.items() if v}
    return record_train, record_test


def fit_and_score(
    included: list[str],
    features: np.ndarray,
    labels: np.ndarray,
    record_train: dict,
    record_test: dict,
    c_value: float,
) -> dict | None:
    train_idx = np.concatenate([record_train[r] for r in included if r in record_train])
    test_idx = np.concatenate([record_test[r] for r in included if r in record_test])
    if train_idx.size == 0 or test_idx.size == 0:
        return None
    y_train = labels[train_idx]
    if np.unique(y_train).size < 2:
        return None
    y_test = labels[test_idx]

    model = exp.make_model(c_value)
    model.fit(features[train_idx], y_train)
    predictions = model.predict(features[test_idx])

    result = {
        "n_train_windows": int(train_idx.size),
        "n_test_windows": int(test_idx.size),
        "accuracy": float(accuracy_score(y_test, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(y_test, predictions)),
    }
    if (y_test == VT_LABEL).any():
        result["vt_recall"] = float(recall_score(y_test, predictions, pos_label=VT_LABEL))
    else:
        result["vt_recall"] = float("nan")
    if (y_test == VF_LABEL).any():
        result["vf_recall"] = float(recall_score(y_test, predictions, pos_label=VF_LABEL))
    else:
        result["vf_recall"] = float("nan")
    result["vt_precision"] = float(precision_score(y_test, predictions, pos_label=VT_LABEL, zero_division=0))
    result["vf_precision"] = float(precision_score(y_test, predictions, pos_label=VF_LABEL, zero_division=0))
    return result


def pick_seed_records(candidates: list[str], labels_by_record: dict, rng: np.random.Generator, count_per_class: int = 2) -> list[str]:
    vt_pool = [r for r in candidates if labels_by_record[r] == "VT"]
    vf_pool = [r for r in candidates if labels_by_record[r] == "VF_FAMILY"]
    seed = list(rng.choice(vt_pool, size=min(count_per_class, len(vt_pool)), replace=False))
    seed += list(rng.choice(vf_pool, size=min(count_per_class, len(vf_pool)), replace=False))
    return seed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--databases-root", type=Path, default=Path("E:/Thesis/databases"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=None)
    parser.add_argument("--c-value", type=float, default=DEFAULT_C)
    parser.add_argument("--acceptance-metric", choices=["accuracy", "balanced_accuracy"], default="balanced_accuracy")
    parser.add_argument("--tolerance", type=float, default=0.0, help="reject a candidate if the metric drops by more than this")
    parser.add_argument("--floor", type=float, default=None,
                         help="if set, ignore --tolerance: accept any candidate whose resulting metric stays >= floor "
                              "(lets the metric degrade from its current value, only rejects a drop below the floor itself)")
    parser.add_argument("--order-seed", type=int, default=ORDER_SEED)
    parser.add_argument("--seed-per-class", type=int, default=2)
    parser.add_argument("--features", type=str, default=None,
                         help="comma-separated subset of ALL_FEATURE_NAMES to use; default is all 18")
    arguments = parser.parse_args()

    output = arguments.output_dir
    output.mkdir(parents=True, exist_ok=True)
    cache = arguments.cache or (Path("final_high_power_design") / "temporal_stability_raw_cache.npz")

    rows, features = load_dataset(arguments.databases_root, cache)
    labels = np.array([row["label"] for row in rows], dtype=np.int64)

    if arguments.features:
        selected_names = [name.strip() for name in arguments.features.split(",")]
        unknown = [name for name in selected_names if name not in ALL_FEATURE_NAMES]
        if unknown:
            raise SystemExit(f"Unknown feature name(s): {unknown}. Valid names: {ALL_FEATURE_NAMES}")
        columns = [ALL_FEATURE_NAMES.index(name) for name in selected_names]
        features = features[:, columns]
        print(f"Using {len(selected_names)} of {len(ALL_FEATURE_NAMES)} features: {selected_names}")
    else:
        print(f"Using all {len(ALL_FEATURE_NAMES)} features: {ALL_FEATURE_NAMES}")

    print(f"Loaded {len(rows)} windows across {len({r['record_id'] for r in rows})} records, {features.shape[1]} feature columns selected")

    record_train, record_test = build_within_record_split(rows)
    all_records = sorted(set(record_train) | set(record_test))
    trainable_records = [r for r in all_records if r in record_train]
    testable_records = set(record_test)
    print(f"{len(trainable_records)} records have trainable windows; {len(testable_records)} of those also have held-out windows")

    label_by_record: dict[str, str] = {}
    for row in rows:
        label_by_record.setdefault(row["record_id"], "VT" if row["label"] == VT_LABEL else "VF_FAMILY")

    rng = np.random.default_rng(arguments.order_seed)
    candidates_with_test = [r for r in trainable_records if r in testable_records]
    seed_records = pick_seed_records(candidates_with_test, label_by_record, rng, arguments.seed_per_class)
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
          f"(train={baseline['n_train_windows']}, test={baseline['n_test_windows']})")

    for step, candidate in enumerate(remaining, start=1):
        tentative = included + [candidate]
        metric_before = baseline[arguments.acceptance_metric]
        result = fit_and_score(tentative, features, labels, record_train, record_test, arguments.c_value)
        if result is None:
            action = "skipped_no_test_windows"
            log_rows.append({
                "step": step, "record_id": candidate, "action": action,
                "n_included_records": len(included), "n_train_windows": None, "n_test_windows": None,
                "accuracy": None, "balanced_accuracy": None, "vt_recall": None, "vf_recall": None,
                "metric_before": metric_before, "delta": None,
            })
            included = tentative  # still add its training windows; it has no test windows to hurt/help
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
              f"(train={result['n_train_windows']}, test={result['n_test_windows']})")

    csv_path = output / "greedy_inclusion_log.csv"
    fieldnames = ["step", "record_id", "action", "n_included_records", "n_train_windows", "n_test_windows",
                  "accuracy", "balanced_accuracy", "vt_recall", "vf_recall", "vt_precision", "vf_precision",
                  "metric_before", "delta"]
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in log_rows:
            writer.writerow({k: row.get(k) for k in fieldnames})
    print(f"\nWrote {csv_path}")

    accepted_steps = [r for r in log_rows if r["action"] in ("seed", "accepted")]
    rejected_steps = [r for r in log_rows if r["action"] == "rejected"]

    fig, axis = plt.subplots(figsize=(10, 5), dpi=140)
    axis.plot(
        [r["n_included_records"] for r in accepted_steps],
        [r[arguments.acceptance_metric] for r in accepted_steps],
        marker="o", color="#2e8b57", label="accepted pool",
    )
    if rejected_steps:
        axis.scatter(
            [r["n_included_records"] for r in rejected_steps],
            [r[arguments.acceptance_metric] for r in rejected_steps],
            marker="x", color="#8b2e2e", s=45, label="rejected attempt (metric it would have produced)", zorder=3,
        )
    axis.set_xlabel("records in training pool")
    axis.set_ylabel(arguments.acceptance_metric)
    axis.set_title("Greedy record inclusion: within-pool held-out-window accuracy\n"
                    "(held-out windows are from records already in the pool -- not new unseen records)")
    axis.legend()
    axis.grid(alpha=0.3)
    fig.tight_layout()
    plot_path = output / "greedy_inclusion_trajectory.png"
    fig.savefig(plot_path)
    plt.close(fig)
    print(f"Wrote {plot_path}")

    rejected_records = [r["record_id"] for r in log_rows if r["action"] == "rejected"]
    summary = {
        "acceptance_metric": arguments.acceptance_metric,
        "tolerance": arguments.tolerance,
        "floor": arguments.floor,
        "c_value": arguments.c_value,
        "seed_records": seed_records,
        "order_seed": arguments.order_seed,
        "final_included_count": len(included),
        "final_metric": baseline[arguments.acceptance_metric],
        "final_accuracy": baseline["accuracy"],
        "final_balanced_accuracy": baseline["balanced_accuracy"],
        "final_vt_recall": baseline["vt_recall"],
        "final_vf_recall": baseline["vf_recall"],
        "final_vt_precision": baseline["vt_precision"],
        "final_vf_precision": baseline["vf_precision"],
        "final_train_windows": baseline["n_train_windows"],
        "final_test_windows": baseline["n_test_windows"],
        "rejected_count": len(rejected_records),
        "rejected_records": rejected_records,
    }
    summary_path = output / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2), encoding="ascii")
    print(f"Wrote {summary_path}")

    print(f"\nFinal pool: {len(included)} records, {arguments.acceptance_metric}={baseline[arguments.acceptance_metric]:.4f}")
    print(f"  accuracy={baseline['accuracy']:.4f}  balanced_accuracy={baseline['balanced_accuracy']:.4f}")
    print(f"  VT precision={baseline['vt_precision']:.4f}  VT recall={baseline['vt_recall']:.4f}")
    print(f"  VF precision={baseline['vf_precision']:.4f}  VF recall={baseline['vf_recall']:.4f}")
    print(f"Rejected {len(rejected_records)} records: {rejected_records}")


if __name__ == "__main__":
    main()
