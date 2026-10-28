# Thesis Reference: Methods, Results and Decisions of the Final Design

Status: 2026-10-28. Companion to [../FINAL_DESIGN_README.md](../FINAL_DESIGN_README.md),
which lists where every file is. This document is written for thesis chapters:
it defines every method and evaluation protocol, collects every result table,
and records the design decisions with the evidence behind them.

Provenance rules used here:

- Algorithm and evaluation numbers come from the scripts named next to each
  table (mostly in `hw_shared_pipeline/`). They are reproducible with the
  commands in FINAL_DESIGN_README.md, Section 5.
- RTL, FPGA and ASIC numbers are transcribed from `FinalRTLSummary.md`,
  `final_two_stage_design/hardware/README.md`, `Documents/asic_paper_reporting_data.md`
  and `ASIC_Reports_Latest_100kHz_20261020/README.md`. Those documents are the
  authority for hardware claims and carry further qualifications.
- No evaluation data was selected according to whether a model classified it
  correctly. Inclusion rules are label- and signal-quality-based and fixed in
  advance.

---

## 1. Data

### 1.1 Databases

| Database | Records | Native rate | Role |
| --- | ---: | ---: | --- |
| MIT-BIH Arrhythmia (mitdb) | 48 | 360 Hz | Stage 1 (mostly normal and other arrhythmias); Stage 2 external check (short VT runs, VFL in 207) |
| MIT-BIH Malignant Ventricular Ectopy (vfdb) | 22 | 250 Hz | Stage 1 and Stage 2 |
| CU Ventricular Tachyarrhythmia (cudb) | 35 | 250 Hz | Stage 1 and Stage 2 (VF only; no VT annotations) |

Channel 1 of each record is used. All records are resampled to 120 Hz by
linear interpolation on a fixed time grid (MATLAB `interp1(...,'linear')`,
reproduced exactly in Python). This simulates a 120 Hz ADC; a real device
would sample at 120 Hz behind an analogue anti-alias filter.

### 1.2 Windows

- Window 240 samples (2 s), stride 120 samples (1 s), 50% overlap.
- Stage 1 window label: abnormal if >= 80% of its samples lie in a VT or
  VF-family interval, normal if <= 20%, otherwise dropped. Windows with more
  than 1% artifact-masked samples are dropped (annotation artifacts `~`, `|`,
  artifact/noise comments, plus a statistical signal-artifact detector).
- Stage 2 windows: only inside annotated VT or VF-family intervals (VF, VFIB,
  VFL, CUDB `[`/`]` brackets), only closed intervals, no invalid samples, no
  annotated noise, and before the first shock (a dropout run of >= 0.2 s).

### 1.3 Labels

- Stage 1 uses `build_normal_abnormal_labels` (in the official evaluator):
  abnormal = VT or any VF-family rhythm; everything else, including other
  arrhythmias, is Normal. For CUDB the abnormal region also includes a
  heuristic tachycardia lead-in before each VF onset.
- Stage 2 uses annotated VT vs VF-family intervals only. The CUDB lead-in
  heuristic (which `build_vt_vf_sample_labels` marks as "VT") is not an
  annotation and is excluded from Stage 2 VT truth in the evaluations below
  unless stated.

### 1.4 Splits

| Model | Pool | Split |
| --- | --- | --- |
| Stage 1 | all 105 records (no exclusions) | 84 train / 21 test, record-level, seed 17 (`split_records_for_holdout`); test record indices saved in the model (`testRecordIds`) |
| Stage 2 | 38 records: the greedy-curated SEED96 order (40) minus vfdb/610 and cudb/cu18 | 34 train / 4 test (vfdb/615, vfdb/429, cudb/cu13, cudb/cu32); leave-one-record-out over all 38 |

Stage 2 pool size: 5,541 windows (1,911 VT, 3,630 VF). Records with Stage 2
windows that are outside the pool: 8 VFDB records excluded as mostly noise
(vfdb/420, 421, 422, 423, 427, 430, 602, 612), the two dropped records, cudb/cu30,
and the MIT-BIH VT/VFL records. The pool was formed by greedy record inclusion
on internal consistency; this is a training-set curation and must be stated.

---

## 2. Signal processing and features

### 2.1 Shared front end

ECG -> resample to 120 Hz -> quantize to Q3.8 (signed, 3 integer and 8
fraction bits, truncation toward zero, saturating). Both stages read these
same samples.

