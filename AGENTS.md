# Agent Instructions

## Project Context
- This repository contains MATLAB code for ECG feature extraction, Pan-Tompkins based processing, and SVM classification of arrhythmia classes.
- Core MATLAB scripts live in `code/`; trained model artifacts are stored in `models/`.
- ECG databases and generated result folders can be large. Do not add new database copies, logs, or validation output unless explicitly requested.

## Development Notes
- Preserve the existing script-oriented MATLAB style unless a refactor is explicitly requested.
- The full ECG databases are expected under repo-local `databases/` using the PhysioNet folder names:
  - `databases/mit-bih-arrhythmia-database-1.0.0`
  - `databases/mit-bih-malignant-ventricular-ectopy-database-1.0.0`
  - `databases/cu-ventricular-tachyarrhythmia-database-1.0.0`
- Do not require environment variables for the default full-database training path. Use env vars only as optional overrides when explicitly requested.
- Keep generated `.mat` model files in `models/` and avoid overwriting unrelated model artifacts.
- For sequence-gate retraining, do not overwrite stale artifacts from a different record split. Save full-split variants with a distinct suffix such as `_records84_21` when needed.
- Use ASCII text for new files unless there is a specific reason to preserve another encoding.

## Current Sequence-Gate Results
- `code/train_q38_sequence_gate_iterative.m` trains the Q3.8 sequence-level support gate on 3 consecutive windows.
- Latest full-database split: 84 train records, 21 test records.
- Best high-recall hardware-simple model remains `count`:
  - artifact: `models/stage1_q38_sequence3_iterative_lsvm_100hz_count_from_guard98.mat`
  - metrics: accuracy 91.80%, precision 0.7835, recall 0.9316, F1 0.8511, AUC 0.9446
- More feature-rich variants improve AUC but reduce recall:
  - `count_max_sum_delta_min`: accuracy 91.44%, precision 0.8216, recall 0.8430, F1 0.8322, AUC 0.9697
- Hardware interpretation of cumulative sequence features:
  - `count`: number of abnormal base-window decisions in 3 consecutive windows
  - `max`: maximum abnormal score across the 3 windows
  - `sum`: sum of abnormal scores across the 3 windows
  - `delta`: last score minus first score
  - `min`: minimum abnormal score across the 3 windows

## Current 120 Hz Retraining Results
- Latest 120 Hz retraining used 2-second windows, 1-second step, Q3.8 quantization, 84 train records, and 21 test records.
- Stage 1 120 Hz base model:
  - artifact: `models/stage1_normal_vs_abnormal_window_quantized_q3_8_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude.mat`
  - features: `mean_abs`, `zero_crossings`, `line_length`, `threshold_crossing_count`, `robust_range`
  - metrics: accuracy 79.35%, precision 0.3141, recall 0.9617, F1 0.4736, AUC 0.9576
- 120 Hz pure sequence-count model:
  - artifact: `models/stage1_q38_sequence3_iterative_lsvm_120hz_count_from_guard98.mat`
  - feature: `abnormal_vote_count` over 3 consecutive overlapping windows
  - metrics: accuracy 90.75%, precision 0.7551, recall 0.9357, F1 0.8358, AUC 0.9395
- 120 Hz hybrid sequence/window count models:
  - sequence 2 artifact: `models/stage1_q38_sequence2_window_lsvm_120hz_count_from_guard98.mat`, metrics: accuracy 93.20%, precision 0.8402, recall 0.8762, F1 0.8579, AUC 0.9701
  - sequence 3 artifact: `models/stage1_q38_sequence3_window_lsvm_120hz_count_from_guard98.mat`, metrics: accuracy 93.48%, precision 0.8583, recall 0.8875, F1 0.8727, AUC 0.9747
  - features: endpoint window `mean_abs`, `zero_crossings`, `line_length`, `threshold_crossing_count`, `robust_range`, plus only one sequence-derived feature: `abnormal_vote_count`
- `abnormal_vote_count` is the count of recent base Stage 1 window decisions with score >= `baseDecisionThreshold`; at 120 Hz the base threshold is -1.059938192.

## Verification
- For MATLAB changes, run the narrowest relevant script or validation command when feasible.
- If full training is too expensive, document the lighter syntax or smoke check that was run.
- Before committing, check `git status --short` and make sure large untracked database or output directories are not staged accidentally.
