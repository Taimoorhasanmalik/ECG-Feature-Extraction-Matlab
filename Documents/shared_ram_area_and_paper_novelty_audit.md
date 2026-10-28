# Shared RAM, ASIC area and paper contribution audit

Date: 2026-10-15.

This audit examines the saved RTL, the existing AWS Genus netlist and reports,
the current paper draft, and selected primary prior art. No RTL, model weights,
paper LaTeX or server design files were changed. No new synthesis was run.

## 1. Resolution of the buffer-size confusion

Several different comparisons had been described as "shared RAM savings."
They must be kept separate.

| Comparison | Before | After | What follows |
| --- | --- | --- | --- |
| User's proposed single-store comparison | 512 x 16 = 8192 declared bits | 240 x 32 = 7680 declared bits | 6.25% fewer declared bits; ASIC area unknown |
| Packing two equal-depth stores | 240 x 16 + 240 x 16 = 7680 declared bits | 240 x 32 = 7680 declared bits | No payload-capacity saving from packing alone |
| Recorded deep-history experiment | 512 x 32 = 16384 declared bits | 240 x 32 = 7680 declared bits | 53.125% fewer declared bits, with unchanged useful width |
| Earlier parallel RTL, overlapping banks | 2 x 240 x 12 + 2 x 240 x 14 = 12480 useful bits | 240 x (12 + 14) = 6240 useful bits | 50% less sample-payload storage capacity |

The last row is the significant additional finding. The earlier parallel
two-stage implementation has FOUR sample memories, not just one 240-sample
memory per stage. Each stage has two overlapping-window banks, and each bank
owns its own full sample array. The final design retains two statistics banks
per stage but eliminates the bank-local sample copies.

The final Verilog declares 7680 bits because it pads the 12-bit and 14-bit
signals into independent 16-bit write lanes. The extra six bits per word are
sign extensions. The inspected ASIC netlist retains 26 useful bits per word.
Comparing old unpadded declarations with the new padded declaration would give
38.4615%, rather than the useful-payload reduction of 50%. State which quantity
is being compared; do not mix these widths in one percentage.

### Source evidence

- Earlier top: [two_stage_ecg_top.v](../final_two_stage_design/hardware/rtl/two_stage_ecg_top.v)
  instantiates both independent stage paths.
- [stage1_fixed_path.v](../final_two_stage_design/hardware/rtl/stage1_fixed_path.v),
  line 80, generates two `stage1_fixed_feature_bank` instances. Each instantiates
  `feature_mean_abs_fix_mean_bank` with width 12 and length 240.
- [05_mean_abs_threshold_bank.v](../final_two_stage_design/hardware/stage1_hdl/05_mean_abs_threshold_bank.v),
  line 43, declares a complete `sample_mem` for each such bank.
- [stage2_features_q.v](../final_two_stage_design/hardware/rtl/stage2_features_q.v),
  line 19, declares a 240 x 14 sample memory; line 175 generates two banks.
- [FinalRTL core](../FinalRTL/rtl/two_stage_shared_replay_top.v), lines 27 and 112,
  selects depth 240 or 512 but keeps the declared word width at 32 in both modes.
- [Recorded depth-comparison script](../final_two_stage_design/hardware/scripts/report_clock_buffer_tradeoff.tcl)
  selects `SHARED_HP1_MODEL=1` for both cases and toggles `DEEP_HISTORY`.
- [Existing depth-comparison report](two_stage_clock_buffer_area_power_tradeoff.md)
  explicitly records 512 x 32 versus 240 x 32, with identical model coefficients.

No 512 x 16 two-stage logical-history declaration was found in the searched
repository Verilog/SystemVerilog and text documentation. It remains a valid
hypothetical comparison, but is not the identified recorded deep-history
baseline. If 512 x 16 refers to EACH of two stage stores, the total is instead
16384 declared bits. If it refers to one raw-sample store, it also changes the
filter/replay organization and cannot be treated as an equivalent replacement
for two continuously filtered histories without further analysis.

