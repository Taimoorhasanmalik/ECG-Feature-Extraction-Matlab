# Final RTL Summary: Power-Aware Two-Stage ECG Classifier

Document date: 2026-10-09. Recorded implementation evidence: 2026-10-08.

This document describes the final selected RTL architecture as a standalone design. It defines the configuration, data flow, arithmetic, scheduling, activation policy, clocking, interfaces, FPGA results, and verification boundaries. It describes what the RTL implements; it does not imply completed clinical validation or measured FPGA power savings.

## 1. Design objective and operating principle

The system processes a single ECG channel sampled at 120 samples/s. Stage 1 continuously evaluates normal-versus-abnormal activity. Stage 2 performs VT-versus-VF-family classification only for windows started while its sequence-controlled enable is active.

The design reduces duplicated hardware by sharing the window sequencer, circular-history addressing, replay feature datapath, scheduler, and classifier multiply-accumulate engine. Separate causal filters and streaming-statistics state are retained because the two models require different filtered signals.

The entire processing pipeline runs at 500 Hz while Stage 2 is asleep and at 100 kHz while Stage 2 is armed or has work to finish. Stage 1 uses the same processing clock as Stage 2; there are not two independently frequency-switched stage clocks. Selective clock gating additionally stops the Stage 2 statistics clock and the shared classifier clock when their work is absent.

When Stage 1 enables Stage 2, both stages start their newly aligned windows on the next raw sample accepted by the processing core. Started Stage 2 windows are always completed and reported, even if Stage 1 subsequently disarms new Stage 2 starts.

## 2. Selected configuration and project

The canonical implementation is `final_two_stage_design/hardware/`.

| Item | Final selection |
| --- | --- |
| FPGA board/device | Basys 3, Artix-7 `xc7a35tcpg236-1` |
| FPGA tool used for recorded results | Vivado 2020.2 |
| Saved Vivado project | `final_two_stage_design/hardware/vivado_adaptive_project/two_stage_adaptive.xpr` |
| Board top | `basys3_two_stage_adaptive_top` |
| Acquisition/processing integration top | `two_stage_adaptive_clock_top` |
| Processing core | `two_stage_shared_replay_top` |
| Source clock | 100 MHz |
| Input sample rate | 120 samples/s |
| Processing clock, Stage 2 asleep | 500 Hz |
| Processing clock, Stage 2 armed/draining | 100 kHz |
| Window length | 240 accepted samples, nominally 2 s |
| Window stride | 120 accepted samples, nominally 1 s |
| Overlap | 50%, two accumulator banks per stage |
| Logical history | 240 words x 32 bits |
| Stage 1 replay | One sample every two processing cycles |
| Stage 2 replay | One sample every processing cycle |
| Sequence enable | At least two abnormal votes among three completed Stage 1 windows |
| Disarm | Two consecutive normal sequence decisions |
| Disarm handling | Stop new Stage 2 starts; finish and report started windows |

The selected parameter values are:

```text
SOURCE_HZ        = 100000000
ADAPTIVE_CLOCK   = 1
CLOCK_GATING     = 1
STAGE1_FULL_RATE = 0
SHARED_HP1_MODEL = 1
DEEP_HISTORY    = 0
```

The integration wrapper fixes the last two values when instantiating the processing core. Do not instantiate the core with its unqualified parameter defaults and assume that it selects this configuration. `SHARED_HP1_MODEL=1` selects the six-feature Stage 2 model and shared MAC; it does not mean that Stage 1 and Stage 2 use one identical filter.

The packaged source snapshot is `final_two_stage_240_power_design/`. The canonical adaptive project and routed evidence are in the hardware directory above.

The editable architecture is in `publication_figures/2 Stage Power Aware Design.drawio (1).drawio`, on the page named **Implemented adaptive RTL**. Use that page as the diagram corresponding to this document.

## 3. End-to-end data flow

```text
100 MHz source-domain acquisition, 120 samples/s
                      |
              one-entry sample mailbox
                      |
       common Q16.16-to-Q3.8 input quantization
                      |
             +--------+--------+
             |                 |
        5 Hz high-pass     1 Hz high-pass
          Stage 1           Stage 2
             |                 |
       alignment registers / common sample boundaries
             |                 |
       Stage 1 statistics  Stage 2 gated statistics
             |                 |
             +---- 240 x 32 history ----+
                       |
             selected-lane replay engine
                       |
               shared classifier MAC
                       |
             +---------+---------+
             |                   |
      Stage 1 base vote     Stage 2 VT/VF result
             |
       rolling 2-of-3 gate
             |
     arm/restart, disarm/drain, processing speed request
```

Streaming collection continues while the scheduler replays completed windows. The two filter paths are concurrent. Replay and classifier scoring are time-multiplexed; they do not execute two complete stage jobs in parallel.

## 4. Acquisition interface and sample transfer

The reusable integration top accepts:

- `source_clk`: the 100 MHz clock.
- `resetn`: active-low reset.
- `sample_q16_16[31:0]`: signed input, interpreted as the integer value divided by 65536.
- `sample_valid`: a source-clock sample strobe.

It returns `sample_ready` and sticky `input_overflow`. The source must wait for startup readiness and present new samples only when the mailbox is ready. The intended contract is periodic 120 Hz acquisition, not arbitrary high-rate bursts.

`ecg_sample_mailbox` contains one held 32-bit sample and a request/acknowledge toggle handshake. Request and acknowledgement each cross through two synchronizer flip-flops. The source holds the bundled sample data stable until the acknowledgement returns. The processing side captures the data and emits one delivered-valid pulse for each accepted request. Source-side reset release uses a two-flip-flop initialization chain.

