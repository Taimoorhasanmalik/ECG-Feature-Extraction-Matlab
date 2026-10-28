#!/usr/bin/env bash
# Resume the known preserved pair after the initial top-layer conflict.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
backend="$package_dir/../CadenceASICImplementation"
pair_dir=$(cd -- "${1:?Pair directory}" && pwd -P)
case_dir="$pair_dir/adaptive_gated"
export ECG_MODE=adaptive_gated
test -s "$case_dir/cts/reports/CTS_PREPARED.txt"
test -d "$case_dir/cts/checkpoints/post_cts.enc.dat"
run_stage() {
    local stage=$1 script=$2
    mkdir -- "$case_dir/$stage"
    printf 'STAGE_START case=adaptive_gated stage=%s time=%s\n' "$stage" "$(date -u +%FT%TZ)"
    ( cd -- "$case_dir/$stage"
      innovus -no_gui -files "$backend/$script" -log innovus.log 2>&1 | tee console.log
      if grep -qRE '^\*\*ERROR:' console.log reports; then exit 1; fi
    )
    printf 'STAGE_END case=adaptive_gated stage=%s time=%s\n' "$stage" "$(date -u +%FT%TZ)"
}
export ECG_ASIC_POSTCTS_DIR="$case_dir/cts" ECG_ASIC_ROUTE_ACTION=route
run_stage route_retry1 routing.tcl
export ECG_ASIC_ROUTE_RUN_DIR="$case_dir/route_retry1" ECG_ASIC_ROUTE_ACTION=postroute
run_stage postroute routing.tcl
export ECG_ASIC_ROUTED_DIR="$case_dir/postroute"
run_stage export physical_export.tcl
export ECG_ASIC_EXPORT_DIR="$case_dir/export"
bash "$backend/run_physical_verification.sh" 2>&1 | tee "$case_dir/verification_launch.log"
grep '^Physical verification directory:' "$case_dir/verification_launch.log" | tail -1 > "$case_dir/verification_path.txt"
bash "$package_dir/run_pair_capture.sh" "$case_dir" adaptive_gated
export ECG_TCF="$case_dir/activity/activity.tcf" ECG_ACTIVITY_LEVEL=gate
run_stage power routed_power.tcl
python3 "$package_dir/audit_pair.py" case "$case_dir"
printf 'CASE_COMPLETED mode=adaptive_gated path=%s\n' "$case_dir"
