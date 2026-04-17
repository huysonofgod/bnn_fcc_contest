// DEG2 profile wrapper — shorter depth, TOTAL_LAYERS=3
// TOPOLOGY = {16, 4, 2}, PARALLEL_INPUTS = 4, PARALLEL_NEURONS = {4, 2}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_deg2;
    bnn_fcc_coverage_tb #(
        .INPUT_BUS_WIDTH  (32),
        .TOTAL_LAYERS     (3),
        .TOPOLOGY         ('{16, 4, 2}),
        .PARALLEL_INPUTS  (4),
        .PARALLEL_NEURONS ('{4, 2}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("DEG2")
    ) u_tb ();
endmodule