The mailbox preserves input samples during clock-frequency changes under the specified sample-arrival contract. There is no deliberate switching-time sample drop. A strobe received while the mailbox is busy sets overflow; the design is not a multi-entry FIFO and does not promise recovery of that rejected sample.

At 500 Hz, delivery and subsequent core acceptance incur several milliseconds of synchronization/pipeline latency. Consequently, the phrase "next sample after enable" means the next raw sample accepted by the processing core after its arm decision. A sample may have been acquired earlier in the source domain and still qualify if it has not yet been accepted by the core. The interface does not export an acquisition timestamp.

ADC control, analogue conditioning, nonfinite-value handling, upstream resampling, and host communications are outside the implemented core. Changing the input rate to 250 Hz is not a runtime option of this final configuration: the filter coefficients, windows, models, and timing assumptions are for 120 Hz.

## 5. Input quantization and independent causal filters

Both filters receive the same common input quantization:

```text
q8 = clamp(truncate_toward_zero(sample_q16_16 / 256), -2048, 2047)
physical input represented by q8 = q8 / 256
```

This is a signed 12-bit Q3.8 input. Fractional reduction truncates toward zero for both signs rather than rounding negative values downward.

### 5.1 Stage 1 preprocessing

`ecg_pthighpass_iir` implements a causal third-order Butterworth high-pass with a 5 Hz corner at 120 Hz sampling. It uses 32-bit coefficients with 20 fractional bits, 64-bit feedback state with 28 fractional bits, and 96-bit product/sum wires. Output conversion truncates toward zero and saturates to signed 12-bit Q3.8.

For the recurrence

```text
y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + b3*x[n-3]
     + na1*y[n-1] + na2*y[n-2] + na3*y[n-3]
```

the coefficient integers, each scaled by `2^20`, are:

| Coefficient | Stored 32-bit hexadecimal integer |
| --- | --- |
| B0 | `000C4E29` |
| B1 | `FFDB1585` |
| B2 | `0024EA7B` |
| B3 | `FFF3B1D7` |
| NA1 | `0027A52B` |
| NA2 | `FFDEAA9C` |
| NA3 | `000976B8` |

The feedback coefficients include the recurrence sign. Each feedback product is arithmetically shifted by 20 before summation into the wide-state update. Preserve these operation boundaries when reproducing bit-exact arithmetic.

### 5.2 Stage 2 preprocessing

`stage2_shared_hp1_q29` implements a separate causal third-order Butterworth high-pass with a 1 Hz corner at 120 Hz sampling. Coefficients are signed 32-bit integers with 29 fractional bits. Input and feedback histories are signed 40-bit values with 29 fractional bits; the sum/product path is 80 bits. Output is signed 14-bit Q5.8, saturated to integer bounds -8192 through 8191.

| Coefficient | Stored integer, scaled by `2^29` |
| --- | ---: |
| B0 | 509480620 |
| B1 | -1528441861 |
| B2 | 1528441861 |
| B3 | -509480620 |
| A1 | -1554398152 |
| A2 | 1501088162 |
| A3 | -483487738 |

The recurrence subtracts `A1*y[n-1] + A2*y[n-2] + A3*y[n-3]`. The wide sum is truncated toward zero by 29 fractional bits to update state, then by 21 fractional bits to produce the Q8 output. The 40-bit state update uses the resulting low 40 bits; it is not an independently saturated state update.

Both filters update for every accepted input sample, including while Stage 2 classification is disabled. Keeping Stage 2's causal IIR history warm avoids restarting its filter at an episode boundary. Window restart does not reset either filter.

Pipeline alignment registers ensure that the Stage 1 history lane and Stage 2 history lane represent the same raw sample index. An alignment failure raises an overflow indication.

## 6. Shared window sequencer and trigger alignment

One `feature_set` instance controls both stages with `WINDOW_SAMPLES=240` and `STEP_SAMPLES=120`. It advances only on valid samples, not on every processing-clock edge. It generates start, finish, active, and bank-enable masks for two alternating overlap banks.

The first and final samples of each window are included. Two banks allow adjacent 240-sample windows to overlap by 120 samples without retaining a second independent window history. The banks hold statistics and timing state, not two complete copies of the ECG samples.

For an aligned start index `k`, successive spans are:

```text
Window A: samples k       through k + 239
Window B: samples k + 120 through k + 359
Window C: samples k + 240 through k + 479
```

On a new Stage 2 arm, the controller records the next eligible raw-sample boundary. The restart is applied when that sample emerges through the filter pipeline, ensuring that neither an already-filtered earlier sample nor the triggering window is substituted for the intended start.

The common sequencer restarts both stages on this boundary. Partial Stage 1 windows are discarded, and the Stage 1 vote history is cleared because windows straddling a rephase are not a consecutive three-window sequence. Stage 1 then needs three newly completed windows before emitting another sequence decision. Stage 2 starts its first window immediately at the aligned boundary; it does not wait for those three Stage 1 decisions.

Sample indexing remains continuous across rephases. An internal per-job start index supports exact sample-span verification. Public result IDs are zero-based completed-window IDs, not raw starting-sample indices, and are not reset on rephase. Both stages can report the same completed-window ID when they classified the same aligned span.

## 7. Shared 240-word circular history

The selected core implements:

```text
window_history[0:239] : 32 bits per address
bits 15:0            : sign-extended 12-bit Stage 1 filtered sample
bits 31:16           : sign-extended 14-bit Stage 2 filtered sample
```

This is 7680 logical data bits, or 960 bytes. Although the useful filtered values occupy 26 bits, the RTL uses two 16-bit lanes so the two writes can be enabled independently. Address 239 wraps explicitly to address 0.

