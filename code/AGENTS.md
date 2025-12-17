# Repository Guidelines

## Project Structure & Module Organization
MATLAB sources live directly in `code/` and follow a feature-based naming scheme (`train_afib.m`, `inference_VT.m`, etc.). Shared signal-processing helpers such as `pan_tompkin.m`, `calc_rr.m`, and `calc_qs.m` power both training and inference flows. `pan_tompkin` now returns an extra `window_features` struct (2 s bandpass stats) alongside the fiducial outputs—every caller must capture or ignore this ninth return value explicitly; requesting further outputs yields `detector_state` (adaptive thresholds) plus optional P-wave fiducials. Raw ECG records plus annotations are expected under `databases/<dataset>/`. Model artifacts (`afib_model.mat`, `vt_model.mat`, `vf_model.mat`) stay beside the scripts that create them; keep generated plots or diagnostics in a sibling `outputs/` directory (e.g., `outputs/pan_tompkin_windows.png`), and stash reusable smoke data/scripts under `tests/` (see `tests/test_pan_tompkin_features.m`).

## Build, Test & Development Commands
- `matlab -batch "train_afib"` — launches AFIB training with the default dataset, prints k-fold metrics, and saves `afib_model.mat`.
- `matlab -batch "train_VT"` — performs VT training and writes `vt_model.mat`.
- `matlab -batch "inference_afib"` / `matlab -batch "inference_VT"` — runs per-file inference; edit the script header variables to target specific records. `inference_VT.m` currently loads `vf_model.mat` and expects `vf_svm_model`; keep that pairing or update both when you regenerate VT weights.
- `matlab -batch "pan_tompkin_demo"` (optional helper section) — quickly validates R-peak detection if you add a short harness around `pan_tompkin`.

## Coding Style & Naming Conventions
Use 4-space indentation, all-lowercase function names with underscores, and descriptive variable names that reflect ECG concepts (`rr_int`, `vt_labels`). Favor vectorized MATLAB operations over loops. Document non-obvious logic with concise `%` comments, especially around annotation parsing or threshold tuning; call out deviations like the absolute-derivative envelope, forward-only threshold relaxation, left/right QRS search windows, and the P-wave detection window inside `pan_tompkin`. When adding scripts, mirror the existing `train_<rhythm>.m` pattern for discoverability and thread new helper outputs (e.g., `window_features`, optional `detector_state`, P fiducials) end-to-end.

## Testing Guidelines
Every change that touches feature extraction should at least re-run `pan_tompkin` on a known clean record (e.g., `databases/mitdb/100`) and confirm expected peak counts. Training scripts already print accuracy, precision, recall, F1, and AUC per fold—capture these logs in PR notes. For regressions, build lightweight smoke tests that load `*.mat` models and execute a few beats through `inference_*` scripts; store helper tests under `tests/` if they become reusable. Use `tests/test_pan_tompkin_features.m` as the pattern—it validates the extra `window_features` fields, overlays WFDB beat and rhythm annotations (and prints their time spans), and drops a visualization into `outputs/`. When comparing algorithm versions, run `tests/compare_pan_tompkin_versions.m` to get percentage agreement and overlay plots saved under `outputs/`.

## Commit & Pull Request Guidelines
Recent history shows concise, imperative subjects (“Trying Window sizing”, “Deliverable 1 Complete”). Follow that pattern, keep subjects ≤72 chars, and describe *what* and *why* in the body when needed. PRs should link to relevant issues, list datasets used, include metric deltas, and attach screenshots of inference plots when visual changes occur. Mention any new dependencies or MATLAB toolboxes so reviewers can reproduce the run.
