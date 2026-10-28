// 100 MHz Basys 3 source divided to the selected processing/replay clock.
module ecg_clock_1khz #(
    parameter integer OUTPUT_HZ=1000
) (
    input wire clk_100mhz,external_resetn,
    output wire clk_1khz,clock_ready
);
    localparam integer HALF_DIV=100000000/(2*OUTPUT_HZ);
    localparam integer COUNT_BITS=$clog2(HALF_DIV);
    reg [COUNT_BITS-1:0] count;
    reg divided_clock;
    always @(posedge clk_100mhz or negedge external_resetn) begin
        if (!external_resetn) begin
            count<=0;divided_clock<=0;
        end else if (count==HALF_DIV-1) begin
            count<=0;divided_clock<=~divided_clock;
        end else count<=count+1'b1;
    end
    BUFG clk_1khz_buf (.I(divided_clock),.O(clk_1khz));
    (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync;
    always @(posedge clk_1khz or negedge external_resetn)
        if (!external_resetn) reset_sync<=0;
        else reset_sync<={reset_sync[0],1'b1};
    assign clock_ready=reset_sync[1];
endmodule