The lanes share write and replay addressing. Stage 1's lane writes on every aligned valid sample. Stage 2's lane writes only when a started Stage 2 window is collecting. When no such window exists, that lane retains its contents and stops writing; it is not erased or power-switched off.

The independently write-enabled lanes map to two `RAMB18E1` primitives in the recorded implementation, equivalent to one 36-Kbit BRAM tile of capacity. One logical shared history does not mean one physical RAMB18 primitive. The implementation has neither a 512-word history nor two separately sequenced 240-word buffers.

Replay begins at the saved start pointer of the completed window and reads samples chronologically using the common synchronous RAM read path. Metadata stores window ID, bank, starting sample index, and starting address; it does not copy window data into a second queue.

The ring is deliberately shallow. Correct operation requires reading each sample before its address is overwritten by future acquisition. The whole replay does not have to finish before the next sample arrives: it must stay ahead of the overwrite frontier, starting with the oldest word. Periodic sample spacing and bounded scheduler latency are therefore part of the architecture, not optional interface details.

## 8. Streaming statistics and snapshots

Each stage has two `shared_stream_stats_bank` instances corresponding to its overlapping windows. These states remain separate because the 5 Hz and 1 Hz filters produce different values.

The banks accumulate:

- Signed sample sum for the integer window mean.
- Minimum and maximum samples, tracked directly without sorting or a sample-array scan.
- Line length: sum of absolute adjacent differences.
- Derivative-sign changes for Stage 1, ignoring zero differences.

The first sample initializes the bank. The final sample is included before sum/min/max/difference/count snapshots are captured. Stage 2 does not use the streaming derivative-sign snapshot; it obtains that feature during its selected replay.

Keeping these streaming quantities available avoids extra replay passes for mean, extrema, and line length. It also avoids RMS computation and a general order-statistics engine in the selected feature set. Division and scaling by known constants remain in the RTL; the design should not be described as having no dividers or no multipliers.

## 9. Shared replay feature extraction

One replay datapath selects the appropriate filtered lane and its bank snapshots. The stage selection is held for the entire job. Stage 1 and Stage 2 do not alternate ownership sample-by-sample within a replay window.

Both models use centered amplitude, threshold crossings, derivative-sign changes, and line length. The shared engine computes replay-dependent quantities once for each scheduled stage window. Stage 2 additionally uses block amplitude range and block-to-block amplitude transition.

### 9.1 Arithmetic definitions

Let `N=240`, `q[i]` be the selected signed Q8 integer, and:

```text
S    = sum(q[i])
m    = truncate_toward_zero(S / 240)
u[i] = q[i] - m
A    = sum(abs(u[i]))
L    = sum(abs(q[i] - q[i-1])) for i = 1..239
P    = max(abs(min(q) - m), abs(max(q) - m))
t[i] = (P != 0) and (5 * abs(u[i]) >= P)
C    = number of changes in t[i], for i = 1..239
Z    = number of sign changes between successive nonzero differences
```

`Z` is a derivative-sign-change count, not an ordinary count of signal samples crossing zero. Zero differences do not reset the last nonzero derivative sign. For a zero-amplitude window, the threshold predicate is false throughout.

Stage 2 divides the window into eight contiguous 30-sample blocks. If `B[j]` is the sum of `abs(u[i])` in block `j`, then:

```text
M = floor(A / 240)
R = floor((max(B) - min(B)) / 30)
T = floor(sum(abs(B[j] - B[j-1]), j=1..7) / 210)
```

The RTL carries centered quantities scaled by 240 to keep integer comparisons and accumulation consistent. Its corresponding division constants are 57600, 7200, and 50400 for `M`, `R`, and `T`. These are equivalent to the definitions above before the specified saturation and packing.

### 9.2 Features presented to the MAC

Features are presented as signed 32-bit values with 16 fractional bits. The exact integer packing is:

| Feature slot | Stage 1 integer presented to MAC | Stage 2 integer presented to MAC |
| --- | --- | --- |
| f0, mean absolute centered amplitude | `M << 8` | `min(M,4095) << 8` |
| f1, derivative-sign changes | `Z << 15` | `Z << 15` |
| f2, line length | `L << 7` | `min(floor(L/2),65535) << 8` |
| f3, threshold crossing count | `C << 16` | `C << 16` |
| f4, local amplitude range | 0, not scored | `min(R,4095) << 8` |
| f5, amplitude transition | 0, not scored | `min(T,1023) << 8` |

Thus the numeric count feature is `Z/2`, and the numeric line-length feature is `L/512`, with Stage 2 line length additionally quantized to a Q8 step and saturated. Mean absolute amplitude, range, and transition are represented in Q8 amplitude units before conversion to the MAC input format.

Stage 1 uses the bounded slices implemented in RTL: `M[11:0]`, `Z[7:0]`, `L[20:0]`, and `C[7:0]`. The table describes their in-range values; the RTL bit slicing is authoritative for exact reproduction. Stage 2 count accumulators are nine bits. Preserve truncation, saturation, packing, and feature ordering when validating or replacing model weights.

## 10. One clock-gated classifier MAC

`shared_classifier_mac_q` is the selected classifier for both stages. A request captures the stage identity, completed-window ID, and feature values. One selected feature/weight product is accumulated per classifier clock cycle.

Stage 1 processes four products. Stage 2 processes six products. The multiplier/MAC datapath is shared, not instantiated once per model. A wide multiplier can occupy multiple FPGA DSP primitives; a single logical MAC does not imply that the complete implementation uses only one DSP.

