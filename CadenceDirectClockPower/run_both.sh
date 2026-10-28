#!/usr/bin/env bash
set -euo pipefail
analysis_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${ECG_SIM_ONLY:-0} == 0 ]]; then command -v python3 >/dev/null; fi
mkdir -p "$analysis_dir/runs"
pair_dir=$(mktemp -d "$analysis_dir/runs/pair_XXXXXX")
echo "Comparison directory: $pair_dir"
bash "$analysis_dir/run_case.sh" gated_500hz "$pair_dir/gated_500hz"
bash "$analysis_dir/run_case.sh" ungated_100khz "$pair_dir/ungated_100khz"
if [[ ${ECG_SIM_ONLY:-0} == 0 ]]; then
  python3 "$analysis_dir/summarize.py" "$pair_dir"
else
  echo 'Simulation-only run; no power comparison was computed.'
fi
