# Paper Reporting Summary: Two-Stage Low/High-Power ECG VT/VF Classifier

This document consolidates every result, design decision, and metric needed
to report the final two-stage system in the thesis/paper. It covers Stage 1
(low-power Normal-vs-Abnormal gate), Stage 2 (VT-vs-VF classifier), the
combined end-to-end system, and the engineering investigations that justify
the final design choices.

---

## 1. System Architecture

A two-stage, power-aware ECG classifier:

```
ECG window
   |
   v
Stage 1 (low-power): Normal vs Abnormal
   |
   |-- Normal   -> no Stage 2 activation
   |
   |-- Abnormal -> Stage 2 (high-power): VT vs VF
```

Both stages run at **120 Hz** (2.0 s window, 1.0 s step) so they can share
one ADC/clock feed. Stage 1 runs continuously on every window; Stage 2 only
runs on windows Stage 1's gate flags as abnormal. Stage 1 is deliberately
tuned for very high recall (it must rarely miss a real abnormal event),
letting Stage 2 assume most windows it receives are already abnormal and
focus only on the VT-vs-VF distinction.

**Final, deployed artifacts** (unchanged from the thesis-selected design):
- Stage 1: `final_low_power_design/`
- Stage 2: `stage2_hardware_deliverable/120hz/`
- Combined end-to-end test harness (new this session): `final_two_stage_design/`

---

## 2. Stage 1: Low-Power Normal vs Abnormal Gate

### 2.1 Design

- **Databases**: MIT-BIH Arrhythmia (mitdb), MIT-BIH Malignant Ventricular
  Ectopy (vfdb), CU Ventricular Tachyarrhythmia (cudb) — full pool, no
  record exclusions.
- **Sample rate**: 120 Hz. **Window**: 2.0 s. **Step**: 1.0 s.
- **Label definition**: Abnormal = VT or any VF-family rhythm (VF, VFIB,
  VFL). **Everything else counts as Normal**, including other real
  arrhythmias (AFib, PVCs, bigeminy, etc.) — Stage 1 is a VT/VF gate, not a
  general arrhythmia detector.
- **Preprocessing**: quantize to Q3.8 (fixed-point, truncate-toward-zero) →
  causal 3rd-order Butterworth highpass at 5 Hz (Pan-Tompkins-style,
  streaming-realizable) → quantize to Q3.8 again.
- **Features (4)**: `mean_abs`, `zero_crossings`, `line_length`,
  `threshold_crossing_count` (threshold = 0.20 × window's own max
  |amplitude|). `rms_amplitude` and `robust_range` are excluded.
- **Classifier**: linear SVM, class-weighted, trained with a
  recall-floor-guarded threshold objective (`accuracy_recall_floor`,
  min recall 0.98 for the deployed base model).
- **Record-level holdout split**: 84 train / 21 test records (test
  fraction 0.20, split seed 17).
- **Sequence gate**: hard vote-count rule over 3 consecutive window
  decisions — **abnormal if ≥2 of the last 3 windows are abnormal**
  (the deployed "2-of-3" rule). This is NOT a trained second-stage model;
  it's a fixed threshold on a vote count.

### 2.2 Metrics (final, deployed)

| Configuration | Accuracy | Precision | Recall | F1 | AUC |
|---|---|---|---|---|---|
| Base window model alone | 91.93% | 0.5483 | 0.9734 | 0.7015 | 0.9855 |
| **2-of-3 sequence gate (deployed)** | **95.32%** | **0.8596** | **0.9806** | **0.9161** | — |
| ≥1-of-3 (any) | 91.85% | 0.7634 | 0.9959 | 0.8643 | 0.9827 |
| ≥3-of-3 (unanimous) | 96.68% | 0.9273 | 0.9470 | 0.9370 | 0.9827 |

Reproduced exactly via `final_low_power_design/code/eval_pthighpass_seq_120hz.m`.

### 2.3 Investigations that did NOT change the final design (report as negative/confirmatory results)

