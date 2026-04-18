// ODD profile wrapper — FAN_IN=17 padding stress
// TOPOLOGY = {17, 8, 5, 3}, 64/64/8 bus baseline, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 4, 3}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_odd;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{17, 8, 5, 3}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 4, 3}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("ODD")
    ) u_tb ();
endmodule