The older parallel RTL also uses different Stage 2 filtering, feature rules,
classifier organization and activation policy. Its storage declarations prove
the structural bank duplication; a whole-design comparison against it would
not isolate memory sharing or guarantee identical classifications.

## 2. What the existing ASIC implementation actually contains

Read-only AWS audit of:

```text
/home/ec2-user/CadencePowerAnalysis/power_adaptive_normal_validated_4UoJO0/mapped.v
SHA256: e6a9744448b10e85dcfb139cfbf998e3a80ace7c35549d05eb65d7a8b82c79ba
```

All 6240 flip-flop instances named `window_history_reg[...]` are `SDFFQX1`.
The loaded `slow_vdd1v0_basicCells.lib` gives this cell area as 7.524 um^2.
Its name contains "SDFF"; that does not establish that the design has a
manufacturing scan chain. This audit only counts mapped storage cells.

```text
Current history storage-cell area = 6240 x 7.524
                                  = 46949.760 um^2
                                  = 0.046949760 mm^2
Full core mapped cell area        = 112280.994 um^2
History storage-cell share        = 41.8145%
```

This is a verified subset of the synthesis cell area. It excludes the memory's
read-selection network, address decoding, control and clock-distribution cost.
It is not a routed RAM macro area or floorplan area. The FPGA BRAM primitive
count does not describe the standard-cell ASIC mapping.

Under an explicitly hypothetical assumption that all versions use the same
one-bit storage cell:

| Organization | Useful bits | Storage-cell area at 7.524 um^2/bit | Status |
| --- | ---: | ---: | --- |
| Current 240-word history | 6240 | 46949.760 um^2 | Verified cells in mapped netlist |
| Four earlier bank-local arrays | 12480 | 93899.520 um^2 | Same-cell estimate, not synthesized baseline |
| 512-word dual-lane history | 13312 | 100159.488 um^2 | Same-cell estimate, not synthesized baseline |

Thus the same-cell estimates of avoided storage are 0.046949760 mm^2 versus
four bank-local arrays and 0.053209728 mm^2 versus the 512-word dual-lane history.
Neither is a measured total ASIC area reduction. Mapping can select different
cells; enable/read logic and timing constraints can change; an SRAM macro
would have a different cost model.

The 0.0532 mm^2 estimate from the conversation must never be attached to the
512 x 16 versus 240 x 32 comparison.

Reproduce the measured count and library value on AWS:

```bash
netlist=/home/ec2-user/CadencePowerAnalysis/power_adaptive_normal_validated_4UoJO0/mapped.v
lib=/opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/timing/slow_vdd1v0_basicCells.lib
sha256sum "$netlist"
grep -E 'DFF.*window_history' "$netlist" |
    awk '{count[$1]++} END {for (cell in count) print cell, count[cell]}'
grep -m1 -A1 'cell (SDFFQX1)' "$lib"
```

The existing FPGA experiment found TWO RAMB18E1 blocks in BOTH the 512- and
240-entry cases. It did not demonstrate physical FPGA RAM-area savings.

## 3. The architectural reason a 240-entry history works

Each filtered sample is written once into its lane. Overlapping windows are
represented by boundaries and statistics, not by separate copies of samples.
When a window completes, the scheduler replays its samples oldest first while
new input continues to replace old history entries.

The critical condition is a deadline on EACH read, not simply a deadline on
the end of the whole replay. For regularly spaced writes, define:

```text
N       window length (240)
D       history depth (at least N)
fs      sample rate (120 samples/s)
j       sample offset within the completed window, 0 ... N-1
tread(j) time from the last window write to the RAM read of sample j
```

The sample at offset j is overwritten after D-N+j+1 subsequent input writes:

```text
tread(j) < (D - N + j + 1) / fs       for every j
```

