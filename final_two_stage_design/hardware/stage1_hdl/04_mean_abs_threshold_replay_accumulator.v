/*
 * feature_mean_abs_fix_mean_accumulator
 * -------------------------------------
 *
 * Replay-pass feature accumulator for the fix-mean-only MATLAB centered
 * window features.
 *
 * MATLAB behavior being matched:
 *
 *   windowMean = fix(sum(q_i) / N)
 *   centered_i = q_i - windowMean
 *   meanAbs = fix(sum(abs(centered_i)) / N)
 *   max_abs = max(abs(raw_max - windowMean), abs(raw_min - windowMean))
 *   threshold = 0.20 * max_abs
 *   thresholdCrossingCount = transitions(abs(centered_i) >= threshold)
 *
 * q_i and meanAbs are Q3.8 integers. Verilog signed division by a positive
 * constant truncates toward zero, matching MATLAB fix() here.
 *
 * raw_min and raw_max are tracked during the first pass while the window sum
 * is accumulated. That makes max_abs_centered known before replay starts, so
 * mean_abs and threshold crossings are computed in the same replay pass.
 *
 * The threshold fraction is fixed at 0.20 = 1/5, so the replay compare is
 * implemented without division:
 *
 *   abs(centered_i) >= max_abs / 5
 *   5 * abs(centered_i) >= max_abs
 */

