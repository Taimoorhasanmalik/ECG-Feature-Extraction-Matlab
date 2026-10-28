set package_dir [file dirname [file dirname [file normalize [info script]]]]
set project_dir [file join $package_dir vivado_adaptive_project]
set project_file [file join $project_dir two_stage_adaptive.xpr]
set ::ADAPTIVE_CLOCK 1
if {[file exists $project_file]} {
    file mkdir [file join $project_dir two_stage_adaptive.gen sources_1]
    open_project $project_file
} else {
    create_project two_stage_adaptive $project_dir -part xc7a35tcpg236-1
}
set_property target_language Verilog [current_project]
foreach source_file [concat \
    [glob [file join $package_dir rtl *.v]] \
    [glob [file join $package_dir stage1_hdl *.v]] \
    [list [file join $package_dir mem_vectors synthetic_two_stage_demo_q3_8.mem]]] {
    if {[llength [get_files -quiet $source_file]]==0} {add_files -norecurse $source_file}
}
set xdc [file join $package_dir constraints two_stage_adaptive_basys3.xdc]
if {[llength [get_files -quiet $xdc]]==0} {add_files -fileset constrs_1 -norecurse $xdc}
set_property top basys3_two_stage_adaptive_top [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "Adaptive project ready: $project_file"
if {$argc>0} {
    if {$argc!=1 || [lindex $argv 0] ne "verify"} {error "Use optional argument verify"}
    synth_design -top basys3_two_stage_adaptive_top -part xc7a35tcpg236-1
    report_clocks
    puts "Adaptive project-context synthesis passed"
    close_design
}
close_project
