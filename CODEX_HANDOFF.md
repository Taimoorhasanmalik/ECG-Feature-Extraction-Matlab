# Codex Handoff: Lightweight ECG Support Classifier

This file records the current training flow, hard requirements, experiments tried, and the next work items so another Codex session can continue without relying on chat history.

## Project Goal

Build a low-power support classifier for ECG VT/VF detection. This support model should decide when to invoke a higher-power main classifier. The support model should be hardware-friendly and should prefer catching dangerous VT/VF events while reducing unnecessary main-classifier invocations.

## Hard Requirements

- Use MATLAB scripts in `code/`.
- Save trained model artifacts in `models/`.
- Do not overwrite previous model artifacts. Create a new MATLAB file and a new model artifact for each meaningful experiment.
- Treat **VT**, **VF**, and **VFL** windows as **Abnormal**.
- Treat all other rhythm classes as **Normal** for this support model.
- Use a **record-level train/test split**, not testing on the same windows used for training.
- The current training flow uses:
  - target sample rate: `100 Hz`
  - window length: `2.0 s`
  - step: `1.0 s`
  - Q3.8 signed quantization after resampling
  - record-level holdout test fraction: `0.20`
  - linear SVM using MATLAB `fitcsvm`
  - GPU path requested by default
- If GPU training/prediction fails, report the failure. Do not silently fall back to CPU for the GPU-required scripts.
- Keep features hardware-friendly:
  - avoid complex nonlinear features unless explicitly requested
  - avoid too many squaring and division operations
  - linear SVM is preferred for the lightweight hardware path
  - use simple accumulators/counts/comparisons where possible
- The current best direction is sequence-level gating using consecutive windows.

## Dataset Locations Used on This PC

```powershell
C:\Users\Taimoor\Desktop\Thesis\databases\mit-bih-malignant-ventricular-ectopy-database-1.0.0
C:\Users\Taimoor\Desktop\Thesis\databases\mit-bih-arrhythmia-database-1.0.0
C:\Users\Taimoor\Desktop\Thesis\databases\cu-ventricular-tachyarrhythmia-database-1.0.0
```

On another PC, set paths without editing scripts:

```powershell
$env:ECG_TRAIN_DATABASE_PATHS="C:\path\mit-bih-arrhythmia-database-1.0.0;C:\path\mit-bih-malignant-ventricular-ectopy-database-1.0.0;C:\path\cu-ventricular-tachyarrhythmia-database-1.0.0"
```

Optional environment switches already supported by the training scripts:

```powershell
$env:ECG_TRAIN_DATABASES="mitdb,vfdb,cudb"
$env:ECG_TARGET_SAMPLE_RATE_HZ="100"
$env:ECG_ABNORMAL_AUGMENTATION_FACTOR="1"
$env:ECG_TEST_FRACTION="0.20"
$env:ECG_TRAIN_TEST_SPLIT_SEED="17"
```

## Window Labeling Rule

Each 2-second window has about `200` samples at `100 Hz`.

For clean ML training/testing, the scripts label a whole window using the abnormal sample fraction:

- `>= 80%` abnormal samples: window label = Abnormal
- `<= 20%` abnormal samples: window label = Normal
- between `20%` and `80%`: discard the mixed/uncertain window

This applies before the record-level train/test split.

Important: this is clean ML evaluation. For final hardware simulation, we should add a separate streaming evaluation over all windows, including transition/mixed windows.

## CUDB Label Extraction

CUDB VF intervals are extracted from annotation markers:

- `[` starts a VF/VFL interval
- `]` ends a VF/VFL interval

The scripts also mark tachycardia lead-in before VF markers using sustained fast RR behavior.

## Current Feature Baseline

Base single-window features:

- `mean_abs`
- `zero_crossings`
- `line_length`
- `threshold_crossing_count`
- `robust_range`

`rms_amplitude` exists in some scripts but is excluded in the strongest Q3.8 runs because it adds squaring/square-root cost and did not help enough.

