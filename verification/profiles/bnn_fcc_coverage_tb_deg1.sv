// DEG1 profile wrapper — single-neuron pathological
// Deviation from §17.5.1: TOPOLOGY[last] bumped from 1 to 2 because bnn_argmax
// asserts NUM_CLASSES >= 2. Intent of DEG1 (PARALLEL_INPUTS=1 symmetry stress) is preserved
// TOPOLOGY = {8, 8, 1, 2}, 64/64/8 bus baseline, PARALLEL_INPUTS = 8, PARALLEL_NEURONS = {8, 1, 2}
`timescale 1ns / 100ps

module bnn_fcc_coverage_tb_deg1;
    bnn_fcc_coverage_tb #(
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{8, 8, 1, 2}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 1, 2}),
        .NUM_IMAGES       (5),
        .TIMEOUT          (10ms),
        .PROFILE_TAG      ("DEG1")
    ) u_tb ();
endmodule
