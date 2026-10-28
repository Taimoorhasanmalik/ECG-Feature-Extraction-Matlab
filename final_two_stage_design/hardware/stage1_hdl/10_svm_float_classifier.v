/*
 * svm_4feat_float_classifier
 * --------------------------
 *
 * Sequential custom 16-bit E6/F10 SVM dot-product classifier for the
 * four hardware features currently produced by feature_extractor_4feat_float_top:
 *
 *   score = W_MEAN_ABS  * mean_abs_float
 *         + W_ZERO      * zero_crossings_float
 *         + W_LINE      * line_length_float
 *         + W_THRESH    * threshold_crossing_count_float
 *         + BIAS
 *
 * Feature order must match the MATLAB training/export order:
 *
 *   0: mean_abs
 *   1: zero_crossings
 *   2: line_length
 *   3: threshold_crossing_count
 *
 * The weights and bias are Xilinx custom E6/F10 constants rounded from the
 * single-precision values in the
 * final 120 Hz pthighpass no-robust-range MATLAB model/export:
 *
 *   final_low_power_design/models/pthighpass_svm_cpu_export.mat
 *
 * MATLAB trained the linear SVM with standardization enabled. The constants
 * below fold both standardization and the MATLAB decisionThreshold into the
 * hardware dot product, so the classifier only needs:
 *
 *   abnormal when score >= 0
 *
 * Required Vivado Floating-Point IP modules:
 *
 *   floating_point_2: custom 16-bit E6/F10 floating-point multiply
 *   floating_point_3: custom 16-bit E6/F10 floating-point add
 *
 * Configure both IPs with AXI-stream non-blocking interfaces matching the
 * existing project style:
 *
 *   - no s_axis_*_tready
 *   - no m_axis_result_tready
 *   - no aclken
 *   - no aresetn
 *
 * This module intentionally uses one multiplier and one adder. The feature
 * window rate is slow, so the extra classifier latency is much cheaper than
 * instantiating four parallel multipliers and a full adder tree.
 */

