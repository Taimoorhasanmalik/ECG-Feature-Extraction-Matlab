#!/usr/bin/env bash
# Only large waveform files in recognized OLD analysis simulation directories.
# Default is read-only. Logs, reports, RTL, netlists and archives are excluded.
set -euo pipefail
action=${1:---dry-run}
requested_root=${2:-/home/ec2-user/CadencePowerAnalysis}
[[ "$action" == --dry-run || "$action" == --delete ]] || { echo 'Use --dry-run or --delete [OLD_ANALYSIS_ROOT]' >&2; exit 2; }
root=$(cd -- "$requested_root" && pwd -P)
[[ "${root##*/}" == CadencePowerAnalysis && "$root" != /CadencePowerAnalysis ]] || {
  echo 'Refusing cleanup: target must be the specifically named CadencePowerAnalysis directory.' >&2; exit 2;
}
if [[ "$action" == --delete ]]; then
  command -v pgrep >/dev/null || { echo 'Cannot check running tools: pgrep is required for deletion.' >&2; exit 2; }
  if pgrep -u "$(id -u)" -x 'xrun|xmsim|genus' >/dev/null || \
     pgrep -u "$(id -u)" -f '[n]ormalize_vcd[.]awk|[p]repare_power_capture[.]sh' >/dev/null; then
    echo 'Refusing deletion while simulation, synthesis or old capture processing is running.' >&2; exit 2
  fi
fi
shopt -s nullglob
files=(); resolved_targets=(); total=0
for run in "$root"/*; do
  [[ -d "$run" && ! -L "$run" ]] || continue
  name=${run##*/}
  [[ "$name" =~ ^(adaptive_gated|fixed_gated|fixed_ungated)_(normal|demo)_quick[01]_[[:alnum:]]{6}$ ]] || continue
  [[ -f "$run/config.txt" && -f "$run/simulation.log" ]] || continue
  for file in "$run/activity.vcd" "$run/activity.normalized.tmp" "$run"/power_capture_??????/activity.vcd; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    resolved=$(realpath -e -- "$file")
    [[ "$resolved" == "$run/"* ]] || { echo "Skipping out-of-scope link: $file" >&2; continue; }
    size=$(stat -c %s -- "$file")
    ((size>=10485760)) || continue
    files+=("$file"); resolved_targets+=("$resolved"); total=$((total+size))
    printf '%12s bytes  %s\n' "$size" "$file"
  done
done
awk -v n="${#files[@]}" -v size="$total" 'BEGIN {printf "Selected %d waveform files, %.3f GiB.\n",n,size/1073741824}'
if [[ "$action" == --dry-run ]]; then
  echo 'DRY RUN: nothing deleted. Re-run with --delete only after reviewing this list.'
  exit 0
fi
for index in "${!files[@]}"; do
  file=${files[index]}
  # Revalidate the exact file immediately before a nonrecursive unlink.
  [[ -f "$file" && ! -L "$file" ]] || { echo "Target changed: $file" >&2; exit 2; }
  resolved=$(realpath -e -- "$file")
  [[ "$resolved" == "${resolved_targets[index]}" && "$resolved" == "$root/"* ]] || { echo 'Target escaped original cleanup scope' >&2; exit 2; }
  if command -v fuser >/dev/null && fuser -s "$file"; then
    echo "File is in use; refusing to remove: $file" >&2; exit 2
  fi
  rm -- "$file"
  echo "Removed waveform: $file"
done
echo 'Logs, reports, configs, mapped netlists, RTL and archives were preserved.'
echo 'Deleted waveforms require a backup or resimulation to recover.'
