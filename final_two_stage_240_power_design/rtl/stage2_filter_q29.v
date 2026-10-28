// Stage 2 causal filters. All coefficients are signed integers scaled by 2^29.
// Internal IIR samples are signed 40-bit Q10.29; division truncates toward zero.
module stage2_biquad_q29 #(
    parameter signed [31:0] B0 = 0, B1 = 0, B2 = 0,
    parameter signed [31:0] A1 = 0, A2 = 0
) (
    input wire clk, resetn, input_valid,
    input wire signed [39:0] x_q29,
    output reg output_valid,
    output reg signed [39:0] y_q29
);
    reg signed [39:0] x1, x2, y1, y2;
    wire signed [79:0] sum_q58 =
        $signed(x_q29) * $signed(B0) +
        $signed(x1) * $signed(B1) +
        $signed(x2) * $signed(B2) -
        $signed(y1) * $signed(A1) -
        $signed(y2) * $signed(A2);
    wire signed [79:0] scaled = sum_q58 >= 0 ?
        (sum_q58 >>> 29) : -((-sum_q58) >>> 29);
    wire signed [39:0] next_y = scaled[39:0];
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            x1 <= 0; x2 <= 0; y1 <= 0; y2 <= 0;
            y_q29 <= 0; output_valid <= 0;
        end else begin
            output_valid <= input_valid;
            if (input_valid) begin
                x2 <= x1; x1 <= x_q29;
                y2 <= y1; y1 <= next_y;
                y_q29 <= next_y;
            end
        end
    end
endmodule

module stage2_filter_q29 (
    input wire clk, resetn, sample_valid,
    input wire signed [31:0] sample_q16_16,
    output wire output_valid,
    output wire signed [13:0] output_q5_8
);
    // scipy/MATLAB butter(1,0.1,'high',fs=120), rounded to Q2.29.
    localparam signed [31:0] DB0 = 32'sd535469054;
    localparam signed [31:0] DB1 = -32'sd535469054;
    localparam signed [31:0] DA1 = -32'sd534067196;
    reg signed [31:0] dc_x1, dc_y1;
    reg signed [13:0] dc_out;
    reg dc_valid;
    wire signed [71:0] dc_sum =
        $signed(sample_q16_16) * $signed(DB0) +
        $signed(dc_x1) * $signed(DB1) -
        $signed(dc_y1) * $signed(DA1);
    wire signed [71:0] dc_scaled = dc_sum >= 0 ?
        (dc_sum >>> 29) : -((-dc_sum) >>> 29);
    wire signed [31:0] dc_y_next = dc_scaled[31:0];
    // Q16.16 -> Q5.8, truncation toward zero, then saturation.
    wire signed [31:0] dc_q8 = dc_y_next >= 0 ?
        (dc_y_next >>> 8) : -((-dc_y_next) >>> 8);
    wire signed [13:0] dc_clamped = dc_q8 > 32'sd8191 ? 14'sd8191 :
        dc_q8 < -32'sd8192 ? -14'sd8192 : dc_q8[13:0];
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            dc_x1 <= 0; dc_y1 <= 0; dc_out <= 0; dc_valid <= 0;
        end else begin
            dc_valid <= sample_valid;
            if (sample_valid) begin
                dc_x1 <= sample_q16_16;
                dc_y1 <= dc_y_next;
                dc_out <= dc_clamped;
            end
        end
    end

    wire [4:0] valid;
    wire signed [39:0] y [0:4];
    assign valid[0] = dc_valid;
    assign y[0] = $signed(dc_out) <<< 21;
    // Four sections from final_two_stage_design/stage2/deliverable/
    // stage2_hardware_model.json, rounded to Q2.29.
    stage2_biquad_q29 #(
        .B0(32'sd120953413), .B1(32'sd241906826), .B2(32'sd120953413),
        .A1(32'sd291847725), .A2(32'sd58520377)
    ) s0(clk, resetn, valid[0], y[0], valid[1], y[1]);
    stage2_biquad_q29 #(
        .B0(32'sd536870912), .B1(32'sd1073741824), .B2(32'sd536870912),
        .A1(32'sd403112624), .A2(32'sd271979909)
    ) s1(clk, resetn, valid[1], y[1], valid[2], y[2]);
    stage2_biquad_q29 #(
        .B0(32'sd536870912), .B1(-32'sd1073741824), .B2(32'sd536870912),
        .A1(-32'sd1047752273), .A2(32'sd511249993)
    ) s2(clk, resetn, valid[2], y[2], valid[3], y[3]);
    stage2_biquad_q29 #(
        .B0(32'sd536870912), .B1(-32'sd1073741824), .B2(32'sd536870912),
        .A1(-32'sd1062839945), .A2(32'sd526334946)
    ) s3(clk, resetn, valid[3], y[3], valid[4], y[4]);
    wire signed [39:0] out_q8 = y[4] >= 0 ?
        (y[4] >>> 21) : -((-y[4]) >>> 21);
    assign output_q5_8 = out_q8 > 40'sd8191 ? 14'sd8191 :
        out_q8 < -40'sd8192 ? -14'sd8192 : out_q8[13:0];
    assign output_valid = valid[4];
endmodule
