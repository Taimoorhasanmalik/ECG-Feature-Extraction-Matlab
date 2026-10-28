#!/usr/bin/env bash
# Copy reports only: no implementation rerun and no database/TCF/GDS copies.
set -euo pipefail
pair_dir=$(cd -- "${1:?Accepted pair directory}" && pwd -P)
test -s "$pair_dir/comparison.md"
staging=$(mktemp -d "$pair_dir/apr_reports_XXXXXX")
cp -- "$pair_dir/comparison.md" "$staging/COMPARISON.md"
for mode in adaptive_gated fixed_ungated; do
    case_dir="$pair_dir/$mode"
    if [[ $mode == adaptive_gated ]]; then label=gated_500Hz; else label=ungated_100kHz; fi
    target="$staging/$label"
    test -s "$case_dir/case_result.json"
    routed=$(sed -n 's/^source_routed=//p' "$case_dir/power/reports/power_provenance.txt")
    synthesis=$(sed -n 's/^synthesis=//p' "$case_dir/case_config.txt")
    physical=$(sed -n 's/^Physical verification directory: //p' "$case_dir/verification_path.txt")
    case "$routed/" in "$case_dir/"*) ;; *) echo 'Routed source outside case' >&2; exit 1;; esac
    mkdir -p -- "$target/area" "$target/power" "$target/timing/raw_compressed" \
        "$target/constraints" "$target/validation" "$target/provenance" \
        "$target/synthesis_reference"
    cp -- "$routed/reports/area_breakdown.txt" "$target/area/postroute_area.txt"
    cp -- "$routed/reports/placement_after_summary.rpt" "$target/area/placement_summary.rpt"
    cp -- "$case_dir/power/reports/"* "$target/power/"
    cp -- "$routed/reports/timing/"* "$target/timing/raw_compressed/"
    for corner in slow fast; do
        for check in setup hold data_hold removal; do
            cp -- "$routed/reports/view_${corner}_${check}.rpt" "$target/timing/"
        done
    done
    cp -- "$routed/reports/clocks.rpt" "$routed/reports/timing_intent.rpt" "$target/timing/"
    cp -- "$case_dir/export/exports/post_route.sdc" "$target/constraints/"
    cp -- "$case_dir/voltus_clocks.txt" "$target/validation/actual_power_clocks.txt" 2>/dev/null || \
        cp -- "$case_dir/power/voltus_clocks.txt" "$target/validation/actual_power_clocks.txt"
    cp -- "$routed/reports/routing_drc.rpt" "$routed/reports/connectivity.rpt" \
        "$routed/reports/power_ground_check.rpt" "$physical/verification_verdict.json" \
        "$case_dir/activity/capture_validation.txt" "$case_dir/activity/config.txt" \
        "$case_dir/activity/input_sha256.txt" "$case_dir/activity/simulation.log" "$target/validation/"
    cp -- "$case_dir/case_result.json" "$case_dir/case_config.txt" \
        "$case_dir/verification_path.txt" "$routed/reports/input_provenance.txt" \
        "$routed/reports/route_provenance.txt" "$target/provenance/"
    if [[ -f "$routed/reports/driver_repair.txt" ]]; then
        cp -- "$routed/reports/driver_repair.txt" "$target/provenance/"
    fi
    for report in area.rpt gates.rpt timing.rpt clocks.rpt generated_clocks.rpt \
            timing_intent.rpt mapped_unresolved.rpt analysis_notes.txt; do
        cp -- "$synthesis/reports/$report" "$target/synthesis_reference/"
    done
done
(cd -- "$staging"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$staging/SHA256SUMS"
archive="$staging.tar.gz"
tar -czf "$archive" -C "$staging" .
sha256sum "$archive"
printf 'APR_REPORT_ARCHIVE=%s\n' "$archive"
