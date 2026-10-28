// Acquisition is synchronous to source_clk and independent of processing
// speed. Results are synchronous to processing_clk (exposed for integration).
// ADAPTIVE_CLOCK=0 is the matched fixed-100-kHz cost-comparison baseline.
module two_stage_adaptive_clock_top #(
    parameter integer SOURCE_HZ=100000000,
    parameter integer ADAPTIVE_CLOCK=1,
    parameter integer STAGE1_FULL_RATE=0,
    parameter integer CLOCK_GATING=1
) (
    input wire source_clk,resetn,sample_valid,
    input wire signed [31:0] sample_q16_16,
    output wire sample_ready,input_overflow,
    output wire processing_clk,clock_ready,fast_mode,processing_fast_request,
    output wire class_valid,class_is_stage2,classifier_clock_enabled,
    output wire [31:0] class_window_id,
    output wire [1:0] class_code,
    output wire stage1_window_overflow,stage2_window_overflow,classifier_overflow
);
    ecg_adaptive_clock #(.SOURCE_HZ(SOURCE_HZ),
        .SLOW_HZ(ADAPTIVE_CLOCK ? 500 : 100000)) low_power_clock (
        .source_clk(source_clk),.resetn(resetn),
        .fast_request(ADAPTIVE_CLOCK ? processing_fast_request : 1'b1),
        .processing_clk(processing_clk),.fast_mode(fast_mode),
        .clock_ready(clock_ready)
    );
    wire pipeline_resetn=resetn && clock_ready;
    wire delivered_valid;
    wire signed [31:0] delivered_data;
    ecg_sample_mailbox mailbox (
        .source_clk(source_clk),.processing_clk(processing_clk),
        .resetn(pipeline_resetn),.sample_valid(sample_valid),
        .sample_data(sample_q16_16),.sample_ready(sample_ready),
        .overflow(input_overflow),.processing_valid(delivered_valid),
        .processing_data(delivered_data)
    );
    two_stage_shared_replay_top #(.SHARED_HP1_MODEL(1),.DEEP_HISTORY(0),
        .CLOCK_GATING(CLOCK_GATING),.STAGE1_FULL_RATE(STAGE1_FULL_RATE)) pipeline (
        .clk(processing_clk),.resetn(pipeline_resetn),
        .sample_valid(delivered_valid),.sample_q16_16(delivered_data),
        .class_valid(class_valid),.class_window_id(class_window_id),
        .class_code(class_code),.class_is_stage2(class_is_stage2),
        .classifier_clock_enabled(classifier_clock_enabled),
        .stage1_window_overflow(stage1_window_overflow),
        .stage2_window_overflow(stage2_window_overflow),
        .classifier_overflow(classifier_overflow),
        .processing_fast_request(processing_fast_request)
    );
endmodule
