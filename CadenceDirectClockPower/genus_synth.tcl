# Direct-clock, core-only estimate. No FPGA clock-generation model is present.
proc required_env {name} {
    if {![info exists ::env($name)] || $::env($name) eq ""} {error "Set $name"}
    return $::env($name)
}
set analysis_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [required_env ECG_RTL_DIR]]
set lib [file normalize [required_env ECG_LIB]]
set mode [required_env ECG_MODE]
if {$mode ni {gated_500hz ungated_100khz}} {error "Invalid direct-clock mode"}
set source_hz [expr {$mode eq "gated_500hz" ? 500 : 100000}]
set vcd [file normalize [required_env ECG_VCD]]
foreach path [list $lib $vcd] {if {![file isfile $path]} {error "Missing file: $path"}}
set config_path [file join [file dirname $vcd] config.txt]
set audit_path [file join [file dirname $vcd] capture_validation.txt]
foreach {path variable} [list $config_path config_text $audit_path audit_text] {
    if {![file isfile $path]} {error "Missing provenance: $path"}
    set handle [open $path r]; set $variable [read $handle]; close $handle
}
foreach expected [list "mode=$mode" "source_hz=$source_hz" "direct_clock=1" "workload=normal" \
    "capture_validation=PASS" "capture_bounded=1" "vcd_time_origin=0"] {
    if {![regexp -line "^${expected}$" $config_text]} {error "Capture mismatch: expected $expected"}
}
if {![regexp -line {^capture_duration_ns=([0-9]+)$} $config_text -> duration_ns] ||
    $duration_ns<1000000000 || ![regexp -line {^capture_validation=PASS$} $audit_text] ||
    ![regexp -line "^duration_ns=${duration_ns}$" $audit_text]} {error "Invalid capture audit"}
file mkdir reports
file copy -force $audit_path reports/capture_validation.txt
set_db library [list $lib]
if {$mode eq "gated_500hz" && [llength [get_db lib_cells *TLATNCAX12]]==0} {error "Missing native ICG cell"}
set handle [open [file join $analysis_dir rtl files.f] r]
set hdl_files {}
foreach entry [split [read $handle] "\n"] {
    set entry [string trim $entry]
    if {$entry eq ""} {continue}
    set path [file join $rtl_dir $entry]
    if {![file isfile $path]} {error "Missing RTL: $path"}
    lappend hdl_files $path
}
close $handle
lappend hdl_files [file join $analysis_dir rtl asic_clock_primitives.v]
lappend hdl_files [file join $analysis_dir rtl ecg_direct_power_top.v]
set read_args [list -sv]
if {$mode eq "ungated_100khz"} {lappend read_args -define ECG_DIRECT_UNGATED}
read_hdl {*}$read_args $hdl_files
elaborate ecg_direct_power_top
check_design -unresolved > reports/unresolved.rpt
source [file join $analysis_dir constraints core.sdc]
read_vcd -static -vcd_scope ecg_direct_power_tb/dut $vcd
set_db syn_generic_effort medium
set_db syn_map_effort medium
set_db syn_opt_effort medium
syn_generic
syn_map
syn_opt
check_design -unresolved > reports/mapped_unresolved.rpt
report_area > reports/area.rpt
report_gates > reports/gates.rpt
report_timing > reports/timing.rpt
report_clocks > reports/clocks.rpt
check_timing_intent > reports/timing_intent.rpt
write_hdl > mapped.v
write_sdc > mapped.sdc
report_power > reports/preliminary_power.rpt
set handle [open reports/activity_audit_status.txt w]
if {[llength [info commands report_sdb_annotation]]==0} {
    puts $handle "report_sdb_annotation: UNAVAILABLE; coverage not verified"
} elseif {[catch {report_sdb_annotation > reports/mapped_annotation.rpt} message]} {
    puts $handle "report_sdb_annotation: FAILED: $message"
} else {puts $handle "report_sdb_annotation: GENERATED; review coverage"}
close $handle
set handle [open reports/analysis_notes.txt w]
puts $handle "mode=$mode; source_hz=$source_hz; sample_hz=120; direct_clock=1"
puts $handle "library=$lib"
puts $handle "activity=$vcd; capture_duration_ns=$duration_ns"
puts $handle "Pipeline-only ASIC estimate; no divider, mailbox or external clock generator"
puts $handle "No physical CTS/routing, SRAM macro or IO-load/driver model"
puts $handle "Normal-only combined frequency-and-gating comparison, not isolated gating savings"
close $handle
puts "Analysis script completed. Not physical power/timing sign-off."
quit
