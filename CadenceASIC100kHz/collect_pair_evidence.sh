#!/usr/bin/env bash
# Keep a compact reporting bundle; large databases/TCFs stay on AWS.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
pair_dir=$(cd -- "${1:?Pair directory}" && pwd -P)
python3 "$package_dir/audit_pair.py" compare "$pair_dir"
staging=$(mktemp -d "$pair_dir/reporting_evidence_XXXXXX")
cp -- "$pair_dir/comparison.md" "$staging/"
for mode in adaptive_gated fixed_ungated; do
    source_case="$pair_dir/$mode"
    target_case="$staging/$mode"
    mkdir -- "$target_case"
    cp -- "$source_case/case_result.json" "$source_case/case_config.txt" \
        "$source_case/verification_path.txt" "$target_case/"
    for folder in activity power/reports export/reports; do
        mkdir -p -- "$target_case/$folder"
    done
    cp -- "$source_case/activity/capture_validation.txt" \
        "$source_case/activity/config.txt" "$source_case/activity/input_sha256.txt" \
        "$source_case/activity/simulation.log" "$target_case/activity/"
    cp -- "$source_case/power/reports/routed_power.rpt" \
        "$source_case/power/reports/power_provenance.txt" \
        "$source_case/power/reports/parasitic_annotation.rpt" \
        "$target_case/power/reports/"
    cp -- "$source_case/power/voltus_clocks.txt" "$target_case/"
    physical=$(sed -n 's/^Physical verification directory: //p' "$source_case/verification_path.txt")
    cp -- "$physical/verification_verdict.json" "$target_case/"
    routed=$(sed -n 's/^source_routed=//p' "$source_case/power/reports/power_provenance.txt")
    mkdir -- "$target_case/routing"
    cp -- "$routed/reports/area_breakdown.txt" \
        "$routed/reports/timing/final.summary.gz" \
        "$routed/reports/timing/final_hold.summary.gz" "$target_case/routing/"
    if [[ -f "$routed/reports/driver_repair.txt" ]]; then
        cp -- "$routed/reports/driver_repair.txt" "$target_case/routing/"
    fi
done
archive="$staging.tar.gz"
tar -czf "$archive" -C "$staging" .
sha256sum "$archive"
printf 'REPORTING_ARCHIVE=%s\n' "$archive"
