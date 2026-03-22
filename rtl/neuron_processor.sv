module neuron_processor #(
    parameter int P_W               = 8,
    parameter int MAX_NEURON_INPUTS = 784,
    parameter int BEAT_PC_W         = $clog2(P_W + 1),
    parameter int ACC_W             = $clog2(MAX_NEURON_INPUTS + 1)
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [P_W-1:0]       x_in,
    input  logic [P_W-1:0]       w_in,
    input  logic [ACC_W-1:0]     threshold_in,
    input  logic                 valid_in,
    input  logic                 last_in,

    output logic [ACC_W-1:0]     popcount_out,
    output logic                 act_out,
    output logic                 valid_out,


    //DEBUG SIGNALS ---REMIND: delete once verified correct---
    output logic [P_W-1:0]       dbg_xnor_bits,
    output logic [BEAT_PC_W-1:0] dbg_beat_popcount,
    output logic [ACC_W-1:0]     dbg_accum
);

    logic accept;
    logic final_beat;
    logic acc_we;
    logic acc_clr;
    logic out_we;

    NP_ctl u_ctl (
        .valid_in    (valid_in),
        .last_in     (last_in),
        .accept      (accept),
        .final_beat  (final_beat),
        .acc_we      (acc_we),
        .acc_clr     (acc_clr),
        .out_we      (out_we)
    );

    NP_datapath #(
        .P_W               (P_W),
        .MAX_NEURON_INPUTS (MAX_NEURON_INPUTS),
        .BEAT_PC_W         (BEAT_PC_W),
        .ACC_W             (ACC_W)
    ) u_dp (
        .clk              (clk),
        .rst              (rst),
        .x_in             (x_in),
        .w_in             (w_in),
        .threshold_in     (threshold_in),
        .acc_we           (acc_we),
        .acc_clr          (acc_clr),
        .out_we           (out_we),
        .popcount_out     (popcount_out),
        .act_out          (act_out),
        .valid_out        (valid_out),
        .dbg_xnor_bits    (dbg_xnor_bits),
        .dbg_beat_popcount(dbg_beat_popcount),
        .dbg_accum        (dbg_accum)
    );

endmodule
