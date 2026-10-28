#!/usr/bin/env bash
# Complete comparison after both independently audited cases finish, including
# a resumed case. Never substitute missing/default power for a failed run.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pair_dir=$(cd -- "${1:?Pair directory}" && pwd -P)
printf 'Waiting for both accepted case reports: %s\n' "$pair_dir"
for ((attempt=0; attempt<1080; attempt++)); do
    if [[ -s "$pair_dir/adaptive_gated/case_result.json" && -s "$pair_dir/fixed_ungated/case_result.json" ]]; then
        python3 "$package_dir/audit_pair.py" compare "$pair_dir" 2>&1 | tee "$pair_dir/comparison_console.log"
        printf 'POWER_PAIR_COMPLETED %s\n' "$pair_dir"
        exit 0
    fi
    sleep 10
done
printf 'Timed out waiting for accepted case reports; inspect both driver logs.\n' >&2
exit 1
