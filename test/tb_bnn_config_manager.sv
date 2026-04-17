`timescale 1ns/10ps

`ifndef CFGM_SW01
`ifndef CFGM_SW02
`ifndef CFGM_SW03
`ifndef CFGM_SW04
`ifndef CFGM_SW05
`ifndef CFGM_SW06
`ifndef CFGM_SW07
`ifndef CFGM_SW08
`ifndef CFGM_SW09
`ifndef CFGM_SW10
`ifndef CFGM_SW11
`ifndef CFGM_SW12
`define CFGM_SW01
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif

module tb_bnn_config_manager;

    import bnn_cfg_mgr_pkg::*;

`ifdef CFGM_SW01
    localparam string SWEEP_NAME = "SW01_sfc64";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:8, 2:10, default:1};
`elsif CFGM_SW02
    localparam string SWEEP_NAME = "SW02_sfc32";
    localparam int CONFIG_BUS_WIDTH = 32;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:8, 2:10, default:1};
`elsif CFGM_SW03
    localparam string SWEEP_NAME = "SW03_sfc16";
    localparam int CONFIG_BUS_WIDTH = 16;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:8, 2:10, default:1};
`elsif CFGM_SW04
    localparam string SWEEP_NAME = "SW04_sfc8";
    localparam int CONFIG_BUS_WIDTH = 8;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:8, 2:10, default:1};
`elsif CFGM_SW05
    localparam string SWEEP_NAME = "SW05_sfc_pw16";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 16;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:16, 1:16, 2:10, default:1};
`elsif CFGM_SW06
    localparam string SWEEP_NAME = "SW06_sfc_pw4";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 4;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:4, 1:4, 2:10, default:1};
`elsif CFGM_SW07
    localparam string SWEEP_NAME = "SW07_mixed_4_8_16";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 4;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:16, 2:10, default:1};
`elsif CFGM_SW08
    localparam string SWEEP_NAME = "SW08_mixed_16_8_4";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:256, 2:256, 3:10, default:0};
    localparam int PARALLEL_INPUTS = 16;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:4, 2:10, default:1};
`elsif CFGM_SW09
    localparam string SWEEP_NAME = "SW09_odd_17_7_1";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 3;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:17, 1:7, 2:1, default:0};
    localparam int PARALLEL_INPUTS = 4;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:4, 1:1, default:1};
`elsif CFGM_SW10
    localparam string SWEEP_NAME = "SW10_min_8_1";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 2;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:8, 1:1, default:0};
    localparam int PARALLEL_INPUTS = 4;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:1, default:1};
`elsif CFGM_SW11
    localparam string SWEEP_NAME = "SW11_small_output";
    localparam int CONFIG_BUS_WIDTH = 64;
    localparam int TOTAL_LAYERS = 4;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:784, 1:16, 2:8, 3:2, default:0};
    localparam int PARALLEL_INPUTS = 8;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:8, 1:8, 2:2, default:1};
`elsif CFGM_SW12
    localparam string SWEEP_NAME = "SW12_odd32";
    localparam int CONFIG_BUS_WIDTH = 32;
    localparam int TOTAL_LAYERS = 3;
    localparam int TOPOLOGY[TOTAL_LAYERS] = '{0:13, 1:5, 2:3, default:0};
    localparam int PARALLEL_INPUTS = 4;
    localparam int PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{0:4, 1:3, default:1};
