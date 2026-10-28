/*
 * basys3_low_power_detector_top
 * -----------------------------
 *
 * Small Basys 3 board wrapper for smoke-testing the final low-power ECG
 * detector package.
 *
 * This is not the final ADC/SD acquisition top. It uses switches as a manual
 * sample source:
 *
 *   sw[11:0] = signed Q3.8 sample_in
 *   btnC     = one-sample strobe, synchronized and edge-detected
 *   sw[14]   = automatic 120 Hz BRAM demonstration playback
 *   sw[15]   = external resetn; set high to run
 *
 * Human-visible LED status map:
 *
 *   led[0]    latest final sequence decision (1 = abnormal)
 *   led[1]    sticky sequence-result activity
 *   led[2]    latest SVM window decision (1 = abnormal)
 *   led[3]    sticky SVM-result activity
 *   led[4]    sticky feature-window activity
 *   led[5]    sticky high-pass output activity
 *   led[7:6]  latest abnormal vote count
 *   led[8]    sticky window-overflow fault
 *   led[9]    500 Hz clock ready
 *   led[10]   detector reset released / running
 *   led[11]   sticky input-sample activity
 *   led[12]   sign of latest high-pass sample
 *   led[13]   BRAM demonstration mode enabled
 *   led[14]   BRAM demonstration playback complete
 *   led[15]   approximately 1 Hz processing-clock heartbeat
 *
 * Sticky LEDs clear when sw[15] is taken low.
 *
 * For the real system, replace the switch/button sample source with the ADC
 * or SD acquisition path and keep the detector running from clk_500hz.
 */

