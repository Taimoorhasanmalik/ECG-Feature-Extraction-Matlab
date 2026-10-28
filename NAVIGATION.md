# Repository Navigation

Status: 2026-10-29. A map of every folder and file group in this repository,
what it contains, whether it belongs to the final design, and whether it is
committed to git (branch `GPU_PC_DATA`, remote `origin` on GitHub).

Reading order for thesis work:

1. [FINAL_DESIGN_README.md](FINAL_DESIGN_README.md) - what was achieved and where the final files are
2. [Documents/thesis_final_results.md](Documents/thesis_final_results.md) - methods, all results, decisions, limitations
3. [FinalRTLSummary.md](FinalRTLSummary.md) - the final hardware in detail
4. This file - how to find anything else

Status labels used below:

- **FINAL**: part of the final design or its evidence
- **SUPPORT**: needed to run or reproduce the final work
- **OLD**: superseded earlier design or result, kept for history
- **EXPLORATION**: experiments that informed decisions but are not the design
- **SCRATCH**: tool output, logs, caches; safe to ignore
- **LOCAL**: kept on disk only, deliberately not in git

---

## 1. Quick lookup

| I need... | Go to |
| --- | --- |
| The final Stage 1 model | `final_two_stage_design/stage1/models/` or `final_low_power_design/models/` (`stage1_..._robust_range.mat`, `pthighpass_svm_cpu_export.mat`) |
| The final Stage 2 model | `hw_shared_pipeline/stage2/results/stage2_shared_alldata.mat` |
| The final RTL (Verilog) | `FinalRTL/rtl/` (standalone) or `final_two_stage_design/hardware/rtl/` (canonical, with testbenches and references) |
| The Vivado project | `final_two_stage_design/hardware/vivado_adaptive_project/two_stage_adaptive.xpr` |
| FPGA resource/timing reports | `final_two_stage_design/hardware/adaptive_clock_test/`, `FinalRTL/reports/` |
| ASIC results (area, power, timing) | `ASIC_Reports_Latest_100kHz_20261020/README.md`, `SUMMARY.csv` |
| Original, unedited Cadence tool reports | `Cadence_Original_Reports_100kHz_20261020/` |
| ASIC scripts | `CadenceASIC100kHz/` (final), `CadencePowerAnalysis/`, `CadenceDirectClockPower/` |
| Stage 1 training / official evaluation | `final_low_power_design/code/` |
| Stage 2 training and validation | `hw_shared_pipeline/stage2/build_stage2_shared.py` |
| Whole-database and long-term evaluation | `hw_shared_pipeline/` (see its README) |
| Confusion matrix figures | `E:\Thesis\Publication_Figures\confusion_*.png` |
| Architecture figures | `E:\Thesis\Publication_Figures\` (see FINAL_DESIGN_README Section 4.6) |
| Results tables for the thesis | `Documents/thesis_final_results.md` Section 6 |
| ASIC write-up for the thesis | `Documents/asic_paper_reporting_data.md`, `Documents/native_100khz_power_pair_report.md` |
| Conference paper draft | `E:\Thesis\ISCAS Template\Conference-LaTeX-template_10-17-19\Two_Stage_Paper_Draft.tex` |
| ECG databases | `E:\Thesis\databases\` (outside the repo, never committed) |

---

## 2. Top-level folders

### Final design and its evidence

| Folder | Status | In git | Contents |
| --- | --- | --- | --- |
| `FinalRTL/` | FINAL | yes | Standalone snapshot of the selected adaptive two-stage RTL: 12 Verilog sources (both stages, shared engine, MAC, adaptive clock, mailbox, Basys 3 top), constraints, demo ROM, simulation smoke tests, synthesis reports. Model coefficients are inside the Verilog. |
| `final_two_stage_design/` | FINAL | yes | `hardware/`: canonical RTL, Python integer references, testbenches, scripts, Vivado projects, power comparisons, adaptive-clock tests. `stage1/`: copy of the deployed Stage 1 model and code. `stage2/` and `test_combined_pipeline*.m`: the OLD Stage 2 and old combined tests. |
| `final_two_stage_240_power_design/` | FINAL | yes | Packaged source snapshot of the 240-entry design used for power comparisons. |
| `final_low_power_design/` | FINAL | yes | The deployed Stage 1: training and official evaluation scripts, model, CPU export, corner sweep. |
| `hw_shared_pipeline/` | FINAL | yes | Final Stage 2 model and code, shared-hardware study, whole-database, train/test, confusion-matrix and long-term evaluations, figure generators. Exploration files inside are listed in its README. |
| `ASIC_Reports_Latest_100kHz_20261020/` | FINAL | yes | Latest routed ASIC results (100 kHz source): area, power, timing, constraints, physical checks, for the adaptive gated and fixed ungated cases. The nested folder of the same name is an older incomplete copy (LOCAL). |
| `Cadence_Original_Reports_100kHz_20261020/` | FINAL | yes | The original Cadence (Genus/Innovus) report files for the same runs, unedited, with a checksum manifest. `Reports Thesis/` is a working copy of the same reports; the `.rar` archive is LOCAL. |
| `CadenceASIC100kHz/` | FINAL | yes | Scripts, constraints and evidence for the final native 100 kHz ASIC runs. |
| `CadencePowerAnalysis/` | SUPPORT | yes | Scripts for the full-core pre-layout power analysis. |
| `CadenceDirectClockPower/` | SUPPORT | yes | Scripts for the direct-clock pipeline-only power pair (the 2.02 uW vs 3.54 uW figure in the paper draft). |
| `CadenceASICImplementation/` | OLD | no (LOCAL) | Earlier routed ASIC run with a 100 MHz source, including large layout exports (GDS, DEF, SPEF). Not the final variant; 211 MB. |
| `Documents/` | FINAL | yes | Thesis and paper write-ups (thesis_final_results.md, ASIC and power reports, novelty audit, earlier summaries) and older Word documents. |

### Supporting code (needed by the final scripts)

| Location | Status | In git | Why it is needed |
| --- | --- | --- | --- |
| `vt_vf_expanded_cohort_feature_ranking_experiment.py`, `vt_vf_morphology_pt_05_40_autocorrelation_experiment.py`, `vt_vf_temporal_stability_feature_experiment.py` (root) | SUPPORT | yes | Record reading, interval labelling, window and feature helpers imported by the Stage 2 and evaluation scripts. |
| `greedy_record_inclusion/vt_vf_seed96_record_holdout_validation.py`, `vt_vf_greedy_record_inclusion_window_holdout.py` | SUPPORT | yes | Define the 38-record Stage 2 pool (`SEED96_ORDER`) and the shared model/data helpers. |
| `greedy_record_inclusion/*shared_window*.py` | EXPLORATION | yes | The window-before-filter experiments cited as evidence. |
| `stage1_greedy_record_inclusion/stage1_greedy_record_inclusion.py` | SUPPORT | yes | Within-record split helper used by the screening scripts. |
| `code/build_vt_vf_sample_labels.m` | SUPPORT | yes | VT / VF sample labeller called by the whole-database MATLAB evaluation. |
| The rest of `greedy_record_inclusion/` and `stage1_greedy_record_inclusion/` | EXPLORATION | no | Greedy record curation, seed sweeps, filter variants. |

### Earlier work and experiments

| Folder | Status | In git | Contents |
| --- | --- | --- | --- |
| `code/` | OLD | partly | Original MATLAB project (Pan-Tompkins, beat-level SVMs, Q3.8 gate trainers). Six tracked files have uncommitted edits made before the final work. |
| `models/` | OLD | partly | Earlier trained models (215 MB on disk; only some tracked). |
| `final_high_power_design/` | EXPLORATION | no | Standalone high-power VT/VF experiment (653 MB, includes very large feature caches). |
| `stage2_hardware_deliverable/` | OLD | no | The previous Stage 2 hardware deliverable (DC blocker + 0.5-40 Hz band-pass, 7 features). |
| `shared_frontend_validation/` | OLD | no | Shared Q3.8 front-end check for the previous Stage 2. |
| `Vivado_FullPipeline_LED/` | separate demo | no | Basys 3 demo of the full pipeline with status LEDs (2026-10-21). See its README. |
| `Vivado_RealECG_LogicAnalyzer/` | separate demo | no | Basys 3 replay of real ECG with logic-analyzer outputs, including a 96 s recording with a 55 s VT episode (2026-10-22). See its README. |
| `publication_figures/` | mixed | no | Figure scripts and PNG exports kept in the repo (the editable thesis figures are in `E:\Thesis\Publication_Figures\`). |
| `results/`, `change_records/` | OLD | no | August-September waveform annotation plots and change logs. |
| `vt_vf_dual_peak_detector_examples*/` | EXPLORATION | no | Example plots from a peak-detector experiment. |
| `Relevant_Papers/` | reference | yes | Related-work PDFs. |
| `tools/` | SUPPORT | no | WFDB MATLAB toolbox. |
| `xsim.dir/`, `__pycache__/`, `.Xil/` | SCRATCH | no | Simulator and Python caches. |

---

## 3. Files in the repository root

| Files | Status | In git | Notes |
| --- | --- | --- | --- |
| `FINAL_DESIGN_README.md`, `NAVIGATION.md`, `FinalRTLSummary.md` | FINAL | yes | Start here. |
| `AGENTS.md` | reference | yes | Instructions for coding agents working in this repo. |
| `README.txt` | OLD | yes | Original 2025 project readme. |
| `CODEX_HANDOFF.md`, `ASTRA_BRIEF.md` | reference | no | Earlier hand-off notes for other assistants. |
| `vt_vf_*.py` and `vt_vf_*.csv` (94 files) | EXPLORATION | 3 modules yes | Stage 2 research history (feature ranking, temporal voting, detector-free experiments). Only the three SUPPORT modules above are committed. |
| `*.tar.gz`, `*.zip`, `*.rar` | LOCAL | no (ignored) | Archives transferred from the AWS ASIC server; several are intermediate attempts. Too large for GitHub. |
| `vivado*.jou/log`, `xsim*`, `xelab*`, `webtalk*`, `transcript`, `*.wdb`, `*.log` | SCRATCH | no | Tool journals, logs and waveform databases. |
| `*.npz` in the root, `Technical Literature Review ... .pdf` | LOCAL | no | Experiment caches and a literature review. |

---

## 4. Outside this repository

| Location | Contents |
| --- | --- |
| `E:\Thesis\databases\` | MIT-BIH Arrhythmia, MIT-BIH Malignant Ventricular Ectopy and CU Ventricular Tachyarrhythmia databases (PhysioNet). Every script reads from here. |
| `E:\Thesis\Publication_Figures\` | Editable drawio figures and PNG exports: architecture, datapath, concept, confusion matrices. |
| `E:\Thesis\ISCAS Template\Conference-LaTeX-template_10-17-19\` | Conference paper draft `Two_Stage_Paper_Draft.tex`. |
| `E:\Thesis\Paper Draft Low Power.tex` | Earlier Stage-1-only paper draft. |
| AWS (`/home/ec2-user/...`) | Raw ASIC waveforms, netlists and checkpoints; see `Documents/asic_paper_reporting_data.md` Section 9. |

---

## 5. Git notes

- Snapshot commits on `GPU_PC_DATA` contain everything marked "yes" above.
- The root `.gitignore` keeps out archives, tool scratch, regenerable caches
  and the older nested ASIC report copy.
- To add something marked LOCAL later, check its size first: GitHub rejects
  files over 100 MB.
