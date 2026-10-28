#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
workload=${1:-normal}
mode=${2:-adaptive_gated}
defines=()
case "$mode" in
    adaptive_gated) ;;
    fixed_gated) defines+=(+define+ECG_FIXED_CLOCK) ;;
    fixed_ungated) defines+=(+define+ECG_FIXED_CLOCK +define+ECG_NO_CLOCK_GATING) ;;
    *) exit 2 ;;
esac
case "$workload" in clock|normal|demo) ;; *) exit 2;; esac
mkdir -p "$package_dir/runs"
run_dir=$(mktemp -d "$package_dir/runs/sim_${workload}_XXXXXX")
printf 'Simulation directory: %s\n' "$run_dir"
cd -- "$run_dir"
if [[ "$workload" == clock ]]; then
    xrun -64bit -sv -timescale 1ns/1ps -unbuffered "$package_dir/rtl/ecg_adaptive_clock.v" \
        "$package_dir/rtl/asic_clock_primitives.v" "$package_dir/sim/gsclib_icg_functional.v" \
        "$package_dir/sim/clock_profile_tb.sv" -top clock_profile_tb -l simulation.log
else
    sources=()
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        entry=${entry%$'\r'}
        [[ -z "$entry" ]] || sources+=("$package_dir/$entry")
    done < "$package_dir/rtl/files.f"
    xrun -64bit -sv -timescale 1ns/1ps -unbuffered -access +r "${sources[@]}" \
        "$package_dir/sim/gsclib_icg_functional.v" "$package_dir/sim/ecg_asic_power_tb.sv" \
        "${defines[@]}" -top ecg_asic_power_tb -l simulation.log +NO_DUMP=1 \
        "+WORKLOAD=$workload" +WARMUP_SAMPLES=1200 "+MEASURE_SAMPLES=${ECG_MEASURE_SAMPLES:-120}" \
        "+MEM_FILE=$package_dir/mem/synthetic_two_stage_demo_q3_8.mem"
fi
grep -q '^PASS:' simulation.log
printf 'Simulation passed: %s\n' "$run_dir"