The Q3.8 scripts quantize the converted ECG signal to signed Q3.8:

- range: `[-8, 7.99609375]`
- step: `1/256`

## Training Files Created

### Q3.8 Single-Window Baseline

File:

```text
code/train_normal_vs_abnormal_window_quantized_q3_8_features.m
```

Artifact:

```text
models/stage1_normal_vs_abnormal_window_quantized_q3_8_robust_lsvm_100hz_without_rms_amplitude.mat
```

Holdout metrics:

- accuracy: `93.26%`
- precision: `0.6218`
- recall: `0.7719`
- F1: `0.6888`
- AUC: `0.9576`
- confusion `[TN FP; FN TP] = [24398 1289; 626 2119]`

### Recall-Focused Q3.8 Model

File:

```text
code/train_q38_recall90_gate.m
```

Artifact:

```text
models/stage1_normal_vs_abnormal_window_quantized_q3_8_recall90_robust_lsvm_100hz_without_rms_amplitude.mat
```

This improved recall relative to the first Q3.8 model but did not reach the desired recall target.

### Guard-98 Recall-Focused Q3.8 Model

File:

```text
code/train_q38_recall90_guard98_gate.m
```

Artifact:

```text
models/stage1_normal_vs_abnormal_window_quantized_q3_8_recall90_guard98_robust_lsvm_100hz_without_rms_amplitude.mat
```

Holdout metrics:

- accuracy: `79.04%`
- precision: `0.3105`
- recall: `0.9596`
- F1: `0.4692`
- AUC: `0.9588`
- confusion `[TN FP; FN TP] = [19839 5848; 111 2634]`

This was the best single-window support model for recall and is the base model used by the sequence-gate experiment.

### Consecutive-Window Rule Analysis

File:

```text
code/analyze_q38_two_window_rule.m
```

This script analyzed consecutive-window trigger behavior on the held-out records using the Guard-98 base model.

Two consecutive abnormal windows:

- false invocations: `5123`
- wrong invocation rate over all windows: `18.02%`
- precision: `0.3382`
- recall: `0.9537`
- confusion `[TN FP; FN TP] = [20564 5123; 127 2618]`

Three consecutive abnormal windows:

- false invocations: `4462`
- wrong invocation rate over all windows: `15.69%`
- precision: `0.3688`
- recall: `0.9497`
- confusion `[TN FP; FN TP] = [21225 4462; 138 2607]`

The windows are genuinely consecutive within the same record. With 2-second windows and 1-second step, three consecutive windows span about 4 seconds.

### Raw ECG Zero-Crossing Plus Window Mean Variants

Files:

```text
code/train_q38_zcraw_mean_abs_gate.m
code/train_q38_zcraw_mean_noabs_gate.m
```

Changes:

- zero crossing is counted on the ECG window itself, not on the first-difference waveform
- `window_mean` was added
- one variant kept `mean_abs`
- one variant removed `mean_abs`

Artifacts:

```text
models/stage1_q38_zcraw_mean_abs_recall95_lsvm_100hz_without_rms_amplitude.mat
models/stage1_q38_zcraw_mean_noabs_recall95_lsvm_100hz_without_mean_abs_rms_amplitude.mat
```

`zcraw_mean_abs` holdout metrics:

- accuracy: `75.91%`
- precision: `0.2557`
- recall: `0.8821`
- F1: `0.3965`
- AUC: `0.8927`
- confusion `[TN FP; FN TP] = [18196 6165; 283 2118]`

`zcraw_mean_noabs` holdout metrics:

- accuracy: `73.42%`
- precision: `0.2362`
- recall: `0.8797`
- F1: `0.3724`
- AUC: `0.8816`
- confusion `[TN FP; FN TP] = [17560 6834; 289 2113]`

Conclusion: these did not improve the model. The previous Guard-98 single-window model remained better.

## Sequence-Gate Experiment

File:

```text
code/train_q38_sequence_gate_iterative.m
```

Purpose:

Train a second-stage lightweight gate on consecutive-window behavior instead of isolated windows.

