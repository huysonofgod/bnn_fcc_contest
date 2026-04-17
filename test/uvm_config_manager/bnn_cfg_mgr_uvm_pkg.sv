`timescale 1ns/10ps

package bnn_cfg_mgr_uvm_pkg;

    import bnn_cfg_mgr_pkg::*;

    // -------------------------------------------------------------------------
    // Fixed maxima for the verification envelope.
    // These match the fixed-width BFM interface and the accepted sweep space.
    // -------------------------------------------------------------------------
    localparam int CFGM_MAX_BUS_WIDTH = 64;
    localparam int CFGM_MAX_BUS_BYTES = 8;
    localparam int CFGM_MAX_NLY       = 3;
    localparam int CFGM_MAX_PW        = 16;

    // -------------------------------------------------------------------------
    // Packed beat representation used by the config AXI driver.
    // Data and keep are always stored at the maximum width; only the low
    // active bytes for a given profile are driven.
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic [CFGM_MAX_BUS_WIDTH-1:0] data;
        logic [CFGM_MAX_BUS_BYTES-1:0] keep;
        logic                          last;
    } axi_beat_t;

    // -------------------------------------------------------------------------
    // Observed or expected cfg write transaction.
    // The scoreboard uses one common representation for weights and thresholds
    // so it can compare either side with one reporting path.
    // -------------------------------------------------------------------------
    typedef struct {
        bit                           is_thr;
        int                           layer;
        int                           np;
        int                           addr;
        logic [CFGM_MAX_PW-1:0]       data;
        logic [31:0]                  thr_data;
        bit                           last_word;
        bit                           last_neuron;
        bit                           last_msg;
    } write_txn_t;

    // -------------------------------------------------------------------------
    // Shared chance helper used by both drivers.
    // Keeping this logic in one function avoids small but annoying differences
    // in random-stall semantics across components.
    // -------------------------------------------------------------------------
    function automatic bit chance_fn(input int unsigned pct);
        if (pct >= 100)
            return 1'b1;
        if (pct == 0)
            return 1'b0;
        return ($urandom_range(0, 99) < pct);
    endfunction

    // -------------------------------------------------------------------------
    // Count inactive keep lanes over only the active low-order bytes.
    // Questa does not allow variable-width packed slices in all simulation
    // phases, so this helper makes the active-byte reduction explicit.
    // -------------------------------------------------------------------------
    function automatic int keep_hole_count_fn(
        input logic [CFGM_MAX_BUS_BYTES-1:0] keep,
        input int bus_bytes
    );
        int holes;
        holes = 0;
        for (int i = 0; i < bus_bytes; i++) begin
            if (!keep[i])
                holes++;
        end
        return holes;
    endfunction

    // -------------------------------------------------------------------------
    // Environment configuration object.
    // This captures the active sweep profile so all classes can reason about
    // the same geometry without pulling compile-time constants through every
    // constructor signature.
    // -------------------------------------------------------------------------
    class cfg_env_cfg;
        string sweep_name;
        int    config_bus_width;
        int    bus_bytes;
        int    total_layers;
        int    nly;
        int    lid_w;
        int    parallel_inputs;
        int    acc_w;
        int    max_pw;
        int    topology[$];
        int    parallel_neurons[$];

        // ---------------------------------------------------------------------
        // Constructor.
        // The top module populates this once from the active compile-time
        // profile, then every class shares the same immutable config handle.
        // ---------------------------------------------------------------------
        function new(
            input string name_i,
            input int config_bus_width_i,
            input int total_layers_i,
            input int lid_w_i,
            input int parallel_inputs_i,
            input int acc_w_i,
            input int max_pw_i,
            input int topology_i[$],
            input int parallel_neurons_i[$]
        );
            sweep_name       = name_i;
            config_bus_width = config_bus_width_i;
            bus_bytes        = config_bus_width_i / 8;
            total_layers     = total_layers_i;
            nly              = total_layers_i - 1;
            lid_w            = lid_w_i;
            parallel_inputs  = parallel_inputs_i;
            acc_w            = acc_w_i;
            max_pw           = max_pw_i;
            topology         = topology_i;
            parallel_neurons = parallel_neurons_i;
        endfunction

        // ---------------------------------------------------------------------
        // Return the P_W value used by the specified non-input layer.
        // Layer 0 consumes `parallel_inputs`; later layers consume the previous
        // entry from `parallel_neurons`, matching the Phase-4 wrapper contract.
        // ---------------------------------------------------------------------
        function automatic int layer_pw_idx(input int layer_idx);
            if (layer_idx == 0)
                return parallel_inputs;
            return parallel_neurons[layer_idx - 1];
        endfunction

        // ---------------------------------------------------------------------
        // Return the P_N value used by the specified non-input layer.
        // ---------------------------------------------------------------------
        function automatic int layer_pn_idx(input int layer_idx);
            return parallel_neurons[layer_idx];
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // One configuration message (header + payload).
    // This item is intentionally lightweight: the program object owns message
    // sequencing, while the item owns only one message's header/payload fields.
    // -------------------------------------------------------------------------
    class cfg_msg_item;
        string               name;
        bit [7:0]            msg_type;
        bit [7:0]            layer_id;
        bit [15:0]           layer_inputs;
        bit [15:0]           num_neurons;
        bit [15:0]           bytes_per_neuron;
        bit [31:0]           total_bytes;
        byte unsigned        payload[$];

        // ---------------------------------------------------------------------
        // Constructor.
        // Named items make scoreboard and waveform review substantially faster,
        // especially once malformed-message tests enter the suite.
        // ---------------------------------------------------------------------
        function new(string name_i = "");
            name             = name_i;
            msg_type         = '0;
            layer_id         = '0;
            layer_inputs     = '0;
            num_neurons      = '0;
            bytes_per_neuron = '0;
            total_bytes      = '0;
            payload          = {};
        endfunction

        // ---------------------------------------------------------------------
        // Return the expected wrapper-side error classification for this header.
        // The coverage subscriber uses this when sampling generated programs,
        // and the scoreboarding/report path uses it to explain malformed cases.
        // ---------------------------------------------------------------------
        function automatic dbg_error_class_t classify(input cfg_env_cfg cfg);
            dbg_error_class_t cls;
            cls = CFG_ERR_NONE;

            if (msg_type > 8'h01)
                cls = CFG_ERR_BAD_MSGTYPE;
            else if (layer_id >= cfg.nly)
                cls = CFG_ERR_BAD_LAYERID;
            else if ((msg_type == 8'h00) &&
                     (bytes_per_neuron == 16'd0) &&
                     (num_neurons != 16'd0))
                cls = CFG_ERR_BAD_BPN0;
            else if (num_neurons == 16'd0)
                cls = CFG_ERR_BAD_NNEUR0;
            else if ((msg_type == 8'h00) &&
                     (total_bytes != (bytes_per_neuron * num_neurons)))
                cls = CFG_ERR_BAD_TOTALBYTES;
            else if ((msg_type == 8'h01) &&
                     (layer_id == (cfg.nly - 1)))
                cls = CFG_ERR_EXTRA_T2;

            return cls;
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // One end-to-end config program.
    // This is the unit the tests hand to the environment. It owns both the
    // message list and the golden cfg write transactions expected from it.
    // -------------------------------------------------------------------------
    class cfg_program_item;
        string               name;
        cfg_msg_item         msgs[$];
        write_txn_t          expected[$];
        dbg_eos_strategy_t   eos_strategy;
        int                  valid_prob_pct;
        int                  keep_hole_prob_pct;
        bit                  force_ready_stalls;
        int                  ready_prob_pct;
        int                  hold_ready_low_cycles;
        int                  early_last_beat_idx;
        bit                  expect_error;
        int                  expected_extra_t2_count;

        // ---------------------------------------------------------------------
        // Constructor with conservative defaults.
        // The defaults describe a legal, non-stalling, EOS-on-final-beat
        // program. Individual tests then override only the knobs they need.
        // ---------------------------------------------------------------------
        function new(string name_i = "");
            name                    = name_i;
            eos_strategy            = EOS_LAST_BEAT;
            valid_prob_pct          = 100;
            keep_hole_prob_pct      = 0;
            force_ready_stalls      = 1'b0;
            ready_prob_pct          = 100;
            hold_ready_low_cycles   = 0;
            early_last_beat_idx     = -1;
            expect_error            = 1'b0;
            expected_extra_t2_count = 0;
        endfunction

        // ---------------------------------------------------------------------
        // Append one weight message and its expected M10 write transactions.
        // The payload uses the binding packing rule:
        //   - LSB-first within each byte
        //   - padded upper bits of the final byte are 1s
        // ---------------------------------------------------------------------
        function automatic void append_weight_msg(
            input cfg_env_cfg cfg,
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
            fan_in      = cfg.topology[layer_idx];
            num_neurons = cfg.topology[layer_idx + 1];
            p_w         = cfg.layer_pw_idx(layer_idx);
            p_n         = cfg.layer_pn_idx(layer_idx);
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
                        txn.is_thr      = 1'b0;
                        txn.layer       = layer_idx;
                        txn.np          = neuron % p_n;
                        txn.addr        = ((neuron / p_n) * wpn) + word_idx;
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

                        expected.push_back(txn);
                    end
                end
            end

            if (total_bytes_override >= 0) begin
                while (msg.payload.size() > total_bytes_override)
                    void'(msg.payload.pop_back());
                while (msg.payload.size() < total_bytes_override)
                    msg.payload.push_back($urandom());
            end

            msgs.push_back(msg);
        endfunction

        // ---------------------------------------------------------------------
        // Append one threshold message and its expected cfg_thr transactions.
        // Thresholds are emitted little-endian and the expected address uses the
        // wrapper-owned `(np, addr)` bridge logic
        // ---------------------------------------------------------------------
        function automatic void append_threshold_msg(
            input cfg_env_cfg cfg,
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
            num_neurons = cfg.topology[layer_idx + 1];
            p_n         = cfg.layer_pn_idx(layer_idx);

            msg.msg_type         = 8'h01;
            msg.layer_id         = (layer_id_override >= 0) ? layer_id_override[7:0] : layer_idx[7:0];
            msg.layer_inputs     = 16'h0000;
            msg.num_neurons      = 16'((nneur_override >= 0) ? nneur_override : num_neurons);
            msg.bytes_per_neuron = 16'd4;
            msg.total_bytes      = 32'((total_bytes_override >= 0) ? total_bytes_override : (4 * num_neurons));
            msg.payload.delete();

            for (int neuron = 0; neuron < num_neurons; neuron++) begin
                logic [31:0] thr_val;
                thr_val = 32'($urandom_range(0, (1 << cfg.acc_w) - 1));
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
                    expected.push_back(txn);
                end
            end

            if (total_bytes_override >= 0) begin
                while (msg.payload.size() > total_bytes_override)
                    void'(msg.payload.pop_back());
                while (msg.payload.size() < total_bytes_override)
                    msg.payload.push_back($urandom());
            end

            if (count_extra_t2)
                expected_extra_t2_count++;
            msgs.push_back(msg);
        endfunction

        // ---------------------------------------------------------------------
        // Build the canonical legal configuration stream for the active profile.
        // This reproduces the shipped ordering:
        //   W0,T0,W1,T1,...,W_last_hidden,T_last_hidden,W_output
        // with optional extra output-layer threshold messages.
        // ---------------------------------------------------------------------
        function automatic void build_legal_program(
            input cfg_env_cfg cfg,
            input int repeat_count = 1,
            input bit include_extra_t2 = 1'b0
        );
            for (int rep = 0; rep < repeat_count; rep++) begin
                for (int layer = 0; layer < cfg.nly; layer++) begin
                    append_weight_msg(cfg, $sformatf("W%0d_rep%0d", layer, rep), layer);
                    if (layer < (cfg.nly - 1)) begin
                        append_threshold_msg(cfg, $sformatf("T%0d_rep%0d", layer, rep), layer);
                    end else if (include_extra_t2) begin
                        append_threshold_msg(cfg,
                                             $sformatf("T%0d_extra_rep%0d", layer, rep),
                                             layer,
                                             -1, -1, -1,
                                             1'b1, 1'b1);
                    end
                end
            end
        endfunction

        // ---------------------------------------------------------------------
        // Malformed-program helpers used by the negative suite.
        // Each helper prepends one malformed message and then appends a legal
        // recovery program so the scoreboard can confirm graceful continue.
        // ---------------------------------------------------------------------
        function automatic void build_bad_msg_type_program(input cfg_env_cfg cfg);
            append_weight_msg(cfg, "bad_msg_type", 0, 8'h42, -1, -1, -1, 16, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        function automatic void build_bad_layer_id_program(input cfg_env_cfg cfg);
            append_weight_msg(cfg, "bad_layer_id", 0, -1, cfg.nly, -1, -1, 16, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        function automatic void build_bad_bpn_zero_program(input cfg_env_cfg cfg);
            append_weight_msg(cfg, "bad_bpn_zero", 0, -1, -1, 0, 10, 0, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        function automatic void build_bad_total_bytes_program(input cfg_env_cfg cfg);
            append_weight_msg(cfg, "bad_total_bytes", 0, -1, -1, -1, -1, 15, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        function automatic void build_bad_nneur_zero_program(input cfg_env_cfg cfg);
            append_threshold_msg(cfg, "bad_nneur_zero", 0, -1, 0, 0, 1'b0, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        function automatic void build_multiple_errors_program(input cfg_env_cfg cfg);
            append_weight_msg(cfg, "bad_msg_type", 0, 8'h55, -1, -1, -1, 8, 1'b0);
            append_weight_msg(cfg, "bad_layer_id", 0, -1, cfg.nly, -1, -1, 8, 1'b0);
            append_weight_msg(cfg, "bad_bpn_zero", 0, -1, -1, 0, 10, 0, 1'b0);
            build_legal_program(cfg, 1, 1'b0);
            expect_error = 1'b1;
        endfunction

        // ---------------------------------------------------------------------
        // Serialize the message list into a byte stream.
        // Header bytes are emitted little-endian exactly as the DUT expects.
        // ---------------------------------------------------------------------
        function automatic void build_byte_stream(ref byte unsigned stream[$]);
            stream.delete();
            foreach (msgs[msg_idx]) begin
                cfg_msg_item msg;
                msg = msgs[msg_idx];

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
        endfunction

        // ---------------------------------------------------------------------
        // Pack the serialized byte stream into fixed-width AXI beats.
        // Optional keep holes are inserted only on non-terminal lanes so one
        // beat can never collapse to all keep=0.
        //
        // `early_last_beat_idx` is a deliberate negative/confidence hook. When
        // set, the selected beat gets TLAST and the final beat does not. This
        // lets the parser coverage suite exercise sticky `saw_last_r_q` paths
        // without changing the functional RTL.
        // ---------------------------------------------------------------------
        function automatic void pack_beats(
            input cfg_env_cfg cfg,
            ref axi_beat_t beats[$]
        );
            byte unsigned stream[$];
            int byte_idx;

            beats.delete();
            build_byte_stream(stream);
            byte_idx = 0;

            while (byte_idx < stream.size()) begin
                axi_beat_t beat;
                bit any_keep;
                beat = '0;

                for (int lane = 0; lane < cfg.bus_bytes; lane++) begin
                    bit use_hole;
                    use_hole = 1'b0;
                    if ((lane < (cfg.bus_bytes - 1)) &&
                        (keep_hole_prob_pct > 0) &&
                        (byte_idx < stream.size()) &&
                        chance_fn(keep_hole_prob_pct)) begin
                        use_hole = 1'b1;
                    end

                    if (!use_hole && (byte_idx < stream.size())) begin
                        beat.keep[lane] = 1'b1;
                        beat.data[(lane * 8) +: 8] = stream[byte_idx];
                        byte_idx++;
                    end
                end

                any_keep = 1'b0;
                for (int lane = 0; lane < cfg.bus_bytes; lane++) begin
                    any_keep |= beat.keep[lane];
                end

                if (!any_keep) begin
                    beat.keep[0] = 1'b1;
                    beat.data[7:0] = stream[byte_idx];
                    byte_idx++;
                end

                beats.push_back(beat);
            end

            if (eos_strategy == EOS_LAST_BEAT) begin
                if (beats.size() != 0)
                    beats[beats.size()-1].last = 1'b1;
            end else begin
                axi_beat_t trailer;
                trailer = '0;
                trailer.keep[0] = 1'b1;
                trailer.data[7:0] = 8'h00;
                trailer.last = 1'b1;
                beats.push_back(trailer);
            end

            if ((early_last_beat_idx >= 0) && (early_last_beat_idx < beats.size())) begin
                foreach (beats[i])
                    beats[i].last = 1'b0;
                beats[early_last_beat_idx].last = 1'b1;
            end
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Coverage subscriber.
    // Review note:
    //   The class uses function-sampled covergroups rather than event-sampled
    //   covergroups so the monitors can precisely control what gets sampled.
    //   This dramatically reduces ambiguity during review.
    // -------------------------------------------------------------------------
    class cfg_coverage_subscriber;
        covergroup cg_msg_shape with function sample(
            bit [7:0] msg_type,
            bit [7:0] layer_id,
            int fan_in,
            int nneur,
            int bpn,
            dbg_error_class_t err_class
        );
            option.per_instance = 1;
            cp_msg_type: coverpoint msg_type {
                bins weights = {8'h00};
                bins thr     = {8'h01};
                bins illegal = {[8'h02:8'hFF]};
            }
            cp_layer: coverpoint layer_id {
                bins valid[] = {[0:2]};
                bins illegal = {[3:255]};
            }
            cp_fan_in: coverpoint fan_in {
                bins one      = {1};
                bins odd[]    = {7, 13, 17};
                bins sixteen  = {16};
                bins thirty2  = {32};
                bins two56    = {256};
                bins seven84  = {784};
                bins other    = default;
            }
            cp_nneur: coverpoint nneur {
                bins zero      = {0};
                bins one       = {1};
                bins small_n[] = {2, 3, 5, 7, 10, 16};
                bins big_n     = {256};
                bins other     = default;
            }
            cp_bpn: coverpoint bpn {
                bins zero = {0};
                bins one  = {1};
                bins two  = {2};
                bins four = {4};
                bins big[] = {32, 98};
                bins other = default;
            }
            cp_err: coverpoint err_class;
            cx_type_layer: cross cp_msg_type, cp_layer;
        endgroup

        covergroup cg_bus with function sample(int hole_count, bit last_flag, int bus_width);
            option.per_instance = 1;
            cp_holes: coverpoint hole_count {
                bins none = {0};
                bins one  = {1};
                bins few  = {[2:3]};
                bins many = {[4:7]};
            }
            cp_last: coverpoint last_flag;
            cp_bus: coverpoint bus_width {
                bins w8  = {8};
                bins w16 = {16};
                bins w32 = {32};
                bins w64 = {64};
            }
            cx_holes_last: cross cp_holes, cp_last;
        endgroup

        covergroup cg_handshake with function sample(bit [1:0] cfg_hs, bit [1:0] payload_hs);
            option.per_instance = 1;
            cp_cfg: coverpoint cfg_hs {
                bins idle      = {2'b00};
                bins wait_v    = {2'b10};
                bins ready_o   = {2'b01};
                bins handshake = {2'b11};
            }
            cp_payload: coverpoint payload_hs {
                bins idle      = {2'b00};
                bins wait_v    = {2'b10};
                bins ready_o   = {2'b01};
                bins handshake = {2'b11};
            }
        endgroup

        covergroup cg_error with function sample(dbg_error_class_t err_class, bit sticky);
            option.per_instance = 1;
            cp_class: coverpoint err_class;
            cp_sticky: coverpoint sticky;
            cx_class_sticky: cross cp_class, cp_sticky;
        endgroup

        covergroup cg_eos with function sample(dbg_eos_strategy_t strategy);
            option.per_instance = 1;
            cp_strategy: coverpoint strategy;
        endgroup

        covergroup cg_write with function sample(int layer, bit last_msg);
            option.per_instance = 1;
            cp_layer: coverpoint layer {
                bins layer0 = {0};
                bins layer1 = {1};
                bins layer2 = {2};
            }
            cp_last: coverpoint last_msg;
        endgroup

        // ---------------------------------------------------------------------
        // Constructor.
        // Every covergroup is instantiated explicitly here to make it obvious
        // to reviewers that this class is the only coverage owner.
        // ---------------------------------------------------------------------
        function new();
            cg_msg_shape = new();
            cg_bus       = new();
            cg_handshake = new();
            cg_error     = new();
            cg_eos       = new();
            cg_write     = new();
        endfunction

        function automatic void sample_msg(
            bit [7:0] msg_type,
            bit [7:0] layer_id,
            int fan_in,
            int nneur,
            int bpn,
            dbg_error_class_t err_class
        );
            cg_msg_shape.sample(msg_type, layer_id, fan_in, nneur, bpn, err_class);
            cg_error.sample(err_class, (err_class != CFG_ERR_NONE));
        endfunction

        function automatic void sample_bus(int hole_count, bit last_flag, int bus_width);
            cg_bus.sample(hole_count, last_flag, bus_width);
        endfunction

        function automatic void sample_handshake(bit [1:0] cfg_hs, bit [1:0] payload_hs);
            cg_handshake.sample(cfg_hs, payload_hs);
        endfunction

        function automatic void sample_error(dbg_error_class_t err_class, bit sticky);
            cg_error.sample(err_class, sticky);
        endfunction

        function automatic void sample_eos(dbg_eos_strategy_t strategy);
            cg_eos.sample(strategy);
        endfunction

        function automatic void sample_write(int layer, bit last_msg);
            cg_write.sample(layer, last_msg);
        endfunction

        // ---------------------------------------------------------------------
        // Compact coverage summary string used by the scoreboard footer.
        // ---------------------------------------------------------------------
        function automatic string summary_string();
            return $sformatf("msg=%0.2f bus=%0.2f hs=%0.2f err=%0.2f eos=%0.2f write=%0.2f",
                             cg_msg_shape.get_coverage(),
                             cg_bus.get_coverage(),
                             cg_handshake.get_coverage(),
                             cg_error.get_coverage(),
                             cg_eos.get_coverage(),
                             cg_write.get_coverage());
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Scoreboard.
    // This is intentionally stateful rather than purely functional because the
    // monitors run continuously in the background across many tests.
    // -------------------------------------------------------------------------
    class cfg_scoreboard;
        virtual cfg_mgr_bfm_if       vif;
        cfg_env_cfg                  cfg;
        cfg_coverage_subscriber      cov;

        int                          pass_count;
        int                          fail_count;
        string                       fail_log[$];
        write_txn_t                  obs_wr_q [CFGM_MAX_NLY][$];
        write_txn_t                  obs_thr_q[CFGM_MAX_NLY][$];

        function new(
            virtual cfg_mgr_bfm_if vif_i,
            cfg_env_cfg cfg_i,
            cfg_coverage_subscriber cov_i
        );
            vif        = vif_i;
            cfg        = cfg_i;
            cov        = cov_i;
            pass_count = 0;
            fail_count = 0;
        endfunction

        // ---------------------------------------------------------------------
        // Common scoreboard check helper.
        // Every mismatch goes both to `$error` and to the replayable fail log.
        // ---------------------------------------------------------------------
        function automatic void check(string test_name, bit cond, string msg = "");
            if (cond) begin
                pass_count++;
            end else begin
                fail_count++;
                fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
                $error("[SB] %s: %s", test_name, msg);
            end
        endfunction

        // ---------------------------------------------------------------------
        // Clear observed transactions before a new program starts.
        // ---------------------------------------------------------------------
        function automatic void clear_observed();
            for (int i = 0; i < CFGM_MAX_NLY; i++) begin
                obs_wr_q[i].delete();
                obs_thr_q[i].delete();
            end
        endfunction

        // ---------------------------------------------------------------------
        // Record one accepted weight write from the passive monitor.
        // ---------------------------------------------------------------------
        function automatic void record_weight(input write_txn_t txn);
            if ((txn.layer >= 0) && (txn.layer < cfg.nly))
                obs_wr_q[txn.layer].push_back(txn);
        endfunction

        // ---------------------------------------------------------------------
        // Record one accepted threshold write from the passive monitor.
        // ---------------------------------------------------------------------
        function automatic void record_threshold(input write_txn_t txn);
            if ((txn.layer >= 0) && (txn.layer < cfg.nly))
                obs_thr_q[txn.layer].push_back(txn);
        endfunction

        // ---------------------------------------------------------------------
        // Wait for cfg_done with a program-specific timeout.
        // ---------------------------------------------------------------------
        task automatic wait_for_done(input string test_name, input int max_cycles = 3000000);
            int cycles;
            cycles = 0;
            while (!vif.cfg_done && (cycles < max_cycles)) begin
                @(posedge vif.clk);
                cycles++;
            end
            check(test_name, vif.cfg_done, "cfg_done did not assert before timeout");
        endtask

        // ---------------------------------------------------------------------
        // Wait until the cfg output ports are idle for a few cycles.
        // This prevents a compare from racing the final accepted write.
        // ---------------------------------------------------------------------
        task automatic wait_for_quiesce(input int idle_cycles = 8, input int max_cycles = 200000);
            int idle_count;
            int cycles;
            idle_count = 0;
            cycles     = 0;

            while ((idle_count < idle_cycles) && (cycles < max_cycles)) begin
                bit all_idle;
                all_idle = 1'b1;
                @(posedge vif.clk);

                for (int i = 0; i < cfg.nly; i++) begin
                    if (vif.cfg_wr_valid[i] || vif.cfg_thr_valid[i])
                        all_idle = 1'b0;
                end

                if (all_idle)
                    idle_count++;
                else
                    idle_count = 0;

                cycles++;
            end
        endtask

        // ---------------------------------------------------------------------
        // Compare observed writes against the program's golden transactions.
        // The compare is intentionally flattened by layer and transaction type
        // so failure reporting stays direct and grep-friendly.
        // ---------------------------------------------------------------------
        task automatic compare_program(input string test_name, cfg_program_item prog);
            write_txn_t exp_wr_q [CFGM_MAX_NLY][$];
            write_txn_t exp_thr_q[CFGM_MAX_NLY][$];

            foreach (prog.expected[idx]) begin
                if (prog.expected[idx].is_thr)
                    exp_thr_q[prog.expected[idx].layer].push_back(prog.expected[idx]);
                else
                    exp_wr_q[prog.expected[idx].layer].push_back(prog.expected[idx]);
            end

            for (int layer = 0; layer < cfg.nly; layer++) begin
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
                  vif.cfg_error == prog.expect_error,
                  $sformatf("cfg_error exp=%0b got=%0b", prog.expect_error, vif.cfg_error));

            check(test_name,
                  vif.cfg_extra_t2_count == prog.expected_extra_t2_count,
                  $sformatf("cfg_extra_t2_count exp=%0d got=%0d",
                            prog.expected_extra_t2_count, vif.cfg_extra_t2_count));
        endtask

        // ---------------------------------------------------------------------
        // Print one compact end-of-run summary.
        // ---------------------------------------------------------------------
        task automatic report_summary(input string title);
            $display("============================================================");
            $display("  SCOREBOARD SUMMARY -- %s", title);
            $display("============================================================");
            $display("  PASS         : %0d", pass_count);
            $display("  FAIL         : %0d", fail_count);
            $display("  Covergroups  : %s", cov.summary_string());
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
    endclass

    // -------------------------------------------------------------------------
    // Sink-side ready driver.
    // This component models the per-layer cfg write acceptance side. Most tests
    // run with ready held high; stress tests enable random stalls, and a small
    // number of confidence tests request an initial all-low window.
    // -------------------------------------------------------------------------
    class cfg_sink_driver;
        virtual cfg_mgr_bfm_if   vif;
        cfg_env_cfg              cfg;
        bit                      enable_random_stalls;
        int                      ready_prob_pct;
        int                      hold_low_cycles_remaining;
        bit                      program_active;

        function new(virtual cfg_mgr_bfm_if vif_i, cfg_env_cfg cfg_i);
            vif  = vif_i;
            cfg  = cfg_i;
            enable_random_stalls    = 1'b0;
            ready_prob_pct          = 100;
            hold_low_cycles_remaining = 0;
            program_active          = 1'b0;
        endfunction

        // ---------------------------------------------------------------------
        // Arm the sink policy for the upcoming program.
        // ---------------------------------------------------------------------
        function automatic void configure_program(cfg_program_item prog);
            enable_random_stalls     = prog.force_ready_stalls;
            ready_prob_pct           = prog.ready_prob_pct;
            hold_low_cycles_remaining = prog.hold_ready_low_cycles;
            program_active           = 1'b1;
        endfunction

        // ---------------------------------------------------------------------
        // Return to the idle all-ready state.
        // ---------------------------------------------------------------------
        function automatic void idle();
            enable_random_stalls      = 1'b0;
            ready_prob_pct            = 100;
            hold_low_cycles_remaining = 0;
            program_active            = 1'b0;
        endfunction

        // ---------------------------------------------------------------------
        // Continuous ready generation.
        // ---------------------------------------------------------------------
        task automatic run();
            forever begin
                @(posedge vif.clk);
                if (vif.rst || !program_active) begin
                    vif.set_all_ready(cfg.nly, 1'b1);
                end else if (hold_low_cycles_remaining > 0) begin
                    vif.set_all_ready(cfg.nly, 1'b0);
                    hold_low_cycles_remaining--;
                end else if (enable_random_stalls) begin
                    vif.set_all_ready(cfg.nly, 1'b0);
                    for (int i = 0; i < cfg.nly; i++) begin
                        vif.cfg_wr_ready[i]  <= chance_fn(ready_prob_pct);
                        vif.cfg_thr_ready[i] <= chance_fn(ready_prob_pct);
                    end
                end else begin
                    vif.set_all_ready(cfg.nly, 1'b1);
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // AXI config driver.
    // Owns only the DUT ingress. All sink-side readiness is delegated to the
    // sink driver so driver intent stays focused on message serialization.
    // -------------------------------------------------------------------------
    class cfg_axi_driver;
        virtual cfg_mgr_bfm_if       vif;
        cfg_env_cfg                  cfg;
        cfg_coverage_subscriber      cov;

        function new(
            virtual cfg_mgr_bfm_if vif_i,
            cfg_env_cfg cfg_i,
            cfg_coverage_subscriber cov_i
        );
            vif = vif_i;
            cfg = cfg_i;
            cov = cov_i;
        endfunction

        // ---------------------------------------------------------------------
        // Drive one config program onto the AXI ingress.
        // If `reset_after_handshakes` is set, the driver asserts reset once that
        // many handshakes have completed and then returns without comparing the
        // partially-driven program. Reset-recovery tests use this path.
        // ---------------------------------------------------------------------
        task automatic drive_program(
            cfg_program_item prog,
            input int reset_after_handshakes = -1
        );
            axi_beat_t beats[$];
            int beat_idx;
            int handshakes;
            int wait_cycles;

            foreach (prog.msgs[i]) begin
                cov.sample_msg(prog.msgs[i].msg_type,
                               prog.msgs[i].layer_id,
                               prog.msgs[i].layer_inputs,
                               prog.msgs[i].num_neurons,
                               prog.msgs[i].bytes_per_neuron,
                               prog.msgs[i].classify(cfg));
            end

            prog.pack_beats(cfg, beats);
            beat_idx    = 0;
            handshakes  = 0;
            wait_cycles = 0;

            while (beat_idx < beats.size()) begin
                @(posedge vif.clk);

                if (vif.config_valid && vif.config_ready) begin
                    beat_idx++;
                    handshakes++;
                end

                if ((reset_after_handshakes >= 0) &&
                    (handshakes == reset_after_handshakes)) begin
                    vif.clear_input_drives();
                    vif.rst <= 1'b1;
                    repeat (5) @(posedge vif.clk);
                    vif.rst <= 1'b0;
                    repeat (3) @(posedge vif.clk);
                    vif.clear_input_drives();
                    return;
                end

                if (beat_idx < beats.size()) begin
                    if (vif.config_valid && !vif.config_ready) begin
                        vif.config_valid <= 1'b1;
                    end else if (chance_fn(prog.valid_prob_pct)) begin
                        vif.config_valid <= 1'b1;
                        vif.config_data  <= beats[beat_idx].data;
                        vif.config_keep  <= beats[beat_idx].keep;
                        vif.config_last  <= beats[beat_idx].last;
                    end else begin
                        vif.config_valid <= 1'b0;
                    end
                end else begin
                    vif.clear_input_drives();
                end

                wait_cycles++;
                if (wait_cycles > 2000000)
                    $fatal(1, "[DRV] Timeout while driving AXI beats for %s", prog.name);
            end

            @(posedge vif.clk);
            vif.clear_input_drives();
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Passive AXI monitor.
    // Samples only real handshakes and DUT-observed gray-box status. This keeps
    // coverage tied to actual DUT behavior rather than just the program intent.
    // -------------------------------------------------------------------------
    class cfg_axi_monitor;
        virtual cfg_mgr_bfm_if       vif;
        cfg_env_cfg                  cfg;
        cfg_coverage_subscriber      cov;
        bit                          cfg_done_d;

        function new(
            virtual cfg_mgr_bfm_if vif_i,
            cfg_env_cfg cfg_i,
            cfg_coverage_subscriber cov_i
        );
            vif      = vif_i;
            cfg      = cfg_i;
            cov      = cov_i;
            cfg_done_d = 1'b0;
        endfunction

        task automatic run();
            forever begin
                @(posedge vif.clk);

                if (vif.rst) begin
                    cfg_done_d = 1'b0;
                    continue;
                end

                cov.sample_handshake({vif.config_valid, vif.config_ready},
                                     {vif.payload_valid, vif.payload_ready});

                if (vif.config_valid && vif.config_ready) begin
                    cov.sample_bus(keep_hole_count_fn(vif.config_keep, cfg.bus_bytes),
                                   vif.config_last,
                                   cfg.config_bus_width);
                end

                if (vif.hdr_valid) begin
                    cov.sample_msg(vif.hdr_msg_type,
                                   vif.hdr_layer_id,
                                   vif.hdr_layer_inputs,
                                   vif.hdr_num_neurons,
                                   vif.hdr_bytes_per_neuron,
                                   dbg_error_class_t'(vif.dbg_error_class));
                end

                if (vif.cfg_done && !cfg_done_d)
                    cov.sample_eos(dbg_eos_strategy_t'(vif.dbg_eos_strategy));

                cfg_done_d = vif.cfg_done;
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Passive per-layer cfg write monitor.
    // Each instance watches exactly one layer slot and forwards accepted
    // transactions into the scoreboard and the write covergroup.
    // -------------------------------------------------------------------------
    class engine_cfg_monitor;
        virtual cfg_mgr_bfm_if       vif;
        cfg_env_cfg                  cfg;
        cfg_scoreboard               sb;
        cfg_coverage_subscriber      cov;
        int                          layer_idx;

        function new(
            virtual cfg_mgr_bfm_if vif_i,
            cfg_env_cfg cfg_i,
            cfg_scoreboard sb_i,
            cfg_coverage_subscriber cov_i,
            int layer_idx_i
        );
            vif       = vif_i;
            cfg       = cfg_i;
            sb        = sb_i;
            cov       = cov_i;
            layer_idx = layer_idx_i;
        endfunction

        task automatic run();
            forever begin
                @(posedge vif.clk);
                if (vif.rst)
                    continue;

                if (vif.cfg_wr_valid[layer_idx] && vif.cfg_wr_ready[layer_idx]) begin
                    write_txn_t txn;
                    txn = '{default:'0};
                    txn.is_thr      = 1'b0;
                    txn.layer       = layer_idx;
                    txn.np          = vif.cfg_wr_np[layer_idx];
                    txn.addr        = vif.cfg_wr_addr[layer_idx];
                    txn.data        = vif.cfg_wr_data[layer_idx];
                    txn.last_word   = vif.cfg_wr_last_word[layer_idx];
                    txn.last_neuron = vif.cfg_wr_last_neuron[layer_idx];
                    txn.last_msg    = vif.cfg_wr_last_msg[layer_idx];
                    sb.record_weight(txn);
                    cov.sample_write(layer_idx, txn.last_msg);
                end

                if (vif.cfg_thr_valid[layer_idx] && vif.cfg_thr_ready[layer_idx]) begin
                    write_txn_t txn;
                    txn = '{default:'0};
                    txn.is_thr   = 1'b1;
                    txn.layer    = layer_idx;
                    txn.np       = vif.cfg_thr_np[layer_idx];
                    txn.addr     = vif.cfg_thr_addr[layer_idx];
                    txn.thr_data = vif.cfg_thr_data[layer_idx];
                    sb.record_threshold(txn);
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Environment shell.
    // The env owns one shared coverage model and scoreboard, then wires every
    // active/passive component to the same virtual interface.
    // -------------------------------------------------------------------------
    class cfg_env;
        virtual cfg_mgr_bfm_if               vif;
        cfg_env_cfg                          cfg;
        cfg_coverage_subscriber              cov;
        cfg_scoreboard                       sb;
        cfg_sink_driver                      sink_drv;
        cfg_axi_driver                       axi_drv;
        cfg_axi_monitor                      axi_mon;
        engine_cfg_monitor                   eng_mon[$];
        bit                                  background_started;

        function new(virtual cfg_mgr_bfm_if vif_i, cfg_env_cfg cfg_i);
            vif                = vif_i;
            cfg                = cfg_i;
            cov                = new();
            sb                 = new(vif_i, cfg_i, cov);
            sink_drv           = new(vif_i, cfg_i);
            axi_drv            = new(vif_i, cfg_i, cov);
            axi_mon            = new(vif_i, cfg_i, cov);
            background_started = 1'b0;

            for (int i = 0; i < cfg.nly; i++) begin
                engine_cfg_monitor mon_h;
                mon_h = new(vif_i, cfg_i, sb, cov, i);
                eng_mon.push_back(mon_h);
            end
        endfunction

        // ---------------------------------------------------------------------
        // Start all continuous background components.
        // This is called once at time zero; components remain alive across the
        // whole regression and are naturally reset by the interface reset task.
        // ---------------------------------------------------------------------
        task automatic start_background();
            if (background_started)
                return;

            background_started = 1'b1;
            fork
                sink_drv.run();
                axi_mon.run();
                begin
                    for (int i = 0; i < eng_mon.size(); i++) begin
                        automatic int idx = i;
                        fork
                            eng_mon[idx].run();
                        join_none
                    end
                end
            join_none
        endtask

        // ---------------------------------------------------------------------
        // Reset the DUT and clear scoreboard observation queues.
        // ---------------------------------------------------------------------
        task automatic reset_dut();
            sink_drv.idle();
            sb.clear_observed();
            vif.reset_dut(cfg.nly);
        endtask

        // ---------------------------------------------------------------------
        // Execute one program end-to-end.
        // Normal tests call this with `expect_abort=0`. Reset-interruption tests
        // use `expect_abort=1` so the scoreboard does not compare partial data.
        // ---------------------------------------------------------------------
        task automatic run_program(
            input string test_name,
            cfg_program_item prog,
            input int reset_after_handshakes = -1,
            input bit expect_abort = 1'b0
        );
            sb.clear_observed();
            sink_drv.configure_program(prog);
            axi_drv.drive_program(prog, reset_after_handshakes);

            if (!expect_abort) begin
                sb.wait_for_done(test_name);
                // Give the wrapper + M10 datapath time to surface any final
                // registered writes after cfg_done. This is especially important
                // on short output-layer geometries where msg_done can precede the
                // last observed cfg_wr_valid pulse by several cycles.
                repeat (32) @(posedge vif.clk);
                sb.wait_for_quiesce();
                sb.compare_program(test_name, prog);
            end

            sink_drv.idle();
        endtask

        // ---------------------------------------------------------------------
        // Print the consolidated scoreboard + coverage footer.
        // ---------------------------------------------------------------------
        task automatic report_summary();
            sb.report_summary($sformatf("bnn_config_manager_uvm (%s)", cfg.sweep_name));
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Base test shell.
    // Derived or library-style tests reuse the same helper methods so stimulus
    // construction stays consistent across the suite.
    // -------------------------------------------------------------------------
    class cfg_base_test;
        cfg_env                       env;
        virtual cfg_mgr_bfm_if        vif;
        cfg_env_cfg                   cfg;

        function new(cfg_env env_i, virtual cfg_mgr_bfm_if vif_i, cfg_env_cfg cfg_i);
            env = env_i;
            vif = vif_i;
            cfg = cfg_i;
        endfunction

        task automatic reset_between_tests();
            env.reset_dut();
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Named test library.
    // This keeps each scenario as a separate task but reuses the same class
    // instance, which is lighter than creating twenty tiny derived objects.
    // -------------------------------------------------------------------------
    class cfg_test_lib extends cfg_base_test;

        function new(cfg_env env_i, virtual cfg_mgr_bfm_if vif_i, cfg_env_cfg cfg_i);
            super.new(env_i, vif_i, cfg_i);
        endfunction

        // ---------------------------------------------------------------------
        // Baseline legal SFC program.
        // ---------------------------------------------------------------------
        task automatic test_smoke_sfc();
            cfg_program_item prog;
            prog = new("test_smoke_sfc");
            prog.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_smoke_sfc", prog);
        endtask

        // ---------------------------------------------------------------------
        // Legal program with an extra output-layer threshold message.
        // This validates the tolerant-route path and the debug counter.
        // ---------------------------------------------------------------------
        task automatic test_legal_with_extra_t2();
            cfg_program_item prog;
            prog = new("test_legal_with_extra_t2");
            prog.build_legal_program(cfg, 1, 1'b1);
            env.run_program("test_legal_with_extra_t2", prog);
        endtask

        // ---------------------------------------------------------------------
        // EOS arrives on a trailer beat after the final message has already
        // completed. This targets the late-EOS ordering path.
        // ---------------------------------------------------------------------
        task automatic test_eos_late();
            cfg_program_item prog;
            prog = new("test_eos_late");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.eos_strategy = EOS_AFTER_TRAILER;
            env.run_program("test_eos_late", prog);
        endtask

        // ---------------------------------------------------------------------
        // EOS is asserted on the final beat of the final message.
        // ---------------------------------------------------------------------
        task automatic test_eos_with_final_message();
            cfg_program_item prog;
            prog = new("test_eos_with_final_message");
            prog.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_eos_with_final_message", prog);
        endtask

        // ---------------------------------------------------------------------
        // Two legal configurations separated by a full reset.
        // ---------------------------------------------------------------------
        task automatic test_back_to_back_configs();
            cfg_program_item prog_a;
            cfg_program_item prog_b;
            prog_a = new("test_back_to_back_configs_a");
            prog_a.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_back_to_back_configs_a", prog_a);
            reset_between_tests();
            prog_b = new("test_back_to_back_configs_b");
            prog_b.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_back_to_back_configs_b", prog_b);
        endtask

        // ---------------------------------------------------------------------
        // Layer decode sweep.
        // A compact confidence test that proves every legal layer ID reaches
        // the matching cfg port set.
        // ---------------------------------------------------------------------
        task automatic test_layer_id_decode_all();
            cfg_program_item prog;
            prog = new("test_layer_id_decode_all");
            for (int layer = 0; layer < cfg.nly; layer++) begin
                prog.append_weight_msg(cfg, $sformatf("layer%0d_weight", layer), layer);
                if (layer < (cfg.nly - 1))
                    prog.append_threshold_msg(cfg, $sformatf("layer%0d_thr", layer), layer);
            end
            env.run_program("test_layer_id_decode_all", prog);
        endtask

        // ---------------------------------------------------------------------
        // Contest-stress profile used by the sweep harness.
        // ---------------------------------------------------------------------
        task automatic test_contest_stress();
            cfg_program_item prog;
            prog = new("test_contest_stress");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.valid_prob_pct     = 80;
            prog.keep_hole_prob_pct = 5;
            prog.force_ready_stalls = 1'b1;
            prog.ready_prob_pct     = 65;
            env.run_program("test_contest_stress", prog);
        endtask

        // ---------------------------------------------------------------------
        // Lower-valid-rate stress.
        // ---------------------------------------------------------------------
        task automatic test_stress_low_valid();
            cfg_program_item prog;
            prog = new("test_stress_low_valid");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.valid_prob_pct     = 60;
            prog.force_ready_stalls = 1'b1;
            prog.ready_prob_pct     = 65;
            env.run_program("test_stress_low_valid", prog);
        endtask

        // ---------------------------------------------------------------------
        // Dense keep-hole stress for M7 integration.
        // ---------------------------------------------------------------------
        task automatic test_keep_holes_dense();
            cfg_program_item prog;
            prog = new("test_keep_holes_dense");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.keep_hole_prob_pct = 30;
            env.run_program("test_keep_holes_dense", prog);
        endtask

        // ---------------------------------------------------------------------
        // Long back-to-back legal stream under stress settings.
        // ---------------------------------------------------------------------
        task automatic test_b2b_no_idle();
            cfg_program_item prog;
            prog = new("test_b2b_no_idle");
            prog.build_legal_program(cfg, 16, 1'b0);
            prog.valid_prob_pct     = 80;
            prog.keep_hole_prob_pct = 5;
            prog.force_ready_stalls = 1'b1;
            prog.ready_prob_pct     = 65;
            env.run_program("test_b2b_no_idle", prog);
        endtask

        // ---------------------------------------------------------------------
        // Reset while still parsing the first header.
        // ---------------------------------------------------------------------
        task automatic test_reset_mid_header();
            cfg_program_item prog;
            prog = new("test_reset_mid_header");
            prog.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_reset_mid_header_abort", prog, 1, 1'b1);
            test_smoke_sfc();
        endtask

        // ---------------------------------------------------------------------
        // Reset during the first weight payload.
        // The handshake count is intentionally approximate because the goal is
        // recovery confidence, not exact byte placement.
        // ---------------------------------------------------------------------
        task automatic test_reset_mid_payload_w();
            cfg_program_item prog;
            prog = new("test_reset_mid_payload_w");
            prog.build_legal_program(cfg, 1, 1'b0);
            env.run_program("test_reset_mid_payload_w_abort",
                            prog,
                            (cfg.bus_bytes >= 8) ? 6 : 20,
                            1'b1);
            test_smoke_sfc();
        endtask

        // ---------------------------------------------------------------------
        // Reset during a threshold-only payload.
        // This isolates the M9 path from the larger legal program.
        // ---------------------------------------------------------------------
        task automatic test_reset_mid_payload_t();
            cfg_program_item prog;
            prog = new("test_reset_mid_payload_t");
            prog.append_threshold_msg(cfg, "only_t0", 0);
            env.run_program("test_reset_mid_payload_t_abort",
                            prog,
                            (cfg.bus_bytes >= 8) ? 2 : 10,
                            1'b1);
            test_smoke_sfc();
        endtask

        // ---------------------------------------------------------------------
        // Reset exactly when the final EOS beat is being handshaken.
        // ---------------------------------------------------------------------
        task automatic test_reset_during_eos_beat();
            cfg_program_item prog;
            axi_beat_t beats[$];
            prog = new("test_reset_during_eos_beat");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.pack_beats(cfg, beats);
            env.run_program("test_reset_during_eos_beat_abort", prog, beats.size(), 1'b1);
            test_smoke_sfc();
        endtask

        // ---------------------------------------------------------------------
        // Malformed message families.
        // ---------------------------------------------------------------------
        task automatic test_bad_msg_type();
            cfg_program_item prog;
            prog = new("test_bad_msg_type");
            prog.build_bad_msg_type_program(cfg);
            env.run_program("test_bad_msg_type", prog);
        endtask

        task automatic test_bad_layer_id();
            cfg_program_item prog;
            prog = new("test_bad_layer_id");
            prog.build_bad_layer_id_program(cfg);
            env.run_program("test_bad_layer_id", prog);
        endtask

        task automatic test_bad_bpn_zero();
            cfg_program_item prog;
            prog = new("test_bad_bpn_zero");
            prog.build_bad_bpn_zero_program(cfg);
            env.run_program("test_bad_bpn_zero", prog);
        endtask

        task automatic test_bad_total_bytes();
            cfg_program_item prog;
            prog = new("test_bad_total_bytes");
            prog.build_bad_total_bytes_program(cfg);
            env.run_program("test_bad_total_bytes", prog);
        endtask

        task automatic test_bad_nneur_zero();
            cfg_program_item prog;
            prog = new("test_bad_nneur_zero");
            prog.build_bad_nneur_zero_program(cfg);
            env.run_program("test_bad_nneur_zero", prog);
        endtask

        task automatic test_multiple_errors();
            cfg_program_item prog;
            prog = new("test_multiple_errors");
            prog.build_multiple_errors_program(cfg);
            env.run_program("test_multiple_errors", prog);
        endtask

        // ---------------------------------------------------------------------
        // Condition-closure test: empty-payload header with TLAST on the header.
        // This is a deliberate parser confidence test to hit the M8 empty-payload
        // `saw_last_r_q || byte_last` branch in PARSE_HEADER.
        // ---------------------------------------------------------------------
        task automatic test_empty_payload_header_last();
            cfg_program_item prog;
            prog = new("test_empty_payload_header_last");
            prog.append_threshold_msg(cfg,
                                      "empty_payload_header_last",
                                      0,
                                      -1,
                                      0,
                                      0,
                                      1'b0,
                                      1'b0);
            prog.expect_error = 1'b1;
            env.run_program("test_empty_payload_header_last", prog);
        endtask

        // ---------------------------------------------------------------------
        // Condition-closure test: inject TLAST in the middle of a payload.
        // The DUT is still required to finish based on `total_bytes`, but the
        // parser's sticky `saw_last_r_q` path now becomes observable.
        // ---------------------------------------------------------------------
        task automatic test_early_tlast_mid_payload();
            cfg_program_item prog;
            prog = new("test_early_tlast_mid_payload");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.early_last_beat_idx = (cfg.bus_bytes >= 8) ? 3 : 10;
            env.run_program("test_early_tlast_mid_payload", prog);
        endtask

        // ---------------------------------------------------------------------
        // Confidence test for M10 backpressure under a long initial sink stall.
        // This does not guarantee every M10-only condition row will close at the
        // integration level, but it deliberately exercises the longest available
        // cfg output hold path through the wrapper.
        // ---------------------------------------------------------------------
        task automatic test_long_cfg_sink_stall();
            cfg_program_item prog;
            prog = new("test_long_cfg_sink_stall");
            prog.build_legal_program(cfg, 1, 1'b0);
            prog.hold_ready_low_cycles = 64;
            prog.force_ready_stalls    = 1'b1;
            prog.ready_prob_pct        = 70;
            env.run_program("test_long_cfg_sink_stall", prog);
        endtask

        // ---------------------------------------------------------------------
        // Full regression order for the default run.
        // The condition-closure tests are included near the end so earlier
        // failures are easier to diagnose against the baseline suite first.
        // ---------------------------------------------------------------------
        task automatic run_full_suite();
            test_smoke_sfc();
            reset_between_tests();
            test_legal_with_extra_t2();
            reset_between_tests();
            test_eos_late();
            reset_between_tests();
            test_eos_with_final_message();
            reset_between_tests();
            test_back_to_back_configs();
            reset_between_tests();
            test_layer_id_decode_all();
            reset_between_tests();
            test_contest_stress();
            reset_between_tests();
            test_stress_low_valid();
            reset_between_tests();
            test_keep_holes_dense();
            reset_between_tests();
            test_b2b_no_idle();
            reset_between_tests();
            test_reset_mid_header();
            reset_between_tests();
            test_reset_mid_payload_w();
            reset_between_tests();
            test_reset_mid_payload_t();
            reset_between_tests();
            test_reset_during_eos_beat();
            reset_between_tests();
            test_bad_msg_type();
            reset_between_tests();
            test_bad_layer_id();
            reset_between_tests();
            test_bad_bpn_zero();
            reset_between_tests();
            test_bad_total_bytes();
            reset_between_tests();
            test_bad_nneur_zero();
            reset_between_tests();
            test_multiple_errors();
            reset_between_tests();
            test_empty_payload_header_last();
            reset_between_tests();
            test_early_tlast_mid_payload();
            reset_between_tests();
            test_long_cfg_sink_stall();
        endtask

        // ---------------------------------------------------------------------
        // Named-test dispatcher for `+TEST=...`.
        // ---------------------------------------------------------------------
        task automatic run_named(input string test_name);
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
            else if (test_name == "test_empty_payload_header_last") test_empty_payload_header_last();
            else if (test_name == "test_early_tlast_mid_payload") test_early_tlast_mid_payload();
            else if (test_name == "test_long_cfg_sink_stall") test_long_cfg_sink_stall();
            else $fatal(1, "Unknown +TEST=%s", test_name);
        endtask
    endclass

endpackage
