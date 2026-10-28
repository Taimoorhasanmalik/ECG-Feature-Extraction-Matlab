`timescale 1ns/1ps
module stage2_classifier_reference_tb;
    reg clk=0, resetn=0, hold_awake=0, request_valid=0;
    reg [31:0] request_window_id=0;
    reg signed [31:0] f0=0,f1=0,f2=0,f3=0,f4=0,f5=0,f6=0;
    always #5 clk=~clk;
    wire ready,clock_enabled,result_valid,vf,overflow;
    wire [31:0] result_window_id;
    wire signed [63:0] score;
    reg [82:0] feature_mem [0:3];
    reg [63:0] score_mem [0:3];
    string vector_dir;
    integer i, received, gated_edges, stopped_edges;
    always @(posedge dut.gated_clk) gated_edges=gated_edges+1;
    stage2_classifier_gated_q dut (
        .clk(clk),.resetn(resetn),.hold_awake(hold_awake),
        .request_valid(request_valid),.request_window_id(request_window_id),
        .f0_q16_16(f0),.f1_q16_16(f1),.f2_q16_16(f2),
        .f3_q16_16(f3),.f4_q16_16(f4),.f5_q16_16(f5),
        .f6_q16_16(f6),.input_ready(ready),
        .classifier_clock_enabled(clock_enabled),
        .result_valid(result_valid),.result_window_id(result_window_id),
        .vf(vf),.score_q29(score),.overflow(overflow)
    );
    initial begin
        if (!$value$plusargs("VECTOR_DIR=%s",vector_dir)) $fatal(1,"VECTOR_DIR missing");
        $readmemh({vector_dir,"/features.mem"},feature_mem);
        $readmemh({vector_dir,"/scores.mem"},score_mem);
        received=0;gated_edges=0;
        repeat (4) @(negedge clk);
        resetn=1;
        if (clock_enabled) $fatal(1,"clock active while asleep");
        for (i=0;i<4;i=i+1) begin
            @(negedge clk);
            hold_awake=1;
            if (!ready) $fatal(1,"classifier not ready");
            request_window_id=i;
            f0=$signed(feature_mem[i][11:0]) <<< 8;
            f1=$signed(feature_mem[i][28:12]) <<< 8;
            f2=$signed(feature_mem[i][37:29]) <<< 16;
            f3=$signed(feature_mem[i][46:38]) <<< 16;
            f4=$signed(feature_mem[i][58:47]) <<< 8;
            f5=$signed(feature_mem[i][70:59]) <<< 8;
            f6=$signed(feature_mem[i][82:71]) <<< 8;
            request_valid=1;
            @(negedge clk);
            request_valid=0;
            wait(result_valid);
            if (result_window_id!=i || score!==score_mem[i] || vf!==($signed(score_mem[i])>0))
                $fatal(1,"result mismatch window=%0d score=%h expected=%h",i,score,score_mem[i]);
            received=received+1;
            repeat (3) @(negedge clk);
        end
        hold_awake=0;
        repeat (5) @(negedge clk);
        stopped_edges=gated_edges;
        repeat (5) @(negedge clk);
        if (gated_edges!=stopped_edges || clock_enabled || overflow || received!=4)
            $fatal(1,"gate/overflow failure");
        $display("PASS: 4 exact classifier scores; clock closed when idle");
        $finish;
    end
endmodule
