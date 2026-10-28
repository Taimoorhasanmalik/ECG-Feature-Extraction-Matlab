/*
 * feature_line_zero_diff_float_bank
 * ---------------------------------
 *
 * Floating-point output wrapper for the shared diff feature hardware.
 *
 * This file keeps feature_line_zero_diff_bank.v as the verified integer core
 * and puts the Vivado Floating-Point IP boundary at the feature output.
 *
 * Integer core outputs:
 *
 *   diff_abs_sum        = sum(abs(q_i - q_(i-1)))
 *   zero_crossing_count = count sign changes in diff()
 *
 * MATLAB real-valued features for 2-second windows:
 *
 *   line_length    = diff_abs_sum / (256 * 2)
 *                  = diff_abs_sum * 1/512
 *
 *   zero_crossings = zero_crossing_count / 2
 *                  = zero_crossing_count * 0.5
 *
 * Required Vivado Floating-Point IP modules:
 *
 *   1. fp_u24_to_float
 *      - Operation: fixed-to-float
 *      - Input: unsigned integer, DIFF_AXIS_WIDTH bits, 0 fractional bits
 *      - Output: custom 16-bit E6/F10 float
 *
 *   2. fp_u16_to_float
 *      - Operation: fixed-to-float
 *      - Input: unsigned integer, COUNT_AXIS_WIDTH bits, 0 fractional bits
 *      - Output: custom 16-bit E6/F10 float
 *
 *   3. fp_float_mul
 *      - Operation: custom 16-bit E6/F10 floating-point multiply
 *
 * The constants use the Xilinx custom E6/F10 encoding:
 *
 *   16'h2C00 = 1/512
 *   16'h3C00 = 0.5
 *
 * The two output valid pulses are independent. feature_float_valid pulses
 * when both floating-point feature values have been received and latched.
 */

