`timescale 1ns/1ps

module BUFG(input wire I, output wire O);
    assign O=I;
endmodule

// Standalone ModelSim model of the Xilinx BUFGCE for this testbench only.
// Do not add this file to a Vivado synthesis source set: the FPGA primitive
// comes from the Xilinx device library.
module BUFGCE #(
    parameter CE_TYPE = "SYNC",
    parameter SIM_DEVICE = "7SERIES"
) (
    input  wire I,
    input  wire CE,
    output wire O
);
    reg ce_low_phase = 1'b0;
    always @(negedge I)
        ce_low_phase <= CE;
    assign O = I & ce_low_phase;
endmodule
