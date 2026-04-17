`timescale 1ns/10ps

`ifndef BNN_WEIGHT_UNPACKER_TB_P_W
`define BNN_WEIGHT_UNPACKER_TB_P_W 10
`endif
`ifndef BNN_WEIGHT_UNPACKER_TB_P_N
`define BNN_WEIGHT_UNPACKER_TB_P_N 3
`endif
`ifndef BNN_WEIGHT_UNPACKER_TB_ADDR_W
`define BNN_WEIGHT_UNPACKER_TB_ADDR_W 16
`endif
`ifndef BNN_WEIGHT_UNPACKER_TB_NPID_W
`define BNN_WEIGHT_UNPACKER_TB_NPID_W 8
`endif

interface bnn_weight_unpacker_bfm #(
    parameter int P_W    = `BNN_WEIGHT_UNPACKER_TB_P_W,
    parameter int P_N    = `BNN_WEIGHT_UNPACKER_TB_P_N,
    parameter int LID_W  = 4,
    parameter int NPID_W = `BNN_WEIGHT_UNPACKER_TB_NPID_W,
    parameter int ADDR_W = `BNN_WEIGHT_UNPACKER_TB_ADDR_W
)(
    input logic clk
);
    logic                  rst;
    logic [15:0]           cfg_fan_in;
    logic [15:0]           cfg_bytes_per_neuron;
    logic [15:0]           cfg_num_neurons;
    logic [LID_W-1:0]      cfg_layer_id;
    logic                  cfg_load;
    logic                  byte_valid;
    logic                  byte_ready;
    logic [7:0]            byte_data;
    logic                  wr_valid;
    logic                  wr_ready;
    logic [LID_W-1:0]      wr_layer;
    logic [NPID_W-1:0]     wr_np;
    logic [ADDR_W-1:0]     wr_addr;
    logic [P_W-1:0]        wr_data;
    logic                  wr_last_word;
    logic                  wr_last_neuron;
    logic                  wr_last_msg;

    task automatic clear_drives();
        cfg_fan_in           <= '0;
        cfg_bytes_per_neuron <= '0;
        cfg_num_neurons      <= '0;
        cfg_layer_id         <= '0;
        cfg_load             <= 1'b0;
        byte_valid           <= 1'b0;
        byte_data            <= '0;
        wr_ready             <= 1'b0;
    endtask

    task automatic reset_dut(int cycles = 5);
        rst <= 1'b1;
        clear_drives();
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask
endinterface

module bnn_weight_unpacker_tb;

    //
    // Main DUT Parameters
    //
    parameter int P_W    = `BNN_WEIGHT_UNPACKER_TB_P_W;
    parameter int P_N    = `BNN_WEIGHT_UNPACKER_TB_P_N;
    parameter int LID_W  = 4;
    parameter int NPID_W = `BNN_WEIGHT_UNPACKER_TB_NPID_W;
    parameter int ADDR_W = `BNN_WEIGHT_UNPACKER_TB_ADDR_W;

    localparam int ACCUM_W = P_W + 8;
    localparam int BIA_W   = $clog2(ACCUM_W + 1);
    localparam int MAX_RANDOM_FAN_IN = (3 * P_W) + 3;
    localparam int MAX_RANDOM_NEURONS = (2 * P_N) + 1;

    typedef struct packed {
        logic [LID_W-1:0]  layer;
        logic [NPID_W-1:0] np;
        logic [ADDR_W-1:0] addr;
        logic [P_W-1:0]    data;
        logic              last_word;
        logic              last_neuron;
        logic              last_msg;
    } beat_t;

    //
    // Clock / Interface / DUT
    //
    logic clk = 0;
    always #5 clk = ~clk;

    bnn_weight_unpacker_bfm #(
        .P_W    (P_W),
        .P_N    (P_N),
        .LID_W  (LID_W),
        .NPID_W (NPID_W),
        .ADDR_W (ADDR_W)
    ) bfm (clk);

    bnn_weight_unpacker #(
        .P_W    (P_W),
        .P_N    (P_N),
        .LID_W  (LID_W),
        .NPID_W (NPID_W),
        .ADDR_W (ADDR_W)
    ) DUT (
        .clk                (clk),
        .rst                (bfm.rst),
        .cfg_fan_in         (bfm.cfg_fan_in),
        .cfg_bytes_per_neuron(bfm.cfg_bytes_per_neuron),
        .cfg_num_neurons    (bfm.cfg_num_neurons),
        .cfg_layer_id       (bfm.cfg_layer_id),
        .cfg_load           (bfm.cfg_load),
        .byte_valid         (bfm.byte_valid),
        .byte_ready         (bfm.byte_ready),
        .byte_data          (bfm.byte_data),
        .wr_valid           (bfm.wr_valid),
        .wr_ready           (bfm.wr_ready),
        .wr_layer           (bfm.wr_layer),
        .wr_np              (bfm.wr_np),
        .wr_addr            (bfm.wr_addr),
        .wr_data            (bfm.wr_data),
        .wr_last_word       (bfm.wr_last_word),
        .wr_last_neuron     (bfm.wr_last_neuron),
        .wr_last_msg        (bfm.wr_last_msg)
    );

    //
    // Transaction / Response Classes
    //
    class m10_msg_item;
        rand int unsigned    fan_in;
        rand int unsigned    num_neurons;
        rand logic [LID_W-1:0] layer_id;
        rand int unsigned    valid_prob_pct;
        rand int unsigned    ready_prob_pct;

        int                  id;
        string               name;
        int                  bytes_per_neuron;
        int                  words_per_neuron;
        logic [7:0]          byte_q[$];
        beat_t               exp_beats[$];

        constraint c_fan_in {
            fan_in inside {[1:MAX_RANDOM_FAN_IN]};
            fan_in dist {
                [1:P_W-1]             := 4,
                P_W                   := 2,
                [P_W+1:(2*P_W)-1]     := 4,
                [(2*P_W):(3*P_W)+3]   := 3
            };
        }

        constraint c_num_neurons {
            num_neurons inside {[1:MAX_RANDOM_NEURONS]};
            num_neurons dist {
                1                     := 2,
                [2:P_N]               := 3,
                [P_N+1:MAX_RANDOM_NEURONS] := 3
            };
        }

        constraint c_layer {
            layer_id inside {[0:(1<<LID_W)-1]};
        }

        constraint c_probs {
            valid_prob_pct inside {[60:100]};
            ready_prob_pct inside {[40:100]};
        }

        function new();
            id = -1;
            name = "";
        endfunction

        function void build_directed(
            input int id_i,
            input string name_i,
            input int unsigned fan_in_i,
            input int unsigned num_neurons_i,
            input logic [LID_W-1:0] layer_i,
            input int unsigned valid_prob_i = 100,
            input int unsigned ready_prob_i = 100
        );
            id             = id_i;
            name           = name_i;
            fan_in         = fan_in_i;
            num_neurons    = num_neurons_i;
            layer_id       = layer_i;
            valid_prob_pct = valid_prob_i;
            ready_prob_pct = ready_prob_i;
            build_payload();
        endfunction

        function void build_random(
            input int id_i,
            input string prefix = "rand"
        );
            id = id_i;
            if (!randomize())
                $fatal(1, "[GEN] randomize() failed for item %0d", id_i);
            name = $sformatf("%s_%0d", prefix, id_i);
            build_payload();
        endfunction

        function void build_payload();
            byte_q = {};
            exp_beats = {};

            bytes_per_neuron = (fan_in + 7) / 8;
            words_per_neuron = (fan_in + P_W - 1) / P_W;

            for (int neuron = 0; neuron < int'(num_neurons); neuron++) begin
                bit neuron_bits[];
                neuron_bits = new[fan_in];

                for (int bit_idx = 0; bit_idx < int'(fan_in); bit_idx++)
                    neuron_bits[bit_idx] = $urandom_range(0, 1);

                for (int byte_idx = 0; byte_idx < bytes_per_neuron; byte_idx++) begin
                    logic [7:0] packed_byte;
                    packed_byte = '0;
                    for (int bit_in_byte = 0; bit_in_byte < 8; bit_in_byte++) begin
                        int src_bit;
                        src_bit = (byte_idx * 8) + bit_in_byte;
                        if (src_bit < int'(fan_in))
                            packed_byte[bit_in_byte] = neuron_bits[src_bit];
                        else
                            packed_byte[bit_in_byte] = 1'b1;
                    end
                    byte_q.push_back(packed_byte);
                end

                for (int word_idx = 0; word_idx < words_per_neuron; word_idx++) begin
                    beat_t exp;
                    exp = '0;
                    exp.layer = layer_id;
                    exp.np    = NPID_W'(neuron % P_N);
                    exp.addr  = ADDR_W'(((neuron / P_N) * words_per_neuron) + word_idx);
                    exp.last_word   = (word_idx == (words_per_neuron - 1));
                    exp.last_neuron = exp.last_word && (neuron == (int'(num_neurons) - 1));
                    exp.last_msg    = exp.last_neuron;

                    for (int bit_pos = 0; bit_pos < P_W; bit_pos++) begin
                        int src_bit;
                        src_bit = (word_idx * P_W) + bit_pos;
                        if (src_bit < int'(fan_in))
                            exp.data[bit_pos] = neuron_bits[src_bit];
                        else
                            exp.data[bit_pos] = 1'b1;
                    end

                    exp_beats.push_back(exp);
                end
            end
        endfunction

        function m10_msg_item copy();
            m10_msg_item cpy;
            cpy = new();
            cpy.id               = id;
            cpy.name             = name;
            cpy.fan_in           = fan_in;
            cpy.num_neurons      = num_neurons;
            cpy.layer_id         = layer_id;
            cpy.valid_prob_pct   = valid_prob_pct;
            cpy.ready_prob_pct   = ready_prob_pct;
            cpy.bytes_per_neuron = bytes_per_neuron;
            cpy.words_per_neuron = words_per_neuron;
            cpy.byte_q           = byte_q;
            cpy.exp_beats        = exp_beats;
            return cpy;
        endfunction

        function string sprint();
            return $sformatf("id=%0d name=%s layer=%0d fan_in=%0d bpn=%0d wpn=%0d nneur=%0d valid_prob=%0d ready_prob=%0d exp_beats=%0d",
                             id, name, layer_id, fan_in, bytes_per_neuron,
                             words_per_neuron, num_neurons, valid_prob_pct,
                             ready_prob_pct, exp_beats.size());
        endfunction
    endclass

    class m10_rsp_item;
        int    id;
        string name;
        beat_t beats[$];

        function new();
            id = -1;
            name = "";
        endfunction
    endclass

    //
    // Generator
    //
    class m10_generator;
        mailbox #(m10_msg_item) drv_mbx;
        event                   drv_done;

        function new(mailbox #(m10_msg_item) drv_mbx_i, event drv_done_i);
            drv_mbx  = drv_mbx_i;
            drv_done = drv_done_i;
        endfunction

        task automatic send_item(m10_msg_item item);
            drv_mbx.put(item);
            @(drv_done);
        endtask

        task run();
            m10_msg_item item;
            int next_id;

            next_id = 0;

            item = new();
            item.build_directed(next_id++, "single_word_pad_emit", P_W - 3, 1, LID_W'(0), 100, 100);
            send_item(item);

            item = new();
            item.build_directed(next_id++, "multi_neuron_exact_boundary", P_W, P_N + 2, LID_W'(1), 100, 100);
            send_item(item);

            item = new();
            item.build_directed(next_id++, "two_words_exact", 2 * P_W, 3, LID_W'(2), 100, 100);
            send_item(item);

            item = new();
            item.build_directed(next_id++, "three_words_tail_pad", (2 * P_W) + 3, 1, LID_W'(3), 100, 100);
            send_item(item);

            item = new();
            item.build_directed(next_id++, "np_wrap_and_local_addr", P_W + 5, (2 * P_N) + 1, LID_W'(0), 100, 100);
            send_item(item);

            item = new();
            item.build_directed(next_id++, "gaps_and_backpressure", (2 * P_W) + 3, P_N + 3, LID_W'(2), 80, 50);
            send_item(item);

            for (int i = 0; i < 40; i++) begin
                item = new();
                item.build_random(next_id++);
                send_item(item);
            end

            drv_mbx.put(null);
        endtask
    endclass

    //
    // Driver
    //
    class m10_driver;
        virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif;
        mailbox #(m10_msg_item) drv_mbx;
        mailbox #(m10_msg_item) exp_mbx;
        event                   drv_done;

        function new(
            virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif_i,
            mailbox #(m10_msg_item) drv_mbx_i,
            mailbox #(m10_msg_item) exp_mbx_i,
            event drv_done_i
        );
            vif      = vif_i;
            drv_mbx  = drv_mbx_i;
            exp_mbx  = exp_mbx_i;
            drv_done = drv_done_i;
        endfunction

        function automatic bit chance(input int unsigned pct);
            return ($urandom_range(0, 99) < int'(pct));
        endfunction

        task automatic pulse_cfg(m10_msg_item item);
            @(posedge vif.clk);
            vif.cfg_fan_in           <= 16'(item.fan_in);
            vif.cfg_bytes_per_neuron <= 16'(item.bytes_per_neuron);
            vif.cfg_num_neurons      <= 16'(item.num_neurons);
            vif.cfg_layer_id         <= item.layer_id;
            vif.cfg_load             <= 1'b1;
            vif.byte_valid           <= 1'b0;
            vif.byte_data            <= '0;
            vif.wr_ready             <= chance(item.ready_prob_pct);

            @(posedge vif.clk);
            vif.cfg_load <= 1'b0;
        endtask

        task automatic drive_payload(m10_msg_item item);
            int byte_idx;
            int wait_cycles;

            byte_idx = 0;
            wait_cycles = 0;

            while (byte_idx < item.byte_q.size()) begin
                @(posedge vif.clk);

                if (vif.byte_valid && vif.byte_ready)
                    byte_idx++;

                vif.cfg_load  <= 1'b0;
                vif.wr_ready  <= chance(item.ready_prob_pct);

                if (byte_idx < item.byte_q.size()) begin
                    if ((vif.byte_valid && !vif.byte_ready) || chance(item.valid_prob_pct)) begin
                        vif.byte_valid <= 1'b1;
                        vif.byte_data  <= item.byte_q[byte_idx];
                    end else begin
                        vif.byte_valid <= 1'b0;
                    end
                end else begin
                    vif.byte_valid <= 1'b0;
                    vif.byte_data  <= '0;
                end

                wait_cycles++;
                if (wait_cycles > 50000) begin
                    $fatal(1, "[DRV] Timeout while sending payload for %s", item.sprint());
                end
            end

            @(posedge vif.clk);
            vif.byte_valid <= 1'b0;
            vif.byte_data  <= '0;
        endtask

        task automatic wait_for_last_msg(m10_msg_item item);
            int wait_cycles;
            bit seen_last;

            wait_cycles = 0;
            seen_last   = 1'b0;

            while (!seen_last) begin
                @(posedge vif.clk);

                if (vif.wr_valid && vif.wr_ready && vif.wr_last_msg)
                    seen_last = 1'b1;

                vif.byte_valid <= 1'b0;
                vif.cfg_load   <= 1'b0;
                vif.wr_ready   <= chance(item.ready_prob_pct);

                wait_cycles++;
                if (wait_cycles > 50000) begin
                    $fatal(1, "[DRV] Timeout waiting for wr_last_msg for %s", item.sprint());
                end
            end

            @(posedge vif.clk);
            vif.wr_ready <= 1'b0;
        endtask

        task automatic drive_one(m10_msg_item item);
            $display("[DRV] %s", item.sprint());
            pulse_cfg(item);
            drive_payload(item);
            wait_for_last_msg(item);
            exp_mbx.put(item.copy());
        endtask

        task run();
            forever begin
                m10_msg_item item;

                drv_mbx.get(item);
                if (item == null) begin
                    exp_mbx.put(null);
                    ->drv_done;
                    break;
                end

                drive_one(item);
                ->drv_done;
            end
        endtask
    endclass

    //
    // Output Monitor
    //
    class m10_output_monitor;
        virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif;
        mailbox #(m10_rsp_item) rsp_mbx;

        function new(
            virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif_i,
            mailbox #(m10_rsp_item) rsp_mbx_i
        );
            vif     = vif_i;
            rsp_mbx = rsp_mbx_i;
        endfunction

        task run();
            m10_rsp_item rsp;

            rsp = new();
            forever begin
                @(posedge vif.clk);

                if (vif.rst) begin
                    rsp = new();
                end else if (vif.wr_valid && vif.wr_ready) begin
                    beat_t beat;
                    beat = '0;
                    beat.layer       = vif.wr_layer;
                    beat.np          = vif.wr_np;
                    beat.addr        = vif.wr_addr;
                    beat.data        = vif.wr_data;
                    beat.last_word   = vif.wr_last_word;
                    beat.last_neuron = vif.wr_last_neuron;
                    beat.last_msg    = vif.wr_last_msg;
                    rsp.beats.push_back(beat);

                    if (vif.wr_last_msg) begin
                        rsp_mbx.put(rsp);
                        rsp = new();
                    end
                end
            end
        endtask
    endclass

    //
    // Scoreboard
    //
    class m10_scoreboard;
        mailbox #(m10_msg_item) exp_mbx;
        mailbox #(m10_rsp_item) rsp_mbx;
        int                     pass_count;
        int                     fail_count;
        int                     msg_count;
        string                  fail_log[$];

        function new(
            mailbox #(m10_msg_item) exp_mbx_i,
            mailbox #(m10_rsp_item) rsp_mbx_i
        );
            exp_mbx = exp_mbx_i;
            rsp_mbx = rsp_mbx_i;
            pass_count = 0;
            fail_count = 0;
            msg_count  = 0;
        endfunction

        function automatic void check(string label, logic cond, string msg = "");
            if (cond) begin
                pass_count++;
            end else begin
                fail_count++;
                fail_log.push_back($sformatf("[FAIL] %s: %s", label, msg));
                $error("[SB] %s: %s", label, msg);
            end
        endfunction

        task automatic compare_item(m10_msg_item exp, m10_rsp_item act);
            int min_beats;

            msg_count++;
            check($sformatf("%s_rsp_nonempty", exp.name),
                  act.beats.size() > 0,
                  "no output beats observed");

            check($sformatf("%s_beat_count", exp.name),
                  act.beats.size() == exp.exp_beats.size(),
                  $sformatf("expected %0d beats got %0d",
                            exp.exp_beats.size(), act.beats.size()));

            min_beats = (act.beats.size() < exp.exp_beats.size()) ?
                        act.beats.size() : exp.exp_beats.size();

            for (int i = 0; i < min_beats; i++) begin
                check($sformatf("%s_data_%0d", exp.name, i),
                      act.beats[i].data === exp.exp_beats[i].data,
                      $sformatf("exp=0x%0h got=0x%0h",
                                exp.exp_beats[i].data, act.beats[i].data));
                check($sformatf("%s_layer_%0d", exp.name, i),
                      act.beats[i].layer === exp.exp_beats[i].layer,
                      $sformatf("exp=%0d got=%0d",
                                exp.exp_beats[i].layer, act.beats[i].layer));
                check($sformatf("%s_np_%0d", exp.name, i),
                      act.beats[i].np === exp.exp_beats[i].np,
                      $sformatf("exp=%0d got=%0d",
                                exp.exp_beats[i].np, act.beats[i].np));
                check($sformatf("%s_addr_%0d", exp.name, i),
                      act.beats[i].addr === exp.exp_beats[i].addr,
                      $sformatf("exp=%0d got=%0d",
                                exp.exp_beats[i].addr, act.beats[i].addr));
                check($sformatf("%s_last_word_%0d", exp.name, i),
                      act.beats[i].last_word === exp.exp_beats[i].last_word,
                      $sformatf("exp=%0b got=%0b",
                                exp.exp_beats[i].last_word, act.beats[i].last_word));
                check($sformatf("%s_last_neuron_%0d", exp.name, i),
                      act.beats[i].last_neuron === exp.exp_beats[i].last_neuron,
                      $sformatf("exp=%0b got=%0b",
                                exp.exp_beats[i].last_neuron, act.beats[i].last_neuron));
                check($sformatf("%s_last_msg_%0d", exp.name, i),
                      act.beats[i].last_msg === exp.exp_beats[i].last_msg,
                      $sformatf("exp=%0b got=%0b",
                                exp.exp_beats[i].last_msg, act.beats[i].last_msg));
            end
        endtask

        task run();
            forever begin
                m10_msg_item exp;
                m10_rsp_item act;

                exp_mbx.get(exp);
                if (exp == null)
                    break;

                rsp_mbx.get(act);
                compare_item(exp, act);
            end
        endtask

        function void report_status();
            $display("============================================================");
            $display("[SB] Messages checked : %0d", msg_count);
            $display("[SB] Checks passed    : %0d", pass_count);
            $display("[SB] Checks failed    : %0d", fail_count);
            if (fail_count != 0) begin
                foreach (fail_log[idx])
                    $display("%s", fail_log[idx]);
            end
            $display("============================================================");
        endfunction
    endclass

    //
    // Environment / Test
    //
    class m10_env;
        m10_generator      gen;
        m10_driver         drv;
        m10_output_monitor mon;
        m10_scoreboard     sb;

        mailbox #(m10_msg_item) drv_mbx;
        mailbox #(m10_msg_item) exp_mbx;
        mailbox #(m10_rsp_item) rsp_mbx;
        event                   drv_done;

        virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif;

        function new(
            virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif_i
        );
            vif     = vif_i;
            drv_mbx = new();
            exp_mbx = new();
            rsp_mbx = new();

            gen = new(drv_mbx, drv_done);
            drv = new(vif, drv_mbx, exp_mbx, drv_done);
            mon = new(vif, rsp_mbx);
            sb  = new(exp_mbx, rsp_mbx);
        endfunction

        task run();
            fork
                gen.run();
                drv.run();
                mon.run();
                sb.run();
            join_any
            disable fork;
            sb.report_status();
        endtask
    endclass

    class m10_base_test;
        virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif;
        m10_env e;

        function new(
            virtual bnn_weight_unpacker_bfm #(P_W, P_N, LID_W, NPID_W, ADDR_W) vif_i
        );
            vif = vif_i;
            e   = new(vif_i);
        endfunction

        task run();
            vif.reset_dut(5);
            e.run();
        endtask
    endclass

    //
    // SVA (Gray Box)
    //

    //
    // SVA-1: Output valid must hold until consumed.
    //
    property p_wr_valid_hold;
        @(posedge clk) disable iff (bfm.rst)
        (bfm.wr_valid && !bfm.wr_ready) |=> bfm.wr_valid;
    endproperty
    assert property (p_wr_valid_hold)
    else $error("[SVA] wr_valid dropped before wr_ready");

    //
    // SVA-2: Full output payload must remain stable during backpressure.
    //
    property p_wr_payload_stable;
        @(posedge clk) disable iff (bfm.rst)
        (bfm.wr_valid && !bfm.wr_ready) |=> $stable({
            bfm.wr_layer,
            bfm.wr_np,
            bfm.wr_addr,
            bfm.wr_data,
            bfm.wr_last_word,
            bfm.wr_last_neuron,
            bfm.wr_last_msg
        });
    endproperty
    assert property (p_wr_payload_stable)
    else $error("[SVA] Output payload changed during backpressure");

    //
    // SVA-3: byte_ready is qualified by ACCUMULATE state exactly as documented.
    //
    property p_byte_ready_qualified;
        @(posedge clk) disable iff (bfm.rst)
        (DUT.u_ctrl.state_r == DUT.u_ctrl.ACCUMULATE) |->
            (bfm.byte_ready == (~bfm.wr_valid || bfm.wr_ready));
    endproperty
    assert property (p_byte_ready_qualified)
    else $error("[SVA] byte_ready mismatch in ACCUMULATE state");

    //
    // SVA-4: byte_ready must be low outside ACCUMULATE.
    //
    property p_byte_ready_only_in_accumulate;
        @(posedge clk) disable iff (bfm.rst)
        (DUT.u_ctrl.state_r != DUT.u_ctrl.ACCUMULATE) |-> !bfm.byte_ready;
    endproperty
    assert property (p_byte_ready_only_in_accumulate)
    else $error("[SVA] byte_ready asserted outside ACCUMULATE");

    //
    // SVA-5: bits_in counter must remain within accumulator capacity.
    //
    property p_bits_in_bounded;
        @(posedge clk) disable iff (bfm.rst)
        DUT.u_dp.bits_in_r_q <= BIA_W'(ACCUM_W);
    endproperty
    assert property (p_bits_in_bounded)
    else $error("[SVA] bits_in_r_q overflowed ACCUM_W");

    //
    // SVA-6: txn_we must produce a valid output beat on the next cycle.
    //
    property p_txn_we_drives_wr_valid;
        @(posedge clk) disable iff (bfm.rst)
        DUT.txn_we |=> bfm.wr_valid;
    endproperty
    assert property (p_txn_we_drives_wr_valid)
    else $error("[SVA] txn_we failed to raise wr_valid");

    //
    // SVA-7: wr_last_msg implies wr_last_word and wr_last_neuron.
    //
    property p_last_msg_implies_terminal_flags;
        @(posedge clk) disable iff (bfm.rst)
        (bfm.wr_valid && bfm.wr_last_msg) |-> (bfm.wr_last_word && bfm.wr_last_neuron);
    endproperty
    assert property (p_last_msg_implies_terminal_flags)
    else $error("[SVA] wr_last_msg asserted without terminal flags");

    //
    // SVA-8: No unknown output payload when wr_valid is asserted.
    //
    property p_no_unknown_output;
        @(posedge clk) disable iff (bfm.rst)
        bfm.wr_valid |-> !$isunknown({
            bfm.wr_layer,
            bfm.wr_np,
            bfm.wr_addr,
            bfm.wr_data,
            bfm.wr_last_word,
            bfm.wr_last_neuron,
            bfm.wr_last_msg
        });
    endproperty
    assert property (p_no_unknown_output)
    else $error("[SVA] Unknown output payload while wr_valid=1");

    //
    // Functional Coverage
    //
    covergroup cg_m10 @(posedge clk iff (!bfm.rst));
        option.per_instance = 1;

        cp_state: coverpoint DUT.u_ctrl.state_r {
            bins idle_s       = {DUT.u_ctrl.IDLE};
            bins accumulate_s = {DUT.u_ctrl.ACCUMULATE};
            bins emit_s       = {DUT.u_ctrl.EMIT};
            bins pad_emit_s   = {DUT.u_ctrl.PAD_EMIT};
        }

        cp_cfg_load: coverpoint bfm.cfg_load {
            bins pulse = {1'b1};
        }

        cp_bits_in: coverpoint DUT.u_dp.bits_in_r_q {
            bins zero_v    = {0};
            bins partial_v = {[1:P_W-1]};
            bins emit_v    = {[P_W:ACCUM_W]};
        }

        cp_byte_handshake: coverpoint {bfm.byte_valid, bfm.byte_ready} {
            bins idle_v     = {2'b00};
            bins wait_v     = {2'b10};
            bins transfer_v = {2'b11};
        }

        cp_wr_backpressure: coverpoint {bfm.wr_valid, bfm.wr_ready} {
            bins stall_v = {2'b10};
            bins flow_v  = {2'b11};
        }

        cp_wr_np: coverpoint bfm.wr_np iff (bfm.wr_valid && bfm.wr_ready) {
            bins np0 = {0};
            bins np1 = {1};
            bins np2 = {2};
        }

        cp_wr_layer: coverpoint bfm.wr_layer iff (bfm.wr_valid && bfm.wr_ready) {
            bins layer0 = {0};
            bins layer1 = {1};
            bins layer2 = {2};
            bins layer3 = {3};
        }

        cp_wr_addr: coverpoint bfm.wr_addr iff (bfm.wr_valid && bfm.wr_ready) {
            bins zero_v    = {0};
            bins nonzero_v = {[1:(1<<ADDR_W)-1]};
        }

        cp_last_word: coverpoint bfm.wr_last_word iff (bfm.wr_valid && bfm.wr_ready) {
            bins mid_v  = {1'b0};
            bins last_v = {1'b1};
        }

        cp_last_msg: coverpoint bfm.wr_last_msg iff (bfm.wr_valid && bfm.wr_ready) {
            bins not_final_v = {1'b0};
            bins final_v     = {1'b1};
        }
    endgroup

    cg_m10 cg_inst = new();

    //
    // Top-Level Control
    //
    m10_base_test test;

    initial begin
        real cov_pct;

        $timeformat(-9, 0, " ns");
        test = new(bfm);

        fork
            begin
                test.run();

                cov_pct = cg_inst.get_coverage();
                $display("[COV] cg_m10 functional coverage = %0.2f%%", cov_pct);

                if (test.e.sb.fail_count != 0)
                    $fatal(1, "[TB] Scoreboard reported %0d failures", test.e.sb.fail_count);

                if (cov_pct < 100.0)
                    $fatal(1, "[TB] Functional coverage below target: %0.2f%%", cov_pct);

                $display("[PASS] bnn_weight_unpacker_tb completed cleanly");
                $finish;
            end

            begin
                repeat (250000) @(posedge clk);
                $fatal(1, "[TB] Global timeout");
            end
        join_any

        disable fork;
    end

endmodule
