/*
 * feature_extractor_4feat_float_top
 * ---------------------------------
 *
 * Combined four-feature floating-point extractor for the current hardware
 * model. One feature_set instance creates overlapping 240-sample windows
 * with 120-sample step. Two physical banks are used by feature_set, and each
 * bank has:
 *
 *   - feature_mean_abs_fix_mean_float_bank:
 *       mean_abs_float
 *       threshold_crossing_count_float
 *
 *   - feature_line_zero_diff_float_bank:
 *       line_length_float
 *       zero_crossings_float
 *
 * The diff features finish earlier than the centered features. This module
 * latches each feature group per bank and asserts features_valid when both
 * groups for the same window are available.
 */

module feature_extractor_4feat_float_top #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer STEP_SAMPLES = 120,
    parameter integer WINDOW_SECONDS = 2
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    output reg  [15:0]                    mean_abs_float,
    output reg  [15:0]                    zero_crossings_float,
    output reg  [15:0]                    line_length_float,
    output reg  [15:0]                    threshold_crossing_count_float,
    output reg                            features_valid,
    output reg                            feature_bank,
    output reg  [31:0]                    completed_window_count,

    output wire                           window_overflow
);

    wire signed [SAMPLE_WIDTH-1:0] sample_out;
    wire sample_out_valid;
    wire [31:0] sample_index;
    wire [31:0] window_count;
    wire [1:0] window_start;
    wire [1:0] window_end;
    wire [1:0] feature_bank_enable;
    wire [1:0] window_active;

    wire [15:0] bank0_mean_abs_float;
    wire [15:0] bank1_mean_abs_float;
    wire [15:0] bank0_threshold_float;
    wire [15:0] bank1_threshold_float;
    wire bank0_centered_valid;
    wire bank1_centered_valid;

    wire [15:0] bank0_line_length_float;
    wire [15:0] bank1_line_length_float;
    wire [15:0] bank0_zero_crossings_float;
    wire [15:0] bank1_zero_crossings_float;
    wire bank0_diff_valid;
    wire bank1_diff_valid;

    reg [15:0] bank0_mean_abs_latched;
    reg [15:0] bank1_mean_abs_latched;
    reg [15:0] bank0_threshold_latched;
    reg [15:0] bank1_threshold_latched;
    reg [15:0] bank0_line_length_latched;
    reg [15:0] bank1_line_length_latched;
    reg [15:0] bank0_zero_crossings_latched;
    reg [15:0] bank1_zero_crossings_latched;

    reg bank0_centered_pending;
    reg bank1_centered_pending;
    reg bank0_diff_pending;
    reg bank1_diff_pending;

    wire bank0_ready =
        (bank0_centered_pending || bank0_centered_valid) &&
        (bank0_diff_pending || bank0_diff_valid);

    wire bank1_ready =
        (bank1_centered_pending || bank1_centered_valid) &&
        (bank1_diff_pending || bank1_diff_valid);

    feature_set #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .STEP_SAMPLES   (STEP_SAMPLES)
    ) sequencer (
        .clk                 (clk),
        .resetn              (resetn),
        .restart             (1'b0),
        .sample_in           (sample_in),
        .sample_valid        (sample_valid),
        .sample_out          (sample_out),
        .sample_out_valid    (sample_out_valid),
        .sample_index        (sample_index),
        .window_count        (window_count),
        .window_start        (window_start),
        .window_end          (window_end),
        .feature_bank_enable (feature_bank_enable),
        .window_active       (window_active),
        .window_overflow     (window_overflow)
    );

    feature_mean_abs_fix_mean_float_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES)
    ) centered_bank0 (
        .clk                            (clk),
        .resetn                         (resetn),
        .sample_in                      (sample_out),
        .sample_valid                   (sample_out_valid),
        .bank_enable                    (feature_bank_enable[0]),
        .window_start                   (window_start[0]),
        .window_end                     (window_end[0]),
        .integer_feature_valid          (),
        .mean_abs_float                 (bank0_mean_abs_float),
        .threshold_crossing_count_float (bank0_threshold_float),
        .feature_float_valid            (bank0_centered_valid)
    );

    feature_mean_abs_fix_mean_float_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES)
    ) centered_bank1 (
        .clk                            (clk),
        .resetn                         (resetn),
        .sample_in                      (sample_out),
        .sample_valid                   (sample_out_valid),
        .bank_enable                    (feature_bank_enable[1]),
        .window_start                   (window_start[1]),
        .window_end                     (window_end[1]),
        .integer_feature_valid          (),
        .mean_abs_float                 (bank1_mean_abs_float),
        .threshold_crossing_count_float (bank1_threshold_float),
        .feature_float_valid            (bank1_centered_valid)
    );

    feature_line_zero_diff_float_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .WINDOW_SECONDS (WINDOW_SECONDS)
    ) diff_bank0 (
        .clk                         (clk),
        .resetn                      (resetn),
        .sample_in                   (sample_out),
        .sample_valid                (sample_out_valid),
        .bank_enable                 (feature_bank_enable[0]),
        .window_start                (window_start[0]),
        .window_end                  (window_end[0]),
        .diff_abs_sum                (),
        .zero_crossing_count         (),
        .integer_feature_valid       (),
        .line_length_float           (bank0_line_length_float),
        .line_length_float_valid     (),
        .zero_crossings_float        (bank0_zero_crossings_float),
        .zero_crossings_float_valid  (),
        .feature_float_valid         (bank0_diff_valid)
    );

    feature_line_zero_diff_float_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .WINDOW_SECONDS (WINDOW_SECONDS)
    ) diff_bank1 (
        .clk                         (clk),
        .resetn                      (resetn),
        .sample_in                   (sample_out),
        .sample_valid                (sample_out_valid),
        .bank_enable                 (feature_bank_enable[1]),
        .window_start                (window_start[1]),
        .window_end                  (window_end[1]),
        .diff_abs_sum                (),
        .zero_crossing_count         (),
        .integer_feature_valid       (),
        .line_length_float           (bank1_line_length_float),
        .line_length_float_valid     (),
        .zero_crossings_float        (bank1_zero_crossings_float),
        .zero_crossings_float_valid  (),
        .feature_float_valid         (bank1_diff_valid)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mean_abs_float <= 16'd0;
            zero_crossings_float <= 16'd0;
            line_length_float <= 16'd0;
            threshold_crossing_count_float <= 16'd0;
            features_valid <= 1'b0;
            feature_bank <= 1'b0;
            completed_window_count <= 32'd0;

            bank0_mean_abs_latched <= 16'd0;
            bank1_mean_abs_latched <= 16'd0;
            bank0_threshold_latched <= 16'd0;
            bank1_threshold_latched <= 16'd0;
            bank0_line_length_latched <= 16'd0;
            bank1_line_length_latched <= 16'd0;
            bank0_zero_crossings_latched <= 16'd0;
            bank1_zero_crossings_latched <= 16'd0;

            bank0_centered_pending <= 1'b0;
            bank1_centered_pending <= 1'b0;
            bank0_diff_pending <= 1'b0;
            bank1_diff_pending <= 1'b0;
        end else begin
            features_valid <= 1'b0;

            if (bank0_centered_valid) begin
                bank0_mean_abs_latched <= bank0_mean_abs_float;
                bank0_threshold_latched <= bank0_threshold_float;
                bank0_centered_pending <= 1'b1;
            end

            if (bank1_centered_valid) begin
                bank1_mean_abs_latched <= bank1_mean_abs_float;
                bank1_threshold_latched <= bank1_threshold_float;
                bank1_centered_pending <= 1'b1;
            end

            if (bank0_diff_valid) begin
                bank0_line_length_latched <= bank0_line_length_float;
                bank0_zero_crossings_latched <= bank0_zero_crossings_float;
                bank0_diff_pending <= 1'b1;
            end

            if (bank1_diff_valid) begin
                bank1_line_length_latched <= bank1_line_length_float;
                bank1_zero_crossings_latched <= bank1_zero_crossings_float;
                bank1_diff_pending <= 1'b1;
            end

            if (bank0_ready) begin
                mean_abs_float <= bank0_centered_valid
                    ? bank0_mean_abs_float
                    : bank0_mean_abs_latched;
                threshold_crossing_count_float <= bank0_centered_valid
                    ? bank0_threshold_float
                    : bank0_threshold_latched;
                line_length_float <= bank0_diff_valid
                    ? bank0_line_length_float
                    : bank0_line_length_latched;
                zero_crossings_float <= bank0_diff_valid
                    ? bank0_zero_crossings_float
                    : bank0_zero_crossings_latched;
                feature_bank <= 1'b0;
                features_valid <= 1'b1;
                completed_window_count <= completed_window_count + 32'd1;
                bank0_centered_pending <= 1'b0;
                bank0_diff_pending <= 1'b0;
            end else if (bank1_ready) begin
                mean_abs_float <= bank1_centered_valid
                    ? bank1_mean_abs_float
                    : bank1_mean_abs_latched;
                threshold_crossing_count_float <= bank1_centered_valid
                    ? bank1_threshold_float
                    : bank1_threshold_latched;
                line_length_float <= bank1_diff_valid
                    ? bank1_line_length_float
                    : bank1_line_length_latched;
                zero_crossings_float <= bank1_diff_valid
                    ? bank1_zero_crossings_float
                    : bank1_zero_crossings_latched;
                feature_bank <= 1'b1;
                features_valid <= 1'b1;
                completed_window_count <= completed_window_count + 32'd1;
                bank1_centered_pending <= 1'b0;
                bank1_diff_pending <= 1'b0;
            end
        end
    end

endmodule
