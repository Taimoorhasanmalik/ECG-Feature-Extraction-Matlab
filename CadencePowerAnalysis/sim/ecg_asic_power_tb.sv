`timescale 1ns/1ps
module ecg_asic_power_tb;
`ifdef ECG_QUICK_SIM
    localparam integer SOURCE_HZ = 200000;
`else
    localparam integer SOURCE_HZ = 100000000;
`endif
    localparam realtime SOURCE_HALF_NS = 500000000.0 / SOURCE_HZ;
    reg source_clk = 0;
    always #(SOURCE_HALF_NS) source_clk = ~source_clk;
    reg resetn = 0, sample_valid = 0;
    reg signed [31:0] sample_q16_16 = 0;
    wire sample_ready, input_overflow, processing_clk, clock_ready, fast_mode;
    wire fast_request, class_valid, class_is_stage2, mac_enabled;
    wire overflow1, overflow2, overflow_mac;
    wire [31:0] class_id;
    wire [1:0] class_code;
    reg signed [11:0] demo_memory [0:1199];
    integer warmup_samples = 1200, measure_samples = 120;
    integer sent = 0, accepted = 0, phase = 0;
    integer stage1_results = 0, stage2_results = 0, fast_entries = 0;
    integer measure_s1 = 0, measure_s2 = 0;
    integer processing_edges = 0, fast_processing_edges = 0;
    integer q8;
    reg previous_fast = 0, capture_active = 0, capture_started = 0;
    time capture_start, capture_end;
    string workload = "normal", memory_file, vcd_file = "activity.vcd";
    integer no_dump = 0;

`ifdef ECG_GATE_NETLIST
    // The routed netlist already fixes SOURCE_HZ during synthesis.
    ecg_asic_power_top dut (
`else
    ecg_asic_power_top #(.SOURCE_HZ(SOURCE_HZ)) dut (
`endif
        .source_clk(source_clk), .resetn(resetn),
        .sample_valid(sample_valid), .sample_q16_16(sample_q16_16),
        .sample_ready(sample_ready), .input_overflow(input_overflow),
        .processing_clk(processing_clk), .clock_ready(clock_ready),
        .fast_mode(fast_mode), .processing_fast_request(fast_request),
        .class_valid(class_valid), .class_is_stage2(class_is_stage2),
        .classifier_clock_enabled(mac_enabled), .class_window_id(class_id),
        .class_code(class_code), .stage1_window_overflow(overflow1),
        .stage2_window_overflow(overflow2), .classifier_overflow(overflow_mac)
    );

    // Same deterministic synthetic low-rate beat used by the existing power
    // experiment. This is a workload, not a clinical normal/abnormal label.
    function automatic integer normal_q8(input integer index);
        integer value;
        begin
            value = (index * 17) % 7 - 3;
            case (index % 120)
                18,20: value = value + 12;
                19: value = value + 20;
                45: value = value - 30;
                46: value = value + 220;
                47: value = value - 50;
                72,74: value = value + 18;
                73: value = value + 28;
            endcase
            normal_q8 = value;
        end
    endfunction

    always @(posedge processing_clk) if (resetn && clock_ready) begin
        if (dut.core.delivered_valid) accepted = accepted + 1;
        if (input_overflow || overflow1 || overflow2 || overflow_mac)
            $fatal(1, "Input/window/classifier overflow");
        if (capture_active) begin
            processing_edges = processing_edges + 1;
            if (fast_mode) fast_processing_edges = fast_processing_edges + 1;
        end
        if (class_valid) begin
            if ($isunknown({class_is_stage2, class_code, class_id}))
                $fatal(1, "Unknown classification output");
            if (class_is_stage2) begin
                if (class_code != 1 && class_code != 2)
                    $fatal(1, "Invalid Stage 2 result code");
                stage2_results = stage2_results + 1;
                if (capture_active) measure_s2 = measure_s2 + 1;
            end else begin
                if (class_code != 0 && class_code != 3)
                    $fatal(1, "Invalid Stage 1 result code");
                stage1_results = stage1_results + 1;
                if (capture_active) measure_s1 = measure_s1 + 1;
            end
            $display("RESULT time_ns=%0t stage2=%0d id=%0d code=%0d measured=%0d",
                $time, class_is_stage2, class_id, class_code, capture_active);
        end
    end
    always @(negedge source_clk) if (resetn) begin
        if (fast_mode && !previous_fast) fast_entries = fast_entries + 1;
        previous_fast = fast_mode;
    end

    initial begin
        if ($value$plusargs("WARMUP_SAMPLES=%d", warmup_samples)) begin end
        if ($value$plusargs("MEASURE_SAMPLES=%d", measure_samples)) begin end
        if ($value$plusargs("WORKLOAD=%s", workload)) begin end
        if ($value$plusargs("VCD_FILE=%s", vcd_file)) begin end
        if ($value$plusargs("NO_DUMP=%d", no_dump)) begin end
        if (warmup_samples < 1 || measure_samples < 1)
            $fatal(1, "Sample counts must be positive");
        if (workload != "normal" && workload != "demo")
            $fatal(1, "WORKLOAD must be normal or demo");
        if (workload == "demo") begin
            if (!$value$plusargs("MEM_FILE=%s", memory_file))
                $fatal(1, "demo requires +MEM_FILE=...");
            $readmemh(memory_file, demo_memory);
            for (integer k = 0; k < 1200; k = k + 1)
                if ($isunknown(demo_memory[k])) $fatal(1, "Invalid demo memory");
        end
        $timeformat(-9, 0, "", 1);
        $display("CONFIG source_hz=%0d sample_hz=120 warmup_samples=%0d measure_samples=%0d workload=%s",
            SOURCE_HZ, warmup_samples, measure_samples, workload);
`ifdef ECG_QUICK_SIM
        $display("FUNCTIONAL_ONLY: reduced source clock; not power activity");
        if (!no_dump) $fatal(1, "Quick check requires +NO_DUMP=1");