Use a strict inequality unless the memory's simultaneous read/write behavior
is explicitly guaranteed and verified. In the actual interface, replace this
ideal periodic deadline with the earliest accepted write time, including clock
quantization, mailbox delivery and permitted input jitter.

If reads start at latency L and advance every c processing clocks:

```text
L + j*c/fproc < (D - N + j + 1)/fs
```

When c/fproc is smaller than 1/fs, the first read is the tightest deadline in
this simple schedule. With D=N, that first read must happen before the next
sample write. At 500 Hz, alternate-cycle Stage 1 replay advances at 250
samples/s, faster than the 120 samples/s writer; its start latency and the
one-second job interval still need to fit. When both stages finish together,
Stage 2 waits for the Stage 1 job, so its oldest-sample deadline drives the
higher processing frequency.

The familiar 480 + 240 = 720 replay cycles, or 7.2 ms at 100 kHz, is a useful
conservative schedule illustration. It excludes prefetch, scoring, handoff
and arbitration. Requiring BOTH complete replays before the next sample gives
86.4 kHz before overhead, but that is a sufficient replay-only condition,
not a proven minimum clock frequency.

A 512-entry history gives the oldest word 273 sample intervals (2.275 s)
before overwrite in this model. Other constraints, including the one-slot
pending queues and one-second window stride, still apply. 512 is an implemented
depth choice, not a demonstrated mathematical minimum for slow replay.

The defensible design insight is the coupling between storage depth,
arbitration latency and processing frequency. A useful paper figure should
show the writer and reader progressing through the same ring, with the
oldest unread word as the deadline.

## 4. Contribution candidates, ranked by support

These are contributions to substantiate, not declarations that each primitive
is new to the literature.

### A. Joint design of shared storage, replay scheduling and activity control

Both stages have separate filtered data but aligned sample indices. Window
alignment permits common addressing and one replay engine; shallow history
requires bounded service latency; the clock policy provides the required
service rate while Stage 2 is active. The active clock remains requested while
collection or queued work drains.

This is a stronger architectural contribution than simply "we shared RAM."
The 50% useful-payload reduction against bank-local overlap storage can be
derived from the actual declarations. Whole-core area and energy benefits
still need controlled ablations. Existing RTL reference tests check sample
spans and scores, but are not an exhaustive proof of every overwrite deadline.

### B. Preserve stage-specific filtering while sharing compatible operations

The 5 Hz and 1 Hz filters retain their own state, while replay arithmetic and
the classifier are reused. The model search was guided by this hardware
constraint: Stage 2 uses the common feature operations plus two block-amplitude
features, instead of requiring a separate feature engine.

[The exploration report](../hw_shared_pipeline/README.md) records a concrete
reason not to merge the filters: the tested shared12/1 Hz Stage 1 candidate
reached 92.68% accuracy and 95.02% recall, versus 95.32% and 98.06% for the
deployed 5 Hz Stage 1 under the stated MATLAB protocol. This comparison changes
the filter/feature candidate together; it is not a pure cutoff-only ablation.

This supports selective hardware sharing informed by classification results.
It does not establish that all possible shared-filter models must perform worse.

### C. Exact streaming summaries allow one mean-dependent replay pass

The fill pass maintains sum and extrema. With the actual truncated mean m,

```text
max_i |q[i] - m| = max(|min(q) - m|, |max(q) - m|)
```

The peak needed by the threshold is therefore available before replay.
Centered absolute amplitude and threshold transitions can be accumulated in
the same pass. `5*abs(q[i]-m) >= peak` implements the one-fifth threshold without
per-sample division. Stage 2 also accumulates its block amplitude range and
adjacent-block transition feature during that replay.

The mathematical identity is elementary, and the Stage 1 implementation already
used it. Present it as a specific exact hardware optimization that enables
the combined architecture, not as an invented new mathematical result.

### D. Retain causal filter state while suppressing downstream idle work

