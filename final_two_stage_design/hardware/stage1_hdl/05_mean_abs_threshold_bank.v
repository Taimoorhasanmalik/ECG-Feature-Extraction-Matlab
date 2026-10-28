/*
 * feature_mean_abs_fix_mean_bank
 * ------------------------------
 *
 * Bank-local centered-feature hardware for the MATLAB fix-mean-only model.
 *
 * This block stores one window while feature_window_sum_bank computes
 * window_sum, raw_min, and raw_max. At window_end, it replays the stored
 * samples and computes:
 *
 *   mean_abs_q8 = fix(sum(abs(q_i - fix(sum(q_i) / N))) / N)
 *   threshold_crossing_count = transitions(abs(centered_i) >= 0.20*max_abs)
 *
 * raw_min/raw_max make max(abs(centered)) available before replay starts, so
 * mean_abs and threshold transitions are computed in the same replay pass.
 */

module feature_mean_abs_fix_mean_bank #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer SUM_WIDTH = SAMPLE_WIDTH + $clog2(WINDOW_SAMPLES + 1),
    parameter integer CENTERED_WIDTH = SAMPLE_WIDTH + 1,
    parameter integer ABS_ACC_WIDTH = CENTERED_WIDTH + $clog2(WINDOW_SAMPLES + 1),
    parameter integer COUNT_WIDTH = $clog2(WINDOW_SAMPLES + 1)
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    input  wire                           bank_enable,
    input  wire                           window_start,
    input  wire                           window_end,

    output reg signed [SAMPLE_WIDTH-1:0]  mean_abs_q8,
    output reg [COUNT_WIDTH-1:0]          threshold_crossing_count,
    output reg                            feature_valid
);

    localparam integer INDEX_WIDTH = $clog2(WINDOW_SAMPLES);

    reg signed [SAMPLE_WIDTH-1:0] sample_mem [0:WINDOW_SAMPLES-1];
    reg [INDEX_WIDTH-1:0] write_index;
    reg [INDEX_WIDTH-1:0] replay_index;
    reg replay_active;
    reg signed [SAMPLE_WIDTH-1:0] raw_min_acc;
    reg signed [SAMPLE_WIDTH-1:0] raw_max_acc;

    wire signed [SUM_WIDTH-1:0] window_sum;
    wire sum_valid;

    wire signed [SAMPLE_WIDTH-1:0] replay_sample =
        sample_mem[replay_index];

    wire replay_last =
        replay_index == WINDOW_SAMPLES - 1;

    wire signed [SAMPLE_WIDTH-1:0] mean_abs_q8_internal;
    wire [COUNT_WIDTH-1:0] threshold_count_internal;
    wire mean_abs_valid_internal;
    wire mean_abs_busy;

    wire signed [SAMPLE_WIDTH-1:0] next_raw_min =
        (window_start || (sample_in < raw_min_acc)) ? sample_in : raw_min_acc;

    wire signed [SAMPLE_WIDTH-1:0] next_raw_max =
        (window_start || (sample_in > raw_max_acc)) ? sample_in : raw_max_acc;

    feature_window_sum_bank #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .SUM_WIDTH      (SUM_WIDTH)
    ) first_pass_sum (
        .clk           (clk),
        .resetn        (resetn),
        .sample_in     (sample_in),
        .sample_valid  (sample_valid),
        .bank_enable   (bank_enable),
        .window_start  (window_start),
        .window_end    (window_end),
        .window_sum    (window_sum),
        .feature_valid (sum_valid)
    );

    feature_mean_abs_fix_mean_accumulator #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .SUM_WIDTH      (SUM_WIDTH),
        .CENTERED_WIDTH (CENTERED_WIDTH),
        .ABS_ACC_WIDTH  (ABS_ACC_WIDTH),
        .COUNT_WIDTH    (COUNT_WIDTH)
    ) second_pass_mean_abs (
        .clk                    (clk),
        .resetn                 (resetn),
        .start                  (sum_valid),
        .window_sum             (window_sum),
        .raw_min                (raw_min_acc),
        .raw_max                (raw_max_acc),
        .replay_sample          (replay_sample),
        .replay_valid           (replay_active),
        .replay_last            (replay_last),
        .mean_abs_q8            (mean_abs_q8_internal),
        .threshold_crossing_count (threshold_count_internal),
        .feature_valid          (mean_abs_valid_internal),
        .busy                   (mean_abs_busy)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            write_index <= {INDEX_WIDTH{1'b0}};
            replay_index <= {INDEX_WIDTH{1'b0}};
            replay_active <= 1'b0;
            raw_min_acc <= {SAMPLE_WIDTH{1'b0}};
            raw_max_acc <= {SAMPLE_WIDTH{1'b0}};
            mean_abs_q8 <= {SAMPLE_WIDTH{1'b0}};
            threshold_crossing_count <= {COUNT_WIDTH{1'b0}};
            feature_valid <= 1'b0;
        end else begin
            feature_valid <= 1'b0;

            if (sample_valid && bank_enable) begin
                sample_mem[write_index] <= sample_in;
                raw_min_acc <= next_raw_min;
                raw_max_acc <= next_raw_max;

                if (window_end) begin
                    write_index <= {INDEX_WIDTH{1'b0}};
                end else if (window_start) begin
                    write_index <= {{(INDEX_WIDTH-1){1'b0}}, 1'b1};
                end else begin
                    write_index <= write_index + 1'b1;
                end
            end

            if (sum_valid) begin
                replay_active <= 1'b1;
                replay_index <= {INDEX_WIDTH{1'b0}};
            end else if (replay_active) begin
                if (replay_last) begin
                    replay_active <= 1'b0;
                    replay_index <= {INDEX_WIDTH{1'b0}};
                end else begin
                    replay_index <= replay_index + 1'b1;
                end
            end

            if (mean_abs_valid_internal) begin
                mean_abs_q8 <= mean_abs_q8_internal;
                threshold_crossing_count <= threshold_count_internal;
                feature_valid <= 1'b1;
            end
        end
    end

endmodule
