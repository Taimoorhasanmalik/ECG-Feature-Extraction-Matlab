set package_dir [file dirname [file dirname [file normalize [info script]]]]
create_project -in_memory -part xc7a35tcpg236-1
set stage1 [list \
    01_highpass_iir_filter.v \
    02_window_sequencer.v \
    03_window_sum_bank.v \
    04_mean_abs_threshold_replay_accumulator.v \
    05_mean_abs_threshold_bank.v \
    07_diff_line_zero_bank.v \
    12_clock_wizard_detector_wrapper.v \
    14_ecg_bram_demo_source.v]
foreach name $stage1 {
    add_files -norecurse [file join $package_dir stage1_hdl $name]
}
foreach name [list stage1_fixed_path.v stage2_filter_q29.v stage2_shared_hp1_q29.v stage2_features_q.v \
        stage2_classifier_gated_q.v shared_classifier_mac_q.v two_stage_ecg_top.v \
        two_stage_shared_replay_top.v ecg_clock_1khz.v basys3_two_stage_top.v] {
    add_files -norecurse [file join $package_dir rtl $name]
}
add_files -norecurse [file join $package_dir mem_vectors synthetic_two_stage_demo_q3_8.mem]
add_files -fileset constrs_1 -norecurse [file join $package_dir constraints two_stage_basys3.xdc]
set_property top basys3_two_stage_top [current_fileset]
update_compile_order -fileset sources_1
synth_design -top basys3_two_stage_top -part xc7a35tcpg236-1
report_utilization
report_timing_summary