### 2.2 Stage 1 path

1. Causal 3rd-order Butterworth high-pass, 5 Hz, transfer-function form,
   continuous (state never reset).
2. Re-quantize to Q3.8.
3. Per window: subtract the window mean (mean truncated to Q3.8), then
   - `mean_abs` = mean of |x - m|, truncated to Q3.8
   - `zero_crossings` = sign changes of the first difference (zero values hold
     the previous sign), divided by 2 s
   - `line_length` = sum |x[n] - x[n-1]|, divided by 2 s
   - `threshold_crossing_count` = transitions of |x - m| >= 0.2 * max|x - m|

### 2.3 Stage 2 path (final)

1. Causal 3rd-order Butterworth high-pass, 1 Hz, continuous (RTL coefficients Q2.29).
2. Re-quantize to Q5.8 (wider than Stage 1: this filter's output overshoots
   beyond the Q3.8 range).
3. Per window, the shared feature engine with Q5.8 internal precision:
   the same four features as Stage 1, plus over eight 30-sample blocks of |x - m|
   - `local_amp_range` = max - min of the 8 block means
   - `amp_transition` = mean |difference| of consecutive block means
4. Per-feature formats (8 fraction bits): mean_abs Q4.8, zero_crossings Q8.8,
   line_length Q8.8, threshold_crossing_count Q8.8, local_amp_range Q4.8,
   amp_transition Q2.8.

The same engine reproduces the deployed Stage 1 features bit for bit
(maximum difference 0 over all 38 records, `test_two_stage_hw_shared.m`), which
is what allows one physical feature engine for both stages.

---

## 3. Classifiers

### 3.1 Stage 1 (deployed, unchanged in this work)

- Linear SVM (`fitcsvm`), trained on the 84 train records with the deployed
  recipe: normal downsampling ratio and box constraint chosen by 5-fold CV
  (ratios {1, 2}, box {0.3, 1, 3}, class weights balanced or none),
  SMOTE-style abnormal augmentation (factor 1.0: one synthetic window per real
  abnormal window, interpolated between two real ones), feature outlier
  removal (robust z > 8).
- Decision threshold T: maximum training accuracy subject to training recall
  >= 0.98.
- Sequence gate: d[n] = 1 if s1 >= T; abnormal sequence if d[n] + d[n-1] + d[n-2] >= 2.
- Hardware: folded weights in Q8.24, Q40 score; 11 base-decision changes in
  33,169 test windows versus the floating-point model.

### 3.2 Stage 2 (final)

- Standardization + linear SVM (scikit-learn LinearSVC, balanced class
  weights, C = 1), trained on all 38 pool records for deployment.
- The scaler is folded into one weight vector and bias, quantized to Q3.12
  (weights) and Q2.12 (bias): score = sum(w_i * f_i) + b; VT if score <= 0,
  otherwise VF.
- `build_stage2_shared.py` sizes the formats from the data and exports the
  model; `validate_stage2_shared.m` recomputes everything from the raw records
  in MATLAB fixed point.

---

## 4. Hardware architecture (summary)

Full description, timing and verification: `FinalRTLSummary.md`.

| Item | Final selection |
| --- | --- |
| Board / device | Basys 3, Artix-7 xc7a35tcpg236-1, Vivado 2020.2 |
| Tops | board `basys3_two_stage_adaptive_top`, integration `two_stage_adaptive_clock_top`, core `two_stage_shared_replay_top` |
| Source clock / input | 100 MHz / 120 samples/s |
| Processing clock | 500 Hz while Stage 2 sleeps; 100 kHz while armed or draining |
| Shared resources | window sequencer, 240 x 32-bit two-lane history, replay feature datapath, scheduler, clock-gated classifier MAC |
| Separate resources | the two warm filters and per-stage streaming-statistics state |
| Enable | >= 2 abnormal votes of 3 completed Stage 1 windows; both stages restart collection at the next raw sample; vote history cleared |
| Disable | two consecutive normal sequence decisions; started Stage 2 windows finish and report (drain), then the clock slows |
| Gating | Stage 2 statistics clock and shared MAC clock gated (BUFGCE on FPGA); Stage 2 RAM writes gated; both filters stay clocked |
| Outputs | Other = 0, VT = 1, VF-family = 2, Stage 1 abnormal = 3, with window ID |
| Replay cost | Stage 1 480 cycles (0.96 s at 500 Hz, 4.8 ms at 100 kHz); Stage 2 240 cycles (2.4 ms at 100 kHz) |
| Arm-to-fast-clock latency | about 1 ms (worst observed 1.0025 ms in simulation) |

