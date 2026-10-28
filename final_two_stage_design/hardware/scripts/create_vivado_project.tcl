# Create or reopen the persistent Basys 3 project without copying RTL.
# Run from any working directory with Vivado 2020.2:
# vivado -mode batch -source final_two_stage_design/hardware/scripts/create_vivado_project.tcl
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set project_dir [file join $package_dir vivado_project]
set project_file [file join $project_dir two_stage_basys3.xpr]

if {[file exists $project_file]} {
    # Vivado expects this default generated-IP path when reopening projects,
    # even though this design uses no packaged IP.
    file mkdir [file join $project_dir two_stage_basys3.gen sources_1]
    open_project $project_file
} else {
    create_project two_stage_basys3 $project_dir -part xc7a35tcpg236-1
}
set_property target_language Verilog [current_project]

set rtl_files [list \
    [file join $package_dir stage1_hdl 01_highpass_iir_filter.v] \
    [file join $package_dir stage1_hdl 02_window_sequencer.v] \
    [file join $package_dir stage1_hdl 14_ecg_bram_demo_source.v] \
    [file join $package_dir rtl stage2_filter_q29.v] \
    [file join $package_dir rtl stage2_shared_hp1_q29.v] \
    [file join $package_dir rtl stage2_classifier_gated_q.v] \
    [file join $package_dir rtl shared_classifier_mac_q.v] \
    [file join $package_dir rtl two_stage_shared_replay_top.v] \
    [file join $package_dir rtl ecg_clock_1khz.v] \
    [file join $package_dir rtl basys3_two_stage_top.v]]
foreach source_file $rtl_files {
    if {![file exists $source_file]} {
        error "Missing RTL source: $source_file"
    }
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -norecurse $source_file
    }
}

set demo_file [file join $package_dir mem_vectors synthetic_two_stage_demo_q3_8.mem]
if {![file exists $demo_file]} {
    error "Missing demo memory: $demo_file"
}
if {[llength [get_files -quiet $demo_file]] == 0} {
    add_files -norecurse $demo_file
}

set constraints_file [file join $package_dir constraints two_stage_basys3.xdc]
if {![file exists $constraints_file]} {
    error "Missing constraints: $constraints_file"
}
if {[llength [get_files -quiet $constraints_file]] == 0} {
    add_files -fileset constrs_1 -norecurse $constraints_file
}

set_property top basys3_two_stage_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "Vivado project ready: $project_file"
puts "Top: [get_property top [get_filesets sources_1]]"
puts "Part: [get_property part [current_project]]"
if {$argc > 0} {
    set action [lindex $argv 0]
    if {$action ne "verify"} {
        error "Unsupported action '$action'; use no action or 'verify'"
    }
    # A direct project-context synthesis avoids Windows Script Host, which
    # Vivado's launch_runs wrapper needs on some locked-down machines.
    if {[get_property STATUS [get_runs synth_1]] ne "Not started"} {
        reset_run synth_1
    }
    synth_design -top basys3_two_stage_top -part xc7a35tcpg236-1
    puts "Project-context synthesis completed"
    report_utilization
    close_design
}
close_project
