# Two-stage 240-entry power-comparison package

The optional adaptive whole-pipeline clock RTL is also included: 500 Hz idle,
100 kHz while Stage 2 is active/draining, with a source-domain sample mailbox.
See `docs/two_stage_adaptive_clock.md` for policy, latency and verification.
The reproducible adaptive tests and separate Vivado project are in the
canonical sibling `final_two_stage_design/hardware/` package. Existing power
reports in this folder remain the fixed-100-kHz gate comparison, not adaptive
clock power measurements.

This standalone snapshot contains the 240-entry shared-replay ECG core and
the gated-versus-always-on Stage 2 clock experiment. It is packaged like
`final_low_power_design`: sources, a reproducible test, reports, a paper note,
and a manifest are together. It does not contain ECG databases, trained MATLAB
models, Vivado caches, or a board-current measurement.

The two variants differ only in the `CLOCK_GATING` parameter:

- `1`: Stage 2 window-statistics clock closes outside armed/started windows;
  the shared classifier MAC clock opens only for scoring.
- `0`: both of those clocks remain enabled after reset.

Both variants keep the Stage 2 causal high-pass filter running to preserve its
state. Both use the same Stage 2 RAM write-enable policy. The target is
`xc7a35tcpg236-1`, with a 100 kHz processing clock and 120 Hz input samples.
This is the shared-replay 240-entry design, not the earlier separate-window
`two_stage_ecg_top` architecture.

`STAGE1_FULL_RATE=1` is an optional verified experiment that advances Stage 1
replay every clock, like Stage 2. The shipped default remains `0` (alternate
cycles). See `stage1_full_rate_test/README.md` and its routed reports.

## Existing result

The included synthetic, mostly-normal trace contains 2,400 samples (20 s)
plus 1 s to drain pending work. It produced 17 normal Stage 1 results, no
Stage 2 results, and identical cycle-by-cycle outputs in both variants. The
gated Stage 2 statistics clock was enabled for 0 of 2,100,001 processing
cycles; the gated shared classifier clock for 114 cycles. The always-on
variant enabled both for the full trace.

Routed Vivado 2020.2 reports for both variants show 0.070 W total on-chip,
0.000 W dynamic, and 0.070 W device static at 0.001 W display precision.
This does **not** resolve a numeric power saving: only about 11% of routed
nets matched the RTL SAIF, and Vivado warned about gated-clock activity.
Clock-cycle suppression is proven; a watt-level saving is not yet measured.
See `docs/two_stage_idle_clock_gating_power.md` for the paper-ready caveats.

## Reproduce

From this folder, with Vivado 2020.2 installed at
`C:\Xilinx\Vivado\2020.2`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_power_comparison.ps1
```

The script compiles the paired XSIM test, regenerates
`power_comparison/mostly_normal_240.saif`, and routes/reports both variants.
Pass `-VivadoRoot <path>` if Vivado is installed elsewhere. It uses a fresh
temporary simulator work directory; the selected reports and SAIF are written
into this package. A complete run takes considerably longer than an RTL-only
test. The supplied reports are the already-generated result, so rerunning is
optional.
Use `-SimulationOnly` to run the paired activity test without rerouting.

To substantiate a small power difference, the next experiment should use
post-implementation activity with better net matching and preferably a
paired FPGA rail-current measurement with the same waveform, voltage, and
temperature in both gate modes. No physical power saving is claimed here.
