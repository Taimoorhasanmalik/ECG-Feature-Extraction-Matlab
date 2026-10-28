# Run with xsim after elaborating mostly_normal_power_tb with -debug typical.
set package_dir [file dirname [file dirname [file normalize [info script]]]]
set saif_file [file join $package_dir power_comparison mostly_normal_240.saif]
open_saif $saif_file
log_saif [get_objects -r *]
run all
close_saif
quit