---

## 5. Evaluation protocols

| Protocol | Definition | Used for |
| --- | --- | --- |
| Official Stage 1 protocol | `eval_pthighpass_seq_120hz.m`: MIT-BIH normal windows thinned to 25% before the split (CUDB is thinned too, see 9.7), feature outlier removal, sequences of 3 consecutive surviving windows, sequence truth = abnormal if any of the 3 windows is abnormal, prediction = 2-of-3 votes | comparable with the published 95.32% |
| Every window (streaming) | every labelled window of every record, natural prevalence (about 9 normal per abnormal), no thinning or outlier removal, gate on the fixed 1 s grid | realistic per-window behaviour |
| Leave-one-record-out (LORO) | each record classified by a model trained without it | honest Stage 2 generalization |
| End-to-end on VT/VF windows | `test_two_stage_hw_shared.m`: for each true VT/VF window, correct if Stage 1's gate is on and Stage 2 gives the right subtype; "always warm" (Stage 2 filter running) or "cold start" (Stage 2 filter starts from zero when the gate fires; windows before power-on count as missed) | Stage 2 in the system |
| Episode level | episode = run of truly abnormal windows; detected if the gate fires inside it; latency from onset; false alarm = gate-on run touching no episode (5 s padding) | wearable view |
| Per minute | 60-window blocks; abnormal block >= 10 s of VT/VF; normal block has no VT/VF within 5 s of its edges; predicted abnormal if the gate fires in the block | wearable confusion matrices |

---

## 6. Results

### 6.1 Stage 1: Normal vs Abnormal (deployed model)

Official protocol, after the 2-of-3 gate (`eval_shared_stage1_seq.m`, `ECG_EVAL_SPLIT`):

| Split | TN | FP | FN | TP | Accuracy | Precision | Sensitivity | Specificity | F1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Test (21 records) | 7,177 | 429 | 52 | 2,627 | 0.9532 | 0.8596 | 0.9806 | 0.9436 | 0.9161 |
| Train (84) | 18,715 | 4,498 | 198 | 10,440 | 0.8613 | 0.6989 | 0.9814 | 0.8062 | 0.8164 |
| Train + test (105) | 25,892 | 4,927 | 250 | 13,067 | 0.8827 | 0.7262 | 0.9812 | 0.8401 | 0.8347 |

Base window model before the gate (official protocol, test): accuracy 91.93%,
precision 0.5483, recall 0.9734, F1 0.7015, AUC 0.9855
(`Documents/paper_reporting_summary.md`). The test records are easier than
the training records, so train + test is the more representative figure.

Every window, after the 2-of-3 gate (`report_train_test_metrics.py`, `confusion_matrices.py`):

| Data | TN | FP | FN | TP | Accuracy | Precision | Sensitivity | Specificity | F1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Test (21) | 23,448 | 2,436 | 68 | 2,678 | 0.913 | 0.524 | 0.975 | 0.906 | 0.681 |
| Train (84) | 79,883 | 17,041 | 256 | 10,915 | 0.840 | 0.390 | 0.977 | 0.824 | 0.558 |
| Train + test (105) | 103,331 | 19,477 | 324 | 13,593 | 0.855 | 0.411 | 0.977 | 0.841 | 0.579 |
| MIT-BIH only | 74,286 | 6,057 | 30 | 230 | 0.925 | 0.037 | 0.885 | 0.925 | 0.070 |
| VFDB only | 25,032 | 6,330 | 79 | 7,848 | 0.837 | 0.554 | 0.990 | 0.798 | 0.710 |
| CUDB only | 4,013 | 7,090 | 215 | 5,515 | 0.566 | 0.438 | 0.963 | 0.361 | 0.602 |

Precision here is low because normal windows outnumber abnormal ones about
9 to 1; sensitivity and specificity do not depend on that ratio.

Long-term view (`long_term_metrics.py`, `long_term_confusion.py`), 105 records, 41.8 h:

