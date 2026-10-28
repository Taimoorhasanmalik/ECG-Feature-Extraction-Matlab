`timescale 1ns/1ps
// Analysis boundary: external source clock directly drives the pipeline.
// No divider, adaptive-clock controller, acquisition mailbox or board logic.
module ecg_direct_power_top (
    input wire source_clk, resetn, sample_valid,
    input wire signed [31:0] sample_q16_16,
    output wire processing_clk, class_valid, class_is_stage2,
    output wire [31:0] class_window_id,
    output wire [1:0] class_code,
    output wire classifier_clock_enabled, processing_fast_request,
    output wire stage1_window_overflow, stage2_window_overflow, classifier_overflow
);
`ifdef ECG_DIRECT_UNGATED
    localparam integer GATING = 0;
`else
    localparam integer GATING = 1;
`endif
    assign processing_clk = source_clk;
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(1), .DEEP_HISTORY(0),
        .CLOCK_GATING(GATING), .STAGE1_FULL_RATE(0)
    ) pipeline (
        .clk(source_clk), .resetn(resetn), .sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16), .class_valid(class_valid),
        .class_is_stage2(class_is_stage2), .class_window_id(class_window_id),
        .class_code(class_code), .classifier_clock_enabled(classifier_clock_enabled),
        .processing_fast_request(processing_fast_request),
        .stage1_window_overflow(stage1_window_overflow),
        .stage2_window_overflow(stage2_window_overflow),
        .classifier_overflow(classifier_overflow)
    );
endmodule
