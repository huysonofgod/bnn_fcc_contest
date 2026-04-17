`timescale 1ns/10ps

module bnn_score_collector_tb;

    //
    // Parameters
    //
    parameter int P_N         = 8;
    parameter int NUM_NEURONS = 10;
    parameter int ACC_W       = 8;

    localparam int PASSES   = (NUM_NEURONS + P_N - 1) / P_N;   // 2
    localparam int SCORE_W  = NUM_NEURONS * ACC_W;              // 80
    localparam int NP_CNT_W = $clog2(P_N + 1);
    localparam int REMAINDER = NUM_NEURONS % P_N;               // 2
    localparam int LAST_PASS_COUNT = (REMAINDER == 0) ? P_N : REMAINDER; // 2

    //
    // DUT Interface Signals
    //
    logic                  clk = 0;
    logic                  rst = 1;
    logic                  s_valid;
    logic                  s_ready;
    logic [P_N*ACC_W-1:0]  s_scores;
    logic [NP_CNT_W-1:0]   s_count;
    logic                  s_last_pass;
    logic                  m_valid;
    logic                  m_ready;
    logic [SCORE_W-1:0]    m_scores;
    logic                  m_last;

    //
    // Clock Generation (100 MHz)
    //
    always #5 clk = ~clk;

    //
    // DUT Instantiation
    //
    bnn_score_collector #(
        .P_N         (P_N),
        .NUM_NEURONS (NUM_NEURONS),
        .ACC_W       (ACC_W)
    ) DUT (
        .clk         (clk),
        .rst         (rst),
        .s_valid     (s_valid),
        .s_ready     (s_ready),
        .s_scores    (s_scores),
        .s_count     (s_count),
        .s_last_pass (s_last_pass),
        .m_valid     (m_valid),
        .m_ready     (m_ready),
        .m_scores    (m_scores),
        .m_last      (m_last)
    );

    //
    // SVA Properties (Gray Box)
    //

    //
    // SVA-1: m_last always equals m_valid -- the score collector outputs one
    // result per image, so every valid output is also the last output.
    // RATIONALE: Downstream expects m_last to mark single-shot results.
    //
    property p_m_last_equals_m_valid;
        @(posedge clk) disable iff (rst)
        m_valid == m_last;
    endproperty
    assert property (p_m_last_equals_m_valid)
    else $error("[SVA] FAIL: m_last != m_valid");

    //
    // SVA-2: m_valid rises only after s_last_pass handshake -- output is only
    // valid after all neuron passes have been collected.
    // RATIONALE: m_valid is registered, and assertion sampling observes the
    // rise one cycle later; allow the triggering handshake in the prior 1-2
    // cycles to match the documented registered timing.
    //
    property p_m_valid_after_last_pass;
        @(posedge clk) disable iff (rst)
        $rose(m_valid) |-> (
            $past(s_valid && s_last_pass && s_ready, 1) ||
            $past(s_valid && s_last_pass && s_ready, 2)
        );
    endproperty
    assert property (p_m_valid_after_last_pass)
    else $error("[SVA] FAIL: m_valid rose without prior s_last_pass handshake");

    //
    // SVA-3: AXI-Stream valid-hold on output -- once m_valid asserts, it stays
    // high until m_ready completes the handshake.
    // RATIONALE: AXI4-Stream protocol compliance.
    //
    property p_m_valid_hold;
        @(posedge clk) disable iff (rst)
        $rose(m_valid) |-> (m_valid until_with m_ready);
    endproperty
    assert property (p_m_valid_hold)
    else $error("[SVA] FAIL: m_valid dropped without m_ready handshake");

    //
    // SVA-4: m_scores stable during backpressure
    // RATIONALE: Data must not change while waiting for consumption.
    //
    property p_m_scores_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> $stable(m_scores);
    endproperty
    assert property (p_m_scores_stable)
    else $error("[SVA] FAIL: m_scores changed during backpressure");

    //
    // SVA-5: s_ready deasserts during OUTPUT and CLEAR states
    // RATIONALE: Collector cannot accept input while outputting or clearing.
    //
    property p_s_ready_in_collect;
        @(posedge clk) disable iff (rst)
        (DUT.u_fsm.state_r != DUT.u_fsm.COLLECT) |-> !s_ready;
    endproperty
    assert property (p_s_ready_in_collect)
    else $error("[SVA] FAIL: s_ready asserted outside COLLECT state");

    //
    // Covergroups
    //

    //
    // COVERGROUP: Covers s_count values, s_last_pass, score value ranges,
    // and output backpressure events.
    //
    covergroup cg_collector @(posedge clk iff (!rst));
        // Cover s_count values
        cp_s_count: coverpoint s_count iff (s_valid && s_ready) {
            bins full_v    = {P_N};
            bins partial_v = {[1:P_N-1]};
        }

        // Cover s_last_pass
        cp_last_pass: coverpoint s_last_pass iff (s_valid && s_ready) {
            bins more_v  = {0};
            bins final_v = {1};
        }

        // Cover score values (first neuron's score)
        cp_scores: coverpoint s_scores[ACC_W-1:0] iff (s_valid && s_ready) {
            bins zero_v = {0};
            bins low_v  = {[1:127]};
            bins high_v = {[128:255]};
        }

        // Cover output backpressure
        cp_output_stall: coverpoint {m_valid, m_ready} {
            bins stall = {2'b10};
            bins flow  = {2'b11};
        }

        // Cover FSM states
        cp_state: coverpoint DUT.u_fsm.state_r {
            bins collect = {DUT.u_fsm.COLLECT};
            bins output_s = {DUT.u_fsm.OUTPUT};
            bins clear_s  = {DUT.u_fsm.CLEAR};
        }
    endgroup

    cg_collector cg_inst = new();

    //
    // Reference Model
    //
    logic [ACC_W-1:0] ref_score_bank [0:NUM_NEURONS-1];

    function automatic void ref_clear();
        for (int i = 0; i < NUM_NEURONS; i++)
            ref_score_bank[i] = '0;
    endfunction

    function automatic void ref_store(
        input logic [P_N*ACC_W-1:0] scores,
        input int                    count,
        input int                    pass_idx
    );
        int base_idx;
        base_idx = pass_idx * P_N;
        for (int i = 0; i < count; i++) begin
            if ((base_idx + i) < NUM_NEURONS)
                ref_score_bank[base_idx + i] = scores[i*ACC_W +: ACC_W];
        end
    endfunction

    function automatic logic [SCORE_W-1:0] ref_flatten();
        logic [SCORE_W-1:0] flat;
        for (int j = 0; j < NUM_NEURONS; j++)
            flat[j*ACC_W +: ACC_W] = ref_score_bank[j];
        return flat;
    endfunction

    //
    // Scoreboard
    //
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    function automatic void check(string test_name, logic cond, string msg = "");
        if (cond) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
            $error("[SB] %s: %s", test_name, msg);
        end
    endfunction

    //
    // Reset Task
    //
    task automatic reset_dut();
        rst         <= 1'b1;
        s_valid     <= 1'b0;
        s_scores    <= '0;
        s_count     <= '0;
        s_last_pass <= 1'b0;
        m_ready     <= 1'b0;
        ref_clear();
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    //
    // Helper: Send one pass of scores and optionally check output
    //
    task automatic send_pass(
        input logic [P_N*ACC_W-1:0] scores,
        input int                    count,
        input logic                  last_pass_flag,
        input int                    pass_idx
    );
        // Drive slave interface
        @(posedge clk);
        s_valid     <= 1'b1;
        s_scores    <= scores;
        s_count     <= NP_CNT_W'(count);
        s_last_pass <= last_pass_flag;

        @(posedge clk);
        while (!s_ready) @(posedge clk);
        s_valid     <= 1'b0;
        s_last_pass <= 1'b0;

        // Update reference model
        ref_store(scores, count, pass_idx);
    endtask

    //
    // Helper: Collect output and compare with reference
    //
    task automatic collect_output(string test_name, real ready_prob);
        logic [SCORE_W-1:0] expected;
        int timeout;

        expected = ref_flatten();

        timeout = 0;
        while (!m_valid && timeout < 1000) begin
            @(posedge clk);
            timeout++;
        end

        check($sformatf("%s_m_valid", test_name), m_valid,
              "m_valid did not assert");

        // Apply backpressure
        if (ready_prob < 1.0) begin
            m_ready <= 1'b0;
            repeat ($urandom_range(1, 5)) @(posedge clk);
        end

        m_ready <= 1'b1;
        @(posedge clk);

        // Compare scores
        for (int n = 0; n < NUM_NEURONS; n++) begin
            logic [ACC_W-1:0] exp_score, act_score;
            exp_score = expected[n*ACC_W +: ACC_W];
            act_score = m_scores[n*ACC_W +: ACC_W];
            check($sformatf("%s_neuron_%0d", test_name, n),
                  act_score === exp_score,
                  $sformatf("exp=%0d got=%0d", exp_score, act_score));
        end

        m_ready <= 1'b0;
        repeat (3) @(posedge clk);

        // Clear ref for next image
        ref_clear();
    endtask

    //
    // Helper: Run one complete image (all passes)
    //
    task automatic run_one_image(
        string test_name,
        real ready_prob
    );
        for (int p = 0; p < PASSES; p++) begin
            logic [P_N*ACC_W-1:0] scores;
            int count;
            logic is_last;

            // Generate random scores
            for (int i = 0; i < P_N; i++)
                scores[i*ACC_W +: ACC_W] = $urandom_range(0, 255);

            is_last = (p == PASSES - 1);
            count = is_last ? LAST_PASS_COUNT : P_N;

            send_pass(scores, count, is_last, p);
        end

        collect_output(test_name, ready_prob);
    endtask

    //
    // Test Scenarios
    //

    //--- Test 1: Single-pass degenerate case (PASSES=1 when P_N>=NUM_NEURONS) -
    // NOTE: With current params PASSES=2, so we test multi-pass instead.
    // This test sends both passes normally.
    task automatic test_basic_multipass();
        $display("[TEST] test_basic_multipass: PASSES=%0d", PASSES);
        run_one_image("basic_multipass", 1.0);
    endtask

    //--- Test 2: All-zero scores -- verify zero handling ----------------------
    task automatic test_all_zero_scores();
        $display("[TEST] test_all_zero_scores");
        for (int p = 0; p < PASSES; p++) begin
            logic [P_N*ACC_W-1:0] scores;
            scores = '0;
            send_pass(scores, (p == PASSES-1) ? LAST_PASS_COUNT : P_N,
                      (p == PASSES-1), p);
        end
        collect_output("all_zero", 1.0);
    endtask

    //--- Test 3: Maximum scores -- all neurons at max popcount ----------------
    task automatic test_max_scores();
        $display("[TEST] test_max_scores: all 0xFF");
        for (int p = 0; p < PASSES; p++) begin
            logic [P_N*ACC_W-1:0] scores;
            for (int i = 0; i < P_N; i++)
                scores[i*ACC_W +: ACC_W] = 8'hFF;
            send_pass(scores, (p == PASSES-1) ? LAST_PASS_COUNT : P_N,
                      (p == PASSES-1), p);
        end
        collect_output("max_scores", 1.0);
    endtask

    //--- Test 4: Output backpressure -- m_ready=0 during OUTPUT state ---------
    task automatic test_output_backpressure();
        $display("[TEST] test_output_backpressure");
        run_one_image("output_bp", 0.3);
    endtask

    //--- Test 5: Multiple images back-to-back ---------------------------------
    task automatic test_multi_image();
        $display("[TEST] test_multi_image: 10 consecutive images");
        for (int img = 0; img < 10; img++) begin
            run_one_image($sformatf("multi_img_%0d", img), 0.8);
        end
    endtask

    //--- Test 6: Known values for score bank verification ---------------------
    task automatic test_known_values();
        logic [P_N*ACC_W-1:0] scores_p0, scores_p1;
        $display("[TEST] test_known_values: verify exact score bank contents");

        // Pass 0: neurons 0-7 get scores 10,20,30,40,50,60,70,80
        for (int i = 0; i < P_N; i++)
            scores_p0[i*ACC_W +: ACC_W] = 8'((i+1) * 10);
        send_pass(scores_p0, P_N, 1'b0, 0);

        // Pass 1: neurons 8-9 get scores 90,100 (count=2)
        for (int i = 0; i < P_N; i++)
            scores_p1[i*ACC_W +: ACC_W] = 8'((i+9) * 10);
        send_pass(scores_p1, LAST_PASS_COUNT, 1'b1, 1);

        collect_output("known_values", 1.0);
    endtask

    //--- Test 7: Random stress with varied backpressure -----------------------
    task automatic test_random_stress();
        $display("[TEST] test_random_stress: 20 images, random bp");
        for (int img = 0; img < 20; img++) begin
            real rp;
            rp = 0.5 + ($urandom_range(0, 50) / 100.0);
            run_one_image($sformatf("stress_%0d", img), rp);
        end
    endtask

    //
    // Main Test Sequence
    //
    initial begin
        $display("============================================================");
        $display("  bnn_score_collector Testbench (CRV+, Gray-Box)");
        $display("  P_N=%0d, NUM_NEURONS=%0d, ACC_W=%0d, PASSES=%0d",
                 P_N, NUM_NEURONS, ACC_W, PASSES);
        $display("============================================================");

        reset_dut();

        test_basic_multipass();
        reset_dut();

        test_all_zero_scores();
        reset_dut();

        test_max_scores();
        reset_dut();

        test_known_values();
        reset_dut();

        test_output_backpressure();
        reset_dut();

        test_multi_image();
        reset_dut();

        test_random_stress();

        repeat (20) @(posedge clk);

        //
        // Scoreboard Summary
        //
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_score_collector");
        $display("============================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failure Details ---");
            foreach (fail_log[i])
                $display("    %s", fail_log[i]);
        end
        $display("  Coverage     : %.1f%%", cg_inst.get_coverage());
        $display("============================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("============================================================");

        $finish;
    end

endmodule
