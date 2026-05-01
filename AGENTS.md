# Agent Instructions

## Project Context
- This repository contains MATLAB code for ECG feature extraction, Pan-Tompkins based processing, and SVM classification of arrhythmia classes.
- Core MATLAB scripts live in `code/`; trained model artifacts are stored in `models/`.
- ECG databases and generated result folders can be large. Do not add new database copies, logs, or validation output unless explicitly requested.

## Development Notes
- Preserve the existing script-oriented MATLAB style unless a refactor is explicitly requested.
- Prefer environment-variable switches already used by the training scripts, such as `ECG_TRAIN_DATABASES` and `ECG_TARGET_SAMPLE_RATE_HZ`, over hard-coded local paths.
- Keep generated `.mat` model files in `models/` and avoid overwriting unrelated model artifacts.
- Use ASCII text for new files unless there is a specific reason to preserve another encoding.

## Verification
- For MATLAB changes, run the narrowest relevant script or validation command when feasible.
- If full training is too expensive, document the lighter syntax or smoke check that was run.
- Before committing, check `git status --short` and make sure large untracked database or output directories are not staged accidentally.
