"""Long-term (wearable) confusion matrices for the final two-stage design.

Unit = what a wearable reports over time, with labelling rules fixed from the
annotations before looking at any prediction:

  Stage 1, per 1-minute block (60 consecutive 1 s windows of a record):
      abnormal block: >= 10 s of truly abnormal (VT/VF) windows
      normal block:   no abnormal window in the block or within 5 s of its edges
      other blocks (only a few seconds of VT/VF) are left out
      predicted abnormal: the 2-of-3 gate fired at least once in the block
  Stage 2, per true VT/VF episode (Stage 2's own episode windows):
      predicted label = majority vote of the episode's window decisions
  Combined, per 1-minute block, 3 classes:
      VT / VF block: >= 10 s of annotated VT (resp. VF) and more of it than the
      other class; Normal block as above; others left out
      prediction: gate never fired -> Normal, else majority Stage 2 label over
      the gated windows in the block

No retraining; uses whole_database_windows.mat and stage2_all_records_windows.npz.
Modifies no existing file.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from confusion_matrices import CACHE, FIG_DIR, HOLDOUT, OUT_DIR, POOL
from report_train_test_metrics import matlab_record_names

BLOCK = 60
MIN_ABN = 10
PAD = 5


def block_slices(n):
    return [(s, min(s + BLOCK, n)) for s in range(0, n - BLOCK + 1, BLOCK)]


def stage1_blocks(R, rec, scope):
    truth_list, pred_list = [], []
    for r in np.unique(rec[scope]):
        rows = np.flatnonzero(rec == r)
        abn = R[rows, 3] >= 1
        gate = R[rows, 5] == 1
        for s, e in block_slices(rows.size):
            n_abn = abn[s:e].sum()
            if n_abn >= MIN_ABN:
                truth_list.append(True)
            elif not abn[max(0, s - PAD):min(rows.size, e + PAD)].any():
                truth_list.append(False)
            else:
                continue
            pred_list.append(gate[s:e].any())
    t, p = np.array(truth_list), np.array(pred_list)
    return [[int(np.sum(~t & ~p)), int(np.sum(~t & p))], [int(np.sum(t & ~p)), int(np.sum(t & p))]]


def combined_blocks(R, rec, scope, col):
    vt = int(R[:, 6].min())
    cm = np.zeros((3, 3), int)                       # rows/cols: Normal, VT, VF
    for r in np.unique(rec[scope]):
        rows = np.flatnonzero(rec == r)
        truth = R[rows, 3].astype(int)
        lead_in = R[rows, 8] == 1
        any_abn = truth >= 1
        gate = R[rows, 5] == 1
        s2 = R[rows, col]
        for s, e in block_slices(rows.size):
            n_vt = np.sum((truth[s:e] == 1) & ~lead_in[s:e])
            n_vf = np.sum(truth[s:e] == 2)
            if n_vt >= MIN_ABN and n_vt > n_vf:
                t = 1
            elif n_vf >= MIN_ABN and n_vf >= n_vt:
                t = 2
            elif not any_abn[max(0, s - PAD):min(rows.size, e + PAD)].any():
                t = 0
            else:
                continue
            g = gate[s:e]
            p = 0 if not g.any() else (1 if np.mean(s2[s:e][g] == vt) > 0.5 else 2)
            cm[t, p] += 1
    return cm.tolist()


def stage2_episodes(scope_fn, honest):
    c = np.load(CACHE)
    rec, start, y, x = c["record"], c["start"], c["label"], c["features"]
    deploy = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_alldata.mat")
    vt, vf = int(deploy["vt_label"].ravel()[0]), int(deploy["vf_label"].ravel()[0])
    pred = np.where(x @ deploy["combined_weight_q"].ravel() + float(deploy["combined_bias_q"].ravel()[0]) > 0, vf, vt)
    if honest:
        loro = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_loro_weights.mat")
        for i, r in enumerate(str(np.atleast_1d(v)[0]).strip() for v in loro["record_id"].ravel()):
            m = rec == r
            pred[m] = np.where(x[m] @ loro["weight_q"][i] + float(loro["bias_q"][i][0]) > 0, vf, vt)
    cm = np.zeros((2, 2), int)                       # rows/cols: VF, VT
    for r in np.unique(rec):
        if not scope_fn(r):
            continue
        idx = np.flatnonzero(rec == r)
        idx = idx[np.argsort(start[idx])]
        b = 0
        for k in range(1, idx.size + 1):
            if k == idx.size or start[idx[k]] - start[idx[k - 1]] != 120 or y[idx[k]] != y[idx[k - 1]]:
                seg = idx[b:k]
                t = 1 if y[seg[0]] == vt else 0
                p = 1 if np.mean(pred[seg] == vt) > 0.5 else 0
                cm[t, p] += 1
                b = k
    return cm.tolist()


def binary_metrics(cm):
    (tn, fp), (fn, tp) = cm
    n = tn + fp + fn + tp
    p, r = tp / max(tp + fp, 1), tp / max(tp + fn, 1)
    return dict(n=n, accuracy=(tp + tn) / max(n, 1), precision=p, sensitivity=r,
                specificity=tn / max(tn + fp, 1), f1=2 * p * r / max(p + r, 1e-12))


def multiclass_metrics(cm):
    cm = np.asarray(cm)
    out = {"n": int(cm.sum()), "accuracy": float(np.trace(cm) / max(cm.sum(), 1)), "classes": {}}
    for i, name in enumerate(["Normal", "VT", "VF"]):
        tp = cm[i, i]
        p = tp / max(cm[:, i].sum(), 1)
        r = tp / max(cm[i, :].sum(), 1)
        out["classes"][name] = dict(precision=float(p), recall=float(r), f1=float(2 * p * r / max(p + r, 1e-12)))
    out["macro_f1"] = float(np.mean([v["f1"] for v in out["classes"].values()]))
    return out


def draw(ax, cm, labels, title):
    import matplotlib.colors as mcolors

    ramp = ["#fcfcfb", "#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
    cmap = mcolors.LinearSegmentedColormap.from_list("seq_blue", ramp)
    cm = np.asarray(cm, dtype=float)
    k = cm.shape[0]
    share = cm / np.maximum(cm.sum(axis=1, keepdims=True), 1)
    ax.pcolormesh(share, cmap=cmap, vmin=0, vmax=1, edgecolors="#fcfcfb", linewidth=2)
    big = 15 if k == 2 else 13
    for i in range(k):
        for j in range(k):
            dark = share[i, j] > 0.55
            ax.text(j + 0.5, i + 0.42, f"{int(cm[i, j]):,}", ha="center", va="center", fontsize=big, fontweight="bold",
                    color="#ffffff" if dark else "#0b0b0b")
            ax.text(j + 0.5, i + 0.68, f"{100 * share[i, j]:.1f}%", ha="center", va="center", fontsize=10.5,
                    color="#e6eefb" if dark else "#52514e")
    ax.set_xticks(np.arange(k) + 0.5, labels[1], fontsize=11)
    ax.set_yticks(np.arange(k) + 0.5, labels[0], fontsize=11, rotation=90, va="center")
    ax.set_xlim(0, k)
    ax.set_ylim(k, 0)
    ax.xaxis.set_ticks_position("top")
    ax.xaxis.set_label_position("top")
    ax.set_xlabel("Predicted", fontsize=11, color="#52514e", labelpad=6)
    ax.set_ylabel("True", fontsize=11, color="#52514e")
    ax.tick_params(length=0, colors="#0b0b0b")
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_title(title, fontsize=11.5, color="#0b0b0b", pad=46, loc="left")


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    w = scipy.io.loadmat(HERE / "results" / "whole_database_windows.mat")
    R = w["results"]
    rec = matlab_record_names()[R[:, 0].astype(int) - 1]
    everything = np.ones(len(R), bool)
    pool = R[:, 2] == 1

    s1_all = stage1_blocks(R, rec, everything)
    s1_test = stage1_blocks(R, rec, R[:, 1] == 1)
    s2_pool = stage2_episodes(lambda r: r in POOL, honest=False)
    s2_pool_loro = stage2_episodes(lambda r: r in POOL, honest=True)
    s2_all = stage2_episodes(lambda r: True, honest=False)
    c_pool = combined_blocks(R, rec, pool, 6)
    c_all = combined_blocks(R, rec, everything, 6)

    results = {
        "stage1_minutes_all105": dict(cm=s1_all, **binary_metrics(s1_all)),
        "stage1_minutes_test21": dict(cm=s1_test, **binary_metrics(s1_test)),
        "stage2_episodes_pool_deployed": dict(cm=s2_pool, **binary_metrics(s2_pool)),
        "stage2_episodes_pool_loro": dict(cm=s2_pool_loro, **binary_metrics(s2_pool_loro)),
        "stage2_episodes_all_deployed": dict(cm=s2_all, **binary_metrics(s2_all)),
        "combined_minutes_pool38": dict(cm=c_pool, **multiclass_metrics(c_pool)),
        "combined_minutes_all105": dict(cm=c_all, **multiclass_metrics(c_all)),
    }
    (OUT_DIR / "long_term_confusion.json").write_text(json.dumps(results, indent=1))
    for k, v in results.items():
        print(k, v)

    plt.rcParams["font.family"] = "serif"
    plt.rcParams["font.serif"] = ["Times New Roman", "DejaVu Serif"]
    fig, axes = plt.subplots(3, 2, figsize=(10.5, 15), facecolor="#fcfcfb")
    panels = [
        (s1_all, (["Normal", "Abnormal"],) * 2, "Stage 1 · per minute · all 105 records", "s1"),
        (s1_test, (["Normal", "Abnormal"],) * 2, "Stage 1 · per minute · test records (21)", "s1"),
        (s2_pool, (["VF", "VT"],) * 2, "Stage 2 · per episode · curated pool (38)", "s2"),
        (s2_all, (["VF", "VT"],) * 2, "Stage 2 · per episode · all records", "s2"),
        (c_pool, (["Normal", "VT", "VF"],) * 2, "Combined · per minute · curated pool (38)", "c"),
        (c_all, (["Normal", "VT", "VF"],) * 2, "Combined · per minute · all 105 records", "c"),
    ]
    for ax, (cm, labels, title, kind) in zip(axes.ravel(), panels):
        ax.set_facecolor("#fcfcfb")
        draw(ax, cm, labels, title)
        k = len(cm)
        if kind == "s1":
            m = binary_metrics(cm)
            text = (f"acc {m['accuracy']:.3f} · sens {m['sensitivity']:.3f} · spec {m['specificity']:.3f}\n"
                    f"prec {m['precision']:.3f} · F1 {m['f1']:.3f} · n = {m['n']:,} minutes")
        elif kind == "s2":
            m = binary_metrics(cm)
            text = (f"acc {m['accuracy']:.3f} · VT sens {m['sensitivity']:.3f} · VF sens {m['specificity']:.3f}\n"
                    f"VT prec {m['precision']:.3f} · VT F1 {m['f1']:.3f} · n = {m['n']:,} episodes")
        else:
            m = multiclass_metrics(cm)
            text = (f"acc {m['accuracy']:.3f} · macro F1 {m['macro_f1']:.3f} · n = {m['n']:,} minutes\n"
                    f"VT P/R {m['classes']['VT']['precision']:.2f}/{m['classes']['VT']['recall']:.2f} · "
                    f"VF P/R {m['classes']['VF']['precision']:.2f}/{m['classes']['VF']['recall']:.2f}")
        ax.text(0, k * 1.06, text, transform=ax.transData, va="top", fontsize=10.5, color="#52514e")
    fig.suptitle("Long-term (wearable) view: per minute of recording and per episode", fontsize=14, x=0.02, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.97), h_pad=4.5, w_pad=4)
    out = FIG_DIR / "confusion_longterm.png"
    fig.savefig(out, dpi=200, facecolor=fig.get_facecolor())
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