| Measure | Value |
| --- | --- |
| Abnormal episodes detected, all (186) | 172 (92.5%); misses are short runs, mostly MIT-BIH |
| Episodes >= 10 s (88) | 88 (100%) |
| Sustained episodes >= 30 s (66) | 66 (100%); test records 10 / 10 |
| Detection latency after onset | median 0 s, 90th percentile 1 s (2 s on test records) |
| False alarms per hour | 51.2 overall (2,141 events); test records 38.1; MIT-BIH 38.3 (median record 5.0); VFDB 58.9; CUDB 93.9 |
| Per minute, all records | TN 1,331, FP 768, FN 0, TP 277: sensitivity 1.000, specificity 0.634 |
| Per minute, test records | TN 334, FP 138, FN 0, TP 57: sensitivity 1.000, specificity 0.708 |

### 6.2 Stage 2: VT vs VF (final 1 Hz model, fixed-point weights)

On its own data (`report_train_test_metrics.py`, `confusion_matrices.py`).
Matrix order [VF->VF, VF->VT; VT->VF, VT->VT]; VF sensitivity = VT specificity.

| Model / split | Matrix | Accuracy | VT precision | VT sensitivity | VT F1 | VF precision | VF sensitivity | VF F1 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Deployed, train (34) | [3239 222; 307 1569] | 0.901 | 0.876 | 0.836 | 0.856 | 0.913 | 0.936 | 0.925 |
| Deployed, test (4) | [167 2; 6 29] | 0.961 | 0.936 | 0.829 | 0.879 | 0.965 | 0.988 | 0.977 |
| Deployed, train + test (38) | [3406 224; 313 1598] | 0.903 | 0.877 | 0.836 | 0.856 | 0.916 | 0.938 | 0.927 |
| **LORO (38)** | [3382 248; 538 1373] | **0.858** | 0.847 | 0.718 | 0.778 | 0.863 | 0.932 | 0.896 |
| Record-grouped stratified 5-fold (38) | | 0.801 | | | | | | |

The 4-record test set has only 204 windows; LORO is the figure to report as
generalization. The deployed weights are the all-data weights, so 0.961 is not
an independent test accuracy of the deployed classifier.

Fixed-point checks: MATLAB re-extraction vs Python on the 204 holdout windows:
0 prediction mismatches, maximum feature difference 0, MATLAB accuracy 0.9608.
RTL (hardware-fixed filter and features) with each record's LORO weights:
0.858148 over 5,541 windows; the all-data model has zero prediction changes
against its fixed-point export.

Filter choice (LORO, 6 shared-engine features, `evaluate_shared_candidates.py`
and an inline LORO run):

