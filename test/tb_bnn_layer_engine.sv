`timescale 1ns/10ps

`ifndef ENG_TB_LAYER_IDX
`define ENG_TB_LAYER_IDX 0
`endif
`ifndef ENG_TB_FAN_IN
`define ENG_TB_FAN_IN 784
`endif
`ifndef ENG_TB_NUM_NEURONS
`define ENG_TB_NUM_NEURONS 256
`endif
`ifndef ENG_TB_P_W
`define ENG_TB_P_W 8
`endif
`ifndef ENG_TB_P_N
`define ENG_TB_P_N 8
`endif
`ifndef ENG_TB_NEXT_P_W
`define ENG_TB_NEXT_P_W 8
`endif
`ifndef ENG_TB_ACC_W
`define ENG_TB_ACC_W 10
`endif
`ifndef ENG_TB_IS_OUTPUT_LAYER
`define ENG_TB_IS_OUTPUT_LAYER 0
`endif
`ifndef ENG_TB_FANOUT_STAGES
`define ENG_TB_FANOUT_STAGES 0
`endif

module tb_bnn_layer_engine;

    // Parameters
    parameter int  LAYER_IDX       = `ENG_TB_LAYER_IDX;
    parameter int  FAN_IN          = `ENG_TB_FAN_IN;
    parameter int  NUM_NEURONS     = `ENG_TB_NUM_NEURONS;
    parameter int  P_W             = `ENG_TB_P_W;
    parameter int  P_N             = `ENG_TB_P_N;
    parameter int  NEXT_P_W        = `ENG_TB_NEXT_P_W;
    parameter int  ACC_W           = `ENG_TB_ACC_W;
    parameter bit  IS_OUTPUT_LAYER = `ENG_TB_IS_OUTPUT_LAYER;
    parameter int  LID_W           = 2;
    parameter int  FANOUT_STAGES   = `ENG_TB_FANOUT_STAGES;

    localparam int ITERS           = (FAN_IN + P_W - 1) / P_W;
    localparam int PASSES          = (NUM_NEURONS + P_N - 1) / P_N;
    localparam int WT_DEPTH        = ITERS * PASSES;
    localparam int REMAINDER       = NUM_NEURONS % P_N;
    localparam int LAST_PASS_COUNT = (REMAINDER == 0) ? P_N : REMAINDER;
    localparam int NP_ID_W         = (P_N > 1) ? $clog2(P_N) : 1;
    localparam int WT_ADDR_W       = $clog2((ITERS * PASSES) > 1 ? (ITERS * PASSES) : 2);

    // Generous image timeout: cover all PASSES × ITERS beats plus pipeline drain
    localparam int IMAGE_TIMEOUT   = (PASSES * ITERS + 20) * 20 + 500;
    localparam int B2B_IMAGES      = 16;
    localparam int CONTEST_IMAGES  = 24;
    localparam int START_IGNORE_OBS_CYCLES =
        (IMAGE_TIMEOUT > 4000) ? 4000 : IMAGE_TIMEOUT;

    // DUT interface
    logic                         clk = 1'b0;
    logic                         rst = 1'b1;

    logic                         start        = 1'b0;
    logic                         busy;
    logic                         done;

    logic                         s_valid      = 1'b0;
    logic                         s_ready;
    logic [P_W-1:0]               s_data       = '0;
    logic                         s_last       = 1'b0;

    logic                         m_valid;
    logic                         m_ready      = 1'b0;
    logic [NEXT_P_W-1:0]          m_data;
    logic                         m_last;

    logic                         score_valid;
    logic                         score_ready  = 1'b0;
    logic [NUM_NEURONS*ACC_W-1:0] score_data;
    logic                         score_last;

    logic                         cfg_wr_valid = 1'b0;
    logic                         cfg_wr_ready;
    logic [LID_W-1:0]             cfg_wr_layer = '0;
    logic [15:0]                  cfg_wr_np    = '0;
    logic [15:0]                  cfg_wr_addr  = '0;
    logic [P_W-1:0]               cfg_wr_data  = '0;

    logic                         cfg_thr_valid = 1'b0;
    logic                         cfg_thr_ready;
    logic [LID_W-1:0]             cfg_thr_layer = '0;
    logic [15:0]                  cfg_thr_np    = '0;
    logic [15:0]                  cfg_thr_addr  = '0;
    logic [31:0]                  cfg_thr_data  = '0;

    // Clock generation — 100 MHz
    always #5 clk = ~clk;

    // DUT instantiation
    bnn_layer_engine #(
        .LAYER_IDX       (LAYER_IDX),
        .FAN_IN          (FAN_IN),
        .NUM_NEURONS     (NUM_NEURONS),
        .P_W             (P_W),
        .P_N             (P_N),
        .NEXT_P_W        (NEXT_P_W),
        .ACC_W           (ACC_W),
        .IS_OUTPUT_LAYER (IS_OUTPUT_LAYER),
        .LID_W           (LID_W),
        .FANOUT_STAGES   (FANOUT_STAGES)
    ) DUT (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .s_valid        (s_valid),
        .s_ready        (s_ready),
        .s_data         (s_data),
        .s_last         (s_last),
        .m_valid        (m_valid),
        .m_ready        (m_ready),
        .m_data         (m_data),
        .m_last         (m_last),
        .score_valid    (score_valid),
        .score_ready    (score_ready),
        .score_data     (score_data),
        .score_last     (score_last),
        .cfg_wr_valid   (cfg_wr_valid),
        .cfg_wr_ready   (cfg_wr_ready),
        .cfg_wr_layer   (cfg_wr_layer),
        .cfg_wr_np      (cfg_wr_np),
        .cfg_wr_addr    (cfg_wr_addr),
        .cfg_wr_data    (cfg_wr_data),
        .cfg_thr_valid  (cfg_thr_valid),
        .cfg_thr_ready  (cfg_thr_ready),
        .cfg_thr_layer  (cfg_thr_layer),
        .cfg_thr_np     (cfg_thr_np),
        .cfg_thr_addr   (cfg_thr_addr),
        .cfg_thr_data   (cfg_thr_data)
    );

    // Shadow RAMs — mirrors DUT weight and threshold BRAMs per NP
    // The TB loads shadow_wt[j][addr] and shadow_thr[j][addr] alongside every
    // cfg_wr_valid / cfg_thr_valid transaction. The golden model reads from
    // these shadow arrays to compute expected output.
    logic [P_W-1:0]   shadow_wt  [P_N][WT_DEPTH];
    logic [ACC_W-1:0] shadow_thr [P_N][PASSES];    // THR_DEPTH = PASSES

    // Update shadow on every config write
    always @(posedge clk) begin
        if (!rst) begin
            if (cfg_wr_valid && cfg_wr_layer == LAYER_IDX[LID_W-1:0]) begin
                for (int j = 0; j < P_N; j++) begin
                    if (cfg_wr_np[NP_ID_W-1:0] == j[NP_ID_W-1:0])
                        shadow_wt[j][cfg_wr_addr[($clog2(WT_DEPTH)>1?$clog2(WT_DEPTH):1)-1:0]]
                            <= cfg_wr_data;
                end
            end
            if (cfg_thr_valid && cfg_thr_layer == LAYER_IDX[LID_W-1:0]) begin
                for (int j = 0; j < P_N; j++) begin
                    if (cfg_thr_np[NP_ID_W-1:0] == j[NP_ID_W-1:0])
                        shadow_thr[j][cfg_thr_addr[($clog2(PASSES)>1?$clog2(PASSES):1)-1:0]]
                            <= cfg_thr_data[ACC_W-1:0];
                end
            end
        end
    end

    // Output collector — gathers DUT output beats until *_last
    // Hidden mode: collect m_data beats until m_last=1
    logic [NEXT_P_W-1:0] out_beats[$];
    int                   out_beat_cnt = 0;

    // Output mode: collect score_data (one beat) on score_valid&&score_ready
    logic [NUM_NEURONS*ACC_W-1:0] out_score_beat;
    int                           out_score_cnt = 0;

    logic output_done = 1'b0;  // set when *_last is seen
    logic done_seen_sticky = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            out_beat_cnt  <= 0;
            out_score_cnt <= 0;
            output_done   <= 1'b0;
            done_seen_sticky <= 1'b0;
        end else begin
            if (!IS_OUTPUT_LAYER && m_valid && m_ready) begin
                out_beats.push_back(m_data);
                out_beat_cnt <= out_beat_cnt + 1;
                if (m_last) output_done <= 1'b1;
            end
            if (IS_OUTPUT_LAYER && score_valid && score_ready) begin
                out_score_beat <= score_data;
                out_score_cnt  <= out_score_cnt + 1;
                if (score_last) output_done <= 1'b1;
            end
            if (done) done_seen_sticky <= 1'b1;
        end
    end

    task automatic clear_output_collector();
        out_beats.delete();
        out_beat_cnt  = 0;
        out_score_cnt = 0;
        output_done   = 1'b0;
        done_seen_sticky = 1'b0;
    endtask

    // Scoreboard
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    function automatic void check(string name, logic cond, string msg = "");
        if (cond) pass_count++;
        else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", name, msg));
            $error("%s: %s", name, msg);
        end
    endfunction

    // SVAs

    // done is a single-cycle pulse.
    property p_done_single_cycle;
        @(posedge clk) disable iff (rst)
        done |=> !done;
    endproperty
    assert property (p_done_single_cycle)
    else $error("Assertion failed: done lasted more than 1 cycle");

    // start accepted when !busy → busy must be high next cycle.
    property p_busy_after_start;
        @(posedge clk) disable iff (rst)
        (start && !busy) |=> busy;
    endproperty
    assert property (p_busy_after_start)
    else $error("Assertion failed: busy not asserted after start");

    // AXI-stream hold on input when stalled.
    // s_data and s_valid must be stable while s_valid=1 and s_ready=0.
    property p_stream_in_stall;
        @(posedge clk) disable iff (rst)
        (s_valid && !s_ready) |=> ($stable(s_data) && s_valid);
    endproperty
    assert property (p_stream_in_stall)
    else $error("Assertion failed: s_data changed or s_valid dropped while stalled");

    // AXI-stream hold on hidden output when stalled.
    property p_hidden_out_stall;
        @(posedge clk) disable iff (rst)
        (!IS_OUTPUT_LAYER && m_valid && !m_ready) |=> ($stable(m_data) && m_valid);
    endproperty
    assert property (p_hidden_out_stall)
    else $error("Assertion failed: m_data changed or m_valid dropped while stalled");

    // AXI-stream hold on score output when stalled.
    property p_score_out_stall;
        @(posedge clk) disable iff (rst)
        (IS_OUTPUT_LAYER && score_valid && !score_ready) |=>
            ($stable(score_data) && score_valid);
    endproperty
    assert property (p_score_out_stall)
    else $error("Assertion failed: score_data changed while stalled");

    // Threshold write data upper bits must be zero. [H14]
    // threshold is ACC_W bits but arrives as 32-bit cfg_thr_data; bits above
    // ACC_W are silently truncated. TB enforces only legal values are written.
    property p_thr_upper_zero;
        @(posedge clk) disable iff (rst)
        cfg_thr_valid |-> (cfg_thr_data[31:ACC_W] == '0);
    endproperty
    assert property (p_thr_upper_zero)
    else $error("Assertion failed: cfg_thr_data[31:%0d] != 0 [H14]", ACC_W);

    // Internal NP valid must correspond to a previously accepted input
    // beat. This closes the explicit [H17] engine-integration hazard.
    property p_np_valid_after_accept;
        @(posedge clk) disable iff (rst)
        DUT.np_valid_in |-> $past(DUT.buf_valid && DUT.buf_ready);
    endproperty
    assert property (p_np_valid_after_accept)
    else $error("Assertion failed: np_valid_in without prior input accept");

    // The held NP input beat must equal the previously accepted replay
    // buffer beat when np_valid_in fires.
    property p_np_x_matches_accept;
        @(posedge clk) disable iff (rst)
        DUT.np_valid_in |-> (DUT.np_x_r_q == $past(DUT.buf_data));
    endproperty
    assert property (p_np_x_matches_accept)
    else $error("Assertion failed: held x beat mismatched accepted beat");

    // Covergroups

    covergroup cg_lifecycle @(posedge clk);
        cp_busy  : coverpoint busy;
        cp_done  : coverpoint done;
        cp_start : coverpoint start;
        x_start_busy : cross cp_start, cp_busy;  // (1,1)=ignored start, (1,0)=accepted
    endgroup

    covergroup cg_stream_in @(posedge clk);
        cp_sv : coverpoint s_valid;
        cp_sr : coverpoint s_ready;
        x_in  : cross cp_sv, cp_sr;  // all four corners
    endgroup

    covergroup cg_stream_out @(posedge clk);
        cp_ov : coverpoint (IS_OUTPUT_LAYER ? score_valid  : m_valid);
        cp_or : coverpoint (IS_OUTPUT_LAYER ? score_ready  : m_ready);
        x_out : cross cp_ov, cp_or;
    endgroup

    covergroup cg_geometry;
        cp_p_n   : coverpoint P_N             { bins b[] = {1, 2, 4, 8, 10, 16, 32}; }
        cp_p_w   : coverpoint P_W             { bins b[] = {1, 4, 8, 16}; }
        cp_layer : coverpoint LAYER_IDX       { bins b[] = {0, 1, 2}; }
        cp_mode  : coverpoint IS_OUTPUT_LAYER { bins b[] = {0, 1}; }
        x_mode_geom : cross cp_p_n, cp_mode;
    endgroup

    cg_lifecycle  cg_lc = new();
    cg_stream_in  cg_si = new();
    cg_stream_out cg_so = new();
    cg_geometry   cg_g  = new();

    // Reset task
    task automatic reset_dut(int cycles = 10);
        rst           <= 1'b1;
        start         <= 1'b0;
        s_valid       <= 1'b0;
        s_last        <= 1'b0;
        s_data        <= '0;
        m_ready       <= 1'b0;
        score_ready   <= 1'b0;
        cfg_wr_valid  <= 1'b0;
        cfg_thr_valid <= 1'b0;
        clear_output_collector();
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    // Config loader
    // Writes all weights and (if hidden mode) all thresholds into the DUT BRAMs
    // via the cfg_wr / cfg_thr ports.  Also writes into shadow arrays.
    // Weight layout: for NP j, address = pass*ITERS + iter stores the weight
    // word that lane j will use at that address (fed from BRAM during compute).
    // For the golden model to work, we index shadow_wt[j][addr] where
    // addr = pass*ITERS + iter.  The actual neuron processed by NP j at
    // pass p is neuron (p*P_N + j).
    task automatic load_config(
        input logic [P_W-1:0]   wt     [P_N][WT_DEPTH],
        input logic [ACC_W-1:0] thr    [P_N][PASSES]    // ignored if IS_OUTPUT_LAYER
    );
        // Write weights
        for (int j = 0; j < P_N; j++) begin
            for (int a = 0; a < WT_DEPTH; a++) begin
                @(posedge clk);
                cfg_wr_valid <= 1'b1;
                cfg_wr_layer <= LID_W'(LAYER_IDX);
                cfg_wr_np    <= 16'(j);
                cfg_wr_addr  <= 16'(a);
                cfg_wr_data  <= wt[j][a];
            end
        end
        @(posedge clk); cfg_wr_valid <= 1'b0;

        // Write thresholds (hidden mode only)
        if (!IS_OUTPUT_LAYER) begin
            for (int j = 0; j < P_N; j++) begin
                for (int p = 0; p < PASSES; p++) begin
                    @(posedge clk);
                    cfg_thr_valid <= 1'b1;
                    cfg_thr_layer <= LID_W'(LAYER_IDX);
                    cfg_thr_np    <= 16'(j);
                    cfg_thr_addr  <= 16'(p);
                    // Upper bits MUST be zero per [H14] and assertion
                    cfg_thr_data  <= 32'(thr[j][p]);
                end
            end
            @(posedge clk); cfg_thr_valid <= 1'b0;
        end
        repeat (3) @(posedge clk);
    endtask

    // Input stream driver
    // Drives ITERS beats of P_W-bit input data with s_valid/s_last.
    // valid_prob controls s_valid duty cycle (contest stress).
    task automatic drive_input_stream(
        input logic [P_W-1:0] img_data [ITERS],
        input real             valid_prob = 1.0
    );
        for (int i = 0; i < ITERS; i++) begin
            // Optional valid gap
            if (valid_prob < 1.0) begin
                while ($urandom_range(0,99) >= int'(valid_prob * 100)) begin
                    @(posedge clk); s_valid <= 1'b0; s_last <= 1'b0;
                end
            end
            @(posedge clk);
            s_valid <= 1'b1;
            s_data  <= img_data[i];
            s_last  <= (i == ITERS - 1);
            // Hold until handshake
            while (!s_ready) @(posedge clk);
        end
        @(posedge clk);
        s_valid <= 1'b0;
        s_last  <= 1'b0;
    endtask

    // Output drain — waits until output_done or timeout
    task automatic drain_output(
        input real  ready_prob = 1.0,
        input int   timeout = 0
    );
        int tmo = (timeout == 0) ? IMAGE_TIMEOUT : timeout;
        int t = 0;
        while (!output_done && t < tmo) begin
            @(posedge clk);
            t++;
            m_ready     <= (ready_prob >= 1.0) ? 1'b1 :
                           ($urandom_range(0,99) < int'(ready_prob * 100));
            score_ready <= (ready_prob >= 1.0) ? 1'b1 :
                           ($urandom_range(0,99) < int'(ready_prob * 100));
        end
        m_ready     <= 1'b1;
        score_ready <= 1'b1;
        // Drain any remaining stall
        if (!output_done) begin
            repeat (10) @(posedge clk);
        end
        check("drain_output_done", output_done,
              $sformatf("output_done not set after %0d cycles", tmo));
    endtask

    // Wait for done pulse with timeout
    task automatic wait_for_done(int timeout_cyc = 0);
        int tmo = (timeout_cyc == 0) ? IMAGE_TIMEOUT : timeout_cyc;
        int t = 0;
        while (!done_seen_sticky && t < tmo) begin
            @(posedge clk);
            t++;
        end
        check("done_seen", done_seen_sticky == 1'b1,
              $sformatf("done never asserted after %0d cycles", tmo));
        if (done) begin
            @(posedge clk);
            check("done_single_cycle", done == 1'b0,
                  "done still high one cycle after asserting");
        end else begin
            pass_count++;
        end
    endtask

    // Golden model
    // Computes expected output from the shadow RAMs and a provided image.
    // For hidden mode:
    //   For neuron n (= pass*P_N + lane_j):
    //     popcount[n] = sum_{i=0}^{ITERS-1} popcount(img[i] XNOR shadow_wt[j][pass*ITERS+i])
    //     activation[n] = (popcount[n] >= shadow_thr[j][pass])
    //   Pack into ceil(NUM_NEURONS / NEXT_P_W) output words LSB-first.
    // For output mode:
    //   score[n] = popcount[n]  (no threshold compare)
    //   score_data = all scores packed as {score[NUM_NEURONS-1], ..., score[0]}
    // Comparison: beat-accurate for hidden (compare out_beats[]), word compare
    // for output (compare out_score_beat).
    function automatic int popcount_pw(logic [P_W-1:0] v);
        int c = 0;
        for (int b = 0; b < P_W; b++) if (v[b]) c++;
        return c;
    endfunction

    task automatic verify_golden(
        input logic [P_W-1:0] img [ITERS],
        input string           test_name
    );
        int       accum    [NUM_NEURONS];
        logic     act      [NUM_NEURONS];
        logic [NUM_NEURONS*ACC_W-1:0] exp_score;
        logic [NUM_NEURONS-1:0]       exp_act_bits;

        // Compute popcount for each neuron
        for (int p = 0; p < PASSES; p++) begin
            for (int j = 0; j < P_N; j++) begin
                int n = p * P_N + j;
                if (n >= NUM_NEURONS) continue;
                accum[n] = 0;
                for (int i = 0; i < ITERS; i++) begin
                    logic [P_W-1:0] xnor_bits;
                    xnor_bits = img[i] ~^ shadow_wt[j][p * ITERS + i];
                    accum[n] += popcount_pw(xnor_bits);
                end
            end
        end

        if (!IS_OUTPUT_LAYER) begin
            // Hidden mode: compute activations then verify packed stream
            for (int n = 0; n < NUM_NEURONS; n++) begin
                logic exp_a;
                // threshold for neuron n: NP lane j=n%P_N, pass p=n/P_N
                int j = n % P_N;
                int p = n / P_N;
                exp_a = (ACC_W'(accum[n]) >= shadow_thr[j][p]);
                exp_act_bits[n] = exp_a;
            end

            // Build expected packed word stream (LSB = neuron 0)
            begin
                int exp_n_beats = (NUM_NEURONS + NEXT_P_W - 1) / NEXT_P_W;
                check($sformatf("%s_beat_count", test_name),
                      out_beats.size() == exp_n_beats,
                      $sformatf("got %0d beats expected %0d", out_beats.size(), exp_n_beats));

                for (int b = 0; b < exp_n_beats && b < out_beats.size(); b++) begin
                    logic [NEXT_P_W-1:0] exp_word = '0;
                    for (int bit_i = 0; bit_i < NEXT_P_W; bit_i++) begin
                        int neuron_idx = b * NEXT_P_W + bit_i;
                        if (neuron_idx < NUM_NEURONS)
                            exp_word[bit_i] = exp_act_bits[neuron_idx];
                    end
                    check($sformatf("%s_beat%0d", test_name, b),
                          out_beats[b] == exp_word,
                          $sformatf("DUT=0x%0h expected=0x%0h", out_beats[b], exp_word));
                end
            end

        end else begin
            // Output mode: verify score_data matches raw popcounts
            for (int n = 0; n < NUM_NEURONS; n++)
                exp_score[n*ACC_W +: ACC_W] = ACC_W'(accum[n]);

            check($sformatf("%s_score_beat_count", test_name),
                  out_score_cnt == 1,
                  $sformatf("got %0d score beats expected 1", out_score_cnt));

            check($sformatf("%s_score_data", test_name),
                  out_score_beat === exp_score,
                  $sformatf("score mismatch"));
        end
    endtask

    // Run one complete image end-to-end
    task automatic run_image(
        input logic [P_W-1:0] img   [ITERS],
        input real             in_valid_prob  = 1.0,
        input real             out_ready_prob = 1.0,
        input string           test_name      = "img"
    );
        clear_output_collector();

        // Pulse start (STATE.md §4.4: one cycle, only when !busy)
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Drive input stream and drain output concurrently
        fork
            drive_input_stream(img, in_valid_prob);
            drain_output(out_ready_prob);
        join

        // Wait for done
        wait_for_done();

        // Verify output
        verify_golden(img, test_name);

        repeat (5) @(posedge clk);
    endtask

    // Config initializer: all-zero weights, mid-range thresholds
    task automatic load_zero_weights_mid_thr();
        logic [P_W-1:0]   wt [P_N][WT_DEPTH];
        logic [ACC_W-1:0] th [P_N][PASSES];
        for (int j = 0; j < P_N; j++)
            for (int a = 0; a < WT_DEPTH; a++) wt[j][a] = '0;
        for (int j = 0; j < P_N; j++)
            for (int p = 0; p < PASSES; p++) th[j][p] = ACC_W'(FAN_IN / 2);
        load_config(wt, th);
    endtask

    task automatic load_random_config();
        logic [P_W-1:0]   wt [P_N][WT_DEPTH];
        logic [ACC_W-1:0] th [P_N][PASSES];
        for (int j = 0; j < P_N; j++)
            for (int a = 0; a < WT_DEPTH; a++) wt[j][a] = P_W'($urandom());
        for (int j = 0; j < P_N; j++)
            for (int p = 0; p < PASSES; p++)
                th[j][p] = ACC_W'($urandom_range(0, (1 << ACC_W) - 1));
        load_config(wt, th);
    endtask

    // �� Single image, all-zero weights → all activations 0 (hidden mode)
    task automatic test_t01_zero_weights();
        logic [P_W-1:0] img [ITERS];
        $display("Running: zero weights, random image, hidden mode");
        if (IS_OUTPUT_LAYER) begin $display("Skipped (IS_OUTPUT_LAYER=1)"); pass_count++; return; end
        reset_dut();
        load_zero_weights_mid_thr();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 1.0, "T01_zero_weights");
    endtask

    // �� Single image, random weights, hidden mode
    task automatic test_t02_random_hidden();
        logic [P_W-1:0] img [ITERS];
        $display("Running: random weights, random image, hidden mode");
        if (IS_OUTPUT_LAYER) begin $display("Skipped (IS_OUTPUT_LAYER=1)"); pass_count++; return; end
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 1.0, "T02_random_hidden");
    endtask

    // �� Single image, output mode
    task automatic test_t03_output_mode();
        logic [P_W-1:0] img [ITERS];
        $display("Running: random weights, output mode");
        if (!IS_OUTPUT_LAYER) begin $display("Skipped (IS_OUTPUT_LAYER=0)"); pass_count++; return; end
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 1.0, "T03_output_mode");
    endtask

    // Back-to-back images, no gap
    task automatic test_t04_back_to_back();
        logic [P_W-1:0] img [ITERS];
        $display("Running: %0d back-to-back images", B2B_IMAGES);
        reset_dut();
        load_random_config();
        for (int n = 0; n < B2B_IMAGES; n++) begin
            for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
            run_image(img, 1.0, 1.0, $sformatf("T04_img%0d", n));
        end
    endtask

    // Input backpressure: contest stress (valid_prob=0.8)
    task automatic test_t05_input_bp();
        logic [P_W-1:0] img [ITERS];
        $display("Running: input backpressure valid_prob=0.8");
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 0.8, 1.0, "T05_in_bp");
    endtask

    // Output backpressure: contest stress (ready_prob=0.5)
    task automatic test_t06_output_bp();
        logic [P_W-1:0] img [ITERS];
        $display("Running: output backpressure ready_prob=0.5");
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 0.5, "T06_out_bp");
    endtask

    // Combined contest stress: in=0.8, out=0.5
    task automatic test_t07_contest_stress();
        logic [P_W-1:0] img [ITERS];
        $display("Running: combined contest stress (in=0.8, out=0.5), %0d images",
                 CONTEST_IMAGES);
        reset_dut();
        load_random_config();
        for (int n = 0; n < CONTEST_IMAGES; n++) begin
            for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
            run_image(img, 0.8, 0.5, $sformatf("T07_img%0d", n));
        end
    endtask

    // start ignored while busy
    task automatic test_t08_start_while_busy();
        logic [P_W-1:0] img [ITERS];
        int   extra_done;
        int   busy_reassert;
        $display("Running: start pulse while busy must be ignored");
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        clear_output_collector();

        // Launch a normal image
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        // While busy, fire a spurious start — should be ignored
        repeat (3) @(posedge clk);
        check("T08_busy_during_test", busy == 1'b1,
              "busy not asserted — image didn't start?");
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        // Drive inputs with m_ready=1 and drain
        m_ready     <= 1'b1;
        score_ready <= 1'b1;
        drive_input_stream(img, 1.0);
        wait_for_done();

        // Verify there is exactly ONE done pulse (the spurious start was ignored)
        extra_done = 0;
        busy_reassert = 0;
        repeat (START_IGNORE_OBS_CYCLES) begin
            @(posedge clk);
            if (done) extra_done++;
            if (busy) busy_reassert++;
        end
        check("T08_no_second_done", extra_done == 0,
              $sformatf("extra done pulses seen=%0d (spurious start was NOT ignored)", extra_done));
        check("T08_busy_stays_low", busy_reassert == 0,
              $sformatf("busy reasserted for %0d cycles after completion", busy_reassert));
    endtask

    // Reset mid-image then clean recovery
    task automatic test_t09_reset_recovery();
        logic [P_W-1:0] img [ITERS];
        $display("Running: reset mid-image then clean recovery");
        reset_dut();
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());

        // Start image
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        // Drive a few input beats
        for (int i = 0; i < ITERS/2; i++) begin
            @(posedge clk);
            s_valid <= 1'b1; s_data <= img[i];
            s_last  <= (i == ITERS-1);
            while (!s_ready) @(posedge clk);
        end
        @(posedge clk); s_valid <= 1'b0;

        // Reset
        rst <= 1'b1;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        check("T09_busy_zero_after_reset", busy == 1'b0,
              $sformatf("busy=%0b after reset", busy));
        check("T09_done_zero_after_reset", done == 1'b0,
              $sformatf("done=%0b after reset", done));

        // Run a clean image after reset; need to reload config (RAMs persist across reset)
        load_random_config();
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 1.0, "T09_clean_after_reset");
    endtask

    // Config write to wrong layer: shadow unchanged
    task automatic test_t10_wrong_layer_write();
        int wrong_layer;
        logic [P_W-1:0] original_wt [P_N][WT_DEPTH];
        logic [P_W-1:0] img [ITERS];
        $display("Running: config write to wrong layer, weights unchanged");
        reset_dut();
        load_random_config();

        // Save shadow state
        for (int j = 0; j < P_N; j++)
            for (int a = 0; a < WT_DEPTH; a++)
                original_wt[j][a] = shadow_wt[j][a];

        // Write to a different layer (LAYER_IDX XOR 1 mod 2^LID_W)
        wrong_layer = (LAYER_IDX ^ 1) & ((1 << LID_W) - 1);
        for (int j = 0; j < P_N; j++) begin
            for (int a = 0; a < WT_DEPTH; a++) begin
                @(posedge clk);
                cfg_wr_valid <= 1'b1;
                cfg_wr_layer <= LID_W'(wrong_layer);
                cfg_wr_np    <= 16'(j);
                cfg_wr_addr  <= 16'(a);
                cfg_wr_data  <= P_W'($urandom());
            end
        end
        @(posedge clk); cfg_wr_valid <= 1'b0;
        repeat (3) @(posedge clk);

        // Shadow should be unchanged
        begin
            logic mismatch = 1'b0;
            for (int j = 0; j < P_N; j++)
                for (int a = 0; a < WT_DEPTH; a++)
                    if (shadow_wt[j][a] !== original_wt[j][a]) mismatch = 1'b1;
            check("T10_shadow_unchanged", !mismatch,
                  "Shadow weights changed after wrong-layer write");
        end

        // Run image with original weights — should still be correct
        for (int i = 0; i < ITERS; i++) img[i] = P_W'($urandom());
        run_image(img, 1.0, 1.0, "T10_orig_weights_still_valid");
    endtask

    // Main test sequence
    initial begin
        $display("=====================================================");
        $display(" tb_bnn_layer_engine — Level-1 CRV + Golden Model");
        $display(" LAYER=%0d FAN_IN=%0d NUM_NEURONS=%0d P_W=%0d P_N=%0d",
                 LAYER_IDX, FAN_IN, NUM_NEURONS, P_W, P_N);
        $display(" NEXT_P_W=%0d ACC_W=%0d IS_OUTPUT=%0b FANOUT=%0d",
                 NEXT_P_W, ACC_W, IS_OUTPUT_LAYER, FANOUT_STAGES);
        $display(" ITERS=%0d PASSES=%0d LAST_PASS_COUNT=%0d",
                 ITERS, PASSES, LAST_PASS_COUNT);
        $display(" B2B_IMAGES=%0d CONTEST_IMAGES=%0d",
                 B2B_IMAGES, CONTEST_IMAGES);
        $display("=====================================================");

        cg_g.sample();

        test_t01_zero_weights();
        test_t02_random_hidden();
        test_t03_output_mode();
        test_t04_back_to_back();
        test_t05_input_bp();
        test_t06_output_bp();
        test_t07_contest_stress();
        test_t08_start_while_busy();
        test_t09_reset_recovery();
        test_t10_wrong_layer_write();

        repeat (20) @(posedge clk);

        $display("");
        $display("=====================================================");
        $display(" SCOREBOARD SUMMARY — tb_bnn_layer_engine");
        $display("=====================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failures ---");
            foreach (fail_log[i]) $display("    %s", fail_log[i]);
        end
        $display("  Lifecycle CG : %.1f%%", cg_lc.get_coverage());
        $display("  Stream-In CG : %.1f%%", cg_si.get_coverage());
        $display("  Stream-Out CG: %.1f%%", cg_so.get_coverage());
        $display("  Geometry CG  : %.1f%%", cg_g.get_coverage());
        $display("=====================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("=====================================================");

        $finish;
    end

endmodule
