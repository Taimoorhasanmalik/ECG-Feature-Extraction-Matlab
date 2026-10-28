`timescale 1ns/1ps
// Only the gated case instantiates native ICG cells. The ungated case removes
// them rather than retaining cells with enables tied high.
module BUFG(input wire I, output wire O);
    assign O = I;
endmodule
module BUFGCE #(parameter CE_TYPE="SYNC", SIM_DEVICE="7SERIES") (
    input wire I, CE, output wire O
);
`ifdef ECG_DIRECT_UNGATED
    assign O = I;
`else
    TLATNCAX12 clock_gate (.CK(I), .E(CE), .ECK(O));
`endif
endmodule
