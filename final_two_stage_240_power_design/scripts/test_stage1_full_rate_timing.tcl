# Route the experimental one-sample-per-clock Stage 1 replay core at 100 kHz.
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set report_dir [file join $package_dir stage1_full_rate_test]
file mkdir $report_dir
create_project -in_memory -part xc7a35tcpg236-1
foreach name [list 01_highpass_iir_filter.v 02_window_sequencer.v] {
    add_files -norecurse [file join $package_dir stage1_hdl $name]
}
foreach name [list stage2_filter_q29.v stage2_shared_hp1_q29.v \
        stage2_classifier_gated_q.v shared_classifier_mac_q.v \
        two_stage_shared_replay_top.v] {
    add_files -norecurse [file join $package_dir rtl $name]
}
set_property top two_stage_shared_replay_top [current_fileset]
update_compile_order -fileset sources_1
synth_design -top two_stage_shared_replay_top -part xc7a35tcpg236-1 \
    -generic SHARED_HP1_MODEL=1 -generic DEEP_HISTORY=0 \
    -generic CLOCK_GATING=1 -generic STAGE1_FULL_RATE=1
create_clock -name clk_processing -period 10000 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $report_dir full_rate_utilization.rpt]
report_timing_summary -file [file join $report_dir full_rate_timing.rpt]
puts "Completed Stage 1 full-rate core-only routed timing test"
