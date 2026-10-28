# Direct-clock ASIC pipeline power report

Report date: 2026-10-13.

## Summary

A matched, 60-second normal-workload experiment compared the shared two-stage
ECG pipeline at a direct 500 Hz clock with idle clock gating against the same
pipeline at a direct 100 kHz clock without those gates. The reported estimates
show a 99.309% reduction in dynamic power and a 43.010% reduction in total power.
All 67 reported Stage 1 window IDs, classification decisions and fixed-point
scores matched across the two simulations.

These are activity-based, pipeline-only, pre-layout ASIC estimates. They are
not measured FPGA, board or silicon power, and do not represent the power of
the complete adaptive-clock system.

## Experiment configuration

| Item | Configuration |
| --- | --- |
| Low-power case | `gated_500hz`: direct 500 Hz source; idle gates enabled |
| Baseline case | `ungated_100khz`: direct 100 kHz source; gates bypassed |
| Pipeline | Shared 240-entry replay architecture from `FinalRTL` |
| RTL parameters | `SHARED_HP1_MODEL=1`, `DEEP_HISTORY=0`, `STAGE1_FULL_RATE=0` |
| Input | Identical deterministic synthetic normal ECG-like sample values and order |
| Sampling rate | 120 samples/s on average |
| Window / stride | 240 samples / 120 samples (2 s / 1 s) |
| Warm-up | 1200 samples (10 s) |
| Measured interval | 60 s; 7200 input samples per case |
| Simulation | Xcelium 26.03-s001 |
| Synthesis and power | Genus 25.10-p002_1 with its integrated Joules engine |
| Liberty | `slow_vdd1v0_basicCells.lib`, GSCLIB045 SVT v4.8 |
| Library corner | 0.9 V, 125 C, nominal process value 1 |

The analyzed wrapper directly connects the external source clock to the
pipeline. It contains no divider, adaptive clock controller or acquisition
mailbox. The low-power case gates the Stage 2 statistics clock and the shared
Stage 1/2 classifier MAC when idle. The Stage 2 causal filter remains warm in
both cases. The baseline bypasses these gate adapters rather than retaining
enabled ICG cells in their place.

Stage 2 was not requested and performed no classifications in this normal-only
experiment. Thus, the result concerns idle-heavy operation, not active Stage 2
classification or wake-up transitions. The shared MAC still performs Stage 1
scoring; its savings cannot be attributed exclusively to Stage 2.

## Reported results

Power values below are transcribed from the AWS comparison summary supplied
by the user. Both cases completed with `Normal exit.`

| Case | Dynamic (uW) | Leakage (uW) | Total (uW) | Energy over 60 s (uJ) |
| --- | ---: | ---: | ---: | ---: |
| `gated_500hz` | 0.010635 | 2.007880 | 2.018510 | 121.110600 |
| `ungated_100khz` | 1.539543 | 2.002300 | 3.541850 | 212.511000 |

Dynamic power is internal plus switching power. Energy is average total power
multiplied by the measured duration. Values are independently rounded in the
tool summary, so displayed components may not sum exactly to displayed totals.

```text
Total-power reduction = (3.541850 - 2.018510) / 3.541850 * 100
                      = 43.010%
Dynamic reduction    = (1.539543 - 0.010635) / 1.539543 * 100
                      = 99.309%
Total-power saving   = 1.523340 uW
Energy saving        = 212.511000 - 121.110600
                      = 91.400400 uJ over 60 s
```

Leakage accounts for approximately 99.47% of the low-power case's total.
Clock gating suppresses clock-driven activity but does not disconnect the
power supply, so it does not eliminate leakage. The small difference between
the two reported leakage estimates is not evidence of leakage removal by
clock gating; the cases are separately synthesized and mapped.

## Verification and provenance

The paired flow validates bounded VCD captures, checks activity annotation and
matches complete Stage 1 IDs, decisions and scores before producing its
comparison. The reported pair matched 67 Stage 1 results across warm-up,
measurement and drain; this is not a claim of 67 results inside the 60-second
power interval. Output latencies are allowed to differ between clock rates.

The same sample sequence is delivered synchronously at each source clock.
Delivery intervals are 4 or 5 cycles at 500 Hz and 833 or 834 cycles at 100 kHz.
The average sample rate is matched, but sample timestamps have different
clock-quantization jitter. This test does not establish clinical accuracy.

AWS run directory:

```text
/home/ec2-user/CadenceDirectClockPower/runs/pair_ySMQG6
```

Retain `comparison.md`, `comparison.csv`, each case's `simulation.log` and
`config.txt`, and the Genus logs and reports, especially
`preliminary_power.rpt`, `mapped_annotation.rpt`, `capture_validation.txt`,
`mapped_unresolved.rpt`, `clocks.rpt` and `analysis_notes.txt`. The raw server
artifacts were not copied into this repository or independently re-run for
this report. The source package and reproduction instructions are in
[CadenceDirectClockPower](../CadenceDirectClockPower/README.md).

## Interpretation and limits

- The comparison changes frequency and clock gating together. It does not
  isolate either contribution. A four-case comparison at both frequencies,
  with and without gating, would separate their effects.
- Divider, mailbox, external clock generation, ADC/board power, physical clock
  tree synthesis, routed parasitics, SRAM macros and realistic IO loading are
  outside this estimate. The 43.010% reduction must not be presented as a
  whole-system or FPGA power reduction.
- Earlier estimates that included the 100 MHz source-domain infrastructure
  used a different analysis boundary. Their totals are not directly comparable
  to these pipeline-only numbers; a hierarchical breakdown would be needed to
  attribute the difference to particular blocks.
- A permanent 500 Hz clock has not been established as sufficient for active
  Stage 2 processing. Mixed normal/abnormal workloads and adaptive transitions
  require separate tests of timing, throughput and power.
- These two cases use the same shared architecture. They do not quantify area
  savings versus independent, duplicated Stage 1 and Stage 2 implementations.
- The longer capture improves workload coverage; duration alone does not
  guarantee a larger average-power saving.

## Suggested paper statement

> Under a deterministic normal-only 120-sample/s input, a 60-second
> activity-based pre-layout ASIC evaluation of the shared ECG pipeline
> estimated 0.010635 uW dynamic and 2.018510 uW total power with a direct
> 500 Hz clock and idle clock gating, compared with 1.539543 uW dynamic and
> 3.541850 uW total power at a direct ungated 100 kHz clock. Combined frequency
> reduction and gating reduced dynamic power by 99.309% and total power by
> 43.010%, while preserving all 67 reported Stage 1 IDs, decisions and scores.
> Clock-generation and acquisition-interface power were excluded; Stage 2
> classification remained inactive throughout the experiment.
