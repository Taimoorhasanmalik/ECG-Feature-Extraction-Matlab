`timescale 1ns/1ps
// Functional model only: no delay, leakage, or internal-power characterization.
// Genus must use the Liberty cell, never this model. Gate-level simulation
// must instead use the matching vendor standard-cell simulation library.
module TLATNCAX12(input wire CK, E, output wire ECK);
    reg enable_latched;
    always @(CK or E)
        if (!CK) enable_latched <= E;
    assign ECK = CK & enable_latched;
endmodule
