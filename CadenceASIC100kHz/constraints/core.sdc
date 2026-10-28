# Units ns. One external 100 kHz master; no 100 MHz clock exists.
create_clock -name source_100khz -period 10000.0 [get_ports source_clk]
set processing_pin [get_pins core/low_power_clock/clock_buffer/O]
if {[sizeof_collection $processing_pin]!=1} {error "Missing ASIC processing ICG output"}
create_generated_clock -name processing_fast -source [get_ports source_clk] \
    -divide_by 1 $processing_pin
# The slow clock passes one full source pulse per 200 cycles. Its high time
# is 5000 ns, NOT the 1000000 ns implied by a 50%-duty divide_by 200 clock.
if {$mode eq "adaptive_gated"} {
    create_generated_clock -name processing_slow -source [get_ports source_clk] \
        -master_clock source_100khz -edges {1 2 401} -add $processing_pin
    set_clock_groups -physically_exclusive \
        -group [get_clocks processing_fast] -group [get_clocks processing_slow]
}
set_input_delay 1.0 -clock source_100khz [get_ports {sample_valid sample_q16_16*}]
set_output_delay 1.0 -clock source_100khz [get_ports {sample_ready input_overflow}]
set_output_delay 1.0 -clock processing_fast \
    [get_ports {class_valid class_is_stage2 classifier_clock_enabled class_window_id* \
        class_code* clock_ready fast_mode processing_fast_request stage1_window_overflow \
        stage2_window_overflow classifier_overflow}]
# No blanket reset or CDC exceptions. External IO driver/load assumptions,
# generated-clock gating checks and mode transitions require implementation review.
