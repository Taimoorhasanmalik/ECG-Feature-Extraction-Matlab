# Run from any directory, using Vivado batch or its Tcl console.
# Direct synthesis avoids reliance on a platform-specific launch_runs wrapper.
set finalrtl_script_dir [file dirname [file normalize [info script]]]
source [file join $finalrtl_script_dir add_files.tcl]
set finalrtl_report_dir [file join $finalrtl_script_dir reports]
file mkdir $finalrtl_report_dir
synth_design -top basys3_two_stage_adaptive_top -part xc7a35tcpg236-1 \
    -generic {ADAPTIVE_CLOCK=1 STAGE1_FULL_RATE=0}

set finalrtl_blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $finalrtl_blackboxes] != 0} {
    error "Synthesis left unresolved black boxes: $finalrtl_blackboxes"
}
foreach {clock_name expected_period} {clk_100mhz 10 processing_fast 10000 processing_slow 2000000} {
    set finalrtl_clock [get_clocks -quiet $clock_name]
    if {[llength $finalrtl_clock] != 1 ||
        abs([get_property PERIOD $finalrtl_clock] - $expected_period) > 1.0} {
        error "Missing or incorrect clock: $clock_name"
    }
}
report_utilization -file [file join $finalrtl_report_dir synthesis_utilization.rpt]
report_utilization -hierarchical -file [file join $finalrtl_report_dir synthesis_hierarchy.rpt]
report_clocks -file [file join $finalrtl_report_dir synthesis_clocks.rpt]
report_timing_summary -report_unconstrained -file [file join $finalrtl_report_dir synthesis_timing.rpt]
report_drc -file [file join $finalrtl_report_dir synthesis_drc.rpt]
write_checkpoint -force [file join $finalrtl_report_dir final_ecg_synth.dcp]
puts "FINAL_RTL_SYNTHESIS_PASS: no unresolved black boxes; all three clocks constrained"
# Remove unused compatibility logic/clock buffers using the normal first
# implementation step. Preserve raw synthesis reports separately: their DRC
# can flag an unused third cascaded gate before this cleanup.
opt_design
report_utilization -file [file join $finalrtl_report_dir optimized_utilization.rpt]
report_drc -file [file join $finalrtl_report_dir optimized_drc.rpt]
write_checkpoint -force [file join $finalrtl_report_dir final_ecg_opt.dcp]
set finalrtl_drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $finalrtl_drc_errors] != 0} {
    error "Post-optimization DRC errors remain; inspect optimized_drc.rpt: $finalrtl_drc_errors"
}
puts "FINAL_RTL_OPTIMIZATION_PASS: post-optimization DRC has no errors"
puts "Reports/checkpoint: $finalrtl_report_dir"
puts "Synthesis is not routed timing, CDC/reset, power or board sign-off."
