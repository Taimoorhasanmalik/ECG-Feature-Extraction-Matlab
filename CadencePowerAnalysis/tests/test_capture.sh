#!/usr/bin/env bash
# Small synthetic VCD regression; no ECG databases or Cadence license needed.
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ecg_capture_test_XXXXXX")
echo "Test outputs: $test_dir"
# Exercise normalization with a deliberately small source rate; production
# prepare_power_capture.sh separately requires a full-rate 100 MHz simulation.
awk 'BEGIN {
  print "$timescale\n  1 ps\n$end"
  print "$scope module ecg_asic_power_tb $end\n$scope module dut $end"
  print "$var wire 1 ! source_clk $end\n$var wire 1 \" processing_clk $end"
  print "$var wire 8 % unknown_data [7:0] $end"
  print "$scope module core $end\n$scope module pipeline $end"
  print "$var parameter 32 p PREFETCH_1 [31:0] $end"
  print "$var reg 14 d payload [13:0] $end"
  print "$var wire 1 # s2_stats_clk $end\n$scope module mac2 $end"
  print "$var wire 1 $ gated_clk $end"
  print "$upscope $end\n$upscope $end\n$upscope $end\n$upscope $end\n$upscope $end"
  print "$enddefinitions $end\n#10000000000000\n$dumpvars\n0!\n0\"\n0#\n0$\nb0 %\nb1 p\nb0 d\n$end"
  for(i=1;i<=20;i++) {
    printf "#%.0f\n", 10000000000000+i*500000000
    print (i%2) "!"
    if(i%2) print (int((i+1)/2)%2) "\""
    if(i==1) print "1$"
    if(i==3) print "0$"
  }
  print "$dumpoff\nx!\nx\"\nx#\nx$\n$end\n#10010279999850"
}' > "$test_dir/raw.vcd"
run_filter() {
  awk -v duration_ns=10000000 -v source_hz=1000 \
    -v capture_start_ns=10000000000 -v expected_processing_edges=5 \
    -v mode=adaptive_gated -v workload=normal \
    -v audit_file="$test_dir/audit.txt" -f "$analysis_dir/normalize_vcd.awk" "$@"
}
run_filter -v input_normalized=0 "$test_dir/raw.vcd" > "$test_dir/bounded.vcd"
[[ $(tail -1 "$test_dir/bounded.vcd") == '#10000000000' ]]
! grep -q '\$dumpoff' "$test_dir/bounded.vcd"
grep -qx 'source_rising_edges=10' "$test_dir/audit.txt"
grep -qx 'processing_rising_edges=5' "$test_dir/audit.txt"
grep -qx 'stage2_stats_rising_edges=0' "$test_dir/audit.txt"
grep -qx 'mac_rising_edges=1' "$test_dir/audit.txt"
# Old package output: already shifted to zero but still includes the tail.
awk '/^#[0-9]+$/ {printf "#%.0f\n",substr($0,2)-10000000000000; next} {print}' \
  "$test_dir/raw.vcd" > "$test_dir/old_normalized.vcd"
run_filter -v input_normalized=1 "$test_dir/old_normalized.vcd" > "$test_dir/repaired.vcd"
cmp "$test_dir/bounded.vcd" "$test_dir/repaired.vcd"
# Reprocessing an already bounded VCD is stable, with no boundary edge added.
run_filter -v input_normalized=1 "$test_dir/bounded.vcd" > "$test_dir/idempotent.vcd"
cmp "$test_dir/bounded.vcd" "$test_dir/idempotent.vcd"
expect_rejection() {
  local name=$1
  shift
  if run_filter "$@" > "$test_dir/$name.output" 2> "$test_dir/$name.error"; then
    echo "FAIL: accepted $name" >&2; exit 1
  fi
  grep -q 'VCD validation failed:' "$test_dir/$name.error"
}
expect_rejection wrong_origin -v input_normalized=1 "$test_dir/raw.vcd"
awk '/^#10009000000000$/ {exit} {print}' "$test_dir/raw.vcd" > "$test_dir/short.vcd"
expect_rejection truncated -v input_normalized=0 "$test_dir/short.vcd"
sed 's/1!/0!/' "$test_dir/raw.vcd" > "$test_dir/wrong_source.vcd"
expect_rejection source_count -v input_normalized=0 "$test_dir/wrong_source.vcd"
expect_rejection processing_count -v input_normalized=0 -v expected_processing_edges=4 "$test_dir/raw.vcd"
awk '{print} /^#10000500000000$/ {print "1#"}' "$test_dir/raw.vcd" > "$test_dir/ungated_stats.vcd"
expect_rejection ungated_stats -v input_normalized=0 "$test_dir/ungated_stats.vcd"
awk '$0=="1$" {print "0$";next} {print}' "$test_dir/raw.vcd" > "$test_dir/stopped_mac.vcd"
expect_rejection stopped_mac -v input_normalized=0 "$test_dir/stopped_mac.vcd"
sed 's/s2_stats_clk/missing_clk/' "$test_dir/raw.vcd" > "$test_dir/missing.vcd"
expect_rejection missing_clock -v input_normalized=0 "$test_dir/missing.vcd"
sed 's/0#/x#/' "$test_dir/raw.vcd" > "$test_dir/unknown.vcd"
expect_rejection unknown_clock -v input_normalized=0 "$test_dir/unknown.vcd"
awk '{print} /^#10009000000000$/ {print "$dumpoff\nx!\n$end"}' \
  "$test_dir/raw.vcd" > "$test_dir/early_off.vcd"
