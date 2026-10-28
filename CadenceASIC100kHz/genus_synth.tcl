# Run in a fresh directory with genus -del_scale 10 -files /path/genus_synth.tcl
set package_dir [file dirname [file normalize [info script]]]
set mode adaptive_gated
if {[info exists ::env(ECG_MODE)]} {set mode $::env(ECG_MODE)}
if {$mode ni {adaptive_gated fixed_gated fixed_ungated}} {error "Invalid ECG_MODE"}
set lib /opt/cadence/pdks/gsclib045_svt_v4.8/gsclib045/timing/slow_vdd1v0_basicCells.lib
if {[info exists ::env(ECG_LIB)]} {set lib [file normalize $::env(ECG_LIB)]}
if {![file isfile $lib]} {error "Missing Liberty library"}
file mkdir reports
set_db library [list $lib]
if {[llength [get_db lib_cells *TLATNCAX12]]==0} {error "Missing integrated clock gate"}
set handle [open [file join $package_dir rtl files.f] r]
set sources {}
foreach entry [split [read $handle] "\n"] {
    set entry [string trim $entry]
    if {$entry ne ""} {lappend sources [file join $package_dir $entry]}
}
close $handle
set definitions {SYNTHESIS}
if {$mode ne "adaptive_gated"} {lappend definitions ECG_FIXED_CLOCK}
if {$mode eq "fixed_ungated"} {lappend definitions ECG_NO_CLOCK_GATING}
read_hdl -sv -define $definitions $sources
elaborate ecg_asic_power_top
check_design -unresolved > reports/unresolved.rpt
source [file join $package_dir constraints core.sdc]
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
set handle [open reports/analysis_notes.txt w]
puts $handle "mode=$mode\nlibrary=$lib\nactivity=NONE"
puts $handle "source_hz=100000; sample_hz=120; processing_hz=[expr {$mode eq "adaptive_gated" ? "500/100000" : "100000"}]"
puts $handle "source_clock=source_100khz\nclock_profile=direct100k_pulse_div200"
puts $handle "slow_clock_high_ns=5000; slow_clock_period_ns=2000000"
puts $handle "ASIC native 100 kHz source; no 100 MHz clock or fast-mode divider"
puts $handle "No power claim: fresh routed/gate-activity estimates are required"
close $handle
puts "ASIC 100 kHz synthesis completed; inspect timing, clocks and unresolved reports"
quit