`else
    initial $fatal(1, "tb_bnn_config_manager: unknown CFGM_SWxx profile");
`endif

    localparam int NLY      = TOTAL_LAYERS - 1;
    localparam int LID_W    = (NLY > 1) ? $clog2(NLY) : 1;
    localparam int NPID_W   = 8;
    localparam int ADDR_W   = 16;
    localparam int MAX_PW   = 16;
    localparam int ACC_W    = 10;
    localparam int BUS_BYTES= CONFIG_BUS_WIDTH / 8;
    localparam int CLK_PERIOD = 10;

    typedef struct packed {
        logic [CONFIG_BUS_WIDTH-1:0]   data;
        logic [BUS_BYTES-1:0]          keep;
        logic                          last;
    } axi_beat_t;

    typedef struct {
        bit                           is_thr;
        int                           layer;
        int                           np;
        int                           addr;
        logic [MAX_PW-1:0]            data;
        logic [31:0]                  thr_data;
        bit                           last_word;
        bit                           last_neuron;
        bit                           last_msg;
    } write_txn_t;

    class cfg_msg_item;
        string               name;
        bit [7:0]            msg_type;
        bit [7:0]            layer_id;
        bit [15:0]           layer_inputs;
        bit [15:0]           num_neurons;
        bit [15:0]           bytes_per_neuron;
        bit [31:0]           total_bytes;
        byte unsigned        payload[$];

        function new(string name_i = "");
            name = name_i;
            msg_type = '0;
            layer_id = '0;
            layer_inputs = '0;
            num_neurons = '0;
            bytes_per_neuron = '0;
            total_bytes = '0;
            payload = {};
        endfunction
    endclass

    class cfg_program_item;
        string               name;
        cfg_msg_item         msgs[$];
        write_txn_t          expected[$];
        dbg_eos_strategy_t   eos_strategy;
        int                  valid_prob_pct;
        int                  keep_hole_prob_pct;
        bit                  force_ready_stalls;
        bit                  expect_error;
        int                  expected_extra_t2_count;

        function new(string name_i = "");
            name = name_i;
            eos_strategy = EOS_LAST_BEAT;
            valid_prob_pct = 100;
            keep_hole_prob_pct = 0;
            force_ready_stalls = 1'b0;
            expect_error = 1'b0;
            expected_extra_t2_count = 0;
        endfunction
    endclass

    // ─── Clock / DUT I/O ────────────────────────────────────────────────────
    logic clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic                          rst = 1'b1;
    logic                          config_valid = 1'b0;
    logic                          config_ready;
    logic [CONFIG_BUS_WIDTH-1:0]   config_data = '0;
    logic [BUS_BYTES-1:0]          config_keep = '0;
    logic                          config_last = 1'b0;

    logic [NLY-1:0]                cfg_wr_valid;
    logic [NLY-1:0]                cfg_wr_ready = '1;
    logic [NLY-1:0][LID_W-1:0]     cfg_wr_layer;
    logic [NLY-1:0][NPID_W-1:0]    cfg_wr_np;
    logic [NLY-1:0][ADDR_W-1:0]    cfg_wr_addr;
    logic [NLY-1:0][MAX_PW-1:0]    cfg_wr_data;
    logic [NLY-1:0]                cfg_wr_last_word;
    logic [NLY-1:0]                cfg_wr_last_neuron;
    logic [NLY-1:0]                cfg_wr_last_msg;

    logic [NLY-1:0]                cfg_thr_valid;
    logic [NLY-1:0]                cfg_thr_ready = '1;
    logic [NLY-1:0][LID_W-1:0]     cfg_thr_layer;
    logic [NLY-1:0][NPID_W-1:0]    cfg_thr_np;
    logic [NLY-1:0][ADDR_W-1:0]    cfg_thr_addr;
    logic [NLY-1:0][31:0]          cfg_thr_data;

    logic                          cfg_done;
    logic                          cfg_error;
    logic [15:0]                   cfg_extra_t2_count;
    logic                          cfg_done_d = 1'b0;

    bnn_config_manager #(
        .CONFIG_BUS_WIDTH (CONFIG_BUS_WIDTH),
        .TOTAL_LAYERS     (TOTAL_LAYERS),
        .TOPOLOGY         (TOPOLOGY),
        .PARALLEL_INPUTS  (PARALLEL_INPUTS),
        .PARALLEL_NEURONS (PARALLEL_NEURONS),
        .ACC_W            (ACC_W),
        .MAX_PW           (MAX_PW)
    ) DUT (
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
        .cfg_wr_np          (cfg_wr_np),
        .cfg_wr_addr        (cfg_wr_addr),
        .cfg_wr_data        (cfg_wr_data),
        .cfg_wr_last_word   (cfg_wr_last_word),
        .cfg_wr_last_neuron (cfg_wr_last_neuron),
        .cfg_wr_last_msg    (cfg_wr_last_msg),
        .cfg_thr_valid      (cfg_thr_valid),
        .cfg_thr_ready      (cfg_thr_ready),
        .cfg_thr_layer      (cfg_thr_layer),
        .cfg_thr_np         (cfg_thr_np),
        .cfg_thr_addr       (cfg_thr_addr),
        .cfg_thr_data       (cfg_thr_data),
        .cfg_done           (cfg_done),
        .cfg_error          (cfg_error),
        .cfg_extra_t2_count (cfg_extra_t2_count)
    );

    // ─── Scoreboard / monitor storage ───────────────────────────────────────
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    write_txn_t obs_wr_q [NLY][$];
    write_txn_t obs_thr_q[NLY][$];

    bit ready_stall_enable = 1'b0;
    int ready_prob_pct = 100;

    function automatic bit chance(input int unsigned pct);
        if (pct >= 100)
            return 1'b1;
        if (pct == 0)
            return 1'b0;
        return ($urandom_range(0, 99) < pct);
    endfunction

    function automatic int layer_pw_idx(input int layer_idx);
        if (layer_idx == 0)
            return PARALLEL_INPUTS;
        return PARALLEL_NEURONS[layer_idx-1];
    endfunction

    function automatic int layer_pn_idx(input int layer_idx);
        return PARALLEL_NEURONS[layer_idx];
    endfunction

    task automatic check(input string test_name, input bit cond, input string msg = "");
        if (cond) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
            $error("[SB] %s: %s", test_name, msg);
        end
    endtask

    task automatic clear_inputs();
        config_valid <= 1'b0;
        config_data  <= '0;
        config_keep  <= '0;
        config_last  <= 1'b0;
        cfg_wr_ready <= '1;
        cfg_thr_ready<= '1;
    endtask

    task automatic clear_observed();
        for (int i = 0; i < NLY; i++) begin
            obs_wr_q[i].delete();
            obs_thr_q[i].delete();
        end
    endtask

    task automatic reset_dut();
        rst <= 1'b1;
        ready_stall_enable <= 1'b0;
        ready_prob_pct <= 100;
        clear_inputs();
        clear_observed();
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // ─── Background monitors ────────────────────────────────────────────────
    always @(posedge clk) begin
        if (!rst) begin
            for (int i = 0; i < NLY; i++) begin
                if (cfg_wr_valid[i] && cfg_wr_ready[i]) begin
                    write_txn_t txn;
                    txn = '{default:'0};
                    txn.is_thr      = 1'b0;
                    txn.layer       = i;
                    txn.np          = cfg_wr_np[i];
                    txn.addr        = cfg_wr_addr[i];
                    txn.data        = cfg_wr_data[i];
                    txn.thr_data    = '0;
                    txn.last_word   = cfg_wr_last_word[i];
                    txn.last_neuron = cfg_wr_last_neuron[i];
                    txn.last_msg    = cfg_wr_last_msg[i];
                    obs_wr_q[i].push_back(txn);
                end

                if (cfg_thr_valid[i] && cfg_thr_ready[i]) begin
                    write_txn_t txn;
                    txn = '{default:'0};
                    txn.is_thr      = 1'b1;
                    txn.layer       = i;
                    txn.np          = cfg_thr_np[i];
                    txn.addr        = cfg_thr_addr[i];
                    txn.data        = '0;
                    txn.thr_data    = cfg_thr_data[i];
                    txn.last_word   = 1'b0;
                    txn.last_neuron = 1'b0;
                    txn.last_msg    = 1'b0;
                    obs_thr_q[i].push_back(txn);
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst || !ready_stall_enable) begin
            cfg_wr_ready  <= '1;
            cfg_thr_ready <= '1;
        end else begin
            for (int i = 0; i < NLY; i++) begin
                cfg_wr_ready[i]  <= chance(ready_prob_pct);
                cfg_thr_ready[i] <= chance(ready_prob_pct);
            end
        end
    end

    always_ff @(posedge clk) begin
        cfg_done_d <= cfg_done;
        if (rst)
            cfg_done_d <= 1'b0;
    end

    // ─── Coverage ───────────────────────────────────────────────────────────
    covergroup cg_msg_shape @(posedge clk iff (DUT.hdr_valid));
        cp_msg_type: coverpoint DUT.hdr_msg_type {
            bins weights = {8'h00};
            bins thr     = {8'h01};
            bins illegal = {[8'h02:8'hFF]};
        }
        cp_layer: coverpoint DUT.hdr_layer_id {
            bins valid[] = {[0:NLY-1]};
            bins illegal = {[NLY:255]};
        }
        cp_fan_in: coverpoint DUT.hdr_layer_inputs {
            bins one      = {1};
            bins odd[]    = {7, 13, 17};
            bins sixteen  = {16};
            bins thirty2  = {32};
            bins two56    = {256};
            bins seven84  = {784};
            bins other    = default;
        }
        cp_nneur: coverpoint DUT.hdr_num_neurons {
            bins zero   = {0};
            bins one    = {1};
            bins small_n[] = {2, 3, 5, 7, 10, 16};
            bins big_n     = {256};
            bins other  = default;
        }
        cp_bpn: coverpoint DUT.hdr_bytes_per_neuron {
            bins zero = {0};
            bins one  = {1};
            bins two  = {2};
            bins four = {4};
            bins big[] = {32, 98};
            bins other = default;
        }
        cp_err: coverpoint DUT.dbg_error_class;
        cx_type_layer: cross cp_msg_type, cp_layer;
    endgroup
    cg_msg_shape cg_msg_shape_inst = new();

    covergroup cg_bus @(posedge clk iff (config_valid && config_ready));
        cp_holes: coverpoint $countones(~config_keep) {
            bins none = {0};
            bins one  = {1};
            bins few  = {[2:3]};
            bins many = {[4:BUS_BYTES-1]};
        }
        cp_last: coverpoint config_last;
        cp_bus: coverpoint CONFIG_BUS_WIDTH {
            bins w8  = {8};
            bins w16 = {16};
            bins w32 = {32};
            bins w64 = {64};
        }
        cx_holes_last: cross cp_holes, cp_last;
    endgroup
    cg_bus cg_bus_inst = new();

    covergroup cg_handshake @(posedge clk);
        cp_cfg: coverpoint {config_valid, config_ready} {
            bins idle      = {2'b00};
            bins wait_v    = {2'b10};
            bins ready_o   = {2'b01};
            bins handshake = {2'b11};
        }
        cp_payload: coverpoint {DUT.payload_valid, DUT.payload_ready} {
            bins idle      = {2'b00};
            bins wait_v    = {2'b10};
            bins ready_o   = {2'b01};
            bins handshake = {2'b11};
        }
    endgroup
    cg_handshake cg_handshake_inst = new();

    covergroup cg_error @(posedge clk iff (DUT.hdr_valid));
        cp_class: coverpoint DUT.dbg_error_class;
        cp_sticky: coverpoint DUT.cfg_error_r_q;
        cx_class_sticky: cross cp_class, cp_sticky;
    endgroup
    cg_error cg_error_inst = new();

    covergroup cg_eos @(posedge clk iff (cfg_done && !cfg_done_d));
        cp_strategy: coverpoint DUT.dbg_eos_strategy_r_q;
    endgroup
    cg_eos cg_eos_inst = new();

    covergroup cg_write @(posedge clk iff (!rst));
        cp_wr_layer: coverpoint DUT.cur_layer_id_r_q {
            bins layer[] = {[0:NLY-1]};
        }
        cp_wr_last: coverpoint cfg_wr_last_msg {
            bins none = {'0};
            bins some = default;
        }
    endgroup
    cg_write cg_write_inst = new();

    // ─── Gray-box assertions ────────────────────────────────────────────────
    property p_cfg_valid_hold;
        @(posedge clk) disable iff (rst)
        config_valid && !config_ready
        |=> config_valid &&
            $stable(config_data) &&
            $stable(config_keep) &&
            $stable(config_last);
    endproperty
    a_cfg_valid_hold: assert property (p_cfg_valid_hold)
        else $error("[SVA] config_valid dropped or payload changed under backpressure");

    property p_done_after_both_seen;
        @(posedge clk) disable iff (rst)
        $rose(cfg_done) |-> (DUT.eos_seen_r_q && DUT.msg_done_seen_r_q);
    endproperty
    a_done_after_both_seen: assert property (p_done_after_both_seen)
        else $error("[SVA] cfg_done rose before eos/msg_done were both observed");

    property p_thr_idx_in_bounds;
        @(posedge clk) disable iff (rst)
        DUT.m9_thresh_valid_w |-> (DUT.thr_neuron_idx_r_q < DUT.cur_nneur_r_q);
    endproperty
    a_thr_idx_in_bounds: assert property (p_thr_idx_in_bounds)
        else $error("[SVA] threshold neuron index exceeded current num_neurons");

    property p_discard_stays_ready;
        @(posedge clk) disable iff (rst)
        DUT.cur_msg_error_r_q && DUT.payload_valid |-> DUT.payload_ready;
    endproperty
    a_discard_stays_ready: assert property (p_discard_stays_ready)
        else $error("[SVA] payload_ready dropped during discard mode");

    // ─── Program builders ───────────────────────────────────────────────────
    task automatic append_weight_msg(
        cfg_program_item prog,
        input string name_i,
        input int layer_idx,
        input int msg_type_override = -1,
        input int layer_id_override = -1,
        input int bpn_override = -1,
        input int nneur_override = -1,
        input int total_bytes_override = -1,
        input bit append_expected = 1'b1
    );
        cfg_msg_item msg;
        int fan_in;
        int num_neurons;
        int p_w;
        int p_n;
        int bpn;
        int wpn;

        msg = new(name_i);
        fan_in      = TOPOLOGY[layer_idx];
        num_neurons = TOPOLOGY[layer_idx + 1];
        p_w         = layer_pw_idx(layer_idx);
        p_n         = layer_pn_idx(layer_idx);
        bpn         = (fan_in + 7) / 8;
        wpn         = (fan_in + p_w - 1) / p_w;

        msg.msg_type         = (msg_type_override >= 0) ? msg_type_override[7:0] : 8'h00;
        msg.layer_id         = (layer_id_override >= 0) ? layer_id_override[7:0] : layer_idx[7:0];
        msg.layer_inputs     = fan_in[15:0];
        msg.num_neurons      = 16'((nneur_override >= 0) ? nneur_override : num_neurons);
        msg.bytes_per_neuron = 16'((bpn_override >= 0) ? bpn_override : bpn);
        msg.total_bytes      = 32'((total_bytes_override >= 0) ? total_bytes_override : (bpn * num_neurons));
        msg.payload.delete();

        for (int neuron = 0; neuron < num_neurons; neuron++) begin
            bit neuron_bits[];
            neuron_bits = new[fan_in];
            for (int bit_idx = 0; bit_idx < fan_in; bit_idx++)
                neuron_bits[bit_idx] = $urandom_range(0, 1);

            for (int byte_idx = 0; byte_idx < bpn; byte_idx++) begin
                byte unsigned packed_byte;
                packed_byte = 8'h00;
                for (int bit_in_byte = 0; bit_in_byte < 8; bit_in_byte++) begin
                    int src_bit;
                    src_bit = (byte_idx * 8) + bit_in_byte;
                    if (src_bit < fan_in)
                        packed_byte[bit_in_byte] = neuron_bits[src_bit];
                    else
                        packed_byte[bit_in_byte] = 1'b1;
                end
                msg.payload.push_back(packed_byte);
            end

            if (append_expected) begin
                for (int word_idx = 0; word_idx < wpn; word_idx++) begin
                    write_txn_t txn;
                    txn = '{default:'0};
                    txn.is_thr = 1'b0;
                    txn.layer  = layer_idx;
                    txn.np     = neuron % p_n;
                    txn.addr   = ((neuron / p_n) * wpn) + word_idx;
                    txn.last_word   = (word_idx == (wpn - 1));
                    txn.last_neuron = txn.last_word && (neuron == (num_neurons - 1));
                    txn.last_msg    = txn.last_neuron;

                    for (int bit_pos = 0; bit_pos < p_w; bit_pos++) begin
                        int src_bit;
                        src_bit = (word_idx * p_w) + bit_pos;
                        if (src_bit < fan_in)
                            txn.data[bit_pos] = neuron_bits[src_bit];
                        else
                            txn.data[bit_pos] = 1'b1;
                    end
                    prog.expected.push_back(txn);
                end
            end
        end

        if (total_bytes_override >= 0) begin
            while (msg.payload.size() > total_bytes_override)
                void'(msg.payload.pop_back());
            while (msg.payload.size() < total_bytes_override)
                msg.payload.push_back($urandom());
        end

        prog.msgs.push_back(msg);
    endtask

    task automatic append_threshold_msg(
        cfg_program_item prog,
        input string name_i,
        input int layer_idx,
        input int layer_id_override = -1,
        input int nneur_override = -1,
        input int total_bytes_override = -1,
        input bit append_expected = 1'b1,
        input bit count_extra_t2 = 1'b0
    );
        cfg_msg_item msg;
        int num_neurons;
        int p_n;

        msg = new(name_i);
        num_neurons = TOPOLOGY[layer_idx + 1];
        p_n         = layer_pn_idx(layer_idx);

        msg.msg_type         = 8'h01;
        msg.layer_id         = (layer_id_override >= 0) ? layer_id_override[7:0] : layer_idx[7:0];
        msg.layer_inputs     = 16'h0000;
        msg.num_neurons      = 16'((nneur_override >= 0) ? nneur_override : num_neurons);
        msg.bytes_per_neuron = 16'd4;
        msg.total_bytes      = 32'((total_bytes_override >= 0) ? total_bytes_override : (4 * num_neurons));
        msg.payload.delete();

        for (int neuron = 0; neuron < num_neurons; neuron++) begin
            logic [31:0] thr_val;
            thr_val = 32'($urandom_range(0, (1 << ACC_W) - 1));
            msg.payload.push_back(thr_val[7:0]);
            msg.payload.push_back(thr_val[15:8]);
            msg.payload.push_back(thr_val[23:16]);
            msg.payload.push_back(thr_val[31:24]);

            if (append_expected) begin
                write_txn_t txn;
                txn = '{default:'0};
                txn.is_thr   = 1'b1;
                txn.layer    = layer_idx;
                txn.np       = neuron % p_n;
                txn.addr     = neuron / p_n;
                txn.thr_data = thr_val;
                prog.expected.push_back(txn);
            end
        end

        if (total_bytes_override >= 0) begin
            while (msg.payload.size() > total_bytes_override)
                void'(msg.payload.pop_back());
            while (msg.payload.size() < total_bytes_override)
                msg.payload.push_back($urandom());
        end

        if (count_extra_t2)
            prog.expected_extra_t2_count++;
        prog.msgs.push_back(msg);
    endtask

    task automatic build_legal_program(
        cfg_program_item prog,
        input int repeat_count = 1,
        input bit include_extra_t2 = 1'b0
    );
        for (int rep = 0; rep < repeat_count; rep++) begin
            for (int layer = 0; layer < NLY; layer++) begin
                append_weight_msg(prog, $sformatf("W%0d_rep%0d", layer, rep), layer);
                if (layer < (NLY - 1)) begin
                    append_threshold_msg(prog, $sformatf("T%0d_rep%0d", layer, rep), layer);
                end else if (include_extra_t2) begin
                    append_threshold_msg(prog,
                                         $sformatf("T%0d_extra_rep%0d", layer, rep),
                                         layer,
                                         -1, -1, -1,
                                         1'b1, 1'b1);
                end
            end
        end
    endtask

    task automatic build_bad_msg_type_program(cfg_program_item prog);
        append_weight_msg(prog, "bad_msg_type", 0, 8'h42, -1, -1, -1, 16, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    task automatic build_bad_layer_id_program(cfg_program_item prog);
        append_weight_msg(prog, "bad_layer_id", 0, -1, NLY, -1, -1, 16, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    task automatic build_bad_bpn_zero_program(cfg_program_item prog);
        append_weight_msg(prog, "bad_bpn_zero", 0, -1, -1, 0, 10, 0, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    task automatic build_bad_total_bytes_program(cfg_program_item prog);
        append_weight_msg(prog, "bad_total_bytes", 0, -1, -1, -1, -1, 15, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    task automatic build_bad_nneur_zero_program(cfg_program_item prog);
        append_threshold_msg(prog, "bad_nneur_zero", 0, -1, 0, 0, 1'b0, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    task automatic build_multiple_errors_program(cfg_program_item prog);
        append_weight_msg(prog, "bad_msg_type", 0, 8'h55, -1, -1, -1, 8, 1'b0);
        append_weight_msg(prog, "bad_layer_id", 0, -1, NLY, -1, -1, 8, 1'b0);
        append_weight_msg(prog, "bad_bpn_zero", 0, -1, -1, 0, 10, 0, 1'b0);
        build_legal_program(prog, 1, 1'b0);
        prog.expect_error = 1'b1;
    endtask

    // ─── Byte-stream / AXI packing ──────────────────────────────────────────
    task automatic build_byte_stream(
        cfg_program_item prog,
        ref byte unsigned stream[$]
    );
        stream.delete();
        foreach (prog.msgs[msg_idx]) begin
            cfg_msg_item msg;
            msg = prog.msgs[msg_idx];

            stream.push_back(msg.msg_type);
            stream.push_back(msg.layer_id);
            stream.push_back(msg.layer_inputs[7:0]);
            stream.push_back(msg.layer_inputs[15:8]);
            stream.push_back(msg.num_neurons[7:0]);
            stream.push_back(msg.num_neurons[15:8]);
            stream.push_back(msg.bytes_per_neuron[7:0]);
            stream.push_back(msg.bytes_per_neuron[15:8]);
            stream.push_back(msg.total_bytes[7:0]);
            stream.push_back(msg.total_bytes[15:8]);
            stream.push_back(msg.total_bytes[23:16]);
            stream.push_back(msg.total_bytes[31:24]);
            stream.push_back(8'h00);
            stream.push_back(8'h00);
            stream.push_back(8'h00);
            stream.push_back(8'h00);

            foreach (msg.payload[pidx])
                stream.push_back(msg.payload[pidx]);
        end
    endtask

    task automatic pack_beats(
        cfg_program_item prog,
        ref axi_beat_t beats[$]
    );
        byte unsigned stream[$];
        int byte_idx;
        beats.delete();
        build_byte_stream(prog, stream);
        byte_idx = 0;

        while (byte_idx < stream.size()) begin
            axi_beat_t beat;
            beat = '0;

            for (int lane = 0; lane < BUS_BYTES; lane++) begin
                bit use_hole;
                use_hole = 1'b0;
                if ((lane < (BUS_BYTES - 1)) &&
                    (prog.keep_hole_prob_pct > 0) &&
                    (byte_idx < stream.size()) &&
                    chance(prog.keep_hole_prob_pct)) begin
                    use_hole = 1'b1;
                end

                if (!use_hole && (byte_idx < stream.size())) begin
                    beat.keep[lane] = 1'b1;
                    beat.data[(lane*8) +: 8] = stream[byte_idx];
                    byte_idx++;
                end
            end

            if (beat.keep == '0) begin
                beat.keep[0] = 1'b1;
                beat.data[7:0] = stream[byte_idx];
                byte_idx++;
            end

            beats.push_back(beat);
        end

        if (prog.eos_strategy == EOS_LAST_BEAT) begin
            beats[beats.size()-1].last = 1'b1;
        end else begin
            axi_beat_t trailer;
            trailer = '0;
            trailer.keep[0] = 1'b1;
            trailer.data[7:0] = 8'h00;
            trailer.last = 1'b1;
            beats.push_back(trailer);
        end
    endtask

    task automatic drive_beats(
        input axi_beat_t beats[$],
        input int valid_prob_pct,
        input int reset_after_handshakes = -1
    );
        int beat_idx;
        int handshakes;
        int wait_cycles;

        beat_idx = 0;
        handshakes = 0;
        wait_cycles = 0;

        while (beat_idx < beats.size()) begin
            @(posedge clk);

            if (config_valid && config_ready) begin
                beat_idx++;
                handshakes++;
            end

            if ((reset_after_handshakes >= 0) && (handshakes == reset_after_handshakes)) begin
                config_valid <= 1'b0;
                config_data  <= '0;
                config_keep  <= '0;
                config_last  <= 1'b0;
                rst <= 1'b1;
                repeat (5) @(posedge clk);
                rst <= 1'b0;
                repeat (3) @(posedge clk);
                clear_inputs();
                clear_observed();
                return;
            end

            if (beat_idx < beats.size()) begin
                if (config_valid && !config_ready) begin
                    config_valid <= 1'b1;
                end else if (chance(valid_prob_pct)) begin
                    config_valid <= 1'b1;
                    config_data  <= beats[beat_idx].data;
                    config_keep  <= beats[beat_idx].keep;
                    config_last  <= beats[beat_idx].last;
                end else begin
                    config_valid <= 1'b0;
                    config_data  <= config_data;
                    config_keep  <= config_keep;
                    config_last  <= config_last;
                end
            end else begin
                config_valid <= 1'b0;
                config_data  <= '0;
                config_keep  <= '0;
                config_last  <= 1'b0;
            end

            wait_cycles++;
            if (wait_cycles > 2000000)
                $fatal(1, "[DRV] Timeout while driving AXI beats");
        end

        @(posedge clk);
        config_valid <= 1'b0;
        config_data  <= '0;
        config_keep  <= '0;
        config_last  <= 1'b0;
    endtask

    task automatic wait_for_done(input string test_name, input int max_cycles = 3000000);
        int cycles;
        cycles = 0;
        while (!cfg_done && (cycles < max_cycles)) begin
            @(posedge clk);
            cycles++;
        end
        check(test_name, cfg_done, "cfg_done did not assert before timeout");
    endtask

    task automatic wait_for_quiesce(input int idle_cycles = 8, input int max_cycles = 200000);
        int idle_count;
        int cycles;
        idle_count = 0;
        cycles = 0;

        while ((idle_count < idle_cycles) && (cycles < max_cycles)) begin
            @(posedge clk);
            if ((cfg_wr_valid == '0) && (cfg_thr_valid == '0))
                idle_count++;
            else
                idle_count = 0;
            cycles++;
        end
    endtask

    task automatic compare_program(input string test_name, cfg_program_item prog);
        write_txn_t exp_wr_q [NLY][$];
        write_txn_t exp_thr_q[NLY][$];

        foreach (prog.expected[idx]) begin
            if (prog.expected[idx].is_thr)
                exp_thr_q[prog.expected[idx].layer].push_back(prog.expected[idx]);
            else
                exp_wr_q[prog.expected[idx].layer].push_back(prog.expected[idx]);
        end

        for (int layer = 0; layer < NLY; layer++) begin
            check(test_name,
                  obs_wr_q[layer].size() == exp_wr_q[layer].size(),
                  $sformatf("layer%0d weight count exp=%0d got=%0d",
                            layer, exp_wr_q[layer].size(), obs_wr_q[layer].size()));

            for (int i = 0; i < ((obs_wr_q[layer].size() < exp_wr_q[layer].size()) ?
                                  obs_wr_q[layer].size() : exp_wr_q[layer].size()); i++) begin
                check(test_name,
                      obs_wr_q[layer][i].np == exp_wr_q[layer][i].np,
                      $sformatf("layer%0d weight[%0d] np exp=%0d got=%0d",
                                layer, i, exp_wr_q[layer][i].np, obs_wr_q[layer][i].np));
                check(test_name,
                      obs_wr_q[layer][i].addr == exp_wr_q[layer][i].addr,
                      $sformatf("layer%0d weight[%0d] addr exp=%0d got=%0d",
                                layer, i, exp_wr_q[layer][i].addr, obs_wr_q[layer][i].addr));
                check(test_name,
                      obs_wr_q[layer][i].data === exp_wr_q[layer][i].data,
                      $sformatf("layer%0d weight[%0d] data mismatch", layer, i));
                check(test_name,
                      obs_wr_q[layer][i].last_word == exp_wr_q[layer][i].last_word,
                      $sformatf("layer%0d weight[%0d] last_word mismatch", layer, i));
                check(test_name,
                      obs_wr_q[layer][i].last_neuron == exp_wr_q[layer][i].last_neuron,
                      $sformatf("layer%0d weight[%0d] last_neuron mismatch", layer, i));
                check(test_name,
                      obs_wr_q[layer][i].last_msg == exp_wr_q[layer][i].last_msg,
                      $sformatf("layer%0d weight[%0d] last_msg mismatch", layer, i));
            end

            check(test_name,
                  obs_thr_q[layer].size() == exp_thr_q[layer].size(),
                  $sformatf("layer%0d thr count exp=%0d got=%0d",
                            layer, exp_thr_q[layer].size(), obs_thr_q[layer].size()));

            for (int i = 0; i < ((obs_thr_q[layer].size() < exp_thr_q[layer].size()) ?
                                  obs_thr_q[layer].size() : exp_thr_q[layer].size()); i++) begin
                check(test_name,
                      obs_thr_q[layer][i].np == exp_thr_q[layer][i].np,
                      $sformatf("layer%0d thr[%0d] np exp=%0d got=%0d",
                                layer, i, exp_thr_q[layer][i].np, obs_thr_q[layer][i].np));
                check(test_name,
                      obs_thr_q[layer][i].addr == exp_thr_q[layer][i].addr,
                      $sformatf("layer%0d thr[%0d] addr exp=%0d got=%0d",
                                layer, i, exp_thr_q[layer][i].addr, obs_thr_q[layer][i].addr));
                check(test_name,
                      obs_thr_q[layer][i].thr_data === exp_thr_q[layer][i].thr_data,
                      $sformatf("layer%0d thr[%0d] data mismatch", layer, i));
            end
        end

        check(test_name,
              cfg_error == prog.expect_error,
              $sformatf("cfg_error exp=%0b got=%0b", prog.expect_error, cfg_error));
        check(test_name,
              cfg_extra_t2_count == prog.expected_extra_t2_count,
              $sformatf("cfg_extra_t2_count exp=%0d got=%0d",
                        prog.expected_extra_t2_count, cfg_extra_t2_count));
    endtask

    task automatic run_program(input string test_name, cfg_program_item prog);
        axi_beat_t beats[$];
        pack_beats(prog, beats);
        clear_observed();
        ready_stall_enable <= prog.force_ready_stalls;
        ready_prob_pct     <= prog.force_ready_stalls ? 65 : 100;
        drive_beats(beats, prog.valid_prob_pct);
        wait_for_done(test_name);
        wait_for_quiesce();
        compare_program(test_name, prog);
        ready_stall_enable <= 1'b0;
        ready_prob_pct     <= 100;
    endtask

    // ─── Named tests ────────────────────────────────────────────────────────
    task automatic test_smoke_sfc();
        cfg_program_item prog;
        prog = new("test_smoke_sfc");
        build_legal_program(prog, 1, 1'b0);
        run_program("test_smoke_sfc", prog);
    endtask

    task automatic test_legal_with_extra_t2();
        cfg_program_item prog;
        prog = new("test_legal_with_extra_t2");
        build_legal_program(prog, 1, 1'b1);
        run_program("test_legal_with_extra_t2", prog);
    endtask

    task automatic test_eos_late();
        cfg_program_item prog;
        prog = new("test_eos_late");
        build_legal_program(prog, 1, 1'b0);
        prog.eos_strategy = EOS_AFTER_TRAILER;
        run_program("test_eos_late", prog);
    endtask

    task automatic test_eos_with_final_message();
        cfg_program_item prog;
        prog = new("test_eos_with_final_message");
        build_legal_program(prog, 1, 1'b0);
        run_program("test_eos_with_final_message", prog);
    endtask

    task automatic test_back_to_back_configs();
        cfg_program_item prog_a;
        cfg_program_item prog_b;
        prog_a = new("test_back_to_back_configs_a");
        build_legal_program(prog_a, 1, 1'b0);
        run_program("test_back_to_back_configs_a", prog_a);
        reset_dut();
        prog_b = new("test_back_to_back_configs_b");
        build_legal_program(prog_b, 1, 1'b0);
        run_program("test_back_to_back_configs_b", prog_b);
    endtask

    task automatic test_layer_id_decode_all();
        cfg_program_item prog;
        prog = new("test_layer_id_decode_all");
        for (int layer = 0; layer < NLY; layer++) begin
            append_weight_msg(prog, $sformatf("layer%0d_weight", layer), layer);
            if (layer < (NLY - 1))
                append_threshold_msg(prog, $sformatf("layer%0d_thr", layer), layer);
        end
        run_program("test_layer_id_decode_all", prog);
    endtask

    task automatic test_contest_stress();
        cfg_program_item prog;
        prog = new("test_contest_stress");
        build_legal_program(prog, 1, 1'b0);
        prog.valid_prob_pct = 80;
        prog.keep_hole_prob_pct = 5;
        prog.force_ready_stalls = 1'b1;
        run_program("test_contest_stress", prog);
    endtask

    task automatic test_stress_low_valid();
        cfg_program_item prog;
        prog = new("test_stress_low_valid");
        build_legal_program(prog, 1, 1'b0);
        prog.valid_prob_pct = 60;
        prog.force_ready_stalls = 1'b1;
        run_program("test_stress_low_valid", prog);
    endtask

    task automatic test_keep_holes_dense();
        cfg_program_item prog;
        prog = new("test_keep_holes_dense");
        build_legal_program(prog, 1, 1'b0);
        prog.valid_prob_pct = 100;
        prog.keep_hole_prob_pct = 30;
        run_program("test_keep_holes_dense", prog);
    endtask

    task automatic test_b2b_no_idle();
        cfg_program_item prog;
        prog = new("test_b2b_no_idle");
        build_legal_program(prog, 16, 1'b0);
        prog.valid_prob_pct = 80;
        prog.keep_hole_prob_pct = 5;
        prog.force_ready_stalls = 1'b1;
        run_program("test_b2b_no_idle", prog);
    endtask

    task automatic test_reset_mid_header();
        cfg_program_item prog;
        axi_beat_t beats[$];
        prog = new("test_reset_mid_header");
        build_legal_program(prog, 1, 1'b0);
        pack_beats(prog, beats);
        clear_observed();
        drive_beats(beats, 100, 1);
        clear_observed();
        test_smoke_sfc();
    endtask

    task automatic test_reset_mid_payload_w();
        cfg_program_item prog;
        axi_beat_t beats[$];
        prog = new("test_reset_mid_payload_w");
        build_legal_program(prog, 1, 1'b0);
        pack_beats(prog, beats);
        clear_observed();
        drive_beats(beats, 100, (BUS_BYTES >= 8) ? 6 : 20);
        clear_observed();
        test_smoke_sfc();
    endtask

    task automatic test_reset_mid_payload_t();
        cfg_program_item prog;
        axi_beat_t beats[$];
        prog = new("test_reset_mid_payload_t");
        append_threshold_msg(prog, "only_t0", 0);
        pack_beats(prog, beats);
        clear_observed();
        drive_beats(beats, 100, (BUS_BYTES >= 8) ? 2 : 10);
        clear_observed();
        test_smoke_sfc();
    endtask

    task automatic test_reset_during_eos_beat();
        cfg_program_item prog;
        axi_beat_t beats[$];
        prog = new("test_reset_during_eos_beat");
        build_legal_program(prog, 1, 1'b0);
        pack_beats(prog, beats);
        clear_observed();
        drive_beats(beats, 100, beats.size());
        clear_observed();
        test_smoke_sfc();
    endtask

    task automatic test_bad_msg_type();
        cfg_program_item prog;
        prog = new("test_bad_msg_type");
        build_bad_msg_type_program(prog);
        run_program("test_bad_msg_type", prog);
    endtask

    task automatic test_bad_layer_id();
        cfg_program_item prog;
        prog = new("test_bad_layer_id");
        build_bad_layer_id_program(prog);
        run_program("test_bad_layer_id", prog);
    endtask

    task automatic test_bad_bpn_zero();
        cfg_program_item prog;
        prog = new("test_bad_bpn_zero");
        build_bad_bpn_zero_program(prog);
        run_program("test_bad_bpn_zero", prog);
    endtask

    task automatic test_bad_total_bytes();
        cfg_program_item prog;
        prog = new("test_bad_total_bytes");
        build_bad_total_bytes_program(prog);
        run_program("test_bad_total_bytes", prog);
    endtask

    task automatic test_bad_nneur_zero();
        cfg_program_item prog;
        prog = new("test_bad_nneur_zero");
        build_bad_nneur_zero_program(prog);
        run_program("test_bad_nneur_zero", prog);
    endtask

    task automatic test_multiple_errors();
        cfg_program_item prog;
        prog = new("test_multiple_errors");
        build_multiple_errors_program(prog);
        run_program("test_multiple_errors", prog);
    endtask

    task automatic run_full_suite();
        test_smoke_sfc();
        reset_dut();
        test_legal_with_extra_t2();
        reset_dut();
        test_eos_late();
        reset_dut();
        test_eos_with_final_message();
        reset_dut();
        test_back_to_back_configs();
        reset_dut();
        test_layer_id_decode_all();
        reset_dut();
        test_contest_stress();
        reset_dut();
        test_stress_low_valid();
        reset_dut();
        test_keep_holes_dense();
        reset_dut();
        test_b2b_no_idle();
        reset_dut();
        test_reset_mid_header();
        reset_dut();
        test_reset_mid_payload_w();
        reset_dut();
        test_reset_mid_payload_t();
        reset_dut();
        test_reset_during_eos_beat();
        reset_dut();
        test_bad_msg_type();
        reset_dut();
        test_bad_layer_id();
        reset_dut();
        test_bad_bpn_zero();
        reset_dut();
        test_bad_total_bytes();
        reset_dut();
        test_bad_nneur_zero();
        reset_dut();
        test_multiple_errors();
    endtask

    task automatic run_named_test(input string test_name);
        if (test_name == "test_smoke_sfc") test_smoke_sfc();
        else if (test_name == "test_legal_with_extra_t2") test_legal_with_extra_t2();
        else if (test_name == "test_eos_late") test_eos_late();
        else if (test_name == "test_eos_with_final_message") test_eos_with_final_message();
        else if (test_name == "test_back_to_back_configs") test_back_to_back_configs();
        else if (test_name == "test_layer_id_decode_all") test_layer_id_decode_all();
        else if (test_name == "test_contest_stress") test_contest_stress();
        else if (test_name == "test_stress_low_valid") test_stress_low_valid();
        else if (test_name == "test_keep_holes_dense") test_keep_holes_dense();
        else if (test_name == "test_b2b_no_idle") test_b2b_no_idle();
        else if (test_name == "test_reset_mid_header") test_reset_mid_header();
        else if (test_name == "test_reset_mid_payload_w") test_reset_mid_payload_w();
        else if (test_name == "test_reset_mid_payload_t") test_reset_mid_payload_t();
        else if (test_name == "test_reset_during_eos_beat") test_reset_during_eos_beat();
        else if (test_name == "test_bad_msg_type") test_bad_msg_type();
        else if (test_name == "test_bad_layer_id") test_bad_layer_id();
        else if (test_name == "test_bad_bpn_zero") test_bad_bpn_zero();
        else if (test_name == "test_bad_total_bytes") test_bad_total_bytes();
        else if (test_name == "test_bad_nneur_zero") test_bad_nneur_zero();
        else if (test_name == "test_multiple_errors") test_multiple_errors();
        else begin
            $fatal(1, "Unknown +TEST=%s", test_name);
        end
    endtask

    task automatic report_summary();
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_config_manager (%s)", SWEEP_NAME);
        $display("============================================================");
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        $display("  Covergroups  : msg=%0.2f bus=%0.2f hs=%0.2f err=%0.2f eos=%0.2f write=%0.2f",
                 cg_msg_shape_inst.get_coverage(),
                 cg_bus_inst.get_coverage(),
                 cg_handshake_inst.get_coverage(),
                 cg_error_inst.get_coverage(),
                 cg_eos_inst.get_coverage(),
                 cg_write_inst.get_coverage());
        if (fail_count != 0) begin
            $display("  --- Failure Details ---");
            foreach (fail_log[i])
                $display("%s", fail_log[i]);
        end
        $display("============================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST CHECK(S) FAILED ***", fail_count);
        $display("============================================================");
    endtask

    // ─── Main sequence ──────────────────────────────────────────────────────
    initial begin
        string test_name;
        $display("[TB] bnn_config_manager profile=%s BUS=%0d TOTAL_LAYERS=%0d",
                 SWEEP_NAME, CONFIG_BUS_WIDTH, TOTAL_LAYERS);
        reset_dut();

        if ($value$plusargs("TEST=%s", test_name))
            run_named_test(test_name);
        else
            run_full_suite();

        report_summary();

        if (fail_count != 0)
            $fatal(1, "bnn_config_manager TB failed with %0d scoreboard error(s)", fail_count);
        else
            $display("PASS : bnn_config_manager TB completed without scoreboard failures");

        $finish;
    end

endmodule
