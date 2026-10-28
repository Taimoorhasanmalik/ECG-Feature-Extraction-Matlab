#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pair_dir=$(cd -- "${1:?Accepted pair directory}" && pwd -P)
output=$(mktemp -d "$pair_dir/native_area_reports_XXXXXX")
pids=()
for mode in adaptive_gated fixed_ungated; do
    routed=$(sed -n 's/^source_routed=//p' "$pair_dir/$mode/power/reports/power_provenance.txt")
    case "$routed/" in "$pair_dir/$mode/"*) ;; *) exit 1;; esac
    mkdir -- "$output/$mode"
    (
        cd -- "$output/$mode"
        export ECG_ASIC_ROUTED_DIR="$routed"
        innovus -no_gui -files "$package_dir/native_postroute_area.tcl" \
            -log innovus.log > console.log 2>&1
        grep -qx 'NATIVE POST-ROUTE AREA REPORTS GENERATED' console.log
        if grep -qE '^\*\*ERROR:' console.log; then exit 1; fi
    ) &
    pids+=("$!")
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
if [[ $status != 0 ]]; then echo "Native report generation failed: $output" >&2; exit 1; fi
tar -czf "$output.tar.gz" -C "$output" .
sha256sum "$output.tar.gz"
printf 'NATIVE_AREA_ARCHIVE=%s.tar.gz\n' "$output"
