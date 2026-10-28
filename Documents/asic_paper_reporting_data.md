# ASIC hardware results for paper reporting

Latest results (2026-10-20): the ASIC-native 100 kHz-source implementation has
completed fresh routing, selected external DRC/LVS and matched 60 s gate-level
power tests. Full-core adaptive gated power is 2.27357 uW (0.03186 uW dynamic,
2.24171 uW leakage), versus 4.21401 uW fixed ungated. Combined frequency-and-
gating reductions are 46.047% total and 98.385% dynamic at 0.9 V / 125 C on
synthetic normal input. Adaptive non-filler area is 0.117552240 mm^2. All 66
classification IDs/codes and capture-membership flags match. See the
[native-clock paired report](native_100khz_power_pair_report.md) for evidence
and qualifications. The 100 MHz-source and pipeline-only figures below are
preserved references, not the PPA of this new variant.

## Update: routed implementation, 2026-10-19

The full adaptive core has now completed detailed routing, coupled RC
extraction and post-route optimization. This supersedes the earlier
CTS-only physical status below; the pipeline-only power comparison retains
its original scope and must not be relabeled as routed full-core power.

| Routed full-core result | Value |
| --- | ---: |
| Non-filler standard-cell area | 117,769.752 um^2 (0.117769752 mm^2) |
| Non-filler cell count | 30,477 |
| Core floorplan area | 187,191.648 um^2 |
| Setup / hold WNS | +7.355 / +0.008 ns |
| Setup / hold violating paths | 0 / 0 |
| Native routing DRC / electrical violations | 0 / 0 |
| External default GPDK045 DRC | 562 selected rules, 0 violations |
| Transistor-level LVS | MATCH, no blackboxed cells |
| Routed parasitics | All 35,208 real nets fully annotated |
| Full-core routed normal-workload dynamic power | 25.99471 uW |
| Full-core routed normal-workload leakage power | 2.24055 uW |
| Full-core routed normal-workload total power | 28.23527 uW |

Research-implementation wording: "The complete adaptive core was placed
and routed in a generic 45 nm standard-cell technology. The routed core
occupies 0.11777 mm^2 of non-filler cell area and passes the selected default
DRC checks and transistor-level LVS. Setup and hold timing are met under
the stated clock, IO and two-PVT analysis assumptions."

Only one antenna rule is enabled in the supplied deck's default selection.
Density/DFM, comprehensive antenna, EM/IR and formal RTL equivalence have
not been closed; do not claim foundry-qualified sign-off or fabrication.
Routed power is a 0.9 V / 125 C, 1 s synthetic normal-workload estimate
using zero-delay functional gate-level activity. All inputs, flop outputs
and power-analysis nets are annotated, with validated 100 MHz source and
500 Hz processing clocks. It includes divider/mailbox/clock-tree power,
but not SDF-dependent glitches, and is not an active-Stage-2 power result.
No routed gated-versus-ungated reduction is established by this single case.
See [the routed implementation report](asic_routed_implementation_report.md)
for exact files, execution history, constraints and remaining qualifications.

## Earlier analysis snapshot (retained)

Report date: 2026-10-14. Tool runs: 2026-10-12/13 (UTC).
Numerical power, area, capture-validation and post-CTS timing reports were
read directly from AWS when preparing this file. This is a reporting snapshot,
not a claim of completed ASIC sign-off.

## 1. Results that can be reported now

Two different analysis boundaries must remain separate:

| Evaluation | Scope | Main result | Qualification |
| --- | --- | --- | --- |
| Normal-workload power comparison | Shared pipeline, direct external clock; divider/mailbox excluded | 43.010% total-power and 99.309% dynamic-power reduction | Activity-based, pre-layout ASIC estimate; frequency and gating changed together |
| Physical implementation through CTS | Complete adaptive core, including divider/mailbox | 0.117722214 mm^2 cell area; setup WNS +7.436 ns, hold WNS +0.030 ns | Post-CTS, pre-route estimates under current constraints; not post-layout power or sign-off |

Do not combine the pipeline-only power with full-core post-CTS area into an
apparently matched post-layout PPA result without explicitly labeling the
different boundaries and implementation stages.

## 2. Hardware architecture and operating conditions

