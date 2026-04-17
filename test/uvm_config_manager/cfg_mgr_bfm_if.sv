`timescale 1ns/10ps

interface cfg_mgr_bfm_if(input logic clk);

    // -------------------------------------------------------------------------
    // Verification envelope.
    // These maxima come directly from the active config-manager sweep space.
    // -------------------------------------------------------------------------
    localparam int CFGM_MAX_BUS_WIDTH = 64;
    localparam int CFGM_MAX_BUS_BYTES = 8;
    localparam int CFGM_MAX_NLY       = 3;
    localparam int CFGM_MAX_LID_W     = 2;
    localparam int CFGM_MAX_NPID_W    = 8;
    localparam int CFGM_MAX_ADDR_W    = 16;
    localparam int CFGM_MAX_PW        = 16;

    // -------------------------------------------------------------------------
    // Primary DUT-facing config ingress.
    // The driver owns the input-side signals. The top module mirrors the DUT's
    // outputs back into this interface for passive components.
    // -------------------------------------------------------------------------
    logic                            rst;
    logic                            config_valid;
    logic [CFGM_MAX_BUS_WIDTH-1:0]   config_data;
    logic [CFGM_MAX_BUS_BYTES-1:0]   config_keep;
    logic                            config_last;
    logic                            config_ready;

    // -------------------------------------------------------------------------
    // Per-layer cfg write/threshold ports.
    // The sink driver owns *_ready. The top module mirrors the DUT outputs.
    // -------------------------------------------------------------------------
    logic [CFGM_MAX_NLY-1:0]                         cfg_wr_valid;
    logic [CFGM_MAX_NLY-1:0]                         cfg_wr_ready;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_LID_W-1:0]    cfg_wr_layer;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_NPID_W-1:0]   cfg_wr_np;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_ADDR_W-1:0]   cfg_wr_addr;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_PW-1:0]       cfg_wr_data;
    logic [CFGM_MAX_NLY-1:0]                         cfg_wr_last_word;
    logic [CFGM_MAX_NLY-1:0]                         cfg_wr_last_neuron;
    logic [CFGM_MAX_NLY-1:0]                         cfg_wr_last_msg;

    logic [CFGM_MAX_NLY-1:0]                         cfg_thr_valid;
    logic [CFGM_MAX_NLY-1:0]                         cfg_thr_ready;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_LID_W-1:0]    cfg_thr_layer;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_NPID_W-1:0]   cfg_thr_np;
    logic [CFGM_MAX_NLY-1:0][CFGM_MAX_ADDR_W-1:0]   cfg_thr_addr;
    logic [CFGM_MAX_NLY-1:0][31:0]                  cfg_thr_data;

    // -------------------------------------------------------------------------
    // High-level wrapper status mirrored from the DUT.
    // -------------------------------------------------------------------------
    logic                            cfg_done;
    logic                            cfg_error;
    logic [15:0]                     cfg_extra_t2_count;

    // -------------------------------------------------------------------------
    // Passive components sample these to avoid re-deriving wrapper state in
    // multiple places.
    // -------------------------------------------------------------------------
    logic                            hdr_valid;
    logic [7:0]                      hdr_msg_type;
    logic [7:0]                      hdr_layer_id;
    logic [15:0]                     hdr_layer_inputs;
    logic [15:0]                     hdr_num_neurons;
    logic [15:0]                     hdr_bytes_per_neuron;
    logic [31:0]                     hdr_total_bytes;
    logic                            payload_valid;
    logic                            payload_ready;
    logic [1:0]                      dbg_routing_state;
    logic [2:0]                      dbg_error_class;
    logic                            dbg_eos_strategy;

    // -------------------------------------------------------------------------
    // Clear all actively-driven ingress signals.
    // Review note:
    //   This is the "safe idle" state used before reset, between tests, and
    //   after the driver completes a program. Keeping it in one task prevents
    //   skew between driver resets and top-level reset sequencing.
    // -------------------------------------------------------------------------
    task automatic clear_input_drives();
        config_valid <= 1'b0;
        config_data  <= '0;
        config_keep  <= '0;
        config_last  <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Set the cfg write/threshold ready vectors to a uniform value.
    // Only the active layer count is driven; higher entries are cleared to zero
    // so stale values cannot leak between sweep profiles.
    // -------------------------------------------------------------------------
    task automatic set_all_ready(input int nly, input bit value);
        cfg_wr_ready  <= '0;
        cfg_thr_ready <= '0;
        for (int i = 0; i < nly; i++) begin
            cfg_wr_ready[i]  <= value;
            cfg_thr_ready[i] <= value;
        end
    endtask

    // -------------------------------------------------------------------------
    // Synchronous reset sequence for the UVM bench.
    // The task keeps the DUT idle, asserts reset for five cycles, then leaves a
    // short post-reset gap before stimulus begins.
    // -------------------------------------------------------------------------
    task automatic reset_dut(input int nly);
        rst <= 1'b1;
        clear_input_drives();
        set_all_ready(nly, 1'b1);
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

endinterface
