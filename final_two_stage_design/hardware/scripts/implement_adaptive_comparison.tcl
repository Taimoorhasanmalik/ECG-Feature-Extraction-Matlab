# Matched board wrappers, acquisition and mailbox in both. Only divider
# policy differs. No SAIF-based power claim is made by this area experiment.
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set report_dir [file join $package_dir adaptive_clock_test]
file mkdir $report_dir
set modes {0 1}
if {$argc>0} {set modes $argv}
foreach mode $modes {
    if {$mode ni {0 1}} {error "Use optional mode arguments 0 and/or 1"}
    set ::ADAPTIVE_CLOCK $mode
    create_project -in_memory -part xc7a35tcpg236-1
    add_files -norecurse [glob [file join $package_dir rtl *.v]]
    add_files -norecurse [glob [file join $package_dir stage1_hdl *.v]]
    add_files -norecurse [file join $package_dir mem_vectors synthetic_two_stage_demo_q3_8.mem]
    synth_design -top basys3_two_stage_adaptive_top -part xc7a35tcpg236-1 \
        -generic ADAPTIVE_CLOCK=$mode
    read_xdc [file join $package_dir constraints two_stage_adaptive_basys3.xdc]
    report_utilization -hierarchical -file [file join $report_dir mode${mode}_synth_utilization.rpt]
    opt_design
    foreach {name period} {processing_fast 10000 processing_slow 2000000} {
        if {[llength [get_clocks -quiet $name]]!=1 ||
            abs([get_property PERIOD [get_clocks $name]]-$period)>1.0} {
            error "Missing or incorrect processing constraint: $name"
        }
    }
    place_design
    route_design
    report_utilization -hierarchical -file [file join $report_dir mode${mode}_routed_utilization.rpt]
    report_utilization -file [file join $report_dir mode${mode}_resources.rpt]
    report_timing_summary -file [file join $report_dir mode${mode}_timing.rpt]
    report_cdc -details -file [file join $report_dir mode${mode}_cdc.rpt]
    report_drc -file [file join $report_dir mode${mode}_drc.rpt]
    report_clocks -file [file join $report_dir mode${mode}_clocks.rpt]
    if {[llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0]] ||
        [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0]]} {
        error "Routed timing failed for mode $mode; inspect reports"
    }
    close_project
}