The Stage 2 IIR updates on each accepted sample even while Stage 2 window
collection is disabled. This preserves the state of the continuous-filter
reference. Its history lane stops writing when no started Stage 2 window is
collecting; statistics clocks stop; the shared MAC wakes for either stage.
The controller finishes started windows before removing the fast-clock request.

This is a useful state-management contribution. It needs an activation-boundary
comparison against both an always-running reference and a filter-reset variant
to quantify the energy/first-window-error trade-off. It is selective clock and
write gating; the implementation does not switch off the Stage 2 supply.

### E. Treat false wakeups and drain time as an energy cost of sequence decisions

The gate threshold changes how often the system enters fast operation. The
cost of a false wake is more than one classifier invocation: new windows must
be collected, the reset Stage 1 vote history must refill, and started Stage 2
windows must finish.

For an ideal post-arm interval in which every new Stage 1 window is normal,
the first new three-window decision is available near 4 s and the second near
5 s. With decisions finishing before the next stride start, the last started
Stage 2 window completes near 6 s. These are analytical timing examples
relative to the first newly aligned sample, not measured minimum/maximum
episode durations; processing, input phase and further abnormal decisions
change them.

An informative new experiment would report false wakes/hour, time in fast
mode, detection delay and energy for 1-of-3, 2-of-3 and 3-of-3 policies. It
would connect the existing classification trade-off to the actual hardware
power policy, rather than assuming abnormal-window fraction equals active time.

### F. Further optimization opportunity: exact filter numerator factoring

**Proposed, not implemented or synthesized.** Both selected third-order
filters have a feedforward numerator that can be factored without changing
their rounded coefficients. Let x0 through x3 denote the current and three
delayed integer inputs, and define:

`u = x0 - 3*x1 + 3*x2 - x3`.

The Stage 1 coefficients in `FinalRTL/rtl/01_highpass_iir_filter.v` are exactly
`[806441, -2419323, 2419323, -806441]`. Thus its feedforward sum is exactly:

`F1 = 806441*u`.

The Stage 2 coefficients in `FinalRTL/rtl/stage2_shared_hp1_q29.v` are
`[509480620, -1528441861, 1528441861, -509480620]`. Their middle magnitudes
are one integer coefficient unit larger than three times the outer magnitude.
The exact identity is therefore:

`F2 = 509480620*u + (x2 - x1)`.

Dropping the residual term would change the quantized filter. Each expression
replaces four logical feedforward constant products with one, while leaving
the three feedback products unchanged. Multiplication by three in the
pre-adder can use a shift and addition. This is not evidence that the mapped
multiplier/DSP count or total area will fall by the same proportion: synthesis
may already exploit constant coefficients, and pre-adder width and timing
also matter.

For a bit-exact implementation, sign-extend before the pre-additions, retain
at least 15 bits for the Stage 1 pre-adder and 43 bits for the general 40-bit
Stage 2 pre-adder, and preserve the existing final accumulator widths and
rounding locations. In particular, do not move Stage 1's individual feedback
shifts or Stage 2's final truncation-toward-zero across the summation.

Audit validation: the coefficient identities were checked exactly, followed
by 625 combinations of minimum, maximum, -1, 0 and 1 inputs and 10,000
deterministic pseudo-random tuples per filter using arbitrary-precision integer
arithmetic. All 10,625 cases per filter passed. This checks the algebra only,
not Verilog expression sizing, sequential equivalence or implementation PPA.

Factoring symmetric filter coefficients is not a new general technique. A
useful additional contribution would be a demonstrated bit-exact reduction
for these deployed filters, including the residual correction, with unchanged
features/scores and measured ASIC area/power. It should remain future work
until the RTL and matched synthesis experiment are completed.

## 5. Prior-art check and limits on novelty claims

Primary sources inspected or retrieved through their publisher records:

