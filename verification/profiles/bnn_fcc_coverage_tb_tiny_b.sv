// TINY_B profile wrapper — power-of-two
// TOPOLOGY = {16, 8, 8, 4}, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 8, 4}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_tiny_b;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{16, 8, 8, 4}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 8, 4}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("TINY_B")
    ) u_tb ();
endmodule
