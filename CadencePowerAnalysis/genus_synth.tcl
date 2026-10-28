# Genus Common UI bring-up / preliminary RTL-activity power estimate.
# Run from a new output directory: genus -del_scale 10 -files /path/genus_synth.tcl
# Never include sim/gsclib_icg_functional.v in this flow.
proc required_env {name} {
    if {![info exists ::env($name)] || $::env($name) eq ""} {
        error "Set environment variable $name"
    }
    return $::env($name)
}
set analysis_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [required_env ECG_RTL_DIR]]
set lib [file normalize [required_env ECG_LIB]]
if {![file isfile $lib]} {error "Library not found: $lib"}
set mode adaptive_gated
if {[info exists ::env(ECG_MODE)]} {set mode $::env(ECG_MODE)}
if {$mode ni {fixed_ungated fixed_gated adaptive_gated}} {error "Invalid ECG_MODE"}
file mkdir reports
set_db library [list $lib]
if {[llength [get_db lib_cells *TLATNCAX12]] == 0} {
    error "TLATNCAX12 was not found in the loaded Liberty library"
}
set source_list [open [file join $rtl_dir rtl files.f] r]
set hdl_files {}
foreach entry [split [read $source_list] "\n"] {
    set entry [string trim $entry]
    if {$entry eq ""} {continue}
    set source [file join $rtl_dir $entry]
    if {![file isfile $source]} {error "Missing RTL: $source"}
    lappend hdl_files $source
}
close $source_list
lappend hdl_files [file join $analysis_dir rtl asic_clock_primitives.v]
lappend hdl_files [file join $analysis_dir rtl ecg_asic_power_top.v]
set read_args [list -sv]
if {$mode ne "adaptive_gated"} {lappend read_args -define ECG_FIXED_CLOCK}
if {$mode eq "fixed_ungated"} {lappend read_args -define ECG_NO_CLOCK_GATING}
read_hdl {*}$read_args $hdl_files
elaborate ecg_asic_power_top
check_design -unresolved > reports/unresolved.rpt
source [file join $analysis_dir constraints core.sdc]

set activity_description "NONE: no power report will be generated"
if {[info exists ::env(ECG_VCD)] && $::env(ECG_VCD) ne ""} {
    set vcd [file normalize $::env(ECG_VCD)]
    if {![file isfile $vcd]} {error "VCD not found: $vcd"}
    # Only prepare_power_capture.sh outputs have validated bounded provenance.
    set config_path [file join [file dirname $vcd] config.txt]
    if {![file isfile $config_path]} {error "Missing activity provenance: $config_path"}
    set config_handle [open $config_path r]
    set config_text [read $config_handle]
    close $config_handle
    if {![regexp -line {^quick=0$} $config_text] ||
        ![regexp -line "^mode=${mode}$" $config_text] ||
        ![regexp -line {^vcd_time_origin=0$} $config_text] ||
        ![regexp -line {^capture_bounded=1$} $config_text] ||
        ![regexp -line {^capture_validation=PASS$} $config_text] ||
        ![regexp -line {^source_hz=100000000$} $config_text]} {
        error "VCD must be full-rate, bounded, clock-validated and from the same ECG_MODE; run prepare_power_capture.sh"
    }
    if {![regexp -line {^capture_duration_ns=([0-9]+)$} $config_text -> duration_ns] ||
        $duration_ns < 1000000000} {error "Power capture must span at least one full stride"}
    set capture_audit [file join [file dirname $vcd] capture_validation.txt]
    if {![file isfile $capture_audit]} {error "Missing capture_validation.txt"}
    set audit_handle [open $capture_audit r]
    set audit_text [read $audit_handle]
    close $audit_handle
    if {![regexp -line {^capture_validation=PASS$} $audit_text] ||
        ![regexp -line "^duration_ns=${duration_ns}$" $audit_text]} {
        error "Capture audit does not match VCD provenance"
    }
    file copy -force $capture_audit reports/capture_validation.txt
    # Apply RTL activity before mapping so Genus can propagate through mapping.
    # Verify this command's syntax/annotation summary in installed Genus 25.1.
    # Failure is fatal; there is no silent vectorless-power fallback.
    read_vcd -static -vcd_scope ecg_asic_power_tb/dut $vcd
    set activity_description $vcd
}
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
report_clocks -generated > reports/generated_clocks.rpt
check_timing_intent > reports/timing_intent.rpt
write_hdl > mapped.v
write_sdc > mapped.sdc
if {$activity_description ne "NONE: no power report will be generated"} {
    report_power > reports/preliminary_power.rpt
    # These are diagnostic reports, never a vectorless fallback. Some Genus
    # installations do not expose all Joules report commands. Record failures
    # explicitly; a completed power report is not a passed coverage audit.
    set audit_status [open reports/activity_audit_status.txt w]
    foreach {command report_file} {
        report_activity reports/mapped_activity.rpt
        report_sdb_annotation reports/mapped_annotation.rpt
    } {
        if {[llength [info commands $command]] == 0} {
            puts $audit_status "$command: UNAVAILABLE; inspect installed Genus help before accepting power"
        } elseif {[catch {$command > $report_file} message]} {
            puts $audit_status "$command: FAILED: $message"
        } else {
            puts $audit_status "$command: GENERATED; human coverage review still required"
        }
    }
    close $audit_status
}
set meta [open reports/analysis_notes.txt w]
puts $meta "mode=$mode"
puts $meta "library=$lib"
puts $meta "activity=$activity_description"
if {$activity_description ne "NONE: no power report will be generated"} {
    puts $meta "capture_bounded=1; capture_duration_ns=$duration_ns"
}
puts $meta "source_hz=100000000; sample_hz=120; processing_hz=500/100000"
puts $meta "ASIC estimate only; no physical CTS, routed parasitics or SRAM macro"
puts $meta "TLATNCAX12 adapter; no FPGA clock-buffer power model"
puts $meta "Inspect unresolved references, timing, activity annotation and clock rates"
puts $meta "Full-rate and adaptive policies can select different sample spans"
close $meta
puts "Analysis script completed. This is not power/timing/CDC sign-off."
quit
