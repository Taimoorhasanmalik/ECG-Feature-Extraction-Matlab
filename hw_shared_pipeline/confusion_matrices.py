"""Confusion matrices for Stage 1 and Stage 2 of the final design, using every
window available under inclusion rules fixed BEFORE looking at model output.

Stage 1 (deployed model, Normal vs Abnormal):
  - official protocol (eval_shared_stage1_seq.m, deployed model + CPU export):
    test 21 records, train 84, train + test 105
  - every labelled window of all 105 records (evaluate_whole_database.m),
    per window and after the 2-of-3 gate, by split and by database
Stage 2 (final 1 Hz model, VT vs VF):
  - every window of every record (MITDB, VFDB, CUDB) that passes Stage 2's own
    window rules: inside an annotated VT or VF-family interval, closed
    interval, no invalid samples, no annotated noise, before the first shock.
    Same front end and feature engine as build_stage2_shared.py.
  - deployed all-data model, and "honest" (leave-one-record-out weights for the
    38 pool records; every other record is already unseen by the model)
  - reported by record group: curated pool, dropped from pool, the 8 noisy
    VFDB records, other unused VFDB/CUDB records, MIT-BIH.

No data is included or excluded based on whether a model classifies it
correctly. Modifies no existing file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "greedy_record_inclusion"))
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "stage2"))
import build_stage2_shared as s2
import extract_shared_candidates as esc
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
from vt_vf_seed96_record_holdout_validation import SEED96_ORDER

OUT_DIR = HERE / "results"
FIG_DIR = Path("E:/Thesis/Publication_Figures")
CACHE = OUT_DIR / "stage2_all_records_windows.npz"
DROPPED = {"vfdb/610", "cudb/cu18"}
NOISY = {"vfdb/420", "vfdb/421", "vfdb/422", "vfdb/423", "vfdb/427", "vfdb/430", "vfdb/602", "vfdb/612"}
POOL = [r for r in SEED96_ORDER if r not in DROPPED]
HOLDOUT = {"vfdb/615", "vfdb/429", "cudb/cu13", "cudb/cu32"}

# Official-protocol Stage 1 results (2-of-3 hard rule, deployed model + CPU
# export), from eval_shared_stage1_seq.m with ECG_EVAL_SPLIT = test / train / all.
# [[TN, FP], [FN, TP]]; the test row reproduces the paper's 95.32% exactly.
STAGE1_OFFICIAL = {
    "test (21 records)": [[7177, 429], [52, 2627]],
    "train (84 records)": [[18715, 4498], [198, 10440]],
    "train + test (105 records)": [[25892, 4927], [250, 13067]],
}


def group_of(record_id):
    if record_id.startswith("mitdb/"):
        return "MIT-BIH (never used by Stage 2)"
    if record_id in NOISY:
        return "8 noisy VFDB records (excluded)"
    if record_id in DROPPED:
        return "dropped from pool (vfdb/610, cudb/cu18)"
    if record_id in POOL:
        return "curated pool (38)"
    return "other unused VFDB/CUDB"


def extract_stage2_all():
    import wfdb

    deploy = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_alldata.mat")
    bits = deploy["feature_integer_bits"].ravel().astype(int)
    rows = {"record": [], "start": [], "label": [], "features": []}
    for db in ("mitdb", "vfdb", "cudb"):
        for record_path in exp.record_bases(Path("E:/Thesis/databases") / exp.DB_FOLDERS[db]):
            record_id = f"{db}/{record_path.name}"
            header = wfdb.rdheader(str(record_path))
            ann = wfdb.rdann(str(record_path), "atr")
            raw = np.asarray(wfdb.rdrecord(str(record_path)).p_signal[:, 0], dtype=np.float64)
            fs0 = float(header.fs)
            filtered = s2.shared_front_end(raw, fs0)
            starts, labels = esc.stage2_windows(db, record_id, ann, ~np.isfinite(raw), fs0, filtered.size)
            if starts.size:
                f = s2.engine(esc.window_matrix(filtered, starts))
                f = np.column_stack([s2.q(f[:, k], bits[k], 8) for k in range(f.shape[1])])
                rows["record"] += [record_id] * starts.size
                rows["start"].append(starts)
                rows["label"].append(labels)
                rows["features"].append(f)
            print(f"    {record_id}: {starts.size} VT/VF windows", flush=True)
    np.savez_compressed(CACHE, record=np.array(rows["record"]), start=np.concatenate(rows["start"]),
                        label=np.concatenate(rows["label"]), features=np.vstack(rows["features"]))


def binary_cm(truth, pred):
    return [[int(np.sum(~truth & ~pred)), int(np.sum(~truth & pred))],
            [int(np.sum(truth & ~pred)), int(np.sum(truth & pred))]]


def metrics(cm):
    (tn, fp), (fn, tp) = cm
    n = tn + fp + fn + tp
    p = tp / max(tp + fp, 1)
    r = tp / max(tp + fn, 1)
    return dict(n=n, accuracy=(tp + tn) / max(n, 1), precision=p, sensitivity=r,
                specificity=tn / max(tn + fp, 1), f1=2 * p * r / max(p + r, 1e-12))


def stage2_matrices():
    if not CACHE.exists():
        extract_stage2_all()
    c = np.load(CACHE)
    rec, y, x = c["record"], c["label"], c["features"]
    deploy = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_alldata.mat")
    loro = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_loro_weights.mat")
    vt, vf = int(deploy["vt_label"].ravel()[0]), int(deploy["vf_label"].ravel()[0])
    pred_deploy = np.where(x @ deploy["combined_weight_q"].ravel() + float(deploy["combined_bias_q"].ravel()[0]) > 0, vf, vt)
    pred_honest = pred_deploy.copy()
    loro_ids = np.array([str(np.atleast_1d(r)[0]).strip() for r in loro["record_id"].ravel()])
    for i, r in enumerate(loro_ids):
        m = rec == r
        pred_honest[m] = np.where(x[m] @ loro["weight_q"][i] + float(loro["bias_q"][i][0]) > 0, vf, vt)
    groups = np.array([group_of(r) for r in rec])
    out = {}
    scopes = {"curated pool (38), train + test": groups == "curated pool (38)",
              "curated pool, train (34)": (groups == "curated pool (38)") & ~np.isin(rec, list(HOLDOUT)),
              "curated pool, test (4)": np.isin(rec, list(HOLDOUT)),
              "all records, every eligible window": np.ones(rec.size, bool)}
    for g in sorted(set(groups)):
        scopes[f"group: {g}"] = groups == g
    for name, mask in scopes.items():
        for model, pred in (("deployed", pred_deploy), ("honest", pred_honest)):
            truth = y[mask] == vt                       # positive class = VT
            cm = binary_cm(truth, pred[mask] == vt)
            out[f"{name} | {model}"] = dict(cm=cm, records=int(len(set(rec[mask]))), **metrics(cm))
    return out


def stage1_matrices():
    w = scipy.io.loadmat(HERE / "results" / "whole_database_windows.mat")
    R = w["results"]
    names = []
    for folder, alias in (("mit-bih-arrhythmia-database-1.0.0", "mitdb"),
                          ("mit-bih-malignant-ventricular-ectopy-database-1.0.0", "vfdb"),
                          ("cu-ventricular-tachyarrhythmia-database-1.0.0", "cudb")):
        names += [alias for _ in sorted((Path("E:/Thesis/databases") / folder).glob("*.hea"))]
    db = np.array(names)[R[:, 0].astype(int) - 1]
    labelled = R[:, 3] >= 0
    truth = R[:, 3] >= 1
    out = {}
    for name, cm in STAGE1_OFFICIAL.items():
        out[f"official protocol, {name} | 2-of-3 gate"] = dict(cm=cm, **metrics(cm))
    scopes = {"every window, test (21 records)": R[:, 1] == 1, "every window, train (84 records)": R[:, 1] == 0,
              "every window, train + test (105 records)": np.ones(len(R), bool)}
    for d in ("mitdb", "vfdb", "cudb"):
        scopes[f"every window, {d} only"] = db == d
    for name, mask in scopes.items():
        m = mask & labelled
        for rule, col in (("per window", 4), ("2-of-3 gate", 5)):
            cm = binary_cm(truth[m], R[m, col] == 1)
            out[f"{name} | {rule}"] = dict(cm=cm, **metrics(cm))
    return out


def draw(ax, cm, row_labels, col_labels, title):
    import matplotlib.colors as mcolors

    ramp = ["#fcfcfb", "#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
    cmap = mcolors.LinearSegmentedColormap.from_list("seq_blue", ramp)
    cm = np.asarray(cm, dtype=float)
    share = cm / np.maximum(cm.sum(axis=1, keepdims=True), 1)
    ax.pcolormesh(share, cmap=cmap, vmin=0, vmax=1, edgecolors="#fcfcfb", linewidth=2)
    for i in range(2):
        for j in range(2):
            dark = share[i, j] > 0.55
            ink = "#ffffff" if dark else "#0b0b0b"
            sub = "#e6eefb" if dark else "#52514e"
            ax.text(j + 0.5, i + 0.42, f"{int(cm[i, j]):,}", ha="center", va="center", fontsize=15, fontweight="bold", color=ink)
            ax.text(j + 0.5, i + 0.66, f"{100 * share[i, j]:.1f}%", ha="center", va="center", fontsize=11, color=sub)
    ax.set_xticks([0.5, 1.5], col_labels, fontsize=11)
    ax.set_yticks([0.5, 1.5], row_labels, fontsize=11, rotation=90, va="center")
    ax.set_xlim(0, 2)
    ax.set_ylim(2, 0)
    ax.xaxis.set_ticks_position("top")
    ax.xaxis.set_label_position("top")
    ax.set_xlabel("Predicted", fontsize=11, color="#52514e", labelpad=6)
    ax.set_ylabel("True", fontsize=11, color="#52514e")
    ax.tick_params(length=0, colors="#0b0b0b")
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_title(title, fontsize=11.5, color="#0b0b0b", pad=46, loc="left")


def caption(m, stage):
    if stage == 1:
        return (f"acc {m['accuracy']:.3f} · sens {m['sensitivity']:.3f} · spec {m['specificity']:.3f}\n"
                f"prec {m['precision']:.3f} · F1 {m['f1']:.3f} · n = {m['n']:,}")
    return (f"acc {m['accuracy']:.3f} · VT sens {m['sensitivity']:.3f} · VF sens {m['specificity']:.3f}\n"
            f"VT prec {m['precision']:.3f} · VT F1 {m['f1']:.3f} · n = {m['n']:,}")


def figure(panels, stage, path, suptitle):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams["font.family"] = "serif"
    plt.rcParams["font.serif"] = ["Times New Roman", "DejaVu Serif"]
    cols = 2
    rows = (len(panels) + 1) // 2
    fig, axes = plt.subplots(rows, cols, figsize=(10, 4.7 * rows), facecolor="#fcfcfb")
    labels = (["Normal", "Abnormal"], ["Normal", "Abnormal"]) if stage == 1 else (["VF", "VT"], ["VF", "VT"])
    for ax, (title, m) in zip(np.ravel(axes), panels):
        ax.set_facecolor("#fcfcfb")
        draw(ax, m["cm"], labels[0], labels[1], title)
        ax.text(0, 2.12, caption(m, stage), transform=ax.transData, va="top", fontsize=10.5, color="#52514e")
    for ax in np.ravel(axes)[len(panels):]:
        ax.axis("off")
    fig.suptitle(suptitle, fontsize=14, x=0.02, ha="left", color="#0b0b0b")
    fig.tight_layout(rect=(0, 0, 1, 0.96), h_pad=4.5, w_pad=4)
    fig.savefig(path, dpi=200, facecolor=fig.get_facecolor())
    plt.close(fig)


def main():
    s1 = stage1_matrices()
    s2m = stage2_matrices()
    OUT_DIR.mkdir(exist_ok=True)
    (OUT_DIR / "confusion_matrices.json").write_text(json.dumps({"stage1": s1, "stage2": s2m}, indent=1))

    for title, store in (("STAGE 1 (positive = Abnormal)", s1), ("STAGE 2 (positive = VT)", s2m)):
        print(f"\n===== {title} =====")
        for k, m in store.items():
            (tn, fp), (fn, tp) = m["cm"]
            recs = f" recs={m['records']:<3}" if "records" in m else ""
            print(f"{k:<75}{recs} [[{tn:>7} {fp:>6}] [{fn:>6} {tp:>6}]] acc {m['accuracy']:.4f} prec {m['precision']:.4f} "
                  f"sens {m['sensitivity']:.4f} spec {m['specificity']:.4f} F1 {m['f1']:.4f}")

    figure([("Official protocol · test (21 records)", s1["official protocol, test (21 records) | 2-of-3 gate"]),
            ("Official protocol · train + test (105 records)", s1["official protocol, train + test (105 records) | 2-of-3 gate"]),
            ("Every window · test (21 records)", s1["every window, test (21 records) | 2-of-3 gate"]),
            ("Every window · train + test (105 records)", s1["every window, train + test (105 records) | 2-of-3 gate"])],
           1, FIG_DIR / "confusion_stage1.png", "Stage 1: Normal vs Abnormal, after the 2-of-3 gate (deployed model)")
    figure([("Curated pool · train + test (38 records) · deployed", s2m["curated pool (38), train + test | deployed"]),
            ("Curated pool · leave-one-record-out", s2m["curated pool (38), train + test | honest"]),
            ("All eligible windows, all records · deployed", s2m["all records, every eligible window | deployed"]),
            ("All eligible windows · honest (LORO in pool)", s2m["all records, every eligible window | honest"])],
           2, FIG_DIR / "confusion_stage2.png", "Stage 2: VT vs VF (final 1 Hz model, fixed-point weights)")
    print(f"\nWrote {OUT_DIR / 'confusion_matrices.json'}\nWrote {FIG_DIR / 'confusion_stage1.png'} and confusion_stage2.png")


if __name__ == "__main__":
    main()
