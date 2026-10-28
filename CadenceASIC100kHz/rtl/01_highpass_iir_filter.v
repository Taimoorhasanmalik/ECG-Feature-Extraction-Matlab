/*
 * ecg_pthighpass_iir
 * ------------------
 *
 * Fixed-point causal high-pass preprocessing stage for the MATLAB
 * pthighpass model:
 *
 *   [b, a] = butter(3, 5/(120/2), 'high');
 *   y      = filter(b, a, x);
 *   y_q38  = fix(y * 256) / 256;
 *
 * Input and output are signed Q3.8 integers. The internal filter keeps a
 * wider Q(FRAC_BITS + COEFF_FRAC_BITS) state so feedback precision is not
 * lost after every sample.
 *
 * Difference equation:
 *
 *   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + b3*x[n-3]
 *        - a1*y[n-1] - a2*y[n-2] - a3*y[n-3]
 *
 * The feedback coefficients below are stored as -a1, -a2, -a3 so the datapath
 * is a straight sum of products.
 */

module ecg_pthighpass_iir #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer FRAC_BITS = 8,
    parameter integer COEFF_WIDTH = 32,
    parameter integer COEFF_FRAC_BITS = 20,
    parameter integer STATE_WIDTH = 64,
    parameter integer PRODUCT_WIDTH = 96,

    parameter signed [COEFF_WIDTH-1:0] B0  = 32'sh000C4E29,
    parameter signed [COEFF_WIDTH-1:0] B1  = 32'shFFDB1585,
    parameter signed [COEFF_WIDTH-1:0] B2  = 32'sh0024EA7B,
    parameter signed [COEFF_WIDTH-1:0] B3  = 32'shFFF3B1D7,
    parameter signed [COEFF_WIDTH-1:0] NA1 = 32'sh0027A52B,
    parameter signed [COEFF_WIDTH-1:0] NA2 = 32'shFFDEAA9C,
    parameter signed [COEFF_WIDTH-1:0] NA3 = 32'sh000976B8
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    output reg  signed [SAMPLE_WIDTH-1:0] sample_out,
    output reg                            sample_out_valid
);

    localparam integer STATE_FRAC_BITS = FRAC_BITS + COEFF_FRAC_BITS;
    localparam integer OUTPUT_SHIFT = STATE_FRAC_BITS - FRAC_BITS;

    localparam signed [STATE_WIDTH-1:0] Q_MAX =
        ({{(STATE_WIDTH-1){1'b0}}, 1'b1} <<< (SAMPLE_WIDTH - 1)) - 1;

    localparam signed [STATE_WIDTH-1:0] Q_MIN =
        -({{(STATE_WIDTH-1){1'b0}}, 1'b1} <<< (SAMPLE_WIDTH - 1));

    reg signed [SAMPLE_WIDTH-1:0] x1;
    reg signed [SAMPLE_WIDTH-1:0] x2;
    reg signed [SAMPLE_WIDTH-1:0] x3;

    reg signed [STATE_WIDTH-1:0] y1;
    reg signed [STATE_WIDTH-1:0] y2;
    reg signed [STATE_WIDTH-1:0] y3;

    wire signed [PRODUCT_WIDTH-1:0] ff0 =
        $signed(sample_in) * $signed(B0);
    wire signed [PRODUCT_WIDTH-1:0] ff1 =
        $signed(x1) * $signed(B1);
    wire signed [PRODUCT_WIDTH-1:0] ff2 =
        $signed(x2) * $signed(B2);
    wire signed [PRODUCT_WIDTH-1:0] ff3 =
        $signed(x3) * $signed(B3);

    wire signed [PRODUCT_WIDTH-1:0] fb1_full =
        $signed(y1) * $signed(NA1);
    wire signed [PRODUCT_WIDTH-1:0] fb2_full =
        $signed(y2) * $signed(NA2);
    wire signed [PRODUCT_WIDTH-1:0] fb3_full =
        $signed(y3) * $signed(NA3);

    wire signed [PRODUCT_WIDTH-1:0] fb1 = fb1_full >>> COEFF_FRAC_BITS;
    wire signed [PRODUCT_WIDTH-1:0] fb2 = fb2_full >>> COEFF_FRAC_BITS;
    wire signed [PRODUCT_WIDTH-1:0] fb3 = fb3_full >>> COEFF_FRAC_BITS;

    wire signed [PRODUCT_WIDTH-1:0] y_sum =
        ff0 + ff1 + ff2 + ff3 + fb1 + fb2 + fb3;

    wire signed [STATE_WIDTH-1:0] next_y =
        y_sum[STATE_WIDTH-1:0];

    wire signed [STATE_WIDTH-1:0] shifted_positive =
        next_y >>> OUTPUT_SHIFT;

    wire signed [STATE_WIDTH-1:0] shifted_toward_zero =
        next_y[STATE_WIDTH-1]
            ? -(( -next_y ) >>> OUTPUT_SHIFT)
            : shifted_positive;

    wire signed [SAMPLE_WIDTH-1:0] saturated_output =
        (shifted_toward_zero > Q_MAX)
            ? {1'b0, {(SAMPLE_WIDTH-1){1'b1}}}
        : (shifted_toward_zero < Q_MIN)
            ? {1'b1, {(SAMPLE_WIDTH-1){1'b0}}}
        : shifted_toward_zero[SAMPLE_WIDTH-1:0];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            x1 <= {SAMPLE_WIDTH{1'b0}};
            x2 <= {SAMPLE_WIDTH{1'b0}};
            x3 <= {SAMPLE_WIDTH{1'b0}};
            y1 <= {STATE_WIDTH{1'b0}};
            y2 <= {STATE_WIDTH{1'b0}};
            y3 <= {STATE_WIDTH{1'b0}};
            sample_out <= {SAMPLE_WIDTH{1'b0}};
            sample_out_valid <= 1'b0;
        end else begin
            sample_out_valid <= 1'b0;

            if (sample_valid) begin
                x3 <= x2;
                x2 <= x1;
                x1 <= sample_in;

                y3 <= y2;
                y2 <= y1;
                y1 <= next_y;

                sample_out <= saturated_output;
                sample_out_valid <= 1'b1;
            end
        end
    end

endmodule