| Stage 2 filter | LORO accuracy |
| --- | ---: |
| 3rd-order HP 5 Hz (Stage 1's filter) | 0.668 |
| 3rd-order HP 3 Hz | 0.856 |
| 3rd-order HP 2 Hz | 0.866 |
| **3rd-order HP 1 Hz (selected)** | **0.864** (0.858 in the final export) |
| 4th-order BP 0.1-40 Hz (intermediate design) | 0.808 |
| 4th-order BP 1-40 Hz | 0.863 |
| 4th-order BP 2-40 Hz | 0.860 |
| 4th-order BP 3-40 Hz | 0.846 |
| 4th-order BP 5-40 Hz | 0.751 |

The previous Stage 2 (0.1 Hz DC blocker + 4th-order 0.5-40 Hz band-pass,
7 features, Q2.13) scored 0.951 on the 4-record holdout; it was not evaluated
with LORO in the same harness.

Beyond the curated pool (every eligible window of all records, deployed model):

| Records | Matrix [VF->VF, VF->VT; VT->VF, VT->VT] | Accuracy | VT sensitivity | VF sensitivity |
| --- | --- | ---: | ---: | ---: |
| Curated pool (38) | [3406 224; 313 1598] | 0.903 | 0.836 | 0.938 |
| 8 noisy VFDB records | [1619 0; 3151 39] | 0.345 | 0.012 | 1.000 |
| MIT-BIH (9 records, never used by Stage 2) | [134 1; 117 8] | 0.546 | 0.064 | 0.993 |
| Dropped from pool (2) | [14 11; 3 1] | 0.517 | 0.250 | 0.560 |
| All 58 records with eligible windows | [5211 294; 3584 1646] | 0.639 | 0.315 | 0.947 |

Per episode (majority vote over the episode's windows): curated pool
[114 14; 11 11], accuracy 0.833 (VF 0.891, VT 0.500 of 22 episodes); all
records [132 15; 82 20], accuracy 0.610.

### 6.3 Combined system

End-to-end on true VT/VF windows (`test_two_stage_hw_shared.m`, 38 pool records;
Stage 1 gate recall: VT 0.993, VF 0.990; sustained view VT 0.999):

| Stage 2 model | Mode | All VT/VF windows | Sustained-VT view (VT episodes >= 30 windows) |
| --- | --- | ---: | ---: |
| Deployed (all-data) | always warm | 0.896 | 0.915 |
| Deployed (all-data) | cold start | 0.883 | 0.908 |
| LORO | always warm | 0.852 | 0.870 |
| LORO | cold start | 0.839 | 0.862 |

Previous design on the deployed, sustained-VT basis with a fixed +3-window
warm-up rule: 0.895. Cold start with the 1 Hz filter still classifies 97% of
VT windows. These numbers include only true VT/VF windows; they say nothing
about false alarms on normal time.

Every window, three classes Normal / VT / VF, deployed Stage 2, 38 pool records
(annotated labels; `report_train_test_metrics.py`):

| Split | Overall accuracy | Detection sensitivity | Detection specificity | VT P / R / F1 | VF P / R / F1 | Macro F1 |
| --- | ---: | ---: | ---: | --- | --- | ---: |
| Train (34) | 0.656 | 0.991 | 0.603 | 0.519 / 0.837 / 0.641 | 0.276 / 0.904 / 0.423 | 0.605 |
| Test (4) | 0.775 | 0.964 | 0.768 | 0.786 / 0.667 / 0.721 | 0.134 / 0.994 / 0.236 | 0.608 |
| Train + test (38) | 0.673 | 0.990 | 0.630 | 0.522 / 0.834 / 0.642 | 0.263 / 0.908 / 0.407 | 0.607 |

All 105 records: overall 0.808, detection sensitivity 0.977, specificity 0.841.

Per minute, three classes (`long_term_confusion.py`), rows = true Normal / VT / VF,
columns = predicted Normal / VT / VF:

| Data | Matrix | Accuracy | Macro F1 |
| --- | --- | ---: | ---: |
| 38 pool records | [173 23 240; 0 26 8; 0 6 78] | 0.500 | 0.511 |
| All 105 records | [1331 82 686; 0 26 74; 0 18 115] | 0.631 | 0.411 |

Per episode, 38 pool records: every episode is detected; 84.3% are detected
and correctly typed (VT 0.476, VF 0.912).

Remaining false alarms are mostly abnormal rhythms labelled Normal: left bundle
branch block (mitdb/109), paced rhythm (mitdb/107), frequent PVCs and
bigeminy (mitdb/213, 233), and the baseline rhythm of malignant-ectopy patients
(vfdb/418, 424, 419). Two thirds of the false-alarm windows are more than a
minute from any VT/VF, so they are not boundary effects.

Proposed verifier (not in the RTL; `train_stage2_verifier.py`): a 4-weight
linear SVM on the Stage 1 features already in registers, trained only on
gated windows (real VT/VF vs false alarm), threshold keeping >= 90% of real
VT/VF in training. Record-grouped 5-fold out-of-fold results:

| Configuration | 38 pool records: accuracy / detection sens / spec | All 105: accuracy / sens / spec | VT F1 / VF F1 (38) |
| --- | --- | --- | --- |
| 2-of-3 gate, no verifier | 0.673 / 0.990 / 0.630 | 0.808 / 0.977 / 0.841 | 0.642 / 0.407 |
| 2-of-3 gate + verifier | 0.811 / 0.951 / 0.801 | 0.885 / 0.864 / 0.931 | 0.707 / 0.538 |
| 3-of-3 gate + verifier | 0.830 / 0.932 / 0.828 | 0.896 / 0.836 / 0.944 | 0.713 / 0.564 |
| 5-of-5 gate + verifier | 0.837 / 0.923 / 0.837 | 0.900 / 0.825 / 0.950 | 0.725 / 0.569 |

It fits in Stage 1's slot (about 0.1 ms per step) and could also gate Stage 2
wake-up, saving power.

### 6.4 FPGA implementation

Source: `FinalRTLSummary.md` Section 18 and `final_two_stage_design/hardware/README.md`.

| Routed design (XC7A35T) | LUTs | FFs | DSP48E1 | RAMB18 |
| --- | ---: | ---: | ---: | ---: |
| Earlier parallel Stage 1 + Stage 2 (500 Hz, board wrapper) | 14,205 | 16,128 | 76 | - |
| Shared engine + shared MAC, fixed 100 kHz | 5,155 | 2,368 | 48 | 2 |
| **Final adaptive design, board wrapper** | **5,172** | **2,404** | **48** | **2** |
| Shared core only (240-entry, 100 kHz) | 4,875 | 2,318 | 48 | 2 |

- Adaptive divider/controller: 29 LUTs, 23 FFs; incremental cost of frequency
  adaptation 15 LUTs and 8 FFs, no extra global clock resource.
- Timing: overall setup slack +3.536 ns, hold +0.037 ns; processing domain
  setup slack +9,937 ns. Operating frequencies verified; no maximum-frequency
  sign-off.
- Verification: integer Python references are the exact arithmetic targets;
  ModelSim matches filter values, features, scores, classes, alignment and
  episode transitions, including a 3,600-sample reactivation test (25 Stage 1
  and 15 Stage 2 scores, 2 arms, return to slow mode, drain of started windows).
- Shared storage: the earlier parallel RTL held four sample memories
  (2 x 240 x 12 + 2 x 240 x 14 = 12,480 useful bits); the final design holds
  240 x (12 + 14) = 6,240 useful bits, a 50% reduction in sample-payload
  storage (`Documents/shared_ram_area_and_paper_novelty_audit.md`).
- Vivado vectorless power (low confidence) about 0.079 W total; FPGA clock
  gating shows no difference at 1 mW resolution. No board power measured.

### 6.5 ASIC implementation (generic 45 nm, GPDK045)

Source: `ASIC_Reports_Latest_100kHz_20261020/README.md`,
`Documents/native_100khz_power_pair_report.md`, `Documents/asic_paper_reporting_data.md`.

Latest full-core result (100 kHz source, routed, 2026-10-20; 60 s synthetic
normal input, Stage 2 inactive, 0.9 V / 125 C slow corner):

| Metric | Adaptive, gated | Fixed 100 kHz, ungated |
| --- | ---: | ---: |
| Processing clock on normal input | 500 Hz | 100 kHz |
| Dynamic power | 0.03186 uW | 1.97239 uW |
| Leakage power | 2.24171 uW | 2.24162 uW |
| Total power | 2.27357 uW | 4.21401 uW |
| Energy over 60 s | 136.41 uJ | 252.84 uJ |
| Non-filler cell area | 0.117552 mm^2 (30,363 cells) | 0.117653 mm^2 |
| Setup / hold WNS | +4,998.2 / +0.022 ns | +4,998.1 / +0.013 ns |

Combined frequency-and-gating reduction: 46.05% total, 98.39% dynamic. Selected
external DRC (562 rules) clean and transistor-level LVS match. All 66
classification IDs/codes matched between the two cases.

Earlier pipeline-only estimate (direct clock, no divider): 2.0185 uW gated at
500 Hz vs 3.5419 uW ungated at 100 kHz (43.0% total, 99.3% dynamic). This is
the figure in the conference draft. The earlier 100 MHz-source routed core
(28.235 uW) is not the final variant.

Points to state with these numbers:

- Leakage is about 99% of the gated total; the slow 125 C corner is pessimistic
  for leakage, so the percentage is understated and the absolute value is
  conservative.
- Both power cases are Stage-1-only (Stage 2 never activates on normal input).
  They do not measure active Stage 2 or wake-up power and must not be paired
  with the accuracy difference between warm and gated Stage 2.
- The 240 x 32 history maps to 6,240 standard-cell flip-flops (about 42% of
  the mapped area in the full-core synthesis run); no SRAM macro was evaluated.
- Generic technology: no foundry sign-off, density/antenna/EM-IR closure or
  fabrication is claimed.

---

## 7. Design decisions and the evidence for them

| Question | Decision | Evidence |
| --- | --- | --- |
| One shared filter and window for both stages? | No | Inside the official Stage 1 MATLAB pipeline, a shared 1 Hz filter gave Stage 1 92.68% / precision 0.813 / recall 0.950 (12 features) and 84.98% / 0.654 / 0.951 (6 difference features), vs 95.32% / 0.860 / 0.981 deployed. A copy of the deployed evaluator reproduced 95.32% exactly, so the drop is the filter, not the code. |
| Window before the filter (filter restarted per window)? | No | Stage 2 holdout fell from 0.951 to 0.892 (cascade) and from 0.956 to 0.878 (single band-pass); the 0.1-1 Hz corners do not settle in 2 s. With the filter continuous, window placement makes no difference (identical 0.9559). |
| Give Stage 1 Stage 2's 0.1-40 Hz filter? | No | Abnormal recall fell from 0.936 to 0.814 in the Python harness. |
| Stage 2 filter | 3rd-order 1 Hz HP | Best LORO among cheap filters (Section 6.2), and 3rd order instead of an 8th-order band-pass plus DC blocker. |
| Share the feature engine and MAC | Yes | Shared engine reproduces Stage 1 features exactly; Stage 2 needs no feature hardware of its own. |
| Stage 2 feature set | 7 -> 6 | `local_amp_mean` equals `mean_abs` for eight equal blocks; Stage 1's zero-crossing rule replaced the deadband rule (cost 0.002 LORO). |
| Add difference-signal features to Stage 2 | No | LORO 0.845 vs 0.864 (overfits). |
| Tune Stage 2 C or smooth with 2-of-3 | No | <= 0.3 points; errors are whole records, not jitter. |
| Data for evaluation | All eligible windows, fixed rules | Accuracy-based inclusion would measure the selection, not the model. |
| Verifier for Stage 1 false alarms | Open | Software results in 6.3; not yet in RTL. |

Earlier Stage 1 investigations (Q5.8 post-filter widening, record curation,
trained sequence-gate SVM) were examined and not adopted; see
`Documents/paper_reporting_summary.md`.

---

## 8. Limitations and threats to validity

1. Stage 1 false alarms: 51 per hour overall, specificity 0.36 on CUDB, where
   many "normal" windows are likely unannotated ventricular activity. This
   dominates combined precision and per-minute accuracy.
2. Stage 2 generalization: strong within its curated pool (LORO 0.858) but most
   VT in MIT-BIH and in the 8 excluded noisy records is called VF. The pool was
   curated by greedy inclusion; state this.
3. The 4-record Stage 2 holdout (204 windows) is too small to report alone.
4. End-to-end numbers used a simplified fixed-grid gating policy. The RTL
   policy (rephase on trigger, vote-history reset, two-normal disarm, 0.96 s
   Stage 1 replay at 500 Hz) has not been evaluated on held-out continuous
   records.
5. Precision depends on test-set prevalence; report sensitivity, specificity
   and false alarms per hour alongside it.
6. Resampling by linear interpolation does not model an analogue anti-alias
   filter.
7. The official Stage 1 evaluator maps the CUDB folder to MIT-BIH because
   "tachyarrhythmia" contains "arrhythmia" (`database_alias_from_folder`), so
   CUDB normal windows are also thinned to 25%. This slightly favours the
   published precision. The original file was not changed.
8. Hardware power: FPGA power is vectorless and unmeasured; ASIC power is a
   simulation estimate on synthetic normal input at a pessimistic corner with
   Stage 2 inactive; no gating-only experiment exists.

---

## 9. Suggested thesis structure

| Chapter | Content | Sources here |
| --- | --- | --- |
| Introduction | wearable VT/VF detection, power budget, two-stage idea, sustained (>= 30 s) vs non-sustained VT | Sections 1, 4 |
| Background and related work | ECG features, linear SVMs, fixed point, clock gating; comparison table | conference draft Table I; `Documents/asic_paper_reporting_data.md` 10.4 |
| Data and labelling | databases, labels, windows, splits, curation | Section 1 |
| Algorithm design | front end, both stages, features, classifiers, design decisions | Sections 2, 3, 7 |
| Fixed-point design and verification | formats, MATLAB/Python/RTL parity | Sections 2.3, 3, 6.2, 6.4 |
| Hardware architecture | shared datapath, history, scheduler, adaptive clock, enable/disable policy | Section 4, `FinalRTLSummary.md` |
| Results | Stage 1, Stage 2, combined, long-term, FPGA, ASIC | Section 6 |
| Discussion | false alarms, generalization, verifier, patient-specific calibration as future work | Sections 6.3, 8 |
| Conclusion and future work | open items | Section 8, FINAL_DESIGN_README Section 7 |

Figures: see FINAL_DESIGN_README Section 4.6. Use the power-aware design
drawing (`E:\Thesis\Publication_Figures\2 Stage Power Aware Design.drawio`)
or the common-architecture exports for the hardware chapter, the datapath
figure for the algorithm chapter, and the confusion matrices for results.
Check the hardware figure against Section 4 before use: the adaptive clock,
the enable/disable policy and the two separate filters must all appear.
