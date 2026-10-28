// One registered divider and one BUFG, not a mux between clock sources.
// A new terminal count is adopted only after a complete old half-cycle.
module ecg_adaptive_clock #(
    parameter integer SOURCE_HZ=100000000,
    parameter integer SLOW_HZ=500,
    parameter integer FAST_HZ=100000
) (
    input wire source_clk, resetn, fast_request,
    output wire processing_clk,
    output reg fast_mode,
    output wire clock_ready
);
    localparam integer SLOW_HALF=SOURCE_HZ/(2*SLOW_HZ);
    localparam integer FAST_HALF=SOURCE_HZ/(2*FAST_HZ);
    localparam integer COUNT_BITS=SLOW_HALF>1 ? $clog2(SLOW_HALF) : 1;
    reg [COUNT_BITS-1:0] count;
    reg divided_clock;
    (* ASYNC_REG="TRUE" *) reg [1:0] request_sync;
    always @(posedge source_clk or negedge resetn) begin
        if (!resetn) begin
            request_sync<=0;count<=0;divided_clock<=0;fast_mode<=0;
        end else begin
            request_sync<={request_sync[0],fast_request};
            if (count==(fast_mode ? FAST_HALF-1 : SLOW_HALF-1)) begin
                count<=0;
                divided_clock<=~divided_clock;
                fast_mode<=request_sync[1];
            end else count<=count+1'b1;
        end
    end
    BUFG clock_buffer (.I(divided_clock),.O(processing_clk));
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync;
    always @(posedge processing_clk or negedge resetn)
        if (!resetn) ready_sync<=0;
        else ready_sync<={ready_sync[0],1'b1};
    assign clock_ready=ready_sync[1];
endmodule