Features have 16 fractional bits; selected signed weight integers have 24 fractional bits. Products and the signed 64-bit score accumulator therefore have 40 fractional bits. Bias is initialized before accumulation. Model scaling/offsets are folded into the fixed coefficients, so a separate runtime normalization datapath is unnecessary.

| Slot | Stage 1 weight integer | Stage 2 weight integer |
| --- | ---: | ---: |
| f0 | 44266604 | -41836544 |
| f1 | -1368018 | -344064 |
| f2 | -435043 | 1150976 |
| f3 | 1618828 | 126976 |
| f4 | 0 | -11345920 |
| f5 | 0 | -4149248 |
| Bias, scaled by `2^40` | 793979191296 | 1386469130240 |

The decision boundaries deliberately differ at an exact zero score:

```text
Stage 1 base abnormal vote: score >= 0
Stage 2 VF-family decision: score > 0
Stage 2 VT decision:        score <= 0
```

Weights are compiled constants, not runtime-programmable registers. The classifier request and result use a toggle handoff between the parent processing clock and its gated derivative. `input_ready` is false while a request is pending. A duplicate request while pending sets sticky classifier overflow.

The shared MAC's `BUFGCE` is enabled while either stage has a pending score transaction. It stays open through computation and result handoff, then closes. It must still wake for Stage 1 scores when Stage 2 is asleep.

The deployed coefficient sources are `final_two_stage_design/stage1/models/pthighpass_svm_cpu_export.mat` for Stage 1 and `hw_shared_pipeline/stage2/results/stage2_shared_alldata.mat` for Stage 2. The coefficient table above identifies the actual compiled values. Independent holdout/LORO weights used for accuracy assessment are evaluation models, not dynamically selected hardware coefficient banks.

## 11. Scheduler and mux ownership

The core has one pending metadata slot for Stage 1 and one for Stage 2. A completion handoff records the corresponding snapshots and history location. The scheduler selects Stage 1 first if both are pending; otherwise it selects Stage 2.

The selected job fixes history lane, bank snapshots, model coefficients, and output identity. The lane/model mux changes when the scheduler dispatches a new stage job and transitions into that job's prefetch/replay path. It is not selected solely by the external abnormal flag and is not switched midway through a window.

The processing FSM uses:

| States | Function |
| --- | --- |
| `IDLE` | Dispatch pending Stage 1, otherwise pending Stage 2 |
| `PREFETCH_1`, `PREFETCH_2` | Start synchronous history read |
| `REPLAY_1` | Stage 1 shared feature accumulation, alternate-cycle advance |
| `SCORE_1_REQ`, `SCORE_1_WAIT` | Submit and receive shared MAC score |
| `DECIDE_1` | Update vote history and episode policy; emit sequence result |
| `REPLAY_2` | Stage 2 shared feature accumulation, every-cycle advance |
| `SEND_2`, `WAIT_2` | Submit shared MAC request and emit subtype result |

Unexpected result IDs/stage identities and overwriting an occupied pending slot raise sticky scheduler overflow. There is no deep completed-window queue, and overflow does not reconstruct stale overwritten history.

## 12. Stage 2 enabling, disarming, and drain

### 12.1 Enabling condition

Each completed Stage 1 base window contributes one vote determined by its score. After three valid base-window decisions are available, the rolling three-vote count produces:

```text
2 or 3 abnormal votes -> abnormal sequence decision
0 or 1 abnormal vote  -> normal sequence decision
```

An abnormal sequence decision clears the consecutive-normal marker. If Stage 2 was not armed, it arms Stage 2, requests the common sequencer restart, clears the old three-vote history, and requests fast processing. Subsequent abnormal sequence decisions while already armed do not repeatedly restart the windows.

The abnormal code identifies an episode trigger; Stage 2 does not retrospectively subtype the triggering Stage 1 window. Its classification uses newly collected, trigger-aligned windows.

### 12.2 Disabling condition

The first normal sequence decision records a normal marker but leaves Stage 2 armed. A second consecutive normal sequence decision disarms new Stage 2 starts. An intervening abnormal sequence decision clears the marker.

This condition is two normal **sequence decisions**, not simply two normal base-window votes and not a timer expiry. Sequence history is overlapping and decisions are produced at completed-window cadence after the vote-history warm-up.

### 12.3 Drain-before-sleep policy

Disarming does not cancel any started Stage 2 window. Each started bank continues collecting its required samples, captures its final statistics, replays, classifies, and reports its original window ID. These results are historical relative to the current arm state and must not be discarded merely because Stage 1 has returned to normal.

There is no separate public `historical` flag. Historical interpretation follows from the original window identity and the episode/disarm state maintained by the consumer. The public result is still marked `class_is_stage2=1`.

The actual fast-request condition is:

```text
stage2_armed OR restart_pending OR any_started_stage2_bank
OR stage2_ready_handoff OR stage2_pending_job
OR state in {PREFETCH_2, REPLAY_2, SEND_2, WAIT_2}
```

This preserves fast operation across collection-to-replay and replay-to-score handoffs. Only after all these conditions clear may the whole pipeline return to 500 Hz. Stage 1 continues working during Stage 2 collection, replay, scoring, and drain.

If input ends before a started window receives all 240 samples, that partial window cannot complete. Fast mode can therefore remain requested at the end of a finite trace; this is not an instruction to fabricate missing samples or cancel the window.

## 13. Adaptive divider structure and safe frequency changes

`ecg_adaptive_clock` generates one registered divided clock from the continuously running 100 MHz source. Its structure is:

```text
processing_fast_request
          |
 two source-clock synchronizer FFs
          |
 boundary-updated fast_mode register
          |
 selected half-cycle terminal count
          |
 17-bit counter -> registered clock toggle -> BUFG -> processing_clk
```

