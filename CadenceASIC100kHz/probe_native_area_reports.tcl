file mkdir reports
foreach command {report_area reportGateCount summaryReport report_summary report_design_area} {
    set target [file join reports ${command}_help.txt]
    if {[catch {redirect -file $target [list help $command]} message]} {
        puts "AREA_HELP_UNAVAILABLE $command: $message"
    } else {puts "AREA_HELP_GENERATED $command"}
}
puts "Native area reporting commands: [lsort [info commands *area*]]"
puts "Native gate reporting commands: [lsort [info commands *GateCount*]]"
exit 0
