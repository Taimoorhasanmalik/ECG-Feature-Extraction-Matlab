# Report-only restore. No optimization, netlist edits or checkpoint writes.
set output [pwd]
if {[catch {
    if {![info exists ::env(ECG_ASIC_ROUTED_DIR)]} {error "Set ECG_ASIC_ROUTED_DIR"}
    set routed [file normalize $::env(ECG_ASIC_ROUTED_DIR)]
    set checkpoint [file join $routed checkpoints post_route.enc.dat]
    if {![file isdirectory $checkpoint]} {error "Missing accepted checkpoint"}
    restoreDesign $checkpoint ecg_asic_power_top
    cd $output
    if {[dbGet top.name] ne "ecg_asic_power_top" || ![dbGet top.statusDetailRouted]} {
        error "Expected the routed full-core database"
    }
    file mkdir reports
    report_area -detail -depth 3 -out_file reports/innovus_postroute_area.rpt
    report_area -detail -depth 3 -include_physical \
        -out_file reports/innovus_postroute_area_including_physical.rpt
    reportGateCount -level 3 -stdCellOnly -outfile reports/innovus_postroute_gate_count.rpt
    foreach name {innovus_postroute_area.rpt innovus_postroute_area_including_physical.rpt innovus_postroute_gate_count.rpt} {
        set path [file join reports $name]
        if {![file isfile $path] || [file size $path] == 0} {error "Empty native report: $name"}
    }
    set handle [open reports/report_source.txt w]
    puts $handle "source_routed=$routed\nrestored_checkpoint=$checkpoint"
    puts $handle "Report-only restore of accepted routed database; no implementation changes"
    puts $handle "Area reports are emitted by native report_area, not a scripted cell-area table"
    close $handle
} message options]} {
    puts stderr "NATIVE AREA REPORT FAILED: $message"
    if {[dict exists $options -errorinfo]} {puts stderr [dict get $options -errorinfo]}
    exit 1
}
puts "NATIVE POST-ROUTE AREA REPORTS GENERATED"
exit 0