The toggle interval follows `SOURCE_HZ / (2 * desired_frequency)`:

| Mode | Source cycles per half-cycle | Counter values | Half-period | Full period |
| --- | ---: | --- | ---: | ---: |
| 500 Hz | 100000 | 0 through 99999 | 1 ms | 2 ms |
| 100 kHz | 500 | 0 through 499 | 5 us | 10 us |

The counter width is `ceil(log2(100000))=17` bits. It counts source-clock ticks, not ECG samples. At the active terminal count it resets, toggles the registered output, and adopts the synchronized requested mode for the next half-cycle.

A requested rate change therefore completes the old half-cycle rather than shortening a pulse midway through it. The selection is between terminal-count constants; there is no clock-source mux, no `BUFGMUX`, no MMCM/PLL reconfiguration, and no voltage scaling.

Slow-to-fast adoption can wait up to the remaining 1 ms slow half-cycle plus synchronization/observation latency. The next fast rising edge can follow 5 us later depending on transition phase. Acquisition remains at 120 Hz on the source clock and is not accelerated by fast processing.

Two processing-clock readiness flip-flops qualify startup. Pipeline reset is held until external reset is released and `clock_ready` is asserted. Reset initializes filter state, sequencing, scheduling, votes, and overflow state; the history array itself is not bulk-cleared.

## 14. What is clock-gated, write-gated, and always maintained

| Block | Operation while Stage 2 sleeps | Operation while armed/draining |
| --- | --- | --- |
| 100 MHz divider/acquisition domain | Running | Running |
| Common processing distribution | 500 Hz | 100 kHz |
| Stage 1 filter and statistics | Process every accepted sample | Process every accepted sample |
| Stage 2 causal filter | Process every accepted sample; retain warm state | Same |
| Common sequencer/control | Running on processing clock | Same, at fast rate |
| Stage 1 history writes | Enabled on aligned sample | Enabled on aligned sample |
| Stage 2 history writes | Disabled without started Stage 2 banks | Enabled while started banks collect |
| Stage 2 streaming-statistics clock | Closed | Open while armed or any started bank collects |
| Shared replay engine | Available for Stage 1 | Scheduled between both stages |
| Shared classifier clock | Open only for pending Stage 1 scoring | Open only for pending scoring from either stage |

Stage 2 statistics use a synchronous `BUFGCE` with enable `resetn && (stage2_armed || any_started_stage2_bank)` in the selected gated configuration. Its clock may close after collection finishes even while the remaining Stage 2 replay job runs in the parent processing domain.

The entire Stage 2 path is not independently clock-gated: its filter stays warm and its replay/MAC resources are shared. RAM lane write suppression is not removal of BRAM supply power. The implementation performs clock gating and clock-frequency adaptation, not transistor-level power gating. FPGA static/leakage power is not directly eliminated.

## 15. Replay throughput and latency calculations

The input period is:

```text
Tsample = 1/120 = 8.333333 ms
Tstride = 120/120 = 1 s
Twindow = 240/120 = 2 s nominal window duration
```

The elapsed acquisition time between the first and last samples of a 240-sample span is `239/120 = 1.991667 s`; "2 s window" denotes its sample-count duration.

Nominal replay-only costs are:

| Work | Processing cycles | At 500 Hz | At 100 kHz |
| --- | ---: | ---: | ---: |
| Stage 1, selected alternate-cycle replay | 480 | 0.96 s | 4.8 ms |
| Stage 2, every-cycle replay | 240 | Not the selected Stage 2 operating mode | 2.4 ms |
| One Stage 1 + one Stage 2 replay | 720 | Not the selected armed operating mode | 7.2 ms |

The Stage 1 number is a nominal two-cycle-per-sample budget; exact edge count includes starting phase. Prefetch, dispatch, MAC opening/initialization, four or six product cycles, result handoff, and decision/report states add overhead.

At 500 Hz the selected Stage 1 replay advances at 250 samples/s, exceeding the 120 samples/s overwrite rate. Its 0.96 s replay leaves about 40 ms, or 20 processing cycles, before the next nominal one-second-stride completion; controller/scoring overhead consumes part of this margin. No fast burst is requested simply because a normal Stage 1 window needs replay.

At 100 kHz, Stage 1-priority replay contributes about 4.8 ms before a waiting Stage 2 job. The first Stage 2 history read and control overhead must still fit before the oldest Stage 2 sample is overwritten at the next nominal 8.33 ms acquisition. This is why scheduling, input spacing, and processing rate must be considered together. The 7.2 ms combined replay figure is not a complete worst-case latency guarantee.

A newly enabled Stage 2 result also requires its 240 newly collected samples; the approximately 1 ms clock transition does not remove that acquisition delay. Initial sequence-gate readiness requires three completed overlapping Stage 1 windows, nominally reaching the third completion near 4 s from initial collection, before its replay/scoring delay. Actual abnormal detection can take longer depending on votes.

The 500 Hz Stage 1 replay delay can be close to one second and is much larger than divider switching latency. This delay and the common-window rephase are part of the final operating policy and must be included in end-to-end detection evaluation. Operating frequency is verified at 500 Hz/100 kHz; maximum achievable frequency has not been established by a maximum-frequency implementation sweep.

## 16. Output contract and diagnostics

Results are emitted in the processing-clock domain. `class_valid` is a one-processing-cycle pulse; the remaining fields are meaningful as a transaction when it is asserted. An external host must capture them with an appropriate synchronized result interface or mailbox. There is no public result backpressure input.