module feature_line_zero_diff_float_bank #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer WINDOW_SECONDS = 2,
    parameter integer DIFF_WIDTH = SAMPLE_WIDTH + 1,
    parameter integer DIFF_ACC_WIDTH = DIFF_WIDTH + $clog2(WINDOW_SAMPLES),
    parameter integer COUNT_WIDTH = $clog2(WINDOW_SAMPLES + 1),
    parameter integer DIFF_AXIS_WIDTH = 24,
    parameter integer COUNT_AXIS_WIDTH = 16
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    input  wire                           bank_enable,
    input  wire                           window_start,
    input  wire                           window_end,

    output wire [DIFF_ACC_WIDTH-1:0]      diff_abs_sum,
    output wire [COUNT_WIDTH-1:0]         zero_crossing_count,
    output wire                           integer_feature_valid,

    output reg  [15:0]                    line_length_float,
    output reg                            line_length_float_valid,
    output reg  [15:0]                    zero_crossings_float,
    output reg                            zero_crossings_float_valid,
    output reg                            feature_float_valid
);

    localparam [15:0] LINE_LENGTH_SCALE_FLOAT = 16'h2C00;
    localparam [15:0] ZERO_CROSS_SCALE_FLOAT  = 16'h3C00;

    wire [DIFF_AXIS_WIDTH-1:0] diff_abs_sum_axis =
        {{(DIFF_AXIS_WIDTH-DIFF_ACC_WIDTH){1'b0}}, diff_abs_sum};

    wire [COUNT_AXIS_WIDTH-1:0] zero_count_axis =
        {{(COUNT_AXIS_WIDTH-COUNT_WIDTH){1'b0}}, zero_crossing_count};

    wire [15:0] diff_abs_sum_float;
    wire        diff_abs_sum_float_valid;
    wire [15:0] zero_count_float;
    wire        zero_count_float_valid;

    wire [15:0] line_length_float_internal;
    wire        line_length_float_valid_internal;
    wire [15:0] zero_crossings_float_internal;
    wire        zero_crossings_float_valid_internal;

    reg line_length_pending;
    reg zero_crossings_pending;
    reg [15:0] line_length_latched;
    reg [15:0] zero_crossings_latched;

    feature_line_zero_diff_bank #(
        .SAMPLE_WIDTH     (SAMPLE_WIDTH),
        .WINDOW_SAMPLES   (WINDOW_SAMPLES),
        .WINDOW_SECONDS   (WINDOW_SECONDS),
        .DIFF_WIDTH       (DIFF_WIDTH),
        .DIFF_ACC_WIDTH   (DIFF_ACC_WIDTH),
        .COUNT_WIDTH      (COUNT_WIDTH)
    ) integer_diff_core (
        .clk                 (clk),
        .resetn              (resetn),
        .sample_in           (sample_in),
        .sample_valid        (sample_valid),
        .bank_enable         (bank_enable),
        .window_start        (window_start),
        .window_end          (window_end),
        .diff_abs_sum        (diff_abs_sum),
        .zero_crossing_count (zero_crossing_count),
        .feature_valid       (integer_feature_valid)
    );

    floating_point_0 diff_sum_to_float (
        .aclk                   (clk),
        .s_axis_a_tvalid        (integer_feature_valid),
        .s_axis_a_tdata         (diff_abs_sum_axis),
        .m_axis_result_tvalid   (diff_abs_sum_float_valid),
        .m_axis_result_tdata    (diff_abs_sum_float)
    );

    floating_point_2 line_length_scale (
        .aclk                   (clk),
        .s_axis_a_tvalid        (diff_abs_sum_float_valid),
        .s_axis_a_tdata         (diff_abs_sum_float),
        .s_axis_b_tvalid        (diff_abs_sum_float_valid),
        .s_axis_b_tdata         (LINE_LENGTH_SCALE_FLOAT),
        .m_axis_result_tvalid   (line_length_float_valid_internal),
        .m_axis_result_tdata    (line_length_float_internal)
    );

    floating_point_1 zero_count_to_float (
        .aclk                   (clk),
        .s_axis_a_tvalid        (integer_feature_valid),
        .s_axis_a_tdata         (zero_count_axis),
        .m_axis_result_tvalid   (zero_count_float_valid),
        .m_axis_result_tdata    (zero_count_float)
    );

    floating_point_2 zero_crossing_scale (
        .aclk                   (clk),
        .s_axis_a_tvalid        (zero_count_float_valid),
        .s_axis_a_tdata         (zero_count_float),
        .s_axis_b_tvalid        (zero_count_float_valid),
        .s_axis_b_tdata         (ZERO_CROSS_SCALE_FLOAT),
        .m_axis_result_tvalid   (zero_crossings_float_valid_internal),
        .m_axis_result_tdata    (zero_crossings_float_internal)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            line_length_float <= 16'd0;
            zero_crossings_float <= 16'd0;
            line_length_float_valid <= 1'b0;
            zero_crossings_float_valid <= 1'b0;
            feature_float_valid <= 1'b0;
            line_length_pending <= 1'b0;
            zero_crossings_pending <= 1'b0;
            line_length_latched <= 16'd0;
            zero_crossings_latched <= 16'd0;
        end else begin
            line_length_float_valid <= 1'b0;
            zero_crossings_float_valid <= 1'b0;
            feature_float_valid <= 1'b0;

            if (line_length_float_valid_internal) begin
                line_length_latched <= line_length_float_internal;
                line_length_float <= line_length_float_internal;
                line_length_float_valid <= 1'b1;
                line_length_pending <= 1'b1;
            end

            if (zero_crossings_float_valid_internal) begin
                zero_crossings_latched <= zero_crossings_float_internal;
                zero_crossings_float <= zero_crossings_float_internal;
                zero_crossings_float_valid <= 1'b1;
                zero_crossings_pending <= 1'b1;
            end

            if ((line_length_pending || line_length_float_valid_internal) &&
                (zero_crossings_pending || zero_crossings_float_valid_internal)) begin
                line_length_float <= line_length_float_valid_internal
                    ? line_length_float_internal
                    : line_length_latched;
                zero_crossings_float <= zero_crossings_float_valid_internal
                    ? zero_crossings_float_internal
                    : zero_crossings_latched;
                feature_float_valid <= 1'b1;
                line_length_pending <= 1'b0;
                zero_crossings_pending <= 1'b0;
            end
        end
    end

endmodule
