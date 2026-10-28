// Stage 2, 120 Hz VT/VF linear SVM.
// Inputs are signed Q16.16 feature values in the JSON model's listed order.
// Weights and bias are signed Q2.13. The 64-bit score is Q29.
// One valid input produces one registered result on the next active clock edge.
module stage2_vt_vf_svm_q213 (
    input  wire                    clk,
    input  wire                    resetn,
    input  wire                    features_valid,
    input  wire signed [31:0]      mean_abs_amp_q16_16,
    input  wire signed [31:0]      line_length_q16_16,
    input  wire signed [31:0]      derivative_zero_crossings_q16_16,
    input  wire signed [31:0]      threshold_crossings_q16_16,
    input  wire signed [31:0]      local_amp_mean_q16_16,
    input  wire signed [31:0]      local_amp_range_q16_16,
    input  wire signed [31:0]      amp_transition_q16_16,
    output reg                     result_toggle,
    output reg                     vf,
    output reg  signed [63:0]      score_q29
);
    // stage2_hardware_deliverable/120hz/stage2_hardware_model.json
    localparam signed [15:0] W_MEAN_ABS  = -16'sd7250;
    localparam signed [15:0] W_LINE      =  16'sd178;
    localparam signed [15:0] W_DERIV_ZC  =  16'sd3;
    localparam signed [15:0] W_THRESH    =  16'sd5;
    localparam signed [15:0] W_LOCAL_AVG = -16'sd7250;
    localparam signed [15:0] W_LOCAL_RNG = -16'sd5024;
    localparam signed [15:0] W_TRANS     =  16'sd704;
    // 7922 Q2.13 bias units shifted by 16 feature fraction bits.
    localparam signed [63:0] BIAS_Q29 = 64'sd519176192;

    wire signed [47:0] p_mean_abs  = mean_abs_amp_q16_16               * W_MEAN_ABS;
    wire signed [47:0] p_line      = line_length_q16_16                * W_LINE;
    wire signed [47:0] p_deriv_zc  = derivative_zero_crossings_q16_16  * W_DERIV_ZC;
    wire signed [47:0] p_thresh    = threshold_crossings_q16_16        * W_THRESH;
    wire signed [47:0] p_local_avg = local_amp_mean_q16_16             * W_LOCAL_AVG;
    wire signed [47:0] p_local_rng = local_amp_range_q16_16            * W_LOCAL_RNG;
    wire signed [47:0] p_trans     = amp_transition_q16_16             * W_TRANS;

    wire signed [63:0] score_next = BIAS_Q29
        + {{16{p_mean_abs[47]}},  p_mean_abs}
        + {{16{p_line[47]}},      p_line}
        + {{16{p_deriv_zc[47]}},  p_deriv_zc}
        + {{16{p_thresh[47]}},    p_thresh}
        + {{16{p_local_avg[47]}}, p_local_avg}
        + {{16{p_local_rng[47]}}, p_local_rng}
        + {{16{p_trans[47]}},     p_trans};

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            result_toggle <= 1'b0;
            vf <= 1'b0;
            score_q29 <= 64'sd0;
        end else if (features_valid) begin
            // The model's decision is VF for score > 0, VT otherwise.
            score_q29 <= score_next;
            vf <= (score_next > 64'sd0);
            result_toggle <= ~result_toggle;
        end
    end
endmodule
