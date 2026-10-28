# ASIC-native 100 kHz adaptive clock

This is the ASIC variant. FinalRTL and the previously routed 100 MHz
implementation are preserved separately as the FPGA/reference design.
The common filter, history, feature and classifier RTL is unchanged.

## Clock architecture

The only external master is 100 kHz. One latch-based integrated clock gate
drives the processing clock:

- Fast: pass every source pulse, so processing runs directly at 100 kHz.
- Slow: pass one complete pulse per 200 cycles, giving 500 rising edges/s.
- The counter is held during fast mode; there is no fast divider or clock mux.
- Requests cross through two source-clock synchronizer flops. The gate
  enable and mode state update on the source falling edge, when the gate
  latch is transparent. They are stable before the next source rising edge.
- Stage 2 activation/draining policy, common datapath and 120 Hz acquisition
  are unchanged. The existing sample mailbox remains in the full core.

In slow mode each output pulse is 5 us high and 1995 us low (0.25% duty),
not a 50%-duty divided square wave. The pipeline uses rising edges. The SDC
expresses this waveform explicitly with `-edges {1 2 401}`. Every fast/slow
output high pulse is a full source half-cycle; reset assertion is allowed
to interrupt a pulse. External source-clock generation power is not modeled.

## Validation and synthesis on AWS

```bash
cd /home/ec2-user/CadenceASIC100kHz
bash run_sim.sh clock
bash run_sim.sh normal
bash run_sim.sh demo
bash run_synth.sh
```

Clock tests cover exact steady periods, full pulse width, held fast-mode
counter, 60 phase-offset mode changes and reset recovery. The pipeline
tests check accepted sample counts, overflow, valid classifications and
Stage 2 activity on the synthetic demo. They are not clinical accuracy tests.

The source list is `rtl/files.f`. Synthesis uses the actual gsclib045 Liberty
ICG cell, never the functional simulation model. The clock names are
`source_100khz`, `processing_fast` and `processing_slow`.
The synthesis runner creates a fresh run and does not overwrite earlier data.

For the existing physical flow, select this variant's synthesis directory:

```bash
cd /home/ec2-user/CadenceASICImplementation
export ECG_ASIC_SCOPE=adaptive_core
export ECG_ASIC_SYNTH_DIR=/home/ec2-user/CadenceASIC100kHz/runs/synth_XXXXXX
bash run_import.sh
```

The backend import/CTS checks recognize the explicit native clock profile.
Old area, routing, timing and power figures do not apply to the new netlist;
fresh implementation and activity analysis are required before claiming PPA.

## Matched routed-power comparison

`run_power_pair.sh` launches two complete full-core implementations: adaptive
500 Hz processing with idle gates, and fixed 100 kHz processing without idle
gates. Both have the same 100 kHz source and 120 Hz synthetic normal input.
Each actual routed netlist is simulated for 10 s warm-up and 60 s measurement;
native TCF activity avoids the large VCD files used by earlier experiments.

The runner requires the sibling `CadenceASICImplementation/` backend and the
installed AWS Cadence tools/PDK. Failed stages stop and retain their evidence;
the executed pair used explicit resume scripts for diagnosed routing/export
issues. A script launch alone is not a successful result.

```bash
cd /home/ec2-user/CadenceASIC100kHz
bash run_power_pair.sh
# After both cases pass, using the exact reported pair directory:
python3 audit_pair.py compare runs/power_pair_XXXXXX
bash collect_pair_evidence.sh runs/power_pair_XXXXXX
```

Acceptance checks include full sample acceptance, matching classification
IDs/decisions and measured spans, exact clock counts, complete routed-net
activity/RC coverage, clean routed timing/electrical checks, and the selected
external DRC/LVS checks. The comparison changes frequency and gating together;
it is not a gating-only experiment. Functional gate activity has no SDF and
therefore does not estimate delay-dependent glitches. See
[the reporting summary](../Documents/native_100khz_power_pair_report.md).
