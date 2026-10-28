# Two direct-clock ASIC power experiments

This separate package uses the unchanged final pipeline RTL from FinalRTL.
It does not edit the final design or the previous CadencePowerAnalysis package.

The completed 60 s AWS comparison is documented in the
[direct-clock ASIC power report](../Documents/direct_clock_asic_power_report.md).
It records the supplied server results and their analysis boundary separately
from the local verification status below.

| Case | External source = processing clock | Explicit clock gates |
| --- | ---: | --- |
| gated_500hz | 500 Hz | Stage 2 statistics and shared MAC gated when idle |
| ungated_100khz | 100 kHz | Both gates bypassed; no ICG cells in this path |

There is NO divider, adaptive clock controller, mailbox, mux or 100 MHz clock
inside the analyzed wrapper. Both cases instantiate the same shared 240-entry
pipeline, with SHARED_HP1_MODEL=1, DEEP_HISTORY=0 and STAGE1_FULL_RATE=0.
The synthesis list deliberately excludes all clock-divider/acquisition/board
modules. The Stage 2 causal filter stays warm in both cases, just as in the
final pipeline. The gating switch also controls the shared Stage 1/2 MAC.

This compares frequency reduction AND explicit gating together. It does not
isolate their individual benefits. It excludes power for generating either
external clock and excludes the acquisition interface, board/ADC, physical CTS,
routed parasitics, SRAM macros, IO drivers and output loads. It is a pre-layout
ASIC core estimate, NOT measured silicon or FPGA power.

## Input and timing

Both cases receive the same deterministic synthetic normal ECG-like samples
as the previous power tests, packed into Q16.16 from Q3.8 counts. No clinical
record or calibrated millivolt scale is claimed. Default warm-up is 10 s and
measurement is 60 s: 1200 warm-up + 7200 measured samples = 8400 total.
The capture is exactly [11 s,71 s), followed by 2 s to drain the last result.

Sampling is 120 samples/s on average, synchronous to the source. At 500 Hz,
delivery intervals alternate between 4 and 5 clock cycles; at 100 kHz, between
833 and 834 cycles. Thus timestamps differ by clock quantization, although
sample values/order, capture boundaries and mean sample rate are matched.
Both paths use 240-sample windows and 120-sample strides. The comparison checks
complete Stage 1 IDs, decisions and fixed-point scores, excluding their
different output latencies. The local 60 s tests matched all those results.

These are NORMAL-ONLY experiments. The test stops if Stage 2 is requested or
any overflow occurs. A permanent 500 Hz source cannot be assumed to sustain
active Stage 2 plus Stage 1 replay. This is not an adaptive-wakeup design.

## Upload and run on AWS

Upload CadenceDirectClockPower.tar.gz to /home/ec2-user, then:

```bash
cd /home/ec2-user
tar -xzf CadenceDirectClockPower.tar.gz
cd CadenceDirectClockPower
export ECG_RTL_DIR=/home/ec2-user/FINAL_RTL
export ECG_LIB=/opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/timing/slow_vdd1v0_basicCells.lib
bash run_both.sh
```

The scripts run Xcelium, validate a bounded VCD, then run Genus for each case.
Genus uses -del_scale 10 to avoid the observed low-frequency timing conversion
overflow. It reads the native TLATNCAX12 Liberty gate, never the functional
simulation model. Selected library corner is actually 0.9 V and 125 C, despite
the filename. The 100 kHz case bypasses the ICG adapters entirely.

run_both.sh prints a fresh runs/pair_XXXXXX directory. It contains each case's
simulation.log, config.txt, original VCD, bounded VCD, Genus log, mapped.v,
mapped.sdc, reports and capture audit. Only after matching results, provenance,
library and mapped activity coverage does summarize.py write comparison.csv
and comparison.md. Unsupported annotation reporting prevents acceptance of the
comparison; it does not silently replace activity with default toggles.

To select a different measurement length (integer seconds, same for both):

```bash
ECG_MEASURE_SECONDS=10 bash run_both.sh
```

Or run a single case, still including Xcelium followed by Genus:

```bash
bash run_case.sh gated_500hz
bash run_case.sh ungated_100khz
```

ECG_SIM_ONLY=1 skips Genus, not waveform validation. No quick/reduced-clock
power mode exists: 500 Hz and 100 kHz are the actual requested clock rates.
The original VCD is preserved; a separate bounded copy excludes the dump-off X
block and all drain activity. Preparation reports progress every roughly 10%.
Local 60 s XSim waveforms were approximately 29 MB and 542 MB before bounding;
server sizes can differ, but no 100 MHz divider activity is being dumped.

Inspect clocks.rpt, timing_intent.rpt, mapped_unresolved.rpt,
mapped_annotation.rpt, capture_validation.txt and preliminary_power.rpt before
using results. Coverage is not timing/CDC/physical sign-off. Report total,
dynamic=(internal+switching), leakage and energy=Pavg*T separately. Small area
differences can include both ICG removal and timing-driven cell mapping; they
do not independently establish shared-versus-duplicated architecture savings.

## Clean old AWS waveforms, preserve all logs and reports

Finish or stop old simulation/synthesis/capture processing before cleanup.
Preview the exact candidates (read-only):

```bash
bash /home/ec2-user/CadenceDirectClockPower/cleanup_previous_waveforms.sh --dry-run
```

After reviewing the list, remove those waveform files:

```bash
bash /home/ec2-user/CadenceDirectClockPower/cleanup_previous_waveforms.sh --delete
df -h /home/ec2-user/CadencePowerAnalysis
```

The default scope is ONLY /home/ec2-user/CadencePowerAnalysis. The script checks
the resolved directory name, recognized simulation-run naming, presence of
simulation logs/configs, and exact regular-file paths. It selects only files
>=10 MiB named activity.vcd or activity.normalized.tmp, plus activity.vcd inside
recognized power_capture_XXXXXX subdirectories. It never recursively deletes
directories. Symlink targets outside the selected run are skipped. It refuses
deletion if known EDA/capture processes are running and checks file usage with
fuser where available.

It preserves ALL logs, reports, configs, RTL, mapped netlists, simulator build
directories and archives, and never touches FINAL_RTL or the new package.
Deletion is permanent unless a backup exists; retained logs are not sufficient
to reconstruct a VCD without resimulation. Review the dry run first. The
optional second argument is an explicitly named old CadencePowerAnalysis root,
used by the isolated cleanup tests; never pass a home/workspace root.

## Verification status

Local XSim 2020.2 functional tests passed at the actual 500 Hz and 100 kHz rates
for both 1 s and 60 s measurements. The 60 s tests accepted all 8400 samples,
reported 60 measured Stage 1 classifications, no Stage 2 requests/results and
no overflows; all 67 complete Stage 1 IDs/decisions/scores matched after drain.

VCD regressions cover real-rate clock counts, aliases, unrelated parameter/data
declarations, exact endpoints, retained unknown data and rejected bad captures.
Cleanup tests check dry-run immutability, process guards, preservation of large
logs/reports/unrelated data, root rejection and symlink protection where native
symlinks are available. Python summary tests use explicitly synthetic reports,
not measured power. Tcl control-flow/provenance tests use explicit command
stubs; they do not prove installed Cadence command compatibility.

```bash
bash tests/test_analysis.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_summary.py
```

Not run locally: Xcelium, Genus, library-based power or physical implementation.
The server must verify actual Cadence capture/import/report behavior. No new
watt-level result is claimed by this package. FinalRTL manifest checks remain
unchanged.
