# Cadence ASIC analysis of the final ECG RTL

This is a separate analysis adapter, not a replacement for FinalRTL. The final
FPGA RTL is not edited. Set ECG_RTL_DIR to the uploaded directory containing
rtl/files.f and mem/. No MATLAB files or ECG database copies are required.

## Scope and status

- User environment: Xcelium 26.03 and Genus 25.1 found on PATH.
- Library selected by the user: gsclib045 slow_vdd1v0_basicCells.lib.
- Actual reported nominal corner: 0.9 V, 125 C, nom_process=1; time unit 1 ns,
  leakage power unit 1 pW. The filename is not the actual voltage specification.
- User verified the TLATNCAX12 pins: CK=input clock, E=input enable,
  ECK=gated-clock output; latch_posedge integrated clock-gating cell.
- BUFG becomes a logical wire; BUFGCE wraps that native cell. The functional
  simulation model has no physical delays or power. Genus never reads it.
- X12 is the verified cell, not an optimal gate-sizing claim. Clock-tree
  synthesis and smaller equivalent gates may change its final cost.
- Server bring-up completed in Xcelium 26.03 and Genus 25.10-p002_1. The first
  normal-workload power report used an overlong VCD interval and is provisional.
  The corrected capture path below still needs a server power rerun. Do not
  treat script completion as physical sign-off.
- This is a generic-library ASIC estimate, not Artix-7 or fabricated-silicon
  power. No SRAM macro is supplied; the logical history uses standard-cell
  storage. No routed wires, physical CTS or board/ADC/demo logic is included.

## Files

- rtl/asic_clock_primitives.v: synthesis adapter with a native gate instance.
- rtl/ecg_asic_power_top.v: selected final core, without the FPGA board wrapper.
- sim/gsclib_icg_functional.v: simulation-only gate model; NEVER synthesize it.
- sim/ecg_asic_power_tb.sv: identical deterministic sample streams and bounded
  VCD capture, with input/overflow/result checks.
- run_xcelium.sh: isolated run directories, explicit source lists and metadata.
- prepare_power_capture.sh and normalize_vcd.awk: create a separate bounded,
  normalized VCD and audit clock edges. Preserve the original VCD and logs.
- tests/test_capture.sh: small VCD boundary/clock/provenance regressions.
- POWER_CAPTURE_UPDATE.md: repair the existing server capture and rerun power.
- genus_synth.tcl and constraints/core.sdc: Common UI synthesis bring-up and
  optional preliminary activity-based power report. Installed-tool command
  compatibility and activity annotation must be checked on the user's server.

## 1. Server setup

Place this folder alongside (not inside) your final hardware folder, then set:

```bash
export ECG_RTL_DIR=/absolute/path/to/FINAL_RTL
export ECG_LIB=/opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/timing/slow_vdd1v0_basicCells.lib
cd /absolute/path/to/CadencePowerAnalysis
```

Do not use the FPGA XDC in Genus. Do not compile the old portable clock models
alongside these adapters; that would define BUFG/BUFGCE twice.

## 2. Functional bring-up first

```bash
ECG_QUICK_SIM=1 bash run_xcelium.sh adaptive_gated normal
ECG_QUICK_SIM=1 bash run_xcelium.sh adaptive_gated demo
ECG_QUICK_SIM=1 bash run_xcelium.sh fixed_gated demo
ECG_QUICK_SIM=1 bash run_xcelium.sh fixed_ungated demo
```

Quick runs use a 200 kHz source but real 500 Hz/100 kHz processing and 120 Hz
sampling. They produce NO power activity and are rejected by the power script.
Default warm-up is 1200 samples (10 s), then 120 measured samples (1 s).
The demo repeats the packaged 1200-sample synthetic waveform. The normal
workload uses the earlier deterministic low-rate beat. These are workload
checks, not ECG accuracy/reference regressions or clinical labels.

Each run prints its fresh directory and stores simulation.log and config.txt.
The two fixed-clock cases should produce identical RESULT sequences; compare
their logs before interpreting a gate-power difference. Adaptive timing can
change the trigger-aligned sample spans, so do not require identical adaptive
window IDs/classes or claim unchanged end-to-end accuracy from this test.

## 3. Synthesis bring-up without a power claim