expect_rejection early_dumpoff -v input_normalized=0 "$test_dir/early_off.vcd"
awk '/^#10009000000000$/ {print "#10008000000000";next} {print}' \
  "$test_dir/raw.vcd" > "$test_dir/nonmonotonic.vcd"
expect_rejection backwards_time -v input_normalized=0 "$test_dir/nonmonotonic.vcd"
# Ensure ordinary unknown data is preserved, not silently replaced by zeros.
sed '/^0#/a bx %' "$test_dir/raw.vcd" > "$test_dir/unknown_data.vcd"
run_filter -v input_normalized=0 "$test_dir/unknown_data.vcd" > "$test_dir/kept_unknown.vcd"
grep -qx 'bx %' "$test_dir/kept_unknown.vcd"
# CRLF input and a compact ns timescale must produce equivalent timing/counts.
awk '{sub(/$/, "\r"); print}' "$test_dir/raw.vcd" > "$test_dir/crlf.vcd"
run_filter -v input_normalized=0 "$test_dir/crlf.vcd" > "$test_dir/crlf_bounded.vcd"
cmp "$test_dir/bounded.vcd" "$test_dir/crlf_bounded.vcd"
awk 'NR==1 {print "$timescale 1 ns $end"; next} NR<=3 {next}
 /^#[0-9]+$/ {printf "#%.0f\n", substr($0,2)/1000; next} {print}' \
 "$test_dir/raw.vcd" > "$test_dir/ns.vcd"
run_filter -v input_normalized=0 "$test_dir/ns.vcd" > "$test_dir/ns_bounded.vcd"
[[ $(tail -1 "$test_dir/ns_bounded.vcd") == '#10000000' ]]
# Real 100 MHz source, short fixed-clock capture, and aliased VCD clock IDs.
awk 'BEGIN {
  print "$timescale 1 ns $end\n$scope module ecg_asic_power_tb $end\n$scope module dut $end"
  print "$var wire 1 ! source_clk $end\n$var wire 1 \" processing_clk $end"
  print "$scope module core $end\n$scope module pipeline $end"
  print "$var wire 1 \" s2_stats_clk $end\n$scope module mac2 $end\n$var wire 1 \" gated_clk $end"
  print "$upscope $end\n$upscope $end\n$upscope $end\n$upscope $end\n$upscope $end"
  print "$enddefinitions $end\n#0\n$dumpvars\n0!\n0\"\n$end"
  for(i=1;i<=20000;i++) {
    printf "#%d\n",i*5
    print (i%2) "!"
    if(i%1000==0) print (int(i/1000)%2) "\""
  }
  print "$dumpoff\nx!\nx\"\n$end\n#102800"
}' > "$test_dir/fixed_alias.vcd"
run_filter -v input_normalized=1 -v duration_ns=100000 -v source_hz=100000000 \
  -v expected_processing_edges=10 -v mode=fixed_ungated \
  "$test_dir/fixed_alias.vcd" > "$test_dir/fixed_alias_bounded.vcd"
grep -qx 'source_rising_edges=10000' "$test_dir/audit.txt"
grep -qx 'processing_rising_edges=10' "$test_dir/audit.txt"
grep -qx 'stage2_stats_rising_edges=10' "$test_dir/audit.txt"
grep -qx 'mac_rising_edges=10' "$test_dir/audit.txt"
# Production wrapper rejects quick captures before creating an output folder.
mkdir "$test_dir/quick"
cp "$test_dir/raw.vcd" "$test_dir/quick/activity.vcd"
printf 'mode=adaptive_gated\nworkload=normal\nquick=1\n' > "$test_dir/quick/config.txt"
printf 'PASS: dummy fixture\n' > "$test_dir/quick/simulation.log"
if bash "$analysis_dir/prepare_power_capture.sh" "$test_dir/quick" > "$test_dir/quick.output" 2> "$test_dir/quick.error"; then
  echo 'FAIL: production wrapper accepted a quick simulation' >&2; exit 1
