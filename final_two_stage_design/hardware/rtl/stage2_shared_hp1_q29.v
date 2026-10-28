// Causal third-order 1 Hz high-pass for the shared-feature Stage 2 model.
// Input is the common Q3.8 front end; internal state is Q10.29. Coefficients
// are scipy.signal.butter(3, 1, btype="high", fs=120) rounded to Q2.29.
module stage2_shared_hp1_q29 (
    input wire clk, resetn, sample_valid,
    input wire signed [11:0] sample_q3_8,
    output reg output_valid,
    output reg signed [13:0] output_q5_8
);
    localparam signed [31:0] B0 = 32'sd509480620;
    localparam signed [31:0] B1 = -32'sd1528441861;
    localparam signed [31:0] B2 = 32'sd1528441861;
    localparam signed [31:0] B3 = -32'sd509480620;
    localparam signed [31:0] A1 = -32'sd1554398152;
    localparam signed [31:0] A2 = 32'sd1501088162;
    localparam signed [31:0] A3 = -32'sd483487738;

    reg signed [39:0] x1, x2, x3, y1, y2, y3;
    wire signed [39:0] x0 = $signed(sample_q3_8) <<< 21;
    wire signed [79:0] sum_q58 =
        $signed(x0) * B0 + $signed(x1) * B1 +
        $signed(x2) * B2 + $signed(x3) * B3 -
        $signed(y1) * A1 - $signed(y2) * A2 - $signed(y3) * A3;
    wire signed [79:0] scaled = sum_q58 >= 0 ?
        sum_q58 >>> 29 : -((-sum_q58) >>> 29);
    wire signed [39:0] next_y = scaled[39:0];
    wire signed [39:0] rounded_q8 = next_y >= 0 ?
        next_y >>> 21 : -((-next_y) >>> 21);
    wire signed [13:0] clamped_q8 = rounded_q8 > 40'sd8191 ? 14'sd8191 :
        rounded_q8 < -40'sd8192 ? -14'sd8192 : rounded_q8[13:0];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            x1 <= 0; x2 <= 0; x3 <= 0;
            y1 <= 0; y2 <= 0; y3 <= 0;
            output_q5_8 <= 0; output_valid <= 0;
        end else begin
            output_valid <= sample_valid;
            if (sample_valid) begin
                x3 <= x2; x2 <= x1; x1 <= x0;
                y3 <= y2; y2 <= y1; y1 <= next_y;
                output_q5_8 <= clamped_q8;
            end
        end
    end
endmodule
