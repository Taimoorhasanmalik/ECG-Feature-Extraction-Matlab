# Final Design: Power-Aware Two-Stage ECG VT/VF Classifier

Status: 2026-10-28. This is the entry point for thesis writing. It says what
the project achieved, what the final design is, where every final file lives,
and which files are exploration only.

Detailed methods, every results table, design decisions and limitations are in
[Documents/thesis_final_results.md](Documents/thesis_final_results.md).

---

## 1. What the system does

A single-lead ECG is sampled at 120 Hz. An always-on, very cheap **Stage 1**
decides every second whether the last 2 s of signal is abnormal (VT or any
VF-family rhythm). After 2 of 3 consecutive abnormal decisions it arms
**Stage 2**, which decides VT vs VF. Both stages use linear SVMs on a few
fixed-point features. In hardware the two stages share one feature engine,
one multiply-accumulate (MAC) unit, one window sequencer and one history
memory, and the whole processing clock drops to 500 Hz whenever Stage 2 is
asleep.

## 2. Final architecture

```
ECG (1 lead, 120 samples/s) -> Q3.8 (shared front end)
   |
   |-- Stage 1 path (always on):   3rd-order Butterworth HP 5 Hz -> Q3.8
   |-- Stage 2 path (armed only):  3rd-order Butterworth HP 1 Hz -> Q5.8
   |
   v
shared 240/120 window sequencer + one 240 x 32-bit history (two lanes: 12 + 14 bit)
   |
shared replay feature engine (time-multiplexed)
   |-- slot A, every window:      4 features -> Stage 1 SVM (4 weights + bias)
   |                              -> d[n] = (s1 >= T) -> 2-of-3 vote gate
   |-- slot B, while armed:       6 features -> Stage 2 SVM (6 weights Q3.12 + bias Q2.12)
   |                              -> VT if s2 <= 0, else VF
   v
one shared, clock-gated classifier MAC (weight ROM for both stages)

Gate: arm Stage 2 on >= 2 abnormal votes of 3; disarm after 2 consecutive
normal sequence decisions; started Stage 2 windows finish and report.
Clock: 500 Hz processing while Stage 2 sleeps, 100 kHz while armed/draining.
Outputs: Other = 0, VT = 1, VF-family = 2, Stage 1 abnormal = 3.
```

| | Stage 1 (deployed, unchanged) | Stage 2 (final, redesigned) |
| --- | --- | --- |
| Filter | causal 3rd-order Butterworth high-pass, 5 Hz | causal 3rd-order Butterworth high-pass, 1 Hz |
| Post-filter format | Q3.8 | Q5.8 |
| Features | mean_abs, zero_crossings (of first difference), line_length, threshold_crossing_count | the same 4 + local_amp_range, amp_transition |
| Classifier | linear SVM, threshold for >= 98% training recall, 2-of-3 vote | linear SVM, Q3.12 weights, Q2.12 bias |
| Runs | every window | only while armed |

Why separate filters but shared everything else: a single shared filter was
tested and costs Stage 1 accuracy (Section 6). Filters must run continuously,
so each stage keeps its own filter; windows, features and the MAC are shared.

## 3. Headline results

All numbers below come from runs on the MIT-BIH Arrhythmia (48 records),
MIT-BIH Malignant Ventricular Ectopy (22) and CU Ventricular Tachyarrhythmia
(35) databases. Full tables and definitions: Documents/thesis_final_results.md.

