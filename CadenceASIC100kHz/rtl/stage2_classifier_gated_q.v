// Only this Stage 2 classifier uses the gated clock. Filter/features and
// request/result registers remain on the parent 500 Hz clock.
module stage2_classifier_gated_q #(
    parameter signed [15:0] W0 = -16'sd7588,
    parameter signed [15:0] W1 = 16'sd189,
    parameter signed [15:0] W2 = -16'sd1,
    parameter signed [15:0] W3 = 16'sd3,
    parameter signed [15:0] W4 = -16'sd7586,
    parameter signed [15:0] W5 = -16'sd5208,
    parameter signed [15:0] W6 = 16'sd1246,
    parameter signed [63:0] BIAS_Q29 = 64'sd536084480
) (
    input wire clk, resetn, hold_awake,
    input wire request_valid,
    input wire [31:0] request_window_id,
    input wire signed [31:0] f0_q16_16, f1_q16_16, f2_q16_16,
    input wire signed [31:0] f3_q16_16, f4_q16_16, f5_q16_16,
    input wire signed [31:0] f6_q16_16,
    output wire input_ready, classifier_clock_enabled,
    output reg result_valid, output reg [31:0] result_window_id,
    output reg vf, output reg signed [63:0] score_q29,
    output reg overflow
);
    reg pending, request_toggle, seen_result_toggle;
    reg [31:0] held_id;
    reg signed [31:0] f0, f1, f2, f3, f4, f5, f6;
    wire gated_clk;
    reg seen_request_toggle, result_toggle_core;
    reg [31:0] result_id_core;
    reg vf_core;
    reg signed [63:0] score_core;
    wire gate_ce = resetn && (hold_awake || pending);
    assign classifier_clock_enabled = gate_ce;
    assign input_ready = !pending;
    BUFGCE #(.CE_TYPE("SYNC"), .SIM_DEVICE("7SERIES")) gate (
        .I(clk), .CE(gate_ce), .O(gated_clk));

    // Defaults are the v3 model. The shared-front-end top overrides these
    // with the separately fitted Q2.13 coefficients from its MAT artifact.
    wire signed [63:0] score_next = BIAS_Q29 +
        $signed(f0) * $signed(W0) + $signed(f1) * $signed(W1) +
        $signed(f2) * $signed(W2) + $signed(f3) * $signed(W3) +
        $signed(f4) * $signed(W4) + $signed(f5) * $signed(W5) +
        $signed(f6) * $signed(W6);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            pending <= 0; request_toggle <= 0; seen_result_toggle <= 0;
            held_id <= 0; f0 <= 0; f1 <= 0; f2 <= 0; f3 <= 0;
            f4 <= 0; f5 <= 0; f6 <= 0;
            result_valid <= 0; result_window_id <= 0;
            vf <= 0; score_q29 <= 0; overflow <= 0;
        end else begin
            result_valid <= 0;
            if (result_toggle_core != seen_result_toggle) begin
                seen_result_toggle <= result_toggle_core;
                result_valid <= 1;
                result_window_id <= result_id_core;
                vf <= vf_core; score_q29 <= score_core;
                pending <= 0;
            end
            if (request_valid) begin
                if (pending) overflow <= 1;
                else begin
                    f0 <= f0_q16_16; f1 <= f1_q16_16; f2 <= f2_q16_16;
                    f3 <= f3_q16_16; f4 <= f4_q16_16; f5 <= f5_q16_16;
                    f6 <= f6_q16_16; held_id <= request_window_id;
                    request_toggle <= ~request_toggle; pending <= 1;
                end
            end
        end
    end

    always @(posedge gated_clk or negedge resetn) begin
        if (!resetn) begin
            seen_request_toggle <= 0; result_toggle_core <= 0;
            result_id_core <= 0; vf_core <= 0; score_core <= 0;
        end else if (request_toggle != seen_request_toggle) begin
            seen_request_toggle <= request_toggle;
            result_toggle_core <= ~result_toggle_core;
            result_id_core <= held_id;
            score_core <= score_next;
            vf_core <= score_next > 0;
        end
    end
endmodule
