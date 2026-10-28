# Original Cadence-generated reports

These are the actual tool reports for the latest complete two-stage ASIC
core with a 100 kHz source. Report contents have not been rewritten into
our own tables. File names have only been made easier to identify.

| Original tool report | Gated, 500 Hz processing | Ungated, 100 kHz processing |
| --- | --- | --- |
| Innovus final routed area | [Area](gated_500Hz/innovus_postroute_area.rpt) | [Area](ungated_100kHz/innovus_postroute_area.rpt) |
| Innovus area including physical cells | [Physical-inclusive area](gated_500Hz/innovus_postroute_area_including_physical.rpt) | [Physical-inclusive area](ungated_100kHz/innovus_postroute_area_including_physical.rpt) |
| Genus synthesis area, pre-layout | [Synthesis area](gated_500Hz/genus_synthesis_area.rpt) | [Synthesis area](ungated_100kHz/genus_synthesis_area.rpt) |
| Innovus routed power | [Power](gated_500Hz/innovus_routed_power.rpt) | [Power](ungated_100kHz/innovus_routed_power.rpt) |
| Innovus setup timing summary | [Setup](gated_500Hz/innovus_setup_summary.rpt) | [Setup](ungated_100kHz/innovus_setup_summary.rpt) |
| Innovus hold timing summary | [Hold](gated_500Hz/innovus_hold_summary.rpt) | [Hold](ungated_100kHz/innovus_hold_summary.rpt) |
| Innovus detailed setup paths | [Setup paths](gated_500Hz/innovus_setup_paths.rpt) | [Setup paths](ungated_100kHz/innovus_setup_paths.rpt) |
| Innovus detailed hold paths | [Hold paths](gated_500Hz/innovus_hold_paths.rpt) | [Hold paths](ungated_100kHz/innovus_hold_paths.rpt) |

Each case also includes native gate-count, slow-corner setup and fast-corner
hold reports. `SHA256_MANIFEST.csv` records the checksums of these files.

## Important distinctions

- `genus_synthesis_area.rpt` is the original Genus output before physical
  implementation. It is not the final routed area.
- `innovus_postroute_area.rpt` is emitted by native Innovus `report_area`
  after restoring the accepted routed database. This is not our earlier
  scripted `area_breakdown.txt` tally.
- The physical-inclusive area report deliberately includes row fillers and
  other physical cells. Do not compare its total to a non-filler cell area.
- The Innovus power report uses **mW**, as stated in its header. Multiply by
  1000 to convert to uW. It is based on the original matched 60 s synthetic
  normal captures at 0.9 V / 125 C, including the full core and clock trees.
- Setup/hold reports are the original accepted post-route timing outputs;
  readable files are lossless decompressions of the tool's `.gz` reports.
- Area reports were requested in a later report-only restore of the same
  accepted checkpoints. No optimization, netlist edits or rerouting were
  performed for this export. The original power/timing analyses were not rerun.

AWS source pair:
`/home/ec2-user/CadenceASIC100kHz/runs/power_pair_vwGzHG`.

Gated routed database: `adaptive_gated/postroute/checkpoints/post_route.enc.dat`.
Ungated routed database:
`fixed_ungated/postroute_repaired/checkpoints/post_route.enc.dat`.
The original failed ungated route is not used.

The root README is an index, not Cadence tool output. The `.rpt` files are
native Genus/Innovus output; they retain the tool headers, units and values.
These are research ASIC estimates, not measured silicon or tape-out sign-off.
