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

module tb_bnn_config_manager_uvm;

    import bnn_cfg_mgr_pkg::*;
    import bnn_cfg_mgr_uvm_pkg::*;

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
    initial $fatal(1, "tb_bnn_config_manager_uvm: unknown CFGM_SWxx profile");
`endif

    localparam int NLY       = TOTAL_LAYERS - 1;
    localparam int LID_W     = (NLY > 1) ? $clog2(NLY) : 1;
    localparam int MAX_PW    = 16;
    localparam int ACC_W     = 10;
    localparam int CLK_PERIOD = 10;

    // -------------------------------------------------------------------------
    // Clock and BFM interface.
    // The interface width is fixed to the Phase-4 maxima; the DUT connection
    // uses only the active low slices for the current profile.
    // -------------------------------------------------------------------------
    logic clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    cfg_mgr_bfm_if vif(clk);

    // -------------------------------------------------------------------------
    // Actual DUT-sized wires.
    // These are the only signals that connect directly to the RTL. The top then
    // mirrors them into the fixed-width interface for the class environment.
    // -------------------------------------------------------------------------
    logic                          config_ready_act;
    logic [NLY-1:0]                cfg_wr_valid_act;
    logic [NLY-1:0][LID_W-1:0]     cfg_wr_layer_act;
    logic [NLY-1:0][7:0]           cfg_wr_np_act;
    logic [NLY-1:0][15:0]          cfg_wr_addr_act;
    logic [NLY-1:0][MAX_PW-1:0]    cfg_wr_data_act;
    logic [NLY-1:0]                cfg_wr_last_word_act;
    logic [NLY-1:0]                cfg_wr_last_neuron_act;
    logic [NLY-1:0]                cfg_wr_last_msg_act;
    logic [NLY-1:0]                cfg_thr_valid_act;
    logic [NLY-1:0][LID_W-1:0]     cfg_thr_layer_act;
    logic [NLY-1:0][7:0]           cfg_thr_np_act;
    logic [NLY-1:0][15:0]          cfg_thr_addr_act;
    logic [NLY-1:0][31:0]          cfg_thr_data_act;
    logic                          cfg_done_act;
    logic                          cfg_error_act;
    logic [15:0]                   cfg_extra_t2_count_act;

    // -------------------------------------------------------------------------
    // DUT instantiation.
    // The class environment owns the input-side drivers through vif.
    // -------------------------------------------------------------------------
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
        .rst                (vif.rst),
        .config_valid       (vif.config_valid),
        .config_ready       (config_ready_act),
        .config_data        (vif.config_data[CONFIG_BUS_WIDTH-1:0]),
        .config_keep        (vif.config_keep[(CONFIG_BUS_WIDTH/8)-1:0]),
        .config_last        (vif.config_last),
        .cfg_wr_valid       (cfg_wr_valid_act),
        .cfg_wr_ready       (vif.cfg_wr_ready[NLY-1:0]),
        .cfg_wr_layer       (cfg_wr_layer_act),
        .cfg_wr_np          (cfg_wr_np_act),
        .cfg_wr_addr        (cfg_wr_addr_act),
        .cfg_wr_data        (cfg_wr_data_act),
        .cfg_wr_last_word   (cfg_wr_last_word_act),
        .cfg_wr_last_neuron (cfg_wr_last_neuron_act),
        .cfg_wr_last_msg    (cfg_wr_last_msg_act),
        .cfg_thr_valid      (cfg_thr_valid_act),
        .cfg_thr_ready      (vif.cfg_thr_ready[NLY-1:0]),
        .cfg_thr_layer      (cfg_thr_layer_act),
        .cfg_thr_np         (cfg_thr_np_act),
        .cfg_thr_addr       (cfg_thr_addr_act),
        .cfg_thr_data       (cfg_thr_data_act),
        .cfg_done           (cfg_done_act),
        .cfg_error          (cfg_error_act),
        .cfg_extra_t2_count (cfg_extra_t2_count_act)
    );

    // -------------------------------------------------------------------------
    // Review note:
    //   This centralizes all width adaptation in one place. Classes only ever
    //   look at `vif`, never directly at the DUT.
    // -------------------------------------------------------------------------
    always_comb begin
        vif.config_ready         = config_ready_act;
        vif.cfg_done             = cfg_done_act;
        vif.cfg_error            = cfg_error_act;
        vif.cfg_extra_t2_count   = cfg_extra_t2_count_act;

        vif.cfg_wr_valid         = '0;
        vif.cfg_wr_layer         = '0;
        vif.cfg_wr_np            = '0;
        vif.cfg_wr_addr          = '0;
        vif.cfg_wr_data          = '0;
        vif.cfg_wr_last_word     = '0;
        vif.cfg_wr_last_neuron   = '0;
        vif.cfg_wr_last_msg      = '0;

        vif.cfg_thr_valid        = '0;
        vif.cfg_thr_layer        = '0;
        vif.cfg_thr_np           = '0;
        vif.cfg_thr_addr         = '0;
        vif.cfg_thr_data         = '0;

        for (int i = 0; i < NLY; i++) begin
            vif.cfg_wr_valid[i]       = cfg_wr_valid_act[i];
            vif.cfg_wr_layer[i][LID_W-1:0] = cfg_wr_layer_act[i];
            vif.cfg_wr_np[i]          = cfg_wr_np_act[i];
            vif.cfg_wr_addr[i]        = cfg_wr_addr_act[i];
            vif.cfg_wr_data[i]        = cfg_wr_data_act[i];
            vif.cfg_wr_last_word[i]   = cfg_wr_last_word_act[i];
            vif.cfg_wr_last_neuron[i] = cfg_wr_last_neuron_act[i];
            vif.cfg_wr_last_msg[i]    = cfg_wr_last_msg_act[i];

            vif.cfg_thr_valid[i]      = cfg_thr_valid_act[i];
            vif.cfg_thr_layer[i][LID_W-1:0] = cfg_thr_layer_act[i];
            vif.cfg_thr_np[i]         = cfg_thr_np_act[i];
            vif.cfg_thr_addr[i]       = cfg_thr_addr_act[i];
            vif.cfg_thr_data[i]       = cfg_thr_data_act[i];
        end

        vif.hdr_valid            = DUT.hdr_valid;
        vif.hdr_msg_type         = DUT.hdr_msg_type;
        vif.hdr_layer_id         = DUT.hdr_layer_id;
        vif.hdr_layer_inputs     = DUT.hdr_layer_inputs;
        vif.hdr_num_neurons      = DUT.hdr_num_neurons;
        vif.hdr_bytes_per_neuron = DUT.hdr_bytes_per_neuron;
        vif.hdr_total_bytes      = DUT.hdr_total_bytes;
        vif.payload_valid        = DUT.payload_valid;
        vif.payload_ready        = DUT.payload_ready;
        vif.dbg_routing_state    = DUT.dbg_routing_state;
        vif.dbg_error_class      = DUT.dbg_error_class;
        vif.dbg_eos_strategy     = DUT.dbg_eos_strategy_r_q;
    end

    // -------------------------------------------------------------------------
    // These remain valuable even with the class-based environment because they
    // provide low-latency protocol and internal-state failures directly from
    // the simulator transcript.
    // -------------------------------------------------------------------------
    property p_cfg_valid_hold;
        @(posedge clk) disable iff (vif.rst)
        vif.config_valid && !vif.config_ready
        |=> vif.config_valid &&
            $stable(vif.config_data[CONFIG_BUS_WIDTH-1:0]) &&
            $stable(vif.config_keep[(CONFIG_BUS_WIDTH/8)-1:0]) &&
            $stable(vif.config_last);
    endproperty
    a_cfg_valid_hold: assert property (p_cfg_valid_hold)
        else $error("[SVA] config_valid dropped or payload changed under backpressure");

    property p_done_after_both_seen;
        @(posedge clk) disable iff (vif.rst)
        $rose(vif.cfg_done) |-> (DUT.eos_seen_r_q && DUT.msg_done_seen_r_q);
    endproperty
    a_done_after_both_seen: assert property (p_done_after_both_seen)
        else $error("[SVA] cfg_done rose before eos/msg_done were both observed");

    property p_thr_idx_in_bounds;
        @(posedge clk) disable iff (vif.rst)
        DUT.m9_thresh_valid_w |-> (DUT.thr_neuron_idx_r_q < DUT.cur_nneur_r_q);
    endproperty
    a_thr_idx_in_bounds: assert property (p_thr_idx_in_bounds)
        else $error("[SVA] threshold neuron index exceeded current num_neurons");

    property p_discard_stays_ready;
        @(posedge clk) disable iff (vif.rst)
        DUT.cur_msg_error_r_q && DUT.payload_valid |-> DUT.payload_ready;
    endproperty
    a_discard_stays_ready: assert property (p_discard_stays_ready)
        else $error("[SVA] payload_ready dropped during discard mode");

    // -------------------------------------------------------------------------
    // Environment objects.
    // These are created once after the profile arrays are copied into dynamic
    // arrays for the package classes.
    // -------------------------------------------------------------------------
    cfg_env_cfg  cfg_h;
    cfg_env      env_h;
    cfg_test_lib tests_h;

    initial begin
        int topo_dyn[$];
        int pn_dyn[$];
        string test_name;

        for (int i = 0; i < TOTAL_LAYERS; i++)
            topo_dyn.push_back(TOPOLOGY[i]);

        for (int i = 0; i < NLY; i++)
            pn_dyn.push_back(PARALLEL_NEURONS[i]);

        cfg_h = new(SWEEP_NAME,
                    CONFIG_BUS_WIDTH,
                    TOTAL_LAYERS,
                    LID_W,
                    PARALLEL_INPUTS,
                    ACC_W,
                    MAX_PW,
                    topo_dyn,
                    pn_dyn);
        env_h   = new(vif, cfg_h);
        tests_h = new(env_h, vif, cfg_h);

        $display("[TB] bnn_config_manager_uvm profile=%s BUS=%0d TOTAL_LAYERS=%0d",
                 SWEEP_NAME, CONFIG_BUS_WIDTH, TOTAL_LAYERS);

        env_h.start_background();
        env_h.reset_dut();

        if ($value$plusargs("TEST=%s", test_name))
            tests_h.run_named(test_name);
        else
            tests_h.run_full_suite();

        env_h.report_summary();

        if (env_h.sb.fail_count != 0)
            $fatal(1, "bnn_config_manager_uvm failed with %0d scoreboard error(s)", env_h.sb.fail_count);
        else
            $display("PASS : bnn_config_manager_uvm completed without scoreboard failures");

        $finish;
    end

endmodule
