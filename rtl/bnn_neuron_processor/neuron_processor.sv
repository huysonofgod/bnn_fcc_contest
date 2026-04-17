module neuron_processor #(
    parameter int P_W               = 8,
    parameter int MAX_NEURON_INPUTS = 784,
    parameter int ACC_W             = $clog2(MAX_NEURON_INPUTS + 1)
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [P_W-1:0]       x_in,
    input  logic [P_W-1:0]       w_in,
    input  logic [ACC_W-1:0]     threshold_in,
    input  logic                 valid_in,
    input  logic                 last,
    input  logic                 mode_output_layer_sel,

    output logic [ACC_W-1:0]     popcount_out,
    output logic                 act_out,
    output logic                 valid_out,


    //DEBUG SIGNALS ---REMIND: delete once verified correct---
    output logic [P_W-1:0]       dbg_xnor_bits,
    output logic [$clog2(P_W + 1)-1:0] dbg_beat_popcount,
    output logic [ACC_W-1:0]     dbg_accum,
    output logic                 dbg_neuron_done,
    output logic                 dbg_accept_beat
);

    logic acc_we;
    logic acc_sel;
    logic activation_r_we;
    logic out_score_r_we;
    logic valid_out_we;
    logic dbg_threshold_pass_tap;

    NP_fsm u_fsm (
        .clk             (clk),
        .rst             (rst),
        .valid_in        (valid_in),
        .last_beat_in    (last),
        .acc_we          (acc_we),
        .acc_sel         (acc_sel),
        .activation_r_we (activation_r_we),
        .out_score_r_we  (out_score_r_we),
        .valid_out_we    (valid_out_we),
        .dbg_accept_beat (dbg_accept_beat),
        .dbg_neuron_done (dbg_neuron_done)
    );

    NP_datapath #(
        .P_W               (P_W),
        .MAX_NEURON_INPUTS (MAX_NEURON_INPUTS),
        .ACC_W             (ACC_W)
    ) u_dp (
        .clk                  (clk),
        .rst                  (rst),
        .x_in                 (x_in),
        .w_in                 (w_in),
        .threshold_in         (threshold_in),
        .acc_we               (acc_we),
        .acc_sel              (acc_sel),
        .mode_output_layer_sel(mode_output_layer_sel),
        .activation_r_we      (activation_r_we),
        .out_score_r_we       (out_score_r_we),
        .valid_out_we         (valid_out_we),
        .acc_score_out        (popcount_out),
        .activation_out       (act_out),
        .valid_out            (valid_out),
        .dbg_xnor_bits        (dbg_xnor_bits),
        .dbg_beat_popcount    (dbg_beat_popcount),
        .dbg_acc              (dbg_accum),
        .dbg_threshold_pass   (dbg_threshold_pass_tap)
    );

endmodule