| Output | Meaning |
| --- | --- |
| `class_code=0`, `class_is_stage2=0` | Stage 1 normal sequence result; Other/normal indication |
| `class_code=3`, `class_is_stage2=0` | Stage 1 abnormal sequence result |
| `class_code=1`, `class_is_stage2=1` | Stage 2 VT result |
| `class_code=2`, `class_is_stage2=1` | Stage 2 VF-family result |
| `class_window_id[31:0]` | Completed-window identifier, continuous across rephase |
| `processing_fast_request` | Episode/work request for fast mode, including drain |
| `fast_mode` | Divider's actual adopted fast-mode state |
| `clock_ready` | Processing-clock startup readiness |
| `classifier_clock_enabled` | Shared MAC clock is open for a pending transaction |
| `input_overflow` | Source strobe arrived while acquisition mailbox was busy |
| `stage1_window_overflow` | Sequencer allocation, alignment, or scheduler failure |
| `stage2_window_overflow` | Invalid Stage 2 timing/restart or scheduler failure |
| `classifier_overflow` | Classifier duplicate/pending transaction or scheduler failure |

Stage 1 does not publicly emit every base vote: sequence reports begin only when three votes are valid. Raw score and per-feature outputs are internal verification signals, not exported classifier interface ports. The class code is not a calibrated confidence or probability.

Core overflow flags are sticky after the corresponding failure. The sequencer allocation event is combined into the Stage 1 indication; board display logic also latches observed core overflow events. Production integration must treat any overflow as invalidating an assumed uninterrupted processing contract and define recovery/reset behavior.

## 17. Basys 3 demonstration wrapper

The board wrapper supplies a synthetic 1200-sample signed Q3.8 waveform through `ecg_bram_demo_source`, converted exactly to the Q16.16 acquisition interface. Its cadence remains on the 100 MHz source clock.

`sw[15]` releases reset. `sw[14]` selects/enables automatic demonstration playback. In manual mode, `sw[11:0]` supplies a held signed sample and `btnC` generates a synchronized sample event. Buttons are not debounced and switch sampling is only a bring-up aid, not a production ADC interface. The demo must also respect the mailbox timing contract.

| LED | Meaning |
| --- | --- |
| 0 | Latest class code is 0 |
| 1 | Latest class code is VT/1 |
| 2 | Latest class code is VF-family/2 |
| 3 | At least one result has been seen |
| 4 | Shared classifier clock enabled |
| 5 | Core overflow observed or mailbox overflow |
| 6 | Mailbox input ready |
| 7 | Current `class_valid` pulse |
| 8 | Bit 0 of completed-window ID |
| 9 | Processing clock ready |
| 10 | Qualified processing reset released |
| 11 | Synchronized demonstration mode |
| 12 | Demonstration playback finished |
| 13 | Latest result came from Stage 2 |
| 14 | Fast-processing request |
| 15 | Actual fast mode |

LEDs are indicators, not a timed off-chip result bus. A code-3 Stage 1 report is identified by result fields; there is no dedicated code-3 LED in this wrapper.

## 18. FPGA resource utilization and timing

The recorded routed implementation is the complete adaptive board wrapper, not a core-only area estimate. It includes acquisition, synchronization, divider, demonstration-source integration, and display logic. Values below come from `final_two_stage_design/hardware/adaptive_clock_test/mode1_resources.rpt` and associated routed/timing reports.

| Resource | Used | Device availability | Utilization |
| --- | ---: | ---: | ---: |
| Slice LUTs | 5172 | 20800 | 24.87% |
| Flip-flops | 2404 | 41600 | 5.78% |
| DSP48E1 | 48 | 90 | 53.33% |
| RAMB18E1 | 2 | 100 | 2.00% |
| Global clock resources | 4 | 32 | 12.50% |
| MMCM | 0 | 5 | 0% |
| PLL | 0 | 5 | 0% |

The isolated adaptive divider/controller occupies 29 LUTs and 23 flip-flops. A matched fixed divider/controller comparison attributes an incremental cost of 15 LUTs and 8 flip-flops to frequency adaptation, with no additional global clock resource. This is an observed implemented cost, not a universal device-independent estimate. Whole-design LUT differences are not used as proof that clock selection itself saves logic.

Recorded timing results:

- Overall worst setup slack: +3.536 ns.
- Overall worst hold slack: +0.037 ns.
- Fast processing-domain setup slack: +9937.240 ns.
- Zero unclocked registers and zero unconstrained internal timing endpoints.

Overall slack includes the 100 MHz source and inter-domain paths; it is not the same as processing-domain slack. These results establish satisfaction of the stated constraints, not a signed-off maximum processing frequency or completed board validation.

## 19. Timing constraints, reset, and CDC boundaries

`constraints/two_stage_adaptive_basys3.xdc` defines the 100 MHz source clock and both generated processing clocks at the same physical output: divide-by-1000 for 100 kHz and divide-by-200000 for 500 Hz. The two generated modes are physically exclusive. The source clock remains timed rather than being globally declared asynchronous to processing.

Only first stages of specified request/acknowledge and board-control synchronizers are exempted from ordinary setup analysis. Held mailbox data to captured processing data is constrained with a 5000 ns datapath-only maximum delay, half the fastest processing period. Handshake stability supplies the functional capture contract. The slow period may print as 2000000.125 ns because of Vivado representation; counter division is exact.

The XDC also includes board pin assignments and demonstration-specific exceptions for manually held switches, reset, and untimed LED outputs. These exceptions are not an ADC-interface sign-off template.

Routed DRC has no errors or critical warnings, but DSP-pipelining and asynchronous RAM-control warnings remain. CDC is not fully signed off: reports flag external reset distribution, manually held switch data, reset-controlled gated-clock paths, and multi-clock synchronizer fan-in caused by the two exclusive timing modes. No blanket CDC waivers were added.

