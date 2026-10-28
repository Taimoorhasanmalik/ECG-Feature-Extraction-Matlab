# Run one board-level implementation and a preliminary, vectorless Vivado
# power estimate. Usage: vivado -mode batch -source this_file -tclargs 0|1
# Mode 0 is the 512-entry/1 kHz shared-HP1 design; mode 1 is the 240-entry/
# 100 kHz shared-HP1 design. Filter and classifier coefficients are identical.
if {$argc != 1 || [lindex $argv 0] ni {0 1}} {
    error "Usage: report_clock_buffer_tradeoff.tcl 0|1"
}
set mode [lindex $argv 0]
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set report_dir [file join $package_dir power_comparison]
file mkdir $report_dir
if {$mode == 0} {
    set label shared_512_1khz
    set divide_by 100000
} else {
    set label shared_240_100khz
    set divide_by 1000
}
set ::PROCESSING_CLOCK_DIVIDE_BY $divide_by

create_project -in_memory -part xc7a35tcpg236-1
foreach name [list \
        01_highpass_iir_filter.v 02_window_sequencer.v \
        03_window_sum_bank.v 04_mean_abs_threshold_replay_accumulator.v \
        05_mean_abs_threshold_bank.v 07_diff_line_zero_bank.v \
        12_clock_wizard_detector_wrapper.v 14_ecg_bram_demo_source.v] {
    add_files -norecurse [file join $package_dir stage1_hdl $name]
}
foreach name [list \
        stage1_fixed_path.v stage2_filter_q29.v stage2_shared_hp1_q29.v \
        stage2_features_q.v stage2_classifier_gated_q.v shared_classifier_mac_q.v \
        two_stage_ecg_top.v two_stage_shared_replay_top.v ecg_clock_1khz.v \
        basys3_two_stage_top.v] {
    add_files -norecurse [file join $package_dir rtl $name]
}
add_files -norecurse [file join $package_dir mem_vectors synthetic_two_stage_demo_q3_8.mem]
add_files -fileset constrs_1 -norecurse \
    [file join $package_dir constraints two_stage_basys3.xdc]
set_property top basys3_two_stage_top [current_fileset]
update_compile_order -fileset sources_1
synth_design -top basys3_two_stage_top -part xc7a35tcpg236-1 \
    -generic SHARED_HP1_MODEL=1 -generic DEEP_HISTORY=[expr {!$mode}]
set actual_period [get_property PERIOD [get_clocks clk_processing]]
set expected_period [expr {10.0*$divide_by}]
if {abs($actual_period-$expected_period) > 1.0} {
    error "Incorrect processing-clock constraint: $actual_period vs $expected_period ns"
}
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $report_dir ${label}_utilization.rpt]
report_timing_summary -file [file join $report_dir ${label}_timing.rpt]

# No SAIF is currently available for these two implementations. Use the same
# vectorless defaults for both, and mark the result as an estimate, not a
# measured ECG-workload power saving or a clock-gating ablation.
report_power -file [file join $report_dir ${label}_power_vectorless.rpt]
puts "Completed $label: routed utilization, timing, and vectorless power"
