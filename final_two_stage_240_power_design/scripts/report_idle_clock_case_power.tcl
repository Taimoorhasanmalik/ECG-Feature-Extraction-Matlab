# Diagnostic upper-bound comparison for the inactive Stage 2 state.
# Force both clock-buffer CE pins to their dominant idle state. This drops
# the gated MAC's brief Stage 1 scoring pulses, so it is not the exact 20 s
# workload average; use it only to inspect Vivado's clock-gate modeling.
if {$argc != 1 || [lindex $argv 0] ni {0 1}} {
    error "Usage: report_idle_clock_case_power.tcl 0|1"
}
set mode [lindex $argv 0]
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set report_dir [file join $package_dir power_comparison]
if {$mode} {
    set label idle_gated_240
    set instance gated
    set ce 0
} else {
    set label idle_always_on_240
    set instance always_on
    set ce 1
}
open_checkpoint [file join $::env(TEMP) ${label}_routed.dcp]
read_saif -strip_path mostly_normal_power_tb/$instance \
    [file join $report_dir mostly_normal_240.saif]
set_case_analysis $ce [get_pins stage2_stats_gate/CE0]
set_case_analysis $ce [get_pins mac2/gate/CE0]
report_power -hier all -file [file join $report_dir ${label}_power_case_idle.rpt]
