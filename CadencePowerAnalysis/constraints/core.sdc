# First-pass ASIC constraints, units ns (selected Liberty time_unit=1ns).
# No FPGA pin constraints. No broad source/processing asynchronous waiver.
create_clock -name source_100mhz -period 10.0 [get_ports source_clk]
set processing_pin [get_pins core/low_power_clock/clock_buffer/O]
if {[sizeof_collection $processing_pin] == 0} {
    error "Cannot locate divided-clock pin; inspect the elaborated hierarchy"
}
create_generated_clock -name processing_fast -source [get_ports source_clk] \
    -divide_by 1000 $processing_pin
if {$mode eq "adaptive_gated"} {
    create_generated_clock -name processing_slow -source [get_ports source_clk] \
        -master_clock source_100mhz -divide_by 200000 -add $processing_pin
    set_clock_groups -physically_exclusive \
        -group [get_clocks processing_fast] -group [get_clocks processing_slow]
}
set_input_delay 1.0 -clock source_100mhz \
    [get_ports {sample_valid sample_q16_16*}]
set_output_delay 1.0 -clock source_100mhz \
    [get_ports {sample_ready input_overflow}]
set_output_delay 1.0 -clock processing_fast \
    [get_ports {class_valid class_is_stage2 classifier_clock_enabled \
        class_window_id* class_code* clock_ready fast_mode \
        processing_fast_request stage1_window_overflow stage2_window_overflow \
        classifier_overflow}]
# No guessed broad CDC exceptions. First-stage synchronizers, reset recovery,
# bundled mailbox data delays and physical clock-gate timing require a later
# implementation-specific constraints/CDC review. Timing may flag these here.
# Physical IO drivers/loads and post-CTS clock-tree power are not modeled.
