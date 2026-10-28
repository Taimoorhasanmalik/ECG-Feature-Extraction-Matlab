# Native 100 kHz ASIC variant status

Updated: 2026-10-20.

## Implemented

- External source: 100 kHz, not 100 MHz or 200 kHz.
- Fast processing: direct source pulses through one integrated clock gate.
- Slow processing: one full source pulse per 200 cycles, 500 rising edges/s.
- No clock-source mux; the 8-bit counter is held in fast mode.
- Slow high time is 5 us, low time 1995 us. The SDC uses explicit clock edges.
- Source-synchronous acquisition mailbox, filters, shared history/replay,
  sequence gating, classifiers and Stage 2 drain policy are unchanged.
- Original FPGA RTL and previous implementation artifacts are preserved.

## Observed AWS checks

| Check | Result |
| --- | --- |
| Clock periods / source-aligned pulses | PASS |
| Full 5 us high width during mode changes | PASS |
| Phase-offset fast/slow transitions | 60 transitions PASS |
| Counter held during fast mode | PASS |
| Reset recovery | PASS |
| Synthetic normal pipeline | 1320/1320 samples accepted, S1=7, S2=0, no overflow |
| Synthetic demo pipeline | 1320/1320 accepted, S1=4, S2=5, one fast entry, no overflow |
| Normal measurement processing edges over 1 s | 500 |
| Demo measurement fast processing edges over 1 s | 99921 (includes a mode transition) |
| Genus clock/RTL elaboration | Completed; native 100 kHz constraints loaded |
| Genus mapped synthesis | Completed in synth_nxrT1d; no unresolved references or empty modules |

AWS runs under `/home/ec2-user/CadenceASIC100kHz/runs/`:

- `sim_clock_gICPkv`
- `sim_normal_FU1gmr`
- `sim_demo_feO9lG`
- `synth_nxrT1d`

The first clock-test invocation lacked a simulator-wide default timescale
and failed elaboration. The runner was corrected with `-timescale 1ns/1ps`;
the fresh run above passed. Original logs were retained.

The earlier 28.23527 uW routed full-core result belongs to the preserved
100 MHz-source implementation. It is NOT the power of this new variant.
New synthesis and physical implementation results must be reported separately.

## Paired routed-power tests (completed 2026-10-20)

Actual live pair: `/home/ec2-user/CadenceASIC100kHz/runs/power_pair_vwGzHG`.
`adaptive_gated` reuses the completed native-clock synthesis. `fixed_ungated`
has completed synthesis of its distinct full-core netlist with fixed 100 kHz
processing and disabled idle gates. Both have completed fresh routing,
extraction, GDS export and the selected external DRC/LVS checks. Both 60 s
gate-level captures, routed-power audits and matched-result comparison PASS.
Both retain the same external 100 kHz source and 120 Hz synthetic normal input.
Each capture spans 60 s after 10 s warm-up. Controller/mailbox/clock-tree
power is included; external clock generation is excluded.

The per-case driver proceeds through import, floorplan, power plan, placement,
CTS, Metal1-Metal5 signal routing, optimization, extraction, full GDS export,
external selected DRC/LVS checks, native gate-level TCF capture and routed
power. Any failed stage stops that case and retains its logs/checkpoints.
The pair is not complete until case audits and matched-result comparison pass.

This compares frequency scaling plus gating together, not gating alone.

| Result | Adaptive gated | Fixed ungated |
| --- | ---: | ---: |
| Dynamic power (uW) | 0.03186 | 1.97239 |
| Leakage (uW) | 2.24171 | 2.24162 |
| Total power (uW) | 2.27357 | 4.21401 |
| Non-filler area (mm^2) | 0.117552240 | 0.117652788 |

Combined total-power reduction is 46.047%; dynamic reduction is 98.385%.
All 66 classification IDs/codes and capture-membership flags match. Each case
accepts 8400 samples including warm-up, with 60 measured Stage 1 results and
no Stage 2 results. Actual source is 100 kHz in both; processing is 500 Hz
versus 100 kHz. Activity and real-net RC coverage are complete. Both selected
562-rule DRC decks and transistor LVS pass. These are research routed ASIC
estimates, not measured silicon, gating-only savings or manufacturing sign-off.
See [the reporting summary](../Documents/native_100khz_power_pair_report.md)
and [downloaded comparison](evidence/power_pair_vwGzHG/comparison.md).

The ungated post-route export guard detected two excessive-transition nets.
Only their NAND4XL drivers were changed to same-function NAND4X1 cells;
connections were rerouted and timing/electrical checks repeated. The accepted
source is `fixed_ungated/postroute_repaired`, not the initial rejected route.
The gated case used `adaptive_gated/postroute`. Earlier failed-stage logs and
checkpoints remain on AWS; no failed reports are relabeled as passed.
