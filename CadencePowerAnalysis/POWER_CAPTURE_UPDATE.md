# Bounded power capture update

Only the Cadence analysis scripts change. FinalRTL is unchanged. Original
simulation files and previous power results remain available for comparison.

## Existing normal capture: no new simulation required

After installing the updated analysis files on the server:

```bash
cd /home/ec2-user/CadencePowerAnalysis
power_vcd=$(bash prepare_power_capture.sh \
  /home/ec2-user/CadencePowerAnalysis/adaptive_gated_normal_quick0_emPJOU) && \
export ECG_VCD="$power_vcd"
```

The processor prints its validation report to stderr and returns just the new
VCD filename on stdout. Continue ONLY if it succeeds and prints
capture_validation=PASS. For this capture expect:

- duration_ns=1000000000
- source_rising_edges=100000000
- processing_rising_edges=500
- stage2_stats_rising_edges=0
- a positive MAC edge count below 500 (the MAC also classifies Stage 1)
- final VCD timestamp #1000000000000 if its timescale is 1 ps

It rejects wrong source rates, early dump-off, missing/unknown monitored clocks,
inconsistent counters or incomplete logs. Do not bypass failures or use zeros
to replace unknown data. A rejected output directory is retained for diagnosis,
without a successful config.txt; it must not be used for power.

The original VCD is preserved; allow disk space for one additional copy. New
files live in a fresh power_capture_XXXXXX subdirectory. All timestamps within
the valid interval and all data changes remain unchanged except for shifting
the origin to zero. Events at the capture endpoint are excluded, matching a
half-open [start,end) measurement; an exact final timestamp remains.

## Recalculate adaptive-normal power

Keep ECG_RTL_DIR pointing at the uploaded final hardware, and run:

```bash
test -f "$ECG_VCD" || exit 1
test -f "$ECG_RTL_DIR/rtl/files.f" || exit 1
export ECG_MODE=adaptive_gated
export ECG_LIB=/opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/timing/slow_vdd1v0_basicCells.lib
power_run=$(mktemp -d "$PWD/power_adaptive_normal_bounded_XXXXXX")
cd "$power_run"
genus -del_scale 10 -files ../genus_synth.tcl
```

Inspect/send these outputs:

```bash
cat reports/preliminary_power.rpt
cat reports/capture_validation.txt
cat reports/generated_clocks.rpt
cat reports/timing_intent.rpt
cat reports/activity_audit_status.txt
```

Also inspect mapped_activity.rpt and mapped_annotation.rpt if generated, plus
the RTL annotation report in genus.log. A successful clock-edge audit is not
equivalent to full mapped activity coverage. Genus integration of the new
diagnostic report commands needs confirmation on the server; unsupported
commands are explicitly flagged, not treated as coverage passes.

## Matched baseline simulations

Return to the analysis directory. Use the same warm-up, measurement length,
source phase and synthetic input workload as the adaptive case:

```bash
cd /home/ec2-user/CadencePowerAnalysis
ECG_QUICK_SIM=0 ECG_WARMUP_SAMPLES=1200 ECG_MEASURE_SAMPLES=120 \
  bash run_xcelium.sh fixed_gated normal
ECG_QUICK_SIM=0 ECG_WARMUP_SAMPLES=1200 ECG_MEASURE_SAMPLES=120 \
  bash run_xcelium.sh fixed_ungated normal
```

Each run prints its own Validated power VCD path. Use it with the matching
ECG_MODE and a fresh Genus output folder; retain -del_scale 10. Compare both
fixed-mode RESULT traces, including time, ID and code, before attributing their
power difference to the gates. Never reuse a VCD from another mode.

Compare fixed_ungated -> fixed_gated for explicit gating, fixed_gated ->
adaptive_gated for frequency policy, and fixed_ungated -> adaptive_gated for
combined savings. Report dynamic=(internal+switching), leakage, total and area.
Saving percent = 100 * (baseline-proposed)/baseline. These modes alone do not
prove shared-versus-duplicated datapath area savings.

Repeat all modes with demo for an active-Stage-2 workload. Keep normal and demo
results separate. Adaptive trigger timing can select different sample spans;
record Stage 1/2 counts and fast-mode occupancy with each result. No clinical
accuracy or fabricated-silicon/FPGA power claim follows from these estimates.
