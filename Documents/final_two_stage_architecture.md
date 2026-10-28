# Final Two-Stage Architecture

The final system is a two-stage ECG arrhythmia classification pipeline. The first stage is a low-power Normal vs Abnormal gate, and the second stage is a high-power VT vs VF classifier. This separation is intentional: the low-power model runs continuously, while the high-power model is activated only when the signal is likely abnormal.

## Stage 1: Low-Power Normal vs Abnormal Gate

Stage 1 uses the final Q3.8 fixed-point high-pass model with four simple features:

- `mean_abs`
- `zero_crossings`
- `line_length`
- `threshold_crossing_count`

The selected sequence operating point is the 2-of-3 abnormal vote rule. A window sequence is considered abnormal if at least two of the last three windows are classified as abnormal by the base model.

The selected Stage 1 sequence metrics are:

- Accuracy: 95.32%
- Precision: 0.8596
- Recall: 0.9806
- F1: 0.9161

The most important value here is recall. A recall of 0.9806 means the low-power gate misses very few abnormal windows. This allows the high-power stage to assume that most windows it receives are already abnormal.

## Stage 2: High-Power VT vs VF Classifier

Because Stage 1 already performs Normal vs Abnormal detection, Stage 2 does not need to classify Normal again. Its role is only to classify the abnormal rhythm as either VT or VF.

Final high-level flow:

```text
ECG window
   |
   v
Low-power Stage 1: Normal vs Abnormal
   |
   |-- Normal   -> no high-power classification
   |
   |-- Abnormal -> High-power Stage 2: VT vs VF
```

This makes the high-power model simpler and better aligned with the power-aware design goal. Instead of spending computation on all windows, the system spends high-power computation only on windows that pass the abnormal gate.

## Why Normal vs VT Is Not Part Of The Final High-Power Design

Earlier experiments included Normal vs VT beat-level classification. Those experiments were useful for feature exploration, especially for understanding rhythm-based features such as RR interval and previous RR interval. However, they are not part of the final deployed architecture.

Including Normal again in Stage 2 would duplicate the responsibility of Stage 1. It would also make the high-power model solve a broader problem than necessary. Since Stage 1 already detects abnormal windows with high recall, the cleaner final design is:

- Stage 1: decide whether the window is Normal or Abnormal.
- Stage 2: if abnormal, decide whether the rhythm is VT or VF.

## Thesis Interpretation

This architecture should be presented as a staged, power-aware classifier rather than a single three-class classifier. The contribution is not only the individual SVM models, but also the division of responsibility between them:

- The low-power model prioritizes high recall so abnormal rhythms are rarely missed.
- The sequence rule improves low-power gate reliability before high-power activation.
- The high-power model focuses only on the clinically important abnormal subclasses, VT and VF.

This design reduces unnecessary high-power computation while preserving sensitivity to abnormal rhythms.
