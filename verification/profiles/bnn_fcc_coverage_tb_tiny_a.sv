// TINY_A profile wrapper — small symmetric
// TOPOLOGY = {8, 8, 4, 2}, 64/64/8 bus baseline, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 4, 2}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_tiny_a;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{8, 8, 4, 2}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 4, 2}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("TINY_A")
    ) u_tb ();
endmodule
