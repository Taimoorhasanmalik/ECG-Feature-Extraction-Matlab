# Our Feature Extraction Engine

This note captures how the updated Pan–Tompkins-based detector—referred to as **our feature extraction engine**—processes raw ECG, how it differs from the legacy `pan_tompkin_og`, and what ancillary data it now exports for downstream training/inference scripts.

## Signal Path Overview

1. **Input conditioning**  
   - Accepts a single-channel ECG vector (`ecg`, Hz `fs`).  
   - Mean centered, then routed through the classic low-pass + high-pass Butterworth stack (12 Hz / 5 Hz) at 200 Hz, or a 5–15 Hz band-pass for other sampling rates. The output (`ecg_h`) is normalized and kept for fiducial refinement.

2. **Derivative + envelope instead of square-integrator**  
   - Apply the five-tap derivative filter, take the absolute value, and smooth with a 50 ms moving average to produce `ecg_env`.  
   - This lightweight envelope keeps hardware cost low compared to the original square-and-150 ms moving integrator while still highlighting QRS energy.

3. **Peak proposals + adaptive thresholds**  
   - Run `findpeaks` on `ecg_env` with 0.2 s min distance to get R candidates (`locs/pks`).  
   - Initialize dual adaptive thresholds (`THR_SIG`/`THR_NOISE` for the envelope, `THR_SIG1`/`THR_NOISE1` for `ecg_h`).  
   - Thresholds update per beat, but there is no search-back. Instead, long RR gaps (>1.66× running mean) trigger *forward-only* relaxation: thresholds drop up to 60% and gradually recover each time a valid beat is confirmed. This matches the constraints of real-time devices that cannot rewind buffers.

4. **Beat validation & gating**  
   - For each envelope candidate above `THR_SIG`, the engine checks slope-based heuristics to reject T-waves (<=360 ms from the previous R).  
   - Confirmed peaks are mapped back to the band-passed signal (`qrs_i_raw`, `qrs_amp_raw`); noise levels update when candidates fall below threshold.

5. **Fiducial extraction**  
   - For every successive R pair, compute midpoints and determine:
     - **Q**: minimum within a left window leading into the current R (bounded by the previous beat midpoint or 120 ms).  
     - **S**: minimum between R and the midpoint to the next beat.  
     - **T**: maximum between the S index and that midpoint.  
     - **P** (new): maximum within 250 ms before Q, clipped so it always precedes Q.  
   - Outputs include values and indices for R/Q/S/T and the optional P fiducials.

6. **Window-level statistics**  
   - Slide a 2 s window with 1 s hop across `ecg_h`, capturing mean, variance, and mean absolute deviation. These features feed training pipelines or explain low-frequency drifts.

7. **Detector telemetry**  
   - When callers request an 11th output, `detector_state` returns the per-candidate `THR_SIG`/`THR_SIG1` history and the envelope peak locations. This is used by the smoke test to visualize adaptive thresholds.

## Outputs & Integration Notes

| Output order | Description |
|--------------|-------------|
| 1–8 | R/Q/S/T amplitudes + sample indices (compatible with the legacy function signature). |
| 9 | `delay` to compensate for filter latency in down-stream plotting if needed. |
| 10 | `window_features` struct with `start_idx`, `end_idx`, `mean`, `variance`, `mad`. |
| 11 | `detector_state` (optional) for plotting threshold trajectories. |
| 12–13 | `P_peaks`, `P_peaks_val` (optional) describing atrial fiducials. |

Callers must explicitly capture or ignore each output (e.g., `~, ~, ~, ~, ~, ~, ~, ~, ~, window_features = ...`) to stay compatible with MATLAB’s positional returns.

## Differences vs. `pantompkins_og`

| Area | Legacy behavior | Our feature extraction engine |
|------|----------------|--------------------------------|
| Envelope stage | Squaring + 150 ms moving integrator | Absolute derivative + 50 ms moving mean (normalized) |
| Missed-beat handling | Search-back into buffered data | No rewind—RR-based threshold relaxation plus gradual recovery |
| Fiducials | R/Q/S/T only | Adds deterministic P-wave search before each Q plus sliding-window stats |
| Telemetry | None | Optional `detector_state` for threshold plots + `window_features` struct |
| Pipelined tests | Manual plotting | `tests/test_pan_tompkin_features.m` overlays WFDB rhythm annotations and thresholds |

The separate `tests/compare_pan_tompkin_versions.m` script quantifies agreement (recall/precision/F1) between both detectors using a configurable tolerance and produces overlay plots for quick visual inspection.

## Validation Workflow

1. **Smoke test** – run `tests/test_pan_tompkin_features` after modifying the engine. It checks structure fields, ensures P < Q ordering, plots fiducials, overlays WFDB annotations/rhythm spans, and saves `outputs/pan_tompkin_windows.png`.
2. **Version comparison** – run `tests/compare_pan_tompkin_versions` when tuning thresholds or fiducial windows to see how far the new results deviate from `pantompkins_og` (percentage matches and `outputs/pan_tompkin_comparison.png`).
3. **Downstream impact** – re-run `train_*` and `inference_*` scripts as needed, capturing metrics mentioned in AGENTS.md. Because the engine now emits additional outputs, callers must either request the new values or use the tilde placeholder (`~`) to drop them.

Adhering to this workflow ensures that our feature extraction engine stays reproducible, debuggable, and compatible with both the existing MATLAB scripts and future FPGA-friendly deployments.