| Item | Implemented configuration |
| --- | --- |
| Input | One ECG channel, 120 samples/s |
| Analysis window / stride | 240 / 120 samples, nominally 2 s / 1 s |
| Full-core source clock | 100 MHz |
| Shared processing clock | 500 Hz while Stage 2 sleeps; 100 kHz while armed/draining |
| Clock generation | Adaptive divider; both stages use the same processing clock |
| Shared resources | Window sequencer, addressing/history, replay feature datapath, scheduler and classifier MAC |
| Logical history | 240 words x 32 bits; standard-cell-mapped storage in this ASIC flow, not an SRAM macro |
| Separate resources | Stage-specific causal filters and streaming-statistics state |
| Stage 2 clock gating | Statistics branch; shared classifier MAC is also gated when idle |
| Filter behavior | Stage 1 5 Hz and Stage 2 1 Hz high-pass paths remain warm |
| Stage 2 enable | At least two abnormal votes among three completed Stage 1 windows |
| Stage 2 disable | Two consecutive normal sequence decisions; already started windows finish |
| Window alignment on enable | Both stages restart collection at the next raw sample accepted by the processing core |
| Selected parameters | SHARED_HP1_MODEL=1, DEEP_HISTORY=0, STAGE1_FULL_RATE=0 |

The common features use a time-multiplexed replay datapath; the implementation
is not two independent complete feature-extraction pipelines. Separate filters
are necessary for the stage-specific filtered signals. Stage 2 is not entirely
power-gated: its filter remains active and clock gating does not remove supply
leakage. Runtime sampling-rate changes are not established by these results.

Architecture details: [FinalRTLSummary.md](../FinalRTLSummary.md).
The analyzed source package is [FinalRTL](../FinalRTL/README.md).

## 3. Technology and tools

| Item | Configuration |
| --- | --- |
| Technology | Cadence generic 45 nm kit, GPDK045 / GSCLIB045 SVT v4.8 |
| Simulation | Xcelium 26.03-s001 |
| Synthesis and pre-layout power | Genus 25.10-p002_1, integrated Joules power engine |
| Placement and CTS | Innovus 25.10-p002_1 |
| Slow cell-library view | slow_vdd1v0_basicCells.lib: actual nominal voltage 0.9 V, temperature 125 C |
| Fast cell-library view | fast_vdd1v0_basicCells.lib: actual nominal voltage 1.1 V, temperature 0 C |
| Reference extraction technology | gsclib045/qrc/qx/gpdk045.tch |
| Timing analysis after CTS | Propagated clocks, onChipVariation analysis mode and CPPR; both imported PVT views reported |

The same reference RC technology is used for both PVT views; these are not
independently characterized best/worst RC corners. No qualified OCV/AOCV/SOCV
derates were supplied. Enabling an OCV analysis mode alone is not process
variation sign-off. Library filenames do not establish operating voltage.

Area-unit cross-check: Liberty area equals LEF width x height for INVX1
(0.684 um^2), DFFRX1 (6.840 um^2) and TLATNCAX12 (9.576 um^2).
Conversion: 1 mm^2 = 1,000,000 um^2.

## 4. Pipeline-only power experiment

### 4.1 Protocol

Both runs use identical deterministic synthetic normal ECG-like sample values
and order. These are not clinical-record accuracy experiments. Sampling averages
120 samples/s; clock-quantized delivery times differ between the two clock rates.

- Warm-up: 1200 samples (10 s).
- Measurement: 60 s, 7200 samples per case.
- Window/stride: 240/120 samples.
- Stage 2 classification: inactive throughout this normal-only experiment.
- Functional comparison: all 67 reported Stage 1 IDs, decisions and fixed-point
  scores matched across warm-up, measurement and drain. This is not 67 results
  inside the 60-second measurement interval; output latencies may differ.
- Bounded activity captures passed validation. The shared MAC still computes
  Stage 1 scores, so its gating savings are not exclusively Stage 2 savings.

The low-power wrapper directly clocks the pipeline at 500 Hz with idle gating.
The baseline directly clocks the same shared pipeline at 100 kHz with the two
gates bypassed. Neither wrapper contains the 100 MHz divider/controller or
sample mailbox. No claim is made that permanent 500 Hz operation supports
active Stage 2 throughput.

### 4.2 Power and energy

