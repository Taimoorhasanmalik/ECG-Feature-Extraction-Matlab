# Paper note: idle clock-gating experiment on the 240-entry pipeline

This experiment compares two routed XC7A35T implementations of the same
240-entry shared-replay core at a 100 kHz processing clock. Both use the same
Stage 1 and Stage 2 filters, models, classification policy, and Stage 2 RAM
write enable. Only the Stage 2 window-statistics clock and the shared
classifier-MAC idle clock differ:

- Gated: the Stage 2 statistics BUFGCE closes outside Stage 2 episodes; the
  shared classifier BUFGCE opens only for a scoring request.
- Always-on: those two BUFGCE clock outputs remain enabled after reset.

The Stage 2 IIR high-pass filter stays clocked in both variants so its state
is correct when Stage 2 wakes. Stage 2 is therefore not wholly power-gated.
The classifier MAC serves both stages, so its idle-clock effect is not solely
attributable to Stage 2. The Stage 2 RAM write enable remains gated in both
variants to keep memory mapping comparable.

## Example workload and checks

`mostly_normal_power_tb.sv` supplies a deterministic synthetic 20 s,
120 Hz stream: 15 s of low-rate, beat-shaped samples, followed by 5 s of a
high-frequency challenge. A further second lets pending work drain. This is
not a clinical ECG record and does not establish representative patient
duty cycle. Both variants produced exactly the same results on every cycle:
17 normal Stage 1 sequence results, no abnormal sequence results, and no
Stage 2 results. A separate paired active-vector test produced identical
cycle-by-cycle outputs from the gated and always-on cores, including four
Stage 1 and five Stage 2 classification results. The full RTL regression
also covers other synthetic Stage 2 activation and classification cases.

| 21 s trace counter | Gated | Always-on |
| --- | ---: | ---: |
| Stage 2 statistics clock-enabled cycles | 0 / 2,100,001 | 2,100,001 / 2,100,001 |
| Shared classifier clock-enabled cycles | 114 / 2,100,001 | 2,100,001 / 2,100,001 |
| Stage 2 RAM lane writes | 0 | 0 |

The shared classifier needs its 114 enabled cycles to score Stage 1 windows.
The Stage 2 statistics clock stays closed because the gate never arms in
this example. The counters demonstrate the intended suppression of idle
clock activity, but are not themselves watt measurements.

## Routed Vivado 2020.2 reports

The two implementations used the same core-only top, part, 100 kHz clock
constraint, 25 C nominal environment, and a common Vivado Simulator SAIF
from the example waveform. Power was reported after placement and routing.

| Core implementation | LUTs | Registers | DSP48E1 | RAMB18E1 | Total on-chip | Dynamic | Device static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Idle clocks gated | 4,875 | 2,318 | 48 | 2 | 0.070 W | 0.000 W | 0.070 W |
| Idle clocks always-on | 4,874 | 2,318 | 48 | 2 | 0.070 W | 0.000 W | 0.070 W |

Vivado prints power to 0.001 W, so `0.000 W` dynamic means the dynamic
estimate is below the report's displayed resolution. It does not mean the
dynamic power is physically zero. The total-power equality
means no difference was resolved at that precision. An additional diagnostic
forced the BUFGCTRL enable pins to their dominant idle values with
`set_case_analysis`; it likewise printed 0.070 W for both, but is not the
exact workload average because it suppresses the gated MAC's brief Stage 1
scoring intervals.

The power reports assign medium overall confidence. Only about 11% of
routed design nets matched the RTL SAIF; Vivado estimated activity for the
rest. Vivado also warns that gated-clock activity differs from the nominal
100 kHz clock constraint and that activity set directly on global clock
buffers is ignored. Consequently, these reports cannot justify a numeric
clock-gating power-saving percentage. A post-implementation activity trace
with stronger net matching or a differential VCCINT measurement is needed
to resolve the small power difference at this operating frequency.

Suggested paper wording: "On an idle-heavy synthetic 120 Hz input, the
Stage 2 statistics clock was disabled for all 2.1 million processing cycles
and the shared classifier clock for all but 114 cycles, while classifier
outputs remained unchanged. Vivado 2020.2 reported 70 mW on-chip power for
both gated and always-on cores at 1 mW display precision; therefore a power
saving was not quantitatively resolved by this experiment."

Reproduction files: `final_two_stage_design/hardware/tb/mostly_normal_power_tb.sv`,
`final_two_stage_design/hardware/tb/clock_gate_equivalence_tb.sv`,
`scripts/mostly_normal_power_saif.tcl`,
`scripts/report_mostly_normal_gate_power.tcl`,
`scripts/report_idle_clock_case_power.tcl`, and the routed reports and SAIF
in `final_two_stage_design/hardware/power_comparison/`. AMD describes
[SAIF generation](https://docs.amd.com/r/2020.2-English/ug900-vivado-logic-simulation/Generating-SAIF-Dumping)
and [Vivado power reporting](https://docs.amd.com/r/2020.2-English/ug835-vivado-tcl-commands/report_power)
for this flow.
