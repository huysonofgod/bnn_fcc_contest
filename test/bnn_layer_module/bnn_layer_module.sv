`timescale 1ns / 100ps

module bnn_layer_module #(
    parameter int  LAYER_IDX       = 0,
    parameter int  FAN_IN          = 784,
    parameter int  NUM_NEURONS     = 256,
    parameter int  P_W             = 8,
    parameter int  P_N             = 8,
    parameter int  NEXT_P_W        = 8,             // P_W of next layer (unused if output)
    parameter int  ACC_W           = 10,            // $clog2(MAX_FANIN+1)
    parameter bit  IS_OUTPUT_LAYER = 1'b0,
    parameter int  LID_W           = 2,
    parameter int  FANOUT_STAGES   = 0              // bnn_fanout_buf PIPE_STAGES
) (
    input  logic                          clk,
    input  logic                          rst,

    // Per-image control ----------------------------------------------    input  logic                          start,
    output logic                          busy,
    output logic                          done,

    // Compute stream in (binary words from prev layer or binarizer) --    input  logic                          s_valid,
    output logic                          s_ready,
    input  logic [P_W-1:0]                s_data,
    input  logic                          s_last,

    // Hidden-layer downstream (packed binary, IS_OUTPUT_LAYER==0) ----    output logic                          m_valid,
    input  logic                          m_ready,
    output logic [NEXT_P_W-1:0]           m_data,
    output logic                          m_last,

    // Output-layer downstream (raw scores, IS_OUTPUT_LAYER==1) -------    output logic                          score_valid,
    input  logic                          score_ready,
    output logic [NUM_NEURONS*ACC_W-1:0]  score_data,
    output logic                          score_last,

    // Configuration write port (weight RAMs) -------------------------    input  logic                          cfg_wr_valid,
    output logic                          cfg_wr_ready,
    input  logic [LID_W-1:0]              cfg_wr_layer,
    input  logic [15:0]                   cfg_wr_np,
    input  logic [15:0]                   cfg_wr_addr,
    input  logic [P_W-1:0]                cfg_wr_data,

    // Configuration write port (threshold RAMs) ----------------------    input  logic                          cfg_thr_valid,
    output logic                          cfg_thr_ready,
    input  logic [LID_W-1:0]              cfg_thr_layer,
    input  logic [15:0]                   cfg_thr_np,
    input  logic [15:0]                   cfg_thr_addr,
    input  logic [31:0]                   cfg_thr_data
);

    // Localparams — must match M3 bnn_layer_ctrl formulas exactly
    localparam int ITERS      = (FAN_IN + P_W - 1) / P_W;
    localparam int PASSES     = (NUM_NEURONS + P_N - 1) / P_N;
    localparam int WT_DEPTH   = ITERS * PASSES;
    localparam int THR_DEPTH  = PASSES;

    // Wire widths — match M3's localparam formulas for port compatibility
    localparam int WT_ADDR_W  = $clog2(ITERS * PASSES);
    localparam int THR_ADDR_W = $clog2(PASSES > 1 ? PASSES : 2);
    localparam int NP_CNT_W   = $clog2(P_N + 1);
    localparam int NP_ID_W    = (P_N > 1) ? $clog2(P_N) : 1;

    // RAM address widths — safe minimum of 1 for bnn_dp_ram port compatibility
    localparam int WT_RAM_ADDR_W  = (WT_DEPTH  > 1) ? $clog2(WT_DEPTH)  : 1;
    localparam int THR_RAM_ADDR_W = (THR_DEPTH > 1) ? $clog2(THR_DEPTH) : 1;

    // BRAM writes have no backpressure
    assign cfg_wr_ready  = 1'b1;
    assign cfg_thr_ready = 1'b1;

    // M2 — Input buffer (elastic FIFO between upstream and M3)
    logic            buf_valid;
    logic            buf_ready;
    logic [P_W-1:0]  buf_data;
    logic            buf_last;

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
        .m_valid (buf_valid),
        .m_ready (buf_ready),
        .m_data  (buf_data),
        .m_last  (buf_last),
        .count   ()              // unused
    );

    // L4 — Fan-out buffer for NP x_in broadcast
    logic [P_W-1:0] x_bcast;

    bnn_fanout_buf #(
        .WIDTH       (P_W),
        .PIPE_STAGES (FANOUT_STAGES)
    ) u_data_fanout (
        .clk (clk),
        .rst (rst),
        .d   (buf_data),
        .q   (x_bcast)
    );

    // M3 — Layer controller FSM
    logic                    np_valid_in;
    logic                    np_last;
    logic [WT_ADDR_W-1:0]   wt_rd_addr;
    logic                    wt_rd_en;
    logic [THR_ADDR_W-1:0]  thr_rd_addr;
    logic                    thr_rd_en;
    logic                    result_valid;
    logic                    result_ready;
    logic [NP_CNT_W-1:0]    valid_np_count;
    logic                    last_pass;
    logic                    layer_busy;
    logic                    layer_done;

    // Strobes/status between FSM and sequencer
    logic iter_we, iter_clr;
    logic pass_we, pass_clr;
    logic wt_addr_we, thr_addr_we, vnp_we;
    logic iter_tc, pass_tc;

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
        .busy         (layer_busy),
        .done         (layer_done),
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

    // Passthrough busy/done from M3 to top-level ports
    assign busy = layer_busy;
    assign done = layer_done;

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

    // Per-NP: Weight RAMs + Threshold RAMs + Neuron Processors
    logic [P_W-1:0]    wt_rd_data   [P_N];
    logic [ACC_W-1:0]  thr_rd_data  [P_N];

    logic              np_act       [P_N];
    logic [ACC_W-1:0]  np_popcount  [P_N];
    logic              np_valid_out [P_N];

    // Concatenated vectors for M4/M5
    logic [P_N-1:0]           y_concat;
    logic [P_N*ACC_W-1:0]     score_concat;

    generate
        for (gj = 0; gj < P_N; gj++) begin : g_np_bank

            // Weight RAM (always present) ----------------------------            bnn_dp_ram #(
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
                .rd_data (wt_rd_data[gj])
            );

            // Threshold RAM (hidden layers only) ---------------------            if (IS_OUTPUT_LAYER == 1'b0) begin : g_thr_ram
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
                    .rd_data (thr_rd_data[gj])
                );
            end else begin : g_no_thr_ram
                // Output layer: tie threshold to zero (NP ignores it in output mode)
                assign thr_rd_data[gj] = '0;
            end

            // Neuron Processor ---------------------------------------            // Debug outputs connected to local wires (not part of public contract)
            logic [P_W-1:0]                   dbg_xnor_bits;
            logic [$clog2(P_W+1)-1:0]         dbg_beat_popcount;
            logic [ACC_W-1:0]                  dbg_accum;
            logic                              dbg_neuron_done;
            logic                              dbg_accept_beat;

            neuron_processor #(
                .P_W               (P_W),
                .MAX_NEURON_INPUTS (FAN_IN),
                .ACC_W             (ACC_W)
            ) u_np (
                .clk                    (clk),
                .rst                    (rst),
                .x_in                   (x_bcast),
                .w_in                   (wt_rd_data[gj]),
                .threshold_in           (thr_rd_data[gj]),
                .valid_in               (np_valid_in),
                .last                   (np_last),
                .mode_output_layer_sel  (IS_OUTPUT_LAYER),
                .popcount_out           (np_popcount[gj]),
                .act_out                (np_act[gj]),
                .valid_out              (np_valid_out[gj]),
                .dbg_xnor_bits         (dbg_xnor_bits),
                .dbg_beat_popcount     (dbg_beat_popcount),
                .dbg_accum             (dbg_accum),
                .dbg_neuron_done       (dbg_neuron_done),
                .dbg_accept_beat       (dbg_accept_beat)
            );

            assign y_concat[gj]                      = np_act[gj];
            assign score_concat[gj*ACC_W +: ACC_W]   = np_popcount[gj];
        end
    endgenerate

    // M4 (hidden) or M5 (output) — compile-time selection via generate
    generate
        if (IS_OUTPUT_LAYER == 1'b0) begin : g_hidden
            // M4 Activation Packer (hidden layers) -------------------            bnn_activation_packer #(
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

            // Tie unused output-layer ports
            assign score_valid = 1'b0;
            assign score_data  = '0;
            assign score_last  = 1'b0;

        end else begin : g_output
            // M5 score collector for output layer
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

            // Tie unused hidden-layer ports
            assign m_valid = 1'b0;
            assign m_data  = '0;
            assign m_last  = 1'b0;
        end
    endgenerate

    // Assertions

    // A1. cfg_wr_np must be in range when writing to this layer
    property p_cfg_wr_np_in_range;
        @(posedge clk) disable iff (rst)
            layer_match_wr |-> (cfg_wr_np < P_N);
    endproperty
    a_cfg_wr_np_in_range: assert property (p_cfg_wr_np_in_range)
        else $error("bnn_layer_module[%0d]: cfg_wr_np=%0d >= P_N=%0d",
                    LAYER_IDX, cfg_wr_np, P_N);

    // A2. Threshold upper bits must be zero when writing to this layer
    generate
        if (IS_OUTPUT_LAYER == 1'b0 && ACC_W < 32) begin : g_thr_assertions
            property p_thr_upper_bits_zero;
                @(posedge clk) disable iff (rst)
                    layer_match_thr |-> (cfg_thr_data[31:ACC_W] == '0);
            endproperty
            a_thr_upper_bits_zero: assert property (p_thr_upper_bits_zero)
                else $error("bnn_layer_module[%0d]: threshold upper bits non-zero (data=0x%08h, ACC_W=%0d)",
                            LAYER_IDX, cfg_thr_data, ACC_W);
        end
    endgenerate

    // A3. Output layer must never receive threshold writes
    generate
        if (IS_OUTPUT_LAYER == 1'b1) begin : g_no_thr_for_output
            property p_no_thr_writes_to_output;
                @(posedge clk) disable iff (rst)
                    !layer_match_thr;
            endproperty
            a_no_thr_writes_to_output: assert property (p_no_thr_writes_to_output)
                else $warning("bnn_layer_module[%0d]: threshold write to output layer",
                             LAYER_IDX);
        end
    endgenerate

    // Compile-time sanity checks
    initial begin
        assert (P_N >= 1)  else $fatal(1, "bnn_layer_module: P_N must be >= 1");
        assert (P_W >= 1)  else $fatal(1, "bnn_layer_module: P_W must be >= 1");
        assert (FAN_IN >= 1) else $fatal(1, "bnn_layer_module: FAN_IN must be >= 1");
        assert (NUM_NEURONS >= 1) else $fatal(1, "bnn_layer_module: NUM_NEURONS must be >= 1");
        $display("bnn_layer_module[%0d]: P_W=%0d P_N=%0d FAN_IN=%0d NUM_NEURONS=%0d",
                 LAYER_IDX, P_W, P_N, FAN_IN, NUM_NEURONS);
        $display("  ITERS=%0d PASSES=%0d WT_DEPTH=%0d THR_DEPTH=%0d ACC_W=%0d",
                 ITERS, PASSES, WT_DEPTH, THR_DEPTH, ACC_W);
        $display("  IS_OUTPUT_LAYER=%0b NEXT_P_W=%0d FANOUT_STAGES=%0d",
                 IS_OUTPUT_LAYER, NEXT_P_W, FANOUT_STAGES);
    end

endmodule