fi
grep -q 'Quick simulations cannot supply power activity' "$test_dir/quick.error"
printf 'mode=adaptive_gated\nworkload=normal\nquick=0\n' > "$test_dir/quick/config.txt"
if bash "$analysis_dir/prepare_power_capture.sh" "$test_dir/quick" > "$test_dir/incomplete.output" 2> "$test_dir/incomplete.error"; then
  echo 'FAIL: production wrapper accepted incomplete metadata' >&2; exit 1
fi
grep -q 'Invalid/incomplete full-rate capture metadata' "$test_dir/incomplete.error"
# Valid full-rate metadata plus a truncated waveform must never acquire a
# successful power config or replace the original simulation VCD.
printf 'mode=adaptive_gated\nworkload=normal\nquick=0\nmeasure_samples=120\nwarmup_samples=1200\n' > "$test_dir/quick/config.txt"
printf '%s\n' \
  'CONFIG source_hz=100000000 sample_hz=120 warmup_samples=1200 measure_samples=120 workload=normal' \
  'CAPTURE_START time_ns=10000000000 accepted=1199' \
  'CAPTURE_END time_ns=11000000000 duration_ns=1000000000 S1=1 S2=0 processing_edges=500 fast_edges=0' \
  'PASS: sent=1320 accepted=1320 S1=7 S2=0 fast_entries=0' > "$test_dir/quick/simulation.log"
if bash "$analysis_dir/prepare_power_capture.sh" "$test_dir/quick" > "$test_dir/truncated.output" 2> "$test_dir/truncated.error"; then
  echo 'FAIL: production wrapper accepted a truncated waveform' >&2; exit 1
fi
grep -q 'Capture rejected' "$test_dir/truncated.error"
[[ ! -s "$test_dir/truncated.output" ]]
cmp "$test_dir/raw.vcd" "$test_dir/quick/activity.vcd"
[[ -z $(find "$test_dir/quick" -mindepth 2 -name config.txt -print) ]]
# Fixed-mode normal captures legitimately report 100000 fast edges. Their
# metadata must reach the VCD audit, not be rejected as Stage 2 activity.
for fixed_mode in fixed_gated fixed_ungated; do
  mode_dir="$test_dir/$fixed_mode"
  mkdir "$mode_dir"
  cp "$test_dir/quick/activity.vcd" "$mode_dir/activity.vcd"
  sed "s/mode=adaptive_gated/mode=$fixed_mode/" "$test_dir/quick/config.txt" > "$mode_dir/config.txt"
  sed 's/processing_edges=500 fast_edges=0/processing_edges=100000 fast_edges=100000/' \
    "$test_dir/quick/simulation.log" > "$mode_dir/simulation.log"
  if bash "$analysis_dir/prepare_power_capture.sh" "$mode_dir" > "$test_dir/$fixed_mode.output" 2> "$test_dir/$fixed_mode.error"; then
    echo 'FAIL: accepted deliberately truncated fixed-mode fixture' >&2; exit 1
  fi
  grep -q 'Preparing bounded capture in:' "$test_dir/$fixed_mode.error"
  grep -q 'Capture rejected' "$test_dir/$fixed_mode.error"
  ! grep -q 'Normal capture unexpectedly' "$test_dir/$fixed_mode.error"
  # Stage 2 classification remains forbidden in the normal workload.
  sed 's/S1=1 S2=0/S1=1 S2=1/' "$mode_dir/simulation.log" > "$mode_dir/bad.log"
  mv "$mode_dir/bad.log" "$mode_dir/simulation.log"
  if bash "$analysis_dir/prepare_power_capture.sh" "$mode_dir" > "$test_dir/$fixed_mode.s2.output" 2> "$test_dir/$fixed_mode.s2.error"; then
    echo 'FAIL: accepted Stage 2 activity in normal workload' >&2; exit 1
  fi
  grep -q 'Normal capture unexpectedly exercised Stage 2' "$test_dir/$fixed_mode.s2.error"
done
# Adaptive normal operation must still reject fast-mode activity.
sed 's/fast_edges=0/fast_edges=1/' "$test_dir/quick/simulation.log" > "$test_dir/quick/fast.log"
mv "$test_dir/quick/fast.log" "$test_dir/quick/simulation.log"
if bash "$analysis_dir/prepare_power_capture.sh" "$test_dir/quick" > "$test_dir/adaptive_fast.output" 2> "$test_dir/adaptive_fast.error"; then
  echo 'FAIL: accepted fast adaptive operation in normal workload' >&2; exit 1
fi
grep -q 'Normal adaptive capture unexpectedly entered fast mode' "$test_dir/adaptive_fast.error"
echo 'PASS: raw/normalized/bounded/CRLF/ns captures, clock checks, unknown-data preservation and rejection cases'
