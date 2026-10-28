#!/usr/bin/env bash
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${ECG_RTL_DIR:?Set ECG_RTL_DIR to the uploaded final hardware folder}"
rtl_dir=$(cd -- "$ECG_RTL_DIR" && pwd)
mode=${1:-adaptive_gated}
workload=${2:-normal}
defines=()
case "$mode" in
  fixed_ungated) defines+=(+define+ECG_FIXED_CLOCK +define+ECG_NO_CLOCK_GATING) ;;
  fixed_gated) defines+=(+define+ECG_FIXED_CLOCK) ;;
  adaptive_gated) ;;
  *) echo 'Mode: fixed_ungated, fixed_gated, or adaptive_gated' >&2; exit 2 ;;
esac
case "$workload" in normal|demo) ;; *) echo 'Workload: normal or demo' >&2; exit 2 ;; esac
command -v xrun >/dev/null
sources=()
while IFS= read -r entry || [[ -n "$entry" ]]; do
  entry=${entry%$'\r'}
  [[ -z "$entry" ]] && continue
  [[ -f "$rtl_dir/$entry" ]] || { echo "Missing RTL: $entry" >&2; exit 2; }
  sources+=("$rtl_dir/$entry")
done < "$rtl_dir/rtl/files.f"
quick=${ECG_QUICK_SIM:-0}
no_dump=0
if [[ "$quick" == 1 ]]; then
  defines+=(+define+ECG_QUICK_SIM)
  no_dump=1
  echo 'FUNCTIONAL CHECK ONLY: 200 kHz source, no power activity capture.'
elif [[ "$quick" != 0 ]]; then
  echo 'ECG_QUICK_SIM must be 0 or 1' >&2; exit 2
fi
run_dir=$(mktemp -d "$analysis_dir/${mode}_${workload}_quick${quick}_XXXXXX")
printf 'mode=%s\nworkload=%s\nquick=%s\nrtl_dir=%s\nwarmup_samples=%s\nmeasure_samples=%s\n' \
  "$mode" "$workload" "$quick" "$rtl_dir" \
  "${ECG_WARMUP_SAMPLES:-1200}" "${ECG_MEASURE_SAMPLES:-120}" > "$run_dir/config.txt"
printf 'Run directory: %s\n' "$run_dir"
cd -- "$run_dir"
xrun -64bit -sv -timescale 1ns/1ps -access +r \
  "${defines[@]}" "${sources[@]}" \
  "$analysis_dir/rtl/asic_clock_primitives.v" \
  "$analysis_dir/rtl/ecg_asic_power_top.v" \
  "$analysis_dir/sim/gsclib_icg_functional.v" \
  "$analysis_dir/sim/ecg_asic_power_tb.sv" \
  -top ecg_asic_power_tb -l simulation.log \
  "+WORKLOAD=$workload" "+NO_DUMP=$no_dump" \
  "+WARMUP_SAMPLES=${ECG_WARMUP_SAMPLES:-1200}" \
  "+MEASURE_SAMPLES=${ECG_MEASURE_SAMPLES:-120}" \
  "+MEM_FILE=$rtl_dir/mem/synthetic_two_stage_demo_q3_8.mem" \
  "+VCD_FILE=$run_dir/activity.vcd"
grep -q '^PASS:' simulation.log || { echo 'Simulation did not report PASS' >&2; exit 1; }
if [[ "$no_dump" == 0 ]]; then
  power_vcd=$(bash "$analysis_dir/prepare_power_capture.sh" "$run_dir")
  printf 'Validated power VCD: %s\n' "$power_vcd"
fi
echo "Simulation completed: $run_dir"