All power values are estimates in uW; energy is in uJ.

| Case | Internal | Switching | Dynamic (internal + switching) | Leakage | Total | Total energy over 60 s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gated_500hz | 0.009745750 | 0.000889729 | 0.010635 | 2.007880 | 2.018510 | 121.110600 |
| ungated_100khz | 1.534540000 | 0.005002510 | 1.539543 | 2.002300 | 3.541850 | 212.511000 |

Components, totals and comparison-summary values are independently rounded;
displayed components need not sum exactly to displayed totals.

```text
Total-power reduction = 100 * (3.541850 - 2.018510) / 3.541850
                      = 43.010%
Dynamic reduction    = 100 * (1.539543 - 0.010635) / 1.539543
                      = 99.309%
Total-power saving   = 1.523340 uW
Energy saving        = 91.400400 uJ over 60 s
Energy               = average total power * duration
```

These percentages quantify combined frequency reduction and clock gating,
not clock gating alone. Leakage dominates the low-power total (approximately
99.47%). The small leakage difference is not evidence of leakage elimination;
the two cases were separately synthesized/mapped.

### 4.3 Captured clock activity and annotation

| Evidence over the measured 60 s | gated_500hz | ungated_100khz |
| --- | ---: | ---: |
| Capture validation | PASS | PASS |
| Source / processing rising edges | 30000 / 30000 | 6000000 / 6000000 |
| Stage 2 statistics clock rising edges | 0 | 6000000 |
| Shared classifier MAC clock rising edges | 360 | 6000000 |
| Asserted primary input activity | 35/35 | 35/35 |
| Asserted mapped flop-output activity | 9014/9014 | 9025/9025 |
| Asserted architectural ICG activity | 2/2 | No ICGs in bypassed baseline |

Mapped internal driver nets also include activity computed by propagation;
this is not 100% directly asserted activity on every combinational net.
The activity report lists zero Default entries for these mapped driver nets.

### 4.4 Synthesis area of the same power cases

| Case | Cell count | Mapped cell area (um^2) | Mapped cell area (mm^2) |
| --- | ---: | ---: | ---: |
| gated_500hz | 27549 | 111417.102 | 0.111417102 |
| ungated_100khz | 27486 | 111349.796 | 0.111349796 |

The low-power case has 67.306 um^2 more mapped cell area, approximately
0.06045% above the baseline. This includes mapping differences as well as gate
implementation; it is not a clean standalone ICG-cost measurement. Both cases
use the shared architecture, so this comparison does not quantify area savings
versus duplicated Stage 1/Stage 2 datapaths.

### 4.5 Excluded power

Excluded: divider/controller, sample mailbox, external clock generation,
ADC/analogue/board/IO-interface power, physical CTS, routed parasitics and an
SRAM macro implementation. Therefore, do not report 2.018510 uW or 43.010%
as measured whole-system, post-layout, FPGA or silicon power.

## 5. Complete adaptive-core physical implementation

This scope includes the 100 MHz divider/controller and sample mailbox.
It is a different top-level design from the direct-clock power wrappers.

### 5.1 Area and implementation progress

| Implementation stage | Total instances | Cell area (um^2) | Cell area (mm^2) |
| --- | ---: | ---: | ---: |
| Genus mapped synthesis | 27674 | 112280.994 | 0.112280994 |
| Reviewed placement | 30380 | 117433.566 | 0.117433566 |
| CTS plus post-CTS hold optimization | 30472 | 117722.214 | 0.117722214 |

Physical-stage cell area is the sum of instantiated physical cell bounding
areas, not core/die area. CTS plus hold optimization added 92 instances and
288.648 um^2 (0.24580%) relative to reviewed placement.

| Floorplan quantity | Value |
| --- | ---: |
| Core dimensions | 434.4 x 430.92 um |
| Core area | 187191.648 um^2 = 0.187191648 mm^2 |
| Post-CTS placement density | 62.889% |
| Outer core-only floorplan boundary | 474.4 x 471.2 um |
| Outer boundary area | 223537.28 um^2 = 0.22353728 mm^2 |

The outer boundary has no pad ring/package implementation. Do not call it
final chip die area. The mapped history storage uses standard cells, not a
characterized SRAM macro.

### 5.2 Timing under the current constraints

