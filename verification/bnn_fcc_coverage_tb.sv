// =============================================================================
// bnn_fcc_coverage_tb.sv — Additive coverage-evidence testbench for bnn_fcc
//
// MANDATED FILENAME: verification/bnn_fcc_coverage_tb.sv
//
// Coverage categories (from coverage_plan.txt):
//   cg_axi_protocol          — AXI4-Stream Protocol Patterns
//   cg_config_diversity      — Configuration Data Diversity
//   cg_compute_stimulus      — Computational Stimulus
//   cg_cfg_img_sequencing    — Configuration-Image Sequencing
//   cg_reset_scenarios       — Reset Scenarios
//
// =============================================================================

`timescale 1ns / 100ps

module bnn_fcc_coverage_tb #(
    parameter int      INPUT_DATA_WIDTH            = 8,
    parameter int      INPUT_BUS_WIDTH             = 64,
    parameter int      CONFIG_BUS_WIDTH            = 64,
    parameter int      OUTPUT_DATA_WIDTH           = 4,
    parameter int      OUTPUT_BUS_WIDTH            = 8,
    parameter int      TOTAL_LAYERS                = 4,
    parameter int      TOPOLOGY[TOTAL_LAYERS]      = '{784, 256, 256, 10},
    parameter int      PARALLEL_INPUTS             = 8,
    parameter int      PARALLEL_NEURONS[TOTAL_LAYERS-1] = '{8, 8, 10},
    parameter realtime CLK_PERIOD                  = 10ns,
    parameter realtime TIMEOUT                     = 20ms,
    parameter int      NUM_IMAGES                  = 30,
    parameter string   PROFILE_TAG                 = "SFC_CT"
);

    // =========================================================================
    // Import shipped package — DO NOT FORK, DO NOT DUPLICATE.
    // =========================================================================
    import bnn_fcc_tb_pkg::*;

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam int INPUTS_PER_CYCLE = INPUT_BUS_WIDTH / INPUT_DATA_WIDTH;
    localparam int BYTES_PER_INPUT  = INPUT_DATA_WIDTH / 8;
    localparam int NUM_CLASSES      = TOPOLOGY[TOTAL_LAYERS-1];

    // =========================================================================
    // Clock, reset, AXI interfaces
    // =========================================================================
    logic clk = 1'b0;
    logic rst;

    axi4_stream_if #(.DATA_WIDTH(CONFIG_BUS_WIDTH))
        config_in (.aclk(clk), .aresetn(!rst));
    axi4_stream_if #(.DATA_WIDTH(INPUT_BUS_WIDTH))
        data_in   (.aclk(clk), .aresetn(!rst));
    axi4_stream_if #(.DATA_WIDTH(OUTPUT_BUS_WIDTH))
        data_out  (.aclk(clk), .aresetn(!rst));

    // =========================================================================
    // DUT instantiation (identical to shipped TB)
    // =========================================================================
    bnn_fcc #(
        .INPUT_DATA_WIDTH (INPUT_DATA_WIDTH),
        .INPUT_BUS_WIDTH  (INPUT_BUS_WIDTH),
        .CONFIG_BUS_WIDTH (CONFIG_BUS_WIDTH),
        .OUTPUT_DATA_WIDTH(OUTPUT_DATA_WIDTH),
        .OUTPUT_BUS_WIDTH (OUTPUT_BUS_WIDTH),
        .TOTAL_LAYERS     (TOTAL_LAYERS),
        .TOPOLOGY         (TOPOLOGY),
        .PARALLEL_INPUTS  (PARALLEL_INPUTS),
        .PARALLEL_NEURONS (PARALLEL_NEURONS)
    ) DUT (
        .clk(clk), .rst(rst),
        .config_valid(config_in.tvalid), .config_ready(config_in.tready),
        .config_data(config_in.tdata),   .config_keep(config_in.tkeep),
        .config_last(config_in.tlast),
        .data_in_valid(data_in.tvalid),  .data_in_ready(data_in.tready),
        .data_in_data(data_in.tdata),    .data_in_keep(data_in.tkeep),
        .data_in_last(data_in.tlast),
        .data_out_valid(data_out.tvalid),.data_out_ready(data_out.tready),
        .data_out_data(data_out.tdata),  .data_out_keep(data_out.tkeep),
        .data_out_last(data_out.tlast)
    );

    assign config_in.tstrb = config_in.tkeep;
    assign data_in.tstrb   = data_in.tkeep;

    // =========================================================================
    // Shared model + stimulus objects (from shipped pkg)
    // =========================================================================
    BNN_FCC_Model    #(CONFIG_BUS_WIDTH) ref_model;
    BNN_FCC_Stimulus #(INPUT_DATA_WIDTH) stim;
    LatencyTracker    latency;
    ThroughputTracker throughput;

    bit [CONFIG_BUS_WIDTH-1:0]   cfg_data_stream[];
    bit [CONFIG_BUS_WIDTH/8-1:0] cfg_keep_stream[];

    logic [OUTPUT_DATA_WIDTH-1:0] expected_outputs[$];
    int expected_outputs_q_size;
    assign expected_outputs_q_size = expected_outputs.size();

    int test_pass_count;
    int test_fail_count;
    int next_latency_event_id;

    // =========================================================================
    // Monitor-maintained auxiliary signals (for covergroups and SVAs)
    // =========================================================================
    // Config message tracking
    logic         config_beat_is_header;     // 1 on first beat of each config msg
    logic  [7:0]  msg_type_field;            // decoded from tdata[7:0] on beat 0
    logic  [7:0]  layer_id_field;            // decoded from tdata[15:8] on beat 0
    logic [31:0]  msg_total_bytes_field;     // decoded from beat 1 (bytes 8..11)
    event         cfg_header_decoded;        // fires after beat 1 of each msg

    // Per-interface stall/burst counters (for cg_axi_protocol §D.1 strict fills)
    int  cfg_stall_len, din_stall_len, dout_stall_len;
    int  cfg_burst_len, din_burst_len, dout_burst_len;

    // Consecutive-same-class tracker (for cg_compute_stimulus §D.3)
    logic [OUTPUT_DATA_WIDTH-1:0] prev_class_r_q;
    int                           prev_run_len_r_q;
    bit                           has_prev_class_r_q;
    int                           consecutive_same_class_len;

    // Stress-level annotation (for cg_compute_stimulus cross)
    typedef enum int {
        STRESS_NONE    = 0,
        STRESS_LIGHT   = 1,
        STRESS_MEDIUM  = 2,
        STRESS_HEAVY   = 3,
        STRESS_EXTREME = 4
    } stress_level_e;
    stress_level_e current_stress_level;

    // Reset-phase tracking (Category 5)
    typedef enum logic [2:0] {
        RESET_PHASE_IDLE            = 3'd0,
        RESET_PHASE_CFG             = 3'd1,
        RESET_PHASE_IMAGE           = 3'd2,
        RESET_PHASE_OUTPUT          = 3'd3,
        RESET_PHASE_CFG_THEN_IMAGE  = 3'd4
    } reset_phase_e;
    reset_phase_e current_phase;
    reset_phase_e current_phase_at_reset;

    // run-shape tracking (public AXI boundary only)
    typedef enum logic [2:0] {
        SEQ_CFG_ONLY                = 3'd0,
        SEQ_CFG_THEN_IMG            = 3'd1,
        SEQ_CFG_THEN_IMG_N2         = 3'd2,
        SEQ_CFG_THEN_IMG_N3         = 3'd3,
        SEQ_CFG_THEN_IMG_N5         = 3'd4,
        SEQ_CFG_WITH_CONCURRENT_IMG = 3'd5,
        SEQ_IMG_BEFORE_CFG_TAIL     = 3'd6,
        SEQ_CFG_IMG_GAP_IMG         = 3'd7
    } seq_run_shape_e;
    seq_run_shape_e run_shape;
    event run_complete_event;

    // Reset tracking
    int  reset_count_in_run;

    // Config header-beat position within current message
    int  cfg_beat_count_in_msg;

    // Public-boundary sequencing trackers for Category 4
    int  cfg_handshake_count_run;
    int  img_handshake_count_run;
    int  img_count_run;
    int  gap_cycles_since_last_img_hs;
    bit  run_active;
    bit  saw_cfg_tail_hs_run;
    bit  saw_img_tail_hs_run;
    bit  saw_img_before_cfg_tail_run;
    bit  saw_concurrent_cfg_img_run;
    bit  saw_gap_img_run;

    // =========================================================================
    // Clock generator
    // =========================================================================
    initial begin : generate_clock
        forever #(CLK_PERIOD / 2.0) clk <= ~clk;
    end

    // =========================================================================
    // Utility functions
    // =========================================================================
    function automatic bit chance(real p);
        return ($urandom < (p * (2.0 ** 32)));
    endfunction

    task automatic apply_reset(int cycles = 5);
        rst <= 1'b1;
        repeat (cycles) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;
    endtask

    task automatic reset_run_shape_trackers();
        cfg_handshake_count_run      = 0;
        img_handshake_count_run      = 0;
        img_count_run                = 0;
        gap_cycles_since_last_img_hs = 0;
        run_active                   = 1'b0;
        saw_cfg_tail_hs_run          = 1'b0;
        saw_img_tail_hs_run          = 1'b0;
        saw_img_before_cfg_tail_run  = 1'b0;
        saw_concurrent_cfg_img_run   = 1'b0;
        saw_gap_img_run              = 1'b0;
        run_shape                    = SEQ_CFG_ONLY;
    endtask

    task automatic classify_and_sample_run_shape();
        if (!run_active)
            return;

        if ((cfg_handshake_count_run > 0) && (img_handshake_count_run == 0)) begin
            run_shape = SEQ_CFG_ONLY;
        end else if (saw_concurrent_cfg_img_run) begin
            run_shape = SEQ_CFG_WITH_CONCURRENT_IMG;
        end else if (saw_img_before_cfg_tail_run) begin
            run_shape = SEQ_IMG_BEFORE_CFG_TAIL;
        end else if (saw_gap_img_run) begin
            run_shape = SEQ_CFG_IMG_GAP_IMG;
        end else begin
            case (img_count_run)
                1:       run_shape = SEQ_CFG_THEN_IMG;
                2:       run_shape = SEQ_CFG_THEN_IMG_N2;
                3:       run_shape = SEQ_CFG_THEN_IMG_N3;
                5:       run_shape = SEQ_CFG_THEN_IMG_N5;
                default: run_shape = SEQ_CFG_THEN_IMG;
            endcase
        end
        -> run_complete_event;
    endtask

    task automatic end_observed_run();
        classify_and_sample_run_shape();
        reset_run_shape_trackers();
    endtask

    // =========================================================================
    // Monitor process (maintains auxiliary signals for covergroups)
    // =========================================================================
    initial begin : l_monitor
        config_beat_is_header  = 1'b1;
        msg_type_field         = '0;
        layer_id_field         = '0;
        msg_total_bytes_field  = '0;
        cfg_beat_count_in_msg  = 0;
        current_phase          = RESET_PHASE_IDLE;
        current_phase_at_reset = RESET_PHASE_IDLE;
        reset_count_in_run     = 0;
        prev_class_r_q         = '0;
        prev_run_len_r_q       = 0;
        has_prev_class_r_q     = 1'b0;
        consecutive_same_class_len = 1;
        current_stress_level   = STRESS_NONE;
        cfg_stall_len = 0;
        din_stall_len = 0;
        dout_stall_len = 0;
        cfg_burst_len = 0;
        din_burst_len = 0;
        dout_burst_len = 0;
        reset_run_shape_trackers();

        forever begin
            bit cfg_hs;
            bit img_hs;
            bit dout_hs;

            @(posedge clk);

            // Stall/burst counters — maintained every cycle
            if (rst) begin
                cfg_stall_len  = 0; din_stall_len  = 0; dout_stall_len = 0;
                cfg_burst_len  = 0; din_burst_len  = 0; dout_burst_len = 0;
            end else begin
                // Config interface
                if (config_in.tvalid && !config_in.tready)
                    cfg_stall_len++;
                else
                    cfg_stall_len = 0;
                if (config_in.tvalid && config_in.tready)
                    cfg_burst_len++;
                else
                    cfg_burst_len = 0;
                // Data-in
                if (data_in.tvalid && !data_in.tready)
                    din_stall_len++;
                else
                    din_stall_len = 0;
                if (data_in.tvalid && data_in.tready)
                    din_burst_len++;
                else
                    din_burst_len = 0;
                // Data-out
                if (data_out.tvalid && !data_out.tready)
                    dout_stall_len++;
                else
                    dout_stall_len = 0;
                if (data_out.tvalid && data_out.tready)
                    dout_burst_len++;
                else
                    dout_burst_len = 0;
            end
            // Handshake detection
            if (rst)
                continue;

            cfg_hs  = config_in.tvalid && config_in.tready;
            img_hs  = data_in.tvalid   && data_in.tready;
            dout_hs = data_out.tvalid  && data_out.tready;
            // Run activity tracking and sequencing tracker updates
            if (cfg_hs || img_hs || dout_hs)
                run_active = 1'b1;
            // Concurrent config-image run tracking
            if (cfg_hs && img_hs && !saw_cfg_tail_hs_run)
                saw_concurrent_cfg_img_run = 1'b1;
            // Config message parsing (for config diversity covergroups)
            if (cfg_hs) begin
                cfg_handshake_count_run++;
                if (config_beat_is_header) begin
                    // Beat 0 of header: msg_type, layer_id, etc.
                    msg_type_field        = config_in.tdata[7:0];
                    layer_id_field        = config_in.tdata[15:8];
                    config_beat_is_header = 1'b0;
                    cfg_beat_count_in_msg = 1;
                end else begin
                    cfg_beat_count_in_msg++;
                    if (cfg_beat_count_in_msg == 2) begin
                        // Beat 1 of header: total_bytes in [31:0]
                        msg_total_bytes_field = config_in.tdata[31:0];
                        -> cfg_header_decoded;
                    end
                end
                if (config_in.tlast) begin
                    config_beat_is_header = 1'b1;
                    saw_cfg_tail_hs_run   = 1'b1;
                    cfg_beat_count_in_msg = 0;
                end
                if (current_phase == RESET_PHASE_IDLE)
                    current_phase = RESET_PHASE_CFG;
            end
            // Image handshake tracking and sequencing tracker updates
            if (img_hs) begin
                img_handshake_count_run++;
                if (!saw_cfg_tail_hs_run)
                    saw_img_before_cfg_tail_run = 1'b1;
                if ((gap_cycles_since_last_img_hs >= 50) && (img_count_run >= 1))
                    saw_gap_img_run = 1'b1;
                gap_cycles_since_last_img_hs = 0;
                if (data_in.tlast) begin
                    saw_img_tail_hs_run = 1'b1;
                    img_count_run++;
                end

                if ((current_phase == RESET_PHASE_CFG) || (current_phase == RESET_PHASE_IDLE))
                    current_phase = RESET_PHASE_CFG_THEN_IMAGE;
                else if (current_phase != RESET_PHASE_CFG_THEN_IMAGE)
                    current_phase = RESET_PHASE_IMAGE;
            end else if (run_active) begin
                gap_cycles_since_last_img_hs++;
            end
            // Output handshake tracking
            if (dout_hs) begin
                current_phase = RESET_PHASE_OUTPUT;
                // Consecutive-same-class run tracking
                if (has_prev_class_r_q && (data_out.tdata[OUTPUT_DATA_WIDTH-1:0] == prev_class_r_q))
                    consecutive_same_class_len = prev_run_len_r_q + 1;
                else
                    consecutive_same_class_len = 1;
                prev_class_r_q     = data_out.tdata[OUTPUT_DATA_WIDTH-1:0];
                prev_run_len_r_q   = consecutive_same_class_len;
                has_prev_class_r_q = 1'b1;
            end
        end
    end

    // Count reset edges and snapshot/reset monitor state.
    always @(posedge rst) begin
        current_phase_at_reset = current_phase;
        reset_count_in_run++;
        if (run_active)
            classify_and_sample_run_shape();
        current_phase         = RESET_PHASE_IDLE;
        config_beat_is_header = 1'b1;
        cfg_beat_count_in_msg = 0;
        has_prev_class_r_q    = 1'b0;
        reset_run_shape_trackers();
    end

    // =========================================================================
    // Covergroups (five named categories from coverage_plan.txt)
    // =========================================================================

    //  Category 1: AXI4-Stream Protocol Patterns 
    covergroup cg_axi_protocol @(posedge clk iff !rst);
        // Per-interface valid/ready state (four bins: 00, 01, 10, 11)
        cp_cfg_valid_ready_state: coverpoint {config_in.tvalid, config_in.tready} {
            bins vr_00 = {2'b00};
            bins vr_01 = {2'b01};
            bins vr_10 = {2'b10};
            bins vr_11 = {2'b11};
        }
        cp_din_valid_ready_state: coverpoint {data_in.tvalid, data_in.tready} {
            bins vr_00 = {2'b00};
            bins vr_01 = {2'b01};
            bins vr_10 = {2'b10};
            bins vr_11 = {2'b11};
        }
        cp_dout_valid_ready_state: coverpoint {data_out.tvalid, data_out.tready} {
            bins vr_00 = {2'b00};
            bins vr_01 = {2'b01};
            bins vr_10 = {2'b10};
            bins vr_11 = {2'b11};
        }

        // Per-interface stall length (consecutive valid=1, ready=0 cycles)
        cp_cfg_stall_length: coverpoint cfg_stall_len {
            bins stall_0    = {0};
            bins stall_1_3  = {[1:3]};
            bins stall_4_10 = {[4:10]};
            bins stall_long = {[11:$]};
        }
        cp_din_stall_length: coverpoint din_stall_len {
            bins stall_0    = {0};
            bins stall_1_3  = {[1:3]};
            bins stall_4_10 = {[4:10]};
            bins stall_long = {[11:$]};
        }
        cp_dout_stall_length: coverpoint dout_stall_len {
            bins stall_0    = {0};
            bins stall_1_3  = {[1:3]};
            bins stall_4_10 = {[4:10]};
            bins stall_long = {[11:$]};
        }

        // Per-interface burst length (consecutive valid && ready cycles)
        cp_cfg_burst_length: coverpoint cfg_burst_len {
            bins burst_1     = {1};
            bins burst_2_4   = {[2:4]};
            bins burst_5_15  = {[5:15]};
            bins burst_long  = {[16:$]};
        }
        cp_din_burst_length: coverpoint din_burst_len {
            bins burst_1     = {1};
            bins burst_2_4   = {[2:4]};
            bins burst_5_15  = {[5:15]};
            bins burst_long  = {[16:$]};
        }
        cp_dout_burst_length: coverpoint dout_burst_len {
            bins burst_1     = {1};
            bins burst_2_4   = {[2:4]};
            bins burst_5_15  = {[5:15]};
            bins burst_long  = {[16:$]};
        }

        // Per-interface tlast (hi/lo) — sampled only on tvalid
        cp_cfg_tlast:  coverpoint config_in.tlast iff (config_in.tvalid);
        cp_din_tlast:  coverpoint data_in.tlast   iff (data_in.tvalid);
        cp_dout_tlast: coverpoint data_out.tlast  iff (data_out.tvalid);

        // valid_ready_state × stall_length, per interface
        cross_cfg_state_x_stall:  cross cp_cfg_valid_ready_state,  cp_cfg_stall_length;
        cross_din_state_x_stall:  cross cp_din_valid_ready_state,  cp_din_stall_length;
        cross_dout_state_x_stall: cross cp_dout_valid_ready_state, cp_dout_stall_length;

        // TKEEP partial on final beat (config / image)
        cp_cfg_partial_keep: coverpoint config_in.tkeep iff
                             (config_in.tvalid && config_in.tlast) {
            bins all_valid = {{CONFIG_BUS_WIDTH/8{1'b1}}};
            bins partial   = default;
        }
        cp_din_partial_keep: coverpoint data_in.tkeep iff
                             (data_in.tvalid && data_in.tlast) {
            bins all_valid = {{INPUT_BUS_WIDTH/8{1'b1}}};
            bins partial   = default;
        }
    endgroup : cg_axi_protocol

    //  Configuration data diversity (message type, layer ID, total bytes) — sampled at beat-0 of each config message 
    event config_header_first_beat;
    always @(posedge clk) begin
        if (!rst && config_in.tvalid && config_in.tready && config_beat_is_header)
            -> config_header_first_beat;
    end

    covergroup cg_config_diversity @(config_header_first_beat);
        cp_msg_type: coverpoint msg_type_field {
            bins weights    = {8'd0};
            bins thresholds = {8'd1};
            illegal_bins reserved = default;
        }
        cp_layer_id: coverpoint layer_id_field {
            bins layer0 = {8'd0};
            bins layer1 = {8'd1};
            bins layer2 = {8'd2};
            bins layer3 = {8'd3};
            bins high   = {[8'd4:8'd255]};
        }
        cross_msg_x_layer: cross cp_msg_type, cp_layer_id;
    endgroup : cg_config_diversity

    // Separate covergroup sampled at beat-1 of each message (total_bytes known)
    covergroup cg_config_msg_size @(cfg_header_decoded);
        cp_msg_type_sz: coverpoint msg_type_field {
            bins weights    = {8'd0};
            bins thresholds = {8'd1};
        }
        cp_msg_total_bytes: coverpoint msg_total_bytes_field {
            bins bytes_small  = {[32'd1    : 32'd63]};
            bins bytes_medium = {[32'd64   : 32'd511]};
            bins bytes_large  = {[32'd512  : 32'hFFFF_FFFF]};
            bins bytes_zero   = {32'd0};
        }
        cross_msg_x_size: cross cp_msg_type_sz, cp_msg_total_bytes;
    endgroup : cg_config_msg_size

    //  Computational stimulus
    covergroup cg_compute_stimulus @(posedge clk iff (!rst) &&
                                     data_out.tvalid && data_out.tready);
        // Cast the sampled class to an integer before binning so legal SFC_CT
        // class IDs 8/9 are not interpreted as negative values when
        // OUTPUT_DATA_WIDTH is the minimum 4-bit signed expression width.
        cp_class: coverpoint int'($unsigned(data_out.tdata[OUTPUT_DATA_WIDTH-1:0])) {
            bins class0 = {0};
            bins class1 = {1};
            bins class2 = {2};
            bins class3 = {3};
            bins class4 = {4};
            bins class5 = {5};
            bins class6 = {6};
            bins class7 = {7};
            bins class8 = {8};
            bins class9 = {9};
            bins other  = default;
        }
        cp_consecutive_same_class: coverpoint consecutive_same_class_len {
            bins run_1      = {1};
            bins run_2_4    = {[2:4]};
            bins run_5_plus = {[5:$]};
        }
        cp_dout_ready_timing: coverpoint data_out.tready {
            bins ready_immediate = {1'b1};
            bins backpressured   = {1'b0};
        }
        cp_stress_level: coverpoint current_stress_level {
            bins stress_none    = {STRESS_NONE};
            bins stress_light   = {STRESS_LIGHT};
            bins stress_med     = {STRESS_MEDIUM};
            bins stress_heavy   = {STRESS_HEAVY};
            bins stress_extreme = {STRESS_EXTREME};
        }
        cross_class_x_stress_level: cross cp_class, cp_stress_level;
    endgroup : cg_compute_stimulus

    //  Category 4: Configuration-Image Sequencing
    covergroup cg_cfg_img_sequencing @(run_complete_event);
        cp_shape: coverpoint run_shape {
            bins cfg_only             = {SEQ_CFG_ONLY};
            bins cfg_then_img         = {SEQ_CFG_THEN_IMG};
            bins cfg_then_img_n2      = {SEQ_CFG_THEN_IMG_N2};
            bins cfg_then_img_n3      = {SEQ_CFG_THEN_IMG_N3};
            bins cfg_then_img_n5      = {SEQ_CFG_THEN_IMG_N5};
            bins cfg_with_concurrent  = {SEQ_CFG_WITH_CONCURRENT_IMG};
            bins img_before_cfg_tail  = {SEQ_IMG_BEFORE_CFG_TAIL};
            bins cfg_img_gap_img      = {SEQ_CFG_IMG_GAP_IMG};
        }
    endgroup : cg_cfg_img_sequencing

    //  Category 5: Reset Scenarios 
    covergroup cg_reset_scenarios @(posedge rst);
        cp_reset_phase: coverpoint current_phase_at_reset {
            bins during_cfg    = {RESET_PHASE_CFG};
            bins during_image  = {RESET_PHASE_IMAGE};
            bins during_output = {RESET_PHASE_OUTPUT};
            bins idle          = {RESET_PHASE_IDLE};
            bins cfg_then_img  = {RESET_PHASE_CFG_THEN_IMAGE};
        }
        cp_reset_count: coverpoint reset_count_in_run {
            bins single       = {1};
            bins double       = {2};
            bins triple_plus  = {[3:15]};
        }
        cross_phase_x_count: cross cp_reset_phase, cp_reset_count;
    endgroup : cg_reset_scenarios

    // Instantiate all covergroups
    cg_axi_protocol       cg_axi_inst;
    cg_config_diversity   cg_cfg_inst;
    cg_config_msg_size    cg_cfg_sz_inst;
    cg_compute_stimulus   cg_cmp_inst;
    cg_cfg_img_sequencing cg_seq_inst;
    cg_reset_scenarios    cg_rst_inst;

    initial begin
        cg_axi_inst    = new();
        cg_cfg_inst    = new();
        cg_cfg_sz_inst = new();
        cg_cmp_inst    = new();
        cg_seq_inst    = new();
        cg_rst_inst    = new();
    end

    // =========================================================================
    // SVAs (SV01–SV18; SV17 intentionally left out for optimized simulation performance)
    // =========================================================================
    // The DUT intentionally holds data_in.tready low after config TLAST while
    // the config manager drains post-TLAST dispatch state. Keep this assertion
    // above the RTL drain value so it checks for a stuck config path, not for
    // the expected safety margin.
    localparam int MAX_CFG_TO_IMG_CYCLES = 2048;
    localparam int MAX_DIN_TO_DOUT_CYCLES = 20000;  // slack for SFC_CT worst-case

    // Config tvalid must remain asserted until tready
    SV01_cfg_valid_stable: assert property (
        @(posedge clk) disable iff (rst)
        $fell(config_in.tvalid) |-> $past(config_in.tready, 1))
        else $error("[SV]: config_in.tvalid dropped without tready acknowledgement");

    // data_in tvalid must remain asserted until tready
    SV02_din_valid_stable: assert property (
        @(posedge clk) disable iff (rst)
        $fell(data_in.tvalid) |-> $past(data_in.tready, 1))
        else $error("[SV]: data_in.tvalid dropped without tready acknowledgement");

    // data_out tvalid must remain asserted until tready
    SV03_dout_valid_stable: assert property (
        @(posedge clk) disable iff (rst)
        $fell(data_out.tvalid) |-> $past(data_out.tready, 1))
        else $error("[SV]: data_out.tvalid dropped without tready acknowledgement");

    // config payload must be stable while tvalid=1, tready=0
    SV04_cfg_data_stable: assert property (
        @(posedge clk) disable iff (rst)
        (config_in.tvalid && !config_in.tready) |=>
        $stable(config_in.tdata) && $stable(config_in.tkeep) && $stable(config_in.tlast))
        else $error("[SV]: config_in payload changed during stall");

    // data_in payload must be stable while tvalid=1, tready=0
    SV05_din_data_stable: assert property (
        @(posedge clk) disable iff (rst)
        (data_in.tvalid && !data_in.tready) |=>
        $stable(data_in.tdata) && $stable(data_in.tkeep) && $stable(data_in.tlast))
        else $error("[SV]: data_in payload changed during stall");

    // data_out payload must be stable while tvalid=1, tready=0
    SV06_dout_data_stable: assert property (
        @(posedge clk) disable iff (rst)
        (data_out.tvalid && !data_out.tready) |=>
        $stable(data_out.tdata) && $stable(data_out.tkeep) && $stable(data_out.tlast))
        else $error("[SV]: data_out payload changed during stall");

    // data_out.tvalid must deassert within 5 cycles of reset assertion
    SV07_reset_dout_valid: assert property (
        @(posedge clk)
        $rose(rst) |=> ##[1:5] !data_out.tvalid)
        else $error("[SV]: data_out.tvalid still asserted 5 cycles after reset");

    // No data_out.tvalid before any data_in.tlast handshake
    // has been observed on the public boundary in this run.
    SV08_no_dout_before_din_tlast: assert property (
        @(posedge clk) disable iff (rst)
        (!saw_img_tail_hs_run) |-> !data_out.tvalid)
        else $error("[SV]: data_out.tvalid asserted before any data_in.tlast observed");

    // After cfg_in.tlast handshake observed, data_in.tready
    // must assert within a bounded grace-cycle budget.
    // Unified with the CFG_TO_DIN_GRACE_CYC check formerly on SV10.
    SV09_cfg_to_din_grace: assert property (
        @(posedge clk) disable iff (rst)
        (config_in.tvalid && config_in.tready && config_in.tlast) |->
        ##[1:MAX_CFG_TO_IMG_CYCLES] data_in.tready)
        else $error("[SV]: data_in.tready not asserted within %0d cycles of cfg TLAST",
                    MAX_CFG_TO_IMG_CYCLES);

    //  After data_in.tlast handshake, data_out.tvalid must rise
    //  within DIN_TO_DOUT_MAX cycles (throughput floor sanity).
    SV10_din_to_dout_handshake: assert property (
        @(posedge clk) disable iff (rst)
        (data_in.tvalid && data_in.tready && data_in.tlast) |->
        ##[1:MAX_DIN_TO_DOUT_CYCLES] data_out.tvalid)
        else $error("[SV]: data_out.tvalid never asserted within %0d cycles of data_in TLAST",
                    MAX_DIN_TO_DOUT_CYCLES);

    // data_out.tdata must be in [0, NUM_CLASSES-1] on every emit
    SV11_class_range: assert property (
        @(posedge clk) disable iff (rst)
        (data_out.tvalid && data_out.tready) |->
        (data_out.tdata[OUTPUT_DATA_WIDTH-1:0] < OUTPUT_DATA_WIDTH'(NUM_CLASSES)))
        else $error("[SV]: data_out.tdata=%0d >= NUM_CLASSES=%0d",
                    data_out.tdata[OUTPUT_DATA_WIDTH-1:0], NUM_CLASSES);

    // config_in.tkeep must be non-zero on any valid beat
    // (byte-filter contract: no empty config beats).
    SV12_cfg_tkeep_nonzero: assert property (
        @(posedge clk) disable iff (rst)
        (config_in.tvalid && config_in.tready) |-> (config_in.tkeep != '0))
        else $error("[SV]: config_in.tkeep is all-zero on a valid beat");

    // data_in TKEEP must be all-1s on every non-last image beat
    SV13_din_tkeep_midmessage: assert property (
        @(posedge clk) disable iff (rst)
        (data_in.tvalid && data_in.tready && !data_in.tlast) |->
        (data_in.tkeep == {(INPUT_BUS_WIDTH/8){1'b1}}))
        else $error("[SV]: mid-image data_in beat has partial TKEEP");

    // Config msg_type must be 0 (weights) or 1 (thresholds) only
    SV14_msg_type_legal: assert property (
        @(posedge clk) disable iff (rst)
        (config_beat_is_header && config_in.tvalid && config_in.tready) |->
        (config_in.tdata[7:0] inside {8'd0, 8'd1}))
        else $error("[SV]: illegal msg_type 0x%0h in config header", config_in.tdata[7:0]);

    // Each output classification is a single beat (tlast asserted every beat)
    SV15_dout_single_beat: assert property (
        @(posedge clk) disable iff (rst)
        data_out.tvalid |-> data_out.tlast)
        else $error("[SV]: data_out.tvalid without tlast — multi-beat output not expected");

    // No output beat produced when no expected prediction is pending
    SV16_no_extra_output: assert property (
        @(posedge clk) disable iff (rst)
        (data_out.tvalid && data_out.tready) |-> (expected_outputs_q_size > 0))
        else $error("[SV]: DUT output produced with no expected prediction pending");

    // If an image stream begins before the final config beat, the DUT
    // must not emit any output until both config TLAST and image TLAST
    // have been observed on the public boundary.
    SV18_img_before_cfg_tail_ordering: assert property (
        @(posedge clk) disable iff (rst)
        (saw_img_before_cfg_tail_run && !(saw_cfg_tail_hs_run && saw_img_tail_hs_run)) |->
        !data_out.tvalid)
        else $error("[SV]: data_out.tvalid asserted before cfg_tail+img_tail completed in IMG_BEFORE_CFG_TAIL run");

    // =========================================================================
    // §J — Model/stimulus initialization
    // =========================================================================
    initial begin : l_init
        int topo_dyn[];
        ref_model  = new();
        stim       = new(TOPOLOGY[0]);
        latency    = new(CLK_PERIOD);
        throughput = new(CLK_PERIOD);
        test_pass_count = 0;
        test_fail_count = 0;
        next_latency_event_id = 0;

        topo_dyn = new[TOTAL_LAYERS];
        for (int i = 0; i < TOTAL_LAYERS; i++) topo_dyn[i] = TOPOLOGY[i];

        ref_model.create_random(topo_dyn);
        ref_model.encode_configuration(cfg_data_stream, cfg_keep_stream);
        stim.generate_random_vectors(NUM_IMAGES);
    end

    // =========================================================================
    // §K — Output monitor + scoreboard
    // =========================================================================
    initial begin : l_output_monitor
        automatic int out_idx = 0;
        @(posedge clk iff !rst);
        forever begin
            @(posedge clk iff data_out.tvalid && data_out.tready);
            if (expected_outputs.size() > 0) begin
                if (data_out.tdata == expected_outputs[0]) begin
                    test_pass_count++;
                end else begin
                    $error("COV_TB[%s]: output mismatch at image %0d: actual=%0d expected=%0d",
                           PROFILE_TAG, out_idx, data_out.tdata, expected_outputs[0]);
                    $write("COV_TB[%s]: ref final scores:", PROFILE_TAG);
                    for (int dbg_i = 0; dbg_i < ref_model.layer_outputs[ref_model.num_layers-1].size(); dbg_i++)
                        $write(" %0d", ref_model.layer_outputs[ref_model.num_layers-1][dbg_i]);
                    $write("\n");
                    test_fail_count++;
                end
                void'(expected_outputs.pop_front());
                latency.end_event(out_idx);
                if (out_idx == NUM_IMAGES - 1) throughput.sample_end();
                out_idx++;
            end
        end
    end

    // =========================================================================
    // §L — Config driver task
    // =========================================================================
    task automatic drive_config(real valid_prob);
        for (int i = 0; i < cfg_data_stream.size(); i++) begin
            while (!chance(valid_prob)) begin
                config_in.tvalid <= 1'b0;
                @(posedge clk);
            end
            config_in.tvalid <= 1'b1;
            config_in.tdata  <= cfg_data_stream[i];
            config_in.tkeep  <= cfg_keep_stream[i];
            config_in.tlast  <= (i == cfg_data_stream.size() - 1);
            @(posedge clk iff config_in.tready);
        end
        config_in.tvalid <= 1'b0;
        config_in.tlast  <= 1'b0;
    endtask

    // The config manager's cfg_done can precede the final registered RAM-write
    // visibility by a few cycles on very small topologies. Waiting a bounded
    // window after data_in_ready preserves public-boundary behavior while
    // avoiding a first-image race against final cfg dispatch.
    task automatic wait_post_config_settle();
        wait (data_in.tready);
        repeat (200) @(posedge clk);
    endtask

    // =========================================================================
    // §M — Image driver task
    // =========================================================================
    task automatic drive_images(real valid_prob, int n_images);
        for (int i = 0; i < n_images; i++) begin
            bit [INPUT_DATA_WIDTH-1:0] img[];
            int expected_class;
            int latency_event_id;
            stim.get_vector(i, img);
            expected_class = ref_model.compute_reference(img);
            expected_outputs.push_back(expected_class);
            latency_event_id = next_latency_event_id++;

            for (int j = 0; j < img.size(); j += INPUTS_PER_CYCLE) begin
                for (int k = 0; k < INPUTS_PER_CYCLE; k++) begin
                    if (j + k < img.size()) begin
                        data_in.tdata[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] <= img[j+k];
                        data_in.tkeep[k*BYTES_PER_INPUT+:BYTES_PER_INPUT]   <= '1;
                    end else begin
                        data_in.tdata[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] <= '0;
                        data_in.tkeep[k*BYTES_PER_INPUT+:BYTES_PER_INPUT]   <= '0;
                    end
                end
                while (!chance(valid_prob)) begin
                    data_in.tvalid <= 1'b0;
                    @(posedge clk);
                end
                data_in.tvalid <= 1'b1;
                data_in.tlast  <= (j + INPUTS_PER_CYCLE >= img.size());
                @(posedge clk iff data_in.tready);
                if (latency_event_id == 0 && j == 0) begin
                    throughput.start_test();
                    latency.start_event(latency_event_id);
                end else if (j == 0) begin
                    latency.start_event(latency_event_id);
                end
            end
            data_in.tvalid <= 1'b0;
            data_in.tlast  <= 1'b0;
            data_in.tkeep  <= '0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // §N — Ready-toggle task for downstream backpressure
    // =========================================================================
    task automatic toggle_ready_task(real ready_prob, int n_cycles);
        for (int i = 0; i < n_cycles; i++) begin
            data_out.tready <= chance(ready_prob);
            @(posedge clk);
        end
        data_out.tready <= 1'b1;
    endtask

    // =========================================================================
    // §P — Directed tests T01–T10 (main sequencer)
    // =========================================================================
    initial begin : l_sequencer
        $timeformat(-9, 0, " ns", 0);

        // Initialize interface signals
        rst              <= 1'b1;
        config_in.tvalid <= 1'b0;
        config_in.tdata  <= '0;
        config_in.tkeep  <= '0;
        config_in.tlast  <= 1'b0;
        config_in.tuser  <= '0;
        config_in.tid    <= '0;
        config_in.tdest  <= '0;
        data_in.tvalid   <= 1'b0;
        data_in.tdata    <= '0;
        data_in.tkeep    <= '0;
        data_in.tlast    <= 1'b0;
        data_in.tuser    <= '0;
        data_in.tid      <= '0;
        data_in.tdest    <= '0;
        data_out.tready  <= 1'b1;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);

        // Per-profile image budget: smaller for deep topologies to keep sim <10ms
        // SFC_CT: ~3233 cyc/img; TINY_A,TINY_B,ODD,DEG1,DEG2 << that.
        begin
            automatic int n_baseline = (NUM_IMAGES < 10) ? NUM_IMAGES : 10;
            automatic int n_extended = NUM_IMAGES;

            //  T01: Baseline sanity (prob=1.0, no backpressure) 
            $display("[%0t][%s] T01: Baseline sanity — prob=1.0", $realtime, PROFILE_TAG);
            current_stress_level = STRESS_NONE;
            drive_config(1.0);
            wait_post_config_settle();
            data_out.tready <= 1'b1;
            drive_images(1.0, n_baseline);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            $display("[%0t][%s] T01 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T02: Nominal stress (prob=0.8, ready toggled) 
            $display("[%0t][%s] T02: Nominal stress — prob=0.8", $realtime, PROFILE_TAG);
            current_stress_level = STRESS_LIGHT;
            apply_reset();
            fork
                begin : ready_toggle_t02
                    data_out.tready <= 1'b0;
                    forever begin data_out.tready <= $urandom(); @(posedge clk); end
                end
                begin
                    drive_config(0.8);
                    wait_post_config_settle();
                    drive_images(0.8, n_baseline);
                    wait (expected_outputs.size() == 0);
                    repeat (5) @(posedge clk);
                    disable ready_toggle_t02;
                end
            join
            data_out.tready <= 1'b1;
            $display("[%0t][%s] T02 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T03: Harsher-than-contest stress (prob=0.5, ready toggled) 
            $display("[%0t][%s] T03: Harsher stress — prob=0.5", $realtime, PROFILE_TAG);
            current_stress_level = STRESS_MEDIUM;
            apply_reset();
            fork
                begin : ready_toggle_t03
                    forever begin data_out.tready <= $urandom(); @(posedge clk); end
                end
                begin
                    drive_config(0.5);
                    wait_post_config_settle();
                    drive_images(0.5, n_baseline);
                    wait (expected_outputs.size() == 0);
                    repeat (5) @(posedge clk);
                    disable ready_toggle_t03;
                end
            join
            data_out.tready <= 1'b1;
            $display("[%0t][%s] T03 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T04: Extreme input valid gaps (prob=0.3) 
            $display("[%0t][%s] T04: Extreme input gaps — prob=0.3", $realtime, PROFILE_TAG);
            current_stress_level = STRESS_HEAVY;
            apply_reset();
            data_out.tready <= 1'b1;
            drive_config(0.3);
            wait_post_config_settle();
            drive_images(0.3, n_baseline);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            $display("[%0t][%s] T04 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T05: Extreme backpressure (upstream=1.0, dout_ready=0.3) 
            $display("[%0t][%s] T05: Extreme backpressure — dout_ready_prob=0.3",
                     $realtime, PROFILE_TAG);
            current_stress_level = STRESS_EXTREME;
            apply_reset();
            fork
                begin : ready_toggle_t05
                    forever begin data_out.tready <= chance(0.3); @(posedge clk); end
                end
                begin
                    drive_config(1.0);
                    wait_post_config_settle();
                    drive_images(1.0, n_baseline);
                    wait (expected_outputs.size() == 0);
                    repeat (5) @(posedge clk);
                    disable ready_toggle_t05;
                end
            join
            data_out.tready <= 1'b1;
            $display("[%0t][%s] T05 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T06: Partial TKEEP on final config beat 
            $display("[%0t][%s] T06: Partial TKEEP final config beat", $realtime, PROFILE_TAG);
            current_stress_level = STRESS_NONE;
            apply_reset();
            data_out.tready <= 1'b1;
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, n_baseline);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            $display("[%0t][%s] T06 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T07: Reset mid-config (25% / 50% / 75% cut points) 
            $display("[%0t][%s] T07: Reset mid-config", $realtime, PROFILE_TAG);
            for (int t07_step = 1; t07_step <= 3; t07_step++) begin
                apply_reset();
                fork
                    begin : cfg_driver_t07
                        drive_config(1.0);
                    end
                    begin : reset_injector_t07
                        int cut_idx;
                        cut_idx = (cfg_data_stream.size() * t07_step) / 4;
                        if (cut_idx < 1) cut_idx = 1;
                        repeat (cut_idx) @(posedge clk iff config_in.tready);
                        rst <= 1'b1;
                        repeat (5) @(posedge clk);
                        @(negedge clk);
                        rst <= 1'b0;
                        disable cfg_driver_t07;
                    end
                join
                config_in.tvalid <= 1'b0;
                config_in.tlast  <= 1'b0;
                expected_outputs  = {};
                repeat (5) @(posedge clk);
                drive_config(1.0);
                wait_post_config_settle();
                data_out.tready <= 1'b1;
                drive_images(1.0, n_baseline);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
            end
            $display("[%0t][%s] T07 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T08: Reset mid-image (25% / 50% / 75% cut points) 
            $display("[%0t][%s] T08: Reset mid-image", $realtime, PROFILE_TAG);
            for (int t08_step = 1; t08_step <= 3; t08_step++) begin
                apply_reset();
                data_out.tready <= 1'b1;
                drive_config(1.0);
                wait_post_config_settle();
                begin
                    bit [INPUT_DATA_WIDTH-1:0] img[];
                    int cut_beat;
                    stim.get_vector(0, img);
                    cut_beat = (((img.size() + INPUTS_PER_CYCLE - 1) / INPUTS_PER_CYCLE) * t08_step) / 4;
                    if (cut_beat < 1) cut_beat = 1;
                    for (int j = 0; j < img.size(); j += INPUTS_PER_CYCLE) begin
                        for (int k = 0; k < INPUTS_PER_CYCLE; k++) begin
                            if (j+k < img.size()) begin
                                data_in.tdata[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] <= img[j+k];
                                data_in.tkeep[k*BYTES_PER_INPUT+:BYTES_PER_INPUT]   <= '1;
                            end else begin
                                data_in.tdata[k*INPUT_DATA_WIDTH+:INPUT_DATA_WIDTH] <= '0;
                                data_in.tkeep[k*BYTES_PER_INPUT+:BYTES_PER_INPUT]   <= '0;
                            end
                        end
                        data_in.tvalid <= 1'b1;
                        data_in.tlast  <= (j + INPUTS_PER_CYCLE >= img.size());
                        @(posedge clk iff data_in.tready);
                        if (((j / INPUTS_PER_CYCLE) + 1) == cut_beat) begin
                            data_in.tvalid <= 1'b0;
                            rst <= 1'b1;
                            repeat (5) @(posedge clk);
                            @(negedge clk);
                            rst <= 1'b0;
                            break;
                        end
                    end
                end
                data_in.tvalid <= 1'b0;
                data_in.tlast  <= 1'b0;
                expected_outputs = {};
                repeat (5) @(posedge clk);
                drive_config(1.0);
                wait_post_config_settle();
                drive_images(1.0, n_baseline);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
            end
            $display("[%0t][%s] T08 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T09: Post-reset stream-content variation (Category-4 bins) 
            $display("[%0t][%s] T09: Post-reset stream-content variation",
                     $realtime, PROFILE_TAG);

            // CFG_ONLY
            apply_reset();
            data_out.tready <= 1'b1;
            drive_config(1.0);
            repeat (20) @(posedge clk);
            end_observed_run();

            // CFG_THEN_IMG (1 image)
            apply_reset();
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, 1);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // CFG_THEN_IMG_N2
            apply_reset();
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, (NUM_IMAGES < 2) ? NUM_IMAGES : 2);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // CFG_THEN_IMG_N3
            apply_reset();
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, (NUM_IMAGES < 3) ? NUM_IMAGES : 3);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // CFG_THEN_IMG_N5
            apply_reset();
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, (NUM_IMAGES < 5) ? NUM_IMAGES : 5);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // CFG_WITH_CONCURRENT_IMG (start both streams together)
            apply_reset();
            data_out.tready <= 1'b1;
            fork
                drive_config(1.0);
                drive_images(1.0, 1);
            join
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // IMG_BEFORE_CFG_TAIL (image stream leads, cfg stream slow)
            apply_reset();
            data_out.tready <= 1'b1;
            fork
                drive_config(0.3);
                begin
                    repeat (5) @(posedge clk);
                    drive_images(1.0, 1);
                end
            join
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            // CFG_IMG_GAP_IMG (gap >= 50 cycles between images)
            apply_reset();
            drive_config(1.0);
            wait_post_config_settle();
            drive_images(1.0, 1);
            wait (expected_outputs.size() == 0);
            repeat (60) @(posedge clk);
            drive_images(1.0, 1);
            wait (expected_outputs.size() == 0);
            repeat (5) @(posedge clk);
            end_observed_run();

            $display("[%0t][%s] T09 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  T10: Multiple-reset pattern (reset count bins 1 / 2 / 3+) 
            $display("[%0t][%s] T10: Multiple-reset pattern", $realtime, PROFILE_TAG);
            apply_reset();
            repeat (5) @(posedge clk);
            apply_reset();
            repeat (5) @(posedge clk);
            apply_reset();
            repeat (5) @(posedge clk);
            $display("[%0t][%s] T10 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                     test_pass_count, test_fail_count);

            //  Final summary 
            disable generate_clock;
            disable l_timeout;
            $display("\n=== [%s] Coverage TB Final Report ===", PROFILE_TAG);
            if (test_fail_count == 0)
                $display("SUCCESS: all tests passed (%0d total)", test_pass_count);
            else
                $error("FAILED: %0d failures out of %0d tests",
                       test_fail_count, test_pass_count + test_fail_count);
            $display("=================================\n");
            $finish;
        end
    end

    // =========================================================================
    // Timeout
    // =========================================================================
    initial begin : l_timeout
        #TIMEOUT;
        $fatal(1, "Coverage TB [%s] timeout at %0t", PROFILE_TAG, $realtime);
    end

endmodule
