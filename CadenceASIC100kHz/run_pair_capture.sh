#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case_dir=$(cd -- "${1:?Case directory}" && pwd -P)
mode=${2:?Mode}
mkdir -- "$case_dir/activity"
export ECG_PAIR_TCF="$case_dir/activity/activity.tcf"
library=/opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/verilog/slow_vdd1v0_basicCells.v
cd -- "$case_dir/activity"
sha256sum "$case_dir/export/exports/post_route.v" "$library" \
    "$package_dir/sim/ecg_asic_power_tb.sv" > input_sha256.txt
xrun -64bit -sv -timescale 1ns/1ps -unbuffered -access +r -nospecify \
    +define+ECG_GATE_NETLIST "$library" "$case_dir/export/exports/post_route.v" \
    "$package_dir/sim/ecg_asic_power_tb.sv" -top ecg_asic_power_tb \
    -input "$package_dir/pair_activity.tcl" -l simulation.log \
    +NO_DUMP=1 +WORKLOAD=normal +WARMUP_SAMPLES=1200 +MEASURE_SAMPLES=7200 \
    2>&1 | tee console.log
python3 "$package_dir/audit_pair.py" capture "$case_dir"