```bash
export ECG_MODE=adaptive_gated
unset ECG_VCD
mkdir -p synth_adaptive_bringup
cd synth_adaptive_bringup
genus -del_scale 10 -files ../genus_synth.tcl
```

Read unresolved.rpt and mapped_unresolved.rpt: there must be no unresolved
selected-path modules or cell references. Inspect gates.rpt for native gates,
memory mapping and the expected selected filter/MAC. Review clocks.rpt,
generated_clocks.rpt, timing_intent.rpt and timing.rpt; do not hide failures
with broad false paths. The delay scale avoids the observed internal ps
conversion overflow at 500 Hz; it does not change the RTL clock rates.
This flow generates
no power report without an explicitly supplied full-rate VCD.

## 4. Full-rate activity capture

Back in CadencePowerAnalysis, after functional checks:

```bash
bash run_xcelium.sh fixed_ungated normal
bash run_xcelium.sh fixed_gated normal
bash run_xcelium.sh adaptive_gated normal
```

These use the actual 100 MHz source. Simulation has roughly one billion
source cycles before default capture, and a full-hierarchy VCD can be several
GB per measured second. Check disk space/runtime first. Warm-up is not dumped;
the duration is printed by CAPTURE_END. Capture processing preserves the raw
VCD and writes a bounded copy under power_capture_XXXXXX/, requiring space for
both files. It keeps [CAPTURE_START,CAPTURE_END), writes an exact end timestamp,
and excludes dump-off unknown values and all later simulation-drain timestamps.
It audits source/processing/Stage 2 statistics/MAC clock edges and rejects
incomplete captures, unknown monitored clocks and metadata mismatches. Ordinary
unknown data is preserved, not silently filled with zeros. Acquisition
starts at the same source-clock phase across modes after a fixed startup wait.
For long studies use the installed
Cadence native activity/SAIF flow instead of unbounded VCD. Do not accelerate
the source and rescale the result: divider width/activity would be different.

Repeat all modes with demo to exercise Stage 2. A trace average, an idle
average and an active average are different quantities. Check the measured
S1/S2 counts and fast-mode activity; extend/shift capture if the desired event
is outside it. ECG_WARMUP_SAMPLES and ECG_MEASURE_SAMPLES override the defaults.
Do not shorten capture below a full 1-second stride and call it a steady-state
average; startup, collection, replay and drain must be considered separately.

## 5. Preliminary RTL-activity power in Genus

Use the "Validated power VCD" path printed by the full-rate simulation, NOT
the raw activity.vcd in the simulation directory. Existing old captures can
be repaired with prepare_power_capture.sh; see POWER_CAPTURE_UPDATE.md.

```bash
export ECG_MODE=fixed_gated
export ECG_VCD=/absolute/path/to/fixed_gated_normal_quick0_XXXXXX/power_capture_XXXXXX/activity.vcd
mkdir -p synth_fixed_gated_normal
cd synth_fixed_gated_normal
genus -del_scale 10 -files ../genus_synth.tcl
```

Repeat in separate output directories for the other modes. Keep the exact same
library, RTL, input workload, input phase, warm-up and capture duration. The
script requires matching mode, full-rate, bounded-capture provenance and a
successful capture audit. read_vcd is applied at RTL before mapping
to allow activity propagation. If Genus 25.1 rejects an option, STOP and inspect
its `help read_vcd`; do not replace it with guessed/default toggle rates.
Likewise, unresolved references and poor annotation coverage invalidate a
power result even if report_power creates a file. Inspect the annotation log,
clock activities, undriven/uninitialized state and register/memory coverage.
The script requests post-power activity and annotation reports when exposed
by the installed Genus interface; activity_audit_status.txt explicitly records
unsupported or failed report commands. Missing reports are not a coverage pass.

Any preliminary_power.rpt is pre-layout and only a first-pass estimate. It
does not capture a routed clock tree or accurate gate-delay glitches. For a
stronger result, simulate the mapped netlist with matching vendor cell models
and annotated delays, then analyze that activity using an available supported
power flow. Never use the simple TLATNCAX12 functional model as a replacement
for the complete standard-cell simulation library in that gate-level step.

## Comparisons and paper interpretation