| Metric | Reviewed placement: ideal clocks | Post-CTS/hold optimization: propagated clocks |
| --- | ---: | ---: |
| Setup worst negative slack / WNS (ns) | +7.472 | +7.436 |
| Setup total negative slack / TNS (ns) | 0 | 0 |
| Setup violating paths | 0 | 0 |
| Hold/removal WNS (ns) | -0.090 | +0.030 |
| Hold/removal TNS (ns) | -1.949 | 0 |
| Hold/removal violating paths | 23 | 0 |

WNS denotes the worst reported slack; a positive value indicates margin.
The 23 initial default-group failures were external resetn removal checks,
not ordinary register-data hold failures. After CTS, four remained before
hold optimization (WNS -0.148 ns); optimization cleared the reported checks.
Recovery/removal checks were retained; no blanket reset false path was added.

Independent final per-view worst-path reports:

| Library view | Setup slack (ns) | Hold slack (ns) | Reset-removal slack (ns) |
| --- | ---: | ---: | ---: |
| Slow: 0.9 V, 125 C | +7.436 | +0.159 | +0.030 |
| Fast: 1.1 V, 0 C | +8.778 | +0.032 | +0.032 |

These are pre-route results under current IO/clock/reset assumptions, not
routed timing or an unconditional reset-safety result. A reset-removal check
passing at an assumed phase does not establish safe arbitrary asynchronous
reset release. Do not infer maximum operating frequency from one WNS value.
The constrained source clock is 100 MHz; ECG sampling remains 120 samples/s
and processing remains 500 Hz / 100 kHz.

### 5.3 Physical/clock checks

- Final run: 59 warnings, zero native tool errors; warnings were not waived.
- Native placement: zero violations and zero unplaced instances.
- PG pin check, special-net connectivity and power-via checks: clean.
- Clock structure: two physical roots; both fast/slow processing timing modes
  retained; final reports show clocks propagated in both PVT views.
- Clock DAG: 216 buffers, two integrated clock gates, 8700 regular clock sinks
  plus the processing-clock output port. These are not total-design counts.
- Clock DAG net-violation report: none.
- Reviewed placement early-global-route overflow: 0% horizontal and vertical.
  This is an estimate, not completed detailed signal routing or DRC.

## 6. Separate full-core pre-layout power reference

A previously validated one-second normal-only activity capture for the full
adaptive core (including its continuously clocked 100 MHz source domain)
reported the following Genus estimates at 0.9 V, 125 C:

| Dynamic (uW) | Leakage (uW) | Total (uW) | Implementation stage |
| ---: | ---: | ---: | --- |
| 18.534370 | 2.024900 | 20.559300 | Pre-layout, before physical CTS |

This is not the final post-CTS power, not the matched 60-second direct-clock
comparison, and not evidence for a 43.010% full-core reduction. It illustrates
why the source-clock infrastructure must be included when reporting full-core
power. Do not attribute a precise block-level power contribution without a
hierarchical power report. A validated post-route workload-power result for
the complete adaptive core is still unavailable.

## 7. Suggested paper wording

### Physical implementation

> The shared two-stage ECG core was synthesized, placed and clock-tree
> synthesized using the Cadence generic 45 nm GSCLIB045 library. After
> post-CTS hold optimization, the complete adaptive core occupied
> 0.117722 mm^2 of cell area within a 0.187192 mm^2 core. Under the current
> constraints and reference-RC setup, propagated-clock timing reported
> +7.436 ns setup slack and +0.030 ns hold/removal slack, with zero reported
> setup/hold violations. These are pre-route estimates, not physical sign-off
> or fabricated-silicon measurements.

### Power experiment

> A separate 60-second, normal-only, activity-based pre-layout evaluation of
> the shared pipeline estimated 2.018510 uW total power at a direct 500 Hz
> clock with idle gating, versus 3.541850 uW at an ungated direct 100 kHz
> clock. Combined frequency reduction and gating reduced estimated total
> and dynamic power by 43.010% and 99.309%, respectively. All 67 reported
> Stage 1 IDs, decisions and fixed-point scores matched across the complete
> simulations. Stage 2 classification remained inactive; divider,
> acquisition-interface and external clock-generation power were excluded.

Do not abbreviate these statements into "43% ASIC chip power saving" or
"completed/tape-out-ready ASIC implementation."

