// ASIC clock profile: direct 100 kHz source in fast mode, /200 edge rate
// in slow mode. A single latch-based ICG passes complete source pulses.
// Slow duty cycle is 0.25% (5 us high, 1995 us low), not 50%.
module ecg_adaptive_clock #(
    parameter integer SOURCE_HZ=100000,
    parameter integer SLOW_HZ=500,
    parameter integer FAST_HZ=100000
) (
    input wire source_clk, resetn, fast_request,
    output wire processing_clk,
    output reg fast_mode,
    output wire clock_ready
);
    localparam integer DIVISOR=SOURCE_HZ/SLOW_HZ;
    localparam integer COUNT_BITS=DIVISOR>1 ? $clog2(DIVISOR) : 1;
    reg [COUNT_BITS-1:0] remaining;
    reg pass_pulse;
    (* ASYNC_REG="TRUE" *) reg [1:0] request_sync;
    always @(posedge source_clk or negedge resetn)
        if (!resetn) request_sync<=0;
        else request_sync<={request_sync[0],fast_request};

    // Enable changes only in the source clock's low phase. The ICG latch
    // additionally holds its enable throughout every source high pulse.
    // In fast mode the counter is held: no clock mux or fast divider.
    always @(negedge source_clk or negedge resetn) begin
        if (!resetn) begin
            remaining<=0;pass_pulse<=0;fast_mode<=0;
        end else begin
            fast_mode<=request_sync[1];
            if (request_sync[1]) begin
                remaining<=DIVISOR-1;
                pass_pulse<=1;
            end else if (remaining==0) begin
                remaining<=DIVISOR-1;
                pass_pulse<=1;
            end else begin
                remaining<=remaining-1'b1;
                pass_pulse<=0;
            end
        end
    end
    BUFGCE clock_buffer (.I(source_clk),.CE(pass_pulse),.O(processing_clk));
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync;
    always @(posedge processing_clk or negedge resetn)
        if (!resetn) ready_sync<=0;
        else ready_sync<={ready_sync[0],1'b1};
    assign clock_ready=ready_sync[1];

`ifndef SYNTHESIS
    initial begin
        if (SOURCE_HZ!=FAST_HZ || SLOW_HZ<1 || SOURCE_HZ%SLOW_HZ!=0)
            $fatal(1,"ASIC profile requires FAST_HZ=SOURCE_HZ and integer slow divisor");
    end
`endif
endmodule
