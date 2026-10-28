`timescale 1ns/1ps
// Identical 20 s, 120 Hz sample stream for the gated and always-on 240-entry
// implementations. The deterministic waveform is synthetic, not clinical ECG.
module mostly_normal_power_tb;
    localparam integer SAMPLE_COUNT=2400;
    localparam integer CLOCK_HZ=100000;
    reg clk=0,resetn=0,sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    // 10 us full period: the implemented core clock is 100 kHz.
    always #5000 clk=~clk;

    wire g_valid,g_stage2,g_mac_ce,g_overflow1,g_overflow2,g_overflow_mac;
    wire a_valid,a_stage2,a_mac_ce,a_overflow1,a_overflow2,a_overflow_mac;
    wire [31:0] g_id,a_id;
    wire [1:0] g_code,a_code;
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(1),.DEEP_HISTORY(0),.CLOCK_GATING(1)) gated (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(g_valid),
        .class_window_id(g_id),.class_code(g_code),.class_is_stage2(g_stage2),
        .classifier_clock_enabled(g_mac_ce),
        .stage1_window_overflow(g_overflow1),
        .stage2_window_overflow(g_overflow2),
        .classifier_overflow(g_overflow_mac));
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(1),.DEEP_HISTORY(0),.CLOCK_GATING(0)) always_on (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(a_valid),
        .class_window_id(a_id),.class_code(a_code),.class_is_stage2(a_stage2),
        .classifier_clock_enabled(a_mac_ce),
        .stage1_window_overflow(a_overflow1),
        .stage2_window_overflow(a_overflow2),
        .classifier_overflow(a_overflow_mac));

    integer cycles=0,phase=0,samples=0,stage1_results=0,stage2_results=0;
    integer stage1_abnormal_results=0;
    integer stage2_ce_cycles=0,mac_ce_cycles=0,stage2_write_samples=0;
    integer beat_phase,noise,q8;
    always @(negedge clk) begin
        if (resetn) begin
            cycles=cycles+1;
            sample_valid=0;
            if (samples<SAMPLE_COUNT) begin
                phase=phase+120;
                if (phase>=CLOCK_HZ) begin
                    phase=phase-CLOCK_HZ;
                    sample_valid=1;
                    beat_phase=samples%120;
                    noise=(samples*17)%7-3;
                    q8=noise;
                    // 15 s of low-rate, P/QRS/T-shaped beats, followed by
                    // 5 s of high-frequency challenge to exercise wake-up.
                    if (samples<1800) begin
                        case(beat_phase)
                            18,20: q8=q8+12;
                            19: q8=q8+20;
                            45: q8=q8-30;
                            46: q8=q8+220;
                            47: q8=q8-50;
                            72,74: q8=q8+18;
                            73: q8=q8+28;
                        endcase
                    end else q8=q8+(samples%2 ? 180 : -180);
                    sample_q16_16=q8<<<8;
                    samples=samples+1;
                end
            end
            if (gated.s2_stats_clock_enabled) stage2_ce_cycles=stage2_ce_cycles+1;
            if (g_mac_ce) mac_ce_cycles=mac_ce_cycles+1;
            if (gated.seq_valid && |gated.s2_enable_mask)
                stage2_write_samples=stage2_write_samples+1;
            if (g_valid !== a_valid ||
                (g_valid && (g_stage2!==a_stage2 || g_id!==a_id ||
                             g_code!==a_code)))
                $fatal(1,"power variants differ at cycle %0d",cycles);
            if (g_overflow1||g_overflow2||g_overflow_mac||
                a_overflow1||a_overflow2||a_overflow_mac)
                $fatal(1,"power variant overflow at cycle %0d",cycles);
            if (g_valid) begin
                if (g_stage2) stage2_results=stage2_results+1;
                else begin
                    stage1_results=stage1_results+1;
                    if (g_code==2'd3)
                        stage1_abnormal_results=stage1_abnormal_results+1;
                end
            end
            if (samples==SAMPLE_COUNT && cycles>2100000) begin
                $display("PASS: samples=%0d stage1=%0d abnormal=%0d stage2=%0d stats_ce=%0d/%0d mac_ce=%0d/%0d s2_writes=%0d",
                    samples,stage1_results,stage1_abnormal_results,stage2_results,
                    stage2_ce_cycles,cycles,mac_ce_cycles,cycles,
                    stage2_write_samples);
                $finish;
            end
        end
    end
    initial begin
        repeat(4) @(negedge clk);
        resetn=1;
    end
endmodule
