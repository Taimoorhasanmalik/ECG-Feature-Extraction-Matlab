# Stage 1 one-sample-per-clock replay experiment

The default 240-entry core keeps Stage 1 replay at one sample every two
100 kHz processing clocks (`STAGE1_FULL_RATE=0`), while Stage 2 already uses
one sample per clock. This experiment sets `STAGE1_FULL_RATE=1` without
changing the sample window, filter, feature equations, model, Stage 2 gate,
or Stage 1/Stage 2 priority.

## Result

- The full `final_two_stage_design/hardware/scripts/run_tests.ps1` RTL
  regression passed. The new full-rate runs matched the independent Python
  reference on the 1,200-sample candidate vector (8 Stage 1 scores,
  5 Stage 2 scores) and the 3,600-sample reactivation vector (27 Stage 1
  scores, 16 Stage 2 scores, two arm events, two drained results). No
  overflow was reported.
- A core-only Vivado 2020.2 implementation routed successfully for
  `xc7a35tcpg236-1` at 100 kHz, with 0 timing failures. The timing report
  gives setup WNS = +9936.704 ns and hold WHS = +0.046 ns.
- Routed resources were 4,871 LUTs, 2,315 registers, 48 DSPs, and two
  RAMB18s. The previous half-rate gated routed core used 4,875 LUTs,
  2,318 registers, 48 DSPs, and two RAMB18s. These tiny differences are
  specific to these separately routed core-only builds.

Nominal Stage 1 replay is now 240 clocks = 2.4 ms instead of 480 clocks =
4.8 ms. If both Stage 1 and Stage 2 replays are pending, their nominal
sequential replay total drops from 7.2 ms to 4.8 ms, leaving about 3.53 ms
before the next nominal 120 Hz sample. Prefetch, classifier scoring, and
control add cycles. The input contract assumes non-bursty 120 Hz arrivals.

The default remains half-rate. This is a verified optional experiment, not
yet a board-bitstream or measured-power comparison. It does not establish
that full-rate replay uses less energy; switching is compressed into a
shorter interval and must be measured separately.

Reproduce routing from the repository root:

```powershell
& 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat' -mode batch -source final_two_stage_240_power_design\scripts\test_stage1_full_rate_timing.tcl -nojournal -nolog
```