| Result | Value |
| --- | --- |
| Stage 1, official protocol, 21 held-out test records | acc 95.32%, precision 0.860, sensitivity 0.981, specificity 0.944, F1 0.916 |
| Stage 1, official protocol, train + test (105 records) | acc 88.27%, precision 0.726, sensitivity 0.981, specificity 0.840, F1 0.835 |
| Stage 1, sustained (>= 30 s) episodes detected | 66 / 66 (100%), median 0 s, 90th percentile 1-2 s after onset |
| Stage 1, false alarms in continuous recording | 51 per hour overall (38 per hour on test records); main open problem |
| Stage 2, 38-record pool, leave-one-record-out (honest) | acc 0.858 (VT sens 0.718, VF sens 0.932) |
| Stage 2, deployed model, train + test pool | acc 0.903 (VT sens 0.836, VF sens 0.938) |
| Stage 2 fixed point | MATLAB = Python on every test window (0 mismatches, max feature difference 0); RTL bit-exact vs Python reference |
| Combined, true VT/VF windows flagged and correctly typed | 0.896 (Stage 2 filter always warm), 0.883 (fully gated); old design 0.895 on a sustained-VT basis |
| FPGA (Basys 3, adaptive board wrapper, routed) | 5,172 LUTs, 2,404 FFs, 48 DSPs, 2 RAMB18; earlier parallel design 14,205 LUTs / 76 DSPs |
| ASIC (generic 45 nm GPDK045, routed, DRC/LVS pass) | 2.274 uW adaptive gated vs 4.214 uW fixed ungated (-46.0% total, -98.4% dynamic), 0.1176 mm^2 cell area |

Read the limitations before quoting these (Section 7 and the thesis doc).
In particular the combined 0.896 / 0.883 counts only true VT/VF windows; the
per-window view including normal time is much lower because of Stage 1 false
alarms.

## 4. Where the final files are

