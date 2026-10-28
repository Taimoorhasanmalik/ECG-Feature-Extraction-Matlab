/*
 * feature_mean_abs_fix_mean_float_bank
 * ------------------------------------
 *
 * Floating-point wrapper for feature_mean_abs_fix_mean_bank.
 *
 * The integer bank matches the MATLAB fix-mean-only feature calculation:
 *
 *   mean_abs_q8 = fix(sum(abs(q_i - fix(sum(q_i) / N))) / N)
 *
 * This wrapper converts that Q3.8 integer to MATLAB's real-valued
 * 16-bit custom floating-point feature (Xilinx E6/F10 format):
 *
 *   mean_abs_float = float(mean_abs_q8) * 1/256
 *   threshold_crossing_count_float = float(threshold_crossing_count)
 *
 * Required Vivado Floating-Point IP modules:
 *
 *   floating_point_1: unsigned 16-bit fixed-to-float
 *   floating_point_2: custom 16-bit E6/F10 floating-point multiply
 */

module feature_mean_abs_fix_mean_float_bank #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer COUNT_WIDTH = $clog2(WINDOW_SAMPLES + 1),
    parameter integer MEAN_ABS_AXIS_WIDTH = 16,
    parameter integer COUNT_AXIS_WIDTH = 16
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    input  wire                           bank_enable,
    input  wire                           window_start,
    input  wire                           window_end,

    output wire                           integer_feature_valid,
    output reg  [15:0]                    mean_abs_float,
    output reg  [15:0]                    threshold_crossing_count_float,
    output reg                            feature_float_valid
);

    localparam [15:0] Q8_TO_FLOAT_SCALE = 16'h2E00;

    wire signed [SAMPLE_WIDTH-1:0] mean_abs_q8;
    wire [COUNT_WIDTH-1:0] threshold_crossing_count;
    wire [MEAN_ABS_AXIS_WIDTH-1:0] mean_abs_q8_axis =
        {{(MEAN_ABS_AXIS_WIDTH-SAMPLE_WIDTH){1'b0}}, mean_abs_q8};
    wire [COUNT_AXIS_WIDTH-1:0] threshold_count_axis =
        {{(COUNT_AXIS_WIDTH-COUNT_WIDTH){1'b0}}, threshold_crossing_count};

    wire [15:0] mean_abs_q8_float;
    wire mean_abs_q8_float_valid;
    wire [15:0] mean_abs_float_internal;
    wire mean_abs_float_valid_internal;
    wire [15:0] threshold_count_float_internal;
    wire threshold_count_float_valid_internal;

    reg mean_abs_pending;
    reg threshold_pending;
    reg [15:0] mean_abs_latched;
    reg [15:0] threshold_latched;

    feature_mean_abs_fix_mean_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .COUNT_WIDTH    (COUNT_WIDTH)
    ) integer_mean_abs_core (
        .clk                      (clk),
        .resetn                   (resetn),
        .sample_in                (sample_in),
        .sample_valid             (sample_valid),
        .bank_enable              (bank_enable),
        .window_start             (window_start),
        .window_end               (window_end),
        .mean_abs_q8              (mean_abs_q8),
        .threshold_crossing_count (threshold_crossing_count),
        .feature_valid            (integer_feature_valid)
    );

    floating_point_1 mean_abs_to_float (
        .aclk                   (clk),
        .s_axis_a_tvalid        (integer_feature_valid),
        .s_axis_a_tdata         (mean_abs_q8_axis),
        .m_axis_result_tvalid   (mean_abs_q8_float_valid),
        .m_axis_result_tdata    (mean_abs_q8_float)
    );

    floating_point_2 mean_abs_scale (
        .aclk                   (clk),
        .s_axis_a_tvalid        (mean_abs_q8_float_valid),
        .s_axis_a_tdata         (mean_abs_q8_float),
        .s_axis_b_tvalid        (mean_abs_q8_float_valid),
        .s_axis_b_tdata         (Q8_TO_FLOAT_SCALE),
        .m_axis_result_tvalid   (mean_abs_float_valid_internal),
        .m_axis_result_tdata    (mean_abs_float_internal)
    );

    floating_point_1 threshold_count_to_float (
        .aclk                   (clk),
        .s_axis_a_tvalid        (integer_feature_valid),
        .s_axis_a_tdata         (threshold_count_axis),
        .m_axis_result_tvalid   (threshold_count_float_valid_internal),
        .m_axis_result_tdata    (threshold_count_float_internal)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mean_abs_float <= 16'd0;
            threshold_crossing_count_float <= 16'd0;
            feature_float_valid <= 1'b0;
            mean_abs_pending <= 1'b0;
            threshold_pending <= 1'b0;
            mean_abs_latched <= 16'd0;
            threshold_latched <= 16'd0;
        end else begin
            feature_float_valid <= 1'b0;

            if (mean_abs_float_valid_internal) begin
                mean_abs_latched <= mean_abs_float_internal;
                mean_abs_float <= mean_abs_float_internal;
                mean_abs_pending <= 1'b1;
            end

            if (threshold_count_float_valid_internal) begin
                threshold_latched <= threshold_count_float_internal;
                threshold_crossing_count_float <= threshold_count_float_internal;
                threshold_pending <= 1'b1;
            end

            if ((mean_abs_pending || mean_abs_float_valid_internal) &&
                (threshold_pending || threshold_count_float_valid_internal)) begin
                mean_abs_float <= mean_abs_float_valid_internal
                    ? mean_abs_float_internal
                    : mean_abs_latched;
                threshold_crossing_count_float <= threshold_count_float_valid_internal
                    ? threshold_count_float_internal
                    : threshold_latched;
                feature_float_valid <= 1'b1;
                mean_abs_pending <= 1'b0;
                threshold_pending <= 1'b0;
            end
        end
    end

endmodule
