`timescale 1ns/10ps

module bnn_threshold_assembler (
    input  logic       clk,
    input  logic       rst,
    // Byte input
    input  logic       byte_valid,
    output logic       byte_ready,
    input  logic [7:0] byte_data,
    // 32-bit threshold output
    output logic       thresh_valid,
    input  logic       thresh_ready,
    output logic [31:0] thresh_data
);

    bnn_threshold_assembler_dp u_dp (
        .clk          (clk),
        .rst          (rst),
        .byte_valid   (byte_valid),
        .byte_ready   (byte_ready),
        .byte_data    (byte_data),
        .thresh_valid (thresh_valid),
        .thresh_ready (thresh_ready),
        .thresh_data  (thresh_data)
    );

endmodule
