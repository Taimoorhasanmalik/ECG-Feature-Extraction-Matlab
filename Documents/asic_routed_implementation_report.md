# Routed ASIC implementation report

Date: 2026-10-19. Scope: complete adaptive core, `ecg_asic_power_top`.

Clock-profile update, 2026-10-20: this report records the preserved 100 MHz
source implementation. The new 100 kHz direct / pulse-divided 500 Hz variant
has now completed separate synthesis, routing, selected DRC/LVS and paired
60 s normal-workload power tests. Its full-core gated power is 2.27357 uW,
versus 4.21401 uW fixed ungated; adaptive non-filler area is 0.117552240 mm^2.
See the [native-clock paired report](native_100khz_power_pair_report.md).
The 28.23527 uW figure below is NOT the new variant's power.

This report records the continuation from the verified post-CTS checkpoint.
The final routed core passes the selected external GPDK045 DRC checks and
transistor-level LVS. Routed-core power uses a validated, fully annotated
functional gate-level activity capture.

## Routed implementation

Tool: Innovus 25.10-p002_1. Technology: GPDK045 / gsclib045 SVT.
The original RTL, PDK files and post-CTS checkpoint were preserved.

| Item | Observed result |
| --- | ---: |
| Non-filler cell count | 30,477 |
| Non-filler cell area | 117,769.752 um^2 = 0.117769752 mm^2 |
| Worst setup slack | +7.355 ns |
| Worst hold slack | +0.008 ns |
| Setup / hold violating paths | 0 / 0 |
| Maximum-transition / capacitance violations | 0 / 0 |
| Innovus routing DRC | 0 violations |
| Innovus physical connectivity | No problems or warnings |
| Detailed routing / RC extraction | Completed; regular signal/clock routing uses Metal1-Metal5 |
| External GPDK045 DRC | 562 selected checks, 0 violations |
| External transistor-level LVS | MATCH; 83/83 terminals, 119,459/119,459 nets, 0 blackboxed cells |

These timing checks use the retained 0.9 V / 125 C and 1.1 V / 0 C views,
propagated clocks and coupled routed parasitics. Both RC corners use the
same reference QRC technology at their respective temperatures; qualified
independent RC corners and process-variation derates have not been supplied.
The 100 MHz source and 500 Hz / 100 kHz processing clocks retain the imported
constraints. Remaining IO/reset/clock-transition assumptions remain relevant.

The cell area excludes 39,518 row fillers occupying 69,421.896 um^2. It is not
the core boundary or a pad-inclusive die area. The core area is
187,191.648 um^2; non-filler density is approximately 62.914%.

## Execution and repairs

1. Detailed routing and coupled RC extraction completed from the post-CTS
   checkpoint. Three tie cells were added for constant signal loads.
2. Native post-route setup/DRV and hold optimization reduced the original
   32 maximum-transition violations to three.
3. Two AOI22XL drivers were replaced by AOI22X1 and one NAND4X1 driver by
   NAND4X2. Their connections were rerouted. The resulting setup, hold and
   electrical checks are clean under the current constraints.
4. Standard-cell fillers were inserted. Their area is reported separately.
5. A full standard-cell GDS, routed DEF, logical and PG netlists, SDF, SDC
   and two routed SPEFs were exported.
6. External GDS DRC initially found 20 via-stack violations despite the clean
   Innovus DRC. Higher-effort multi-cut via optimization was run on a copy;
   the external result for that revision still reports 20 stack violations.
   A new route limited to Metal1-Metal5 (`route_layer5_B16WkS`) eliminates
   the failing long regular-net stacks and passes all 562 selected external
   DRC checks. The existing Metal5/Metal6 special-net PG grid is retained.
7. The first LVS attempt reported a mismatch, including missing explicit VDD
   and VSS layout terminals. Export was revised to add power access pins on
   existing connected Metal6 PG wires and omit empty leaf definitions from
   the source netlist. The corrected `physical_verify_ydOmyE` run recognizes
   all 83 terminals but reports passive empty FILL instances on the source
   side. The export script now excludes the seven FILL masters (their CDL
   definitions contain no devices) from the transistor source while retaining
   their full layout geometry. The final `physical_verify_PYkFTA` run reports
   MATCH, including transistor properties, with no blackboxed cells.

## Verification and power status

| Check | Current status |
| --- | --- |
| Native routed setup/hold/electrical/DRC/connectivity | Passing on the final Metal1-Metal5 route |
| External default GPDK045 DRC | PASS: 562 selected rules, 0 results |
| External antenna deck | PASS for its one selected ANT.3 rule; not comprehensive antenna sign-off |
| External transistor-level LVS | MATCH; 0 blackboxed cells and no parameter mismatches |
| Routed-core activity-based power | 28.23527 uW total; exact gate-level activity, 100% input/flop/net annotation |
| RTL-to-routed formal equivalence | Not performed |
| Density/DFM checks and metal fill | Not established; original rule-deck default switches retained |
| EM/IR and manufacturing qualification | Not established |

The regenerated RTL workload simulation accepted all 1,320 samples and
reported PASS. Its bounded power capture spans 1 s, with 100,000,000 source
clock rising edges, 500 processing edges, zero Stage 2 statistics edges and
six shared-MAC edges. Stage 2 classification is inactive for this synthetic
normal workload. The routed-netlist functional simulation also accepts all
1,320 samples and produces the same seven observed Stage 1 classifications,
window IDs and output times as the RTL. This is a workload smoke test, not
formal RTL-to-netlist equivalence or SDF timing simulation.

### Accepted routed-core normal-workload estimate