Base model:

```text
models/stage1_normal_vs_abnormal_window_quantized_q3_8_recall90_guard98_robust_lsvm_100hz_without_rms_amplitude.mat
```

Important behavior:

- scores each held-out/training window using the Guard-98 base model
- forms only real adjacent 3-window sequences within the same record
- if a middle window was discarded or filtered, the sequence is not considered consecutive
- sequence label is Abnormal if at least one of the three component windows is Abnormal
- normal MIT-BIH arrhythmia windows are downsampled before sequence training so MIT-BIH does not dominate the normal class
- abnormal windows are not downsampled
- uses GPU `fitcsvm`
- uses batched GPU prediction
- errors instead of CPU fallback if GPU fails

Simple sequence features are tried one by one:

1. `abnormal_vote_count`
2. `max_score`
3. `sum_score`
4. `score_delta`
5. `min_score`

The feature variants are cumulative:

- `count`
- `count_max`
- `count_max_sum`
- `count_max_sum_delta`
- `count_max_sum_delta_min`

The first run was interrupted by the user after the first variant completed.

Completed artifact:

```text
models/stage1_q38_sequence3_iterative_lsvm_100hz_count_from_guard98.mat
```

Feature set:

- `abnormal_vote_count`

Holdout sequence metrics:

- accuracy: `91.80%`
- precision: `0.7835`
- recall: `0.9316`
- F1: `0.8511`
- AUC: `0.9446`
- confusion `[TN FP; FN TP] = [7272 689; 183 2493]`

This is a major improvement over the single-window gate in precision while keeping recall above 90%.

## Current Best Model

Best completed support-gate result so far:

```text
models/stage1_q38_sequence3_iterative_lsvm_100hz_count_from_guard98.mat
```

Reason:

- precision improved from about `31.05%` to `78.35%`
- recall stayed high at `93.16%`
- feature is extremely hardware-simple: count how many of 3 consecutive base-window decisions were abnormal

## Important Interpretation

The sequence-gate metrics are sequence-level clean holdout metrics, not yet a full streaming hardware simulation over every possible window including transitions.

For final hardware claims, add a separate streaming evaluation script that:

- uses held-out records only
- forms every 2-second window with 1-second step
- does not discard mixed windows
- applies the exact base model and sequence gate
- measures false invocations, missed events, event-level recall, detection delay, and invocation rate

## Next Recommended Work

1. Continue `code/train_q38_sequence_gate_iterative.m` to finish the remaining cumulative feature variants:
   - `count_max`
   - `count_max_sum`
   - `count_max_sum_delta`
   - `count_max_sum_delta_min`
2. Compare each saved artifact against the completed `count` model.
3. If more features do not improve performance, keep the `count` model because it is hardware-simplest.
4. Create a new streaming hardware evaluation file. Do not modify old trainers for this; create a new file.
5. For streaming evaluation, test all windows, including mixed transition windows, because that better simulates real hardware.

## Commands Used Recently

Check MATLAB syntax/style:

```powershell
matlab -batch "addpath('code'); checkcode('code/train_q38_sequence_gate_iterative.m','-id')"
```

Run the sequence-gate trainer:

```powershell
matlab -batch "cd('code'); train_q38_sequence_gate_iterative"
```

Load completed sequence artifact metrics:

```powershell
matlab -batch "S=load('models/stage1_q38_sequence3_iterative_lsvm_100hz_count_from_guard98.mat'); disp(S.holdoutTestMetrics)"
```

## Notes for Next Codex

- Read `AGENTS.md` first.
- Do not delete previous model artifacts.
- Do not overwrite existing `.mat` files unless the user explicitly asks.
- Prefer creating new scripts for new experiments.
- Be careful with `git status`; large database/output files should not be staged.
- `code/AGENTS.md` and `code/inspect_mitdb100_format212_steps.m` were already staged before this handoff work and may be user-added. Verify before changing them.
- The branch at the time of this handoff was `GPU_PC_DATA`.
