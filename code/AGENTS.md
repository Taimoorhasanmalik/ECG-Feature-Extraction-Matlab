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
- Dataset folders such as `databases/` or `Database/<name>/` are expected locally and may be large; do not commit raw ECG database files unless explicitly required.
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

The beat-level scripts require WFDB-style functions such as `rdsamp` and `rdann`. The window-based normal-vs-abnormal trainer includes fallback readers for some WFDB files.

To select databases for the window trainer:

```powershell
$env:ECG_TRAIN_DATABASES = "mitdb,vfdb,cudb"
```

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

When modifying HDL data paths, keep the byte order between `mit212_decoder.v`, `accu.v`, and UART output synchronized.
