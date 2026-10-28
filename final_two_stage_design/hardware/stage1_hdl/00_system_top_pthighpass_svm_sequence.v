/*
 * ecg_pthighpass_4feat_svm_sequence_top
 * -------------------------------------
 *
 * End-to-end path for the MATLAB pthighpass model shape:
 *
 *   Q3.8 ECG samples
 *       -> causal 5 Hz high-pass filter
 *       -> Q3.8 filtered samples
 *       -> feature_extractor_4feat_float_top
 *       -> svm_4feat_float_classifier
 *       -> sequence_count_gate
 *
 * The high-pass filter implements the causal 3rd-order Butterworth structure
 * used in train_q38_recall90_guard98_gate_fix_q38_meanonly_pthighpass.m.
 *
 * The SVM constants in svm_4feat_float_classifier.v are the folded
 * pthighpass-trained constants exported by the final software model. The
 * selected thesis sequence operating point is 2 abnormal votes out of the
 * last 3 windows.
 */

module ecg_pthighpass_4feat_svm_sequence_top #(
    parameter integer SAMPLE_WIDTH = 12,
    parameter integer WINDOW_SAMPLES = 240,
    parameter integer STEP_SAMPLES = 120,
    parameter integer WINDOW_SECONDS = 2,
    parameter integer SEQUENCE_LENGTH = 3,
    parameter integer SEQUENCE_COUNT_THRESHOLD = 2,
    parameter integer SEQUENCE_COUNT_WIDTH = $clog2(SEQUENCE_LENGTH + 1)
) (
    input  wire                           clk,
    input  wire                           resetn,

    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    output wire signed [SAMPLE_WIDTH-1:0] highpass_sample_out,
    output wire                           highpass_sample_valid,

    output wire [15:0]                    mean_abs_float,
    output wire [15:0]                    zero_crossings_float,
    output wire [15:0]                    line_length_float,
    output wire [15:0]                    threshold_crossing_count_float,
    output wire                           features_valid,
    output wire                           feature_bank,
    output wire [31:0]                    completed_window_count,

    output wire [15:0]                    svm_score_float,
    output wire                           svm_score_valid,
    output wire                           window_abnormal,
    output wire                           svm_busy,

    output wire [SEQUENCE_COUNT_WIDTH-1:0] abnormal_vote_count,
    output wire                           final_abnormal,
    output wire                           final_abnormal_valid,
    output wire [31:0]                    completed_sequence_count,

    output wire                           window_overflow
);

    ecg_pthighpass_iir #(
        .SAMPLE_WIDTH (SAMPLE_WIDTH)
    ) highpass_filter (
        .clk              (clk),
        .resetn           (resetn),
        .sample_in        (sample_in),
        .sample_valid     (sample_valid),
        .sample_out       (highpass_sample_out),
        .sample_out_valid (highpass_sample_valid)
    );

    feature_extractor_4feat_float_top #(
        .SAMPLE_WIDTH   (SAMPLE_WIDTH),
        .WINDOW_SAMPLES (WINDOW_SAMPLES),
        .STEP_SAMPLES   (STEP_SAMPLES),
        .WINDOW_SECONDS (WINDOW_SECONDS)
    ) feature_extractor (
        .clk                            (clk),
        .resetn                         (resetn),
        .sample_in                      (highpass_sample_out),
        .sample_valid                   (highpass_sample_valid),
        .mean_abs_float                 (mean_abs_float),
        .zero_crossings_float           (zero_crossings_float),
        .line_length_float              (line_length_float),
        .threshold_crossing_count_float (threshold_crossing_count_float),
        .features_valid                 (features_valid),
        .feature_bank                   (feature_bank),
        .completed_window_count         (completed_window_count),
        .window_overflow                (window_overflow)
    );

    svm_4feat_float_classifier svm_classifier (
        .clk                            (clk),
        .resetn                         (resetn),
        .mean_abs_float                 (mean_abs_float),
        .zero_crossings_float           (zero_crossings_float),
        .line_length_float              (line_length_float),
        .threshold_crossing_count_float (threshold_crossing_count_float),
        .features_valid                 (features_valid),
        .input_ready                    (),
        .svm_score_float                (svm_score_float),
        .svm_score_valid                (svm_score_valid),
        .seizure                        (window_abnormal),
        .busy                           (svm_busy)
    );

    sequence_count_gate #(
        .SEQUENCE_LENGTH (SEQUENCE_LENGTH),
        .COUNT_THRESHOLD (SEQUENCE_COUNT_THRESHOLD),
        .COUNT_WIDTH     (SEQUENCE_COUNT_WIDTH)
    ) sequence_gate (
        .clk                 (clk),
        .resetn              (resetn),
        .window_vote         (window_abnormal),
        .window_vote_valid   (svm_score_valid),
        .abnormal_vote_count (abnormal_vote_count),
        .sequence_abnormal   (final_abnormal),
        .sequence_valid      (final_abnormal_valid),
        .sequence_count      (completed_sequence_count)
    );

endmodule
