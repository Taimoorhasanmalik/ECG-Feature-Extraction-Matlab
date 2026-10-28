/*
 * feature_line_zero_diff_bank
 * ---------------------------
 *
 * Shared first-difference feature hardware.
 *
 * MATLAB uses diff(windowSignal) for both:
 *
 *   - line_length:
 *       sum(abs(diffSignal)) / windowSeconds
 *
 *   - zero_crossings:
 *       count_zero_crossings(diffSignal) / windowSeconds
 *
 * The window mean subtraction cancels in diff(), so this block operates
 * directly on the Q3.8 integer samples q_i.
 *
 * For every sample after the first one in a window:
 *
 *     diff_i = q_i - q_(i-1)
 *
 * The same diff_i feeds both feature accumulators:
 *
 *     diff_abs_sum        += abs(diff_i)
 *     zero_crossing_count += sign_change(diff_i)
 *
 * Zero-valued differences follow the MATLAB rule by not updating the
 * remembered non-zero sign.
 *
 * The floating wrapper converts these raw integer results to MATLAB's
 * real-valued features. This core does not calculate or output debug Q3.8
 * feature values.
 */

module feature_line_zero_diff_bank #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer WINDOW_SECONDS = 2,
    parameter integer DIFF_WIDTH = SAMPLE_WIDTH + 1,
    parameter integer DIFF_ACC_WIDTH = DIFF_WIDTH + $clog2(WINDOW_SAMPLES),
    parameter integer COUNT_WIDTH = $clog2(WINDOW_SAMPLES + 1)
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    input  wire                           bank_enable,
    input  wire                           window_start,
    input  wire                           window_end,

    output reg [DIFF_ACC_WIDTH-1:0]       diff_abs_sum,
    output reg [COUNT_WIDTH-1:0]          zero_crossing_count,
    output reg                            feature_valid
);

    localparam [1:0] SIGN_NONE = 2'd0;
    localparam [1:0] SIGN_POS  = 2'd1;
    localparam [1:0] SIGN_NEG  = 2'd2;

    reg signed [SAMPLE_WIDTH-1:0] prev_sample;
    reg [1:0] prev_nonzero_diff_sign;
    reg [DIFF_ACC_WIDTH-1:0] diff_abs_acc;
    reg [COUNT_WIDTH-1:0] zero_crossing_acc;

    wire signed [DIFF_WIDTH-1:0] sample_extended =
        {sample_in[SAMPLE_WIDTH-1], sample_in};

    wire signed [DIFF_WIDTH-1:0] prev_sample_extended =
        {prev_sample[SAMPLE_WIDTH-1], prev_sample};

    wire signed [DIFF_WIDTH-1:0] diff_sample =
        sample_extended - prev_sample_extended;

    wire [DIFF_WIDTH-1:0] abs_diff =
        diff_sample[DIFF_WIDTH-1] ? -diff_sample : diff_sample;

    wire [DIFF_ACC_WIDTH-1:0] abs_diff_extended =
        {{(DIFF_ACC_WIDTH-DIFF_WIDTH){1'b0}}, abs_diff};

    wire first_sample_in_window =
        window_start;

    wire [1:0] current_diff_sign =
        (diff_sample > 0) ? SIGN_POS :
        (diff_sample < 0) ? SIGN_NEG :
                            SIGN_NONE;

    wire usable_diff =
        !first_sample_in_window &&
        (current_diff_sign != SIGN_NONE);

    wire crossing_hit =
        usable_diff &&
        (prev_nonzero_diff_sign != SIGN_NONE) &&
        (current_diff_sign != prev_nonzero_diff_sign);

    wire [DIFF_ACC_WIDTH-1:0] next_diff_abs_acc =
        diff_abs_acc + abs_diff_extended;

    wire [COUNT_WIDTH-1:0] next_zero_crossing_acc =
        zero_crossing_acc + {{(COUNT_WIDTH-1){1'b0}}, crossing_hit};

    wire [DIFF_ACC_WIDTH-1:0] current_diff_abs_sum =
        window_start ? {DIFF_ACC_WIDTH{1'b0}} : next_diff_abs_acc;

    wire [COUNT_WIDTH-1:0] current_zero_crossing_count =
        window_start ? {COUNT_WIDTH{1'b0}} : next_zero_crossing_acc;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            prev_sample <= {SAMPLE_WIDTH{1'b0}};
            prev_nonzero_diff_sign <= SIGN_NONE;
            diff_abs_acc <= {DIFF_ACC_WIDTH{1'b0}};
            zero_crossing_acc <= {COUNT_WIDTH{1'b0}};
            diff_abs_sum <= {DIFF_ACC_WIDTH{1'b0}};
            zero_crossing_count <= {COUNT_WIDTH{1'b0}};
            feature_valid <= 1'b0;
        end else begin
            feature_valid <= 1'b0;

            if (sample_valid && bank_enable) begin
                prev_sample <= sample_in;

                if (window_start) begin
                    prev_nonzero_diff_sign <= SIGN_NONE;
                end else if (current_diff_sign != SIGN_NONE) begin
                    prev_nonzero_diff_sign <= current_diff_sign;
                end

                if (window_end) begin
                    diff_abs_sum <= current_diff_abs_sum;
                    zero_crossing_count <= current_zero_crossing_count;
                    feature_valid <= 1'b1;
                    diff_abs_acc <= {DIFF_ACC_WIDTH{1'b0}};
                    zero_crossing_acc <= {COUNT_WIDTH{1'b0}};
                end else begin
                    diff_abs_acc <= current_diff_abs_sum;
                    zero_crossing_acc <= current_zero_crossing_count;
                end
            end
        end
    end

endmodule
