"""Stage 1 "difference-on-read" variant: the single shared window stores the
output of a low-corner shared filter (good for Stage 2), and Stage 1 runs the
same feature engine on the first difference d[n] = x[n] - x[n-1] read from that
same buffer (one subtractor, no second filter, no second window). The first
difference is computed on the continuous stream, which in hardware means the
buffer keeps one extra sample (241 entries) so the first d of a window is valid.

Writes Stage 1 features only (Stage 2 keeps using the plain shared-window
features from `extract_shared_candidates.py`).

Modifies no existing file.
"""

from __future__ import annotations

import sys
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.signal import butter, resample_poly, sosfilt

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import extract_shared_candidates as esc
import vt_vf_expanded_cohort_feature_ranking_experiment as exp
import vt_vf_morphology_pt_05_40_autocorrelation_experiment as base

DIFF_CANDIDATES = ["hp1_o3", "hp2_o3", "hp3_o3", "bp1_40_o4", "bp2_40_o4"]


def main() -> None:
    import wfdb

    databases_root = Path("E:/Thesis/databases")
    sos = {n: butter(esc.CANDIDATES[n]["order"], esc.CANDIDATES[n]["band"], btype=esc.CANDIDATES[n]["btype"],
                     fs=esc.FS, output="sos") for n in DIFF_CANDIDATES}
    store = {n: [] for n in DIFF_CANDIDATES}
    record_ids, starts_all, labels_all = [], [], []

    for db in ("mitdb", "vfdb", "cudb"):
        folder = databases_root / exp.DB_FOLDERS[db]
        for record_path in exp.record_bases(folder):
            record_id = f"{db}/{record_path.name}"
            if record_id in esc.STAGE1_EXCLUDED:
                continue
            header = wfdb.rdheader(str(record_path))
            ann = wfdb.rdann(str(record_path), "atr")
            record = wfdb.rdrecord(str(record_path))
            source_fs = float(header.fs)
            raw = np.asarray(record.p_signal[:, 0], dtype=np.float64)
            source = base.interpolate_nonfinite(raw)
            ratio = Fraction(esc.FS / source_fs).limit_denominator(10_000)
            signal = esc.quantize(np.asarray(resample_poly(source, ratio.numerator, ratio.denominator)), 3, 8)
            starts, labels = esc.stage1_windows(db, record_id, ann, raw.size, source_fs, signal.size)
            record_ids.extend([record_id] * starts.size)
            starts_all.extend(starts.tolist())
            labels_all.extend(labels.tolist())
            for n in DIFF_CANDIDATES:
                filtered = esc.quantize(sosfilt(sos[n], signal), 5, 8)
                diff_stream = np.diff(filtered, prepend=filtered[0])
                store[n].append(esc.feature_engine(esc.window_matrix(diff_stream, starts)))
            print(f"    {record_id}: {starts.size}", flush=True)

    for n in DIFF_CANDIDATES:
        np.savez_compressed(
            HERE / "results" / f"diff_{n}.npz",
            feature_names=np.array(esc.FEATURE_NAMES),
            s1_features=np.vstack(store[n]).astype(np.float32),
            s1_record_id=np.array(record_ids),
            s1_start=np.array(starts_all, dtype=np.int64),
            s1_label=np.array(labels_all, dtype=np.int64),
        )
        print(f"Wrote diff_{n}.npz")


if __name__ == "__main__":
    main()
