# Tests Tcl control flow/provenance with explicit tool stubs, NOT Genus itself.
set analysis_dir [file dirname [file dirname [file normalize [info script]]]]
set repository_dir [file dirname $analysis_dir]
if {[info exists ::env(ECG_TEST_TEMP)]} {
    set temp_root $::env(ECG_TEST_TEMP)
} elseif {[info exists ::env(TMPDIR)]} {
    set temp_root $::env(TMPDIR)
} elseif {[info exists ::env(TEMP)]} {
    set temp_root [string map {\\ /} $::env(TEMP)]
} else {
    set temp_root /tmp
}
set test_dir [file join $temp_root ecg_genus_provenance_[pid]_[clock seconds]]
file mkdir $test_dir
proc write_text {path text} {
    set handle [open $path w]
    puts $handle $text
    close $handle
}
proc read_text {path} {
    set handle [open $path r]
    set text [read $handle]
    close $handle
    return $text
}
proc require {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error $message}
}
require {[info complete [read_text [file join $analysis_dir genus_synth.tcl]]]} "Incomplete Tcl script"
# Redirect syntax is interpreted by Genus; here it is just captured as args.
foreach command {set_db read_hdl elaborate check_design create_clock
    create_generated_clock set_clock_groups set_input_delay set_output_delay
    syn_generic syn_map syn_opt report_area report_gates report_timing
    report_clocks check_timing_intent write_hdl write_sdc report_activity quit} {
    proc $command {args} {return ""}
}
proc get_db {args} {return TLATNCAX12}
proc get_pins {args} {return processing_pin}
proc get_ports {args} {return selected_ports}
proc get_clocks {args} {return selected_clocks}
proc sizeof_collection {args} {return 1}
proc read_vcd {args} {incr ::vcd_reads}
proc report_power {args} {incr ::power_reports}
proc report_sdb_annotation {args} {error "Intentional diagnostic-command failure"}
set ::env(ECG_RTL_DIR) [file join $repository_dir FinalRTL]
# Only file existence is tested; get_db/read_hdl/etc above are stubs.
set ::env(ECG_LIB) [file join $analysis_dir README.md]
set ::env(ECG_MODE) adaptive_gated
set config_base "mode=adaptive_gated\nworkload=normal\nquick=0\nvcd_time_origin=0"
set config_valid "$config_base\ncapture_bounded=1\ncapture_validation=PASS\ncapture_duration_ns=1000000000\nsource_hz=100000000"
set test_cases [list \
    [list old_unbounded $config_base "capture_validation=PASS\nduration_ns=1000000000" 0] \
    [list valid $config_valid "capture_validation=PASS\nduration_ns=1000000000" 1] \
    [list wrong_audit $config_valid "capture_validation=PASS\nduration_ns=1027999985" 0] \
    [list wrong_mode [string map {adaptive_gated fixed_gated} $config_valid] "capture_validation=PASS\nduration_ns=1000000000" 0] \
    [list short_capture [string map {1000000000 1000000} $config_valid] "capture_validation=PASS\nduration_ns=1000000" 0]]
foreach test_case $test_cases {
    lassign $test_case label config audit expect_success
    set case_dir [file join $test_dir $label]
    file mkdir $case_dir
    cd $case_dir
    write_text config.txt $config
    write_text capture_validation.txt $audit
    write_text activity.vcd "Dummy file: read_vcd is stubbed in this test."
    set ::env(ECG_VCD) [file join $case_dir activity.vcd]
    set ::vcd_reads 0
    set ::power_reports 0
    set failed [catch {source [file join $analysis_dir genus_synth.tcl]} message]
    require {$failed != $expect_success} "Unexpected result for $label: $message"
    require {$::vcd_reads == $expect_success && $::power_reports == $expect_success} "Invalid provenance reached power engine: $label"
    if {$expect_success} {
        set status [read_text reports/activity_audit_status.txt]
        require {[string match {*report_activity: GENERATED*} $status]} "Missing activity-report status"
        require {[string match {*report_sdb_annotation: FAILED*} $status]} "Diagnostic failure was hidden"
        require {[file isfile reports/capture_validation.txt]} "Capture audit was not copied"
    }
}
puts "PASS: Tcl completeness and stubbed provenance/rejection/diagnostic control-flow checks"
puts "Test outputs: $test_dir"
