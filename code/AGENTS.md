# Repository Guidelines

## Project Structure & Module Organization

This repository contains MATLAB ECG classification code plus Verilog modules for FPGA-side ECG data ingestion.

- `code/` contains all MATLAB scripts and functions.
- `code/pan_tompkin.m` implements QRS/R-peak detection and Q/Q/S/T peak extraction.
- `code/calc_rr.m` and `code/calc_qs.m` compute interval features.
- `code/train_*.m` scripts train SVM classifiers.
- `code/inference_*.m` scripts load saved models and evaluate/plot predictions.
- `code/Seizure_detect.v` is an older floating-point classifier module for `W*X + b`.
- `code/SD_Card_Interfacing/` contains Verilog for SD-card SPI/FAT reading, MIT-BIH format-212 decoding, accumulation, UART output, and small testbenches.
- `models/` stores trained `.mat` model artifacts.
- Dataset folders are expected locally under repo-root `databases/` using PhysioNet folder names. Do not commit raw ECG database files unless explicitly required.
- `Documents/` and `Relevant_Papers/` contain project reference material.

## Build, Test, and Development Commands

Run scripts from MATLAB with the repository root or `code/` on the MATLAB path.

```matlab
cd code
train_afib
train_VT
train_P
train_normal_vs_abnormal_window_features
inference_afib
inference_VT
inference_P
```

The beat-level scripts require WFDB-style functions such as `rdsamp` and `rdann`. The Q3.8 sequence-gate trainer includes fallback readers for MIT-BIH format-212 files and defaults to the repo-local full-database layout:

```text
databases/mit-bih-arrhythmia-database-1.0.0
databases/mit-bih-malignant-ventricular-ectopy-database-1.0.0
databases/cu-ventricular-tachyarrhythmia-database-1.0.0
```

Do not require environment variables for the default full-database training path. Use env vars only as explicit overrides.

Verilog testbenches can be run with an external simulator if installed:

```powershell
iverilog -o mit212_tb SD_Card_Interfacing/mit212_decoder.v SD_Card_Interfacing/mit212_decoder_tb.v
vvp mit212_tb
```

## Coding Style & Naming Conventions

Use MATLAB script/function style already present in `code/`. Prefer clear names such as `R_peaks_ind`, `featureNames`, and `class_weights`. Use 4-space indentation for MATLAB blocks. Keep feature extraction deterministic and avoid hidden dependencies on workspace variables.

For Verilog, keep modules Verilog-2001 compatible unless the whole path is migrated. Use active-low reset names consistently (`rstn` or `resetn`), preserve byte-valid/ready handshakes, and keep testbenches named `*_tb.v`.

## Testing Guidelines

There is no formal automated test suite. Validate MATLAB changes by running the relevant training or inference script on a small local dataset first. For model changes, report accuracy, precision, recall, F1, AUC, class counts, and threshold changes.

Latest 100 Hz full-database Q3.8 sequence-gate training used 84 train records and 21 test records. The hardware-simple `count` artifact remains the best high-recall 100 Hz support gate: `models/stage1_q38_sequence3_iterative_lsvm_100hz_count_from_guard98.mat`, accuracy 91.80%, precision 0.7835, recall 0.9316, F1 0.8511, AUC 0.9446. The most feature-rich `count_max_sum_delta_min` artifact reached AUC 0.9697 but lower recall 0.8430.

Latest 120 Hz retraining used 2-second windows, 1-second step, Q3.8 quantization, and the same 84/21 record split. The 120 Hz Stage 1 base model is `models/stage1_normal_vs_abnormal_window_quantized_q3_8_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude.mat`, using `mean_abs`, `zero_crossings`, `line_length`, `threshold_crossing_count`, and `robust_range`; holdout metrics were accuracy 79.35%, precision 0.3141, recall 0.9617, F1 0.4736, AUC 0.9576. The 120 Hz pure sequence-count model is `models/stage1_q38_sequence3_iterative_lsvm_120hz_count_from_guard98.mat`, using only `abnormal_vote_count` over 3 overlapping windows; metrics were accuracy 90.75%, precision 0.7551, recall 0.9357, F1 0.8358, AUC 0.9395. The new hybrid 120 Hz models are `models/stage1_q38_sequence2_window_lsvm_120hz_count_from_guard98.mat` and `models/stage1_q38_sequence3_window_lsvm_120hz_count_from_guard98.mat`; their features are endpoint window features plus only one sequence-derived feature, `abnormal_vote_count`. Metrics were sequence 2: accuracy 93.20%, precision 0.8402, recall 0.8762, F1 0.8579, AUC 0.9701; sequence 3: accuracy 93.48%, precision 0.8583, recall 0.8875, F1 0.8727, AUC 0.9747.

Validate HDL changes with the smallest relevant testbench first, especially `mit212_decoder_tb.v` for format-212 byte packing. For FPGA top-level changes, document board clock, SD-card filename, UART baud rate, and simulator/synthesis tool used.

## Commit & Pull Request Guidelines

Git history uses short descriptive messages, for example `Update README.txt` and `Deliverable 1 Complete`. Use concise imperative messages such as `Fix VT model path` or `Add window feature validation`.

Pull requests should include:

- A brief description of the algorithm or workflow changed.
- Dataset/database used for validation.
- Metrics before and after the change, when model behavior changes.
- Notes about new model artifacts or required local data paths.

## Agent-Specific Instructions

Do not rewrite generated model files unless the task explicitly requires retraining. Preserve existing user data and local database paths. When modifying training logic, keep inference feature ordering synchronized with `featureNames`.

For `train_q38_sequence_gate_iterative.m`, do not overwrite stale artifacts from a different train/test split. Save comparable full-split variants with a distinct suffix such as `_records84_21` when needed.

When modifying HDL data paths, keep the byte order between `mit212_decoder.v`, `accu.v`, and UART output synchronized.
