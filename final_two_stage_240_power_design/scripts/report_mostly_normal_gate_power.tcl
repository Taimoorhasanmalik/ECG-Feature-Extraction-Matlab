# Core-only, 240-entry gated (1) versus always-on (0) power comparison.
# Run after mostly_normal_power_saif.tcl generated the common SAIF file.
# Usage: vivado -mode batch -source this_file -tclargs 0|1
if {$argc != 1 || [lindex $argv 0] ni {0 1}} {
    error "Usage: report_mostly_normal_gate_power.tcl 0|1"
}
set gate_mode [lindex $argv 0]
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set report_dir [file join $package_dir power_comparison]
set saif_file [file join $report_dir mostly_normal_240.saif]
if {![file exists $saif_file]} {error "Missing activity file: $saif_file"}
if {$gate_mode} {
    set label idle_gated_240
    set sim_instance gated
} else {
    set label idle_always_on_240
    set sim_instance always_on
}

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
    -generic CLOCK_GATING=$gate_mode
create_clock -name clk_processing -period 10000 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $::env(TEMP) ${label}_routed.dcp]
report_utilization -file [file join $report_dir ${label}_utilization.rpt]
report_timing_summary -file [file join $report_dir ${label}_timing.rpt]
read_saif -strip_path mostly_normal_power_tb/$sim_instance \
    -out_file [file join $report_dir ${label}_saif_mapping.rpt] $saif_file
report_power -hier all -file [file join $report_dir ${label}_power_saif.rpt]
report_power -format xml -file [file join $report_dir ${label}_power_saif.xml]
puts "Completed $label with activity from $sim_instance"
