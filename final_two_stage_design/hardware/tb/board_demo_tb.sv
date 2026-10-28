`timescale 1ns/1ps
module board_demo_tb;
    reg clk=0,resetn=0;
    always #5 clk=~clk;
    wire signed [11:0] sample_q8;
    wire sample_valid,done;
    ecg_bram_demo_source #(
        .SAMPLE_WIDTH(12),.SAMPLE_COUNT(1200),
        .CLOCK_HZ(1000),.SAMPLE_RATE_HZ(120),
        .MEMORY_FILE("final_two_stage_design/hardware/mem_vectors/synthetic_two_stage_demo_q3_8.mem")
    ) demo (
        .clk(clk),.resetn(resetn),.enable(1'b1),
        .sample_out(sample_q8),.sample_valid(sample_valid),
        .playback_done(done)
    );
    wire class_valid,class_is_stage2,clock_enabled,overflow1,overflow2,overflow_classifier;
    wire [31:0] class_window_id;
    wire [1:0] class_code;
    wire signed [31:0] sample_q16_16 = $signed(sample_q8) <<< 8;
    two_stage_shared_replay_top dut (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),
        .class_valid(class_valid),.class_window_id(class_window_id),
        .class_code(class_code),.classifier_clock_enabled(clock_enabled),
        .class_is_stage2(class_is_stage2),
        .stage1_window_overflow(overflow1),
        .stage2_window_overflow(overflow2),
        .classifier_overflow(overflow_classifier)
    );
    integer cycles,results,stage2_results,last_stage1_id;
    initial begin
        results=0;stage2_results=0;last_stage1_id=-1;
        repeat(4) @(negedge clk);
        resetn=1;
        for(cycles=0;cycles<11000;cycles=cycles+1) begin
            @(negedge clk);
            if(class_valid) begin
                if(class_is_stage2) begin
                    if(class_window_id>=1200 || (class_code!=1 && class_code!=2))
                        $fatal(1,"board demo Stage 2 result mismatch");
                    stage2_results=stage2_results+1;
                end else begin
                    if((last_stage1_id>=0 && class_window_id<=last_stage1_id) ||
                        (class_code!=2'd3 && class_code!=2'd0))
                        $fatal(1,"board demo Stage 1 mismatch id=%0d class=%0d",
                            class_window_id,class_code);
                    results=results+1;
                    last_stage1_id=class_window_id;
                end
            end
            if(overflow1||overflow2||overflow_classifier) $fatal(1,"overflow");
        end
        if(!done||results<2||stage2_results<1||clock_enabled)
            $fatal(1,"board demo did not finish/close gate");
        $display("PASS: synthetic BRAM demo, %0d Stage 1 and %0d Stage 2 results",results,stage2_results);
        $finish;
    end
endmodule