- **Fixed-point overshoot check**: the causal 5 Hz highpass filter's own
  output can exceed its Q3.8 input range — measured worst case **8.98**
  across a 57-record VFDB+CUDB check (Q3.8's range is ±8, so this genuinely
  clips in the deployed model). A widened **Q5.8** post-filter format
  eliminates this with **no accuracy cost** — in fact a small *improvement*:
  accuracy 91.93% → 92.43%, precision 0.5483 → 0.5648, specificity 0.9135 →
  0.9193, at a negligible recall cost (−0.25 pp). This fix was built and
  validated (`code/train_q38_pthighpass_q58post.m`) but **not adopted** for
  the final deployed Stage 1 — see §2.4.
- **Record curation (greedy forward-inclusion diagnostic)**: applying the
  same methodology used to curate Stage 2's training pool, 6 records were
  found to measurably *corrupt* a held-out-consistent training pool when
  added (`core_accuracy_drop > 0.01`): `cudb/cu12`, `vfdb/421`, `cudb/cu15`,
  `mitdb/207`, `vfdb/602`, `cudb/cu19`. Two of these (`cudb/cu12`,
  `cudb/cu19`) were independently already flagged by an older per-record
  accuracy/recall screen, corroborating the finding. A curated-exclusion
  retrain (dropping these 6 plus Stage 2's own 2 flagged records) was built
  and evaluated but **not adopted** — see §2.4.
- **Trained sequence-gate SVM vs. the hard vote rule**: built a genuine
  second-stage linear SVM on sequence-level features (vote count, max/sum/
  min/delta of raw scores over the last L windows — matching the
  `count`/`count_max_sum_delta_min` architecture), swept L ∈ {2,3,5,7}. Best
  result: L=7, full feature set, **89–90% precision but only ~82.5%
  recall**. The simpler, already-deployed hard 2-of-3 rule (85.96%
  precision / 98.06% recall, §2.2) is a *better* recall/precision/hardware
  tradeoff — no benefit found from the added complexity of a trained
  sequence-level classifier.

### 2.4 Decision: Stage 1 stays as originally deployed

After all the above investigations, the explicit decision was to **keep
Stage 1 exactly as documented in `final_low_power_design/`** (Q3.8
throughout, no record exclusions, hard 2-of-3 vote gate). None of the
explored changes (Q5.8 widening, record exclusion, trained sequence gate)
demonstrated a clear enough win to justify replacing the simpler, already
thesis-validated design. This should be reported as a **negative/
confirmatory result**: the original design was re-examined rigorously and
found to already be a strong, close-to-optimal operating point.

---

## 3. Stage 2: High-Power VT vs VF Classifier

### 3.1 Design (final, `stage2_hardware_deliverable/120hz/`)

- **Databases**: VFDB + CUDB only (no MITDB — Stage 2 only ever sees
  windows Stage 1 already called abnormal).
- **Sample rate**: 120 Hz (matches Stage 1; originally 250 Hz, changed to
  120 Hz so both stages share one ADC/clock).
- **Window**: 2.0 s. **Step**: 1.0 s.
- **Preprocessing** (final, "v3"):
  1. Causal single-pole (1st-order Butterworth) DC blocker at 0.1 Hz —
     replaces an earlier **non-causal whole-record median subtraction**
     (impossible on real streaming hardware). Verified identical accuracy
     (0.9510) to the non-causal version before the fix.
  2. Quantize to **Q5.8**.
  3. Causal 4th-order Butterworth 0.5–40 Hz bandpass (realized as 4
     cascaded biquads, 8th-order effective).
  4. Quantize to **Q5.8** again.
  - Q5.8 (uniform at both points) replaces an original uniform Q3.8: the
    bandpass filter's own gain/overshoot reaches **13.7** worst-case across
    the 49-record candidate pool, and the DC blocker's own output reaches
    **8.9–9.9** regardless of cutoff (swept 0.02–0.5 Hz) — both clip under
    Q3.8. Q5.8 (±32) covers both with margin, at **zero accuracy cost**
    (0.9510 before and after).
- **Features (7)**: `mean_abs_amp`, `line_length`,
  `derivative_zero_crossings`, `threshold_crossings`, `local_amp_mean`,
  `local_amp_range`, `amp_transition`. Per-feature Q-formats: Q3.8 for the
  5 amplitude-scale features, Q8.8 for `line_length` (wider range, up to
  186), Q8.0 for the two counts (integers, no fractional bits needed).
- **Classifier**: `StandardScaler` + `LinearSVC`, folded offline into one
  weight-plus-bias linear form (no runtime division). Weights quantized to
  **Q2.13** (not Q5.8/Q3.8): 2 of 7 weights underflow to exactly zero at
  Q5.8/Q3.8's 1/256 resolution, silently dropping those features; Q2.13's
  1/8192 resolution (32× finer) preserves them, at the cost of less integer
  headroom (max representable ~4.0, comfortably above the largest observed
  weight, 1.38).
- **Record pool**: 38 records (from a greedy forward record-inclusion
  selection, order-seed 96) — **34 train / 4 held-out test**
  (`vfdb/615`, `vfdb/429`, `cudb/cu13`, `cudb/cu32`, never trained on).
  `vfdb/610` (only 4 windows) and `cudb/cu18` (consistent poor performer
  across every diagnostic) dropped from the pool entirely.

### 3.2 Held-out test metrics (4 records, 204 windows: 35 VT, 169 VF)

| | Accuracy | VT precision/recall | VF precision/recall |
|---|---|---|---|
| Float64 (Python reference) | 0.9510 | 0.9310 / 0.7714 | 0.9543 / 0.9882 |
| Q2.13 classifier (fixed-point, MATLAB) | 0.9510 | (identical) | (identical) |
| Q5.8 classifier comparison (rejected) | 0.9461 | — | — |

Fixed-point hardware validation: **0 MATLAB/Python prediction mismatches**,
max |feature diff| = 12 (down from 16.8 in the original pre-fix pipeline).

### 3.3 Standalone accuracy across the FULL 38-record pool (new this session)

Computed by re-running Stage 2's classifier (unconditionally, no Stage 1
gating) on every ground-truth VT/VF window in all 38 pool records:

