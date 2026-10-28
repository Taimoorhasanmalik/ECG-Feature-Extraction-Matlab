# Command-stub control-flow tests. NOT an installed-Genus compatibility test.
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set repo_dir [file dirname $package_dir]
if {[info exists ::env(ECG_TEST_TEMP)]} {set temp_root $::env(ECG_TEST_TEMP)} else {set temp_root /tmp}
set fixture_root [file join $temp_root direct_genus_[pid]_[clock seconds]]
file mkdir $fixture_root
proc write_text {path text} {set handle [open $path w];puts $handle $text;close $handle}
proc read_text {path} {set handle [open $path r];set text [read $handle];close $handle;return $text}
proc assert {condition message} {if {![uplevel 1 [list expr $condition]]} {error $message}}
assert {[info complete [read_text [file join $package_dir genus_synth.tcl]]]} "Incomplete Tcl"
foreach command {set_db read_hdl elaborate check_design create_clock set_input_delay
    set_output_delay syn_generic syn_map syn_opt report_area report_gates report_timing
    report_clocks check_timing_intent write_hdl write_sdc report_sdb_annotation quit} {
    proc $command {args} {return ""}
}
proc get_db {args} {return TLATNCAX12}
proc get_ports {args} {return selected_ports}
proc read_vcd {args} {incr ::reads}
proc report_power {args} {incr ::powers}
set ::env(ECG_RTL_DIR) [file join $repo_dir FinalRTL]
set ::env(ECG_LIB) [file join $package_dir rtl files.f]
foreach fixture {gated_500hz ungated_100khz invalid_source invalid_duration} {
    set ::env(ECG_MODE) [expr {$fixture eq "ungated_100khz" ? "ungated_100khz" : "gated_500hz"}]
    set hz [expr {$::env(ECG_MODE) eq "gated_500hz" ? 500 : 100000}]
    if {$fixture eq "invalid_source"} {set hz 100000000}
    set duration [expr {$fixture eq "invalid_duration" ? 1000 : 60000000000}]
    set output [file join $fixture_root $fixture]
    file mkdir $output
    cd $output
    write_text activity.vcd "Dummy: the stimulus reader is stubbed."
    write_text config.txt "mode=$::env(ECG_MODE)\nsource_hz=$hz\ndirect_clock=1\nworkload=normal\ncapture_bounded=1\ncapture_validation=PASS\nvcd_time_origin=0\ncapture_duration_ns=$duration"
    write_text capture_validation.txt "capture_validation=PASS\nduration_ns=$duration"
    set ::env(ECG_VCD) [file join $output activity.vcd]
    set ::reads 0;set ::powers 0
    set failed [catch {source [file join $package_dir genus_synth.tcl]} message]
    set valid [expr {$fixture in {gated_500hz ungated_100khz}}]
    assert {$failed!=$valid && $::reads==$valid && $::powers==$valid} "Unexpected $fixture result: $message"
}
puts "PASS: both direct-clock Tcl modes and provenance rejection (tool commands stubbed)"
