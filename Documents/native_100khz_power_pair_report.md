# Native 100 kHz full-core gated/ungated comparison

Completed: 2026-10-20. Status: BOTH CASES AND MATCHED COMPARISON PASS.

## Routed full-core power

| Metric | Adaptive gated | Fixed ungated |
| --- | ---: | ---: |
| Cell-internal dynamic | 0.02401 uW | 1.58925 uW |
| Net-switching dynamic | 0.00785 uW | 0.38314 uW |
| Total dynamic | 0.03186 uW | 1.97239 uW |
| Leakage | 2.24171 uW | 2.24162 uW |
| Total | 2.27357 uW | 4.21401 uW |
| Energy over 60 s | 136.4142 uJ | 252.8406 uJ |
| Non-filler cell count | 30363 | 30323 |
| Non-filler cell area | 117552.240 um^2 | 117652.788 um^2 |
| Non-filler cell area in mm^2 | 0.117552240 | 0.117652788 |
| Routed setup / hold WNS | +4998.2 / +0.022 ns | +4998.1 / +0.013 ns |
| Annotated primary inputs | 35/35 | 35/35 |
| Annotated flop outputs | 9138/9138 | 9109/9109 |
| Annotated power-analysis nets | 35108/35108 | 35048/35048 |

Combined frequency-and-gating total-power reduction: **46.047%**.
Dynamic-power reduction: **98.385%**. Total energy saved over 60 s:
116.4264 uJ. Each reduction is `(ungated - gated) / ungated * 100`.
Leakage is essentially unchanged; clock gating does not power down the cells.

Both external selected DRC/LVS checks and capture/clock/netlist/RC audits
passed. Both accepted all 8400 samples with no overflow, produced 60 measured
Stage 1 results and no Stage 2 results, and matched all 66 classification
IDs/codes and capture membership (including warm-up results). Output latencies
are allowed to differ. This is not a formal equivalence or score-level test.

Both routed implementations satisfy setup/hold and electrical limits under
the stated constraints. Their similar cell areas are not a measurement of
shared-history versus duplicated-history area savings. The small difference
includes synthesis, sizing and clock-tree implementation variation and should
not be attributed to clock gating alone. Area excludes row fillers and is
not pad-inclusive die area. The large setup slack is under the 100 kHz source
constraints and is not a measured maximum clock frequency.

| Case | External source | Processing policy | Idle statistics/MAC gates |
| --- | --- | --- | --- |
| adaptive_gated | 100 kHz | 500 Hz normally; 100 kHz while Stage 2 is armed/draining | Enabled |
| fixed_ungated | 100 kHz | Fixed 100 kHz | Disabled |

The matched synthetic normal workload uses 120 samples/s, 1200 warm-up
samples (10 s), and 7200 measurement samples (60 s). Stage 2 remained
inactive throughout normal input. The ungated baseline retains the same
conditional computation/window policy: disabling clock gates does not force
abnormal classifications or make every window a Stage 2 classification.

Both cases cover the complete core: clock controller, sample mailbox,
filter/feature/classifier pipelines and physical clock distribution.
The power view is gsclib045 slow at 0.9 V / 125 C. External clock-generation
power and pad/board power are excluded. Clock policy, floorplan utilization,
library/RC selection and implementation settings are recorded per case.

The gated slow processing clock consists of one full 5 us source-high pulse
per 200 cycles, not a 50%-duty 500 Hz square wave. Its SDC uses the actual
high time. The fixed baseline passes every 100 kHz source pulse.

## Execution and acceptance

AWS pair root:
`/home/ec2-user/CadenceASIC100kHz/runs/power_pair_vwGzHG`.

Each case gets its own synthesis/implementation/capture/power outputs. The
gated case reuses the already completed `synth_nxrT1d` netlist, not an old
100 MHz-source netlist. The ungated case maps a new fixed-clock full core.

Acceptance requires successful physical selected-check verification, all
8400 input samples accepted, no overflow, 60 measured Stage 1 results and
no Stage 2 result on the normal workload. Native TCF transition counts must
show a 100 kHz source and the expected 500 Hz or 100 kHz processing rate;
statistics clock transitions must be zero versus 100 kHz respectively. The
accepted captures contain 30000 versus 6000000 processing rising edges, and
both contain 6000000 source rising edges over the 60 s measurement.
Exact netlist/capture hashes and full input/flop/net activity coverage are
checked. Routed timing/electrical violations must be absent, and the two
classification ID/code streams and capture membership must match; output
latencies are allowed to differ.

Gate-level activity uses functional cell models without SDF. Estimates
therefore include routed capacitance but not delay-dependent glitch activity.
Default PDK DRC/LVS selection does not establish full manufacturing sign-off.