| | Train (34 records, in-sample) | Test (4 held-out) | Combined (38) |
|---|---|---|---|
| True VT / VF windows | 1876 / 3461 | 35 / 169 | 1911 / 3630 |
| VT accuracy | 81.82% | 77.14% | 81.74% |
| VF accuracy | 92.55% | 98.82% | 92.84% |
| **Overall accuracy** | **88.78%** | **95.10%** | **89.01%** |

The test-set figure (95.10%, 194/204) exactly reproduces the originally
validated result — confirms this broader evaluation is methodologically
consistent with the original.

### 3.4 Investigations that did NOT change the final design

- **Highpass-order sweep for the DC blocker** (orders 1/2/3 at the
  currently-used 0.1 Hz cutoff): **identical held-out accuracy (0.9510)**
  and identical per-record breakdown at every order. Overshoot increases
  monotonically with order (9.2 → 10.2 → 11.8), confirming the deployed
  1st-order design has the *lowest* overshoot, not just the lowest cost —
  no motivation to change it.
- **Cutoff sweep for the DC blocker** (0.02–0.5 Hz): clipping risk stays in
  a narrow band (~0.001–0.003% of samples) regardless of cutoff — cutoff
  choice barely matters; format width (Q5.8) is what actually matters.
- **"Filter at the start" architectures**, re-tested under Q5.8 (previously
  rejected under the narrower Q3.8/Q4.8 format specifically because they
  clipped):
  - *0.5 Hz highpass pre-quantization + 40 Hz lowpass post-quantization
    (split design)*: no clipping under Q5.8 at any highpass order (1/2/3
    tested); accuracy 0.9559 (vs. baseline 0.9510) — but this is a
    **single window flipping** (32/34 → 33/34 correct on one record), not a
    real generalizable improvement. Cheaper in hardware (5–6 filter poles
    vs. the deployed design's 9), so a legitimate *hardware-cost*
    alternative, not an *accuracy* one.
  - *Full bandpass entirely before quantization* (one quantize-once
    design): no clipping under Q5.8 either; order 4 (matching the deployed
    filter) reproduces the baseline exactly (0.9510); orders 1–3 give the
    same +1-window bump as above. Confirms that once nothing clips, *where*
    you place the quantization relative to the filter stops mattering.
  - *Reusing Stage 1's own 5 Hz highpass as Stage 2's baseline-removal
    stage*: still rejected — **0.9020 accuracy** (down from 0.9510). This
    is a genuine information-loss problem (the 5 Hz corner throws away
    amplitude content below it that Stage 2's features need), not a
    clipping problem, so Q5.8 does not fix it. Re-verified under Q5.8 to
    confirm the verdict is unchanged.
- **Flat 3-class model (VT / VF / NORMAL) instead of the two-stage
  cascade**: tried and rejected. Overall accuracy looked good (89.2%) but
  is misleading — driven by the NORMAL class dominating the gate-active
  traffic (87% of it). Real recall on the clinically important classes was
  poor: **VT recall 54.2%, VF recall 57.6%** — nearly half of real VT
  events and over 40% of real VF events silently misclassified as NORMAL,
  the worst possible failure mode for a life-critical detector.
- **Hierarchical two-level alternative** (arrhythmia-vs-NORMAL first at a
  tunable recall floor, then VT-vs-VF only within arrhythmia calls): fixes
  the flat 3-class model's recall problem (VF recall 58%→91–94%, VT
  54%→63–67%) but at a real cost — false-arrhythmia rate on true-NORMAL
  windows rises from 6% to 39–64% depending on the chosen recall floor.
  Whether this tradeoff is worth it depends on what a false call triggers
  downstream (a clinician glance vs. an automatic intervention) — a product
  decision, not resolved here.

### 3.5 A real, previously-undiscovered bug found and fixed (worth reporting as a methods note)

While building a curated-exclusion retrain for Stage 1, discovered that the
`problematicRecordKeys`/`cleanTrainingEnabled` per-record exclusion feature
present in **every one of these training scripts** had a latent bug: the
record key was built from `fileparts()` of the full database folder path,
which MATLAB's `fileparts` mis-parses for the versioned folder names
(`...-database-1.0.0` → name `...-1.0`, ext `.0`), so the key never matched
any `"vfdb/…"`-style entry in the exclusion list. This exclusion feature
had therefore **never actually excluded anything** in any prior run that
used it (though it defaults to disabled, so the deployed models were not
affected). Fixed via a robust folder-path-suffix match instead of
`fileparts`.

---

## 4. Combined Two-Stage End-to-End System (new this session)

Built and tested in `final_two_stage_design/` (combines the unchanged
Stage 1 `final_low_power_design/` and the latest Stage 2
`stage2_hardware_deliverable/120hz/`, with a fresh end-to-end test script —
neither original folder was modified).

### 4.1 Methodology

For each of the 38 Stage-2-pool records, Stage 1 runs continuously over the
whole record (its own Q3.8 preprocessing, 4 features, base SVM score,
2-of-3 sequence vote) to get a gate-active/inactive decision per window.
Stage 2 runs continuously too (its own Q5.8 preprocessing, 7 features) but
its classification is only evaluated at windows with known VT/VF ground
truth. Since Stage 2's ground-truth windows are anchored to each
arrhythmia interval's own start time (not the record's absolute t=0 clock),
each is matched to the *nearest* Stage 1 window in time — what a real
continuously-streaming device would actually have active at that moment.

