#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
mkdir -p "$package_dir/runs"
pair_dir=$(mktemp -d "$package_dir/runs/power_pair_XXXXXX")
mkdir -- "$pair_dir/adaptive_gated" "$pair_dir/fixed_ungated"
printf 'Power-pair directory: %s\n' "$pair_dir"
gated_reuse=${ECG_PAIR_GATED_SYNTH:-}
ECG_PAIR_SYNTH_REUSE="$gated_reuse" bash "$package_dir/run_pair_case.sh" \
    "$pair_dir/adaptive_gated" adaptive_gated > "$pair_dir/adaptive_gated/driver.log" 2>&1 &
gated_pid=$!
ECG_PAIR_SYNTH_REUSE= bash "$package_dir/run_pair_case.sh" \
    "$pair_dir/fixed_ungated" fixed_ungated > "$pair_dir/fixed_ungated/driver.log" 2>&1 &
ungated_pid=$!
printf 'gated_pid=%s\nungated_pid=%s\n' "$gated_pid" "$ungated_pid" > "$pair_dir/driver_pids.txt"
status=0
wait "$gated_pid" || status=1
wait "$ungated_pid" || status=1
if [[ "$status" != 0 ]]; then
    printf 'A power case failed; all outputs retained at %s\n' "$pair_dir" >&2
    exit 1
fi
python3 "$package_dir/audit_pair.py" compare "$pair_dir"
printf 'POWER_PAIR_COMPLETED %s\n' "$pair_dir"
