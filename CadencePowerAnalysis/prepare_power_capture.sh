#!/usr/bin/env bash
# Repair old normalized captures or process new raw captures without replacing
# either their VCD or their metadata. Successful outputs get their own folder.
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $# == 1 ]] || { echo 'Usage: bash prepare_power_capture.sh SIMULATION_RUN_DIRECTORY' >&2; exit 2; }
input_dir=$(cd -- "$1" && pwd)
for entry in activity.vcd config.txt simulation.log; do
  [[ -f "$input_dir/$entry" ]] || { echo "Missing $input_dir/$entry" >&2; exit 2; }
done
config_value() {
  awk -F= -v key="$1" '$1 == key {sub(/\r$/, ""); print substr($0, length(key)+2); count++}
    END {if (count != 1) exit 2}' "$input_dir/config.txt"
}
mode=$(config_value mode)
workload=$(config_value workload)
quick=$(config_value quick)
[[ "$quick" == 0 ]] || { echo 'Quick simulations cannot supply power activity.' >&2; exit 2; }
case "$mode" in fixed_ungated|fixed_gated|adaptive_gated) ;; *) echo 'Invalid mode' >&2; exit 2 ;; esac
case "$workload" in normal|demo) ;; *) echo 'Invalid workload' >&2; exit 2 ;; esac
configured_measure=$(config_value measure_samples) || { echo 'Invalid/incomplete full-rate capture metadata.' >&2; exit 2; }
configured_warmup=$(config_value warmup_samples) || { echo 'Invalid/incomplete full-rate capture metadata.' >&2; exit 2; }
input_normalized=$(awk -F= '$1 == "vcd_time_origin" {sub(/\r$/, ""); print $2}' "$input_dir/config.txt")
input_normalized=${input_normalized:-raw}
case "$input_normalized" in raw) input_normalized=0 ;; 0) input_normalized=1 ;; *) echo 'Invalid input VCD origin' >&2; exit 2 ;; esac
# Require a completed run and a single unambiguous capture. Times printed by
# this testbench are ns, independent of the VCD's timescale.
metadata=$(awk -v expected_workload="$workload" -v expected_samples="$configured_measure" -v expected_warmup="$configured_warmup" '
  function value(key, i, pair) {
    for (i=1; i<=NF; i++) {split($i,pair,"="); if(pair[1]==key) return pair[2]}
    return ""
  }
  /^CONFIG / {configs++; source=value("source_hz"); sample=value("sample_hz"); samples=value("measure_samples"); warmup=value("warmup_samples"); workload=value("workload")}
  /^CAPTURE_START / {starts++; start=value("time_ns")}
  /^CAPTURE_END / {ends++; finish=value("time_ns"); duration=value("duration_ns"); edges=value("processing_edges"); fast=value("fast_edges"); s2=value("S2")}
  /^PASS:/ {passes++}
  END {
    if (configs!=1 || starts!=1 || ends!=1 || passes!=1 || source!=100000000 || sample!=120 ||
        workload!=expected_workload || samples!=expected_samples || warmup!=expected_warmup ||
        start !~ /^[0-9]+$/ || finish !~ /^[0-9]+$/ || duration !~ /^[0-9]+$/ ||
        edges !~ /^[0-9]+$/ || fast !~ /^[0-9]+$/ || s2 !~ /^[0-9]+$/ ||
        duration<1000000000 || finish-start!=duration ||
        (duration-samples*1000000000/120 > 10) || (samples*1000000000/120-duration > 10)) exit 2
    printf "%s %s %s %s %s %s\n", source,start,duration,edges,fast,s2
  }' "$input_dir/simulation.log") || { echo 'Invalid/incomplete full-rate capture metadata.' >&2; exit 2; }
read -r source_hz capture_start_ns duration_ns processing_edges fast_edges stage2_results <<< "$metadata"
if [[ "$workload" == normal && "$stage2_results" != 0 ]]; then
  echo 'Normal capture unexpectedly exercised Stage 2.' >&2; exit 2
fi
if [[ "$mode" == adaptive_gated && "$workload" == normal && "$fast_edges" != 0 ]]; then
  echo 'Normal adaptive capture unexpectedly entered fast mode.' >&2; exit 2
fi
if [[ "$mode" != adaptive_gated && "$fast_edges" != "$processing_edges" ]]; then
  echo 'Fixed-clock capture must remain in fast mode.' >&2; exit 2
fi
output_dir=$(mktemp -d "$input_dir/power_capture_XXXXXX")
echo "Preparing bounded capture in: $output_dir" >&2
if ! awk -v duration_ns="$duration_ns" -v source_hz="$source_hz" \
    -v capture_start_ns="$capture_start_ns" -v input_normalized="$input_normalized" \
    -v expected_processing_edges="$processing_edges" -v mode="$mode" -v workload="$workload" \
    -v audit_file="$output_dir/capture_validation.txt" \
    -f "$analysis_dir/normalize_vcd.awk" "$input_dir/activity.vcd" > "$output_dir/activity.vcd"; then
  echo "Capture rejected. Incomplete output retained at $output_dir; do not use it." >&2
  exit 2
fi
# Do not copy stale validation/provenance keys from an earlier run.
awk -F= '$1 !~ /^(vcd_time_origin|capture_bounded|capture_validation|capture_duration_ns|source_hz|original_vcd)$/ {print}' \
  "$input_dir/config.txt" > "$output_dir/config.txt"
printf 'vcd_time_origin=0\ncapture_bounded=1\ncapture_validation=PASS\ncapture_duration_ns=%s\nsource_hz=%s\noriginal_vcd=%s\n' \
  "$duration_ns" "$source_hz" "$input_dir/activity.vcd" >> "$output_dir/config.txt"
cat "$output_dir/capture_validation.txt" >&2
# stdout is deliberately just the filename, allowing ECG_VCD=$(bash ...).
printf '%s\n' "$output_dir/activity.vcd"
