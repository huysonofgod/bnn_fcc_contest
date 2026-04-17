// =============================================================================
// bnn_fcc_reset_if.sv — Minimal reset holder for UVM top coordination
// =============================================================================
`timescale 1ns/1ps

interface bnn_fcc_reset_if(input logic clk);
    logic rst;
endinterface
