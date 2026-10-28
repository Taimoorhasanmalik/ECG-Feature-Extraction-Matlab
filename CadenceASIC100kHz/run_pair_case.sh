#!/usr/bin/env bash
# Fresh full-core physical implementation and 60 s gate-activity power case.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
backend="$package_dir/../CadenceASICImplementation"
case_dir=$(cd -- "${1:?Case directory}" && pwd -P)
mode=${2:?Mode}
case "$mode" in adaptive_gated|fixed_ungated) ;; *) exit 2;; esac
export ECG_MODE="$mode"
trap 'printf "FAILED at line %s; inspect %s\n" "$LINENO" "$case_dir" >&2' ERR
run_innovus() {
    local stage=$1 script=$2
    mkdir -- "$case_dir/$stage"
    printf 'STAGE_START case=%s stage=%s time=%s\n' "$mode" "$stage" "$(date -u +%FT%TZ)"
    ( cd -- "$case_dir/$stage"
      innovus -no_gui -files "$backend/$script" -log innovus.log 2>&1 | tee console.log
      if grep -qRE '^\*\*ERROR:' console.log reports; then
          printf 'Native errors in %s\n' "$stage" >&2; exit 1
      fi
    )
    printf 'STAGE_END case=%s stage=%s time=%s\n' "$mode" "$stage" "$(date -u +%FT%TZ)"
}
if [[ -n ${ECG_PAIR_SYNTH_REUSE:-} ]]; then
    synth_dir=$(cd -- "$ECG_PAIR_SYNTH_REUSE" && pwd -P)
else
    synth_dir="$case_dir/synthesis"
    mkdir -- "$synth_dir"
    ( cd -- "$synth_dir"
      genus -del_scale 10 -files "$package_dir/genus_synth.tcl" -log genus.log 2>&1 | tee console.log
      test -s mapped.v; test -s mapped.sdc
      grep -q 'ASIC 100 kHz synthesis completed' console.log
    )
fi
grep -qx "mode=$mode" "$synth_dir/reports/analysis_notes.txt"
grep -q '^source_hz=100000;' "$synth_dir/reports/analysis_notes.txt"
printf 'mode=%s\nsynthesis=%s\nsource_hz=100000\nmeasure_seconds=60\n' \
    "$mode" "$synth_dir" > "$case_dir/case_config.txt"
export ECG_ASIC_SCOPE=adaptive_core ECG_ASIC_SYNTH_DIR="$synth_dir" ECG_ASIC_PACKAGE_DIR="$backend"
run_innovus import import.tcl
export ECG_ASIC_IMPORT_DIR="$case_dir/import"
run_innovus floorplan floorplan.tcl
export ECG_ASIC_FLOORPLAN_DIR="$case_dir/floorplan"
run_innovus powerplan powerplan.tcl
export ECG_ASIC_POWERPLAN_DIR="$case_dir/powerplan" ECG_ASIC_PLACE_ACTION=place
run_innovus placement placement.tcl
export ECG_ASIC_PLACEMENT_DIR="$case_dir/placement" ECG_ASIC_CTS_ACTION=inspect
run_innovus cts_inspect cts.tcl
export ECG_ASIC_CTS_INSPECTION_DIR="$case_dir/cts_inspect" ECG_ASIC_CTS_ACTION=cts
run_innovus cts cts.tcl
export ECG_ASIC_POSTCTS_DIR="$case_dir/cts" ECG_ASIC_ROUTE_ACTION=route
run_innovus route routing.tcl
export ECG_ASIC_ROUTE_RUN_DIR="$case_dir/route" ECG_ASIC_ROUTE_ACTION=postroute
run_innovus postroute routing.tcl
export ECG_ASIC_ROUTED_DIR="$case_dir/postroute"
run_innovus export physical_export.tcl
export ECG_ASIC_EXPORT_DIR="$case_dir/export"
bash "$backend/run_physical_verification.sh" 2>&1 | tee "$case_dir/verification_launch.log"
grep '^Physical verification directory:' "$case_dir/verification_launch.log" | tail -1 > "$case_dir/verification_path.txt"
bash "$package_dir/run_pair_capture.sh" "$case_dir" "$mode"
export ECG_TCF="$case_dir/activity/activity.tcf" ECG_ACTIVITY_LEVEL=gate
run_innovus power routed_power.tcl
python3 "$package_dir/audit_pair.py" case "$case_dir"
printf 'CASE_COMPLETED mode=%s path=%s\n' "$mode" "$case_dir"
