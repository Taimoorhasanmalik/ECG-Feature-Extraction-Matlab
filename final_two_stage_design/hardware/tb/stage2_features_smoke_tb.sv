`timescale 1ns/1ps
module stage2_features_smoke_tb;
    reg clk = 0, resetn = 0, sample_valid = 0;
    reg signed [13:0] sample_q8 = 0;
    always #5 clk = ~clk;
    wire features_valid, overflow;
    wire [31:0] window_id;
    wire signed [11:0] f0, f4, f5, f6;
    wire signed [16:0] f1;
    wire signed [8:0] f2, f3;
    stage2_features_q dut (
        .clk(clk), .resetn(resetn), .sample_valid(sample_valid),
        .sample_q8(sample_q8), .features_valid(features_valid),
        .window_id(window_id), .mean_abs_q3_8(f0),
        .line_length_q8_8(f1), .derivative_zc(f2),
        .threshold_crossings(f3), .local_amp_mean_q3_8(f4),
        .local_amp_range_q3_8(f5), .amp_transition_q3_8(f6),
        .overflow(overflow)
    );
    integer cycle, n, results;
    initial begin
        n=0; results=0;
        repeat (4) @(negedge clk);
        resetn=1;
        for (cycle=0; cycle<2700; cycle=cycle+1) begin
            @(negedge clk);
            sample_valid = (cycle % 4 == 0) && n < 600;
            if (sample_valid) begin
                sample_q8 = (n % 2 == 0) ? 14'sd256 : -14'sd256;
                n=n+1;
            end
            if (features_valid) begin
                $display("id=%0d f=%0d,%0d,%0d,%0d,%0d,%0d,%0d", window_id,
                    f0,f1,f2,f3,f4,f5,f6);
                if (window_id != results || f0 != 256 || f1 != 65535 ||
                    f2 != 238 || f3 != 0 || f4 != 256 || f5 != 0 || f6 != 0)
                    $fatal(1,"feature mismatch");
                results=results+1;
            end
            if (overflow) $fatal(1,"window overflow");
        end
        if (results < 3) $fatal(1,"too few completed windows");
        $display("PASS: %0d Stage 2 windows",results);
        $finish;
    end
endmodule
