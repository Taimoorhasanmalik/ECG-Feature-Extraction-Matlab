#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
backend="$package_dir/../CadenceASICImplementation"
pair_dir=$(cd -- "${1:?Pair directory}" && pwd -P)
case_dir="$pair_dir/adaptive_gated"
export ECG_MODE=adaptive_gated ECG_ASIC_ROUTED_DIR="$case_dir/postroute"
# The first export stopped in its report-check Tcl before writing GDS.
# Retain its logs and write distinct retry logs in the same output boundary.
( cd -- "$case_dir/export"
  innovus -no_gui -files "$backend/physical_export.tcl" -log innovus_retry1.log \
      2>&1 | tee console_retry1.log
  if grep -qE '^\*\*ERROR:' console_retry1.log; then exit 1; fi
)
export ECG_ASIC_EXPORT_DIR="$case_dir/export"
bash "$backend/run_physical_verification.sh" 2>&1 | tee "$case_dir/verification_launch.log"
grep '^Physical verification directory:' "$case_dir/verification_launch.log" | tail -1 > "$case_dir/verification_path.txt"
bash "$package_dir/run_pair_capture.sh" "$case_dir" adaptive_gated
export ECG_TCF="$case_dir/activity/activity.tcf" ECG_ACTIVITY_LEVEL=gate
mkdir -- "$case_dir/power"
( cd -- "$case_dir/power"
  innovus -no_gui -files "$backend/routed_power.tcl" -log innovus.log 2>&1 | tee console.log
)
python3 "$package_dir/audit_pair.py" case "$case_dir"
printf 'CASE_COMPLETED mode=adaptive_gated path=%s\n' "$case_dir"