## 8. Remaining checks and unsupported claims

Still required: detailed signal routing, routed parasitic extraction,
post-route timing/optimization, validated activity-based post-layout power,
equivalence, CDC/reset/divider-transition verification, and appropriate
DRC/LVS/antenna/EMIR checks. DFT/ATPG and manufacturing qualification are not
established. GPDK045 is a generic technology, not evidence of fabrication.

Open implementation items include the original site/grid metadata warning,
duplicate LEF and incomplete antenna data, physical-only cell requirements,
IO driver/loading assumptions, and canonical generated-clock root/source
latency review. CCOpt resolves the wire-only BUFG module-port clock root to
the divider flip-flop output; native CTS can update IO/source-latency
assertions. post_cts.sdc records the actual output constraints.

The available power cases do not establish gating-only savings, power during
active Stage 2/wake-up, clinical classification accuracy, or shared-versus-
duplicated datapath area savings. Those need separate controlled experiments.

## 9. Evidence locations

Only the reporting data are consolidated here. Large waveforms, netlists,
checkpoints and raw logs remain on AWS; this report does not duplicate them.

| Result | AWS directory |
| --- | --- |
| Paired pipeline power/area | /home/ec2-user/CadenceDirectClockPower/runs/pair_ySMQG6 |
| Full-core synthesis and one-second pre-layout power | /home/ec2-user/CadencePowerAnalysis/power_adaptive_normal_validated_4UoJO0 |
| Reviewed placement | /home/ec2-user/CadenceASICImplementation/runs/placement_review_5uJVg4 |
| Final post-CTS/hold run | /home/ec2-user/CadenceASICImplementation/runs/cts_postcts_wY7mQK |

Power pair evidence: comparison.md and each case's
genus/reports/{preliminary_power.rpt,area.rpt,mapped_annotation.rpt,
capture_validation.txt}, plus simulation.log/config.txt.

Final CTS evidence: reports/inventory_after.txt, reports/placement_after.rpt,
reports/pg_connectivity.rpt, reports/clock_trees_after.rpt,
reports/clocks_after.rpt, reports/timing/final.summary.gz,
reports/timing/final_hold.summary.gz, reports/view_*_{setup,hold,removal}.rpt,
console.log, post_cts.v, post_cts.sdc and checkpoints/post_cts.enc.dat.

Local supporting records:
[direct-clock power report](direct_clock_asic_power_report.md),
[ASIC implementation status](../CadenceASICImplementation/STATUS.md),
[ASIC reproduction instructions](../CadenceASICImplementation/README.md),
[direct-clock experiment instructions](../CadenceDirectClockPower/README.md).


## 10. Interpretation findings and paper-integration status

Added 2026-10-14. These are readings of the numbers already recorded above,
plus a record of what has been written into the paper draft. No new tool run
was performed for this section. Where a statement is an inference rather than
a report value, it is marked unverified.

### 10.1 Clock gating does not reduce leakage, and the gated case leaks slightly more

Leakage is current through powered transistors and is set by supply voltage,
threshold voltage, temperature and transistor count. Clock gating forces the
clock inactive, which removes switching activity. It does not disconnect the
supply, so no leakage path is removed.

| Case | Leakage (uW) |
| --- | ---: |
| `gated_500hz` | 2.007880 |
| `ungated_100khz` | 2.002300 |
| Difference | +0.005580 in the gated case, +0.2786% |

The gated case leaks *more*, not less. Section 4.4 corroborates the direction:
the same case has 67.306 um^2 more mapped cell area, +0.06045%, because the
gated netlist contains ICG cells that the baseline bypasses. Both differences
are small enough that separate synthesis and mapping could account for them,
so neither is a clean standalone ICG-cost measurement.

Consequences for reporting:

- Leakage is 99.4734% of the gated case total. Driving dynamic power to zero
  would reduce the total by only 0.527%.
- Further dynamic optimisation at this corner cannot move total power
  materially. The next lever is power gating, multi-Vt or voltage scaling,
  none of which is implemented.
- Do not describe the 43.010% total-power reduction as a leakage saving, and
  do not attribute any part of the leakage difference to clock gating.

### 10.2 The reporting corner, not the design, sets the total-power headline

