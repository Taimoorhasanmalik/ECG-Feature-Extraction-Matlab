#!/usr/bin/env bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
mkdir -p "$package_dir/runs"
run_dir=$(mktemp -d "$package_dir/runs/synth_XXXXXX")
printf 'Synthesis directory: %s\n' "$run_dir"
cd -- "$run_dir"
genus -del_scale 10 -files "$package_dir/genus_synth.tcl" -log genus.log 2>&1 | tee console.log
test -s mapped.v
test -s mapped.sdc
grep -q 'ASIC 100 kHz synthesis completed' console.log
printf 'Synthesis completed: %s\n' "$run_dir"
