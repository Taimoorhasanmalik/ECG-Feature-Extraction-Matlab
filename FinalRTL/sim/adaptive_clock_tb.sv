`timescale 1ns/1ps
module adaptive_clock_tb;
    reg clk=0,resetn=0,request=0;
    always #5 clk=~clk;
    wire processing_clk,fast_mode,ready;
    ecg_adaptive_clock dut (.source_clk(clk),.resetn(resetn),
        .fast_request(request),.processing_clk(processing_clk),
        .fast_mode(fast_mode),.clock_ready(ready));
    time last_edge=0;
    integer edges=0,slow_halves=0,fast_halves=0;
    always @(processing_clk) if (resetn && $time>0) begin
        if (edges>0) begin
            if ($time-last_edge==1000000) slow_halves++;
            else if ($time-last_edge==5000) fast_halves++;
            else $fatal(1,"Runt/extended clock pulse: %0t ns",$time-last_edge);
        end
        last_edge=$time;edges++;
    end
    initial begin
        #31;resetn=1;
        wait(ready);
        #123457;request=1;
        wait(fast_mode);
        repeat(13) @(negedge processing_clk);
        #777;request=0;
        wait(!fast_mode);
        repeat(3) @(negedge processing_clk);
        if (slow_halves<4 || fast_halves<20) $fatal(1,"Both frequencies not exercised");
        $display("PASS: actual 100 MHz divider, %0d complete slow and %0d complete fast half-cycles, no runt pulses",
            slow_halves,fast_halves);
        $finish;
    end
    initial begin #20000000;$fatal(1,"Clock test timeout");end
endmodule