module svm_4feat_float_classifier #(
    parameter [15:0] W_MEAN_ABS_FLOAT  = 16'h40A3,
    parameter [15:0] W_ZERO_FLOAT      = 16'hB69C,
    parameter [15:0] W_LINE_FLOAT      = 16'hB352,
    parameter [15:0] W_THRESH_FLOAT    = 16'h3716,
    parameter [15:0] BIAS_FLOAT        = 16'h3CE3,
    parameter        POSITIVE_IS_SEIZURE = 1'b1
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire [15:0] mean_abs_float,
    input  wire [15:0] zero_crossings_float,
    input  wire [15:0] line_length_float,
    input  wire [15:0] threshold_crossing_count_float,
    input  wire        features_valid,

    output wire        input_ready,
    output reg  [15:0] svm_score_float,
    output reg         svm_score_valid,
    output reg         seizure,
    output reg         busy
);

    localparam [2:0] STATE_IDLE       = 3'd0;
    localparam [2:0] STATE_START_MUL  = 3'd1;
    localparam [2:0] STATE_WAIT_MUL   = 3'd2;
    localparam [2:0] STATE_START_ADD  = 3'd3;
    localparam [2:0] STATE_WAIT_ADD   = 3'd4;
    localparam [2:0] STATE_DONE       = 3'd5;

    reg [2:0] state;
    reg [1:0] feature_index;

    reg [15:0] x0_mean_abs;
    reg [15:0] x1_zero_crossings;
    reg [15:0] x2_line_length;
    reg [15:0] x3_threshold_count;
    reg [15:0] acc_float;
    reg [15:0] product_float_latched;

    reg        mul_valid_in;
    reg [15:0] mul_a;
    reg [15:0] mul_b;
    wire       mul_valid_out;
    wire [15:0] mul_result;

    reg        add_valid_in;
    reg [15:0] add_a;
    reg [15:0] add_b;
    wire       add_valid_out;
    wire [15:0] add_result;

    assign input_ready = (state == STATE_IDLE);

    floating_point_2 svm_float_multiply (
        .aclk                   (clk),
        .s_axis_a_tvalid        (mul_valid_in),
        .s_axis_a_tdata         (mul_a),
        .s_axis_b_tvalid        (mul_valid_in),
        .s_axis_b_tdata         (mul_b),
        .m_axis_result_tvalid   (mul_valid_out),
        .m_axis_result_tdata    (mul_result)
    );

    floating_point_3 svm_float_add (
        .aclk                   (clk),
        .s_axis_a_tvalid        (add_valid_in),
        .s_axis_a_tdata         (add_a),
        .s_axis_b_tvalid        (add_valid_in),
        .s_axis_b_tdata         (add_b),
        .m_axis_result_tvalid   (add_valid_out),
        .m_axis_result_tdata    (add_result)
    );

    function [15:0] select_feature;
        input [1:0] index;
        begin
            case (index)
                2'd0: select_feature = x0_mean_abs;
                2'd1: select_feature = x1_zero_crossings;
                2'd2: select_feature = x2_line_length;
                2'd3: select_feature = x3_threshold_count;
                default: select_feature = 16'd0;
            endcase
        end
    endfunction

    function [15:0] select_weight;
        input [1:0] index;
        begin
            case (index)
                2'd0: select_weight = W_MEAN_ABS_FLOAT;
                2'd1: select_weight = W_ZERO_FLOAT;
                2'd2: select_weight = W_LINE_FLOAT;
                2'd3: select_weight = W_THRESH_FLOAT;
                default: select_weight = 16'd0;
            endcase
        end
    endfunction

    function score_is_positive;
        input [15:0] score;
        begin
            score_is_positive = ~score[15];
        end
    endfunction

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= STATE_IDLE;
            feature_index <= 2'd0;
            x0_mean_abs <= 16'd0;
            x1_zero_crossings <= 16'd0;
            x2_line_length <= 16'd0;
            x3_threshold_count <= 16'd0;
            acc_float <= 16'd0;
            product_float_latched <= 16'd0;
            mul_valid_in <= 1'b0;
            mul_a <= 16'd0;
            mul_b <= 16'd0;
            add_valid_in <= 1'b0;
            add_a <= 16'd0;
            add_b <= 16'd0;
            svm_score_float <= 16'd0;
            svm_score_valid <= 1'b0;
            seizure <= 1'b0;
            busy <= 1'b0;
        end else begin
            mul_valid_in <= 1'b0;
            add_valid_in <= 1'b0;
            svm_score_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    busy <= 1'b0;
                    if (features_valid) begin
                        x0_mean_abs <= mean_abs_float;
                        x1_zero_crossings <= zero_crossings_float;
                        x2_line_length <= line_length_float;
                        x3_threshold_count <= threshold_crossing_count_float;
                        acc_float <= BIAS_FLOAT;
                        feature_index <= 2'd0;
                        busy <= 1'b1;
                        state <= STATE_START_MUL;
                    end
                end

                STATE_START_MUL: begin
                    mul_a <= select_feature(feature_index);
                    mul_b <= select_weight(feature_index);
                    mul_valid_in <= 1'b1;
                    state <= STATE_WAIT_MUL;
                end

                STATE_WAIT_MUL: begin
                    if (mul_valid_out) begin
                        product_float_latched <= mul_result;
                        state <= STATE_START_ADD;
                    end
                end

                STATE_START_ADD: begin
                    add_a <= acc_float;
                    add_b <= product_float_latched;
                    add_valid_in <= 1'b1;
                    state <= STATE_WAIT_ADD;
                end

                STATE_WAIT_ADD: begin
                    if (add_valid_out) begin
                        acc_float <= add_result;
                        if (feature_index == 2'd3) begin
                            svm_score_float <= add_result;
                            state <= STATE_DONE;
                        end else begin
                            feature_index <= feature_index + 2'd1;
                            state <= STATE_START_MUL;
                        end
                    end
                end

                STATE_DONE: begin
                    svm_score_valid <= 1'b1;
                    seizure <= POSITIVE_IS_SEIZURE
                        ? score_is_positive(svm_score_float)
                        : ~score_is_positive(svm_score_float);
                    busy <= 1'b0;
                    state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
