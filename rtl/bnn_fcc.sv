module bnn_fcc #(
    parameter int INPUT_DATA_WIDTH  = 8,
    parameter int INPUT_BUS_WIDTH   = 64,
    parameter int CONFIG_BUS_WIDTH  = 64,
    parameter int OUTPUT_DATA_WIDTH = 4,
    parameter int OUTPUT_BUS_WIDTH  = 8,

    parameter int TOTAL_LAYERS = 4,  // Includes input, hidden, and output
    parameter int TOPOLOGY[TOTAL_LAYERS] = '{0: 784, 1: 256, 2: 256, 3: 10, default: 0},  // 0: input, TOTAL_LAYERS-1: output

    parameter int PARALLEL_INPUTS = 8,
    parameter int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{default: 8}
) (
    input logic clk,
    input logic rst,

    // AXI streaming configuration interface (consumer)
    input  logic                          config_valid,
    output logic                          config_ready,
    input  logic [  CONFIG_BUS_WIDTH-1:0] config_data,
    input  logic [CONFIG_BUS_WIDTH/8-1:0] config_keep,
    input  logic                          config_last,

    // AXI streaming image input interface (consumer)
    input  logic                         data_in_valid,
    output logic                         data_in_ready,
    input  logic [  INPUT_BUS_WIDTH-1:0] data_in_data,
    input  logic [INPUT_BUS_WIDTH/8-1:0] data_in_keep,
    input  logic                         data_in_last,

    // AXI streaming classification output interface (producer)
    output logic                          data_out_valid,
    input  logic                          data_out_ready,
    output logic [  OUTPUT_BUS_WIDTH-1:0] data_out_data,
    output logic [OUTPUT_BUS_WIDTH/8-1:0] data_out_keep,
    output logic                          data_out_last
);

    // -------------------------------------------------------------------------
    // Small constant helpers for per-layer width derivation.
    // These use fixed-size parameter arrays in constant contexts, which Questa
    // accepts reliably for generate-time localparams.
    // -------------------------------------------------------------------------
    function automatic int layer_pw_const(input int idx);
        if (idx == 0)
            return PARALLEL_INPUTS;
        return PARALLEL_NEURONS[idx - 1];
    endfunction

    function automatic int layer_pn_const(input int idx);
        return PARALLEL_NEURONS[idx];
    endfunction

    // -------------------------------------------------------------------------
    // Configuration manager.
    // It emits per-layer arrays, and each layer engine gets only its matching
    // index. Layer engines still check cfg_wr_layer/cfg_thr_layer internally.
    // -------------------------------------------------------------------------
    logic [NLY-1:0]                 cfg_wr_valid;
    logic [NLY-1:0]                 cfg_wr_ready;
    logic [NLY-1:0][LID_W-1:0]      cfg_wr_layer;
    logic [NLY-1:0][7:0]            cfg_mgr_wr_np;
    logic [15:0]                    cfg_wr_np [NLY];
    logic [NLY-1:0][15:0]           cfg_wr_addr;
    logic [NLY-1:0][MAX_CFG_PW-1:0] cfg_wr_data;
    logic [NLY-1:0]                 cfg_wr_last_word;
    logic [NLY-1:0]                 cfg_wr_last_neuron;
    logic [NLY-1:0]                 cfg_wr_last_msg;

    logic [NLY-1:0]                 cfg_thr_valid;
    logic [NLY-1:0]                 cfg_thr_ready;
    logic [NLY-1:0][LID_W-1:0]      cfg_thr_layer;
    logic [NLY-1:0][7:0]            cfg_mgr_thr_np;
    logic [15:0]                    cfg_thr_np [NLY];
    logic [NLY-1:0][15:0]           cfg_thr_addr;
    logic [NLY-1:0][31:0]           cfg_thr_data;

    logic                           cfg_done;
    logic                           cfg_done_r_q;
    logic                           cfg_error;
    logic [15:0]                    cfg_extra_t2_count;

    bnn_config_manager #(
        .CONFIG_BUS_WIDTH (CONFIG_BUS_WIDTH),
        .TOTAL_LAYERS     (TOTAL_LAYERS),
        .TOPOLOGY         (TOPOLOGY),
        .PARALLEL_INPUTS  (PARALLEL_INPUTS),
        .PARALLEL_NEURONS (PARALLEL_NEURONS),
        .ACC_W            (ACC_W),
        .MAX_PW           (MAX_CFG_PW)
    ) u_cfg_mgr (
        .clk                (clk),
        .rst                (rst),
        .config_valid       (config_valid),
        .config_ready       (config_ready),
        .config_data        (config_data),
        .config_keep        (config_keep),
        .config_last        (config_last),
        .cfg_wr_valid       (cfg_wr_valid),
        .cfg_wr_ready       (cfg_wr_ready),
        .cfg_wr_layer       (cfg_wr_layer),
        .cfg_wr_np          (cfg_mgr_wr_np),
        .cfg_wr_addr        (cfg_wr_addr),
        .cfg_wr_data        (cfg_wr_data),
        .cfg_wr_last_word   (cfg_wr_last_word),
        .cfg_wr_last_neuron (cfg_wr_last_neuron),
        .cfg_wr_last_msg    (cfg_wr_last_msg),
        .cfg_thr_valid      (cfg_thr_valid),
        .cfg_thr_ready      (cfg_thr_ready),
        .cfg_thr_layer      (cfg_thr_layer),
        .cfg_thr_np         (cfg_mgr_thr_np),
        .cfg_thr_addr       (cfg_thr_addr),
        .cfg_thr_data       (cfg_thr_data),
        .cfg_done           (cfg_done),
        .cfg_error          (cfg_error),
        .cfg_extra_t2_count (cfg_extra_t2_count)
    );

    // latch cfg_done and feed it as a level-sensitive start to
    // every layer. Layer FSMs only sample start in IDLE, so holding it high
    // allows each layer to auto-restart for the next image without extra
    // per-layer top-level control state.
    always_ff @(posedge clk) begin
        if (cfg_done)
            cfg_done_r_q <= 1'b1;

        if (rst)
            cfg_done_r_q <= 1'b0;
    end

    genvar gn;
    generate
        for (gn = 0; gn < NLY; gn++) begin : g_cfg_np_extend
            assign cfg_wr_np[gn]  = {8'h00, cfg_mgr_wr_np[gn]};
            assign cfg_thr_np[gn] = {8'h00, cfg_mgr_thr_np[gn]};
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Image front end.
    // Address generator maps one input beat directly to one PARALLEL_INPUTS word, this
    // implementation requires INPUT_BUS_WIDTH/INPUT_DATA_WIDTH == PARALLEL_INPUTS.
    // -------------------------------------------------------------------------
    logic                     pix_valid;
    logic                     pix_ready;
    logic [PARALLEL_INPUTS-1:0] pix_data;
    logic                     pix_last;
    logic                     pix_buf_valid;
    logic                     pix_buf_ready;
    logic [PARALLEL_INPUTS-1:0] pix_buf_data;
    logic                     pix_buf_last;

    // -------------------------------------------------------------------------
    // Stream buses between the front end, inter-layer buffers, and engines.
    // Data is padded to MAX_STREAM_W; each instance slices only its own width.
    // These declarations appear before the image buffer because its m_ready is
    // driven by layer_in_ready[0].
    // -------------------------------------------------------------------------
    logic [NLY-1:0]                    layer_in_valid;
    logic [NLY-1:0]                    layer_in_ready;
    logic [NLY-1:0][MAX_STREAM_W-1:0]  layer_in_data;
    logic [NLY-1:0]                    layer_in_last;

    logic [NLY-1:0]                    hidden_valid;
    logic [NLY-1:0]                    hidden_ready;
    logic [NLY-1:0][MAX_STREAM_W-1:0]  hidden_data;
    logic [NLY-1:0]                    hidden_last;

    bnn_input_binarizer #(
        .BUS_WIDTH        (INPUT_BUS_WIDTH),
        .P_W              (PARALLEL_INPUTS)
    ) u_binarizer (
        .clk     (clk),
        .rst     (rst),
        .s_valid (data_in_valid & cfg_done_r_q),
        .s_ready (pix_ready),
        .s_data  (data_in_data),
        .s_keep  (data_in_keep[PARALLEL_INPUTS-1:0]),
        .s_last  (data_in_last),
        .m_valid (pix_valid),
        .m_ready (pix_buf_ready),
        .m_data  (pix_data),
        .m_last  (pix_last)
    );

    assign data_in_ready = cfg_done_r_q & pix_ready;

    bnn_input_buffer #(
        .WIDTH (PARALLEL_INPUTS),
        .DEPTH (4)
    ) u_img_buf (
        .clk     (clk),
        .rst     (rst),
        .s_valid (pix_valid),
        .s_data  (pix_data),
        .s_last  (pix_last),
        .s_ready (pix_buf_ready),
        .m_valid (pix_buf_valid),
        .m_data  (pix_buf_data),
        .m_last  (pix_buf_last),
        .m_ready (layer_in_ready[0]),
        .count   ()
    );

    assign layer_in_valid[0] = pix_buf_valid;
    assign layer_in_data [0] = {{(MAX_STREAM_W-PARALLEL_INPUTS){1'b0}}, pix_buf_data};
    assign layer_in_last [0] = pix_buf_last;

    // -------------------------------------------------------------------------
    // layer start policy: one level-sensitive signal to every layer.
    // No per-layer derived start registers are permitted.
    // -------------------------------------------------------------------------
    logic [NLY-1:0] layer_start;
    logic [NLY-1:0] layer_busy;
    logic [NLY-1:0] layer_done;
    logic [NLY-1:0] layer_s_ready;

    genvar gs;
    generate
        for (gs = 0; gs < NLY; gs++) begin : g_start
            assign layer_start[gs] = cfg_done_r_q;
            assign layer_in_ready[gs] = layer_s_ready[gs];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Inter-layer buffers. There is one buffer between each pair of adjacent
    // layer engines. The output layer has no hidden-output buffer.
    // -------------------------------------------------------------------------
    genvar gb;
    generate
        for (gb = 0; gb < (NLY > 1 ? NLY-1 : 0); gb++) begin : g_interbuf
            localparam int BUF_W = PARALLEL_NEURONS[gb];
            logic [BUF_W-1:0] inter_data;

            bnn_input_buffer #(
                .WIDTH (BUF_W),
                .DEPTH (4)
            ) u_interlayer_buf (
                .clk     (clk),
                .rst     (rst),
                .s_valid (hidden_valid[gb]),
                .s_data  (hidden_data[gb][BUF_W-1:0]),
                .s_last  (hidden_last[gb]),
                .s_ready (hidden_ready[gb]),
                .m_valid (layer_in_valid[gb+1]),
                .m_data  (inter_data),
                .m_last  (layer_in_last[gb+1]),
                .m_ready (layer_in_ready[gb+1]),
                .count   ()
            );

            assign layer_in_data[gb+1] = {{(MAX_STREAM_W-BUF_W){1'b0}}, inter_data};
        end
    endgenerate

    // Unused hidden output of the final layer is always ready/ignored.
    assign hidden_ready[NLY-1] = 1'b1;

    // -------------------------------------------------------------------------
    // Layer engines.
    // This generate loop is depth-parametric. Each instance derives its local
    // P_W/P_N/FAN_IN/NUM_NEURONS from the public arrays.
    // -------------------------------------------------------------------------
    logic                            score_valid;
    logic                            score_ready;
    logic [NUM_CLASSES*ACC_W-1:0]    score_data;
    logic                            score_last;

    genvar gl;
    generate
        for (gl = 0; gl < NLY; gl++) begin : g_layer
            localparam int PW_I       = (gl == 0) ? PARALLEL_INPUTS : PARALLEL_NEURONS[gl-1];
            localparam int PN_I       = PARALLEL_NEURONS[gl];
            localparam int NEXT_PW_I  = (gl < NLY-1) ? PARALLEL_NEURONS[gl] : 1;
            localparam int FAN_IN_I   = TOPOLOGY[gl];
            localparam int NUM_NEU_I  = TOPOLOGY[gl+1];
            localparam bit IS_OUT_I   = (gl == NLY-1);

            logic [NEXT_PW_I-1:0] m_data_i;
            logic                 m_valid_i;
            logic                 m_last_i;
            logic [NUM_NEU_I*ACC_W-1:0] score_data_i;
            logic                 score_valid_i;
            logic                 score_last_i;

            bnn_layer_engine #(
                .LAYER_IDX       (gl),
                .FAN_IN          (FAN_IN_I),
                .NUM_NEURONS     (NUM_NEU_I),
                .P_W             (PW_I),
                .P_N             (PN_I),
                .NEXT_P_W        (NEXT_PW_I),
                .ACC_W           (ACC_W),
                .IS_OUTPUT_LAYER (IS_OUT_I),
                .LID_W           (LID_W),
                .FANOUT_STAGES   (FANOUT_STAGES)
            ) u_layer (
                .clk            (clk),
                .rst            (rst),
                .start          (layer_start[gl]),
                .busy           (layer_busy[gl]),
                .done           (layer_done[gl]),
                .s_valid        (layer_in_valid[gl]),
                .s_ready        (layer_s_ready[gl]),
                .s_data         (layer_in_data[gl][PW_I-1:0]),
                .s_last         (layer_in_last[gl]),
                .m_valid        (m_valid_i),
                .m_ready        (IS_OUT_I ? 1'b1 : hidden_ready[gl]),
                .m_data         (m_data_i),
                .m_last         (m_last_i),
                .score_valid    (score_valid_i),
                .score_ready    (IS_OUT_I ? score_ready : 1'b1),
                .score_data     (score_data_i),
                .score_last     (score_last_i),
                .cfg_wr_valid   (cfg_wr_valid[gl]),
                .cfg_wr_ready   (cfg_wr_ready[gl]),
                .cfg_wr_layer   (cfg_wr_layer[gl]),
                .cfg_wr_np      (cfg_wr_np[gl]),
                .cfg_wr_addr    (cfg_wr_addr[gl]),
                .cfg_wr_data    (cfg_wr_data[gl][PW_I-1:0]),
                .cfg_thr_valid  (cfg_thr_valid[gl]),
                .cfg_thr_ready  (cfg_thr_ready[gl]),
                .cfg_thr_layer  (cfg_thr_layer[gl]),
                .cfg_thr_np     (cfg_thr_np[gl]),
                .cfg_thr_addr   (cfg_thr_addr[gl]),
                .cfg_thr_data   (cfg_thr_data[gl])
            );

            if (gl < NLY-1) begin : g_hidden_outputs
                assign hidden_valid[gl] = m_valid_i;
                assign hidden_data [gl] = {{(MAX_STREAM_W-NEXT_PW_I){1'b0}}, m_data_i};
                assign hidden_last [gl] = m_last_i;
            end

            if (gl == NLY-1) begin : g_score_outputs
                assign score_valid = score_valid_i;
                assign score_data  = score_data_i;
                assign score_last  = score_last_i;
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Argmax + top-level AXI output register.
    // This is the only producer-facing top-level register. It enforces AXI
    // valid/data/last/keep persistence under data_out_ready backpressure.
    // -------------------------------------------------------------------------
    logic                 arg_valid;
    logic                 arg_ready;
    logic [ARG_IDX_W-1:0] arg_idx;
    logic                 arg_last;

    bnn_argmax #(
        .NUM_CLASSES (NUM_CLASSES),
        .ACC_W       (ACC_W)
    ) u_argmax (
        .clk      (clk),
        .rst      (rst),
        .s_valid  (score_valid),
        .s_ready  (score_ready),
        .s_scores (score_data),
        .s_last   (score_last),
        .m_valid  (arg_valid),
        .m_ready  (arg_ready),
        .m_idx    (arg_idx),
        .m_last   (arg_last)
    );

    assign arg_ready = !data_out_valid || data_out_ready;

    always_ff @(posedge clk) begin
        if (arg_ready) begin
            data_out_valid <= arg_valid;
            data_out_data  <= {{(OUTPUT_BUS_WIDTH-OUTPUT_DATA_WIDTH){1'b0}},
                               OUTPUT_DATA_WIDTH'(arg_idx)};
            data_out_keep  <= {{(OUTPUT_BUS_WIDTH/8-1){1'b0}}, 1'b1};
            data_out_last  <= arg_last;
        end

        if (rst) begin
            data_out_valid <= 1'b0;
            data_out_data  <= '0;
            data_out_keep  <= '0;
            data_out_last  <= 1'b0;
        end
    end

    initial begin
        assert (TOTAL_LAYERS >= 2)
            else $fatal(1, "bnn_fcc: TOTAL_LAYERS must be >= 2");
        assert (INPUT_DATA_WIDTH == 8)
            else $fatal(1, "bnn_fcc: INPUT_DATA_WIDTH must be 8");
        assert ((INPUT_BUS_WIDTH / INPUT_DATA_WIDTH) == PARALLEL_INPUTS)
            else $fatal(1, "bnn_fcc: M6 requires INPUT_BUS_WIDTH/INPUT_DATA_WIDTH (%0d) == PARALLEL_INPUTS (%0d)",
                        INPUT_BUS_WIDTH / INPUT_DATA_WIDTH, PARALLEL_INPUTS);
        assert (PARALLEL_INPUTS == PARALLEL_NEURONS[0])
            else $fatal(1, "bnn_fcc: PARALLEL_INPUTS (%0d) must equal PARALLEL_NEURONS[0] (%0d)",
                        PARALLEL_INPUTS, PARALLEL_NEURONS[0]);
        assert (OUTPUT_BUS_WIDTH >= OUTPUT_DATA_WIDTH)
            else $fatal(1, "bnn_fcc: OUTPUT_BUS_WIDTH must cover OUTPUT_DATA_WIDTH");
        assert (NUM_CLASSES <= (1 << OUTPUT_DATA_WIDTH))
            else $fatal(1, "bnn_fcc: NUM_CLASSES=%0d exceeds OUTPUT_DATA_WIDTH=%0d",
                        NUM_CLASSES, OUTPUT_DATA_WIDTH);
        assert (PARALLEL_INPUTS <= MAX_STREAM_W)
            else $fatal(1, "bnn_fcc: PARALLEL_INPUTS exceeds MAX_STREAM_W");
        foreach (PARALLEL_NEURONS[i]) begin
            assert (PARALLEL_NEURONS[i] <= MAX_STREAM_W)
                else $fatal(1, "bnn_fcc: PARALLEL_NEURONS[%0d] exceeds MAX_STREAM_W", i);
        end
        $display("bnn_fcc: TOTAL_LAYERS=%0d NLY=%0d INPUT_P=%0d NUM_CLASSES=%0d ACC_W=%0d",
                 TOTAL_LAYERS, NLY, PARALLEL_INPUTS, NUM_CLASSES, ACC_W);
    end

endmodule