1. fixed_ungated versus fixed_gated isolates the explicit clock gates. It does
   NOT turn off the data/write enables or force Stage 2 classification always.
2. fixed_gated versus adaptive_gated compares frequency policy with gates
   enabled. Report changed trigger timing/activity alongside the power result.
3. Shared-versus-duplicated area needs another matched architecture baseline;
   these three cases alone do not establish datapath-sharing area savings.

Report internal, switching, leakage and total power separately with units,
actual voltage/temperature, memory implementation, library, workload and tool
versions. Clock gating does not remove supply leakage. The 100 MHz divider and
acquisition remain active. No battery-life or silicon-measurement claim follows
from these estimates. PDK/process generation is generic, not a foundry sign-off.

## Local verification - 2026-10-12

Vivado XSim 2020.2 compiled and elaborated the final wrapper, adapters and
testbench. Reduced-source functional checks (no power dump) passed:

| Mode | Workload | Accepted samples | Stage 1 reports | Stage 2 reports |
| --- | --- | ---: | ---: | ---: |
| adaptive_gated | normal | 1320 | 7 | 0 |
| adaptive_gated | demo | 1320 | 4 | 5 |
| fixed_gated | demo | 1320 | 4 | 5 |
| fixed_ungated | demo | 1320 | 4 | 5 |

Both fixed-mode demo runs produced identical nine-result traces, including
timestamps and IDs. All runs accepted every transmitted sample and reported
no overflow. Their capture intervals were the same 1-second absolute span;
normal adaptive operation had 500 processing edges in that span. These checks
are functional, not bit-exact-reference/clinical or physical-library tests.

Bash syntax and Tcl lexical-completeness checks passed. VCD timestamp
normalization was checked on a synthetic 10^13-tick-offset example. All 16
FinalRTL manifest checksums remain unchanged. Temporary local simulator
outputs are outside this package and are not transferred.

Not run locally: Xcelium, Genus, the physical Liberty model, full-100-MHz
activity capture or any watt-level analysis. Tcl lexical checks do not verify
Genus command/SDC compatibility. Inspect server logs before any power claim.

## Capture-boundary correction - 2026-10-12

The old server normal-workload VCD spanned 1.027999985 s despite a 1 s capture.
Its final dump-off X block and drain timestamp could distort average power.
The 20.037 uW result is provisional and must not be manually rescaled.

The corrected processor preserves the input and clips at the logged duration.
Synthetic regressions passed for raw/old-normalized/already-bounded inputs,
ps/ns timescales, CRLF, aliased clock identifiers, a short 100 MHz source fixture,
and preserved unknown data. Rejection cases include wrong origin, missing and
unknown clocks, incorrect source counts, truncated/backwards timestamps, early
dump-off, quick simulations and incomplete metadata. Run:

```bash
bash tests/test_capture.sh
```

Tcl completeness and provenance rejection/control-flow checks also passed with
explicit Genus command stubs (tests/test_genus_provenance.tcl). These do not
verify installed Cadence command behavior or compute actual power.

No final RTL or filter/classifier logic was changed. Tests do not establish
clinical accuracy, physical timing closure or mapped power coverage.

### VCD declaration lookup correction

The server exposed a parser bug: looking up an unrelated $var declaration in
an AWK array inserted an empty entry, subsequently misidentified as a required
clock. PREFETCH_1 was a parameter, not a missing hardware clock. Membership is
now checked before lookup. The regression fixture includes unrelated parameter,
data and packed-vector declarations; it reproduced the exact PREFETCH_1 failure
before the fix and passes after it. No clock checks were disabled.

### Fixed-clock workload validation correction - 2026-10-13

The fixed 100 kHz normal run correctly reported 100000 processing edges and
100000 fast edges, with no Stage 2 results. The capture wrapper incorrectly
applied the adaptive-only zero-fast-edge requirement to fixed modes. The
validator now separates Stage 2 result checks from frequency-policy checks:
normal workloads require zero Stage 2 results in every mode; adaptive normal
requires zero fast edges; both fixed modes require all processing edges to be
fast. Regression tests confirm fixed normal metadata reaches the VCD audit,
while normal Stage 2 activity and adaptive-normal fast activity remain rejected.
The completed fixed-mode simulation can be reprocessed without resimulation.
