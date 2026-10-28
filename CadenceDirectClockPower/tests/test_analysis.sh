#!/usr/bin/env bash
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ecg_direct_analysis_XXXXXX")
echo "Test outputs: $test_dir"
for mode in gated_500hz ungated_100khz; do
  if [[ "$mode" == gated_500hz ]]; then hz=500; gating=1; else hz=100000; gating=0; fi
  case_dir="$test_dir/$mode"; mkdir "$case_dir"
  printf 'mode=%s\nsource_hz=%s\nclock_gating=%s\ndirect_clock=1\nworkload=normal\nwarmup_samples=1200\nmeasure_samples=120\n' \
    "$mode" "$hz" "$gating" > "$case_dir/config.txt"
  printf '%s\n' \
    "CONFIG mode=$mode source_hz=$hz sample_hz=120 warmup_samples=1200 measure_samples=120 workload=normal direct_clock=1" \
    'CAPTURE_START time_ns=11000000000 accepted=1200' \
    "CAPTURE_END time_ns=12000000000 duration_ns=1000000000 S1=1 S2=0 processing_edges=$hz" \
    'PASS: sent=1320 accepted=1320 S1=8 S2=0' > "$case_dir/simulation.log"
  awk -v hz="$hz" -v gating="$gating" 'BEGIN {
    print "$timescale 1 ps $end\n$scope module ecg_direct_power_tb $end\n$scope module dut $end"
    print "$var wire 1 ! source_clk $end\n$var wire 1 ! processing_clk $end"
    print "$scope module pipeline $end\n$var parameter 32 p PREFETCH_1 [31:0] $end"
    print "$var wire 8 d data [7:0] $end"
    print "$var wire 1 " (gating ? "#" : "!") " s2_stats_clk $end"
    print "$scope module mac2 $end\n$var wire 1 " (gating ? "$" : "!") " gated_clk $end"
    print "$upscope $end\n$upscope $end\n$upscope $end\n$upscope $end\n$enddefinitions $end"
    print "#11000000000000\n$dumpvars\n0!\nb1 p\nbx d"
    if(gating) print "0#\n0$"
    print "$end"
    for(i=1;i<=2*hz;i++) {
      printf "#%.0f\n",11000000000000+i*1000000000000/(2*hz)
      print (i%2) "!"
      if(gating && i<=12) print (i%2) "$"
    }
    print "$dumpoff\nx!\n$end\n#12028000000000"
  }' > "$case_dir/activity.vcd"
  result=$(bash "$analysis_dir/prepare_capture.sh" "$case_dir")
  [[ $(tail -1 "$result") == '#1000000000000' ]]
  ! grep -q '\$dumpoff' "$result"
  grep -qx 'bx d' "$result"
  grep -qx "source_rising_edges=$hz" "$(dirname "$result")/capture_validation.txt"
  grep -qx "processing_rising_edges=$hz" "$(dirname "$result")/capture_validation.txt"
  if [[ "$gating" == 1 ]]; then
    grep -qx 'stage2_stats_rising_edges=0' "$(dirname "$result")/capture_validation.txt"
    grep -qx 'mac_rising_edges=6' "$(dirname "$result")/capture_validation.txt"
  else
    grep -qx "stage2_stats_rising_edges=$hz" "$(dirname "$result")/capture_validation.txt"
    grep -qx "mac_rising_edges=$hz" "$(dirname "$result")/capture_validation.txt"
  fi
done
expect_rejection() {
  if bash "$analysis_dir/prepare_capture.sh" "$1" > "$test_dir/rejected.out" 2> "$test_dir/rejected.err"; then
    echo 'FAIL: accepted deliberately corrupted capture' >&2; exit 1
  fi
  [[ ! -s "$test_dir/rejected.out" ]]
}
mkdir "$test_dir/bad"
cp "$test_dir/gated_500hz/"{config.txt,simulation.log,activity.vcd} "$test_dir/bad/"
sed 's/PREFETCH_1/s2_stats_clk/' "$test_dir/gated_500hz/activity.vcd" > "$test_dir/bad/activity.vcd"
expect_rejection "$test_dir/bad"
awk '/^#11900000000000$/ {exit} {print}' "$test_dir/gated_500hz/activity.vcd" > "$test_dir/bad/activity.vcd"
expect_rejection "$test_dir/bad"
sed 's/^1!/x!/' "$test_dir/gated_500hz/activity.vcd" > "$test_dir/bad/activity.vcd"
expect_rejection "$test_dir/bad"
# Safe cleanup regression: large logs/reports and unrelated data must survive.
old="$test_dir/CadencePowerAnalysis"; run="$old/fixed_gated_normal_quick0_ABC123"
mkdir -p "$run/power_capture_DEF456" "$old/user_data" "$test_dir/mockbin"
printf 'mode=fixed_gated\n' > "$run/config.txt"
printf 'PASS:\n' > "$run/simulation.log"
for file in "$run/activity.vcd" "$run/power_capture_DEF456/activity.vcd" \
  "$run/genus.log" "$run/timing.rpt" "$old/user_data/activity.vcd"; do truncate -s 12M "$file"; done
printf 'outside\n' > "$test_dir/outside.vcd"
ln -s "$test_dir/outside.vcd" "$run/activity.normalized.tmp"
native_symlink=0
if [[ -L "$run/activity.normalized.tmp" ]]; then native_symlink=1; fi
bash "$analysis_dir/cleanup_previous_waveforms.sh" --dry-run "$old" > "$test_dir/cleanup_preview.txt"
[[ -f "$run/activity.vcd" && -f "$run/power_capture_DEF456/activity.vcd" ]]
# Explicit process-check stubs are only for this isolated fixture.
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_dir/mockbin/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$test_dir/mockbin/fuser"
chmod +x "$test_dir/mockbin/pgrep" "$test_dir/mockbin/fuser"
if PATH="$test_dir/mockbin:$PATH" bash "$analysis_dir/cleanup_previous_waveforms.sh" --delete "$old" > "$test_dir/cleanup_busy.txt" 2>&1; then
  echo 'FAIL: cleanup ignored active-process guard' >&2; exit 1
fi
[[ -f "$run/activity.vcd" ]]
printf '#!/usr/bin/env bash\nexit 1\n' > "$test_dir/mockbin/pgrep"
PATH="$test_dir/mockbin:$PATH" bash "$analysis_dir/cleanup_previous_waveforms.sh" --delete "$old" > "$test_dir/cleanup_deleted.txt"
[[ ! -e "$run/activity.vcd" && ! -e "$run/power_capture_DEF456/activity.vcd" ]]
[[ -f "$run/genus.log" && -f "$run/timing.rpt" && -f "$run/config.txt" && -f "$run/simulation.log" ]]
[[ -f "$old/user_data/activity.vcd" && -f "$test_dir/outside.vcd" && -e "$run/activity.normalized.tmp" ]]
if [[ "$native_symlink" == 1 ]]; then [[ -L "$run/activity.normalized.tmp" ]]; fi
if bash "$analysis_dir/cleanup_previous_waveforms.sh" --delete "$test_dir" > "$test_dir/cleanup_bad_root.txt" 2>&1; then
  echo 'FAIL: cleanup accepted an out-of-scope root' >&2; exit 1
fi
echo 'PASS: both direct-clock captures, aliases/parameters, rejection cases and cleanup scope/process safeguards'
