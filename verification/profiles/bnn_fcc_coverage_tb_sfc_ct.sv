// SFC_CT profile wrapper — contest judge point
// TOPOLOGY = {784, 256, 256, 10}, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 8, 10}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_sfc_ct;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{784, 256, 256, 10}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 8, 10}),
        .NUM_IMAGES       (8),
        .TIMEOUT          (200ms),
        .PROFILE_TAG      ("SFC_CT")
    ) u_tb ();
endmodule
