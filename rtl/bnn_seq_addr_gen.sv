`timescale 1ns/10ps

module bnn_seq_addr_gen #(
    parameter int P_W          = 1,
    parameter int P_N          = 8,
    parameter int NUM_NEURONS  = 10,
    parameter int FAN_IN       = 784,
    // Derived parameters used by parent wrappers
    localparam int ITERS       = (FAN_IN + P_W - 1) / P_W,
    localparam int PASSES      = (NUM_NEURONS + P_N - 1) / P_N,
    localparam int WT_ADDR_W   = $clog2((ITERS * PASSES) > 1 ? (ITERS * PASSES) : 2),
    localparam int THR_ADDR_W  = $clog2(PASSES > 1 ? PASSES : 2),
    localparam int NP_CNT_W    = $clog2(P_N + 1),
    localparam int ITER_W      = $clog2(ITERS > 1 ? ITERS : 2),
    localparam int PASS_W      = $clog2(PASSES > 1 ? PASSES : 2)
)(
    input  logic                   clk,
    input  logic                   rst,

    // Strobes from bnn_layer_ctrl (FSM)
    input  logic                   iter_we,
    input  logic                   iter_clr,
    input  logic                   pass_we,
    input  logic                   pass_clr,
    input  logic                   wt_addr_we,
    input  logic                   thr_addr_we,
    input  logic                   vnp_we,

    // Status back to bnn_layer_ctrl (FSM)
    output logic                   iter_tc,
    output logic                   pass_tc,

    // Registered addresses and pass state
    output logic [WT_ADDR_W-1:0]   wt_rd_addr,
    output logic [THR_ADDR_W-1:0]  thr_rd_addr,
    output logic [NP_CNT_W-1:0]    valid_np_count,
    output logic                   last_pass
);

    // Iteration counter
    logic [ITER_W-1:0] iter_cnt_r_q;
    logic [ITER_W-1:0] iter_next;

    assign iter_tc   = (iter_cnt_r_q == ITER_W'(ITERS - 1));
    assign iter_next = iter_clr ? '0 : (iter_cnt_r_q + 1'b1);

    always_ff @(posedge clk) begin
        if (iter_we)
            iter_cnt_r_q <= iter_next;

        if (rst)
            iter_cnt_r_q <= '0;
    end

    // Pass counter
    logic [PASS_W-1:0] pass_cnt_r_q;
    logic [PASS_W-1:0] pass_next;

    assign pass_tc   = (pass_cnt_r_q == PASS_W'(PASSES - 1));
    assign pass_next = pass_clr ? '0 : (pass_cnt_r_q + 1'b1);

    always_ff @(posedge clk) begin
        if (pass_we)
            pass_cnt_r_q <= pass_next;

        if (rst)
            pass_cnt_r_q <= '0;
    end

    // Weight address generation
    logic [WT_ADDR_W-1:0] wt_addr_base;
    logic [WT_ADDR_W-1:0] wt_addr_comb;
    logic [ITER_W-1:0]    wt_iter_sel;
    logic [WT_ADDR_W-1:0] wt_rd_addr_r_q;

    assign wt_addr_base = WT_ADDR_W'(pass_cnt_r_q) * WT_ADDR_W'(ITERS);
    //Weight reads are launched one cycle before the NP consumes a beat.
    //For non-terminal iterations, publish the NEXT iteration address so the
    // 1-cycle RAM output lines up with the next accepted input beat. On the
    //terminal iteration, hold the current address; LOAD_THR handles the next
    //pass prefetch.
    assign wt_iter_sel  = (iter_we && !iter_tc) ? iter_next : iter_cnt_r_q;
    assign wt_addr_comb = wt_addr_base + WT_ADDR_W'(wt_iter_sel);

    always_ff @(posedge clk) begin
        if (wt_addr_we)
            wt_rd_addr_r_q <= wt_addr_comb;

        if (rst)
            wt_rd_addr_r_q <= '0;
    end

    // Threshold address generation
    logic [THR_ADDR_W-1:0] thr_rd_addr_r_q;

    always_ff @(posedge clk) begin
        if (thr_addr_we)
            thr_rd_addr_r_q <= THR_ADDR_W'(pass_cnt_r_q);

        if (rst)
            thr_rd_addr_r_q <= '0;
    end

    // valid_np_count and last_pass
    // NUM_NEURONS % P_N; if 0, full pass uses P_N
    localparam int REMAINDER       = NUM_NEURONS % P_N;
    localparam int LAST_PASS_COUNT = (REMAINDER == 0) ? P_N : REMAINDER;

    logic [NP_CNT_W-1:0] valid_np_count_comb;
    logic [NP_CNT_W-1:0] valid_np_count_r_q;
    logic                last_pass_r_q;

    assign valid_np_count_comb = pass_tc ? NP_CNT_W'(LAST_PASS_COUNT)
                                         : NP_CNT_W'(P_N);

    always_ff @(posedge clk) begin
        if (vnp_we) begin
            valid_np_count_r_q <= valid_np_count_comb;
            last_pass_r_q      <= pass_tc;
        end

        if (rst) begin
            valid_np_count_r_q <= NP_CNT_W'(P_N);
            last_pass_r_q      <= 1'b0;
        end
    end

    // Output assignments
    assign wt_rd_addr     = wt_rd_addr_r_q;
    assign thr_rd_addr    = thr_rd_addr_r_q;
    assign valid_np_count = valid_np_count_r_q;
    assign last_pass      = last_pass_r_q;

    // Compile-time sanity checks
    initial begin
        assert (P_W  >= 1) else $fatal(1, "bnn_seq_addr_gen: P_W must be >= 1");
        assert (P_N  >= 1) else $fatal(1, "bnn_seq_addr_gen: P_N must be >= 1");
        assert (FAN_IN      >= 1) else $fatal(1, "bnn_seq_addr_gen: FAN_IN must be >= 1");
        assert (NUM_NEURONS >= 1) else $fatal(1, "bnn_seq_addr_gen: NUM_NEURONS must be >= 1");
        $display("bnn_seq_addr_gen: P_W=%0d P_N=%0d FAN_IN=%0d NUM_NEURONS=%0d ITERS=%0d PASSES=%0d",
                 P_W, P_N, FAN_IN, NUM_NEURONS, ITERS, PASSES);
    end

endmodule