Evaluated on **5541 total ground-truth windows** (1911 VT, 3630 VF) across
all 38 records — this is only the windows that fall inside a labeled VT/VF
episode (typically 1–9% of a full record's length; the rest is normal or
other non-VT/VF activity with no VT/VF ground truth to score against).

### 4.2 Results

| | Train (34 records) | Test (4 held-out) | Combined (38) |
|---|---|---|---|
| True VT / VF windows | 1876 / 3461 | 35 / 169 | 1911 / 3630 |
| **Stage 1 gate recall** — VT | 99.57% | 82.86% | 99.27% |
| **Stage 1 gate recall** — VF | 98.99% | 99.41% | 99.01% |
| **Stage 2 accuracy, given gated** — VT | 82.01% | 75.86% | 81.92% |
| **Stage 2 accuracy, given gated** — VF | 92.70% | 98.81% | 92.99% |
| **End-to-end combined accuracy** — VT | **81.66%** | **62.86%** | **81.32%** |
| **End-to-end combined accuracy** — VF | **91.77%** | **98.22%** | **92.07%** |
| **Overall end-to-end combined accuracy** | **88.21%** | **92.16%** | **88.36%** |

### 4.3 Key finding for the paper

**VT is the consistent weak point of the combined system** (81.3% end-to-end
vs. 92.1% for VF, on the full 38-record pool — not just a small-sample
artifact of the 4-record test set). This holds at every stage of the
pipeline: Stage 1's gate recall is worse for VT than VF, and Stage 2's own
conditional accuracy is also worse for VT than VF, so the two effects
compound. Comparing standalone Stage 2 (§3.3, 81.7% VT / 92.8% VF combined)
against the gated combined numbers above (81.3% VT / 92.1% VF) shows Stage
1's gate is **not the dominant source of the end-to-end VT shortfall** —
Stage 2's own weaker VT separability is the bigger factor, though Stage 1
does add a further real cost by missing some VT episodes outright (14 of
1911 true VT windows on the combined pool never wake Stage 2 at all).

