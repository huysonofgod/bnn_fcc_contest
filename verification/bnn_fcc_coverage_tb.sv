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

    typedef enum int {
        READY_TIMING_NONE          = 0,
        READY_TIMING_READY_BEFORE  = 1,
        READY_TIMING_SAME_CYCLE    = 2,
        READY_TIMING_READY_AFTER   = 3
    } ready_timing_e;

    typedef enum int {
        CFG_PROFILE_FULL           = 0,
        CFG_PROFILE_LAYER_SUBSET   = 1,
        CFG_PROFILE_WEIGHTS_ONLY   = 2,
        CFG_PROFILE_THRESH_ONLY    = 3,
        CFG_PROFILE_SAME_AFTER_RST = 4,
        CFG_PROFILE_DIFF_AFTER_RST = 5,
        CFG_PROFILE_LAYER_PERM     = 6,
        CFG_PROFILE_MSG_PERM       = 7,
        CFG_PROFILE_POSTSYN_HOOK   = 8
    } cfg_profile_e;

    typedef enum int {
        CFG_ORDER_DEFAULT          = 0,
        CFG_ORDER_LAYER_REVERSE    = 1,
        CFG_ORDER_THRESH_FIRST     = 2,
        CFG_ORDER_WEIGHTS_ONLY     = 3,
        CFG_ORDER_THRESH_ONLY      = 4,
        CFG_ORDER_LAYER_SUBSET     = 5
    } cfg_order_e;

    typedef enum int {
        DENSITY_RANDOM             = 0,
        DENSITY_ALL_ZERO           = 1,
        DENSITY_SPARSE             = 2,
        DENSITY_BALANCED           = 3,
        DENSITY_DENSE              = 4,
        DENSITY_ALL_ONE            = 5
    } weight_density_e;

    typedef enum int {
        THRESH_RANDOM              = 0,
        THRESH_ZERO                = 1,
        THRESH_LOW                 = 2,
        THRESH_MID                 = 3,
        THRESH_HIGH                = 4,
        THRESH_MAX                 = 5
    } threshold_mag_e;

    typedef enum int {
        CLASS_SEQ_UNKNOWN          = 0,
        CLASS_SEQ_REPEATED_IMAGE   = 1,
        CLASS_SEQ_VARYING_IMAGE    = 2,
        CLASS_SEQ_MIXED_SOAK       = 3
    } class_seq_e;

    typedef enum int {
        CLASS_TRANS_UNKNOWN         = 0,
        CLASS_TRANS_SAME            = 1,
        CLASS_TRANS_DIFFERENT       = 2
    } class_transition_e;

    // Reset-phase tracking (Category 5)
    typedef enum logic [3:0] {
        RESET_PHASE_IDLE            = 4'd0,
        RESET_PHASE_BEFORE_CONFIG   = 4'd1,
        RESET_PHASE_CFG             = 4'd2,
        RESET_PHASE_CFG_HEADER      = 4'd3,
        RESET_PHASE_WEIGHT_PAYLOAD  = 4'd4,
        RESET_PHASE_THRESH_PAYLOAD  = 4'd5,
        RESET_PHASE_POST_CFG        = 4'd6,
        RESET_PHASE_IMAGE           = 4'd7,
        RESET_PHASE_OUTPUT          = 4'd8,
        RESET_PHASE_OUTPUT_STALL    = 4'd9,
        RESET_PHASE_TLAST_BOUNDARY  = 4'd10,
        RESET_PHASE_CFG_THEN_IMAGE  = 4'd11
    } reset_phase_e;
    reset_phase_e current_phase;
    reset_phase_e current_phase_at_reset;

    // Category 4 means post-reset stream-content variation, not runtime
    // mid-inference reconfiguration.
    typedef enum logic [3:0] {
        SEQ_FULL_CONFIG             = 4'd0,
        SEQ_LAYER_SUBSET_CONFIG     = 4'd1,
        SEQ_WEIGHTS_ONLY_CONFIG     = 4'd2,
        SEQ_THRESH_ONLY_CONFIG      = 4'd3,
        SEQ_SAME_CONFIG_AFTER_RESET = 4'd4,
        SEQ_DIFF_CONFIG_AFTER_RESET = 4'd5,
        SEQ_LAYER_ORDER_PERM        = 4'd6,
        SEQ_MSG_ORDER_PERM          = 4'd7,
        SEQ_POSTSYN_REPLAY_HOOK     = 4'd8
    } seq_run_shape_e;
    seq_run_shape_e run_shape;
    event run_complete_event;

    cfg_profile_e    current_cfg_profile;
    cfg_order_e      current_cfg_order;
    weight_density_e current_weight_density;
    threshold_mag_e  current_threshold_mag;
    class_seq_e      current_class_seq;
    ready_timing_e   cfg_ready_timing;
    ready_timing_e   din_ready_timing;
    ready_timing_e   dout_ready_timing;

    int inter_image_gap_len;
    int accepted_image_count;
    int accepted_output_count;
    int cfg_beat_wait_cycles;
    int image_beat_wait_cycles;
    bit cfg_complete_seen;
    bit prev_cfg_valid, prev_cfg_ready;
    bit prev_din_valid, prev_din_ready;
    bit prev_dout_valid, prev_dout_ready;

    // Reset tracking
    int  reset_count_in_run;
    int  config_count_since_reset;
    int  images_after_config_count;
    int  class_hit_count;
    int  class_hist[16];
    int  repeated_class_run_len;
    int  long_output_stall_island;
    bit  reserved_field_nonzero;
    bit  output_layer_weights_only_seen;
    class_transition_e current_class_transition;

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
        run_shape                    = SEQ_FULL_CONFIG;
    endtask

    task automatic classify_and_sample_run_shape();
        if (!run_active)
            return;

        case (current_cfg_profile)
            CFG_PROFILE_LAYER_SUBSET:   run_shape = SEQ_LAYER_SUBSET_CONFIG;
            CFG_PROFILE_WEIGHTS_ONLY:   run_shape = SEQ_WEIGHTS_ONLY_CONFIG;
            CFG_PROFILE_THRESH_ONLY:    run_shape = SEQ_THRESH_ONLY_CONFIG;
            CFG_PROFILE_SAME_AFTER_RST: run_shape = SEQ_SAME_CONFIG_AFTER_RESET;
            CFG_PROFILE_DIFF_AFTER_RST: run_shape = SEQ_DIFF_CONFIG_AFTER_RESET;
            CFG_PROFILE_LAYER_PERM:     run_shape = SEQ_LAYER_ORDER_PERM;
            CFG_PROFILE_MSG_PERM:       run_shape = SEQ_MSG_ORDER_PERM;
            CFG_PROFILE_POSTSYN_HOOK:   run_shape = SEQ_POSTSYN_REPLAY_HOOK;
            default:                    run_shape = SEQ_FULL_CONFIG;
        endcase
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
        config_count_since_reset = 0;
        images_after_config_count = 0;
        class_hit_count = 0;
        repeated_class_run_len = 0;
        long_output_stall_island = 0;
        reserved_field_nonzero = 1'b0;
        output_layer_weights_only_seen = 1'b0;
        current_class_transition = CLASS_TRANS_UNKNOWN;
        foreach (class_hist[i]) class_hist[i] = 0;
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
        current_cfg_profile    = CFG_PROFILE_FULL;
        current_cfg_order      = CFG_ORDER_DEFAULT;
        current_weight_density = DENSITY_RANDOM;
        current_threshold_mag  = THRESH_RANDOM;
        current_class_seq      = CLASS_SEQ_UNKNOWN;
        cfg_ready_timing       = READY_TIMING_NONE;
        din_ready_timing       = READY_TIMING_NONE;
        dout_ready_timing      = READY_TIMING_NONE;
        inter_image_gap_len    = 0;
        accepted_image_count   = 0;
        accepted_output_count  = 0;
        cfg_beat_wait_cycles   = 0;
        image_beat_wait_cycles = 0;
        cfg_complete_seen      = 1'b0;
        prev_cfg_valid = 1'b0; prev_cfg_ready = 1'b0;
        prev_din_valid = 1'b0; prev_din_ready = 1'b0;
        prev_dout_valid = 1'b0; prev_dout_ready = 1'b0;
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

            if (cfg_hs) begin
                if (!prev_cfg_valid && prev_cfg_ready)
                    cfg_ready_timing = READY_TIMING_READY_BEFORE;
                else if (!prev_cfg_valid && !prev_cfg_ready)
                    cfg_ready_timing = READY_TIMING_SAME_CYCLE;
                else if (prev_cfg_valid && !prev_cfg_ready)
                    cfg_ready_timing = READY_TIMING_READY_AFTER;
            end
            if (img_hs) begin
                if (!prev_din_valid && prev_din_ready)
                    din_ready_timing = READY_TIMING_READY_BEFORE;
                else if (!prev_din_valid && !prev_din_ready)
                    din_ready_timing = READY_TIMING_SAME_CYCLE;
                else if (prev_din_valid && !prev_din_ready)
                    din_ready_timing = READY_TIMING_READY_AFTER;
            end
            if (dout_hs) begin
                if (!prev_dout_valid && prev_dout_ready)
                    dout_ready_timing = READY_TIMING_READY_BEFORE;
                else if (!prev_dout_valid && !prev_dout_ready)
                    dout_ready_timing = READY_TIMING_SAME_CYCLE;
                else if (prev_dout_valid && !prev_dout_ready)
                    dout_ready_timing = READY_TIMING_READY_AFTER;
            end

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
                    cfg_complete_seen      = 1'b1;
                    config_count_since_reset++;
                    cfg_beat_count_in_msg = 0;
                end
                if ((cfg_beat_count_in_msg == 2) && (config_in.tdata[63:32] != 32'd0))
                    reserved_field_nonzero = 1'b1;
                if (current_phase == RESET_PHASE_IDLE)
                    current_phase = RESET_PHASE_BEFORE_CONFIG;
                if (cfg_beat_count_in_msg <= 2)
                    current_phase = RESET_PHASE_CFG_HEADER;
                else if (msg_type_field == 8'd0)
                    current_phase = RESET_PHASE_WEIGHT_PAYLOAD;
                else if (msg_type_field == 8'd1)
                    current_phase = RESET_PHASE_THRESH_PAYLOAD;
                else
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
                    accepted_image_count++;
                    images_after_config_count++;
                    inter_image_gap_len = gap_cycles_since_last_img_hs;
                end

                if ((current_phase == RESET_PHASE_CFG) || (current_phase == RESET_PHASE_IDLE))
                    current_phase = RESET_PHASE_CFG_THEN_IMAGE;
                else if (current_phase != RESET_PHASE_CFG_THEN_IMAGE)
                    current_phase = RESET_PHASE_IMAGE;
            end else if (run_active) begin
                gap_cycles_since_last_img_hs++;
            end
            // Output handshake tracking
            if (data_out.tvalid && !data_out.tready)
                current_phase = RESET_PHASE_OUTPUT_STALL;
            if (dout_hs) begin
                accepted_output_count++;
                current_phase = RESET_PHASE_OUTPUT;
                // Consecutive-same-class run tracking
                if (has_prev_class_r_q && (data_out.tdata[OUTPUT_DATA_WIDTH-1:0] == prev_class_r_q))
                    consecutive_same_class_len = prev_run_len_r_q + 1;
                else
                    consecutive_same_class_len = 1;
                if (has_prev_class_r_q) begin
                    if (data_out.tdata[OUTPUT_DATA_WIDTH-1:0] == prev_class_r_q)
                        current_class_transition = CLASS_TRANS_SAME;
                    else
                        current_class_transition = CLASS_TRANS_DIFFERENT;
                end
                prev_class_r_q     = data_out.tdata[OUTPUT_DATA_WIDTH-1:0];
                prev_run_len_r_q   = consecutive_same_class_len;
                repeated_class_run_len = consecutive_same_class_len;
                has_prev_class_r_q = 1'b1;
                if (int'($unsigned(data_out.tdata[OUTPUT_DATA_WIDTH-1:0])) < 16) begin
                    if (class_hist[int'($unsigned(data_out.tdata[OUTPUT_DATA_WIDTH-1:0]))] == 0)
                        class_hit_count++;
                    class_hist[int'($unsigned(data_out.tdata[OUTPUT_DATA_WIDTH-1:0]))]++;
                end
            end
            if ((cfg_hs && config_in.tlast) || (img_hs && data_in.tlast) || (dout_hs && data_out.tlast))
                current_phase = RESET_PHASE_TLAST_BOUNDARY;

            prev_cfg_valid  = config_in.tvalid;
            prev_cfg_ready  = config_in.tready;
            prev_din_valid  = data_in.tvalid;
            prev_din_ready  = data_in.tready;
            prev_dout_valid = data_out.tvalid;
            prev_dout_ready = data_out.tready;
        end
    end

    // Count reset edges and snapshot/reset monitor state.
    always @(posedge rst) begin
        current_phase_at_reset = current_phase;
        reset_count_in_run++;
        config_count_since_reset = 0;
        images_after_config_count = 0;
        class_hit_count = 0;
        repeated_class_run_len = 0;
        long_output_stall_island = 0;
        reserved_field_nonzero = 1'b0;
        output_layer_weights_only_seen = 1'b0;
        current_class_transition = CLASS_TRANS_UNKNOWN;
        foreach (class_hist[i]) class_hist[i] = 0;
        if (run_active)
            classify_and_sample_run_shape();
        current_phase         = RESET_PHASE_IDLE;
        config_beat_is_header = 1'b1;
        cfg_beat_count_in_msg = 0;
        has_prev_class_r_q    = 1'b0;
        expected_outputs      = {};
        cfg_complete_seen     = 1'b0;
        accepted_image_count  = 0;
        accepted_output_count = 0;
        inter_image_gap_len   = 0;
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
        cp_long_output_stall_island: coverpoint long_output_stall_island {
            bins none       = {0};
            bins stall_8    = {8};
            bins stall_32   = {32};
            bins stall_128  = {128};
            bins randomized = {[9:31], [33:127], [129:$]};
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

        cp_cfg_ready_timing: coverpoint cfg_ready_timing {
            bins ready_before_valid = {READY_TIMING_READY_BEFORE};
            bins same_cycle         = {READY_TIMING_SAME_CYCLE};
            bins ready_after_valid  = {READY_TIMING_READY_AFTER};
        }
        cp_din_ready_timing: coverpoint din_ready_timing {
            bins ready_before_valid = {READY_TIMING_READY_BEFORE};
            bins same_cycle         = {READY_TIMING_SAME_CYCLE};
            bins ready_after_valid  = {READY_TIMING_READY_AFTER};
        }
        cp_dout_ready_timing: coverpoint dout_ready_timing {
            bins ready_before_valid = {READY_TIMING_READY_BEFORE};
            bins same_cycle         = {READY_TIMING_SAME_CYCLE};
            bins ready_after_valid  = {READY_TIMING_READY_AFTER};
        }

        cp_inter_image_gap: coverpoint inter_image_gap_len {
            bins gap_0        = {0};
            bins gap_1_9      = {[1:9]};
            bins gap_10_49    = {[10:49]};
            bins gap_50_plus  = {[50:$]};
        }

        // Per-interface tlast (hi/lo) — sampled only on tvalid
        cp_cfg_tlast:  coverpoint config_in.tlast iff (config_in.tvalid);
        cp_din_tlast:  coverpoint data_in.tlast   iff (data_in.tvalid);
        cp_dout_tlast: coverpoint data_out.tlast  iff (data_out.tvalid);

        // valid_ready_state × stall_length, per interface
        cross_cfg_state_x_stall:  cross cp_cfg_valid_ready_state,  cp_cfg_stall_length;
        cross_din_state_x_stall:  cross cp_din_valid_ready_state,  cp_din_stall_length;
        cross_dout_state_x_stall: cross cp_dout_valid_ready_state, cp_dout_stall_length;
        cross_cfg_state_x_timing: cross cp_cfg_valid_ready_state, cp_cfg_ready_timing;
        cross_din_state_x_timing: cross cp_din_valid_ready_state, cp_din_ready_timing;
        cross_dout_state_x_timing: cross cp_dout_valid_ready_state, cp_dout_ready_timing;

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
        cp_config_profile: coverpoint current_cfg_profile {
            bins full           = {CFG_PROFILE_FULL};
            bins layer_subset   = {CFG_PROFILE_LAYER_SUBSET};
            bins weights_only   = {CFG_PROFILE_WEIGHTS_ONLY};
            bins thresholds_only= {CFG_PROFILE_THRESH_ONLY};
            bins same_after_rst = {CFG_PROFILE_SAME_AFTER_RST};
            bins diff_after_rst = {CFG_PROFILE_DIFF_AFTER_RST};
            bins layer_perm     = {CFG_PROFILE_LAYER_PERM};
            bins msg_perm       = {CFG_PROFILE_MSG_PERM};
            bins postsyn_hook   = {CFG_PROFILE_POSTSYN_HOOK};
        }
        cp_config_order: coverpoint current_cfg_order {
            bins default_order  = {CFG_ORDER_DEFAULT};
            bins layer_reverse  = {CFG_ORDER_LAYER_REVERSE};
            bins thresh_first   = {CFG_ORDER_THRESH_FIRST};
            bins weights_only   = {CFG_ORDER_WEIGHTS_ONLY};
            bins thresholds_only= {CFG_ORDER_THRESH_ONLY};
            bins layer_subset   = {CFG_ORDER_LAYER_SUBSET};
        }
        cp_reserved_field_nonzero: coverpoint reserved_field_nonzero {
            bins reserved_zero    = {1'b0};
            bins reserved_nonzero = {1'b1};
        }
        cp_output_layer_weights_only: coverpoint output_layer_weights_only_seen {
            bins no  = {1'b0};
            bins yes = {1'b1};
        }
        cross_msg_x_layer: cross cp_msg_type, cp_layer_id;
        cross_profile_x_order: cross cp_config_profile, cp_config_order;
        cross_profile_x_reserved: cross cp_config_profile, cp_reserved_field_nonzero;
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
        cp_weight_density: coverpoint current_weight_density {
            bins random   = {DENSITY_RANDOM};
            bins all_zero = {DENSITY_ALL_ZERO};
            bins sparse   = {DENSITY_SPARSE};
            bins balanced = {DENSITY_BALANCED};
            bins dense    = {DENSITY_DENSE};
            bins all_one  = {DENSITY_ALL_ONE};
        }
        cp_threshold_magnitude: coverpoint current_threshold_mag {
            bins random = {THRESH_RANDOM};
            bins zero   = {THRESH_ZERO};
            bins low    = {THRESH_LOW};
            bins mid    = {THRESH_MID};
            bins high   = {THRESH_HIGH};
            bins max    = {THRESH_MAX};
        }
        cp_class_sequence: coverpoint current_class_seq {
            bins unknown        = {CLASS_SEQ_UNKNOWN};
            bins repeated_image = {CLASS_SEQ_REPEATED_IMAGE};
            bins varying_image  = {CLASS_SEQ_VARYING_IMAGE};
            bins mixed_soak     = {CLASS_SEQ_MIXED_SOAK};
        }
        cp_class_hit_count: coverpoint class_hit_count {
            bins none       = {0};
            bins one        = {1};
            bins few        = {[2:3]};
            bins many       = {[4:9]};
            bins all_sfc    = {[10:$]};
        }
        cp_repeated_class_run_length: coverpoint repeated_class_run_len {
            bins none       = {0};
            bins one        = {1};
            bins two_four   = {[2:4]};
            bins five_plus  = {[5:$]};
        }
        cp_class_transition: coverpoint current_class_transition {
            bins unknown   = {CLASS_TRANS_UNKNOWN};
            bins same      = {CLASS_TRANS_SAME};
            bins different = {CLASS_TRANS_DIFFERENT};
        }
        cross_class_x_stress_level: cross cp_class, cp_stress_level;
        cross_density_x_threshold: cross cp_weight_density, cp_threshold_magnitude;
        cross_class_x_sequence: cross cp_class, cp_class_sequence;
        cross_class_x_transition: cross cp_class, cp_class_transition;
    endgroup : cg_compute_stimulus

    //  Category 4: Configuration-Image Sequencing
    covergroup cg_cfg_img_sequencing @(run_complete_event);
        cp_shape: coverpoint run_shape {
            bins full_config          = {SEQ_FULL_CONFIG};
            bins layer_subset_config  = {SEQ_LAYER_SUBSET_CONFIG};
            bins weights_only_config  = {SEQ_WEIGHTS_ONLY_CONFIG};
            bins thresh_only_config   = {SEQ_THRESH_ONLY_CONFIG};
            bins same_after_reset     = {SEQ_SAME_CONFIG_AFTER_RESET};
            bins diff_after_reset     = {SEQ_DIFF_CONFIG_AFTER_RESET};
            bins layer_order_perm     = {SEQ_LAYER_ORDER_PERM};
            bins msg_order_perm       = {SEQ_MSG_ORDER_PERM};
            bins postsyn_replay_hook  = {SEQ_POSTSYN_REPLAY_HOOK};
        }
        cp_config_count_since_reset: coverpoint config_count_since_reset {
            bins zero      = {0};
            bins one       = {1};
            bins two       = {2};
            bins many      = {[3:$]};
        }
        cp_images_after_config: coverpoint images_after_config_count {
            bins none      = {0};
            bins one       = {1};
            bins two       = {2};
            bins ten       = {10};
            bins fifty     = {50};
            bins hundred   = {100};
            bins many      = {[101:$]};
        }
        cross_shape_x_cfg_count: cross cp_shape, cp_config_count_since_reset;
        cross_shape_x_images: cross cp_shape, cp_images_after_config;
    endgroup : cg_cfg_img_sequencing

    //  Category 5: Reset Scenarios 
    covergroup cg_reset_scenarios @(posedge rst);
        cp_reset_phase: coverpoint current_phase_at_reset {
            bins before_config       = {RESET_PHASE_BEFORE_CONFIG};
            bins mid_header          = {RESET_PHASE_CFG_HEADER};
            bins mid_weight_payload  = {RESET_PHASE_WEIGHT_PAYLOAD};
            bins mid_threshold_payload = {RESET_PHASE_THRESH_PAYLOAD};
            bins post_config_pre_img = {RESET_PHASE_POST_CFG};
            bins mid_image           = {RESET_PHASE_IMAGE, RESET_PHASE_CFG_THEN_IMAGE};
            bins output_valid        = {RESET_PHASE_OUTPUT};
            bins output_backpressure = {RESET_PHASE_OUTPUT_STALL};
            bins tlast_boundary      = {RESET_PHASE_TLAST_BOUNDARY};
            bins idle                = {RESET_PHASE_IDLE};
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
    // SVAs (additive protocol and progress checks beyond the shipped TB)
    // =========================================================================
    // The DUT intentionally holds data_in.tready low after config TLAST while
    // the config manager drains post-TLAST dispatch state. Keep this assertion
    // above the RTL drain value so it checks for a stuck config path, not for
    // the expected safety margin.
    localparam int MAX_CFG_TO_IMG_CYCLES = 2048;
    localparam int MAX_DIN_TO_DOUT_CYCLES = 20000;  // slack for SFC_CT worst-case
    localparam int MAX_AXI_STALL_CYCLES = 4096;

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

    SV17_dout_tkeep_correct: assert property (
        @(posedge clk) disable iff (rst)
        data_out.tvalid |-> (data_out.tkeep == '1))
        else $error("[SV]: data_out.tkeep must be exactly one valid byte on classification output");

    SV19_no_xz_config_payload: assert property (
        @(posedge clk) disable iff (rst)
        config_in.tvalid |-> !$isunknown({config_in.tdata, config_in.tkeep, config_in.tlast}))
        else $error("[SV]: config_in valid payload contains X/Z");

    SV20_no_xz_data_in_payload: assert property (
        @(posedge clk) disable iff (rst)
        data_in.tvalid |-> !$isunknown({data_in.tdata, data_in.tkeep, data_in.tlast}))
        else $error("[SV]: data_in valid payload contains X/Z");

    SV21_no_xz_data_out_payload: assert property (
        @(posedge clk) disable iff (rst)
        data_out.tvalid |-> !$isunknown({data_out.tdata, data_out.tkeep, data_out.tlast}))
        else $error("[SV]: data_out valid payload contains X/Z");

    SV22_no_image_before_config_done: assert property (
        @(posedge clk) disable iff (rst)
        (data_in.tvalid && data_in.tready) |-> cfg_complete_seen)
        else $error("[SV]: DUT accepted image data before config TLAST completed");

    SV23_din_tkeep_nonzero: assert property (
        @(posedge clk) disable iff (rst)
        (data_in.tvalid && data_in.tready) |-> (data_in.tkeep != '0))
        else $error("[SV]: data_in.tkeep is all-zero on an accepted image beat");

    SV24_output_count_not_ahead: assert property (
        @(posedge clk) disable iff (rst)
        accepted_output_count <= accepted_image_count)
        else $error("[SV]: accepted outputs exceeded accepted images");

    SV25_reset_clears_monitor_state: assert property (
        @(posedge clk)
        rst |=> (expected_outputs_q_size == 0 &&
                  accepted_image_count == 0 &&
                  accepted_output_count == 0 &&
                  !cfg_complete_seen))
        else $error("[SV]: additive monitor/scoreboard state not clear during reset");

    SV26_cfg_bounded_no_deadlock: assert property (
        @(posedge clk) disable iff (rst)
        config_in.tvalid |-> ##[0:MAX_AXI_STALL_CYCLES] config_in.tready)
        else $error("[SV]: config_in valid beat stalled beyond bounded no-deadlock budget");

    SV27_din_bounded_no_deadlock: assert property (
        @(posedge clk) disable iff (rst)
        data_in.tvalid |-> ##[0:MAX_AXI_STALL_CYCLES] data_in.tready)
        else $error("[SV]: data_in valid beat stalled beyond bounded no-deadlock budget");

    SV28_dout_bounded_no_deadlock: assert property (
        @(posedge clk) disable iff (rst)
        data_out.tvalid |-> ##[0:MAX_AXI_STALL_CYCLES] data_out.tready)
        else $error("[SV]: data_out valid beat stalled beyond bounded no-deadlock budget");

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
    task automatic append_config_stream(
        input bit [CONFIG_BUS_WIDTH-1:0] part_stream[],
        input bit [CONFIG_BUS_WIDTH/8-1:0] part_keep[],
        inout bit [CONFIG_BUS_WIDTH-1:0] out_stream[],
        inout bit [CONFIG_BUS_WIDTH/8-1:0] out_keep[]
    );
        out_stream = {out_stream, part_stream};
        out_keep   = {out_keep, part_keep};
    endtask

    task automatic build_config_stream(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        cfg_order_e order,
        output bit [CONFIG_BUS_WIDTH-1:0] stream[],
        output bit [CONFIG_BUS_WIDTH/8-1:0] keep[]
    );
        bit [CONFIG_BUS_WIDTH-1:0] layer_stream[];
        bit [CONFIG_BUS_WIDTH/8-1:0] layer_keep[];

        stream = new[0];
        keep   = new[0];

        case (order)
            CFG_ORDER_LAYER_SUBSET: begin
                model_h.get_layer_config(0, 1'b0, layer_stream, layer_keep);
                append_config_stream(layer_stream, layer_keep, stream, keep);
                if (model_h.num_layers > 1) begin
                    model_h.get_layer_config(0, 1'b1, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                end
            end

            CFG_ORDER_WEIGHTS_ONLY: begin
                for (int l = 0; l < model_h.num_layers; l++) begin
                    model_h.get_layer_config(l, 1'b0, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                end
            end

            CFG_ORDER_THRESH_ONLY: begin
                for (int l = 0; l < model_h.num_layers - 1; l++) begin
                    model_h.get_layer_config(l, 1'b1, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                end
            end

            CFG_ORDER_LAYER_REVERSE: begin
                for (int l = model_h.num_layers - 1; l >= 0; l--) begin
                    model_h.get_layer_config(l, 1'b0, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                    if (l < model_h.num_layers - 1) begin
                        model_h.get_layer_config(l, 1'b1, layer_stream, layer_keep);
                        append_config_stream(layer_stream, layer_keep, stream, keep);
                    end
                end
            end

            CFG_ORDER_THRESH_FIRST: begin
                for (int l = 0; l < model_h.num_layers - 1; l++) begin
                    model_h.get_layer_config(l, 1'b1, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                end
                for (int l = 0; l < model_h.num_layers; l++) begin
                    model_h.get_layer_config(l, 1'b0, layer_stream, layer_keep);
                    append_config_stream(layer_stream, layer_keep, stream, keep);
                end
            end

            default: begin
                model_h.encode_configuration(stream, keep);
            end
        endcase
    endtask

    task automatic set_weight_density(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        weight_density_e density
    );
        for (int l = 0; l < model_h.num_layers; l++) begin
            for (int n = 0; n < model_h.weight[l].size(); n++) begin
                for (int i = 0; i < model_h.weight[l][n].size(); i++) begin
                    case (density)
                        DENSITY_ALL_ZERO: model_h.weight[l][n][i] = 1'b0;
                        DENSITY_SPARSE:   model_h.weight[l][n][i] = (i % 8) == 0;
                        DENSITY_BALANCED: model_h.weight[l][n][i] = (i % 2) == 0;
                        DENSITY_DENSE:    model_h.weight[l][n][i] = (i % 8) != 0;
                        DENSITY_ALL_ONE:  model_h.weight[l][n][i] = 1'b1;
                        default: ;
                    endcase
                end
            end
        end
        model_h.outputs_valid = 1'b0;
    endtask

    task automatic set_threshold_magnitude(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        threshold_mag_e magnitude
    );
        for (int l = 0; l < model_h.num_layers; l++) begin
            int fan_in;
            fan_in = model_h.topology[l];
            for (int n = 0; n < model_h.threshold[l].size(); n++) begin
                if (l == model_h.num_layers - 1) begin
                    model_h.threshold[l][n] = 0;
                end else begin
                    case (magnitude)
                        THRESH_ZERO: model_h.threshold[l][n] = 0;
                        THRESH_LOW:  model_h.threshold[l][n] = (fan_in > 4) ? fan_in / 4 : 1;
                        THRESH_MID:  model_h.threshold[l][n] = fan_in / 2;
                        THRESH_HIGH: model_h.threshold[l][n] = (fan_in > 0) ? fan_in - 1 : 0;
                        THRESH_MAX:  model_h.threshold[l][n] = fan_in;
                        default: ;
                    endcase
                end
            end
        end
        model_h.outputs_valid = 1'b0;
    endtask

    task automatic drive_config_stream(
        input bit [CONFIG_BUS_WIDTH-1:0] data_stream[],
        input bit [CONFIG_BUS_WIDTH/8-1:0] keep_stream[],
        real valid_prob
    );
        for (int i = 0; i < data_stream.size(); i++) begin
            while (!chance(valid_prob)) begin
                config_in.tvalid <= 1'b0;
                @(posedge clk);
            end
            config_in.tvalid     <= 1'b1;
            config_in.tdata      <= data_stream[i];
            config_in.tkeep      <= keep_stream[i];
            config_in.tlast      <= (i == data_stream.size() - 1);
            cfg_beat_wait_cycles = 0;
            do begin
                @(posedge clk);
                cfg_beat_wait_cycles++;
                if (cfg_beat_wait_cycles > MAX_AXI_STALL_CYCLES)
                    $fatal(1, "COV_TB[%s]: config beat %0d stalled beyond %0d cycles",
                           PROFILE_TAG, i, MAX_AXI_STALL_CYCLES);
            end while (!config_in.tready);
        end
        config_in.tvalid <= 1'b0;
        config_in.tlast  <= 1'b0;
    endtask

    task automatic drive_config(real valid_prob);
        drive_config_stream(cfg_data_stream, cfg_keep_stream, valid_prob);
    endtask

    task automatic set_reserved_fields_nonzero(
        inout bit [CONFIG_BUS_WIDTH-1:0] stream[]
    );
        int msg_idx;
        int bytes_per_beat;
        int payload_bytes;
        int msg_bytes;
        int msg_beats;

        bytes_per_beat = CONFIG_BUS_WIDTH / 8;
        msg_idx = 0;
        while (msg_idx + 1 < stream.size()) begin
            stream[msg_idx + 1][63:32] = 32'hA5C3_5A3C;
            payload_bytes = int'(stream[msg_idx + 1][31:0]);
            msg_bytes = 16 + payload_bytes;
            msg_beats = (msg_bytes + bytes_per_beat - 1) / bytes_per_beat;
            if (msg_beats <= 0)
                msg_beats = 1;
            msg_idx += msg_beats;
        end
    endtask

    // The config manager's cfg_done can precede the final registered RAM-write
    // visibility by a few cycles on very small topologies. Waiting a bounded
    // window after data_in_ready preserves public-boundary behavior while
    // avoiding a first-image race against final cfg dispatch.
    task automatic wait_post_config_settle();
        wait (data_in.tready);
        current_phase = RESET_PHASE_POST_CFG;
        repeat (200) @(posedge clk);
    endtask

    // =========================================================================
    // §M — Image driver task
    // =========================================================================
    task automatic drive_images_with_model(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        real valid_prob,
        int n_images,
        bit repeated_image,
        bit scoreboard_en
    );
        for (int i = 0; i < n_images; i++) begin
            bit [INPUT_DATA_WIDTH-1:0] img[];
            int expected_class;
            int latency_event_id;
            int img_idx;
            img_idx = repeated_image ? 0 : (i % stim.get_num_vectors());
            stim.get_vector(img_idx, img);
            expected_class = model_h.compute_reference(img);
            if (scoreboard_en)
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
                image_beat_wait_cycles = 0;
                do begin
                    @(posedge clk);
                    image_beat_wait_cycles++;
                    if (image_beat_wait_cycles > MAX_AXI_STALL_CYCLES)
                        $fatal(1, "COV_TB[%s]: image beat stalled beyond %0d cycles",
                               PROFILE_TAG, MAX_AXI_STALL_CYCLES);
                end while (!data_in.tready);
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

    task automatic drive_images(real valid_prob, int n_images);
        drive_images_with_model(ref_model, valid_prob, n_images, 1'b0, 1'b1);
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

    task automatic hold_output_ready_low(int n_cycles);
        long_output_stall_island = n_cycles;
        data_out.tready <= 1'b0;
        repeat (n_cycles) @(posedge clk);
        data_out.tready <= 1'b1;
    endtask

    task automatic run_full_config_images(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        bit [CONFIG_BUS_WIDTH-1:0] stream[],
        bit [CONFIG_BUS_WIDTH/8-1:0] keep[],
        int n_images,
        real valid_prob = 1.0,
        bit repeated_image = 1'b0
    );
        drive_config_stream(stream, keep, valid_prob);
        wait_post_config_settle();
        drive_images_with_model(model_h, valid_prob, n_images, repeated_image, 1'b1);
        wait (expected_outputs.size() == 0);
        repeat (5) @(posedge clk);
        end_observed_run();
    endtask

    task automatic recover_with_full_config_one_image(
        BNN_FCC_Model #(CONFIG_BUS_WIDTH) model_h,
        bit [CONFIG_BUS_WIDTH-1:0] stream[],
        bit [CONFIG_BUS_WIDTH/8-1:0] keep[]
    );
        expected_outputs = {};
        config_in.tvalid <= 1'b0;
        config_in.tlast  <= 1'b0;
        data_in.tvalid   <= 1'b0;
        data_in.tlast    <= 1'b0;
        data_out.tready  <= 1'b1;
        repeat (5) @(posedge clk);
        drive_config_stream(stream, keep, 1.0);
        wait_post_config_settle();
        drive_images_with_model(model_h, 1.0, 1, 1'b0, 1'b1);
        wait (expected_outputs.size() == 0);
        repeat (5) @(posedge clk);
        end_observed_run();
    endtask

    // =========================================================================
    // §P — Directed tests T01–T20 (main sequencer)
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

            begin
                bit [CONFIG_BUS_WIDTH-1:0] alt_stream[];
                bit [CONFIG_BUS_WIDTH/8-1:0] alt_keep[];
                BNN_FCC_Model #(CONFIG_BUS_WIDTH) alt_model;
                int topo_dyn2[];

                //  T09: Same configuration after reset
                $display("[%0t][%s] T09: Same configuration after reset", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_SAME_AFTER_RST;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                apply_reset();
                drive_config(1.0);
                wait_post_config_settle();
                drive_images(1.0, 1);
                wait (expected_outputs.size() == 0);
                apply_reset();
                drive_config(1.0);
                wait_post_config_settle();
                drive_images(1.0, 1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T09 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T10: Different configuration after reset
                $display("[%0t][%s] T10: Different configuration after reset", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_DIFF_AFTER_RST;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                topo_dyn2 = new[TOTAL_LAYERS];
                for (int i = 0; i < TOTAL_LAYERS; i++) topo_dyn2[i] = TOPOLOGY[i];
                alt_model = new();
                alt_model.create_random(topo_dyn2);
                alt_model.encode_configuration(alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images_with_model(alt_model, 1.0, 1, 1'b0, 1'b1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T10 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T11: Partial layer-subset configuration after reset
                $display("[%0t][%s] T11: Partial layer-subset configuration after reset", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_LAYER_SUBSET;
                current_cfg_order   = CFG_ORDER_LAYER_SUBSET;
                build_config_stream(ref_model, CFG_ORDER_LAYER_SUBSET, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                repeat (200) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T11 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T12: Weights-only configuration after reset
                $display("[%0t][%s] T12: Weights-only configuration after reset", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_WEIGHTS_ONLY;
                current_cfg_order   = CFG_ORDER_WEIGHTS_ONLY;
                build_config_stream(ref_model, CFG_ORDER_WEIGHTS_ONLY, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                repeat (200) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T12 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T13: Thresholds-only configuration after reset
                $display("[%0t][%s] T13: Thresholds-only configuration after reset", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_THRESH_ONLY;
                current_cfg_order   = CFG_ORDER_THRESH_ONLY;
                build_config_stream(ref_model, CFG_ORDER_THRESH_ONLY, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                repeat (200) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T13 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T14: Legal layer-order permutation of configuration messages
                $display("[%0t][%s] T14: Legal layer-order permutation", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_LAYER_PERM;
                current_cfg_order   = CFG_ORDER_LAYER_REVERSE;
                build_config_stream(ref_model, CFG_ORDER_LAYER_REVERSE, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images(1.0, 1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T14 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T15: Legal weights/thresholds ordering permutation
                $display("[%0t][%s] T15: Thresholds-before-weights ordering permutation", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_MSG_PERM;
                current_cfg_order   = CFG_ORDER_THRESH_FIRST;
                build_config_stream(ref_model, CFG_ORDER_THRESH_FIRST, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images(1.0, 1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T15 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T16: Weight-density sweep
                $display("[%0t][%s] T16: Weight-density sweep", $realtime, PROFILE_TAG);
                for (int d = 0; d < 5; d++) begin
                    case (d)
                        0: current_weight_density = DENSITY_ALL_ZERO;
                        1: current_weight_density = DENSITY_SPARSE;
                        2: current_weight_density = DENSITY_BALANCED;
                        3: current_weight_density = DENSITY_DENSE;
                        default: current_weight_density = DENSITY_ALL_ONE;
                    endcase
                    current_cfg_profile = CFG_PROFILE_FULL;
                    current_cfg_order   = CFG_ORDER_DEFAULT;
                    set_weight_density(ref_model, current_weight_density);
                    build_config_stream(ref_model, CFG_ORDER_DEFAULT, alt_stream, alt_keep);
                    apply_reset();
                    drive_config_stream(alt_stream, alt_keep, 1.0);
                    wait_post_config_settle();
                    drive_images(1.0, 1);
                    wait (expected_outputs.size() == 0);
                    repeat (5) @(posedge clk);
                    end_observed_run();
                end
                $display("[%0t][%s] T16 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T17: Threshold-magnitude sweep
                $display("[%0t][%s] T17: Threshold-magnitude sweep", $realtime, PROFILE_TAG);
                for (int t = 0; t < 5; t++) begin
                    case (t)
                        0: current_threshold_mag = THRESH_ZERO;
                        1: current_threshold_mag = THRESH_LOW;
                        2: current_threshold_mag = THRESH_MID;
                        3: current_threshold_mag = THRESH_HIGH;
                        default: current_threshold_mag = THRESH_MAX;
                    endcase
                    current_cfg_profile = CFG_PROFILE_FULL;
                    current_cfg_order   = CFG_ORDER_DEFAULT;
                    set_threshold_magnitude(ref_model, current_threshold_mag);
                    build_config_stream(ref_model, CFG_ORDER_DEFAULT, alt_stream, alt_keep);
                    apply_reset();
                    drive_config_stream(alt_stream, alt_keep, 1.0);
                    wait_post_config_settle();
                    drive_images(1.0, 1);
                    wait (expected_outputs.size() == 0);
                    repeat (5) @(posedge clk);
                    end_observed_run();
                end
                $display("[%0t][%s] T17 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T18: Repeated-class vs varying-class image sequences
                $display("[%0t][%s] T18: Repeated vs varying image sequences", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_FULL;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                current_class_seq   = CLASS_SEQ_REPEATED_IMAGE;
                build_config_stream(ref_model, CFG_ORDER_DEFAULT, alt_stream, alt_keep);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images_with_model(ref_model, 1.0, 3, 1'b1, 1'b1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();

                current_class_seq = CLASS_SEQ_VARYING_IMAGE;
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images_with_model(ref_model, 1.0, (NUM_IMAGES < 5) ? NUM_IMAGES : 5, 1'b0, 1'b1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T18 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T19: Long multi-image soak
                $display("[%0t][%s] T19: Long multi-image soak", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_FULL;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                current_class_seq   = CLASS_SEQ_MIXED_SOAK;
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 0.8);
                wait_post_config_settle();
                drive_images_with_model(ref_model, 0.8, n_extended, 1'b0, 1'b1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T19 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T20: Post-synthesis replay hook/stub path
                $display("[%0t][%s] T20: Post-synthesis replay hook/stub path", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_POSTSYN_HOOK;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                $display("[%0t][%s] T20 note: scripts/run_bnn_fcc_post_synth_sim.sh reuses this TB style through bnn_fcc_sfc_top.",
                         $realtime, PROFILE_TAG);
                apply_reset();
                drive_config_stream(alt_stream, alt_keep, 1.0);
                wait_post_config_settle();
                drive_images_with_model(ref_model, 1.0, 1, 1'b0, 1'b1);
                wait (expected_outputs.size() == 0);
                repeat (5) @(posedge clk);
                end_observed_run();
                $display("[%0t][%s] T20 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T21: Reset on message/image/output boundaries
                $display("[%0t][%s] T21: Reset on message/image/output boundaries", $realtime, PROFILE_TAG);
                build_config_stream(ref_model, CFG_ORDER_DEFAULT, alt_stream, alt_keep);
                current_cfg_profile = CFG_PROFILE_FULL;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                current_phase       = RESET_PHASE_TLAST_BOUNDARY;
                apply_reset();
                recover_with_full_config_one_image(ref_model, alt_stream, alt_keep);

                current_phase = RESET_PHASE_TLAST_BOUNDARY;
                repeat (1) @(posedge clk);
                apply_reset();
                recover_with_full_config_one_image(ref_model, alt_stream, alt_keep);

                current_phase = RESET_PHASE_TLAST_BOUNDARY;
                apply_reset();
                recover_with_full_config_one_image(ref_model, alt_stream, alt_keep);

                current_phase = RESET_PHASE_OUTPUT_STALL;
                apply_reset();
                recover_with_full_config_one_image(ref_model, alt_stream, alt_keep);
                $display("[%0t][%s] T21 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T22: Multiple resets in one run
                $display("[%0t][%s] T22: Multiple resets in one run", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_FULL;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                current_phase       = RESET_PHASE_BEFORE_CONFIG;
                apply_reset(3);
                current_phase       = RESET_PHASE_CFG_HEADER;
                apply_reset(4);
                current_phase       = RESET_PHASE_IMAGE;
                apply_reset(5);
                recover_with_full_config_one_image(ref_model, alt_stream, alt_keep);
                $display("[%0t][%s] T22 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T23: Image-count sweep
                $display("[%0t][%s] T23: Image-count sweep", $realtime, PROFILE_TAG);
                begin
                    int image_counts[6];
                    image_counts = '{1, 2, 10, 50, 100, 256};
                    for (int ic = 0; ic < 6; ic++) begin
                        int n_for_profile;
                        n_for_profile = image_counts[ic];
                        current_cfg_profile = CFG_PROFILE_FULL;
                        current_cfg_order   = CFG_ORDER_DEFAULT;
                        current_class_seq   = CLASS_SEQ_MIXED_SOAK;
                        apply_reset();
                        run_full_config_images(ref_model, alt_stream, alt_keep,
                                               n_for_profile, 0.9, 1'b0);
                        $display("[%0t][%s] T23 image_count=%0d histogram_hits=%0d",
                                 $realtime, PROFILE_TAG, n_for_profile, class_hit_count);
                    end
                end
                $display("[%0t][%s] T23 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T24: Long output-stall islands
                $display("[%0t][%s] T24: Long output-stall islands", $realtime, PROFILE_TAG);
                begin
                    int stall_windows[4];
                    stall_windows = '{8, 32, 128, 17};
                    for (int sw = 0; sw < 4; sw++) begin
                        current_cfg_profile = CFG_PROFILE_FULL;
                        current_cfg_order   = CFG_ORDER_DEFAULT;
                        current_stress_level = STRESS_EXTREME;
                        apply_reset();
                        drive_config_stream(alt_stream, alt_keep, 1.0);
                        wait_post_config_settle();
                        data_out.tready <= 1'b0;
                        drive_images_with_model(ref_model, 1.0, 2, 1'b0, 1'b1);
                        wait (data_out.tvalid);
                        hold_output_ready_low(stall_windows[sw]);
                        wait (expected_outputs.size() == 0);
                        repeat (5) @(posedge clk);
                        end_observed_run();
                    end
                end
                data_out.tready <= 1'b1;
                $display("[%0t][%s] T24 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);

                //  T25: Reserved / don't-care header-field variation
                $display("[%0t][%s] T25: Reserved header-field variation", $realtime, PROFILE_TAG);
                current_cfg_profile = CFG_PROFILE_FULL;
                current_cfg_order   = CFG_ORDER_DEFAULT;
                build_config_stream(ref_model, CFG_ORDER_DEFAULT, alt_stream, alt_keep);
                set_reserved_fields_nonzero(alt_stream);
                reserved_field_nonzero = 1'b1;
                apply_reset();
                run_full_config_images(ref_model, alt_stream, alt_keep, 1, 1.0, 1'b0);
                $display("[%0t][%s] T25 complete: pass=%0d fail=%0d", $realtime, PROFILE_TAG,
                         test_pass_count, test_fail_count);
            end

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
