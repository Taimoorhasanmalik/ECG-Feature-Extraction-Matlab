"""Train / test / train+test metrics for each model on the data it was built
on, using the saved fixed-point models (no retraining):

  Stage 1 (streaming): every window of all 105 records (Stage 1's 84 train +
      21 test records), from results/whole_database_windows.mat.
  Stage 2: its 38-record pool (34 train + 4 test) with its own episode
      windows and fixed-point weights from stage2/results: the holdout model
      (trained on the 34), the deployed all-data model, and leave-one-record-out.
  Combined: the 38 records in both stages' train/test sets, every window
      (Normal / VT / VF, annotated labels), from whole_database_windows.mat.

Reports accuracy, precision, recall (= sensitivity), specificity and F1.
Modifies no existing file.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
HOLDOUT = {"vfdb/615", "vfdb/429", "cudb/cu13", "cudb/cu32"}
DB = Path("E:/Thesis/databases")


def binary(truth, pred):
    tp = int(np.sum(pred & truth)); fp = int(np.sum(pred & ~truth))
    fn = int(np.sum(~pred & truth)); tn = int(np.sum(~pred & ~truth))
    p = tp / max(tp + fp, 1); r = tp / max(tp + fn, 1)
    return dict(n=truth.size, acc=(tp + tn) / max(truth.size, 1), precision=p, recall=r,
                specificity=tn / max(tn + fp, 1), f1=2 * p * r / max(p + r, 1e-12))


def row(label, m):
    return (f"  {label:<34} n={m['n']:<7} acc {m['acc']:.4f} | precision {m['precision']:.4f} | "
            f"recall/sens {m['recall']:.4f} | specificity {m['specificity']:.4f} | F1 {m['f1']:.4f}")


def ids(arr):
    return np.array([str(np.atleast_1d(r)[0]).strip() for r in np.ravel(arr)])


def matlab_record_names():
    names = []
    for folder, alias in (("mit-bih-arrhythmia-database-1.0.0", "mitdb"),
                          ("mit-bih-malignant-ventricular-ectopy-database-1.0.0", "vfdb"),
                          ("cu-ventricular-tachyarrhythmia-database-1.0.0", "cudb")):
        names += [f"{alias}/{p.stem}" for p in sorted((DB / folder).glob("*.hea"))]
    return np.array(names)


def stage1(R):
    print("\n==================== STAGE 1 (streaming, every window, 105 records) ====================")
    for split, mask in (("train (84 records)", R[:, 1] == 0), ("test (21 records)", R[:, 1] == 1), ("train + test (105)", np.ones(len(R), bool))):
        rows = mask & (R[:, 3] >= 0)
        truth = R[rows, 3] >= 1
        print(f" {split}")
        print(row("per-window decision", binary(truth, R[rows, 4] == 1)))
        print(row("after 2-of-3 gate", binary(truth, R[rows, 5] == 1)))


def stage2():
    print("\n==================== STAGE 2 (own 38-record pool, own episode windows) ====================")
    alld = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_alldata.mat")
    hold = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_holdout.mat")
    loro = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_loro_weights.mat")
    x = alld["test_features_python"].astype(float)
    y = alld["test_true_label"].ravel().astype(int)
    rid = ids(alld["test_record_id"])
    vt, vf = int(alld["vt_label"].ravel()[0]), int(alld["vf_label"].ravel()[0])

    def predict(w, b, rows):
        return np.where(x[rows] @ np.ravel(w) + float(np.ravel(b)[0]) > 0, vf, vt)

    test = np.isin(rid, list(HOLDOUT))
    loro_ids = ids(loro["record_id"])
    loro_pred = np.zeros_like(y)
    for i, r in enumerate(loro_ids):
        m = rid == r
        loro_pred[m] = predict(loro["weight_q"][i], loro["bias_q"][i], m)

    models = {
        "holdout model (trained on 34 train records)": lambda m: predict(hold["combined_weight_q"], hold["combined_bias_q"], m),
        "deployed all-data model (trained on all 38)": lambda m: predict(alld["combined_weight_q"], alld["combined_bias_q"], m),
        "leave-one-record-out (each record unseen)": lambda m: loro_pred[m],
    }
    for name, fn in models.items():
        print(f" {name}")
        for split, mask in (("train (34)", ~test), ("test (4)", test), ("train + test (38)", np.ones(y.size, bool))):
            pred = fn(mask)
            truth = y[mask]
            print(f"  -- {split}: {int((truth == vt).sum())} VT / {int((truth == vf).sum())} VF windows, accuracy {np.mean(pred == truth):.4f}")
            print(row("    positive = VT", binary(truth == vt, pred == vt)))
            print(row("    positive = VF", binary(truth == vf, pred == vf)))


def combined(R, names):
    print("\n==================== COMBINED (38 records in both train/test sets, every window) ====================")
    rec = names[R[:, 0].astype(int) - 1]
    base = (R[:, 2] == 1) & (R[:, 8] == 0) & (R[:, 3] >= 0) & (R[:, 3] <= 2)
    labels = ["Normal", "VT", "VF"]
    for model, col in (("deployed all-data Stage 2", 6), ("leave-one-record-out Stage 2", 7)):
        print(f" {model}")
        for split, mask in (("train (34)", ~np.isin(rec, list(HOLDOUT))), ("test (4)", np.isin(rec, list(HOLDOUT))), ("train + test (38)", np.ones(len(R), bool))):
            rows = base & mask
            truth = R[rows, 3].astype(int)
            gate = R[rows, 5] == 1
            s2 = R[rows, col].astype(int)
            vt = int(np.min(R[:, 6]))
            pred = np.where(~gate, 0, np.where(s2 == vt, 1, 2))
            f1s = []
            print(f"  -- {split}: {int((truth == 0).sum())} Normal / {int((truth == 1).sum())} VT / {int((truth == 2).sum())} VF windows, "
                  f"overall accuracy {np.mean(pred == truth):.4f}")
            for c in range(3):
                m = binary(truth == c, pred == c)
                f1s.append(m["f1"])
                print(row(f"    {labels[c]}", m))
            print(f"    macro F1 {np.mean(f1s):.4f}")
            print(row("    detection (VT/VF vs Normal)", binary(truth >= 1, pred >= 1)))


def main():
    w = scipy.io.loadmat(HERE / "results" / "whole_database_windows.mat")
    R = w["results"]
    stage1(R)
    stage2()
    combined(R, matlab_record_names())


if __name__ == "__main__":
    main()
