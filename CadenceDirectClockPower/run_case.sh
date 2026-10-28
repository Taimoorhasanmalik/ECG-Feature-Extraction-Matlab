#!/usr/bin/env bash
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${ECG_RTL_DIR:?Set ECG_RTL_DIR to FINAL_RTL}"
rtl_dir=$(cd -- "$ECG_RTL_DIR" && pwd)
mode=${1:-gated_500hz}
defines=()
case "$mode" in
  gated_500hz) source_hz=500; gating=1 ;;
  ungated_100khz) source_hz=100000; gating=0; defines+=(+define+ECG_DIRECT_UNGATED) ;;
  *) echo 'Mode must be gated_500hz or ungated_100khz' >&2; exit 2 ;;
esac
seconds=${ECG_MEASURE_SECONDS:-60}
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] && ((seconds<=3600)) || { echo 'ECG_MEASURE_SECONDS must be 1..3600' >&2; exit 2; }
sim_only=${ECG_SIM_ONLY:-0}
[[ "$sim_only" == 0 || "$sim_only" == 1 ]] || exit 2
command -v xrun >/dev/null
if [[ "$sim_only" == 0 ]]; then command -v genus >/dev/null; : "${ECG_LIB:?Set ECG_LIB to the selected Liberty library}"; fi
sources=()
while IFS= read -r entry || [[ -n "$entry" ]]; do
  entry=${entry%$'\r'}
  [[ -z "$entry" ]] && continue
  [[ -f "$rtl_dir/$entry" ]] || { echo "Missing RTL: $entry" >&2; exit 2; }
  sources+=("$rtl_dir/$entry")
done < "$analysis_dir/rtl/files.f"
if [[ $# -ge 2 ]]; then
  [[ ! -e "$2" ]] || { echo 'Refusing to overwrite an existing output directory' >&2; exit 2; }
  mkdir -- "$2"
  run_dir=$(cd -- "$2" && pwd)
else
  mkdir -p "$analysis_dir/runs"
  run_dir=$(mktemp -d "$analysis_dir/runs/${mode}_XXXXXX")
fi
printf 'mode=%s\nsource_hz=%s\nclock_gating=%s\ndirect_clock=1\nworkload=normal\nrtl_dir=%s\nwarmup_samples=1200\nmeasure_samples=%s\n' \
  "$mode" "$source_hz" "$gating" "$rtl_dir" "$((seconds*120))" > "$run_dir/config.txt"
echo "Run directory: $run_dir"
cd -- "$run_dir"
xrun -64bit -sv -timescale 1ns/1ps -access +r "${defines[@]}" "${sources[@]}" \
  "$analysis_dir/rtl/asic_clock_primitives.v" "$analysis_dir/rtl/ecg_direct_power_top.v" \
  "$analysis_dir/sim/gsclib_icg_functional.v" "$analysis_dir/sim/ecg_direct_power_tb.sv" \
  -top ecg_direct_power_tb -l simulation.log \
  +WARMUP_SAMPLES=1200 "+MEASURE_SAMPLES=$((seconds*120))"
grep -q '^PASS:' simulation.log || { echo 'Simulation did not PASS' >&2; exit 2; }
power_vcd=$(bash "$analysis_dir/prepare_capture.sh" "$run_dir")
echo "Validated power VCD: $power_vcd"
if [[ "$sim_only" == 0 ]]; then
  export ECG_MODE="$mode" ECG_VCD="$power_vcd" ECG_RTL_DIR="$rtl_dir"
  mkdir genus
  cd genus
  genus -del_scale 10 -files "$analysis_dir/genus_synth.tcl"
  [[ -s reports/preliminary_power.rpt ]] || { echo 'No power report; inspect genus.log' >&2; exit 2; }
  grep -q 'Analysis script completed' genus.log || { echo 'Genus script did not finish' >&2; exit 2; }
fi
echo "Case completed: $run_dir"
