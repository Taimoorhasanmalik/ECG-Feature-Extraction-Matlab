// ASIC analysis adapters only. Do not add these to a Vivado source set.
// The final RTL is unchanged. CTS must implement physical clock distribution.
module BUFG(input wire I, output wire O);
    assign O = I;
endmodule

module BUFGCE #(
    parameter CE_TYPE = "SYNC",
    parameter SIM_DEVICE = "7SERIES"
) (
    input wire I, CE,
    output wire O
);
    // Interface verified from the user's gsclib045 Liberty metadata.
    // X12 is a known available cell, not a claim of optimal gate sizing.
    TLATNCAX12 clock_gate (.CK(I), .E(CE), .ECK(O));
endmodule
