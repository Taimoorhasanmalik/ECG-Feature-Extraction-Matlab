# Source this file in an empty/compatible Vivado project, or run it in batch.
# With no project open, create/open FinalRTL/vivado_project/final_ecg.xpr.
# This script adds sources and constraints only; check_synthesis.tcl also
# synthesizes. Simulation primitive substitutes are intentionally excluded.
namespace eval ::ecg_finalrtl {
    variable package_dir [file dirname [file normalize [info script]]]
    variable part xc7a35tcpg236-1
    variable top basys3_two_stage_adaptive_top
    variable rtl_files {}

    proc add_package {} {
        variable package_dir
        variable part
        variable top
        variable rtl_files
        set rtl_files {}
        set list_file [file join $package_dir rtl files.f]
        set handle [open $list_file r]
        set list_text [read $handle]
        close $handle
        foreach line [split $list_text \n] {
            set line [string trim $line]
            if {$line eq "" || [string match {#*} $line]} {continue}
            lappend rtl_files [file normalize [file join $package_dir $line]]
        }
        set memory_file [file join $package_dir mem synthetic_two_stage_demo_q3_8.mem]
        set constraint_file [file join $package_dir constraints two_stage_adaptive_basys3.xdc]
        set required [concat $rtl_files [list $memory_file $constraint_file]]
        foreach source_file $required {
            if {![file isfile $source_file]} {error "Missing package file: $source_file"}
        }
        if {[llength [get_projects -quiet]] == 0} {
            set project_dir [file join $package_dir vivado_project]
            set project_file [file join $project_dir final_ecg.xpr]
            if {[file isfile $project_file]} {
                open_project $project_file
            } else {
                create_project final_ecg $project_dir -part $part
            }
        }
        if {![string equal -nocase [get_property PART [current_project]] $part]} {
            error "Expected FPGA part $part; use an empty project targeting this part."
        }

        # Do not silently replace a user's existing copy of the same module.
        # Also reject a previously added simulation definition of BUFG/BUFGCE.
        foreach existing [get_files -quiet -of_objects [get_filesets sources_1]] {
            set tail [file tail $existing]
            if {[string equal -nocase $tail BUFGCE.v] ||
                [string equal -nocase $tail clock_primitives_sim.v]} {
                error "Simulation clock models are in sources_1: $existing. Remove them from synthesis first."
            }
            foreach source_file $required {
                if {[string equal -nocase $tail [file tail $source_file]] &&
                    ![string equal -nocase [file normalize $existing] [file normalize $source_file]]} {
                    error "Conflicting existing file: $existing. Use an empty project or explicitly remove that copy."
                }
            }
        }

        set_property target_language Verilog [current_project]
        foreach source_file [concat $rtl_files [list $memory_file]] {
            if {[llength [get_files -quiet $source_file]] == 0} {
                add_files -fileset sources_1 -norecurse $source_file
            }
        }
        if {[llength [get_files -quiet $constraint_file]] == 0} {
            add_files -fileset constrs_1 -norecurse $constraint_file
        }
        set_property top $top [get_filesets sources_1]
        set_property generic {ADAPTIVE_CLOCK=1 STAGE1_FULL_RATE=0} [get_filesets sources_1]
        update_compile_order -fileset sources_1
        puts "FINAL_RTL_ADDED: [llength $rtl_files] RTL files, demo memory and board XDC"
        puts "Top: $top; part: $part; adaptive=1; Stage 1 alternate-cycle replay"
        puts "Package: $package_dir"
    }
}
::ecg_finalrtl::add_package
