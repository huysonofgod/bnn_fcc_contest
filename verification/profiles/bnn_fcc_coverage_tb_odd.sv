// ODD profile wrapper — FAN_IN=17 padding stress
// TOPOLOGY = {17, 7, 5, 3}, PARALLEL_INPUTS = 4, PARALLEL_NEURONS = {4, 4, 3}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_odd;
    bnn_fcc_coverage_tb #(
        .INPUT_BUS_WIDTH  (32),
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{17, 7, 5, 3}),
        .PARALLEL_INPUTS  (4),
        .PARALLEL_NEURONS ('{4, 4, 3}),
        .NUM_IMAGES       (10),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("ODD")
    ) u_tb ();
endmodule
