`timescale 1ns/10ps

module bnn_layer_engine #(
    parameter int  LAYER_IDX       = 0,
    parameter int  FAN_IN          = 784,
    parameter int  NUM_NEURONS     = 256,
    parameter int  P_W             = 8,
    parameter int  P_N             = 8,
    parameter int  NEXT_P_W        = 8,
    parameter int  ACC_W           = 10,
    parameter bit  IS_OUTPUT_LAYER = 1'b0,
    parameter int  LID_W           = 2,
    parameter int  FANOUT_STAGES   = 0
)(
    input  logic                          clk,
    input  logic                          rst,

    // Per-image control
    input  logic                          start,
    output logic                          busy,
    output logic                          done,

    //  Compute stream in (binary words from prev layer / binarizer) 
    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic [P_W-1:0]                s_data,
    input  logic                          s_last,

    //  Hidden-layer downstream (packed binary; IS_OUTPUT_LAYER=0) 
    output logic                          m_valid,
    input  logic                          m_ready,
    output logic [NEXT_P_W-1:0]           m_data,
    output logic                          m_last,

    //  Output-layer downstream (raw scores; IS_OUTPUT_LAYER=1) 
    output logic                          score_valid,
    input  logic                          score_ready,
    output logic [NUM_NEURONS*ACC_W-1:0]  score_data,
    output logic                          score_last,

    //  Configuration write port (weight RAMs) 
    input  logic                          cfg_wr_valid,
    output logic                          cfg_wr_ready,
    input  logic [LID_W-1:0]              cfg_wr_layer,
    input  logic [15:0]                   cfg_wr_np,
    input  logic [15:0]                   cfg_wr_addr,
    input  logic [P_W-1:0]                cfg_wr_data,

    // ─── Configuration write port (threshold RAMs) ─────────────────────
    input  logic                          cfg_thr_valid,
    output logic                          cfg_thr_ready,
    input  logic [LID_W-1:0]              cfg_thr_layer,
    input  logic [15:0]                   cfg_thr_np,
    input  logic [15:0]                   cfg_thr_addr,
    input  logic [31:0]                   cfg_thr_data
);

    localparam int ITERS           = (FAN_IN + P_W - 1) / P_W;
    localparam int PASSES          = (NUM_NEURONS + P_N - 1) / P_N;
    localparam int WT_DEPTH        = ITERS * PASSES;
    localparam int THR_DEPTH       = PASSES;

    localparam int WT_ADDR_W       = $clog2((ITERS * PASSES) > 1 ? (ITERS * PASSES) : 2);
    localparam int THR_ADDR_W      = $clog2(PASSES > 1 ? PASSES : 2);
    localparam int NP_CNT_W        = $clog2(P_N + 1);
    localparam int NP_ID_W         = (P_N > 1) ? $clog2(P_N) : 1;

    localparam int WT_RAM_ADDR_W   = (WT_DEPTH  > 1) ? $clog2(WT_DEPTH)  : 1;
    localparam int THR_RAM_ADDR_W  = (THR_DEPTH > 1) ? $clog2(THR_DEPTH) : 1;

    // RAM writes have no backpressure.
    assign cfg_wr_ready  = 1'b1;
    assign cfg_thr_ready = 1'b1;


    logic            buf_src_valid;
    logic            buf_src_ready;
    logic [P_W-1:0]  buf_src_data;
    logic            buf_src_last;
    logic            buf_valid;
    logic            buf_ready;
    logic [P_W-1:0]  buf_data;
    logic            buf_last;
    logic            replay_restart;
    logic            image_start;
    logic [P_W-1:0]  np_x_r_q;
    logic            np_x_sample;

    bnn_input_buffer #(
        .WIDTH (P_W),
        .DEPTH (4)
    ) u_in_buf (
        .clk     (clk),
        .rst     (rst),
        .s_valid (s_valid),
        .s_ready (s_ready),
        .s_data  (s_data),
        .s_last  (s_last),
        .m_valid (buf_src_valid),
        .m_ready (buf_src_ready),
        .m_data  (buf_src_data),
        .m_last  (buf_src_last),
        .count   ()
    );

    bnn_image_replay_buffer #(
        .WIDTH (P_W),
        .DEPTH (ITERS)
    ) u_img_replay (
        .clk            (clk),
        .rst            (rst),
        .image_start    (image_start),
        .replay_restart (replay_restart),
        .in_valid       (buf_src_valid),
        .in_ready       (buf_src_ready),
        .in_data        (buf_src_data),
        .in_last        (buf_src_last),
        .out_valid      (buf_valid),
        .out_ready      (buf_ready),
        .out_data       (buf_data),
        .out_last       (buf_last)
    );

    logic                    np_valid_in;
    logic                    np_last;
    logic                    wt_rd_en;
    logic                    thr_rd_en;
    logic                    result_valid;
    logic                    result_ready;

    logic                    iter_we;
    logic                    iter_clr;
    logic                    pass_we;
    logic                    pass_clr;
    logic                    wt_addr_we;
    logic                    thr_addr_we;
    logic                    vnp_we;

    logic                    iter_tc;
    logic                    pass_tc;

    logic [WT_ADDR_W-1:0]    wt_rd_addr;
    logic [THR_ADDR_W-1:0]   thr_rd_addr;
    logic [NP_CNT_W-1:0]     valid_np_count;
    logic                    last_pass;

    assign image_start    = start & ~busy;
    assign replay_restart = pass_we & ~pass_clr;
    assign np_x_sample    = buf_valid & buf_ready;

    // Hold the exact accepted input beat so the NP bank sees it in the same
    // cycle as the registered np_valid/np_last controls and RAM outputs.
    always_ff @(posedge clk) begin
        if (rst || image_start) begin
            np_x_r_q <= '0;
        end else if (np_x_sample) begin
            np_x_r_q <= buf_data;
        end
    end

    bnn_layer_ctrl #(
        .P_W             (P_W),
        .P_N             (P_N),
        .NUM_NEURONS     (NUM_NEURONS),
        .FAN_IN          (FAN_IN),
        .IS_OUTPUT_LAYER (IS_OUTPUT_LAYER),
        .RESULT_WAIT_CYCLES(FANOUT_STAGES)
    ) u_ctrl (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .busy         (busy),
        .done         (done),
        .s_valid      (buf_valid),
        .s_ready      (buf_ready),
        .s_last       (buf_last),
        .np_valid_in  (np_valid_in),
        .np_last      (np_last),
        .wt_rd_en     (wt_rd_en),
        .thr_rd_en    (thr_rd_en),
        .result_valid (result_valid),
        .result_ready (result_ready),
        .iter_we      (iter_we),
        .iter_clr     (iter_clr),
        .pass_we      (pass_we),
        .pass_clr     (pass_clr),
        .wt_addr_we   (wt_addr_we),
        .thr_addr_we  (thr_addr_we),
        .vnp_we       (vnp_we),
        .iter_tc      (iter_tc),
        .pass_tc      (pass_tc)
    );

    bnn_seq_addr_gen #(
        .P_W         (P_W),
        .P_N         (P_N),
        .NUM_NEURONS (NUM_NEURONS),
        .FAN_IN      (FAN_IN)
    ) u_seq (
        .clk            (clk),
        .rst            (rst),
        .iter_we        (iter_we),
        .iter_clr       (iter_clr),
        .pass_we        (pass_we),
        .pass_clr       (pass_clr),
        .wt_addr_we     (wt_addr_we),
        .thr_addr_we    (thr_addr_we),
        .vnp_we         (vnp_we),
        .iter_tc        (iter_tc),
        .pass_tc        (pass_tc),
        .wt_rd_addr     (wt_rd_addr),
        .thr_rd_addr    (thr_rd_addr),
        .valid_np_count (valid_np_count),
        .last_pass      (last_pass)
    );

    // Per-NP write-enable decode
    logic                layer_match_wr;
    logic                layer_match_thr;
    logic [P_N-1:0]      wt_we;
    logic [P_N-1:0]      thr_we;

    assign layer_match_wr  = cfg_wr_valid  & (cfg_wr_layer  == LAYER_IDX[LID_W-1:0]);
    assign layer_match_thr = cfg_thr_valid & (cfg_thr_layer == LAYER_IDX[LID_W-1:0]);

    genvar gj;
    generate
        for (gj = 0; gj < P_N; gj++) begin : g_we_decode
            assign wt_we[gj]  = layer_match_wr  & (cfg_wr_np[NP_ID_W-1:0]  == gj[NP_ID_W-1:0]);
            assign thr_we[gj] = layer_match_thr & (cfg_thr_np[NP_ID_W-1:0] == gj[NP_ID_W-1:0]);
        end
    endgenerate

    // Per-NP Weight RAMs + Threshold RAMs
    logic [P_N*P_W-1:0]       w_flat;
    logic [P_N*ACC_W-1:0]     thr_flat;

    generate
        for (gj = 0; gj < P_N; gj++) begin : g_mem

            logic [P_W-1:0]   wt_rd_data;
            logic [ACC_W-1:0] thr_rd_data;

            bnn_dp_ram #(
                .WIDTH      (P_W),
                .DEPTH      (WT_DEPTH),
                .OUTPUT_REG (0),
                .MEM_STYLE  ("block")
            ) u_wt_ram (
                .clk     (clk),
                .rst     (rst),
                .wr_en   (wt_we[gj]),
                .wr_addr (cfg_wr_addr[WT_RAM_ADDR_W-1:0]),
                .wr_data (cfg_wr_data),
                .rd_en   (wt_rd_en),
                .rd_addr (wt_rd_addr[WT_RAM_ADDR_W-1:0]),
                .rd_data (wt_rd_data)
            );

            if (IS_OUTPUT_LAYER == 1'b0) begin : g_thr_ram
                bnn_dp_ram #(
                    .WIDTH      (ACC_W),
                    .DEPTH      (THR_DEPTH),
                    .OUTPUT_REG (0),
                    .MEM_STYLE  ("distributed")
                ) u_thr_ram (
                    .clk     (clk),
                    .rst     (rst),
                    .wr_en   (thr_we[gj]),
                    .wr_addr (cfg_thr_addr[THR_RAM_ADDR_W-1:0]),
                    .wr_data (cfg_thr_data[ACC_W-1:0]),
                    .rd_en   (thr_rd_en),
                    .rd_addr (thr_rd_addr[THR_RAM_ADDR_W-1:0]),
                    .rd_data (thr_rd_data)
                );
            end else begin : g_no_thr_ram
                assign thr_rd_data = '0;
            end

            assign w_flat  [gj*P_W   +: P_W]   = wt_rd_data;
            assign thr_flat[gj*ACC_W +: ACC_W] = thr_rd_data;
        end
    endgenerate

    // bnn_np_bank (fan-out + P_N × neuron_processor)
    logic [P_N-1:0]          y_concat;
    logic [P_N*ACC_W-1:0]    score_concat;
    logic                    np_valid_out;

    bnn_np_bank #(
        .P_W           (P_W),
        .P_N           (P_N),
        .ACC_W         (ACC_W),
        .FAN_IN        (FAN_IN),
        .FANOUT_STAGES (FANOUT_STAGES)
    ) u_np_bank (
        .clk                   (clk),
        .rst                   (rst),
        .x_in                  (np_x_r_q),
        .w_flat                (w_flat),
        .thr_flat              (thr_flat),
        .np_valid_in           (np_valid_in),
        .np_last               (np_last),
        .mode_output_layer_sel (IS_OUTPUT_LAYER),
        .y_out                 (y_concat),
        .score_out             (score_concat),
        .np_valid_out          (np_valid_out)
    );

    //  (hidden) or  (output)
    generate
        if (IS_OUTPUT_LAYER == 1'b0) begin : g_hidden
            bnn_activation_packer #(
                .IN_BITS  (P_N),
                .OUT_BITS (NEXT_P_W)
            ) u_packer (
                .clk          (clk),
                .rst          (rst),
                .s_valid      (result_valid),
                .s_ready      (result_ready),
                .s_data       (y_concat),
                .s_count      (valid_np_count),
                .s_last_group (last_pass),
                .m_valid      (m_valid),
                .m_ready      (m_ready),
                .m_data       (m_data),
                .m_last       (m_last)
            );

            assign score_valid = 1'b0;
            assign score_data  = '0;
            assign score_last  = 1'b0;

        end else begin : g_output
            bnn_score_collector #(
                .P_N         (P_N),
                .NUM_NEURONS (NUM_NEURONS),
                .ACC_W       (ACC_W)
            ) u_collector (
                .clk         (clk),
                .rst         (rst),
                .s_valid     (result_valid),
                .s_ready     (result_ready),
                .s_scores    (score_concat),
                .s_count     (valid_np_count),
                .s_last_pass (last_pass),
                .m_valid     (score_valid),
                .m_ready     (score_ready),
                .m_scores    (score_data),
                .m_last      (score_last)
            );

            assign m_valid = 1'b0;
            assign m_data  = '0;
            assign m_last  = 1'b0;
        end
    endgenerate

    // =========================================================================
    // Compile-time sanity
    // =========================================================================
    initial begin
        assert (P_N >= 1)  else $fatal(1, "bnn_layer_engine: P_N must be >= 1");
        assert (P_W >= 1)  else $fatal(1, "bnn_layer_engine: P_W must be >= 1");
        assert (FAN_IN >= 1) else $fatal(1, "bnn_layer_engine: FAN_IN must be >= 1");
        assert (NUM_NEURONS >= 1) else $fatal(1, "bnn_layer_engine: NUM_NEURONS must be >= 1");
        $display("bnn_layer_engine[%0d]: P_W=%0d P_N=%0d FAN_IN=%0d NUM_NEURONS=%0d IS_OUTPUT_LAYER=%0b",
                 LAYER_IDX, P_W, P_N, FAN_IN, NUM_NEURONS, IS_OUTPUT_LAYER);
    end

endmodule
