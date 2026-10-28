# Whole-pipeline adaptive clock experiment

Snapshot note: the project, test scripts and reports described below live
in the canonical sibling `final_two_stage_design/hardware/` package.
Relative project/report paths below refer to its `adaptive_clock_test/`
folder, not this snapshot's `docs/` folder. The adaptive core RTL itself is
also included in this snapshot's `rtl/` folder.

Implemented on 2026-10-08. The fixed-clock project is preserved; the new
project is `../vivado_adaptive_project/two_stage_adaptive.xpr`, top
`basys3_two_stage_adaptive_top`, target `xc7a35tcpg236-1`.
The saved project's own source/constraint configuration also passed
project-context synthesis, with both generated processing clocks present.

## Policy

The shared sequencer, filters, streaming statistics, RAM, replay datapath
and classifier controller all use one processing clock:

- Stage 2 asleep: 500 Hz. Normal Stage 1 windows do not request fast bursts.
- Stage 1 abnormal 2-of-3 sequence decision: arm Stage 2 and request 100 kHz.
  Both stages use 100 kHz for the entire episode.
- Two consecutive normal sequence decisions: stop new Stage 2 windows.
  Remain at 100 kHz while started windows collect, become ready/pending,
  replay and classify. Their historical results are retained.
- After Stage 2 drains: return to 500 Hz. A later abnormal episode wakes it.

`processing_fast_request` includes arm/restart, collecting banks, the ready
handoff, pending work and Stage 2 replay/classifier states. It is not merely
the classifier MAC's clock-enable. The existing Stage 2 statistics and shared
MAC BUFGCE gating remain in place. The Stage 2 causal filter stays warm.

## Clock and input implementation

`ecg_adaptive_clock.v` uses one 17-bit counter, a registered output and one
BUFG. The 100 MHz source remains running. Half-cycle terminal counts are
99,999 for 500 Hz and 499 for 100 kHz. A synchronized request changes the
terminal count only at the boundary of a complete old half-cycle. There is
no BUFGMUX, additional MMCM or separate Stage 1 clock.

The slow-to-fast change completes after the remaining old half-cycle
(at most 1 ms plus synchronization). The next rising processing edge can
follow 5 us later. This is frequency switching, not voltage scaling.

Acquisition is separate: a periodic 120 Hz source in the source-clock domain
feeds a one-entry, 32-bit bundled-data mailbox with request/acknowledge
synchronizers. Hold data until acknowledged and respect `sample_ready`;
also wait for `clock_ready` at startup. `input_overflow` is sticky if a busy
mailbox receives another sample. Arbitrary bursts are not supported. The
source reset release is synchronized. Outputs are in the processing domain;
an external host must synchronize them or use a result mailbox.

At 500 Hz, request synchronization/delivery adds several milliseconds; the
next valid presented to the core is its next accepted input sample. The
existing shared-sequencer restart rule uses that core acceptance boundary,
not the earlier source-domain acquisition timestamp. No samples are
intentionally dropped during switching.

The board demo keeps its 120 Hz cadence on the 100 MHz source clock, not on
the variable processing clock. LED 15 shows actual fast mode, LED 14 shows
the episode/drain request, and LED 5 shows overflow. Switch 14 enables demo
playback, switch 15 releases reset. Buttons are a non-debounced bring-up aid.

## Latency trade-off

The default `STAGE1_FULL_RATE=0` is unchanged: 240 Stage 1 replay samples take
480 processing cycles. At 500 Hz this is 0.96 s, plus prefetch, scheduling and
scoring overhead. Therefore the clock switch's approximately 1 ms delay is
not the dominant delay from a completed window to an abnormal decision.
Stage 2 still needs its new 240 samples (2 s) before subtype classification.

`STAGE1_FULL_RATE=1` is optional and tested, reducing nominal idle replay to
0.48 s. It is not enabled in the new project's defaults. Slower decisions
change trigger-aligned window start indices relative to the fixed-100-kHz
baseline. Bit-exact scores for the same sample span are verified; identical
episode timing or unchanged end-to-end detection accuracy is not claimed.

## Functional verification

ModelSim passed the actual-100-MHz divider test: eight complete slow and
27 complete fast half-cycles, with no runt/extended transition pulses.

Integrated reference tests use a 200 kHz source for simulation speed while
keeping the actual 500 Hz/100 kHz processing periods and 120 Hz sample rate.
Real 100 MHz source logic is checked separately by the divider test and
Vivado timing. This is RTL verification, not an FPGA measurement.

| Stimulus | Samples | Stage 1 scores | Stage 2 scores | Arms | Slow returns |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed, phase 0, default replay | 1200 | 7 | 4 | 1 | 0 |
| Mixed, phase 199999, default replay | 1200 | 7 | 4 | 1 | 0 |
| Stress/normal decisions, default replay | 1200 | 9 | 0 | 0 | 0 |
| Reactivation, phase 0, default replay | 3600 | 25 | 15 | 2 | 1 |
| Reactivation, phase 199999, full-rate replay | 3600 | 25 | 15 | 2 | 1 |

