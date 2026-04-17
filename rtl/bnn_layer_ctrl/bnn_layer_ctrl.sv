`timescale 1ns/10ps

module bnn_layer_ctrl #(
    parameter int P_W             = 1,
    parameter int P_N             = 8,
    parameter int NUM_NEURONS     = 10,
    parameter int FAN_IN          = 784,
    parameter int IS_OUTPUT_LAYER = 0,
    parameter int RESULT_WAIT_CYCLES = 0
)(
    input  logic  clk,
    input  logic  rst,

    // External control
    input  logic  start,            // pulse: begin processing
    output logic  busy,             // registered
    output logic  done,             // registered, 1-cycle pulse

    // Input buffer handshake
    input  logic  s_valid,
    output logic  s_ready,          // combinational from FSM (Moore from state)
    input  logic  s_last,

    // NP bank control (registered)
    output logic  np_valid_in,
    output logic  np_last,

    // RAM read enables (registered)
    output logic  wt_rd_en,
    output logic  thr_rd_en,

    // Result handshake to M4/M5 (registered)
    output logic  result_valid,
    input  logic  result_ready,

    // Strobes to bnn_seq_addr_gen
    output logic  iter_we,
    output logic  iter_clr,
    output logic  pass_we,
    output logic  pass_clr,
    output logic  wt_addr_we,
    output logic  thr_addr_we,
    output logic  vnp_we,

    // Status from bnn_seq_addr_gen
    input  logic  iter_tc,
    input  logic  pass_tc
);

    // FSM combinational D-inputs
    logic np_valid_d;
    logic np_last_d;
    logic wt_rd_en_d;
    logic thr_rd_en_d;
    logic result_valid_d;
    logic busy_d;
    logic done_d;
    // last_pass_d is consumed internally by bnn_seq_addr_gen via vnp_we; the
    // FSM does not need to stage it here.
    logic last_pass_d;

    // FSM instance
    bnn_layer_ctrl_fsm #(
        .RESULT_WAIT_CYCLES(RESULT_WAIT_CYCLES)
    ) u_fsm (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        .s_valid        (s_valid),
        .s_last         (s_last),
        .result_ready   (result_ready),
        .iter_tc        (iter_tc),
        .pass_tc        (pass_tc),
        .iter_we        (iter_we),
        .iter_clr       (iter_clr),
        .pass_we        (pass_we),
        .pass_clr       (pass_clr),
        .wt_addr_we     (wt_addr_we),
        .thr_addr_we    (thr_addr_we),
        .vnp_we         (vnp_we),
        .np_valid_d     (np_valid_d),
        .np_last_d      (np_last_d),
        .wt_rd_en_d     (wt_rd_en_d),
        .thr_rd_en_d    (thr_rd_en_d),
        .result_valid_d (result_valid_d),
        .last_pass_d    (last_pass_d),
        .busy_d         (busy_d),
        .done_d         (done_d),
        .s_ready        (s_ready)
    );

    // Output register block
    // All downstream-visible control signals are registered here so that
    // bnn_layer_ctrl still honors the "registered module boundaries" rule
    // after the counters/address regs have been extracted into
    // bnn_seq_addr_gen.
    logic np_valid_r_q;
    logic np_last_r_q;
    logic wt_rd_en_r_q;
    logic thr_rd_en_r_q;
    logic result_valid_r_q;
    logic busy_r_q;
    logic done_r_q;

    always_ff @(posedge clk) begin
        np_valid_r_q     <= np_valid_d;
        np_last_r_q      <= np_last_d;
        wt_rd_en_r_q     <= wt_rd_en_d;
        thr_rd_en_r_q    <= thr_rd_en_d;
        result_valid_r_q <= result_valid_d;
        busy_r_q         <= busy_d;
        done_r_q         <= done_d;

        if (rst) begin
            np_valid_r_q     <= 1'b0;
            np_last_r_q      <= 1'b0;
            wt_rd_en_r_q     <= 1'b0;
            thr_rd_en_r_q    <= 1'b0;
            result_valid_r_q <= 1'b0;
            busy_r_q         <= 1'b0;
            done_r_q         <= 1'b0;
        end
    end

    assign np_valid_in  = np_valid_r_q;
    assign np_last      = np_last_r_q;
    assign wt_rd_en     = wt_rd_en_r_q;
    assign thr_rd_en    = thr_rd_en_r_q;
    assign result_valid = result_valid_r_q;
    assign busy         = busy_r_q;
    assign done         = done_r_q;

    // Compile-time sanity checks
    initial begin
        assert (P_W  >= 1) else $fatal(1, "bnn_layer_ctrl: P_W must be >= 1");
        assert (P_N  >= 1) else $fatal(1, "bnn_layer_ctrl: P_N must be >= 1");
        assert (FAN_IN      >= 1) else $fatal(1, "bnn_layer_ctrl: FAN_IN must be >= 1");
        assert (NUM_NEURONS >= 1) else $fatal(1, "bnn_layer_ctrl: NUM_NEURONS must be >= 1");
        $display("bnn_layer_ctrl: P_W=%0d P_N=%0d FAN_IN=%0d NUM_NEURONS=%0d IS_OUTPUT_LAYER=%0b",
                 P_W, P_N, FAN_IN, NUM_NEURONS, IS_OUTPUT_LAYER);
    end

endmodule