---

## 5. Summary Table for the Abstract/Conclusion

| System | Metric | Value |
|---|---|---|
| Stage 1 alone (2-of-3 gate) | Accuracy / Precision / Recall / F1 | 95.32% / 0.8596 / 0.9806 / 0.9161 |
| Stage 2 alone (held-out test, VT vs VF) | Accuracy | 95.10% |
| Stage 2 alone (full 38-record pool) | Accuracy | 89.01% |
| **Combined two-stage system (full 38-record pool)** | **Overall end-to-end accuracy** | **88.36%** |
| Combined two-stage system | VT / VF end-to-end accuracy | 81.32% / 92.07% |

---

## 6. File/Artifact Reference

| Artifact | Location |
|---|---|
| Stage 1 final design (deployed) | `final_low_power_design/` |
| Stage 2 final design (deployed) | `stage2_hardware_deliverable/120hz/` (spec: `HARDWARE_SPEC.txt`, pipeline: `SYSTEM_PIPELINE.txt`) |
| Combined two-stage test harness | `final_two_stage_design/test_combined_pipeline.m` |
| Stage 2 fixed-point validation | `code/stage2_vt_vf_hardware_validation/validate_stage2_vt_vf_120hz_v3_pipeline.m` |
| Stage 1 Q5.8 fix (built, not adopted) | `code/train_q38_pthighpass_q58post.m` |
| Stage 1 curated-exclusion retrain (built, not adopted) | `code/train_q38_pthighpass_q58post_curated_exclusions.m` |
| Stage 1 greedy record-inclusion diagnostic | `stage1_greedy_record_inclusion/` |
| Stage 1 trained sequence-gate experiment (built, not adopted) | `stage1_greedy_record_inclusion/stage1_sequence_gate_trainer.py` |
| Flat 3-class model (rejected) | `greedy_record_inclusion/vt_vf_stage2_three_class_model.py` |
| Hierarchical two-level model (exploratory) | `greedy_record_inclusion/vt_vf_stage2_hierarchical_two_stage_model.py` |
| Filter-placement / order / cutoff sweeps | `greedy_record_inclusion/vt_vf_causal_filter_extraction_120hz_v3_*.py` |