All transmitted samples were accepted and filtered exactly once, all checked
scores/features/classes matched the integer reference for their sample span,
and no mailbox, window or classifier overflow was detected. Both reactivation
runs reported two historical results after disarming. Finite traces may end
while Stage 2 remains armed or a partial window lacks future samples; such a
partial window cannot finish without more input. The normal-decision case
never entered fast mode. The worst observed arm-to-mode latency was
1,002,500 ns with the slower simulation source, including observation delay.

## Reproduce

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\final_two_stage_design\hardware\scripts\run_adaptive_tests.ps1
```

Vivado project creation and paired implementation:

```powershell
vivado -mode batch -source final_two_stage_design/hardware/scripts/create_adaptive_vivado_project.tcl
vivado -mode batch -source final_two_stage_design/hardware/scripts/implement_adaptive_comparison.tcl
```

The matched board-level builds share acquisition, the mailbox, the 240-entry
core, classifiers, gate policy and replay rate. `ADAPTIVE_CLOCK=0` fixes
processing at 100 kHz; `1` enables the policy above. The common XDC checks
both steady-state rates (the fixed hardware only uses fast mode) and keeps
100 MHz source timing active. It exempts only synchronization first stages,
uses a bounded mailbox data path, and does not declare the entire source
and processing domains asynchronous. The slow generated-clock period may
show 2,000,000.125 ns due to Vivado representation; the divider count is exact.
Generated-clock construction follows [AMD UG835](https://docs.amd.com/r/2020.2-English/ug835-vivado-tcl-commands/create_generated_clock).

## Paper and power interpretation

Vivado 2020.2 routed results, default half-rate Stage 1 replay:

| Component/resource | Fixed 100 kHz | Adaptive 500 Hz / 100 kHz | Difference |
| --- | ---: | ---: | ---: |
| Divider/controller LUTs | 14 | 29 | +15 |
| Divider/controller flip-flops | 15 | 23 | +8 |
| Mailbox LUTs / flip-flops | 119 / 34 | 119 / 34 | unchanged |
| Complete board wrapper LUTs | 5186 | 5172 | -14 |
| Complete board wrapper flip-flops | 2397 | 2404 | +7 |
| RAMB18 blocks | 2 | 2 | unchanged |
| DSP blocks | 48 | 48 | unchanged |
| Global clock resources | 4 | 4 | unchanged |
| Worst setup slack, ns | 3.862 | 3.536 | both pass |
| Worst hold slack, ns | 0.029 | 0.037 | both pass |

Use +15 LUTs/+8 flip-flops as the observed isolated divider cost. The whole
board LUT decrease is not a claim that frequency selection removes logic:
constant propagation, cross-hierarchy packing and implementation choices
(notably the demonstration source) differ. Both builds include the mailbox;
its cost is additional relative to a directly clocked input interface. The
board's 12-bit Q3.8 input lets Vivado fold unused mailbox bits; a fully general
32-bit acquisition port need not have this same 34-flip-flop mailbox cost.
Reports `mode0_*` and `mode1_*` are respectively fixed and adaptive.

Both timing reports have zero unclocked registers and zero unconstrained
internal endpoints. Fast processing-domain setup slack is 9,937.240 ns for
the adaptive build; the quoted overall WNS also includes 100 MHz and
inter-domain paths. No maximum achievable processing frequency was measured.

The DRC reports have no errors or critical warnings, but retain existing
DSP-pipelining and asynchronous RAM-control warnings. CDC reports are not
clean sign-off: they flag external reset distribution, manually held switch
data and reset-controlled BUFGCE paths. Multi-clock synchronizer fan-in is
also reported because two physically exclusive timing modes share the same
physical source. Request/acknowledge crossings are recognized as two-stage
synchronizers, and mailbox data paths use the handshake and bounded maximum
delay. No blanket CDC waivers were added. Production reset/ADC integration
still requires review and board validation; no bitstream or FPGA power
measurement was performed for this experiment.

This experiment extends the earlier fixed-100-kHz 240-entry versus 1-kHz
512-entry comparison. Keep those earlier numbers separate: this experiment
also introduces a source-domain acquisition interface and mailbox.

An idle processing-clock rate of 500 instead of 100,000 Hz gives 200 times
fewer processing-clock edges per second (99.5% edge-rate reduction). It is
not a 99.5% total-power saving. The 100 MHz divider/acquisition logic remains
active, per-sample arithmetic still executes, active episodes use 100 kHz,
and FPGA static/leakage power is not directly removed by clock gating or
frequency reduction. No new watt-level saving is measured here. The old
fixed-clock RTL SAIF reports must not be reused as adaptive power results;
post-route activity for both modes and/or paired rail-current measurements
are still needed.
