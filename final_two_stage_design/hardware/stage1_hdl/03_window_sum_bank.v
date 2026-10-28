/*
 * feature_window_sum_bank
 * -----------------------
 *
 * First pass of the MATLAB mean_abs feature calculation.
 *
 * For each 240-sample window, this block accumulates the signed Q3.8
 * samples:
 *
 *     window_sum = sum(q_i)
 *
 * The exact centered mean-absolute feature uses window_sum directly in the
 * second-pass accumulator to avoid losing precision. The old debug
 * window_mean output was intentionally removed/commented out so this module
 * does not synthesize a divider.
 *
 * Inputs window_start/window_end/bank_enable must be aligned with sample_in.
 * In the full pipeline they should come from feature_set's registered
 * outputs: sample_out, sample_out_valid, window_start, window_end, and
 * feature_bank_enable.
 */

module feature_window_sum_bank #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer SUM_WIDTH = SAMPLE_WIDTH + $clog2(WINDOW_SAMPLES + 1)
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    input  wire                           bank_enable,
    input  wire                           window_start,
    input  wire                           window_end,

    output reg signed [SUM_WIDTH-1:0]     window_sum,
    /* Debug-only mean removed to avoid synthesizing a divider:
     * output reg signed [SAMPLE_WIDTH-1:0]  window_mean,
     */
    output reg                            feature_valid
);

    reg signed [SUM_WIDTH-1:0] sum_acc;

    wire signed [SUM_WIDTH-1:0] sample_extended =
        {{(SUM_WIDTH-SAMPLE_WIDTH){sample_in[SAMPLE_WIDTH-1]}}, sample_in};

    wire signed [SUM_WIDTH-1:0] next_sum =
        sum_acc + sample_extended;

    wire signed [SUM_WIDTH-1:0] current_window_sum =
        window_start ? sample_extended : next_sum;

    /* Debug-only mean removed to avoid synthesizing a divider:
     * wire signed [SUM_WIDTH-1:0] current_window_mean =
     *     current_window_sum / WINDOW_SAMPLES;
     */

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sum_acc <= {SUM_WIDTH{1'b0}};
            window_sum <= {SUM_WIDTH{1'b0}};
            feature_valid <= 1'b0;
        end else begin
            feature_valid <= 1'b0;

            if (sample_valid && bank_enable) begin
                if (window_end) begin
                    window_sum <= current_window_sum;
                    feature_valid <= 1'b1;
                    sum_acc <= {SUM_WIDTH{1'b0}};
                end else begin
                    sum_acc <= current_window_sum;
                end
            end
        end
    end

endmodule
