`timescale 1ns/1ps
module ecg_direct_power_tb;
`ifdef ECG_DIRECT_UNGATED
    localparam integer SOURCE_HZ=100000;
    localparam MODE="ungated_100khz";
`else
    localparam integer SOURCE_HZ=500;
    localparam MODE="gated_500hz";
`endif
    localparam realtime HALF_NS=500000000.0/SOURCE_HZ;
    reg source_clk=0;
    always #(HALF_NS) source_clk=~source_clk;
    reg resetn=0, sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    wire processing_clk, class_valid, class_is_stage2, mac_enabled, fast_request;
    wire [31:0] class_id;
    wire [1:0] class_code;
    wire overflow1, overflow2, overflow_mac;
    integer warmup_samples=1200, measure_samples=7200;
    integer sent=0, accepted=0, phase=0, s1_results=0, measured_s1=0;
    longint unsigned clock_edges=0;
    integer q8, no_dump=0;
    reg capture_started=0, capture_active=0;
    time capture_start, capture_end;
    ecg_direct_power_top dut (
        .source_clk(source_clk), .resetn(resetn), .sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16), .processing_clk(processing_clk),
        .class_valid(class_valid), .class_is_stage2(class_is_stage2),
        .class_window_id(class_id), .class_code(class_code),
        .classifier_clock_enabled(mac_enabled), .processing_fast_request(fast_request),
        .stage1_window_overflow(overflow1), .stage2_window_overflow(overflow2),
        .classifier_overflow(overflow_mac)
    );
    // Identical deterministic normal waveform to the previous experiment.
    // Values are Q3.8 counts, not calibrated millivolts or clinical labels.
    function automatic integer normal_q8(input integer index);
        integer value;
        begin
            value=(index*17)%7-3;
            case(index%120)
                18,20: value=value+12;
                19: value=value+20;
                45: value=value-30;
                46: value=value+220;
                47: value=value-50;
                72,74: value=value+18;
                73: value=value+28;
            endcase
            normal_q8=value;
        end
    endfunction
    always @(posedge source_clk) if(resetn) begin
        if(sample_valid) accepted=accepted+1;
        if(capture_active) clock_edges=clock_edges+1;
        if(overflow1 || overflow2 || overflow_mac) $fatal(1,"Pipeline overflow");
        if(fast_request) $fatal(1,"Normal-only test requested Stage 2; 500 Hz is not an active-Stage-2 configuration");
        if(class_valid) begin
            if($isunknown({class_id,class_code,class_is_stage2}) || class_is_stage2 || class_code!=0)
                $fatal(1,"Unexpected/unknown classification in synthetic normal workload");
            s1_results=s1_results+1;
            if(capture_active) measured_s1=measured_s1+1;
            $display("RESULT time_ns=%0t stage2=%0d id=%0d code=%0d score_q40=%0d measured=%0d",
                $time,class_is_stage2,class_id,class_code,dut.pipeline.mac_score_q40,capture_active);
        end
    end
    initial begin
        if($value$plusargs("WARMUP_SAMPLES=%d",warmup_samples)) begin end
        if($value$plusargs("MEASURE_SAMPLES=%d",measure_samples)) begin end
        if($value$plusargs("NO_DUMP=%d",no_dump)) begin end
        if(warmup_samples<1200 || measure_samples<120 ||
            warmup_samples%120!=0 || measure_samples%120!=0)
            $fatal(1,"Use >=10 s warm-up and whole-second measurements >=1 s");
        $timeformat(-9,0,"",1);
        $display("CONFIG mode=%s source_hz=%0d sample_hz=120 warmup_samples=%0d measure_samples=%0d workload=normal direct_clock=1",
            MODE,SOURCE_HZ,warmup_samples,measure_samples);
        #10000000; resetn=1;
        // Begin just before a common falling edge at exactly 1 simulated second.
        // Both tests consequently use exactly the same capture boundaries.
        #989999999;
        while(sent<warmup_samples+measure_samples) begin
            @(negedge source_clk);
            sample_valid=0;
            if(sent==warmup_samples && !capture_started) begin
                capture_started=1; capture_active=1; capture_start=$time;
                // Fixed relative name in a unique run directory avoids
                // simulator-specific dynamic filename/string behavior.
                if(!no_dump) begin $dumpfile("activity.vcd"); $dumpvars(0,dut); end
                $display("CAPTURE_START time_ns=%0t accepted=%0d",$time,accepted);
            end
            phase=phase+120;
            if(phase>=SOURCE_HZ) begin
                phase=phase-SOURCE_HZ;
                q8=normal_q8(sent);
                sample_q16_16=q8<<<8;
                sample_valid=1;
                sent=sent+1;
                if(capture_active && (sent-warmup_samples)%1200==0)
                    $display("PROGRESS measured_samples=%0d/%0d",sent-warmup_samples,measure_samples);
            end
        end
        @(negedge source_clk);
        sample_valid=0; capture_end=$time; capture_active=0;
        if(!no_dump) begin $dumpoff; $dumpflush; end
        $display("CAPTURE_END time_ns=%0t duration_ns=%0t S1=%0d S2=0 processing_edges=%0d",
            capture_end,capture_end-capture_start,measured_s1,clock_edges);
        // Drain the final Stage 1 replay at either rate, outside the power window.
        repeat(SOURCE_HZ*2) @(negedge source_clk);
        if(accepted!=sent || s1_results==0 || measured_s1!=measure_samples/120)
            $fatal(1,"Sample/result accounting failure");
        $display("PASS: sent=%0d accepted=%0d S1=%0d S2=0",sent,accepted,s1_results);
        $finish;
    end
    initial begin
        #1;
        #(10000000000.0+(warmup_samples+measure_samples)*(1000000000.0/120.0));
        $fatal(1,"Direct-clock test timed out");
    end
endmodule