- [Sohail et al., IEEE OJCAS 2026, DOI 10.1109/OJCAS.2026.3707506](https://xplorestaging.ieee.org/document/11579362):
  the publisher abstract explicitly describes an event-driven ECG linear SVM
  with a shared MAC. Therefore event-driven operation and a shared SVM MAC
  cannot independently support a first-of-kind claim here. Abstract-level
  evidence was available; the full architecture was not audited in this task.
- [Wu et al., IEEE Access 2019, DOI 10.1109/ACCESS.2019.2956179](https://ieeexplore.ieee.org/document/8915843/):
  this ECG processor exploits similarity between consecutive beats to reuse
  computation. Reuse across ECG windows/inputs is already an established
  architecture direction, although the neural-network mechanism differs.
- [US7463922B1, technical description of overlapping ECG-window storage](https://patents.google.com/patent/US7463922B1/en):
  Figures 5-7 describe duplicated window stores and a more compact arrangement
  that reuses overlapping samples. Sample overlap reuse itself is old. This
  is technical prior-art context, not a legal patent-status or freedom-to-operate
  assessment.
- [DATE 2018 ECG processor paper](https://past.date-conference.com/proceedings-archive/2018/pdf/0470.pdf):
  describes low-complexity ECG features, a small sample buffer and PVC/NVT
  classification. Avoid broad claims that previous low-power ECG hardware
  never handled ventricular rhythms or reduced feature sets.

The current draft also cites Makhlooghpour and Ahmadi's 2023 dual-stage ECG
classifier, DOI 10.1109/BioCAS58349.2023.10388691. Its full primary text could
not be retrieved in this audit, so a detailed mechanism comparison remains
open. Do not interpret the retrieval limitation as evidence that no comparable
method exists.

The targeted search supports positioning the contribution around the specific
rhythm-level cascade and its storage/scheduling/state policy. It does not prove
the draft's universal "no prior hardware" statement. Scope any novelty claim
to a documented comparison table and distinguish window-level rhythm features
from the presence or absence of QRS detection in each compared design.

## 6. Current paper statements that need correction or qualification

Paper inspected:
`E:/Thesis/ISCAS Template/Conference-LaTeX-template_10-17-19/Two_Stage_Paper_Draft.tex`.
Line references below describe the file as inspected on the audit date.

1. **The 88.3% / 90.8% gated results are not established final-RTL policy results.**
   The reported source, [test_two_stage_hw_shared.m](../hw_shared_pipeline/matlab/test_two_stage_hw_shared.m),
   explicitly defines `cold_start` and at line 143 starts the Stage 2 filter
   from zero on activation. It selects existing ground-truth window spans,
   uses a rolling MATLAB gate, and does not reproduce the final hardware's
   500 Hz scoring delay, common rephase, vote reset, two-normal disarm and
   finish-and-report drain. The final RTL keeps the filter warm. The values
   can describe the earlier software experiment, but cannot be attributed
   directly to the selected ASIC without a matched continuous-record evaluation.
   This affects the abstract/contributions, results near line 438, comparison
   table and conclusion.
2. **The selected Stage 2 implementation has no amplitude deadband on derivative
   sign changes.** The paper near line 309 says otherwise. In the RTL,
   `SHARED_HP1_MODEL=1` selects `replay_diff != 0`; the scaled deadband belongs
   to the legacy branch. State that zero differences are skipped.
3. **Stage 2 costs more than two extra features and a weight set.** The claim
   near lines 167 and 513 omits its independent IIR filter, history lane,
   statistics and control state. Say that the feature replay and MAC datapaths
   are shared while stage-specific filtering/storage/state remain.
4. **The shared MAC must open for Stage 1 work too.** The description near
   line 191 ties closure to absence of Stage 2 work. Its actual enable follows
   pending transactions from either stage; Stage 2 statistics have a separate
   enable condition.
5. **The source, processing and sampling frequencies are different.** Replace
   the claim near line 202 that Stage 1 runs at the sample rate with 120 Hz
   sample acceptance and 500 Hz/100 kHz processing, supplied by the divider
   in the full adaptive core.
6. **Do not claim negated feedback coefficients remove a pipeline stage without
   evidence.** Stage 2 explicitly subtracts feedback products. Addition versus
   subtraction notation alone establishes no eliminated register stage.
7. **Keep generalization and deployed-weight results distinct.** The saved
   [Stage 2 summary](../hw_shared_pipeline/stage2/results/stage2_shared_summary.json)
   reports LORO accuracy 85.7968%, versus deployed all-data fixed accuracy
   90.3086%. The draft labels the latter in-sample in its results section but
   the headline presentation should make the distinction equally clear.
8. **Keep power and area scope explicit.** The 43.010% total / 99.309% dynamic
   reduction combines frequency and gating in a normal-only, direct-clock
   pipeline comparison. It excludes the full-core divider/mailbox and does
   not measure energy while Stage 2 classifies episodes. The 0.1177 mm^2 area
   belongs to the full adaptive core after CTS. The draft now distinguishes
   these in part; preserve that qualification throughout.
9. **A hot slow timing corner is not proven the worst leakage corner.** Report
   the actual 0.9 V, 125 C library condition. The available data do not establish
   a worst-case leakage bound across all process/voltage/temperature corners.

## 7. Experiments that would strengthen the paper most

| Priority | Controlled comparison | What it establishes |
| --- | --- | --- |
| 1 | Run the actual warm-filter/rephase/drain policy on held-out continuous records, including hardware decision latency | Accuracy, detection delay, false wakes and duty cycle for the implemented design |
| 2 | Same final filters/models/clock, four bank-local sample stores versus the 240-word circular history | ASIC cost of removing overlap sample duplication |
| 3 | Same final filters/models/clock, 512 x 32 versus 240 x 32 | ASIC cost of depth reduction, separate from frequency changes |
| 4 | Same models and window policy, separate versus shared replay/MAC | Area/latency trade-off of arithmetic sharing |
| 5 | A frequency-by-gating matrix on normal-only input, followed by active/mixed workloads at feasible clocks | Isolated idle controls and realistic episode energy |

For area ablations, use identical output observability, library, synthesis
effort, clocks and IO constraints, and compare at the same implementation
stage. Report total cells plus storage, read/selection logic, arithmetic and
control breakdowns. Verify identical features/scores for matched sample spans.
The old parallel whole design is not a substitute for this controlled baseline.

A memory-only synthesis microbenchmark can measure buffer implementation costs
quickly, but its result must be labeled a component experiment. A compiled SRAM
comparison would need actual available macro views and matching port semantics.

For power, never use the ungated normal-only figure as the power of active
Stage 2. Measure the active operating point and transition/drain energy.
A useful model is `Pavg = (1-d)*Pidle + d*Pactive + wake_rate*Etransition`,
where d includes false wakes and drain, and transition energy is counted only
for effects not already included in the steady-state terms.

## 8. Suggested contribution wording

> We implement a two-stage rhythm classifier with separate causal filters and
> a common window scheduler, circular sample history, feature-replay engine
> and sequential classifier MAC. Replacing the earlier two sample banks per
> stage with a 240-word dual-lane history reduces useful sample-storage capacity
> from 12,480 to 6,240 bits. Streaming summaries and oldest-first replay support
> overlapping windows without bank-local sample copies. The processing clock
> adapts to outstanding work while Stage 2 filter state is retained across
> inactive periods and started windows are completed before returning to slow
> monitoring.

This paragraph describes implemented structure and derived capacity. Add a
whole-ASIC area-reduction percentage only after the controlled area comparison.
Present candidate novelty as the integrated architecture and its demonstrated
trade-offs, rather than claiming that circular memory, clock gating or MAC
sharing were individually introduced by this work.
