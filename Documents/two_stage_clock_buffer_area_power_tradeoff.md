# Paper note: shared replay history depth versus processing clock

The combined 120 Hz ECG hardware was evaluated with two implementations of
the same Stage 1 and Stage 2 fixed-point filters, features, SVM coefficients,
sequence gate, shared replay engine, and clock-gated shared classifier MAC.
Both target the Basys 3 XC7A35T. They differ in the circular history depth
and the processing-clock rate:

| Variant | Logical history | Processing clock | Reason for clock choice |
| --- | ---: | ---: | --- |
| Deep history | 512 x 32 bits | 1 kHz | New samples can arrive while a completed window is replayed. |
| Shallow history | 240 x 32 bits | 100 kHz | Replay must outrun overwrite of the oldest completed-window samples. |

The corresponding Stage 1 replay latencies are about 480 ms and 4.8 ms;
Stage 2 replay latencies are about 240 ms and 2.4 ms. These are processing
latencies after a window closes, not the 2 s window-acquisition time.

At 120 Hz, consecutive samples are 8.33 ms apart. Stage 1 replay consumes
480 clocks (240 samples, alternate cycles), and Stage 2 consumes 240 clocks
(one sample per cycle). Thus the conservative bound to finish both replays
before the next input sample is 720 / 8.33 ms = 86.4 kHz; 100 kHz was
selected with control/scoring margin. This is an architectural throughput
choice, not the FPGA's maximum clock frequency. The 512-entry history permits
the same replay work to extend across incoming samples at 1 kHz.

The two variants use the same model for an identical sample-aligned window,
and both pass fixed-point filter, feature, and score reference checks. Their
end-to-end *window schedules* are not necessarily identical: Stage 2 begins
on the next input sample after the Stage 1 sequence decision, which arrives
later with 1 kHz replay. Therefore equal per-window model accuracy does not
by itself establish equal episode-level accuracy or latency. A matched
record-level cascade evaluation is required before claiming that.
For example, the 3,600-sample reactivation simulation reported 27 Stage 1
and 16 Stage 2 results at 100 kHz, versus 26 and 17 at 1 kHz. Each reported
score matched its fixed-point reference for that window; the result counts
differ because the triggered windows differ.

Vivado 2020.2 is used to synthesize, place, route, and run `report_power` for
both variants with the same XC7A35T part, board wrapper, and model. The
reports in `final_two_stage_design/hardware/power_comparison/` are vectorless
power estimates, not board measurements or ECG-activity-based SAIF estimates.
They should be used as an initial design-space comparison; final power claims
need matched ECG activity, an active/idle duty-cycle distribution, and ideally
board-current measurement. Static and dynamic power must be reported
separately. In particular, a smaller logical RAM need not occupy fewer FPGA
BRAM blocks because allocation is granular.
Both variants retain the same classifier BUFGCE gate and Stage 2 RAM write
enable; this comparison does not isolate the savings from clock gating.

## Routed Vivado comparison

| Variant | LUTs | Flip-flops | DSP48E1 | RAMB18E1 | On-chip total | Dynamic | Device static | Power confidence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 512 entries, 1 kHz | 5,138 | 2,360 | 48 | 2 | 0.079 W | 0.007 W | 0.072 W | Low |
| 240 entries, 100 kHz | 5,155 | 2,368 | 48 | 2 | 0.079 W | 0.007 W | 0.072 W | Low |

Both builds met timing on the board target. The 100 MHz input-clock worst
negative slack was 6.430 ns for the 512-entry build and 7.493 ns for the
240-entry build. The 1 kHz and 100 kHz generated clocks were each constrained
to their actual divider ratios. Vivado reports power to 0.001 W; equality in
the table means **no resolved difference at that precision**, not equal
physical power. The total is estimated FPGA on-chip power, not Basys 3 board
input power. Vivado explicitly assigned low overall confidence because most
I/O activity was unspecified and there was no simulation activity file.

The 512-entry variant uses 17 fewer LUTs and 8 fewer flip-flops, with the
same DSP and BRAM allocations. Thus the 240-entry design did **not** save
mapped BRAM area on this FPGA. At the available reporting precision, neither
variant has demonstrated a power advantage. For the measured FPGA resource
counts, the 512-entry build has the slight edge; its lower processing clock
is also attractive, but a quantitative power-saving claim requires
ECG-driven switching activity or board-current measurements. Keep the
deployed 240-entry default unchanged until end-to-end trigger latency,
window schedules, and workload power are compared using a common criterion.
These resource numbers predate the later Stage 2 statistics-clock-gate
ablation; see `Documents/two_stage_idle_clock_gating_power.md` for that
separate, core-only experiment.

Suggested paper wording: "We implemented both a 512-entry, 1 kHz history
and a 240-entry, 100 kHz history using identical fixed-point models. The
smaller logical history did not reduce physical BRAM allocation on the
XC7A35T. The 512-entry build used 5,138 LUTs versus 5,155, while Vivado's
low-confidence vectorless estimates reported 79 mW on-chip power for both.
Consequently, these estimates do not establish a power benefit from the
240-entry design; activity-driven power and end-to-end latency measurements
are needed before selecting an overall optimum."
