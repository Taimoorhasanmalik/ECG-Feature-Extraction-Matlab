# High-Power VT/VF Experiment Results

## Evaluation protocol

- Task: VT versus true VF classification after the low-power stage has declared a window abnormal.
- Databases: MIT-BIH Arrhythmia Database, MIT-BIH Malignant Ventricular Ectopy Database, and CU Ventricular Tachyarrhythmia Database.
- Dataset: 13,122 two-second windows from 61 records, sampled at 250 Hz with a one-second step.
- Class counts: 7,642 VT windows and 5,480 VF windows.
- Splitting: all primary results use four record-grouped folds. Windows from one record never occur in both training and test data.
- Coverage is reported because causal history and sequence rules cannot classify the first windows of each episode.

## Defensible nested results

These operating points select their adjustable parameters using only the training records inside each outer fold.

| Model | Accuracy | VT precision | VT recall | VF precision | VF recall | VF F1 | Coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| Two-count linear SVM, default boundary | 60.89% | 0.6935 | 0.5865 | 0.5269 | 0.6399 | 0.5779 | 98.29% |
| Two-count linear SVM, precision threshold | 62.44% | 0.6761 | 0.6797 | 0.5517 | 0.5476 | 0.5497 | 98.29% |
| Nested hard sequence, precision objective | **64.61%** | **0.7173** | **0.6704** | **0.5566** | **0.6103** | **0.5822** | 84.46% |
| Nested count-trajectory SVM, precision objective | 63.49% | 0.6753 | 0.7304 | 0.5643 | 0.4985 | 0.5294 | 91.53% |

The nested hard-sequence model is the current most defensible balanced result. Its sequence length and VF vote count are selected independently within each training fold. Its main limitations are reduced coverage and substantial variation between held-out record folds.

## Exploratory high-accuracy operating points

These results use record-pure out-of-fold predictions, but the fusion or final sequence rule was selected after examining the same predictions. They are promising candidates, not unbiased final performance claims.

| Model | Accuracy | VT precision | VT recall | VF precision | VF recall | VF F1 | Coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| Calibrated quadratic organization model | 64.31% | 0.7177 | 0.6368 | 0.5637 | 0.6519 | 0.6046 | 98.29% |
| Organization decision AND nested hard-sequence decision | 67.71% | 0.7107 | 0.7726 | 0.6152 | 0.5362 | 0.5730 | 84.46% |
| Fused decision, 6 VF votes out of 10 | 69.55% | 0.7298 | 0.7889 | 0.6307 | 0.5524 | 0.5890 | 77.49% |
| Fused decision, 14 VF votes out of 20 | **71.30%** | **0.7337** | **0.8358** | **0.6648** | **0.5177** | **0.5821** | 71.37% |

The 14-of-20 result requires about 21 seconds of signal context because two-second windows advance by one second. Its held-out fold accuracies are 54.48%, 78.01%, 77.11%, and 79.70%. The low first-fold result and reduced CUDB coverage mean this operating point requires a new untouched record holdout or fully nested fusion-rule selection before it can be called the final model.

## Features

The hardware-simple two-count model uses:

1. `qualifying_extrema_count`: extrema in the current 1-20 Hz filtered window whose amplitude exceeds an adaptive threshold derived from previous abnormal windows.
2. `candidate_extrema_count`: all local extrema in the current filtered window before applying the adaptive amplitude threshold.

The organization model adds nine relevant features from the existing feature bank:

- `mean_abs`
- `zero_crossings`
- `line_length`
- `threshold_crossing_count`
- `normalized_line_length`
- `crossing_interval_irregularity`
- `autocorrelation_peak`
- `dominant_frequency`
- `spectral_concentration`

Its quadratic implementation explicitly adds pairwise products and squared terms, then trains a linear SVM in the expanded 77-dimensional space.

## Negative and supporting experiments

- Adding qualifying-extrema interval irregularity reduced accuracy to 53.35% for linear SVM and 50.43% for explicit quadratic SVM.
- Explicit quadratic mapping of only the two count features reached 52.91% to 56.51%, depending on configuration, and did not improve the baseline.
- Database-and-record-balanced weighting changed strict nested accuracy only from 60.89% to 60.95%.
- A 15-window raw count-trajectory linear SVM reached 62.94% before nested threshold validation.
- Approximate RBF screening reached 62.15% accuracy, VF precision 0.5320, and VF recall 0.7942. MATLAB could not acquire a supported GPU during this run, so `fitckernel` used the documented CPU fallback.