module basys3_low_power_detector_top (
    input  wire        clk,
    input  wire        btnC,
    input  wire [15:0] sw,
    output wire [15:0] led
);

    wire clk_500hz;
    wire clk_locked;
    wire processing_resetn;
    wire external_resetn = sw[15];

    reg btn_sync_0;
    reg btn_sync_1;
    reg btn_sync_2;
    reg demo_enable_sync_0;
    reg demo_enable_sync_1;

    wire sample_valid_pulse =
        btn_sync_1 & ~btn_sync_2;

    wire signed [11:0] manual_sample_in_q38 =
        sw[11:0];

    wire signed [11:0] demo_sample_in_q38;
    wire demo_sample_valid;
    wire demo_playback_done;

    wire signed [11:0] selected_sample_in_q38 =
        demo_enable_sync_1 ? demo_sample_in_q38 : manual_sample_in_q38;
    wire selected_sample_valid =
        demo_enable_sync_1 ? demo_sample_valid : sample_valid_pulse;

    wire signed [11:0] highpass_sample_out;
    wire highpass_sample_valid;

    wire [15:0] mean_abs_float;
    wire [15:0] zero_crossings_float;
    wire [15:0] line_length_float;
    wire [15:0] threshold_crossing_count_float;
    wire features_valid;

    wire [15:0] svm_score_float;
    wire svm_score_valid;
    wire window_abnormal;

    wire [1:0] abnormal_vote_count;
    wire final_abnormal;
    wire final_abnormal_valid;
    wire window_overflow;

    reg sample_seen;
    reg highpass_seen;
    reg features_seen;
    reg svm_seen;
    reg sequence_seen;
    reg overflow_seen;
    reg [8:0] heartbeat_count;

    assign processing_resetn = external_resetn & clk_locked;

    low_power_clock_divider_100_to_500hz low_power_clock (
        .clk_100mhz      (clk),
        .external_resetn (external_resetn),
        .clk_500hz      (clk_500hz),
        .clock_ready     (clk_locked)
    );

    always @(posedge clk_500hz or negedge processing_resetn) begin
        if (!processing_resetn) begin
            btn_sync_0 <= 1'b0;
            btn_sync_1 <= 1'b0;
            btn_sync_2 <= 1'b0;
            demo_enable_sync_0 <= 1'b0;
            demo_enable_sync_1 <= 1'b0;
        end else begin
            btn_sync_0 <= btnC;
            btn_sync_1 <= btn_sync_0;
            btn_sync_2 <= btn_sync_1;
            demo_enable_sync_0 <= sw[14];
            demo_enable_sync_1 <= demo_enable_sync_0;
        end
    end

    ecg_bram_demo_source #(
        .SAMPLE_WIDTH   (12),
        .SAMPLE_COUNT   (1200),
        .CLOCK_HZ       (500),
        .SAMPLE_RATE_HZ (120),
        .MEMORY_FILE    ("17_bram_demo_input_samples.mem")
    ) demo_source (
        .clk           (clk_500hz),
        .resetn        (processing_resetn),
        .enable        (demo_enable_sync_1),
        .sample_out    (demo_sample_in_q38),
        .sample_valid  (demo_sample_valid),
        .playback_done (demo_playback_done)
    );

    /*
     * Most valid strobes last one 500 Hz clock cycle (2 ms), still too briefly
     * to see on an LED.  Latch one bit per processing stage so board bring-up
     * can show how far data travelled through the detector.  The overflow
     * fault is sticky for the same reason.
     */
    always @(posedge clk_500hz or negedge processing_resetn) begin
        if (!processing_resetn) begin
            sample_seen     <= 1'b0;
            highpass_seen   <= 1'b0;
            features_seen   <= 1'b0;
            svm_seen        <= 1'b0;
            sequence_seen   <= 1'b0;
            overflow_seen   <= 1'b0;
            heartbeat_count <= 9'd0;
        end else begin
            heartbeat_count <= heartbeat_count + 1'b1;

            if (selected_sample_valid)
                sample_seen <= 1'b1;
            if (highpass_sample_valid)
                highpass_seen <= 1'b1;
            if (features_valid)
                features_seen <= 1'b1;
            if (svm_score_valid)
                svm_seen <= 1'b1;
            if (final_abnormal_valid)
                sequence_seen <= 1'b1;
            if (window_overflow)
                overflow_seen <= 1'b1;
        end
    end

    ecg_pthighpass_4feat_svm_sequence_top #(
        .SAMPLE_WIDTH             (12),
        .WINDOW_SAMPLES           (240),
        .STEP_SAMPLES             (120),
        .WINDOW_SECONDS           (2),
        .SEQUENCE_LENGTH          (3),
        .SEQUENCE_COUNT_THRESHOLD (2)
    ) detector (
        .clk                            (clk_500hz),
        .resetn                         (processing_resetn),

        .sample_in                      (selected_sample_in_q38),
        .sample_valid                   (selected_sample_valid),

        .highpass_sample_out            (highpass_sample_out),
        .highpass_sample_valid          (highpass_sample_valid),

        .mean_abs_float                 (mean_abs_float),
        .zero_crossings_float           (zero_crossings_float),
        .line_length_float              (line_length_float),
        .threshold_crossing_count_float (threshold_crossing_count_float),
        .features_valid                 (features_valid),
        .feature_bank                   (),
        .completed_window_count         (),

        .svm_score_float                (svm_score_float),
        .svm_score_valid                (svm_score_valid),
        .window_abnormal                (window_abnormal),
        .svm_busy                       (),

        .abnormal_vote_count            (abnormal_vote_count),
        .final_abnormal                 (final_abnormal),
        .final_abnormal_valid           (final_abnormal_valid),
        .completed_sequence_count       (),

        .window_overflow                (window_overflow)
    );

    assign led[0]  = final_abnormal;
    assign led[1]  = sequence_seen;
    assign led[2]  = window_abnormal;
    assign led[3]  = svm_seen;
    assign led[4]  = features_seen;
    assign led[5]  = highpass_seen;
    assign led[6]  = abnormal_vote_count[0];
    assign led[7]  = abnormal_vote_count[1];
    assign led[8]  = overflow_seen;
    assign led[9]  = clk_locked;
    assign led[10] = processing_resetn;
    assign led[11] = sample_seen;
    assign led[12] = highpass_sample_out[11];
    assign led[13] = demo_enable_sync_1;
    assign led[14] = demo_playback_done;
    assign led[15] = heartbeat_count[8];

endmodule
