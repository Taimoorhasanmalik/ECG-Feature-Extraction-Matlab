"""Stage 2 (VT vs VF) on the SHARED hardware chain.

Uses exactly the front end and feature engine of the shared Stage 1 design
(`hw_shared_pipeline/matlab/train_shared_stage1.m`), so in hardware both
stages read the same window from the same filter:

  raw -> MATLAB-identical linear resample to 120 Hz -> Q3.8 (fix)
      -> causal 3rd-order Butterworth 1 Hz high-pass, transfer-function form
         (same as MATLAB filter(b, a, x)) -> Q5.8 -> 240-sample windows
      -> shared 6-feature engine (identical to shared_engine_features in the
         MATLAB Stage 1 code): mean_abs, zero_crossings, line_length,
         threshold_crossing_count, local_amp_range, amp_transition.

Steps:
  1. extract VT/VF interval windows for every VFDB/CUDB record (same
     validity, noise, shock and closed-interval rules as before);
  2. size a fixed-point format per feature from the observed range (8
     fraction bits) and quantize the features;
  3. validate on the 38-record SEED96 pool: leave-one-record-out, the
     standard 4-record holdout, and record-grouped stratified 5-fold;
  4. export (a) the holdout model + test windows for the MATLAB fixed-point
     parity check and (b) an all-data model for deployment, both with the
     scaler folded into one weight vector + bias and quantized.

Modifies no existing file.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import scipy.io
from scipy.signal import butter, lfilter
from sklearn.metrics import accuracy_score, balanced_accuracy_score, precision_score, recall_score
from sklearn.model_selection import StratifiedGroupKFold

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "greedy_record_inclusion"))
sys.path.insert(0, str(HERE.parent))
import extract_shared_candidates as esc
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base
from vt_vf_seed96_record_holdout_validation import SEED96_ORDER

FS = 120.0
WIDTH = 240
BLOCK = 30
HIGHPASS_HZ = 1.0
HIGHPASS_ORDER = 3
FRACTION_BITS = 8
HOLDOUT = ["vfdb/615", "vfdb/429", "cudb/cu13", "cudb/cu32"]
DROPPED = ["vfdb/610", "cudb/cu18"]
FEATURE_NAMES = ["mean_abs", "zero_crossings", "line_length", "threshold_crossing_count",
                 "local_amp_range", "amp_transition"]
WEIGHT_TOTAL_BITS = 16


def q(x, integer_bits, fraction_bits):
    scale = 2.0 ** fraction_bits
    return np.clip(np.fix(np.asarray(x, dtype=np.float64) * scale) / scale,
                   -(2.0 ** integer_bits), 2.0 ** integer_bits - 1.0 / scale)


def linear_resample_like_matlab(signal, source_fs):
    source_time = np.arange(signal.size) / source_fs
    target_n = max(1, int(math.floor(source_time[-1] * FS)) + 1)
    return np.interp(np.arange(target_n) / FS, source_time, signal)


def shared_front_end(raw, source_fs):
    signal = base.interpolate_nonfinite(raw)
    if abs(source_fs - FS) > 1e-6:
        signal = linear_resample_like_matlab(signal, source_fs)
    signal = q(signal, 3, 8)
    b, a = butter(HIGHPASS_ORDER, HIGHPASS_HZ / (FS / 2.0), btype="high")
    return q(lfilter(b, a, signal), 5, 8)


def engine(windows):
    """Vectorized twin of MATLAB shared_engine_features (integerBits=5)."""
    m = q(windows.sum(axis=1) / WIDTH, 5, 8)
    c = windows - m[:, None]
    d = np.diff(c, axis=1)
    a = np.abs(c)
    mean_abs = q(a.sum(axis=1) / WIDTH, 5, 8)
    zero_crossings = esc.sign_changes(d, np.zeros(d.shape[0])) / 2.0
    line_length = np.abs(d).sum(axis=1) / 2.0
    thr = 0.2 * a.max(axis=1)
    above = (a >= thr[:, None]) & (thr[:, None] > 0)
    threshold_crossings = np.sum(above[:, 1:] != above[:, :-1], axis=1).astype(np.float64)
    blocks = a.reshape(a.shape[0], WIDTH // BLOCK, BLOCK).mean(axis=2)
    local_range = blocks.max(axis=1) - blocks.min(axis=1)
    transition = np.abs(np.diff(blocks, axis=1)).mean(axis=1)
    return np.column_stack([mean_abs, zero_crossings, line_length, threshold_crossings, local_range, transition])


def extract(databases_root):
    import wfdb

    feats, labels, record_ids, starts = [], [], [], []
    for db in ("vfdb", "cudb"):
        for record_path in exp.record_bases(databases_root / exp.DB_FOLDERS[db]):
            record_id = f"{db}/{record_path.name}"
            header = wfdb.rdheader(str(record_path))
            ann = wfdb.rdann(str(record_path), "atr")
            raw = np.asarray(wfdb.rdrecord(str(record_path)).p_signal[:, 0], dtype=np.float64)
            source_fs = float(header.fs)
            filtered = shared_front_end(raw, source_fs)
            st, lb = esc.stage2_windows(db, record_id, ann, ~np.isfinite(raw), source_fs, filtered.size)
            if st.size:
                feats.append(engine(esc.window_matrix(filtered, st)))
                labels.append(lb)
                starts.append(st)
                record_ids.extend([record_id] * st.size)
            print(f"    {record_id}: {st.size} windows", flush=True)
    return np.vstack(feats), np.concatenate(labels), np.array(record_ids), np.concatenate(starts)


def integer_bits_for(max_abs):
    return max(1, int(math.ceil(math.log2(max_abs + 2.0 ** -FRACTION_BITS))) + 1)


def fold_and_quantize(model, weight_int_bits, bias_int_bits):
    scaler, svm = model.named_steps["scaler"], model.named_steps["svm"]
    weight = svm.coef_.ravel() / scaler.scale_
    bias = float(svm.intercept_[0] - np.sum(weight * scaler.mean_))
    wf = WEIGHT_TOTAL_BITS - 1 - weight_int_bits
    return weight, bias, q(weight, weight_int_bits, wf), float(q(bias, bias_int_bits, wf)), wf


def metrics(y, pred, vt):
    return dict(acc=accuracy_score(y, pred), bal=balanced_accuracy_score(y, pred),
                vt_p=precision_score(y, pred, pos_label=vt, zero_division=0),
                vt_r=recall_score(y, pred, pos_label=vt, zero_division=0),
                vf_p=precision_score(y, pred, pos_label=1 - vt if vt in (0, 1) else vt, zero_division=0))


def main():
    out_dir = HERE / "results"
    out_dir.mkdir(parents=True, exist_ok=True)
    x_raw, y, rid, st = extract(Path("E:/Thesis/databases"))

    pool = [r for r in SEED96_ORDER if r not in DROPPED]
    in_pool = np.isin(rid, pool)
    feature_int_bits = [integer_bits_for(float(np.max(np.abs(x_raw[in_pool, k])))) for k in range(x_raw.shape[1])]
    x = np.column_stack([q(x_raw[:, k], feature_int_bits[k], FRACTION_BITS) for k in range(x_raw.shape[1])])
    x, y, rid, st = x[in_pool], y[in_pool], rid[in_pool], st[in_pool]
    vt = int(base.VT_LABEL)
    vf = int(base.VF_LABEL)
    print(f"\nPool windows: {y.size} (VT={int((y == vt).sum())}, VF={int((y == vf).sum())}) over {len(set(rid))} records")
    print("Feature formats: " + ", ".join(f"{n}=Q{b}.{FRACTION_BITS}" for n, b in zip(FEATURE_NAMES, feature_int_bits)))

    def fit(rows):
        return exp.make_model(1.0).fit(x[rows], y[rows])

    loro = np.zeros_like(y)
    for r in pool:
        t = rid == r
        if t.any():
            loro[t] = fit(~t).predict(x[t])
    cv = np.zeros_like(y)
    for tr, te in StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=7).split(x, y, rid):
        cv[te] = fit(tr).predict(x[te])
    test = np.isin(rid, HOLDOUT)
    holdout_model = fit(~test)
    holdout_pred = holdout_model.predict(x[test])

    results = {"loro": metrics(y, loro, vt), "cv5": metrics(y, cv, vt), "holdout4": metrics(y[test], holdout_pred, vt)}
    for name, m in results.items():
        print(f"{name:<9} acc={m['acc']:.4f} bal={m['bal']:.4f} VT P/R={m['vt_p']:.3f}/{m['vt_r']:.3f}")
    per_record = {r: float(accuracy_score(y[rid == r], loro[rid == r])) for r in pool if (rid == r).any()}

    alldata_model = fit(np.ones(y.size, dtype=bool))
    raw_weights = [fold_and_quantize(m, 8, 16)[0] for m in (holdout_model, alldata_model)]
    raw_biases = [fold_and_quantize(m, 8, 16)[1] for m in (holdout_model, alldata_model)]
    weight_int_bits = integer_bits_for(max(float(np.max(np.abs(w))) for w in raw_weights))
    bias_int_bits = integer_bits_for(max(abs(b) for b in raw_biases))

    def fixed_point_predict(wq, bq, features):
        return np.where(features @ wq + bq > 0, vf, vt)

    exports = {}
    for tag, model, rows in (("holdout", holdout_model, test), ("alldata", alldata_model, np.ones(y.size, bool))):
        weight, bias, wq, bq, wf = fold_and_quantize(model, weight_int_bits, bias_int_bits)
        float_pred = model.predict(x[rows])
        fixed_pred = fixed_point_predict(wq, bq, x[rows])
        exports[tag] = dict(fixed_vs_float_mismatch=int(np.sum(float_pred != fixed_pred)),
                            fixed_acc=float(accuracy_score(y[rows], fixed_pred)),
                            weight_format=f"Q{weight_int_bits}.{wf}", bias_format=f"Q{bias_int_bits}.{wf}")
        payload = dict(
            feature_names=np.array(FEATURE_NAMES, dtype=object),
            feature_integer_bits=np.array(feature_int_bits, dtype=np.float64),
            feature_fraction_bits=np.full(len(FEATURE_NAMES), FRACTION_BITS, dtype=np.float64),
            highpass_hz=HIGHPASS_HZ, highpass_order=HIGHPASS_ORDER,
            scaler_mean=model.named_steps["scaler"].mean_.reshape(1, -1),
            scaler_scale=model.named_steps["scaler"].scale_.reshape(1, -1),
            svm_coef=model.named_steps["svm"].coef_.reshape(1, -1),
            svm_intercept=np.array([[model.named_steps["svm"].intercept_[0]]]),
            combined_weight=weight.reshape(1, -1), combined_bias=bias,
            combined_weight_q=wq.reshape(1, -1), combined_bias_q=bq,
            weight_integer_bits=weight_int_bits, bias_integer_bits=bias_int_bits, weight_fraction_bits=wf,
            vt_label=vt, vf_label=vf,
            test_record_id=np.array(rid[rows], dtype=object),
            test_start_sample=st[rows].reshape(-1, 1), test_end_sample=(st[rows] + WIDTH).reshape(-1, 1),
            test_true_label=y[rows].reshape(-1, 1),
            test_python_predicted_label=float_pred.reshape(-1, 1),
            test_python_fixed_point_label=fixed_pred.reshape(-1, 1),
            test_features_python=x[rows],
            train_record_id=np.array(sorted(set(rid[~rows] if tag == "holdout" else rid)), dtype=object),
        )
        scipy.io.savemat(out_dir / f"stage2_shared_{tag}.mat", payload)
        print(f"{tag:<8} fixed-point ({exports[tag]['weight_format']} weights, {exports[tag]['bias_format']} bias): "
              f"acc={exports[tag]['fixed_acc']:.4f}, mismatches vs float={exports[tag]['fixed_vs_float_mismatch']}")

    summary = dict(results=results, per_record_loro=per_record, feature_formats=dict(zip(FEATURE_NAMES, feature_int_bits)),
                   exports=exports, highpass_hz=HIGHPASS_HZ, pool_windows=int(y.size))
    (out_dir / "stage2_shared_summary.json").write_text(json.dumps(summary, indent=2))
    print(f"Wrote {out_dir}")


if __name__ == "__main__":
    main()
