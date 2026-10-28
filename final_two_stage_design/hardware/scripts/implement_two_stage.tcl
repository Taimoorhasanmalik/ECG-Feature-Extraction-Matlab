source [file join [file dirname [file normalize [info script]]] synth_two_stage.tcl]
opt_design
place_design
phys_opt_design
route_design
report_utilization
report_timing_summary