The comparison measures combined frequency scaling and clock gating. It is
not a gating-only saving, a leakage-elimination claim, or measured silicon
power. Earlier pipeline-only and 100 MHz-source full-core figures remain
separate references and must not be substituted for these results.

## Physical implementation, repairs and evidence

The latest area/power/timing reports are also organized into a standalone
[report package](../ASIC_Reports_Latest_100kHz_20261020/README.md), with separate
gated/ungated folders, original reports, readable detailed timing paths,
exported constraints, checksums and a spreadsheet-ready comparison.

For native tool output without our summary tables, use
[the original Cadence reports](../Cadence_Original_Reports_100kHz_20261020/README.md).
Native Innovus `report_area -detail -depth 3` was emitted in report-only
restores of both accepted routed databases. Its totals exactly confirm
117552.240 and 117652.788 um^2; no design changes or new power/timing analysis
were made for this export.

Tools: Genus 25.10-p002_1, Innovus 25.10-p002_1 (integrated Voltus power),
Xcelium 26.03-s001, and PVS/Pegasus. Both cases completed synthesis,
floorplanning, power planning, placement, CTS, routing, coupled RC extraction,
post-route optimization, full-cell GDS export and transistor-level LVS.
The selected default DRC deck contains 562 rules; both cases have zero
violations. The single enabled antenna rule also passes; LVS reports MATCH
with no blackboxed cells.

The gated route initially had pre-existing CTS clock wires above the selected
Metal1-Metal5 regular-routing limit. Those regular wires were regenerated in
an isolated restored checkpoint, preserving clock cells and the PG grid.
The ungated export guard later caught two excessive-transition nets. Drivers
`core/pipeline/g21885` and `core/pipeline/g21603` were resized from NAND4XL
to same-function NAND4X1, rerouted and rechecked. Original failed logs and
checkpoints remain. Export/provenance-script failures were corrected and
rerun; only subsequently audited reports are used above.

Accepted AWS artifacts, relative to the pair root:

| Artifact | Gated | Ungated |
| --- | --- | --- |
| Routed source | adaptive_gated/postroute | fixed_ungated/postroute_repaired |
| Final GDS and routed netlist | adaptive_gated/export/exports | fixed_ungated/export/exports |
| Native gate-level capture | adaptive_gated/activity | fixed_ungated/activity |
| Routed power reports | adaptive_gated/power/reports | fixed_ungated/power/reports |
| Machine-readable result | adaptive_gated/case_result.json | fixed_ungated/case_result.json |

External verification roots are
`/home/ec2-user/CadenceASICImplementation/runs/physical_verify_JJEymC/verification`
(gated) and `physical_verify_EocN3x/verification` (ungated).

The original pair driver records an initial failure, intentionally preserved.
Successful continuations are `adaptive_gated/resume3_driver.log` and
`fixed_ungated/resume1_driver.log`. The final supervisor records
`POWER_PAIR_COMPLETED` in `final_comparison_driver.log`; its comparison reruns
both case audits rather than treating a started job as passed.

Local [comparison](../CadenceASIC100kHz/evidence/power_pair_vwGzHG/comparison.md),
[gated power](../CadenceASIC100kHz/evidence/power_pair_vwGzHG/adaptive_gated/power/reports/routed_power.rpt)
and [ungated power](../CadenceASIC100kHz/evidence/power_pair_vwGzHG/fixed_ungated/power/reports/routed_power.rpt)
have associated area, timing, capture, netlist-hash, RC and physical-verdict
files in the same evidence tree. Large restorable databases and TCFs remain
on AWS. Downloaded evidence archive SHA-256:
`4cf6ec653b62a59e12279684e4c2499d5cac53337bf75d4a02086cbd8270e0c7`.

## Suggested paper wording

"Using a direct 100 kHz source, the complete two-stage core was placed and
routed in a generic 45 nm standard-cell technology. Under a matched 60 s
synthetic normal workload at 0.9 V and 125 C, adaptive 500 Hz processing with
idle clock gating consumed 2.274 uW, compared with 4.214 uW for fixed 100 kHz
ungated processing, reducing estimated total and dynamic power by 46.05% and
98.38%, respectively. The adaptive implementation occupies 0.11755 mm^2 of
non-filler cell area. Estimates include the clock controller, acquisition
mailbox and routed clock distribution; the comparison combines frequency
scaling and clock gating."

These are research post-route estimates, not FPGA measurements, fabricated
silicon results or manufacturing sign-off. They do not characterize abnormal
workloads, average clinical Stage 2 duty cycle, delay-dependent glitches,
external clock generation, pad/board power, full density/DFM/antenna closure,
EM/IR, qualified independent RC corners, DFT or formal RTL equivalence.