Paths are relative to `E:\Thesis\ECG-Feature-Extraction-Matlab\` unless they
start with `E:\Thesis\`.

### 4.1 Trained models

| What | File |
| --- | --- |
| Stage 1 deployed model | `final_two_stage_design/stage1/models/stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_pthighpass_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude_robust_range.mat` (identical copy in `final_low_power_design/models/`) |
| Stage 1 scoring export used by the official evaluator | `final_low_power_design/models/pthighpass_svm_cpu_export.mat` |
| **Stage 2 deployed model** (6 weights, bias, filter settings, feature formats, all 5,541 training windows) | `hw_shared_pipeline/stage2/results/stage2_shared_alldata.mat` |
| Stage 2 model trained on 34 records (4-record holdout check) | `hw_shared_pipeline/stage2/results/stage2_shared_holdout.mat` |
| Stage 2 leave-one-record-out weights (38 sets) | `hw_shared_pipeline/stage2/results/stage2_shared_loro_weights.mat` |

The RTL and ASIC have these coefficients frozen as constants
(`shared_classifier_mac_q.v`, `stage2_shared_hp1_q29.v`). If a model is
retrained, the RTL constants must be regenerated.

### 4.2 Algorithm and training code

| What | File |
| --- | --- |
| Stage 1 training (deployed recipe) | `final_low_power_design/code/train_q38_recall90_guard98_gate_fix_q38_meanonly_pthighpass.m` |
| Stage 1 official evaluation (reproduces 95.32%) | `final_low_power_design/code/eval_pthighpass_seq_120hz.m` |
| Stage 2 build, validation and export | `hw_shared_pipeline/stage2/build_stage2_shared.py` |
| Stage 2 leave-one-record-out export | `hw_shared_pipeline/stage2/export_stage2_loro.py` |
| Stage 2 MATLAB fixed-point parity check | `hw_shared_pipeline/matlab/validate_stage2_shared.m` |

### 4.3 Hardware (RTL, FPGA)

| What | Location |
| --- | --- |
| Canonical hardware directory (RTL, Python integer references, testbenches, scripts, reports) | `final_two_stage_design/hardware/` (see its `README.md`) |
| Saved adaptive Vivado project | `final_two_stage_design/hardware/vivado_adaptive_project/two_stage_adaptive.xpr` |
| Standalone RTL snapshot of the selected adaptive design | `FinalRTL/` (see `FinalRTL/README.md`) |
| Full architecture and verification description | `FinalRTLSummary.md` |
| Routed resource report of the adaptive board design | `final_two_stage_design/hardware/adaptive_clock_test/mode1_resources.rpt` |
| Earlier power/area comparisons (FPGA) | `final_two_stage_design/hardware/power_comparison/`, `Documents/two_stage_clock_buffer_area_power_tradeoff.md`, `Documents/two_stage_idle_clock_gating_power.md` |

### 4.4 ASIC

| What | Location |
| --- | --- |
| **Latest ASIC results (100 kHz source, routed, area/power/timing)** | `ASIC_Reports_Latest_100kHz_20261020/` (start with its `README.md`, `SUMMARY.csv`) |
| Scripts for the latest ASIC runs | `CadenceASIC100kHz/` |
| Earlier routed run (100 MHz source) and delivery | `CadenceASICImplementation/` |
| ASIC summary for writing | `Documents/asic_paper_reporting_data.md` |
| Native 100 kHz gated vs ungated comparison | `Documents/native_100khz_power_pair_report.md` |
| Shared-history storage and novelty audit | `Documents/shared_ram_area_and_paper_novelty_audit.md` |

### 4.5 Evaluation scripts and results (`hw_shared_pipeline/`)

| Purpose | Script | Output |
| --- | --- | --- |
| End-to-end test (Stage 1 gating Stage 2, warm and cold start) | `matlab/test_two_stage_hw_shared.m` | printed |
| Whole-database per-window run (all 105 records) | `matlab/evaluate_whole_database.m` | `results/whole_database_windows.mat` |
| Official Stage 1 protocol on test / train / all | `matlab/eval_shared_stage1_seq.m` (`ECG_EVAL_SPLIT=test|train|all`) | printed |
| Train / test metrics tables | `report_train_test_metrics.py` | printed |
| Confusion matrices (window level) | `confusion_matrices.py` | `results/confusion_matrices.json`, `results/stage2_all_records_windows.npz` |
| Long-term metrics (episodes, false alarms per hour) | `long_term_metrics.py` | printed |
| Long-term confusion matrices (per minute, per episode) | `long_term_confusion.py` | `results/long_term_confusion.json` |

### 4.6 Figures

| Figure | File |
| --- | --- |
| Power-aware two-stage architecture (editable, single page, last edited 2026-10-16) | `E:\Thesis\Publication_Figures\2 Stage Power Aware Design.drawio`; PNG export in `publication_figures/2 Stage Power Aware Design.drawio (1).png`. `FinalRTLSummary.md` names a page "Implemented adaptive RTL" in a `(1).drawio` file; that file and page were not found on 2026-10-28. |
| Shared datapath in thesis style, real traces | `E:\Thesis\Publication_Figures\hw_shared_two_stage_datapath.drawio` |
| Compact concept figure | `E:\Thesis\Publication_Figures\hw_shared_two_stage_concept.drawio` |
| Common architecture and pipeline exports | `E:\Thesis\Publication_Figures\Common Architecture.drawio*.png`, `ECG Arrhythmia Detection Pipeline.png`, `Circular Ram.png` |
| Confusion matrices | `E:\Thesis\Publication_Figures\confusion_stage1.png`, `confusion_stage2.png`, `confusion_longterm.png` |

Generator scripts for the datapath, concept and confusion figures are in
`hw_shared_pipeline/figures/` and `hw_shared_pipeline/*confusion*.py`;
rerunning them overwrites manual draw.io edits.

### 4.7 Documents and drafts

| What | Location |
| --- | --- |
| Thesis methods/results reference | `Documents/thesis_final_results.md` |
| Folder guide for the shared-design evaluation work | `hw_shared_pipeline/README.md` |
| Earlier consolidated results (Stage 1 investigations) | `Documents/paper_reporting_summary.md` |
| Conference paper draft (last edited 2026-10-14) | `E:\Thesis\ISCAS Template\Conference-LaTeX-template_10-17-19\Two_Stage_Paper_Draft.tex` |
| Supervisor progress brief | https://claude.ai/artifact/RfTfJTAjqZaYn58jUqCyfw (private until shared) |

## 5. Reproducing the key numbers

From the repository root (MATLAB R2024b, Python 3 with NumPy/SciPy/scikit-learn/wfdb;
databases in `E:\Thesis\databases\`):

```
# Stage 1 official protocol (95.32% on test); run inside final_low_power_design/code
matlab -batch "eval_pthighpass_seq_120hz"

# Stage 2: build, validate (LORO 0.858), export; then LORO weights
python hw_shared_pipeline/stage2/build_stage2_shared.py
python hw_shared_pipeline/stage2/export_stage2_loro.py

# Stage 2 MATLAB fixed-point parity; end-to-end; whole database (inside hw_shared_pipeline/matlab)
matlab -batch "validate_stage2_shared"
matlab -batch "test_two_stage_hw_shared"
matlab -batch "evaluate_whole_database"

# Tables, confusion matrices, long-term metrics
python hw_shared_pipeline/report_train_test_metrics.py
python hw_shared_pipeline/confusion_matrices.py
python hw_shared_pipeline/long_term_metrics.py
python hw_shared_pipeline/long_term_confusion.py
```

Hardware verification and builds: see `final_two_stage_design/hardware/README.md`
and `FinalRTL/README.md`. ASIC runs: `CadenceASIC100kHz/README.md`.

## 6. Not part of the final design

| Item | Status | Where |
| --- | --- | --- |
| One shared 1 Hz filter for both stages (Stage 1 with 12 or 6 features) | Rejected: Stage 1 92.68% / 0.813 / 0.950 and 84.98% / 0.654 / 0.951 vs 95.32% / 0.860 / 0.981 | `hw_shared_pipeline/models/shared_stage1_*.mat`, `matlab/train_shared_stage1.m` |
| Window before filter (filter restarted per window) | Rejected: about 8 points lost in Stage 2 | `greedy_record_inclusion/*shared_window*.py` |
| Old Stage 2 (0.1 Hz DC blocker + 0.5-40 Hz band-pass, 7 features, Q2.13) | Superseded | `final_two_stage_design/stage2/`, `stage2_hardware_deliverable/` |
| Old combined tests | Superseded | `final_two_stage_design/test_combined_pipeline*.m` |
| Filter-sweep and screening scripts | Exploration | `hw_shared_pipeline/extract_shared_candidates.py`, `evaluate_shared_candidates.py`, `extract_diff_on_read.py`, `evaluate_official_protocol.py`, `results/shared_*.npz`, `results/diff_*.npz` |
| Stage 2 verifier (extra 4-weight SVM rejecting Stage 1 false alarms) | Proposed, evaluated in software only, not in RTL | `hw_shared_pipeline/stage2/train_stage2_verifier.py`, `stage2/results/stage2_verifier_summary.json` |
| Superseded figures | Old | `E:\Thesis\Publication_Figures\hw_shared_two_stage_pipeline.drawio`, `hw_shared_two_stage_block_diagram.drawio`, `2 stage desgin.drawio`, `2 stage design compact.drawio` |

## 7. Open items before claiming final clinical numbers

1. Stage 1 false alarms (51 per hour; specificity 0.36 on CUDB) are the main
   weakness; the verifier halves them in software but is not in the RTL.
2. Stage 2 does not generalise beyond its curated 38-record pool (MIT-BIH VT
   and the 8 excluded noisy VFDB records are mostly called VF).
3. The RTL's exact activation policy (rephase on trigger, vote-history reset,
   two-normal disarm, 500 Hz Stage 1 replay delay) has not been evaluated end
   to end on held-out continuous records; the software end-to-end test used a
   simpler fixed-grid policy.
4. ASIC power runs use synthetic normal input with Stage 2 inactive, at a
   pessimistic 0.9 V / 125 C corner; they do not measure active Stage 2 power
   and must not be paired with accuracy numbers as a trade-off.
5. Nothing in this work is committed to git: `hw_shared_pipeline/`, `FinalRTL/`,
   the hardware and ASIC folders are untracked. Commit before further changes.