The power cases use `slow_vdd1v0_basicCells.lib` at 0.9 V, 125 C, slow
process. That is a timing-signoff corner, chosen to be pessimistic for speed,
and it is also the most pessimistic available choice for leakage.

Timing is not the question being asked here. The processing clock periods are
2 ms and 10 us, and Section 5.2 records large positive slack on the full core.
Nothing in a 45 nm library fails to close at these periods.

Because leakage dominates the total, the corner determines the headline
percentage. Holding the reported dynamic values fixed and varying leakage:

| Leakage per case (uW) | Total-power reduction |
| ---: | ---: |
| 2.00, the present 125 C slow corner | 43.0% |
| 0.50 | 75.0% |
| 0.10 | 93.3% |
| 0.02 | 98.0% |

Recommended action: re-run both cases at a typical process, 25 C, nominal
voltage corner. Same scripts, same VCD captures, only `ECG_LIB` changes.
Report typical as the operating-point figure and retain 125 C slow as the
worst-case bound.

Note the asymmetry when choosing what to publish. The 43.010% is distorted
downward by the corner and should not be the headline. The absolute
2.018510 uW is distorted *upward* by the same corner, which makes it
conservative, so it remains safe to report as a worst-case figure and is
rhetorically stronger than a typical-corner number for the same reason.

### 10.3 Both compared cases are Stage-1-only, and must not be paired with the accuracy figures

The protocol is `workload=normal`. Stage 2 was never requested and performed
no classifications in either case. The comparison is therefore:

| | `gated_500hz` | `ungated_100khz` |
| --- | --- | --- |
| Stage 1 | running | running |
| Stage 2 classification | never | never |
| Stage 2 warm filter | running | running |
| Processing clock | 500 Hz | 100 kHz |
| Clock gates | enabled | bypassed |

This is the always-on path with both activity controls versus the same path
with neither. It is **not** continuous Stage 2 versus gated Stage 2.

Specific risk to avoid: the paper separately reports 89.6% end-to-end accuracy
with Stage 2 running continuously against 88.3% with it gated, a 1.3 point
cost. Placing that near the 99.309% dynamic reduction invites the reader to
form the claim "event-driven Stage 2 costs 1.3 accuracy points and saves
99.3% of dynamic power." That sentence would be false. The two numbers come
from different experiments with different configurations, and Stage 2 is
absent from both power cases.

Measuring the energy cost of the event-driven architecture would need two
things that do not exist yet: a stimulus containing VT/VF episodes so Stage 2
actually activates, and two builds at the same clock rate differing only in
whether Stage 2 is continuous or event-driven. This is a third axis, not
covered by the four-case frequency-by-gating matrix already recommended.

### 10.4 Cross-work power comparison: ranking is favourable, margin is not evidence

Of the five works cited in the paper's comparison table, only two report a
power figure at all.

| Work | Technology | Reported cost | Comparable as power? |
| --- | --- | --- | --- |
| MINA 2025 | FPGA ZCU102 | LUT-normalized GOP/s | no figure |
| Zhang 2025 | 55 nm | 62.2 nJ at 100 MHz | energy per inference |
| Wu 2024 | 180 nm | 0.533 mW | yes |
| Makhlooghpour 2023 | FPGA, HLS | 41.05 uW | yes |
| Bleitner 2023 | 22 nm FDSOI | 130.1 pJ per decision | energy per decision |

Against the two comparable figures this work is 264.1x below Wu and 20.34x
below Makhlooghpour, using the conservative 2.018510 uW. The ranking is
genuinely favourable even at the pessimistic corner.

The margin, however, is confounded and should not be presented as evidence of
the architecture:

- Makhlooghpour is an FPGA implementation; this figure is a 45 nm ASIC
  synthesis estimate. ASIC-versus-FPGA alone plausibly accounts for the full
  20x.
- Wu is 180 nm against 45 nm here, two node generations.
- No technology normalisation is applied, and the measurement bases differ.

The comparison that does carry the contribution is the within-design pair:
same library, same corner, same netlist structure, same stimulus, same capture
method, so node, technology and measurement-basis confounds all cancel. Lead
with 99.309% dynamic reduction; use the cross-work figures as context only.