`endif
        repeat (100) @(negedge source_clk);
        resetn = 1;
        // The acquisition start must not depend on the selected divider mode.
        // Ten milliseconds permits slow-mode reset/mailbox startup in all cases.
        repeat (SOURCE_HZ / 100) @(negedge source_clk);
        if (!clock_ready || !sample_ready) $fatal(1, "Clock/mailbox not ready after startup");
        while (sent < warmup_samples + measure_samples) begin
            @(negedge source_clk);
            sample_valid = 0;
            if (sent == warmup_samples && !capture_started) begin
                capture_started = 1;
                capture_active = 1;
                capture_start = $time;
                if (!no_dump) begin
                    $dumpfile(vcd_file);
                    $dumpvars(0, dut);
                end
                $display("CAPTURE_START time_ns=%0t accepted=%0d", $time, accepted);
            end
            phase = phase + 120;
            if (phase >= SOURCE_HZ) begin
                phase = phase - SOURCE_HZ;
                if (!sample_ready) $fatal(1, "Mailbox busy at sample %0d", sent);
                q8 = workload == "demo" ? $signed(demo_memory[sent % 1200]) : normal_q8(sent);
                sample_q16_16 = q8 <<< 8;
                sample_valid = 1;
                sent = sent + 1;
            end
        end
        @(negedge source_clk);
        sample_valid = 0;
        capture_end = $time;
        capture_active = 0;
        if (!no_dump) begin $dumpoff; $dumpflush; end
        $display("CAPTURE_END time_ns=%0t duration_ns=%0t S1=%0d S2=%0d processing_edges=%0d fast_edges=%0d",
            capture_end, capture_end-capture_start, measure_s1, measure_s2,
            processing_edges, fast_processing_edges);
        wait(accepted == sent);
        repeat (10) @(posedge processing_clk);
        @(negedge processing_clk);
        if (stage1_results == 0) $fatal(1, "No Stage 1 sequence result; increase warmup");
        if (workload == "demo" && stage2_results == 0)
            $fatal(1, "Demo did not exercise Stage 2; increase warmup");
        if (workload == "normal" && stage2_results != 0)
            $fatal(1, "Synthetic normal workload activated Stage 2; inspect results");
        $display("PASS: sent=%0d accepted=%0d S1=%0d S2=%0d fast_entries=%0d",
            sent, accepted, stage1_results, stage2_results, fast_entries);
        $finish;
    end
    initial begin
        #(64'd120000000000);
        $fatal(1, "120-second simulated timeout");
    end
endmodule
