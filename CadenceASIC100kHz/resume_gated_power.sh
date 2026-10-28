#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pair_dir=$(cd -- "${1:?Pair directory}" && pwd -P)
case_dir="$pair_dir/adaptive_gated"
export ECG_MODE=adaptive_gated ECG_ACTIVITY_LEVEL=gate
export ECG_ASIC_ROUTED_DIR="$case_dir/postroute" ECG_TCF="$case_dir/activity/activity.tcf"
test -s "$case_dir/activity/capture_validation.txt"
cd -- "$case_dir/power"
innovus -no_gui -files "$package_dir/../CadenceASICImplementation/routed_power.tcl" \
    -log innovus_retry1.log 2>&1 | tee -a console.log console_retry1.log
python3 "$package_dir/audit_pair.py" case "$case_dir"
printf 'CASE_COMPLETED mode=adaptive_gated path=%s\n' "$case_dir"