Production ADC integration, reset release and BRAM reset-time behavior, gated-clock control review, and reliable host-result transfer still require engineering review and board tests. Positive timing slack alone does not close these items.

## 20. Functional verification completed

The integer Python references are the exact arithmetic targets for RTL comparison. ModelSim verifies filter values, selected features, scores, classes, sample spans, alignment, episode transitions, and diagnostics.

The divider unit test uses the actual 100 MHz source. It checked eight complete slow half-cycles and 27 complete fast half-cycles with no runt or improperly extended transition pulses.

Integrated tests use a 200 kHz source for simulation speed while retaining the actual 500 Hz and 100 kHz processing periods and 120 Hz input cadence. The real-source divider test and Vivado implementation separately cover the 100 MHz source logic. These are simulation/build results, not physical FPGA measurements.

| Stimulus | Samples | Stage 1 scores checked | Stage 2 scores checked | Arms | Returns to slow mode |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed, first source/input phase | 1200 | 7 | 4 | 1 | 0 |
| Mixed, offset source/input phase | 1200 | 7 | 4 | 1 | 0 |
| Stress waveform with normal sequence decisions | 1200 | 9 | 0 | 0 | 0 |
| Reactivation, selected alternate-cycle Stage 1 replay | 3600 | 25 | 15 | 2 | 1 |

All transmitted samples were accepted and filtered exactly once in these cases. Checked features, scores, and classes matched the integer references for their sample spans. No mailbox, window, or classifier overflow was detected. Reactivation produced two historical Stage 2 results after disarming, checked drain-to-slow behavior, and exercised a later wake-up.

An additional full-rate Stage 1 replay option was tested with an offset input phase, but it is not the selected configuration. The worst observed arm-to-mode latency was 1002500 ns in the slower-source integrated simulation, including observation delay.

The saved adaptive Vivado project's source/constraint configuration passed project-context synthesis. A matching board-level build completed placement and routing. No bitstream programming or physical power measurement is claimed by these results.

## 21. Model accuracy evidence and its limits

Stage 1 hardware arithmetic was compared with its saved floating-point model on test records: 11 base-decision changes were observed among 33169 windows. This small arithmetic drift must be acknowledged when reporting model equivalence.

Stage 2 hardware-fixed filtering and feature extraction were evaluated over 5541 windows from 38 records. With each record's independent leave-one-record-out weights, window-level accuracy was 0.858148, approximately 85.81%. The deployed all-data model had zero prediction changes against its fixed-point export over those windows.

An independent four-record holdout model yielded 0.960784 accuracy over 204 windows with zero decision changes against its exported decisions when using hardware-fixed arithmetic. Eight windows differed in line length by one Q8 quantization step. The deployed hardware weights are the all-data weights, not those independent holdout weights, so 96.08% must not be presented as independent test accuracy of the deployed classifier.

These results support arithmetic/model validation at the window level. They do not establish end-to-end clinical accuracy, sensitivity, false-alarm rate, or time-to-detection of the final adaptive trigger-aligned policy. Slow Stage 1 replay changes decision time and therefore the newly aligned sample spans. The complete adaptive policy, including rephase and vote-history reset, still needs held-out, continuous-record evaluation.

## 22. Area, switching activity, and power interpretation

The area strategy is to retain independent state only where required and share expensive completed-window operations. Its main mechanisms are common sequencing/addressing, one logical history, shared replay arithmetic, a shared sequential MAC, streaming sum/extrema/line-length snapshots, and fixed-point model arithmetic. Shared feature hardware does not imply reuse of the same numeric feature values: each stage still evaluates the values belonging to its own filtered lane and selected sample span.

The activity strategy is complementary:

1. Do not collect or write Stage 2 windows unless started while armed.
2. Close Stage 2 statistics distribution outside armed/collecting periods.
3. Close the shared classifier clock whenever neither stage has a pending score.
4. Run the common processing domain at 500 Hz outside Stage 2 episodes.
5. Retain 100 kHz until all Stage 2 work drains, protecting shallow-history replay timing.

Reducing the processing clock from 100000 Hz to 500 Hz reduces its edge rate by a factor of 200, or 99.5%, during sleep. This is not a 99.5% reduction in whole-FPGA power. The 100 MHz source/divider/acquisition still run, per-sample arithmetic still occurs, and static/leakage power remains.

If `d` is the fraction of time spent in fast mode, including drain, the ideal time-weighted processing edge rate is:

```text
f_average = (1-d)*500 + d*100000 Hz
edge-rate reduction relative to continuous 100 kHz = 0.995*(1-d)
```

This estimates processing-clock activity only. Dynamic power depends on switched capacitance, voltage, internal activity, clock distribution, and source-domain cost. No adaptive on-chip watt figure or measured saving percentage is currently established. Do not attach fixed-clock activity reports to this architecture as if they measured adaptive operation.

### 22.1 Required final power experiment

Use matched builds and identical ECG samples/time spans to separate the effects of clock gating and adaptive frequency. Hold model weights, acquisition rate, window policy, and RAM write policy constant for the clock-gating ablation. For adaptive-versus-continuously-fast processing, account for the changed decision/trigger timing rather than assuming identical classified spans.

Generate post-route activity for the actual source clock, processing modes, gated clocks, RAM enables, and drain periods. Include a mostly-normal trace and an abnormal/reactivation trace. Check activity annotation coverage and generated-clock recognition before using Vivado power estimates.

Report static and dynamic power separately, clock- and signal-power components, fast-mode duty, gated-clock open duty, trace duration, input acceptance, and timing/resource configuration. Preserve sufficient numeric precision and tool confidence. Where possible, corroborate estimates with paired board-rail current measurements under the same acquisition/demo conditions.

