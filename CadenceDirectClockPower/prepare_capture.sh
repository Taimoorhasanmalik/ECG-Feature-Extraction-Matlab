#!/usr/bin/env bash
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $# == 1 ]] || { echo 'Usage: bash prepare_capture.sh RUN_DIRECTORY' >&2; exit 2; }
run_dir=$(cd -- "$1" && pwd)
for file in config.txt simulation.log activity.vcd; do [[ -f "$run_dir/$file" ]] || { echo "Missing $file" >&2; exit 2; }; done
get_config() {
  awk -F= -v key="$1" '$1==key {sub(/\r$/,"");print substr($0,length(key)+2);n++} END {if(n!=1)exit 2}' "$run_dir/config.txt"
}
mode=$(get_config mode)
source_hz=$(get_config source_hz)
samples=$(get_config measure_samples)
warmup=$(get_config warmup_samples)
[[ $(get_config direct_clock) == 1 && $(get_config workload) == normal ]] || exit 2
case "$mode:$source_hz" in gated_500hz:500|ungated_100khz:100000) ;; *) echo 'Mode/clock mismatch' >&2; exit 2 ;; esac
metadata=$(awk -v mode="$mode" -v hz="$source_hz" -v samples="$samples" -v warmup="$warmup" '
 function field(name,i,a) {for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]==name)return a[2]} return ""}
 /^CONFIG / {configs++;if(field("mode")!=mode || field("source_hz")!=hz || field("sample_hz")!=120 || field("direct_clock")!=1 || field("workload")!="normal" || field("measure_samples")!=samples || field("warmup_samples")!=warmup) bad=1}
 /^CAPTURE_START / {starts++;start=field("time_ns")}
 /^CAPTURE_END / {ends++;finish=field("time_ns");duration=field("duration_ns");edges=field("processing_edges");if(field("S2")!=0 || field("S1")!=samples/120)bad=1}
 /^PASS:/ {passes++;if(field("sent")!=samples+warmup || field("accepted")!=samples+warmup || field("S2")!=0)bad=1}
 END {if(bad || configs!=1 || starts!=1 || ends!=1 || passes!=1 || start!~/^[0-9]+$/ || finish!~/^[0-9]+$/ || duration!~/^[0-9]+$/ || edges!~/^[0-9]+$/ || duration!=samples*1000000000/120 || finish-start!=duration || duration<1000000000)exit 2;print start,duration,edges}
' "$run_dir/simulation.log") || { echo 'Capture metadata/accounting rejected' >&2; exit 2; }
read -r start_ns duration_ns edges <<< "$metadata"
output_dir=$(mktemp -d "$run_dir/power_capture_XXXXXX")
echo "Preparing direct-clock capture: $output_dir" >&2
if ! awk -v mode="$mode" -v source_hz="$source_hz" -v capture_start_ns="$start_ns" \
  -v duration_ns="$duration_ns" -v expected_processing_edges="$edges" \
  -v audit_file="$output_dir/capture_validation.txt" -f "$analysis_dir/capture.awk" \
  "$run_dir/activity.vcd" > "$output_dir/activity.vcd"; then
  echo "Rejected output retained at $output_dir; do not analyze it." >&2; exit 2
fi
cp -- "$run_dir/config.txt" "$output_dir/config.txt"
printf 'capture_validation=PASS\ncapture_bounded=1\nvcd_time_origin=0\ncapture_duration_ns=%s\n' "$duration_ns" >> "$output_dir/config.txt"
cat "$output_dir/capture_validation.txt" >&2
printf '%s\n' "$output_dir/activity.vcd"
