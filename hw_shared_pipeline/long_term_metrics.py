"""Long-term (wearable) metrics for the final two-stage design, computed from
the saved per-window outputs; no retraining, no change to any model.

Stage 1, every 1 s window of all 105 records (whole_database_windows.mat):
  - episode-level detection: an episode is a run of truly abnormal windows
    (gaps made only of unlabelled transition windows are bridged); it is
    detected if the 2-of-3 gate is on at any window inside it. Latency =
    seconds from episode onset to the first gate-on window.
  - false alarms per hour: runs of gate-on windows that touch no episode
    (episodes padded by 5 windows each side for gate hold-over and label
    edges), per hour of recording.
Stage 2, every eligible VT/VF window of all records (stage2_all_records_windows.npz):
  - episode-level VT/VF decision by majority vote over the episode's windows.
Combined, on the 1 s grid: an episode is fully correct if the gate fires
during it and the majority Stage 2 label over its gated windows matches.

Modifies no existing file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from confusion_matrices import CACHE, HOLDOUT, POOL, group_of
from report_train_test_metrics import matlab_record_names

PAD = 5


def runs(mask):
    """(start, end_exclusive) for each run of True."""
    m = np.concatenate(([False], mask, [False])).astype(int)
    d = np.diff(m)
    return list(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)))


def episodes(truth):
    abnormal = truth >= 1
    bridge = abnormal | (truth == -1)
    out = []
    for s, e in runs(bridge):
        idx = np.flatnonzero(abnormal[s:e])
        if idx.size:
            out.append((s + idx[0], s + idx[-1] + 1))
    return out


def stage1_events(R, rec, scope_name, scope):
    lat, det, dur, fa_events, hours = [], [], [], 0, 0.0
    fa_per_record = []
    for r in np.unique(rec[scope]):
        rows = np.flatnonzero(rec == r)
        truth, gate = R[rows, 3].astype(int), R[rows, 5] == 1
        eps = episodes(truth)
        covered = np.zeros(rows.size, bool)
        for s, e in eps:
            covered[max(0, s - PAD):min(rows.size, e + PAD)] = True
            hits = np.flatnonzero(gate[s:e])
            det.append(hits.size > 0)
            dur.append(e - s)
            lat.append(hits[0] if hits.size else np.nan)
        n_fa = sum(1 for s, e in runs(gate) if not covered[s:e].any())
        h = rows.size / 3600.0
        fa_events += n_fa
        hours += h
        fa_per_record.append(n_fa / h)
    det, dur, lat = np.array(det), np.array(dur), np.array(lat)
    print(f"\n[Stage 1] {scope_name}: {len(np.unique(rec[scope]))} records, {hours:.1f} h monitored, {det.size} abnormal episodes")
    for lab, m in (("all episodes", np.ones(det.size, bool)), ("episodes >= 10 s", dur >= 10), ("episodes >= 30 s (sustained)", dur >= 30)):
        if m.any():
            print(f"   {lab:<30} detected {det[m].sum():>4}/{m.sum():<4} = {det[m].mean():.3f}   "
                  f"median latency {np.nanmedian(lat[m]):.0f} s (90th pct {np.nanpercentile(lat[m], 90):.0f} s)")
    print(f"   false alarms: {fa_events} events = {fa_events / hours:.2f} per hour overall; "
          f"median record {np.median(fa_per_record):.2f}/h, {np.mean(np.array(fa_per_record) == 0):.0%} of records with none")


def stage2_episodes():
    c = np.load(CACHE)
    rec, start, y, x = c["record"], c["start"], c["label"], c["features"]
    deploy = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_alldata.mat")
    loro = scipy.io.loadmat(HERE / "stage2" / "results" / "stage2_shared_loro_weights.mat")
    vt, vf = int(deploy["vt_label"].ravel()[0]), int(deploy["vf_label"].ravel()[0])
    pdep = np.where(x @ deploy["combined_weight_q"].ravel() + float(deploy["combined_bias_q"].ravel()[0]) > 0, vf, vt)
    phon = pdep.copy()
    for i, r in enumerate(str(np.atleast_1d(v)[0]).strip() for v in loro["record_id"].ravel()):
        m = rec == r
        phon[m] = np.where(x[m] @ loro["weight_q"][i] + float(loro["bias_q"][i][0]) > 0, vf, vt)
    eps = []
    for r in np.unique(rec):
        idx = np.flatnonzero(rec == r)
        idx = idx[np.argsort(start[idx])]
        b = 0
        for k in range(1, idx.size + 1):
            if k == idx.size or start[idx[k]] - start[idx[k - 1]] != 120 or y[idx[k]] != y[idx[k - 1]]:
                seg = idx[b:k]
                eps.append((r, y[seg[0]], seg.size, np.mean(pdep[seg] == vf), np.mean(phon[seg] == vf),
                            np.mean(pdep[seg] == y[seg]), np.mean(phon[seg] == y[seg])))
                b = k
    print("\n[Stage 2] VT/VF decision per episode (majority vote over the episode's windows) vs per window")
    for scope_name, keep in (("curated pool (38)", lambda r: r in POOL), ("pool test records (4)", lambda r: r in HOLDOUT),
                             ("all records", lambda r: True)):
        for model, col, wcol in (("deployed", 3, 5), ("honest (LORO in pool)", 4, 6)):
            sel = [e for e in eps if keep(e[0])]
            truth_vf = np.array([e[1] == vf for e in sel])
            frac_vf = np.array([e[col] for e in sel])
            length = np.array([e[2] for e in sel])
            correct = np.where(truth_vf, frac_vf > 0.5, frac_vf < 0.5)
            win_acc = np.sum([e[wcol] * e[2] for e in sel]) / max(length.sum(), 1)
            vt_m = ~truth_vf
            line = (f"   {scope_name:<22} {model:<22} episodes {correct.mean():.3f} ({correct.sum()}/{correct.size}; "
                    f"VT {correct[vt_m].mean():.3f} of {vt_m.sum()}, VF {correct[~vt_m].mean():.3f} of {(~vt_m).sum()})  "
                    f"| windows {win_acc:.3f}")
            long_m = length >= 10
            if long_m.any():
                line += f" | episodes >= 10 s: {correct[long_m].mean():.3f} ({long_m.sum()})"
            print(line)


def combined_episodes(R, rec):
    print("\n[Combined] per true VT/VF episode on the 1 s grid (annotated labels; gate must fire, majority Stage 2 label must match)")
    vt = int(R[:, 6].min())
    for scope_name, scope in (("curated pool (38)", R[:, 2] == 1), ("all 105 records", np.ones(len(R), bool))):
        for model, col in (("deployed", 6), ("honest", 7)):
            res = []
            for r in np.unique(rec[scope]):
                rows = np.flatnonzero(rec == r)
                truth = R[rows, 3].astype(int)
                truth[R[rows, 8] == 1] = -1              # CUDB lead-in heuristic 'VT' is not an annotation
                for cls in (1, 2):
                    for s, e in runs(truth == cls):
                        gate = R[rows[s:e], 5] == 1
                        if not gate.any():
                            res.append((cls, e - s, False, False))
                            continue
                        lab = R[rows[s:e], col][gate]
                        maj = 1 if np.mean(lab == vt) > 0.5 else 2
                        res.append((cls, e - s, True, maj == cls))
            res = np.array(res, dtype=float)
            for lab, m in (("all episodes", np.ones(len(res), bool)), ("episodes >= 10 s", res[:, 1] >= 10)):
                ok = res[m, 3] == 1
                print(f"   {scope_name:<18} {model:<9} {lab:<17} detected {res[m, 2].mean():.3f} | detected and correct subtype "
                      f"{ok.mean():.3f} ({int(ok.sum())}/{int(m.sum())}; VT {ok[res[m, 0] == 1].mean():.3f}, VF {ok[res[m, 0] == 2].mean():.3f})")


def main():
    w = scipy.io.loadmat(HERE / "results" / "whole_database_windows.mat")
    R = w["results"]
    rec = matlab_record_names()[R[:, 0].astype(int) - 1]
    stage1_events(R, rec, "all 105 records", np.ones(len(R), bool))
    stage1_events(R, rec, "Stage 1 test records (21)", R[:, 1] == 1)
    for db in ("mitdb", "vfdb", "cudb"):
        stage1_events(R, rec, f"{db} only", np.char.startswith(rec.astype(str), db))
    stage2_episodes()
    combined_episodes(R, rec)


if __name__ == "__main__":
    main()
