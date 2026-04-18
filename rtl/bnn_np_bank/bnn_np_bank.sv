`timescale 1ns/100ps

module bnn_np_bank #(
    parameter int P_W           = 8,
    parameter int P_N           = 8,
    parameter int ACC_W         = 10,
    parameter int FAN_IN        = 784,
    parameter int FANOUT_STAGES = 0
)(
    input  logic                          clk,
    input  logic                          rst,

    
    input  logic [P_W-1:0]                x_in,

    //  Per-NP weight words (same cycle as x_in; read from per-NP RAMs) ─
    input  logic [P_N*P_W-1:0]            w_flat,

    //  Per-NP thresholds (ACC_W each; hidden layers only, ignored in
    //     output mode via mode_output_layer_sel) 
    input  logic [P_N*ACC_W-1:0]          thr_flat,

    
    input  logic                          np_valid_in,
    input  logic                          np_last,
    input  logic                          mode_output_layer_sel,

    
    output logic [P_N-1:0]                y_out,
    output logic [P_N*ACC_W-1:0]          score_out,
    output logic                          np_valid_out
);

    
    // x_in, w_flat, valid, last, and mode must remain cycle-aligned when
    // FANOUT_STAGES inserts timing-relief latency. Thresholds are pass/image
    // constant and stay at the module boundary.
    logic [P_W-1:0]       x_aligned;
    logic [P_N*P_W-1:0]   w_flat_aligned;
    logic                 np_valid_aligned;
    logic                 np_last_aligned;
    logic                 mode_output_layer_sel_aligned;

    // LOCAL_X_REG=1 when FANOUT_STAGES>=1: the last x pipeline register is
    // moved inside each NP_datapath so Vivado co-locates it with acc_r_q,
    // converting the 1.1 ns cross-NP fanout route into a short intra-NP path.
    localparam int NP_LOCAL_X_REG = (FANOUT_STAGES > 0) ? 1 : 0;

    bnn_fanout_buf #(
        .WIDTH       (P_W),
        .PIPE_STAGES (FANOUT_STAGES > 0 ? FANOUT_STAGES - 1 : 0)
    ) u_x_align (
        .clk (clk),
        .rst (rst),
        .d   (x_in),
        .q   (x_aligned)
    );

    bnn_fanout_buf #(
        .WIDTH       (P_N * P_W),
        .PIPE_STAGES (FANOUT_STAGES)
    ) u_w_align (
        .clk (clk),
        .rst (rst),
        .d   (w_flat),
        .q   (w_flat_aligned)
    );

    bnn_fanout_buf #(
        .WIDTH       (1),
        .PIPE_STAGES (FANOUT_STAGES)
    ) u_valid_align (
        .clk (clk),
        .rst (rst),
        .d   (np_valid_in),
        .q   (np_valid_aligned)
    );

    bnn_fanout_buf #(
        .WIDTH       (1),
        .PIPE_STAGES (FANOUT_STAGES)
    ) u_last_align (
        .clk (clk),
        .rst (rst),
        .d   (np_last),
        .q   (np_last_aligned)
    );

    bnn_fanout_buf #(
        .WIDTH       (1),
        .PIPE_STAGES (FANOUT_STAGES)
    ) u_mode_align (
        .clk (clk),
        .rst (rst),
        .d   (mode_output_layer_sel),
        .q   (mode_output_layer_sel_aligned)
    );

    
    logic              np_valid_lane [P_N];

    genvar gj;
    generate
        for (gj = 0; gj < P_N; gj++) begin : g_np

            logic [P_W-1:0]              lane_w;
            logic [ACC_W-1:0]            lane_thr;
            logic                        lane_act;
            logic [ACC_W-1:0]            lane_pop;

            // Debug outputs — internal only, not part of public contract
            logic [P_W-1:0]              dbg_xnor_bits;
            logic [$clog2(P_W+1)-1:0]    dbg_beat_popcount;
            logic [ACC_W-1:0]            dbg_accum;
            logic                        dbg_neuron_done;
            logic                        dbg_accept_beat;

            assign lane_w   = w_flat_aligned[gj*P_W   +: P_W];
            assign lane_thr = thr_flat[gj*ACC_W +: ACC_W];

            neuron_processor #(
                .P_W               (P_W),
                .MAX_NEURON_INPUTS (FAN_IN),
                .ACC_W             (ACC_W),
                .LOCAL_X_REG       (NP_LOCAL_X_REG)
            ) u_np (
                .clk                   (clk),
                .rst                   (rst),
                .x_in                  (x_aligned),
                .w_in                  (lane_w),
                .threshold_in          (lane_thr),
                .valid_in              (np_valid_aligned),
                .last                  (np_last_aligned),
                .mode_output_layer_sel (mode_output_layer_sel_aligned),
                .popcount_out          (lane_pop),
                .act_out               (lane_act),
                .valid_out             (np_valid_lane[gj]),
                .dbg_xnor_bits         (dbg_xnor_bits),
                .dbg_beat_popcount     (dbg_beat_popcount),
                .dbg_accum             (dbg_accum),
                .dbg_neuron_done       (dbg_neuron_done),
                .dbg_accept_beat       (dbg_accept_beat)
            );

            assign y_out[gj]                     = lane_act;
            assign score_out[gj*ACC_W +: ACC_W]  = lane_pop;
        end
    endgenerate

    // All lanes see identical control — lane 0's valid_out represents the bank.
    assign np_valid_out = np_valid_lane[0];

    
    initial begin
        assert (P_W  >= 1) else $fatal(1, "bnn_np_bank: P_W must be >= 1");
        assert (P_N  >= 1) else $fatal(1, "bnn_np_bank: P_N must be >= 1");
        assert (FAN_IN >= 1) else $fatal(1, "bnn_np_bank: FAN_IN must be >= 1");
        $display("bnn_np_bank: P_W=%0d P_N=%0d ACC_W=%0d FAN_IN=%0d FANOUT_STAGES=%0d",
                 P_W, P_N, ACC_W, FAN_IN, FANOUT_STAGES);
    end

endmodule
