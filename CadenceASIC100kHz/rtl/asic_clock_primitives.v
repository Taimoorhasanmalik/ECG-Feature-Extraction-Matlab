// ASIC mapping, not an FPGA implementation file. Functional simulation uses
// a separate ICG model; synthesis/physical implementation use the Liberty cell.
module BUFGCE #(
    parameter CE_TYPE="SYNC",
    parameter SIM_DEVICE="7SERIES"
) (input wire I, CE, output wire O);
    TLATNCAX12 clock_gate (.CK(I),.E(CE),.ECK(O));
endmodule
