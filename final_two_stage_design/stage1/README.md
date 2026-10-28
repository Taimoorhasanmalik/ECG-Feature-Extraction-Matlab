# Final Low-Power Design

This folder contains the final low-power Stage 1 Normal vs Abnormal design package for the thesis.

## Selected Design

Model type: Q3.8 fixed-point, mean-only, Pan-Tompkins-style high-pass, linear SVM.

Task: classify ECG windows as `Normal` or `Abnormal`.

Windowing:

- Sampling rate: 120 Hz
- Window length: 2 seconds
- Step size: 1 second
- Sequence length: 3 consecutive windows

Final base features:

- `mean_abs`
- `zero_crossings`
- `line_length`
- `threshold_crossing_count`

Dropped features:

- `rms_amplitude`
- `robust_range`

## Files

- `code/train_q38_recall90_guard98_gate_fix_q38_meanonly_pthighpass.m`
  - Training script for the final 4-feature high-pass base model.

- `code/eval_pthighpass_seq_120hz.m`
  - Short runnable sequence-test script.
  - This version uses `models/pthighpass_svm_cpu_export.mat` for CPU scoring because the saved SVM object has GPU-backed internals.

- `code/evaluate_q38_sequence_count_hard_rule_fix_meanonly_pthighpass_120hz.m`
  - Original long-name evaluator kept for traceability.
  - MATLAB cannot run it directly by name because the filename exceeds MATLAB's function-name length limit.

- `models/stage1_normal_vs_abnormal_window_quantized_q3_8_fix_meanonly_pthighpass_recall90_guard98_robust_lsvm_120hz_without_rms_amplitude_robust_range.mat`
  - Final trained base model artifact.

- `models/pthighpass_svm_cpu_export.mat`
  - CPU/export form of the linear SVM weights, bias, standardization values, and threshold.

- `docs/stage1_highpass_sequence_tradeoff.md`
  - One-page explanation of the base-vs-sequence operating-point tradeoff.

## Final Base Model Metrics

Base model alone:

- Accuracy: 91.93%
- Precision: 0.5483
- Recall: 0.9734
- F1: 0.7015
- AUC: 0.9855

## Selected Sequence Logic

The selected sequence operating point is `2 out of 3`.

Rule:

`Abnormal` if at least 2 of the last 3 windows are classified as abnormal by the base model.

Holdout metrics:

- Accuracy: 95.32%
- Precision: 0.8596
- Recall: 0.9806
- F1: 0.9161

This is the selected thesis operating point because it keeps abnormal recall very high while greatly reducing false positives compared with the base model.

## Reproducing The Sequence Test

From the repository root:

```matlab
addpath('final_low_power_design/code');
eval_pthighpass_seq_120hz
```

The script expects the same database layout used by the main repository. The model and CPU export are included in this folder, but the ECG databases are not copied because they are large.
