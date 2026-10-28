`timescale 1ns/1ps
module clock_gate_equivalence_tb #(
    parameter integer N=1200,
    parameter integer CLOCK_HZ=100000
);
    reg clk=0,resetn=0,sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    always #5 clk=~clk;
    wire g_valid,g_stage2,g_ce,g_ov1,g_ov2,g_ovc;
    wire a_valid,a_stage2,a_ce,a_ov1,a_ov2,a_ovc;
    wire [31:0] g_id,a_id;
    wire [1:0] g_code,a_code;
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(1),.DEEP_HISTORY(0),.CLOCK_GATING(1)) gated (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(g_valid),
        .class_window_id(g_id),.class_code(g_code),.class_is_stage2(g_stage2),
        .classifier_clock_enabled(g_ce),.stage1_window_overflow(g_ov1),
        .stage2_window_overflow(g_ov2),.classifier_overflow(g_ovc));
    two_stage_shared_replay_top #(
        .SHARED_HP1_MODEL(1),.DEEP_HISTORY(0),.CLOCK_GATING(0)) always_on (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(a_valid),
        .class_window_id(a_id),.class_code(a_code),.class_is_stage2(a_stage2),
        .classifier_clock_enabled(a_ce),.stage1_window_overflow(a_ov1),
        .stage2_window_overflow(a_ov2),.classifier_overflow(a_ovc));
    reg [31:0] input_mem [0:N-1];
    string vector_dir;
    integer cycle,phase,index,stage1_count,stage2_count;
    initial begin
        if (!$value$plusargs("VECTOR_DIR=%s",vector_dir))
            $fatal(1,"VECTOR_DIR missing");
        $readmemh({vector_dir,"/input.mem"},input_mem);
        phase=0;index=0;stage1_count=0;stage2_count=0;
        repeat(4) @(negedge clk);
        resetn=1;
        for(cycle=0;cycle<N*(CLOCK_HZ/120+2)+CLOCK_HZ;cycle=cycle+1) begin
            @(negedge clk);
            sample_valid=0;
            if(index<N) begin
                phase=phase+120;
                if(phase>=CLOCK_HZ) begin
                    phase=phase-CLOCK_HZ;
                    sample_valid=1;
                    sample_q16_16=input_mem[index];
                    index=index+1;
                end
            end
            if(g_valid!==a_valid ||
               (g_valid && (g_stage2!==a_stage2 || g_id!==a_id ||
                            g_code!==a_code)))
                $fatal(1,"gated and always-on outputs differ at cycle %0d",cycle);
            if(g_ov1||g_ov2||g_ovc||a_ov1||a_ov2||a_ovc)
                $fatal(1,"gated or always-on overflow at cycle %0d",cycle);
            if(g_valid) begin
                if(g_stage2) stage2_count=stage2_count+1;
                else stage1_count=stage1_count+1;
            end
        end
        if(index!=N || stage2_count<1)
            $fatal(1,"active Stage 2 case not covered: samples=%0d s2=%0d",
                index,stage2_count);
        $display("PASS: clock-gate equivalence, %0d Stage 1 and %0d Stage 2 results",
            stage1_count,stage2_count);
        $finish;
    end
endmodule