The fair power claim at present is that the RTL implements mechanisms to reduce avoidable switching; numerical whole-device savings remain to be measured.

## 23. Brief design-selection rationale

Fully duplicated replay/classifier datapaths were not selected because they replicate operations that can meet the workload through scheduling. Separate independently sequenced window stores and oversized history were not selected because common boundaries and timely replay permit a 240-word logical ring. Whole-path filter shutdown was not selected because restarting a causal IIR would change its state and transient behavior. A permanently fast processing clock was not selected because normal monitoring does not require that edge rate throughout idle intervals.

The selected design combines hardware sharing with independent model-appropriate filter state, sequence-qualified Stage 2 activation, drain-safe gating, and one boundary-switched processing clock. Selection reflects the intended area/activity/latency trade-off; it does not imply that every alternative was conclusively worse in measured power or accuracy.

## 24. Source map and reproduction

Paths below are relative to `final_two_stage_design/hardware/` unless stated otherwise.

| File | Responsibility |
| --- | --- |
| `rtl/basys3_two_stage_adaptive_top.v` | Board demo, acquisition selection, result/LED display |
| `rtl/two_stage_adaptive_clock_top.v` | Divider/mailbox/core integration and selected core parameters |
| `rtl/ecg_adaptive_clock.v` | Boundary-switched divider, BUFG, startup readiness |
| `rtl/ecg_sample_mailbox.v` | One-entry source-to-processing sample handshake |
| `rtl/two_stage_shared_replay_top.v` | Core FSM, RAM lanes, scheduling, features, sequence policy, drain; includes `shared_stream_stats_bank` |
| `rtl/shared_classifier_mac_q.v` | Gated, time-multiplexed classifier with both coefficient sets |
| `rtl/stage2_shared_hp1_q29.v` | Warm causal 1 Hz Stage 2 filter |
| `stage1_hdl/01_highpass_iir_filter.v` | Causal 5 Hz Stage 1 filter |
| `stage1_hdl/02_window_sequencer.v` | Common 240/120 overlap sequencer and rephase |
| `stage1_hdl/14_ecg_bram_demo_source.v` | Source-clock synthetic input playback |
| `constraints/two_stage_adaptive_basys3.xdc` | Source/generated clocks, pin map, specific crossing/demo constraints |
| `tb/adaptive_clock_tb.sv` | Actual-source divider transition test |
| `tb/two_stage_shared_reference_tb.sv` | Integrated sample-span/reference/episode tests |
| `reference/fixed_stage1.py` | Integer Stage 1 arithmetic reference |
| `reference/fixed_shared_hp1.py` | Integer Stage 2/shared-path vectors and arithmetic reference |
| `reference/validate_fixed_stage1.py` | Stage 1 saved-model record comparison |
| `reference/validate_shared_hp1_holdout.py` | Stage 2 independent record-level arithmetic/model checks |
| `scripts/run_adaptive_tests.ps1` | Reproducible adaptive RTL test suite |
| `scripts/create_adaptive_vivado_project.tcl` | Create/open adaptive project; optional synthesis verification |
| `scripts/implement_adaptive_comparison.tcl` | Matched routed implementation and resource/timing/CDC reports |
| `adaptive_clock_test/mode1_*.rpt` | Recorded final adaptive build evidence |

Files retained elsewhere in the package are not automatically part of the selected synthesized architecture. The elaborated adaptive top and its parameters identify the active paths.

From the repository root, run the narrow RTL suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\final_two_stage_design\hardware\scripts\run_adaptive_tests.ps1
```

Create/open and optionally verify the adaptive project:

```powershell
& 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat' -mode batch -source final_two_stage_design/hardware/scripts/create_adaptive_vivado_project.tcl -nojournal -nolog
& 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat' -mode batch -source final_two_stage_design/hardware/scripts/create_adaptive_vivado_project.tcl -tclargs verify
```

The paired implementation script accepts mode `1` for the adaptive build:

```powershell
& 'C:\Xilinx\Vivado\2020.2\bin\vivado.bat' -mode batch -source final_two_stage_design/hardware/scripts/implement_adaptive_comparison.tcl -tclargs 1
```

Read-only model checks, using the existing model artifacts and databases:

```powershell
python final_two_stage_design/hardware/reference/validate_fixed_stage1.py
python final_two_stage_design/hardware/reference/validate_shared_hp1_holdout.py
python final_two_stage_design/hardware/reference/validate_shared_hp1_holdout.py --all-records
```

ModelSim and Python dependencies must be available for simulation. Record checks require the existing PhysioNet data and model exports; no new database copies are needed. Vivado build/simulation scripts create their normal run outputs, so run them in an appropriate writable environment.

## 25. Final implementation status

The selected adaptive RTL is implemented, its saved Vivado project is available, reference-based simulations pass for the tested cases, and a matching board-level implementation is placed/routed with positive timing slack.

The final architecture is: **120 Hz acquisition; separate warm 5 Hz/1 Hz filters; one common 240/120 sequencer; one 240 x 32 two-lane history; independent streaming statistics; shared replay and classifier MAC; 2-of-3 Stage 2 enable; two-normal-sequence disarm with finish-and-report drain; 500 Hz idle and 100 kHz episode/drain processing; selective BUFGCE and RAM write gating.**

Remaining validation is explicitly bounded: production reset/CDC/ADC/host integration, on-board functional verification, adaptive activity-based/rail-current power measurement, and continuous held-out evaluation of the complete timing-aware detection policy. These do not change the described architecture, but they are required before asserting production sign-off, measured energy savings, or final clinical performance.