## Current recommendation

Use the nested hard-sequence result as the thesis-grade result until the fusion rule is tested on untouched records. Retain the 14-of-20 fusion as the leading high-accuracy candidate. To validate it, lock the organization model, hard-sequence model, `AND` fusion, and 14-of-20 rule before evaluating a new record holdout. Do not tune another threshold or vote count on that holdout.

## Beat-level Pan-Tompkins experiment

A separate beat-level linear SVM was trained using Pan-Tompkins R detections and local polarity-aware Q, S, and T searches. The six non-aggregated features are R amplitude, Q amplitude, S amplitude, T amplitude, previous RR, and QRS width. QRS width is the time from the locally detected Q minimum to the locally detected S minimum.

The Pan-Tompkins adaptive R threshold now accepts a sensitivity scale. Scale `1.0` is exactly backward compatible; smaller values lower the adaptive threshold. Five scales were evaluated with four record-grouped folds.

| R threshold scale | Beats | VT beats | VF beats | Accuracy | VT precision | VT recall | VF precision | VF recall |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.35 | 27,400 | 16,741 | 10,659 | 60.03% | 0.7531 | 0.5146 | 0.4909 | 0.7350 |
| **0.50** | **27,101** | **16,601** | **10,500** | **60.33%** | **0.7480** | **0.5313** | **0.4918** | **0.7170** |
| 0.65 | 26,592 | 16,472 | 10,120 | 60.21% | 0.7584 | 0.5249 | 0.4848 | 0.7278 |
| 0.80 | 25,879 | 16,100 | 9,779 | 60.15% | 0.7725 | 0.5095 | 0.4825 | 0.7529 |
| 1.00 | 25,120 | 15,754 | 9,366 | 59.20% | 0.7363 | 0.5444 | 0.4672 | 0.6720 |

The selected scale is `0.50`. Lowering the threshold recovered 1,134 additional VF beats compared with scale `1.0` and improved accuracy by 1.13 percentage points. Database accuracy remains uneven: MITDB 88.80%, VFDB 50.49%, and CUDB 74.13%. This confirms that adjustable sensitivity helps missed VF detections, but beat morphology alone does not yet solve cross-database VT/VF separation.

Beat-level artifacts:

- `models/vtvf_beat_pantompkins_adjustable_threshold_selected_lsvm_250hz.mat`
- `models/vtvf_beat_pantompkins_adjustable_threshold_summary.csv`

## Unsupervised PCA feature-learning experiment

PCA was tested as an unsupervised feature extractor before the linear SVM. PCA and component-count selection were fitted strictly inside each record-grouped training fold.

| PCA input | Accuracy | VT precision | VT recall | VF precision | VF recall | VF F1 |
|---|---:|---:|---:|---:|---:|---:|
| Filtered, centered, RMS-normalized 500-sample waveform | 45.69% | 0.5423 | 0.4321 | 0.3829 | 0.4914 | 0.4304 |
| Log normalized 1-20 Hz power spectrum | 49.40% | 0.6014 | 0.3888 | 0.4291 | 0.6407 | 0.5140 |

Raw-waveform PCA is sensitive to the time position and phase of individual deflections. Spectral PCA removes this phase sensitivity but still learns the largest sources of unsupervised variance, which include patient and database differences rather than only VT/VF structure. Neither PCA representation improves on the engineered-feature or sequence models.

PCA artifacts:

- `models/vtvf_truevf_raw_window_pca_nested4fold_lsvm_250hz.mat`
- `models/vtvf_truevf_spectrum_pca_nested4fold_lsvm_250hz.mat`

Primary artifacts:

- `models/vtvf_truevf_extrema_count_candidate_nested_sequence_250hz.mat`
- `models/vtvf_truevf_extrema_organization_interaction_screen_250hz.mat`
- `models/vtvf_truevf_extrema_model_fusion_screen_250hz.mat`
- `models/vtvf_truevf_extrema_fusion_sequence_screen_250hz.mat`
