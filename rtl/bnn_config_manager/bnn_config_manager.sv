`timescale 1ns/10ps

module bnn_config_manager #(
    parameter int CONFIG_BUS_WIDTH       = 64,
    parameter int TOTAL_LAYERS           = 4,
    parameter int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0},
    parameter int PARALLEL_INPUTS        = 8,
    parameter int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{default: 8},
    parameter int ACC_W                  = 10,
    parameter int MAX_PW                 = 16,
    localparam int NLY                   = TOTAL_LAYERS - 1,
    localparam int LID_W                 = (NLY > 1) ? $clog2(NLY) : 1,
    localparam int NPID_W                = 8,
    localparam int ADDR_W                = 16
) (
    input  logic                            clk,
    input  logic                            rst,

    input  logic                            config_valid,
    output logic                            config_ready,
    input  logic [CONFIG_BUS_WIDTH-1:0]     config_data,
    input  logic [CONFIG_BUS_WIDTH/8-1:0]   config_keep,
    input  logic                            config_last,

    output logic [NLY-1:0]                  cfg_wr_valid,
    input  logic [NLY-1:0]                  cfg_wr_ready,
    output logic [NLY-1:0][LID_W-1:0]       cfg_wr_layer,
    output logic [NLY-1:0][NPID_W-1:0]      cfg_wr_np,
    output logic [NLY-1:0][ADDR_W-1:0]      cfg_wr_addr,
    output logic [NLY-1:0][MAX_PW-1:0]      cfg_wr_data,
    output logic [NLY-1:0]                  cfg_wr_last_word,
    output logic [NLY-1:0]                  cfg_wr_last_neuron,
    output logic [NLY-1:0]                  cfg_wr_last_msg,

    output logic [NLY-1:0]                  cfg_thr_valid,
    input  logic [NLY-1:0]                  cfg_thr_ready,
    output logic [NLY-1:0][LID_W-1:0]       cfg_thr_layer,
    output logic [NLY-1:0][NPID_W-1:0]      cfg_thr_np,
    output logic [NLY-1:0][ADDR_W-1:0]      cfg_thr_addr,
    output logic [NLY-1:0][31:0]            cfg_thr_data,

    output logic                            cfg_done,
    output logic                            cfg_error,
    output logic [15:0]                     cfg_extra_t2_count
);

    import bnn_cfg_mgr_pkg::*;

    // Elaboration helpers 
    function automatic int layer_pw_local(input int idx);
        return bnn_cfg_mgr_pkg::layer_pw_fn(PARALLEL_INPUTS, PARALLEL_NEURONS, idx);
    endfunction

    function automatic int layer_pn_local(input int idx);
        return bnn_cfg_mgr_pkg::layer_pn_fn(PARALLEL_NEURONS, idx);
    endfunction

    // M7 byte-filter boundary
    logic        m7_valid;
    logic        m7_ready;
    logic [7:0]  m7_data;
    logic        m7_last;

    bnn_byte_filter #(
        .BUS_WIDTH (CONFIG_BUS_WIDTH)
    ) u_m7 (
        .clk     (clk),
        .rst     (rst),
        .s_valid (config_valid),
        .s_ready (config_ready),
        .s_data  (config_data),
        .s_keep  (config_keep),
        .s_last  (config_last),
        .m_valid (m7_valid),
        .m_ready (m7_ready),
        .m_data  (m7_data),
        .m_last  (m7_last)
    );

    //  M8 header parser / payload router front-end 
    logic        hdr_valid;
    logic [7:0]  hdr_msg_type;
    logic [7:0]  hdr_layer_id;
    logic [15:0] hdr_layer_inputs;
    logic [15:0] hdr_num_neurons;
    logic [15:0] hdr_bytes_per_neuron;
    logic [31:0] hdr_total_bytes;
    logic        payload_valid;
    logic        payload_ready;
    logic [7:0]  payload_data;
    logic        payload_last_byte;
    logic        msg_done;

    bnn_cfg_header_parser u_m8 (
        .clk                 (clk),
        .rst                 (rst),
        .byte_valid          (m7_valid),
        .byte_ready          (m7_ready),
        .byte_data           (m7_data),
        .byte_last           (m7_last),
        .hdr_valid           (hdr_valid),
        .hdr_msg_type        (hdr_msg_type),
        .hdr_layer_id        (hdr_layer_id),
        .hdr_layer_inputs    (hdr_layer_inputs),
        .hdr_num_neurons     (hdr_num_neurons),
        .hdr_bytes_per_neuron(hdr_bytes_per_neuron),
        .hdr_total_bytes     (hdr_total_bytes),
        .payload_valid       (payload_valid),
        .payload_ready       (payload_ready),
        .payload_data        (payload_data),
        .payload_last_byte   (payload_last_byte),
        .msg_done            (msg_done)
    );

    //  Header capture / accounting state 
    logic [7:0]       cur_msg_type_r_q;
    logic [LID_W-1:0] cur_layer_id_r_q;
    logic [15:0]      cur_fan_in_r_q;
    logic [15:0]      cur_nneur_r_q;
    logic [15:0]      cur_bpn_r_q;
    logic [31:0]      cur_total_bytes_r_q;
    logic             cur_msg_error_r_q;

    logic             eos_seen_r_q;
    logic             msg_done_seen_r_q;
    logic             cfg_done_r_q;
    logic             cfg_done_pending_r_q;
    logic [4:0]       cfg_done_drain_r_q;
    logic             cfg_error_r_q;
    logic [15:0]      cfg_extra_t2_count_r_q;
    dbg_eos_strategy_t dbg_eos_strategy_r_q;

    // Threshold address bridge: M9 emits pure words, wrapper derives np/addr.
    logic [15:0] thr_neuron_idx_r_q;

    //  Live header classification 
    logic             hdr_layer_in_range;
    logic             hdr_bad_bpn0;
    logic             hdr_bad_nneur0;
    logic             hdr_bad_total_bytes;
    logic             hdr_extra_t2;
    logic             hdr_is_error;
    dbg_error_class_t dbg_error_class;

    assign hdr_layer_in_range = (hdr_layer_id < NLY);
    assign hdr_bad_bpn0       = (hdr_msg_type == 8'h00) &&
                                (hdr_bytes_per_neuron == 16'd0) &&
                                (hdr_num_neurons != 16'd0);
    assign hdr_bad_nneur0     = (hdr_num_neurons == 16'd0);
    assign hdr_bad_total_bytes= (hdr_msg_type == 8'h00) &&
                                (hdr_total_bytes !=
                                 (32'(hdr_bytes_per_neuron) * 32'(hdr_num_neurons)));
    assign hdr_extra_t2       = (hdr_msg_type == 8'h01) &&
                                hdr_layer_in_range &&
                                (hdr_layer_id == 8'(NLY - 1));

    always_comb begin
        dbg_error_class = CFG_ERR_NONE;
        if (hdr_msg_type > 8'h01)
            dbg_error_class = CFG_ERR_BAD_MSGTYPE;
        else if (!hdr_layer_in_range)
            dbg_error_class = CFG_ERR_BAD_LAYERID;
        else if (hdr_bad_bpn0)
            dbg_error_class = CFG_ERR_BAD_BPN0;
        else if (hdr_bad_nneur0)
            dbg_error_class = CFG_ERR_BAD_NNEUR0;
        else if (hdr_bad_total_bytes)
            dbg_error_class = CFG_ERR_BAD_TOTALBYTES;
        else if (hdr_extra_t2)
            dbg_error_class = CFG_ERR_EXTRA_T2;
    end

    assign hdr_is_error = (dbg_error_class != CFG_ERR_NONE) &&
                          (dbg_error_class != CFG_ERR_EXTRA_T2);

    // Use live header fields on cfg_load cycles; current-message registers own
    // the payload-routing phase that follows.
    logic [15:0]      route_fan_in_w;
    logic [15:0]      route_nneur_w;
    logic [15:0]      route_bpn_w;
    logic [LID_W-1:0] route_layer_id_w;

    assign route_fan_in_w   = hdr_valid ? hdr_layer_inputs : cur_fan_in_r_q;
    assign route_nneur_w    = hdr_valid ? hdr_num_neurons : cur_nneur_r_q;
    assign route_bpn_w      = hdr_valid ? hdr_bytes_per_neuron : cur_bpn_r_q;
    assign route_layer_id_w = hdr_valid ? LID_W'(hdr_layer_id) : cur_layer_id_r_q;

    // Q6 in the reference text mixes level semantics with an edge-ordering
    // shortcut. Implement the stricter "both events observed" behavior so the
    // wrapper tolerates EOS arriving on the final beat or in a late trailer.
    logic eos_seen_event;
    logic final_cfg_seen;
    logic dispatch_idle;
    assign eos_seen_event = config_valid && config_ready && config_last;
    assign final_cfg_seen = (msg_done && (eos_seen_r_q || eos_seen_event)) ||
                            (eos_seen_event && msg_done_seen_r_q);

    // Accounting + current-message capture block. Required because the wrapper
    // owns sticky status, late-EOS handling, and header-to-payload routing.
    always_ff @(posedge clk) begin
        if (hdr_valid) begin
            cur_msg_type_r_q   <= hdr_msg_type;
            cur_layer_id_r_q   <= LID_W'(hdr_layer_id);
            cur_fan_in_r_q     <= hdr_layer_inputs;
            cur_nneur_r_q      <= hdr_num_neurons;
            cur_bpn_r_q        <= hdr_bytes_per_neuron;
            cur_total_bytes_r_q<= hdr_total_bytes;
            cur_msg_error_r_q  <= hdr_is_error;

            if (dbg_error_class == CFG_ERR_EXTRA_T2)
                cfg_extra_t2_count_r_q <= bnn_cfg_mgr_pkg::sat_inc16(cfg_extra_t2_count_r_q);

            if (hdr_is_error)
                cfg_error_r_q <= 1'b1;
        end

        if (msg_done)
            msg_done_seen_r_q <= 1'b1;

        if (eos_seen_event)
            eos_seen_r_q <= 1'b1;

        if (!cfg_done_r_q) begin
            if (final_cfg_seen) begin
                cfg_done_pending_r_q <= 1'b1;
                cfg_done_drain_r_q   <= 5'd16;
                if (msg_done && (eos_seen_r_q || eos_seen_event))
                    dbg_eos_strategy_r_q <= EOS_LAST_BEAT;
                else
                    dbg_eos_strategy_r_q <= EOS_AFTER_TRAILER;
            end else if (cfg_done_pending_r_q) begin
                if (cfg_done_drain_r_q != 5'd0) begin
                    cfg_done_drain_r_q <= cfg_done_drain_r_q - 5'd1;
                end else if (dispatch_idle) begin
                    cfg_done_r_q         <= 1'b1;
                    cfg_done_pending_r_q <= 1'b0;
                end
            end
        end

        if (rst) begin
            cur_msg_type_r_q        <= '0;
            cur_layer_id_r_q        <= '0;
            cur_fan_in_r_q          <= '0;
            cur_nneur_r_q           <= '0;
            cur_bpn_r_q             <= '0;
            cur_total_bytes_r_q     <= '0;
            cur_msg_error_r_q       <= 1'b0;
            eos_seen_r_q            <= 1'b0;
            msg_done_seen_r_q       <= 1'b0;
            cfg_done_r_q            <= 1'b0;
            cfg_done_pending_r_q    <= 1'b0;
            cfg_done_drain_r_q      <= '0;
            cfg_error_r_q           <= 1'b0;
            cfg_extra_t2_count_r_q  <= '0;
            dbg_eos_strategy_r_q    <= EOS_LAST_BEAT;
        end
    end

    assign cfg_done           = cfg_done_r_q;
    assign cfg_error          = cfg_error_r_q;
    assign cfg_extra_t2_count = cfg_extra_t2_count_r_q;

    //  Weight-path fanout (M10 per non-input layer) 
    logic [NLY-1:0]                  cfg_load_w;
    logic [NLY-1:0]                  route_to_w;
    logic [NLY-1:0]                  m10_byte_ready_w;
    logic [NLY-1:0]                  m10_wr_valid_w;
    logic [NLY-1:0][LID_W-1:0]       m10_wr_layer_w;
    logic [NLY-1:0][NPID_W-1:0]      m10_wr_np_w;
    logic [NLY-1:0][ADDR_W-1:0]      m10_wr_addr_w;
    logic [NLY-1:0][MAX_PW-1:0]      m10_wr_data_pad_w;
    logic [NLY-1:0]                  m10_wr_last_word_w;
    logic [NLY-1:0]                  m10_wr_last_neuron_w;
    logic [NLY-1:0]                  m10_wr_last_msg_w;

    genvar gi;
    generate
        for (gi = 0; gi < NLY; gi++) begin : g_m10
            localparam int THIS_P_W = (gi == 0) ? PARALLEL_INPUTS : PARALLEL_NEURONS[gi-1];
            localparam int THIS_P_N = PARALLEL_NEURONS[gi];

            logic [THIS_P_W-1:0] m10_wr_data_i;

            assign cfg_load_w[gi] = hdr_valid &&
                                    !hdr_is_error &&
                                    (hdr_msg_type == 8'h00) &&
                                    (hdr_layer_id == 8'(gi));
            assign route_to_w[gi] = payload_valid &&
                                    !cur_msg_error_r_q &&
                                    (cur_msg_type_r_q == 8'h00) &&
                                    (cur_layer_id_r_q == gi[LID_W-1:0]);

            bnn_weight_unpacker #(
                .P_W    (THIS_P_W),
                .P_N    (THIS_P_N),
                .LID_W  (LID_W),
                .NPID_W (NPID_W),
                .ADDR_W (ADDR_W)
            ) u_m10 (
                .clk                (clk),
                .rst                (rst),
                .cfg_fan_in         (route_fan_in_w),
                .cfg_bytes_per_neuron(route_bpn_w),
                .cfg_num_neurons    (route_nneur_w),
                .cfg_layer_id       (route_layer_id_w),
                .cfg_load           (cfg_load_w[gi]),
                .byte_valid         (route_to_w[gi]),
                .byte_ready         (m10_byte_ready_w[gi]),
                .byte_data          (payload_data),
                .wr_valid           (m10_wr_valid_w[gi]),
                .wr_ready           (~cfg_wr_valid[gi] || cfg_wr_ready[gi]),
                .wr_layer           (m10_wr_layer_w[gi]),
                .wr_np              (m10_wr_np_w[gi]),
                .wr_addr            (m10_wr_addr_w[gi]),
                .wr_data            (m10_wr_data_i),
                .wr_last_word       (m10_wr_last_word_w[gi]),
                .wr_last_neuron     (m10_wr_last_neuron_w[gi]),
                .wr_last_msg        (m10_wr_last_msg_w[gi])
            );

            assign m10_wr_data_pad_w[gi] = {{(MAX_PW-THIS_P_W){1'b0}}, m10_wr_data_i};
        end
    endgenerate

    // ─── Threshold path (M9 + wrapper-owned np/addr derivation) ─────────────
    logic        cfg_load_t;
    logic        route_to_t;
    logic        m9_byte_valid_w;
    logic        m9_byte_ready_w;
    logic        m9_thresh_valid_w;
    logic        m9_thresh_ready_w;
    logic [31:0] m9_thresh_data_w;

    assign cfg_load_t      = hdr_valid && !hdr_is_error && (hdr_msg_type == 8'h01);
    assign route_to_t      = payload_valid && !cur_msg_error_r_q && (cur_msg_type_r_q == 8'h01);
    assign m9_byte_valid_w = route_to_t;

    bnn_threshold_assembler u_m9 (
        .clk         (clk),
        .rst         (rst),
        .byte_valid  (m9_byte_valid_w),
        .byte_ready  (m9_byte_ready_w),
        .byte_data   (payload_data),
        .thresh_valid(m9_thresh_valid_w),
        .thresh_ready(m9_thresh_ready_w),
        .thresh_data (m9_thresh_data_w)
    );

    int cur_layer_pn_w;
    logic selected_wr_ready_w;
    logic selected_thr_slot_open_w;
    dbg_routing_state_t dbg_routing_state;

    always_comb begin
        cur_layer_pn_w          = 1;
        selected_wr_ready_w     = 1'b1;
        selected_thr_slot_open_w= 1'b1;

        for (int i = 0; i < NLY; i++) begin
            if (cur_layer_id_r_q == i[LID_W-1:0]) begin
                cur_layer_pn_w           = layer_pn_local(i);
                selected_wr_ready_w      = m10_byte_ready_w[i];
                selected_thr_slot_open_w = ~cfg_thr_valid[i] || cfg_thr_ready[i];
            end
        end

        if (!payload_valid)
            dbg_routing_state = ROUTE_IDLE;
        else if (cur_msg_error_r_q)
            dbg_routing_state = ROUTE_DISCARD;
        else if (cur_msg_type_r_q == 8'h00)
            dbg_routing_state = ROUTE_W;
        else if (cur_msg_type_r_q == 8'h01)
            dbg_routing_state = ROUTE_T;
        else
            dbg_routing_state = ROUTE_DISCARD;
    end

    always_comb begin
        if (cur_msg_error_r_q)
            payload_ready = 1'b1;
        else if (cur_msg_type_r_q == 8'h00)
            payload_ready = selected_wr_ready_w;
        else if (cur_msg_type_r_q == 8'h01)
            payload_ready = m9_byte_ready_w;
        else
            payload_ready = 1'b1;
    end

    assign m9_thresh_ready_w = selected_thr_slot_open_w;
    assign dispatch_idle = !payload_valid &&
                           !(|m10_wr_valid_w) &&
                           !(|cfg_wr_valid) &&
                           !m9_thresh_valid_w &&
                           !(|cfg_thr_valid);

    logic [NPID_W-1:0] thr_np_w;
    logic [ADDR_W-1:0] thr_addr_w;

    always_comb begin
        if (cur_layer_pn_w <= 1) begin
            thr_np_w   = '0;
            thr_addr_w = ADDR_W'(thr_neuron_idx_r_q);
        end else begin
            thr_np_w   = NPID_W'(thr_neuron_idx_r_q % cur_layer_pn_w);
            thr_addr_w = ADDR_W'(thr_neuron_idx_r_q / cur_layer_pn_w);
        end
    end

    // Required wrapper bridge: M9 is layer-agnostic, so the wrapper owns the
    // per-threshold neuron index that maps to (np, addr).
    always_ff @(posedge clk) begin
        if (cfg_load_t) begin
            thr_neuron_idx_r_q <= '0;
        end else if (m9_thresh_valid_w && m9_thresh_ready_w) begin
            thr_neuron_idx_r_q <= thr_neuron_idx_r_q + 16'd1;
        end

        if (rst)
            thr_neuron_idx_r_q <= '0;
    end

    // Registered dispatch stage 
    // Boundary register. The slot-open ready calculations
    // above give each cfg output a 1-deep skid buffer so valid/data remain
    // stable even when the TB forces cfg_*_ready low for protocol testing.
    always_ff @(posedge clk) begin
        for (int i = 0; i < NLY; i++) begin
            if (m10_wr_valid_w[i] && (~cfg_wr_valid[i] || cfg_wr_ready[i])) begin
                cfg_wr_valid[i]       <= 1'b1;
                cfg_wr_layer[i]       <= m10_wr_layer_w[i];
                cfg_wr_np[i]          <= m10_wr_np_w[i];
                cfg_wr_addr[i]        <= m10_wr_addr_w[i];
                cfg_wr_data[i]        <= m10_wr_data_pad_w[i];
                cfg_wr_last_word[i]   <= m10_wr_last_word_w[i];
                cfg_wr_last_neuron[i] <= m10_wr_last_neuron_w[i];
                cfg_wr_last_msg[i]    <= m10_wr_last_msg_w[i];
            end else if (cfg_wr_valid[i] && cfg_wr_ready[i]) begin
                cfg_wr_valid[i] <= 1'b0;
            end

            if ((cur_layer_id_r_q == i[LID_W-1:0]) &&
                m9_thresh_valid_w &&
                (~cfg_thr_valid[i] || cfg_thr_ready[i])) begin
                cfg_thr_valid[i] <= 1'b1;
                cfg_thr_layer[i] <= cur_layer_id_r_q;
                cfg_thr_np[i]    <= thr_np_w;
                cfg_thr_addr[i]  <= thr_addr_w;
                cfg_thr_data[i]  <= m9_thresh_data_w;
            end else if (cfg_thr_valid[i] && cfg_thr_ready[i]) begin
                cfg_thr_valid[i] <= 1'b0;
            end
        end

        if (rst) begin
            cfg_wr_valid  <= '0;
            cfg_thr_valid <= '0;
        end
    end

    // assertions 
    property p_cfg_error_sticky;
        @(posedge clk) disable iff (rst)
        cfg_error |=> cfg_error;
    endproperty
    a_cfg_error_sticky: assert property (p_cfg_error_sticky)
        else $error("bnn_config_manager: cfg_error deasserted without reset");

    property p_cfg_done_stable;
        @(posedge clk) disable iff (rst)
        cfg_done |=> cfg_done;
    endproperty
    a_cfg_done_stable: assert property (p_cfg_done_stable)
        else $error("bnn_config_manager: cfg_done deasserted without reset");

    property p_hdr_capture_only_on_valid;
        @(posedge clk) disable iff (rst)
        !hdr_valid |=> $stable(cur_msg_type_r_q) &&
                       $stable(cur_layer_id_r_q) &&
                       $stable(cur_fan_in_r_q) &&
                       $stable(cur_nneur_r_q) &&
                       $stable(cur_bpn_r_q) &&
                       $stable(cur_total_bytes_r_q) &&
                       $stable(cur_msg_error_r_q);
    endproperty
    a_hdr_capture_only_on_valid: assert property (p_hdr_capture_only_on_valid)
        else $error("bnn_config_manager: current-message registers changed without hdr_valid");

    initial begin
        assert (TOTAL_LAYERS >= 2)
            else $fatal(1, "bnn_config_manager: TOTAL_LAYERS must be >= 2");
        assert ((CONFIG_BUS_WIDTH % 8) == 0)
            else $fatal(1, "bnn_config_manager: CONFIG_BUS_WIDTH must be byte-aligned");
        assert (PARALLEL_INPUTS >= 1)
            else $fatal(1, "bnn_config_manager: PARALLEL_INPUTS must be >= 1");
        assert (PARALLEL_INPUTS <= MAX_PW)
            else $fatal(1, "bnn_config_manager: PARALLEL_INPUTS=%0d exceeds MAX_PW=%0d",
                        PARALLEL_INPUTS, MAX_PW);
        foreach (PARALLEL_NEURONS[i]) begin
            assert (PARALLEL_NEURONS[i] >= 1)
                else $fatal(1, "bnn_config_manager: PARALLEL_NEURONS[%0d] must be >= 1", i);
            if (i < (TOTAL_LAYERS - 2)) begin
                assert (PARALLEL_NEURONS[i] <= MAX_PW)
                    else $fatal(1, "bnn_config_manager: PARALLEL_NEURONS[%0d]=%0d exceeds MAX_PW=%0d",
                                i, PARALLEL_NEURONS[i], MAX_PW);
            end
        end
        $display("bnn_config_manager: BUS=%0d TOTAL_LAYERS=%0d MAX_PW=%0d",
                 CONFIG_BUS_WIDTH, TOTAL_LAYERS, MAX_PW);
    end

endmodule
