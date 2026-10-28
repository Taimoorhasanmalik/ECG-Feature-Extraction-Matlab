# Selected Liberty units are ns. There is exactly one primary clock.
if {$mode eq "gated_500hz"} {set period_ns 2000000.0} else {set period_ns 10000.0}
create_clock -name direct_clock -period $period_ns [get_ports source_clk]
set_input_delay 1.0 -clock direct_clock [get_ports {sample_valid sample_q16_16*}]
set_output_delay 1.0 -clock direct_clock [get_ports {
    class_valid class_is_stage2 class_window_id* class_code*
    classifier_clock_enabled processing_fast_request
    stage1_window_overflow stage2_window_overflow classifier_overflow}]
# No generated clocks, divider, mailbox, clock mux or source-domain CDC.
# External clock generation, physical CTS/routing and IO drivers/loads are
# outside this first-pass core-only estimate. Reset integration needs review.
