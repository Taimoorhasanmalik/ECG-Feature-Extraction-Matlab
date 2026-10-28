`timescale 1ns/1ps
module two_stage_reference_tb;
    localparam N=1200;
    localparam WINDOWS=9;
    reg clk=0,resetn=0,sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    always #5 clk=~clk;
    wire class_valid, classifier_clock_enabled;
    wire [31:0] class_window_id;
    wire [1:0] class_code;
    wire stage1_window_overflow,stage2_window_overflow,classifier_overflow;
    two_stage_ecg_top dut (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.class_valid(class_valid),
        .class_window_id(class_window_id),.class_code(class_code),
        .classifier_clock_enabled(classifier_clock_enabled),
        .stage1_window_overflow(stage1_window_overflow),
        .stage2_window_overflow(stage2_window_overflow),
        .classifier_overflow(classifier_overflow)
    );
    reg [31:0] input_mem [0:N-1];
    reg [11:0] hp_mem [0:N-1];
    reg [63:0] s1_score_mem [0:WINDOWS-1];
    reg [1:0] class_mem [0:WINDOWS-3];
    string vector_dir;
    integer i,phase,input_count,hp_count,score_count,class_count;
    initial begin
        if (!$value$plusargs("VECTOR_DIR=%s",vector_dir)) $fatal(1,"VECTOR_DIR missing");
        $readmemh({vector_dir,"/input.mem"},input_mem);
        $readmemh({vector_dir,"/stage1_filter.mem"},hp_mem);
        $readmemh({vector_dir,"/stage1_scores.mem"},s1_score_mem);
        $readmemh({vector_dir,"/combined.mem"},class_mem);
        phase=0;input_count=0;hp_count=0;score_count=0;class_count=0;
        repeat (4) @(negedge clk);
        resetn=1;
        for(i=0;i<6100;i=i+1) begin
            @(negedge clk);
            phase=phase+120;
            sample_valid=0;
            if(phase>=500 && input_count<N) begin
                phase=phase-500;
                sample_valid=1;
                sample_q16_16=input_mem[input_count];
                input_count=input_count+1;
            end
            if(dut.stage1.hp_valid) begin
                if(hp_count>=N || dut.stage1.hp_sample!==hp_mem[hp_count])
                    $fatal(1,"Stage 1 filter mismatch sample %0d got %0d exp %0d",
                        hp_count,dut.stage1.hp_sample,$signed(hp_mem[hp_count]));
                hp_count=hp_count+1;
            end
            if(|dut.stage1.feature_valid) begin
                if(score_count>=WINDOWS || dut.stage1.score!==s1_score_mem[score_count])
                    $fatal(1,"Stage 1 score mismatch window %0d got %h exp %h",
                        score_count,dut.stage1.score,s1_score_mem[score_count]);
                score_count=score_count+1;
            end
            if(class_valid) begin
                if(class_window_id!=class_count+2 || class_count>=WINDOWS-2 ||
                    class_code!==class_mem[class_count])
                    $fatal(1,"combined mismatch id=%0d class=%0d expected=%0d",
                        class_window_id,class_code,class_mem[class_count]);
                if(class_window_id==5 && !classifier_clock_enabled)
                    $fatal(1,"clock closed after only one normal result");
                if(class_window_id==6 && classifier_clock_enabled)
                    $fatal(1,"clock stayed open after two normal results");
                class_count=class_count+1;
            end
            if(stage1_window_overflow || stage2_window_overflow || classifier_overflow)
                $fatal(1,"pipeline overflow");
        end
        if(hp_count!=N || score_count!=WINDOWS || class_count!=WINDOWS-2)
            $fatal(1,"counts hp=%0d score=%0d class=%0d",hp_count,score_count,class_count);
        if(classifier_clock_enabled) $fatal(1,"classifier clock did not close");
        $display("PASS: %0d Stage 1 samples, %0d scores, %0d combined classes; gate closed",N,WINDOWS,WINDOWS-2);
        $finish;
    end
endmodule
