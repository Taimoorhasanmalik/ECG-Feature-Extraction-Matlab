`timescale 1ns/1ps
// Portable integration smoke test, not a bit-exact reference/accuracy test.
// A reduced source rate speeds simulation; processing/input rates are real.
module two_stage_adaptive_smoke_tb;
    localparam integer SOURCE_HZ = 200000;
    localparam integer SAMPLE_COUNT = 1200;
    reg source_clk = 0;
    always #2500 source_clk = ~source_clk;
    reg resetn = 0, sample_valid = 0;
    reg signed [31:0] sample_q16_16 = 0;
    reg signed [11:0] sample_memory [0:SAMPLE_COUNT-1];
    wire sample_ready, input_overflow, processing_clk, clock_ready;
    wire fast_mode, fast_request, class_valid, class_is_stage2, mac_enabled;
    wire overflow1, overflow2, overflow_mac;
    wire [31:0] class_id;
    wire [1:0] class_code;
    integer sent = 0, accepted = 0, stage1_results = 0, stage2_results = 0;
    integer phase = 0, fast_entries = 0;
    reg previous_fast = 0;
    string memory_file;

    two_stage_adaptive_clock_top #(.SOURCE_HZ(SOURCE_HZ)) dut (
        .source_clk(source_clk), .resetn(resetn), .sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16), .sample_ready(sample_ready),
        .input_overflow(input_overflow), .processing_clk(processing_clk),
        .clock_ready(clock_ready), .fast_mode(fast_mode),
        .processing_fast_request(fast_request), .class_valid(class_valid),
        .class_is_stage2(class_is_stage2), .classifier_clock_enabled(mac_enabled),
        .class_window_id(class_id), .class_code(class_code),
        .stage1_window_overflow(overflow1), .stage2_window_overflow(overflow2),
        .classifier_overflow(overflow_mac)
    );

    always @(posedge processing_clk) if (resetn && clock_ready) begin
        if (dut.delivered_valid) accepted = accepted + 1;
        if (overflow1 || overflow2 || overflow_mac || input_overflow)
            $fatal(1, "Overflow in portable smoke test");
        if (class_valid) begin
            if ($isunknown({class_is_stage2, class_code, class_id}))
                $fatal(1, "Unknown result fields");
            if (class_is_stage2) begin
                if (class_code != 1 && class_code != 2) $fatal(1, "Invalid Stage 2 code");
                stage2_results = stage2_results + 1;
            end else begin
                if (class_code != 0 && class_code != 3) $fatal(1, "Invalid Stage 1 code");
                stage1_results = stage1_results + 1;
            end
        end
    end
    always @(negedge source_clk) if (resetn) begin
        if (fast_mode && !previous_fast) fast_entries = fast_entries + 1;
        previous_fast = fast_mode;
    end

    initial begin
        if (!$value$plusargs("MEM_FILE=%s", memory_file))
            memory_file = "mem/synthetic_two_stage_demo_q3_8.mem";
        $readmemh(memory_file, sample_memory);
        for (integer k = 0; k < SAMPLE_COUNT; k = k + 1)
            if ($isunknown(sample_memory[k])) $fatal(1, "Missing/invalid input memory at %0d", k);
        #35001; resetn = 1;
        wait(clock_ready && sample_ready);
        while (sent < SAMPLE_COUNT) begin
            @(negedge source_clk);
            sample_valid = 0;
            phase = phase + 120;
            if (phase >= SOURCE_HZ) begin
                phase = phase - SOURCE_HZ;
                if (!sample_ready) $fatal(1, "Input mailbox busy at sample %0d", sent);
                sample_q16_16 = $signed(sample_memory[sent]) <<< 8;
                sample_valid = 1;
                sent = sent + 1;
            end
        end
        @(negedge source_clk); sample_valid = 0;
        wait(accepted == SAMPLE_COUNT);
        repeat (100) @(posedge processing_clk);
        @(negedge processing_clk);
        if (stage1_results == 0 || stage2_results == 0 || fast_entries == 0)
            $fatal(1, "Both stages and fast entry must be exercised");
        $display("PASS: portable adaptive smoke; accepted=%0d S1_results=%0d S2_results=%0d fast_entries=%0d",
                 accepted, stage1_results, stage2_results, fast_entries);
        $finish;
    end
    initial begin #(64'd15000000000); $fatal(1, "Portable smoke test timeout"); end
endmodule