module feature_mean_abs_fix_mean_accumulator #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer SUM_WIDTH = SAMPLE_WIDTH + $clog2(WINDOW_SAMPLES + 1),
    parameter integer CENTERED_WIDTH = SAMPLE_WIDTH + 1,
    parameter integer ABS_ACC_WIDTH = CENTERED_WIDTH + $clog2(WINDOW_SAMPLES + 1),
    parameter integer COUNT_WIDTH = $clog2(WINDOW_SAMPLES + 1)
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire                           start,
    input  wire signed [SUM_WIDTH-1:0]    window_sum,
    input  wire signed [SAMPLE_WIDTH-1:0] raw_min,
    input  wire signed [SAMPLE_WIDTH-1:0] raw_max,

    input  wire signed [SAMPLE_WIDTH-1:0] replay_sample,
    input  wire                           replay_valid,
    input  wire                           replay_last,

    output reg signed [SAMPLE_WIDTH-1:0]  mean_abs_q8,
    output reg [COUNT_WIDTH-1:0]          threshold_crossing_count,
    output reg                            feature_valid,
    output reg                            busy
);

    reg signed [SUM_WIDTH-1:0] active_window_sum;
    reg signed [SAMPLE_WIDTH-1:0] active_raw_min;
    reg signed [SAMPLE_WIDTH-1:0] active_raw_max;
    reg [ABS_ACC_WIDTH-1:0] abs_acc;
    reg [COUNT_WIDTH-1:0] threshold_count_acc;
    reg prev_above_threshold;
    reg first_threshold_sample;

    wire signed [SUM_WIDTH-1:0] window_mean_wide =
        active_window_sum / WINDOW_SAMPLES;

    wire signed [CENTERED_WIDTH-1:0] window_mean_q8 =
        window_mean_wide[CENTERED_WIDTH-1:0];

    wire signed [CENTERED_WIDTH-1:0] raw_min_extended =
        {{(CENTERED_WIDTH-SAMPLE_WIDTH){active_raw_min[SAMPLE_WIDTH-1]}},
            active_raw_min};

    wire signed [CENTERED_WIDTH-1:0] raw_max_extended =
        {{(CENTERED_WIDTH-SAMPLE_WIDTH){active_raw_max[SAMPLE_WIDTH-1]}},
            active_raw_max};

    wire signed [CENTERED_WIDTH-1:0] centered_min =
        raw_min_extended - window_mean_q8;

    wire signed [CENTERED_WIDTH-1:0] centered_max =
        raw_max_extended - window_mean_q8;

    wire [CENTERED_WIDTH-1:0] abs_centered_min =
        centered_min[CENTERED_WIDTH-1]
            ? -centered_min
            : centered_min;

    wire [CENTERED_WIDTH-1:0] abs_centered_max =
        centered_max[CENTERED_WIDTH-1]
            ? -centered_max
            : centered_max;

    wire [CENTERED_WIDTH-1:0] max_abs_centered =
        (abs_centered_max > abs_centered_min)
            ? abs_centered_max
            : abs_centered_min;

    wire signed [CENTERED_WIDTH-1:0] replay_sample_extended =
        {{(CENTERED_WIDTH-SAMPLE_WIDTH){replay_sample[SAMPLE_WIDTH-1]}},
            replay_sample};

    wire signed [CENTERED_WIDTH-1:0] centered_sample =
        replay_sample_extended - window_mean_q8;

    wire [CENTERED_WIDTH-1:0] abs_centered_sample =
        centered_sample[CENTERED_WIDTH-1]
            ? -centered_sample
            : centered_sample;

    wire [ABS_ACC_WIDTH-1:0] abs_centered_extended =
        {{(ABS_ACC_WIDTH-CENTERED_WIDTH){1'b0}}, abs_centered_sample};

    wire [ABS_ACC_WIDTH-1:0] next_abs_acc =
        abs_acc + abs_centered_extended;

    wire [ABS_ACC_WIDTH-1:0] current_mean_abs_q8 =
        next_abs_acc / WINDOW_SAMPLES;

    wire [CENTERED_WIDTH+2:0] abs_centered_times_five =
        {3'b000, abs_centered_sample} * 3'd5;

    wire above_threshold =
        (max_abs_centered != {CENTERED_WIDTH{1'b0}}) &&
        (abs_centered_times_five >= {{3{1'b0}}, max_abs_centered});

    wire threshold_crossing_hit =
        !first_threshold_sample && (above_threshold != prev_above_threshold);

    wire [COUNT_WIDTH-1:0] next_threshold_count =
        threshold_count_acc + {{(COUNT_WIDTH-1){1'b0}}, threshold_crossing_hit};

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            active_window_sum <= {SUM_WIDTH{1'b0}};
            active_raw_min <= {SAMPLE_WIDTH{1'b0}};
            active_raw_max <= {SAMPLE_WIDTH{1'b0}};
            abs_acc <= {ABS_ACC_WIDTH{1'b0}};
            threshold_count_acc <= {COUNT_WIDTH{1'b0}};
            prev_above_threshold <= 1'b0;
            first_threshold_sample <= 1'b1;
            mean_abs_q8 <= {SAMPLE_WIDTH{1'b0}};
            threshold_crossing_count <= {COUNT_WIDTH{1'b0}};
            feature_valid <= 1'b0;
            busy <= 1'b0;
        end else begin
            feature_valid <= 1'b0;

            if (start) begin
                active_window_sum <= window_sum;
                active_raw_min <= raw_min;
                active_raw_max <= raw_max;
                abs_acc <= {ABS_ACC_WIDTH{1'b0}};
                threshold_count_acc <= {COUNT_WIDTH{1'b0}};
                prev_above_threshold <= 1'b0;
                first_threshold_sample <= 1'b1;
                busy <= 1'b1;
            end else if (busy && replay_valid) begin
                abs_acc <= next_abs_acc;
                threshold_count_acc <= next_threshold_count;
                prev_above_threshold <= above_threshold;
                first_threshold_sample <= 1'b0;

                if (replay_last) begin
                    mean_abs_q8 <= current_mean_abs_q8[SAMPLE_WIDTH-1:0];
                    threshold_crossing_count <= next_threshold_count;
                    feature_valid <= 1'b1;
                    abs_acc <= {ABS_ACC_WIDTH{1'b0}};
                    threshold_count_acc <= {COUNT_WIDTH{1'b0}};
                    prev_above_threshold <= 1'b0;
                    first_threshold_sample <= 1'b1;
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule
