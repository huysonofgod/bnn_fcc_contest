// DEG2 profile wrapper — shorter depth, TOTAL_LAYERS=3
// TOPOLOGY = {16, 8, 2}, 64/64/8 bus baseline, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 2}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_deg2;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (3),
        .TOPOLOGY         ('{16, 8, 2}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 2}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("DEG2")
    ) u_tb ();
endmodule