| Component | Power (uW) |
| --- | ---: |
| Cell-internal dynamic | 18.94480 |
| Net-switching dynamic | 7.04991 |
| Total dynamic | 25.99471 |
| Leakage | 2.24055 |
| Total | 28.23527 |

Analysis: Innovus integrated Voltus engine, `view_slow`, 0.9 V / 125 C,
full adaptive core including divider, mailbox and routed clock distribution.
The measured normal workload spans one full 1 s stride after 10 s warm-up.
Source clock: 100 MHz; actual processing clock: 500 Hz; Stage 2 statistics
clock: stopped. Input sampling remains 120 samples/s. These are clock and
sampling rates, not interchangeable frequencies.

`routed_gate_power_8kM62r` annotates 35/35 primary inputs, 9,127/9,127 flop
outputs and 35,211/35,211 power-analysis nets from the exact routed-netlist
TCF. Its clock-frequency and capture-hash audit passes. Extracted RC covers
all 35,208 real routed nets; the different totals are native reporting object
sets. Floating and unloaded declarations are not counted as missing real-net
parasitics.

This is a post-route, activity-based estimate using functional gate simulation
without SDF. It does not model delay-dependent glitch activity and is not
silicon measurement, sign-off power, or an active-Stage-2 workload result.
No new routed gated-versus-ungated comparison was run. Do not substitute this
full-core estimate into the earlier pipeline-only two-clock/gating comparison.

### Rejected/provisional annotation attempts (retained for traceability)

The first Voltus report (`routed_power_BNsSlq`) shows 95.9571% flop-output
annotation and reports 39.06554 uW total. Its `voltus_clocks.txt` lists the
100 MHz source as 8.38861 MHz, inconsistent with the independently validated
100,000,000 source rising edges. This value is consistent with a saturated
2^24 transition count in the VCD-reading path. It is not accepted as the
workload power. Native Xcelium TCF capture (`native_activity_hQkFKG`)
bypasses the VCD-reader count path. Its independently checked transition
counts are 200,000,000 for the source and 1,000 for processing over 1 s,
and the power engine correctly reports 100 MHz / 500 Hz. However, the
`routed_power_final_hcSsv1` RTL-annotation run maps only 8,663/9,127 flop
outputs. Its 62.31478 uW result is provisional: some arithmetic nets receive
default high-frequency activity inconsistent with their processing domain.
It is not a paper-ready workload power result. The completed functional
simulation of the actual routed netlist (`gate_activity_M9CW3J`) captures
mapped-node activity directly and resolves these coverage gaps. No RTL or
PDK changes were needed.

## AWS evidence locations

All run paths below are under `/home/ec2-user/CadenceASICImplementation/runs/`.

| Stage | Directory |
| --- | --- |
| Original post-CTS source | `cts_postcts_wY7mQK` |
| Initial detailed routing | `route_route_QpDvKA` |
| Native post-route optimization | `route_postroute_e7ybTm` |
| Guarded driver repair | `route_repair_WrsEIl` |
| Higher-effort multi-cut via optimization | `route_viarepair_hMTv6O` |
| Metal1-Metal5 reroute | `route_layer5_B16WkS` |
| First full-cell export | `physical_export_HLrnSe` |
| First external verification | `physical_verify_xToCFF/verification` |
| Revised export external verification | `physical_verify_ydOmyE/verification` |
| Revised PG-terminal / leaf-definition export | `physical_export_6tvTiL` |
| Final GDS/DEF/netlist/SDF/SDC/SPEF export | `physical_export_U1Vee5` |
| Final external DRC/LVS/selected antenna | `physical_verify_PYkFTA/verification` |
| Rejected VCD power analysis | `routed_power_BNsSlq` |
| Provisional native RTL-TCF routed power | `routed_power_final_hcSsv1` |
| Validated native RTL-TCF capture | `native_activity_hQkFKG` |
| Functional routed-netlist activity simulation | `gate_activity_M9CW3J` |
| Accepted routed gate-level activity power | `routed_gate_power_8kM62r` |

The regenerated validated capture is
`/home/ec2-user/CadencePowerAnalysis/adaptive_gated_normal_quick0_IPp3NI/power_capture_JCfFD2/activity.vcd`.

Input checkpoints, failed verification reports and logs are retained. A tool
exit status or a script completion marker alone is never treated as physical
verification PASS.

## Final handoff (download verified 2026-10-20)

The final exports and compact evidence are available locally in
`CadenceASICImplementation/final_delivery_FkGWki/`:

- `exports/`: merged GDS, routed DEF, logical/PG netlists, SDC, SDF and SPEFs.
- `route_reports/`: native area, timing, DRC and connectivity reports.
- `verification/`: external rule decks, results, LVS source and comparison.
- `power/`: routed power, clock rates, coverage and annotation audit.
- `activity/`: functional gate TCF, provenance, simulation log and observed
  RTL/gate result comparison.
- `scripts/`: implementation and verification helpers.

The corresponding archive is
`CadenceASICImplementation/final_delivery_FkGWki.tar.gz` locally and
`/home/ec2-user/CadenceASICImplementation/runs/final_delivery_FkGWki.tar.gz`
on AWS. SHA-256:
`e36bb541e7bfa1eb2ee9215f747617693b3770daa6c5f1023887ca678477d357`.

The downloaded archive hash and all 282 regular-file SHA256SUMS entries
were verified. Four harmless relative report-alias symlinks were omitted
during Windows extraction; their target reports are present and unchanged.
The full restorable Innovus session remains on AWS at
`runs/physical_export_U1Vee5/checkpoints/exported.enc.dat`.

Local checks: 8 capture-validation tests and 4 power-audit tests pass;
Python syntax and AWS shell syntax checks pass. These helper tests supplement,
but do not replace, the actual Innovus, Xcelium and Pegasus results above.