Do not compute an energy-per-decision figure for this work. At the 1 s stride
it would be approximately 2 uJ per decision, because a full second of standby
leakage is charged to one classification. Against Bleitner's 130.1 pJ of
switching energy per decision that is roughly a 15000x apparent loss and is a
category error, not a comparison.

### 10.5 The history maps to flip-flops in these netlists

`two_stage_shared_replay_top.v` declares the history as

```verilog
(* ram_style="block" *) reg [31:0] window_history [0:239];
```

`ram_style` is a Xilinx synthesis attribute. Genus ignores it, and
`slow_vdd1v0_basicCells.lib` is a standard-cell library with no memory
compiler, which Section 4.5 already records as an exclusion.

Verified update, 2026-10-15: the full adaptive-core Genus netlist in
`CadencePowerAnalysis/power_adaptive_normal_validated_4UoJO0/mapped.v`
contains exactly 6240 `SDFFQX1` history flip-flops. The two lanes contain
12 + 14 useful bits; redundant sign-extension bits do not require separate
storage. At the library cell area of 7.524 um^2, these storage cells total
46949.760 um^2, or 41.8145% of that run's 112280.994 um^2 mapped core area.
This excludes memory selection/control logic and clock distribution. These
counts belong to the full-core run, not a new audit of the direct-clock pair.

The [RAM and novelty audit](shared_ram_area_and_paper_novelty_audit.md)
records the netlist hash, source declarations, reproduction commands and
distinct buffer baselines. ASIC storage-cell counts cannot be inferred from
the FPGA's two RAMB18 primitives. No compiled SRAM alternative was evaluated.

### 10.6 What has been written into the paper draft

As of 2026-10-14 the ISCAS draft at
`ISCAS Template/Conference-LaTeX-template_10-17-19/Two_Stage_Paper_Draft.tex`
contains the following, and is **7 pages**.

| Element | Location | Source |
| --- | --- | --- |
| Fig. 1, two-stage architecture | page 1, `figure*` | existing drawio export |
| Fig. 2, shared datapath | Section IV, `figure*` at 0.8 textwidth | `Common Architecture.drawio (1).png` |
| Fig. 3, Stage 1 / Stage 2 coexistence | Section V | `coexistence.svg`, generated |
| Fig. 4, reported power | Section VI-C | `power_comparison.svg`, generated |
| 45 nm power result in prose | Section VI-C | Section 4.2 above |
| 2.02 uW in Table I cost column | Table I, Stage 1 row | Section 4.2 above |
| Disarm and drain description | Section V, after Fig. 3 | Section 12 of FinalRTLSummary |

Power wording currently in the draft: gated at 500 Hz the pipeline draws
0.0106 uW dynamic and 2.02 uW total, against 1.5395 uW and 3.54 uW ungated at
100 kHz, a 99.3% dynamic reduction preserving all 67 Stage 1 identifiers,
decisions and scores, with Stage 2 inactive so the figure is the idle
operating point.

Open items against the draft:

- Fig. 1 and Fig. 2 overlap substantially. Fig. 1 additionally carries three
  labels that contradict the text: "Zero-crossing count" where the feature is
  derivative-sign changes, "Stage 1 Normal / Abnormal" where Stage 1 separates
  VT, VF and VFL from all other annotated rhythms, and "Normal / Other Rhythm"
  where the confusion table says Others. Replacing Fig. 1 with Fig. 2 would
  return the paper to 6 pages and remove all three.
- The replay engine box in Fig. 2 omits `C = number of changes in t`, so the
  threshold-crossing feature has no visible origin.
- The clock-rate floors are not stated anywhere in the paper. 480 cycles per
  1 s stride gives a 480 Hz floor for the idle rate; Stage 1's complete job of
  approximately 494 cycles must clear within one 8.3333 ms sample period
  before Stage 2's oldest word is overwritten, giving an armed floor near
  59 kHz. Both are derived from cycle counts and the single pending slot per
  stage, and are unverified against a timing simulation.
- The post-arm warm-up, during which the cleared vote history leaves Stage 1
  silent for three completed windows, is not described in the body text.
- Area is reported in this document but not yet in the paper, which still
  carries only the Artix-7 resource counts. Those counts are for the complete
  board wrapper including the demonstration source and display logic; the
  core-only build is 4875 LUTs against the 5172 currently quoted.
