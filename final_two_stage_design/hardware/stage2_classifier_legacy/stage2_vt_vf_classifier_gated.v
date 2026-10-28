// Dedicated FPGA clock gate and one-entry bridge for the Stage 2 classifier.
// clk is the existing FPGA processing clock; 120 Hz is a sample-valid rate.
// gate_active is the latest Stage 1 sequence decision and must be synchronous
// to clk. The newest feature vector is cached even while the classifier sleeps.
// Keep the Stage 2 filter and feature state on the always-on clock, or replay
// buffered samples after waking it; this wrapper gates only the SVM clock.
module stage2_vt_vf_classifier_gated (
    input  wire                    clk,
    input  wire                    resetn,
    input  wire                    gate_active,
    input  wire                    features_valid,
    input  wire signed [31:0]      mean_abs_amp_q16_16,
    input  wire signed [31:0]      line_length_q16_16,
    input  wire signed [31:0]      derivative_zero_crossings_q16_16,
    input  wire signed [31:0]      threshold_crossings_q16_16,
    input  wire signed [31:0]      local_amp_mean_q16_16,
    input  wire signed [31:0]      local_amp_range_q16_16,
    input  wire signed [31:0]      amp_transition_q16_16,
    output wire                    input_ready,
    output wire                    classifier_clock_enabled,
    output reg                     result_valid,
    output reg                     vf,
    output reg signed [63:0]       score_q29,
    output reg                     input_overflow
);
    reg pending;
    reg cache_unprocessed;
    reg cache_must_process;
    reg seen_pending;
    reg seen_result_toggle;
    reg signed [31:0] c0, c1, c2, c3, c4, c5, c6;
    reg signed [31:0] f0, f1, f2, f3, f4, f5, f6;
    wire classifier_clk;
    wire result_toggle_core;
    wire vf_core;
    wire signed [63:0] score_core;

    // Finish an accepted item and give the one-shot detector one clock to
    // rearm before the BUFGCE closes. A sleeping classifier has no clock edges.
    wire gate_request = resetn &
        (((gate_active | cache_must_process) & cache_unprocessed)
         | pending | seen_pending);
    assign classifier_clock_enabled = gate_request;
    // While asleep a newer window intentionally replaces the cached window.
    // While awake, ready means no unprocessed feature will be overwritten.
    assign input_ready = ~cache_unprocessed | ~gate_active | ~pending;

    // Vivado maps this to the device's dedicated global clock gate. The
    // standalone ModelSim test uses tb/BUFGCE.v as a simulation primitive.
    BUFGCE #(.CE_TYPE("SYNC")) classifier_bufgce (
        .I  (clk),
        .CE (gate_request),
        .O  (classifier_clk)
    );

    // Parent-clock input holding register and output pulse. The toggle is
    // stable while the classifier clock is stopped, so no result is repeated.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            pending <= 1'b0;
            cache_unprocessed <= 1'b0;
            cache_must_process <= 1'b0;
            seen_result_toggle <= 1'b0;
            c0 <= 32'sd0; c1 <= 32'sd0; c2 <= 32'sd0;
            c3 <= 32'sd0; c4 <= 32'sd0; c5 <= 32'sd0;
            c6 <= 32'sd0;
            f0 <= 32'sd0; f1 <= 32'sd0; f2 <= 32'sd0;
            f3 <= 32'sd0; f4 <= 32'sd0; f5 <= 32'sd0;
            f6 <= 32'sd0;
            result_valid <= 1'b0;
            vf <= 1'b0;
            score_q29 <= 64'sd0;
            input_overflow <= 1'b0;
        end else begin
            result_valid <= 1'b0;
            if (result_toggle_core != seen_result_toggle) begin
                seen_result_toggle <= result_toggle_core;
                pending <= 1'b0;
                result_valid <= 1'b1;
                vf <= vf_core;
                score_q29 <= score_core;
            end

            if ((gate_active || cache_must_process) && cache_unprocessed && !pending) begin
                f0 <= c0; f1 <= c1; f2 <= c2; f3 <= c3;
                f4 <= c4; f5 <= c5; f6 <= c6;
                pending <= 1'b1;
                cache_unprocessed <= 1'b0;
                cache_must_process <= 1'b0;
            end

            if (features_valid) begin
                if (!input_ready)
                    input_overflow <= 1'b1;
                c0 <= mean_abs_amp_q16_16;
                c1 <= line_length_q16_16;
                c2 <= derivative_zero_crossings_q16_16;
                c3 <= threshold_crossings_q16_16;
                c4 <= local_amp_mean_q16_16;
                c5 <= local_amp_range_q16_16;
                c6 <= amp_transition_q16_16;
                cache_unprocessed <= 1'b1;
                if (gate_active)
                    cache_must_process <= 1'b1;
            end
        end
    end

    // A request is consumed once even though pending remains asserted until
    // the parent-clock side receives the result toggle.
    wire accept_core = pending & ~seen_pending;
    always @(posedge classifier_clk or negedge resetn) begin
        if (!resetn)
            seen_pending <= 1'b0;
        else if (!pending)
            seen_pending <= 1'b0;
        else if (accept_core)
            seen_pending <= 1'b1;
    end

    stage2_vt_vf_svm_q213 classifier (
        .clk                            (classifier_clk),
        .resetn                         (resetn),
        .features_valid                 (accept_core),
        .mean_abs_amp_q16_16            (f0),
        .line_length_q16_16             (f1),
        .derivative_zero_crossings_q16_16(f2),
        .threshold_crossings_q16_16     (f3),
        .local_amp_mean_q16_16          (f4),
        .local_amp_range_q16_16         (f5),
        .amp_transition_q16_16          (f6),
        .result_toggle                  (result_toggle_core),
        .vf                             (vf_core),
        .score_q29                      (score_core)
    );
endmodule
