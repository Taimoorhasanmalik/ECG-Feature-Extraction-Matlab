`timescale 1ns/1ps

/*
 * ecg_low_power_clocked_wrapper
 * -----------------------------
 *
 * Board-level wrapper for the final low-power ECG detector.
 *
 * A small fabric divider and BUFG replace the Clock Wizard/MMCM. This removes
 * the MMCM's fixed VCCAUX power while retaining a 500 Hz global clock.
 *
 * The ECG processing pipeline runs from the 500 Hz clock. The incoming
 * sample_in/sample_valid interface must be synchronous to clk_500hz.
 */

module low_power_clock_divider_100_to_500hz (
    input  wire clk_100mhz,
    input  wire external_resetn,
    output wire clk_500hz,
    output wire clock_ready
);

    reg [16:0] divide_count;
    reg       divided_clock;

    /* Toggle every 100,000 input cycles: 100 MHz / 200,000 = 500 Hz. */
    always @(posedge clk_100mhz or negedge external_resetn) begin
        if (!external_resetn) begin
            divide_count  <= 17'd0;
            divided_clock <= 1'b0;
        end else if (divide_count == 17'd99999) begin
            divide_count  <= 17'd0;
            divided_clock <= ~divided_clock;
        end else begin
            divide_count <= divide_count + 1'b1;
        end
    end

    /* Put the divided clock on the dedicated global clock network. */
    BUFG clk_500hz_buf (
        .I (divided_clock),
        .O (clk_500hz)
    );

    /* Asynchronous assertion and synchronous release in the 500 Hz domain. */
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync;

    always @(posedge clk_500hz or negedge external_resetn) begin
        if (!external_resetn)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end

    assign clock_ready = reset_sync[1];

endmodule

module ecg_low_power_clocked_wrapper #(
    parameter integer SAMPLE_WIDTH = 12
) (
    input  wire                           clk_100mhz,
    input  wire                           external_resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    output wire                           clk_500hz,
    output wire                           clk_locked,
    output wire                           processing_resetn,

    output wire signed [SAMPLE_WIDTH-1:0] highpass_sample_out,
    output wire                           highpass_sample_valid,

    output wire [15:0]                    mean_abs_float,
    output wire [15:0]                    zero_crossings_float,
    output wire [15:0]                    line_length_float,
    output wire [15:0]                    threshold_crossing_count_float,
    output wire                           features_valid,

    output wire [15:0]                    svm_score_float,
    output wire                           svm_score_valid,
    output wire                           window_abnormal,

    output wire [1:0]                     abnormal_vote_count,
    output wire                           final_abnormal,
    output wire                           final_abnormal_valid,

    output wire                           window_overflow
);

    wire feature_bank;
    wire [31:0] completed_window_count;
    wire svm_busy;
    wire [31:0] completed_sequence_count;

    assign processing_resetn = external_resetn & clk_locked;

    low_power_clock_divider_100_to_500hz low_power_clock (
        .clk_100mhz     (clk_100mhz),
        .external_resetn(external_resetn),
        .clk_500hz     (clk_500hz),
        .clock_ready    (clk_locked)
    );

    ecg_pthighpass_4feat_svm_sequence_top #(
        .SAMPLE_WIDTH             (SAMPLE_WIDTH),
        .WINDOW_SAMPLES           (240),
        .STEP_SAMPLES             (120),
        .WINDOW_SECONDS           (2),
        .SEQUENCE_LENGTH          (3),
        .SEQUENCE_COUNT_THRESHOLD (2)
    ) detector (
        .clk                            (clk_500hz),
        .resetn                         (processing_resetn),

        .sample_in                      (sample_in),
        .sample_valid                   (sample_valid),

        .highpass_sample_out            (highpass_sample_out),
        .highpass_sample_valid          (highpass_sample_valid),

        .mean_abs_float                 (mean_abs_float),
        .zero_crossings_float           (zero_crossings_float),
        .line_length_float              (line_length_float),
        .threshold_crossing_count_float (threshold_crossing_count_float),
        .features_valid                 (features_valid),
        .feature_bank                   (feature_bank),
        .completed_window_count         (completed_window_count),

        .svm_score_float                (svm_score_float),
        .svm_score_valid                (svm_score_valid),
        .window_abnormal                (window_abnormal),
        .svm_busy                       (svm_busy),

        .abnormal_vote_count            (abnormal_vote_count),
        .final_abnormal                 (final_abnormal),
        .final_abnormal_valid           (final_abnormal_valid),
        .completed_sequence_count       (completed_sequence_count),

        .window_overflow                (window_overflow)
    );

endmodule
