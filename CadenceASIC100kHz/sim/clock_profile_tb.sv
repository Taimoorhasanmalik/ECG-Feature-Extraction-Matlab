`timescale 1ns/1ps
module clock_profile_tb;
    reg source_clk=0, resetn=0, request_fast=0;
    wire processing_clk, fast_mode, ready;
    always #5000 source_clk=~source_clk;
    time last_rise;
    integer pulses=0, switches=0;
    ecg_adaptive_clock dut (
        .source_clk(source_clk),.resetn(resetn),.fast_request(request_fast),
        .processing_clk(processing_clk),.fast_mode(fast_mode),.clock_ready(ready)
    );
    always @(posedge processing_clk) if (resetn) begin
        if (source_clk!==1) $fatal(1,"Output rise not on source high");
        last_rise=$time;
        pulses=pulses+1;
    end
    always @(negedge processing_clk) if (resetn && pulses>0)
        if ($time-last_rise!=5000) $fatal(1,"Truncated or stretched output high pulse");

    task automatic expect_period(input time period_ns, input integer edges);
        time previous;
        @(posedge processing_clk); previous=$time;
        repeat(edges) begin
            @(posedge processing_clk);
            if ($time-previous!=period_ns)
                $fatal(1,"Clock period mismatch: got %0t expected %0t",$time-previous,period_ns);
            previous=$time;
        end
    endtask
    initial begin
        repeat(4) @(negedge source_clk);
        #123 resetn=1;
        expect_period(2000000,4);
        if (!ready || fast_mode) $fatal(1,"Initial slow mode not ready");
        for (integer k=0;k<30;k=k+1) begin
            // Requests deliberately change away from source edges.
            #(137+k*73) request_fast=1;
            wait(fast_mode); switches=switches+1;
            expect_period(10000,9);
            @(negedge source_clk); #1;
            if (dut.remaining!=199) $fatal(1,"Counter not held in fast mode");
            #(411+k*11) request_fast=0;
            wait(!fast_mode); switches=switches+1;
            expect_period(2000000,2);
        end
        // Asynchronous reset during a stopped interval must recover.
        @(negedge processing_clk); #171 resetn=0;
        repeat(4) @(negedge source_clk); #19 resetn=1;
        expect_period(2000000,3);
        $display("PASS: 100kHz direct fast, 500Hz /200 slow; switches=%0d pulses=%0d; all high pulses=5us",switches,pulses);
        $finish;
    end
    initial begin #500000000; $fatal(1,"Clock test timeout"); end
endmodule
