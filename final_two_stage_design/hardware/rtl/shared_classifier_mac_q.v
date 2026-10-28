// One clock-gated, time-multiplexed multiply-accumulate classifier for both
// stages. Stage 1 and the six-feature 1 Hz Stage 2 export use a common Q40
// score accumulator. One selected feature/weight pair is processed per clock.
module shared_classifier_mac_q #(
    parameter GATE_IDLE_CLOCK=1
) (
    input wire clk, resetn, request_valid, request_stage2,
    input wire [31:0] request_window_id,
    input wire signed [31:0] f0, f1, f2, f3, f4, f5,
    output wire input_ready, classifier_clock_enabled,
    output reg result_valid, output reg [31:0] result_window_id,
    output reg result_stage2, output reg vf,
    output reg signed [63:0] score_q40,
    output reg overflow
);
    localparam signed [63:0] STAGE1_BIAS_Q40=64'sd793979191296;
    localparam signed [63:0] STAGE2_BIAS_Q40=64'sd1386469130240;

    reg pending, request_toggle, seen_result_toggle;
    reg held_stage2;
    reg [31:0] held_id;
    reg signed [31:0] h0,h1,h2,h3,h4,h5;
    wire gated_clk;
    reg seen_request_toggle, result_toggle_core, active;
    reg [2:0] index;
    reg signed [63:0] accumulator, score_core;
    reg [31:0] result_id_core;
    reg result_stage2_core, vf_core;

    assign input_ready=!pending;
    assign classifier_clock_enabled=resetn && (GATE_IDLE_CLOCK ? pending : 1'b1);
    BUFGCE #(.CE_TYPE("SYNC"),.SIM_DEVICE("7SERIES")) gate (
        .I(clk),.CE(classifier_clock_enabled),.O(gated_clk));

    reg signed [31:0] selected_feature,selected_weight;
    always @* begin
        selected_feature=0;selected_weight=0;
        case(index)
            3'd0: begin
                selected_feature=h0;
                selected_weight=held_stage2 ? -32'sd41836544 : 32'sd44266604;
            end
            3'd1: begin
                selected_feature=h1;
                selected_weight=held_stage2 ? -32'sd344064 : -32'sd1368018;
            end
            3'd2: begin
                selected_feature=h2;
                selected_weight=held_stage2 ? 32'sd1150976 : -32'sd435043;
            end
            3'd3: begin
                selected_feature=h3;
                selected_weight=held_stage2 ? 32'sd126976 : 32'sd1618828;
            end
            3'd4: begin
                selected_feature=h4;
                selected_weight=held_stage2 ? -32'sd11345920 : 0;
            end
            3'd5: begin
                selected_feature=h5;
                selected_weight=held_stage2 ? -32'sd4149248 : 0;
            end
            default: begin selected_feature=0;selected_weight=0;end
        endcase
    end
    wire signed [63:0] sum_next=accumulator+
        $signed(selected_feature)*$signed(selected_weight);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            pending<=0;request_toggle<=0;seen_result_toggle<=0;
            held_stage2<=0;held_id<=0;
            h0<=0;h1<=0;h2<=0;h3<=0;h4<=0;h5<=0;
            result_valid<=0;result_window_id<=0;result_stage2<=0;
            vf<=0;score_q40<=0;overflow<=0;
        end else begin
            result_valid<=0;
            if (result_toggle_core!=seen_result_toggle) begin
                seen_result_toggle<=result_toggle_core;
                result_valid<=1;
                result_window_id<=result_id_core;
                result_stage2<=result_stage2_core;
                vf<=vf_core;score_q40<=score_core;
                pending<=0;
            end
            if (request_valid) begin
                if (pending) overflow<=1;
                else begin
                    held_stage2<=request_stage2;held_id<=request_window_id;
                    h0<=f0;h1<=f1;h2<=f2;h3<=f3;h4<=f4;h5<=f5;
                    request_toggle<=~request_toggle;pending<=1;
                end
            end
        end
    end

    always @(posedge gated_clk or negedge resetn) begin
        if (!resetn) begin
            seen_request_toggle<=0;result_toggle_core<=0;active<=0;
            index<=0;accumulator<=0;score_core<=0;
            result_id_core<=0;result_stage2_core<=0;vf_core<=0;
        end else if (request_toggle!=seen_request_toggle) begin
            seen_request_toggle<=request_toggle;
            accumulator<=held_stage2 ? STAGE2_BIAS_Q40 : STAGE1_BIAS_Q40;
            index<=0;active<=1;
        end else if (active) begin
            if (index==(held_stage2 ? 3'd5 : 3'd3)) begin
                score_core<=sum_next;
                result_id_core<=held_id;
                result_stage2_core<=held_stage2;
                vf_core<=sum_next>0;
                result_toggle_core<=~result_toggle_core;
                active<=0;
            end else begin
                accumulator<=sum_next;
                index<=index+3'd1;
            end
        end
    end
endmodule
