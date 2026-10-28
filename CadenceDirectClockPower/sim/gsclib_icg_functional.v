`timescale 1ns/1ps
// Functional simulation only. Genus loads the Liberty cell, never this model.
module TLATNCAX12(input wire CK, E, output wire ECK);
    reg enable_latched;
    always @(CK or E) if (!CK) enable_latched <= E;
    assign ECK = CK & enable_latched;
endmodule
