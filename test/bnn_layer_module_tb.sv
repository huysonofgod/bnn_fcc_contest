`timescale 1ns / 100ps

module bnn_layer_module_tb #(
    parameter int  LAYER_IDX       = 0,
    parameter int  FAN_IN          = 16,
    parameter int  NUM_NEURONS     = 8,
    parameter int  P_W             = 4,
    parameter int  P_N             = 4,
    parameter int  NEXT_P_W        = 4,
    parameter int  ACC_W           = 8,
    parameter bit  IS_OUTPUT_LAYER = 1'b0,
    parameter int  LID_W           = 2,
    parameter int  NUM_TEST_VECS   = 20,
    parameter int  RAND_SEED       = 32'hDEAD_BEEF
);

    // Localparams
    localparam int ITERS     = (FAN_IN + P_W - 1) / P_W;
    localparam int PASSES    = (NUM_NEURONS + P_N - 1) / P_N;
    localparam int WT_DEPTH  = ITERS * PASSES;
    localparam int THR_DEPTH = PASSES;

    // DUT Interface Signals
    logic                          clk = 1'b0;
    logic                          rst;

    logic                          start;
    logic                          busy;
    logic                          done;

    logic                          s_valid;
    logic                          s_ready;
    logic [P_W-1:0]                s_data;
    logic                          s_last;

    logic                          m_valid;
    logic                          m_ready;
    logic [NEXT_P_W-1:0]           m_data;
    logic                          m_last;

    logic                          score_valid;
    logic                          score_ready;
    logic [NUM_NEURONS*ACC_W-1:0]  score_data;
    logic                          score_last;

    logic                          cfg_wr_valid;
    logic                          cfg_wr_ready;
    logic [LID_W-1:0]              cfg_wr_layer;
    logic [15:0]                   cfg_wr_np;
    logic [15:0]                   cfg_wr_addr;
    logic [P_W-1:0]                cfg_wr_data;

    logic                          cfg_thr_valid;
    logic                          cfg_thr_ready;
    logic [LID_W-1:0]              cfg_thr_layer;
    logic [15:0]                   cfg_thr_np;
    logic [15:0]                   cfg_thr_addr;
    logic [31:0]                   cfg_thr_data;

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    // DUT Instantiation
    bnn_layer_module #(
        .LAYER_IDX       (LAYER_IDX),
        .FAN_IN          (FAN_IN),
        .NUM_NEURONS     (NUM_NEURONS),
        .P_W             (P_W),
        .P_N             (P_N),
        .NEXT_P_W        (NEXT_P_W),
        .ACC_W           (ACC_W),
        .IS_OUTPUT_LAYER (IS_OUTPUT_LAYER),
        .LID_W           (LID_W),
        .FANOUT_STAGES   (0)
    ) DUT (.*);

    // Transaction Type Definition
    typedef struct {
        bit [FAN_IN-1:0]      input_bits;
        bit                   exp_y        [NUM_NEURONS];
        bit [ACC_W-1:0]       exp_popcount [NUM_NEURONS];
        int                   vec_id;
    } trans_t;

    // Observed result from monitor
    typedef struct {
        bit [NUM_NEURONS-1:0] actual_bits;   // hidden layer
        bit [ACC_W-1:0]       actual_scores [NUM_NEURONS]; // output layer
        int                   vec_id;
    } obs_t;

    // Communication Channels (Mailboxes)
    mailbox #(trans_t) gen2drv = new();
    mailbox #(trans_t) drv2sb  = new();
    mailbox #(obs_t)   mon2sb  = new();

    // Reference Model Storage
    bit                golden_weights    [NUM_NEURONS][FAN_IN];
    bit [ACC_W-1:0]    golden_thresholds [NUM_NEURONS];

    // Functional Coverage
    // Coverage sampling signals
    logic cov_start, cov_busy, cov_done;
    logic cov_s_valid, cov_s_ready, cov_m_valid, cov_m_ready;
    logic cov_score_valid, cov_score_ready;

    always @(posedge clk) begin
        cov_start       = start;
        cov_busy        = busy;
        cov_done        = done;
        cov_s_valid     = s_valid;
        cov_s_ready     = s_ready;
        cov_m_valid     = m_valid;
        cov_m_ready     = m_ready;
        cov_score_valid = score_valid;
        cov_score_ready = score_ready;
    end

    covergroup cg_functional @(posedge clk iff (!rst));
        // Control signal transitions
        cp_start: coverpoint cov_start {
            bins idle    = {1'b0};
            bins active  = {1'b1};
        }
        cp_busy: coverpoint cov_busy {
            bins idle    = {1'b0};
            bins active  = {1'b1};
        }
        cp_done: coverpoint cov_done {
            bins idle    = {1'b0};
            bins pulse   = {1'b1};
        }
        // Input handshake
        cp_s_handshake: coverpoint {cov_s_valid, cov_s_ready} {
            bins both_hi  = {2'b11};
            bins v_no_r   = {2'b10};
            bins idle     = {2'b00};
        }
        // Output handshake (hidden)
        cp_m_handshake: coverpoint {cov_m_valid, cov_m_ready} {
            bins both_hi  = {2'b11};
            bins v_no_r   = {2'b10};
            bins idle     = {2'b00};
        }
        // Output handshake (score)
        cp_score_handshake: coverpoint {cov_score_valid, cov_score_ready} {
            bins both_hi  = {2'b11};
            bins v_no_r   = {2'b10};
            bins idle     = {2'b00};
        }
        // Cross: start while busy (should not happen in well-behaved TB)
        cx_start_busy: cross cp_start, cp_busy;
    endgroup
    cg_functional cg_inst = new();

    // Scoreboard Counters
    int pass_count = 0;
    int fail_count = 0;
    int test_count = 0;

    // Reset Task (Timing Rule 3)
    task automatic reset_dut(int cycles = 8);
        @(posedge clk);
        rst           <= 1'b1;
        start         <= 1'b0;
        s_valid       <= 1'b0;
        s_data        <= '0;
        s_last        <= 1'b0;
        m_ready       <= 1'b1;
        score_ready   <= 1'b1;
        cfg_wr_valid  <= 1'b0;
        cfg_wr_layer  <= '0;
        cfg_wr_np     <= '0;
        cfg_wr_addr   <= '0;
        cfg_wr_data   <= '0;
        cfg_thr_valid <= 1'b0;
        cfg_thr_layer <= '0;
        cfg_thr_np    <= '0;
        cfg_thr_addr  <= '0;
        cfg_thr_data  <= '0;
        repeat (cycles) @(posedge clk);
        @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    // Reference Model Generation
    function automatic void generate_random_model();
        for (int n = 0; n < NUM_NEURONS; n++) begin
            for (int b = 0; b < FAN_IN; b++)
                golden_weights[n][b] = $urandom_range(0, 1);
            golden_thresholds[n] = $urandom_range(FAN_IN/4, (3*FAN_IN)/4);
        end
    endfunction

    // Reference Compute (single vector → expected outputs)
    function automatic void compute_reference(
        input  bit [FAN_IN-1:0]   input_bits,
        output bit                exp_y        [NUM_NEURONS],
        output bit [ACC_W-1:0]    exp_popcount [NUM_NEURONS]
    );
        int popcount;
        for (int n = 0; n < NUM_NEURONS; n++) begin
            popcount = 0;
            for (int b = 0; b < FAN_IN; b++)
                if (input_bits[b] == golden_weights[n][b]) popcount++;
            exp_popcount[n] = popcount[ACC_W-1:0];
            exp_y[n] = (popcount >= golden_thresholds[n]) ? 1'b1 : 1'b0;
        end
    endfunction

    // RAM Preload Task — drives cfg_wr_*/cfg_thr_* per interleaving rule
    // Interleaving:
    //   np_id          = neuron % P_N
    //   local_pass     = neuron / P_N
    //   wt_local_addr  = local_pass * ITERS + word_idx
    //   thr_local_addr = local_pass
    // Padding: final partial word (FAN_IN % P_W != 0) padded with 1s per spec
    task automatic preload_layer_rams();
        int np_id, local_pass, wt_local_addr, thr_local_addr;
        bit [P_W-1:0] word_val;
        int bit_idx;

        $display("[%0t] PRELOAD: starting weight RAM preload (FAN_IN=%0d ITERS=%0d PASSES=%0d)",
                 $realtime, FAN_IN, ITERS, PASSES);

        // Weight preload        for (int n = 0; n < NUM_NEURONS; n++) begin
            np_id      = n % P_N;
            local_pass = n / P_N;

            for (int w = 0; w < ITERS; w++) begin
                word_val = '0;
                for (int k = 0; k < P_W; k++) begin
                    bit_idx = w * P_W + k;
                    if (bit_idx < FAN_IN)
                        word_val[k] = golden_weights[n][bit_idx];
                    else
                        word_val[k] = 1'b1;  // pad with 1s per spec
                end

                wt_local_addr = local_pass * ITERS + w;

                @(posedge clk);
                cfg_wr_valid <= 1'b1;
                cfg_wr_layer <= LAYER_IDX[LID_W-1:0];
                cfg_wr_np    <= np_id[15:0];
                cfg_wr_addr  <= wt_local_addr[15:0];
                cfg_wr_data  <= word_val;
            end
        end
        @(posedge clk);
        cfg_wr_valid <= 1'b0;

        // Threshold preload (hidden layers only)        if (!IS_OUTPUT_LAYER) begin
            $display("[%0t] PRELOAD: starting threshold RAM preload", $realtime);
            for (int n = 0; n < NUM_NEURONS; n++) begin
                np_id          = n % P_N;
                local_pass     = n / P_N;
                thr_local_addr = local_pass;

                @(posedge clk);
                cfg_thr_valid <= 1'b1;
                cfg_thr_layer <= LAYER_IDX[LID_W-1:0];
                cfg_thr_np    <= np_id[15:0];
                cfg_thr_addr  <= thr_local_addr[15:0];
                cfg_thr_data  <= {{(32-ACC_W){1'b0}}, golden_thresholds[n]};
            end
            @(posedge clk);
            cfg_thr_valid <= 1'b0;
        end

        $display("[%0t] PRELOAD: complete", $realtime);
        repeat (5) @(posedge clk);
    endtask

    // Start Pulse Driver — issue one start per image
    task automatic issue_start();
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
    endtask

    // Input Vector Driver — streams binary input word-by-word with handshake
    task automatic drive_input_vector(input bit [FAN_IN-1:0] input_bits);
        bit [P_W-1:0] word_val;
        int bit_idx;

        for (int w = 0; w < ITERS; w++) begin
            word_val = '0;
            for (int k = 0; k < P_W; k++) begin
                bit_idx = w * P_W + k;
                if (bit_idx < FAN_IN)
                    word_val[k] = input_bits[bit_idx];
                else
                    word_val[k] = 1'b0;  // input padding is 0s
            end

            @(posedge clk);
            s_valid <= 1'b1;
            s_data  <= word_val;
            s_last  <= (w == ITERS - 1);

            // Wait for handshake acceptance
            forever begin
                @(posedge clk);
                if (s_valid && s_ready) break;
            end
        end

        @(posedge clk);
        s_valid <= 1'b0;
        s_last  <= 1'b0;
    endtask

    // Result Capture — Hidden Layer (M4 packed binary words)
    task automatic capture_hidden_result(
        output bit [NUM_NEURONS-1:0] actual_bits
    );
        int bits_collected = 0;
        actual_bits = '0;

        while (bits_collected < NUM_NEURONS) begin
            @(posedge clk);
            if (m_valid && m_ready) begin
                for (int k = 0; k < NEXT_P_W; k++) begin
                    if (bits_collected < NUM_NEURONS) begin
                        actual_bits[bits_collected] = m_data[k];
                        bits_collected++;
                    end
                end
                if (m_last) break;
            end
        end
    endtask

    // Result Capture — Output Layer (M5 flat score vector)
    task automatic capture_output_result(
        output bit [ACC_W-1:0] actual_scores [NUM_NEURONS]
    );
        forever begin
            @(posedge clk);
            if (score_valid && score_ready) begin
                for (int n = 0; n < NUM_NEURONS; n++)
                    actual_scores[n] = score_data[n*ACC_W +: ACC_W];
                return;
            end
        end
    endtask

    // Run One Image — start + drive + capture + compare
    task automatic run_one_image(
        input  bit [FAN_IN-1:0] input_bits,
        input  bit              exp_y        [NUM_NEURONS],
        input  bit [ACC_W-1:0]  exp_popcount [NUM_NEURONS],
        input  int              vec_id
    );
        bit [NUM_NEURONS-1:0] actual_bits;
        bit [ACC_W-1:0]       actual_scores [NUM_NEURONS];

        // Issue start pulse
        issue_start();

        // Drive input vector and capture result in parallel
        fork
            drive_input_vector(input_bits);
            begin
                if (!IS_OUTPUT_LAYER) begin
                    capture_hidden_result(actual_bits);
                end else begin
                    capture_output_result(actual_scores);
                end
            end
        join

        // Compare against golden model
        if (!IS_OUTPUT_LAYER) begin
            for (int n = 0; n < NUM_NEURONS; n++) begin
                test_count++;
                if (actual_bits[n] !== exp_y[n]) begin
                    fail_count++;
                    $error("[vec %0d] neuron %0d: y mismatch (got %0b, exp %0b, popcount=%0d, threshold=%0d)",
                           vec_id, n, actual_bits[n], exp_y[n],
                           exp_popcount[n], golden_thresholds[n]);
                end else begin
                    pass_count++;
                end
            end
        end else begin
            for (int n = 0; n < NUM_NEURONS; n++) begin
                test_count++;
                if (actual_scores[n] !== exp_popcount[n]) begin
                    fail_count++;
                    $error("[vec %0d] neuron %0d: score mismatch (got %0d, exp %0d)",
                           vec_id, n, actual_scores[n], exp_popcount[n]);
                end else begin
                    pass_count++;
                end
            end
        end
    endtask

    // Generator Process
    // Produces constrained-random input vectors with expected outputs
    int gen_done = 0;
    // Hoisted up so earlier initial blocks can wait on it.
    int directed_done = 0;

    initial begin : generator
        trans_t tx;

        wait (!rst);
        // Wait for directed tests to complete
        wait (directed_done);
        repeat (5) @(posedge clk);

        $display("Generator: Starting random stress: %0d vectors", NUM_TEST_VECS);

        for (int v = 0; v < NUM_TEST_VECS; v++) begin
            for (int b = 0; b < FAN_IN; b++)
                tx.input_bits[b] = $urandom_range(0, 1);
            tx.vec_id = 1000 + v;
            compute_reference(tx.input_bits, tx.exp_y, tx.exp_popcount);
            gen2drv.put(tx);
        end
        gen_done = 1;
        $display("Generator: All %0d random vectors generated", NUM_TEST_VECS);
    end

    // Driver Process
    // Pulls transactions from gen2drv, drives start + input vector, forwards
    // expected data to scoreboard
    initial begin : driver
        trans_t tx;

        wait (!rst);
        wait (directed_done);

        forever begin
            if (gen2drv.try_get(tx)) begin
                // Issue start pulse
                issue_start();

                // Forward expected to scoreboard
                drv2sb.put(tx);

                // Drive the input vector
                drive_input_vector(tx.input_bits);

                // Small inter-image gap
                repeat (2) @(posedge clk);
            end else if (gen_done) begin
                break;
            end else begin
                @(posedge clk);
            end
        end
    end

    // Monitor Process
    // Captures DUT outputs at posedge (Timing Rule 4)
    initial begin : monitor
        obs_t obs;

        wait (!rst);
        wait (directed_done);

        forever begin
            @(posedge clk);
            if (!IS_OUTPUT_LAYER) begin
                if (m_valid && m_ready) begin
                    // Accumulate bits from M4 packer
                    automatic int bits_collected = 0;
                    automatic bit [NUM_NEURONS-1:0] result_bits = '0;

                    // First beat already detected
                    for (int k = 0; k < NEXT_P_W; k++) begin
                        if (bits_collected < NUM_NEURONS) begin
                            result_bits[bits_collected] = m_data[k];
                            bits_collected++;
                        end
                    end

                    if (!m_last) begin
                        while (bits_collected < NUM_NEURONS) begin
                            @(posedge clk);
                            if (m_valid && m_ready) begin
                                for (int k = 0; k < NEXT_P_W; k++) begin
                                    if (bits_collected < NUM_NEURONS) begin
                                        result_bits[bits_collected] = m_data[k];
                                        bits_collected++;
                                    end
                                end
                                if (m_last) break;
                            end
                        end
                    end

                    obs.actual_bits = result_bits;
                    mon2sb.put(obs);
                end
            end else begin
                if (score_valid && score_ready) begin
                    for (int n = 0; n < NUM_NEURONS; n++)
                        obs.actual_scores[n] = score_data[n*ACC_W +: ACC_W];
                    mon2sb.put(obs);
                end
            end
        end
    end

    // Scoreboard Process
    // Compares expected (from drv2sb) vs observed (from mon2sb)
    int random_pass = 0;
    int random_fail = 0;
    int sb_done = 0;

    initial begin : scoreboard
        trans_t expected;
        obs_t   observed;
        int sb_count = 0;

        wait (!rst);
        wait (directed_done);

        while (sb_count < NUM_TEST_VECS) begin
            drv2sb.get(expected);
            mon2sb.get(observed);

            if (!IS_OUTPUT_LAYER) begin
                for (int n = 0; n < NUM_NEURONS; n++) begin
                    if (observed.actual_bits[n] !== expected.exp_y[n]) begin
                        random_fail++;
                        $error("Scoreboard: vec %0d neuron %0d: y mismatch (got %0b, exp %0b)",
                               expected.vec_id, n, observed.actual_bits[n], expected.exp_y[n]);
                    end else begin
                        random_pass++;
                    end
                end
            end else begin
                for (int n = 0; n < NUM_NEURONS; n++) begin
                    if (observed.actual_scores[n] !== expected.exp_popcount[n]) begin
                        random_fail++;
                        $error("Scoreboard: vec %0d neuron %0d: score mismatch (got %0d, exp %0d)",
                               expected.vec_id, n, observed.actual_scores[n], expected.exp_popcount[n]);
                    end else begin
                        random_pass++;
                    end
                end
            end

            sb_count++;
        end

        sb_done = 1;
        $display("Scoreboard: Random stress complete: %0d pass, %0d fail", random_pass, random_fail);
    end

    // SVA Properties (Gray Box — White Box Layer)

    // A1: busy asserts within 2 cycles after start pulse
    property p_busy_after_start;
        @(posedge clk) disable iff (rst)
            $rose(start) |-> ##[1:2] busy;
    endproperty
    a_busy_after_start: assert property (p_busy_after_start)
        else $error("SVA: busy did not assert after start");

    // A2: done is a single-cycle pulse (does not stay high for 2 cycles)
    property p_done_single_pulse;
        @(posedge clk) disable iff (rst)
            done |=> !done;
    endproperty
    a_done_single_pulse: assert property (p_done_single_pulse)
        else $error("SVA: done held high for >1 cycle");

    // A3: No X/Z on m_data when m_valid is asserted (hidden layer)
    generate if (IS_OUTPUT_LAYER == 1'b0) begin : g_sva_hidden
        property p_no_x_m_data;
            @(posedge clk) disable iff (rst)
                m_valid |-> !$isunknown(m_data);
        endproperty
        a_no_x_m_data: assert property (p_no_x_m_data)
            else $error("SVA: X/Z on m_data while m_valid");
    end endgenerate

    // A4: No X/Z on score_data when score_valid is asserted (output layer)
    generate if (IS_OUTPUT_LAYER == 1'b1) begin : g_sva_output
        property p_no_x_score_data;
            @(posedge clk) disable iff (rst)
                score_valid |-> !$isunknown(score_data);
        endproperty
        a_no_x_score_data: assert property (p_no_x_score_data)
            else $error("SVA: X/Z on score_data while score_valid");
    end endgenerate

    // A5: start should not be asserted while busy (protocol)
    property p_no_start_while_busy;
        @(posedge clk) disable iff (rst)
            busy |-> !start;
    endproperty
    a_no_start_while_busy: assert property (p_no_start_while_busy)
        else $warning("SVA: start asserted while busy — potential protocol violation");

    // Directed Test: LM-DT2 — busy/done pulse correctness
    task automatic test_lm_dt2_busy_done();
        bit [FAN_IN-1:0] input_bits;
        bit              exp_y        [NUM_NEURONS];
        bit [ACC_W-1:0]  exp_popcount [NUM_NEURONS];
        int done_seen = 0;

        $display("Directed check: busy_done_pulse_correctness — start");

        // Generate a simple input
        for (int b = 0; b < FAN_IN; b++)
            input_bits[b] = $urandom_range(0, 1);
        compute_reference(input_bits, exp_y, exp_popcount);

        // Monitor done pulse in parallel with image processing
        fork
            run_one_image(input_bits, exp_y, exp_popcount, 2);
            begin : done_watcher
                // Wait for done pulse
                forever begin
                    @(posedge clk);
                    if (done) begin
                        done_seen++;
                        // Verify it's exactly 1 cycle
                        @(posedge clk);
                        if (done) begin
                            $error("Directed check: done held high for >1 cycle");
                            fail_count++;
                        end
                        break;
                    end
                end
            end
        join

        if (done_seen == 1) begin
            $display("Directed check: done pulse observed correctly");
            pass_count++;
            test_count++;
        end else begin
            $error("Directed check: done pulse not observed");
            fail_count++;
            test_count++;
        end

        repeat (5) @(posedge clk);
        $display("Directed check: busy_done_pulse_correctness — done");
    endtask

    // Directed Test: LM-ST2 — output backpressure
    // Toggle m_ready/score_ready off and on to test backpressure handling
    task automatic test_lm_st2_backpressure();
        bit [FAN_IN-1:0] input_bits;
        bit              exp_y        [NUM_NEURONS];
        bit [ACC_W-1:0]  exp_popcount [NUM_NEURONS];

        $display("Stress check: output_backpressure — start");

        for (int b = 0; b < FAN_IN; b++)
            input_bits[b] = $urandom_range(0, 1);
        compute_reference(input_bits, exp_y, exp_popcount);

        // Start a backpressure toggler in parallel
        fork
            run_one_image(input_bits, exp_y, exp_popcount, 90);
            begin : bp_toggler
                // Toggle output ready every few cycles
                forever begin
                    repeat ($urandom_range(2, 5)) @(posedge clk);
                    if (!IS_OUTPUT_LAYER)
                        m_ready <= 1'b0;
                    else
                        score_ready <= 1'b0;
                    repeat ($urandom_range(1, 3)) @(posedge clk);
                    if (!IS_OUTPUT_LAYER)
                        m_ready <= 1'b1;
                    else
                        score_ready <= 1'b1;
                end
            end
        join_any
        disable fork;

        // Restore ready signals
        @(posedge clk);
        m_ready     <= 1'b1;
        score_ready <= 1'b1;

        repeat (5) @(posedge clk);
        $display("Stress check: output_backpressure — done");
    endtask

    // Main Test Sequence
    initial begin : main_test
        bit [FAN_IN-1:0]      input_bits;
        bit                   exp_y        [NUM_NEURONS];
        bit [ACC_W-1:0]       exp_popcount [NUM_NEURONS];

        $timeformat(-9, 0, " ns", 0);
        $display("=============================================================");
        $display("  bnn_layer_module_tb (CRV+)");
        $display("  LAYER_IDX=%0d FAN_IN=%0d NUM_NEURONS=%0d",
                 LAYER_IDX, FAN_IN, NUM_NEURONS);
        $display("  P_W=%0d P_N=%0d NEXT_P_W=%0d ACC_W=%0d",
                 P_W, P_N, NEXT_P_W, ACC_W);
        $display("  IS_OUTPUT_LAYER=%0b NUM_TEST_VECS=%0d",
                 IS_OUTPUT_LAYER, NUM_TEST_VECS);
        $display("  ITERS=%0d PASSES=%0d WT_DEPTH=%0d THR_DEPTH=%0d",
                 ITERS, PASSES, WT_DEPTH, THR_DEPTH);
        $display("=============================================================");

        // Seed RNG
        void'($urandom(RAND_SEED));

        // Generate golden model
        generate_random_model();

        // Reset
        reset_dut();

        // Preload RAMs
        preload_layer_rams();

        // Directed Tests
        // WB-DT2/DT3: basic multi-vector test (proves preload + compute path)
        $display("Directed run: Running %0d directed golden-model vectors...", 5);
        for (int v = 0; v < 5; v++) begin
            for (int b = 0; b < FAN_IN; b++)
                input_bits[b] = $urandom_range(0, 1);
            compute_reference(input_bits, exp_y, exp_popcount);
            run_one_image(input_bits, exp_y, exp_popcount, v);
            repeat (3) @(posedge clk);
        end

        // LM-DT2: busy/done pulse correctness
        test_lm_dt2_busy_done();

        // LM-ST2: output backpressure
        test_lm_st2_backpressure();

        // TB-DT6: threshold boundary classification (hidden layers only)
        if (!IS_OUTPUT_LAYER) begin
            $display("Boundary check: threshold_boundary_classification — start");
            // Create known threshold boundary test
            // Set all weights to 1 for neuron 0, so XNOR with all-1 input = FAN_IN
            // Set threshold to FAN_IN/2 exactly
            begin
                automatic bit old_w [FAN_IN];
                automatic bit [ACC_W-1:0] old_thr;

                // Save originals
                for (int b = 0; b < FAN_IN; b++)
                    old_w[b] = golden_weights[0][b];
                old_thr = golden_thresholds[0];

                // Set neuron 0 weights all-1
                for (int b = 0; b < FAN_IN; b++)
                    golden_weights[0][b] = 1'b1;
                golden_thresholds[0] = FAN_IN / 2;

                // Re-preload (need re-reset to clear NP state)
                reset_dut();
                preload_layer_rams();

                // Test 1: input all-1 → popcount = FAN_IN → exp_y=1 (FAN_IN >= FAN_IN/2)
                input_bits = '1;
                for (int b = FAN_IN; b < $bits(input_bits); b++)
                    input_bits[b] = 0;
                compute_reference(input_bits, exp_y, exp_popcount);
                run_one_image(input_bits, exp_y, exp_popcount, 60);
                repeat (3) @(posedge clk);

                // Test 2: input all-0 → XNOR with all-1 weights = 0 matches → popcount=0
                input_bits = '0;
                compute_reference(input_bits, exp_y, exp_popcount);
                run_one_image(input_bits, exp_y, exp_popcount, 61);
                repeat (3) @(posedge clk);

                // Restore originals
                for (int b = 0; b < FAN_IN; b++)
                    golden_weights[0][b] = old_w[b];
                golden_thresholds[0] = old_thr;

                // Re-preload with original model
                reset_dut();
                preload_layer_rams();
            end
            $display("Boundary check: threshold_boundary_classification — done");
        end

        // LM-ST1: multi_vector_back_to_back (no idle between images)
        $display("Stress check: multi_vector_back_to_back — start");
        for (int v = 0; v < 10; v++) begin
            for (int b = 0; b < FAN_IN; b++)
                input_bits[b] = $urandom_range(0, 1);
            compute_reference(input_bits, exp_y, exp_popcount);
            run_one_image(input_bits, exp_y, exp_popcount, 100 + v);
            // Minimal idle (just 1 cycle between images)
            @(posedge clk);
        end
        $display("Stress check: multi_vector_back_to_back — done");

        $display("-------------------------------------------------------------");
        $display("  Directed tests complete: %0d pass, %0d fail",
                 pass_count, fail_count);
        $display("-------------------------------------------------------------");

        // Signal directed tests done — start random stress via gen/drv/mon/sb
        directed_done = 1;

        // Wait for random stress scoreboard to complete or timeout
        fork
            begin
                wait (sb_done);
                repeat (50) @(posedge clk);
            end
            begin
                #5ms;
                $display("Timeout: Random stress did not complete in time");
            end
        join_any
        disable fork;

        // Final Report        $display("=============================================================");
        $display("  DIRECTED: %0d pass, %0d fail", pass_count, fail_count);
        $display("  RANDOM:   %0d pass, %0d fail", random_pass, random_fail);
        $display("  TOTAL:    %0d pass, %0d fail",
                 pass_count + random_pass, fail_count + random_fail);
        $display("  Coverage: %.1f%%", cg_inst.get_coverage());
        $display("=============================================================");

        if (fail_count == 0 && random_fail == 0)
            $display("*** TEST PASSED ***");
        else
            $display("*** TEST FAILED ***");

        $finish;
    end

    // Watchdog timeout
    initial begin : timeout
        #10ms;
        $error("TIMEOUT: simulation exceeded 10 ms");
        $finish;
    end

endmodule
