// Logical two-stage pipeline. clk is 500 Hz; sample_valid is 120 Hz.
// Input is a signed Q16.16 ECG sample after source-specific acquisition.
// Class encoding: 0=Other, 1=VT, 2=VF-family.
module two_stage_ecg_top (
    input wire clk, resetn, sample_valid,
    input wire signed [31:0] sample_q16_16,
    output reg class_valid,
    output reg [31:0] class_window_id,
    output reg [1:0] class_code,
    output wire classifier_clock_enabled,
    output wire stage1_window_overflow, stage2_window_overflow,
    output wire classifier_overflow
);
    wire signed [63:0] raw_wide = {{32{sample_q16_16[31]}}, sample_q16_16};
    wire signed [63:0] raw_q8 = raw_wide >= 0 ?
        (raw_wide >>> 8) : -((-raw_wide) >>> 8);
    wire signed [11:0] s1_sample = raw_q8 > 64'sd2047 ? 12'sd2047 :
        raw_q8 < -64'sd2048 ? -12'sd2048 : raw_q8[11:0];

    wire s1_abnormal, s1_valid;
    wire [31:0] s1_window_id;
    stage1_fixed_path stage1 (
        .clk(clk), .resetn(resetn), .sample_q3_8(s1_sample),
        .sample_valid(sample_valid), .sequence_abnormal(s1_abnormal),
        .sequence_valid(s1_valid), .sequence_window_id(s1_window_id),
        .window_overflow(stage1_window_overflow)
    );

    wire s2_sample_valid;
    wire signed [13:0] s2_sample;
    stage2_filter_q29 filter2 (
        .clk(clk), .resetn(resetn), .sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),
        .output_valid(s2_sample_valid), .output_q5_8(s2_sample)
    );
    wire s2_feature_valid;
    wire [31:0] s2_window_id;
    wire signed [11:0] s2_f0, s2_f4, s2_f5, s2_f6;
    wire signed [16:0] s2_f1;
    wire signed [8:0] s2_f2, s2_f3;
    stage2_features_q features2 (
        .clk(clk), .resetn(resetn), .sample_valid(s2_sample_valid),
        .sample_q8(s2_sample), .features_valid(s2_feature_valid),
        .window_id(s2_window_id), .mean_abs_q3_8(s2_f0),
        .line_length_q8_8(s2_f1), .derivative_zc(s2_f2),
        .threshold_crossings(s2_f3), .local_amp_mean_q3_8(s2_f4),
        .local_amp_range_q3_8(s2_f5), .amp_transition_q3_8(s2_f6),
        .overflow(stage2_window_overflow)
    );

    reg [31:0] cache_id, decision_id;
    reg cache_valid, decision_seen, decision_abnormal, submitted;
    reg signed [31:0] c0, c1, c2, c3, c4, c5, c6;
    reg hold_awake, one_normal;
    wire classifier_ready, classifier_result_valid, classifier_vf;
    wire classifier_core_overflow;
    reg alignment_overflow;
    reg [31:0] last_class_window_id;
    reg has_class_result;
    assign classifier_overflow = classifier_core_overflow | alignment_overflow;
    wire [31:0] classifier_result_id;
    wire signed [63:0] classifier_score;
    wire dispatch = decision_seen && decision_abnormal && !submitted &&
        cache_valid && cache_id == decision_id && classifier_ready;

    stage2_classifier_gated_q classifier2 (
        .clk(clk), .resetn(resetn), .hold_awake(hold_awake),
        .request_valid(dispatch), .request_window_id(decision_id),
        .f0_q16_16(c0), .f1_q16_16(c1), .f2_q16_16(c2),
        .f3_q16_16(c3), .f4_q16_16(c4), .f5_q16_16(c5),
        .f6_q16_16(c6), .input_ready(classifier_ready),
        .classifier_clock_enabled(classifier_clock_enabled),
        .result_valid(classifier_result_valid),
        .result_window_id(classifier_result_id),
        .vf(classifier_vf), .score_q29(classifier_score),
        .overflow(classifier_core_overflow)
    );

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cache_id <= 0; decision_id <= 0;
            cache_valid <= 0; decision_seen <= 0;
            decision_abnormal <= 0; submitted <= 0;
            c0 <= 0; c1 <= 0; c2 <= 0; c3 <= 0;
            c4 <= 0; c5 <= 0; c6 <= 0;
            hold_awake <= 0; one_normal <= 0;
            class_valid <= 0; class_window_id <= 0; class_code <= 0;
            alignment_overflow <= 0;
            last_class_window_id <= 0; has_class_result <= 0;
        end else begin
            class_valid <= 0;
            if (decision_seen && decision_abnormal && !submitted &&
                cache_valid && cache_id > decision_id)
                alignment_overflow <= 1;
            if (s2_feature_valid) begin
                cache_valid <= 1;
                cache_id <= s2_window_id;
                c0 <= $signed(s2_f0) <<< 8;
                c1 <= $signed(s2_f1) <<< 8;
                c2 <= $signed(s2_f2) <<< 16;
                c3 <= $signed(s2_f3) <<< 16;
                c4 <= $signed(s2_f4) <<< 8;
                c5 <= $signed(s2_f5) <<< 8;
                c6 <= $signed(s2_f6) <<< 8;
            end
            if (dispatch) submitted <= 1;
            if (s1_valid) begin
                decision_id <= s1_window_id;
                decision_seen <= 1;
                decision_abnormal <= s1_abnormal;
                submitted <= 0;
                if (s1_abnormal) begin
                    hold_awake <= 1;
                    one_normal <= 0;
                end else begin
                    if (one_normal) hold_awake <= 0;
                    one_normal <= 1;
                    class_valid <= 1;
                    class_window_id <= s1_window_id;
                    class_code <= 0;
                end
            end
            if (classifier_result_valid) begin
                if ((has_class_result && classifier_result_id <= last_class_window_id) ||
                    (s1_valid && !s1_abnormal))
                    alignment_overflow <= 1;
                else begin
                    class_valid <= 1;
                    class_window_id <= classifier_result_id;
                    class_code <= classifier_vf ? 2'd2 : 2'd1;
                end
            end
            if (class_valid) begin
                last_class_window_id <= class_window_id;
                has_class_result <= 1;
            end
        end
    end
endmodule
