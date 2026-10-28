# hw_shared_pipeline: shared-hardware design, final Stage 2 and evaluation

Status: 2026-10-28. This folder holds the work that produced the final Stage 2
model, the decision to share the feature engine and MAC between the stages,
and every evaluation of the final design. For the project overview and the
location of all final files (including RTL and ASIC), start with
[../FINAL_DESIGN_README.md](../FINAL_DESIGN_README.md). Methods and full
results tables: [../Documents/thesis_final_results.md](../Documents/thesis_final_results.md).

Nothing outside this folder was modified by this work. The deployed Stage 1
model and the official Stage 1 scripts are used read-only.

## What was decided here

| Question | Answer |
| --- | --- |
| Can both stages use one filter and one window? | No. A shared 1 Hz filter lowered Stage 1 to 92.68% / 0.813 / 0.950 in the official MATLAB protocol (deployed: 95.32% / 0.860 / 0.981). |
| What can be shared? | The front end, the window sequencer and history, one feature engine (bit-exact for Stage 1) and one MAC. |
| Final Stage 2 | 3rd-order 1 Hz high-pass, Q5.8, 6 shared-engine features, linear SVM with Q3.12 weights. LORO 0.858 (previous design 0.808 for the 0.1-40 Hz band-pass). |
| Fixed point | MATLAB equals Python on every test window; the RTL matches the Python integer reference. |

## Final files in this folder

| File | Purpose |
| --- | --- |
| `stage2/build_stage2_shared.py` | Extracts Stage 2 windows with the shared front end, sizes feature formats, validates (LORO, 5-fold, 4-record holdout), exports models |
| `stage2/export_stage2_loro.py` | Exports the 38 leave-one-record-out weight sets |
| `stage2/results/stage2_shared_alldata.mat` | **Deployed Stage 2 model** (frozen into the RTL) |
| `stage2/results/stage2_shared_holdout.mat` | Model trained on 34 records, for the 4-record holdout and MATLAB parity |
| `stage2/results/stage2_shared_loro_weights.mat` | LORO weights for honest evaluation |
| `stage2/results/stage2_shared_summary.json` | Validation summary |
| `matlab/validate_stage2_shared.m` | MATLAB fixed-point recomputation from raw records; writes `stage2/results/matlab_stage2_shared_comparison.csv` |
| `matlab/test_two_stage_hw_shared.m` | End-to-end: deployed Stage 1 gating the final Stage 2, warm and cold start, all-data and LORO |
| `matlab/evaluate_whole_database.m` | Streams all 105 records through both stages; writes `results/whole_database_windows.mat` (per-window truth, decisions, features) |
| `matlab/eval_shared_stage1_seq.m` | Copy of the official Stage 1 evaluator with a `ECG_SHARED_VARIANT` switch and `ECG_EVAL_SPLIT=test|train|all` |
| `report_train_test_metrics.py` | Train / test / train+test tables for Stage 1, Stage 2 and the combined system |
| `confusion_matrices.py` | Window-level confusion matrices (writes `results/confusion_matrices.json`, figures in `E:\Thesis\Publication_Figures\confusion_stage*.png`) |
| `long_term_metrics.py` | Episode detection, latency, false alarms per hour, per-episode Stage 2 |
| `long_term_confusion.py` | Per-minute and per-episode confusion matrices (`results/long_term_confusion.json`, `confusion_longterm.png`) |
| `figures/make_shared_datapath_figure.py` | Generates `E:\Thesis\Publication_Figures\hw_shared_two_stage_datapath.drawio` |
| `figures/make_concept_diagram.py` | Generates `hw_shared_two_stage_concept.drawio` |

## Exploration and evidence (not the final design)

| File | What it shows |
| --- | --- |
| `extract_shared_candidates.py`, `evaluate_shared_candidates.py`, `results/shared_*.npz` | Filter sweep (5 Hz to 0.1-40 Hz) for one shared filter; Stage 2 LORO per filter |
| `extract_diff_on_read.py`, `results/diff_*.npz` | Stage 1 reading x[n]-x[n-1] from a shared window |
| `evaluate_official_protocol.py` | Python approximation of the official Stage 1 protocol; does not reproduce MATLAB's cleaning, so absolute numbers differ |
| `matlab/train_shared_stage1.m`, `models/shared_stage1_shared12_120hz.mat`, `models/shared_stage1_shared6diff_120hz.mat` | The rejected shared-filter Stage 1 models, trained with the official recipe |
| `stage2/train_stage2_verifier.py`, `stage2/results/stage2_verifier_summary.json` | Proposed verifier SVM that rejects Stage 1 false alarms (software only) |
| `figures/make_pipeline_figure.py`, `figures/*preview*` | Earlier figure version and previews |

## Reproduce

From the repository root:

```
python hw_shared_pipeline/stage2/build_stage2_shared.py
python hw_shared_pipeline/stage2/export_stage2_loro.py
cd hw_shared_pipeline/matlab
matlab -batch "validate_stage2_shared"
matlab -batch "test_two_stage_hw_shared"
matlab -batch "evaluate_whole_database"
cd ../..
python hw_shared_pipeline/report_train_test_metrics.py
python hw_shared_pipeline/confusion_matrices.py
python hw_shared_pipeline/long_term_metrics.py
python hw_shared_pipeline/long_term_confusion.py
```

Official Stage 1 protocol on train and all records (deployed model):

```
cd hw_shared_pipeline/matlab
set ECG_SHARED_VARIANT=baseline
set ECG_BASE_WINDOW_MODEL_FILE=<repo>/final_low_power_design/models/stage1_..._robust_range.mat
set ECG_BASE_WINDOW_CPU_EXPORT_FILE=<repo>/final_low_power_design/models/pthighpass_svm_cpu_export.mat
set ECG_EVAL_SPLIT=all
matlab -batch "eval_shared_stage1_seq"
```

## Notes

- `evaluate_whole_database.m` derives the database name from folder order. The
  official helper `database_alias_from_folder` maps CUDB to MIT-BIH, which also
  causes the official evaluator to thin CUDB normal windows.
- The CUDB "VT" produced by `build_vt_vf_sample_labels` comes from a pre-VF
  lead-in heuristic, not from annotations; Stage 2 evaluations flag and
  exclude it where stated.
- Large caches (`results/*.npz`, `results/whole_database_windows.mat`) are
  regenerated by the scripts above.
