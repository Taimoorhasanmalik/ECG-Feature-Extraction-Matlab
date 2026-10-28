// Analysis wrapper around the unmodified selected final core.
// ECG_FIXED_CLOCK selects fixed 100 kHz; ECG_NO_CLOCK_GATING disables the
// explicit clock gates only, not window scheduling or data/write enables.
module ecg_asic_power_top #(
    parameter integer SOURCE_HZ = 100000000
) (
    input wire source_clk, resetn, sample_valid,
    input wire signed [31:0] sample_q16_16,
    output wire sample_ready, input_overflow,
    output wire processing_clk, clock_ready, fast_mode, processing_fast_request,
    output wire class_valid, class_is_stage2, classifier_clock_enabled,
    output wire [31:0] class_window_id,
    output wire [1:0] class_code,
    output wire stage1_window_overflow, stage2_window_overflow, classifier_overflow
);
`ifdef ECG_FIXED_CLOCK
    localparam integer ADAPTIVE = 0;
`else
    localparam integer ADAPTIVE = 1;
`endif
`ifdef ECG_NO_CLOCK_GATING
    localparam integer GATING = 0;
`else
    localparam integer GATING = 1;
`endif
    two_stage_adaptive_clock_top #(
        .SOURCE_HZ(SOURCE_HZ), .ADAPTIVE_CLOCK(ADAPTIVE),
        .STAGE1_FULL_RATE(0), .CLOCK_GATING(GATING)
    ) core (
        .source_clk(source_clk), .resetn(resetn),
        .sample_valid(sample_valid), .sample_q16_16(sample_q16_16),
        .sample_ready(sample_ready), .input_overflow(input_overflow),
        .processing_clk(processing_clk), .clock_ready(clock_ready),
        .fast_mode(fast_mode), .processing_fast_request(processing_fast_request),
        .class_valid(class_valid), .class_is_stage2(class_is_stage2),
        .classifier_clock_enabled(classifier_clock_enabled),
        .class_window_id(class_window_id), .class_code(class_code),
        .stage1_window_overflow(stage1_window_overflow),
        .stage2_window_overflow(stage2_window_overflow),
        .classifier_overflow(classifier_overflow)
    );
endmodule
