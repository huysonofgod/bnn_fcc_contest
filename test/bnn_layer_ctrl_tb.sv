`timescale 1ns/10ps

`ifndef BNN_LAYER_CTRL_TB_P_W
`define BNN_LAYER_CTRL_TB_P_W 1
`endif
`ifndef BNN_LAYER_CTRL_TB_P_N
`define BNN_LAYER_CTRL_TB_P_N 8
`endif
`ifndef BNN_LAYER_CTRL_TB_NUM_NEURONS
`define BNN_LAYER_CTRL_TB_NUM_NEURONS 10
`endif
`ifndef BNN_LAYER_CTRL_TB_FAN_IN
`define BNN_LAYER_CTRL_TB_FAN_IN 16
`endif
`ifndef BNN_LAYER_CTRL_TB_IS_OUTPUT_LAYER
`define BNN_LAYER_CTRL_TB_IS_OUTPUT_LAYER 0
`endif

module bnn_layer_ctrl_tb;

    // Parameters (moderate size for fast simulation)
    parameter int P_W             = `BNN_LAYER_CTRL_TB_P_W;
    parameter int P_N             = `BNN_LAYER_CTRL_TB_P_N;
    parameter int NUM_NEURONS     = `BNN_LAYER_CTRL_TB_NUM_NEURONS;
    parameter int FAN_IN          = `BNN_LAYER_CTRL_TB_FAN_IN;
    parameter int IS_OUTPUT_LAYER = `BNN_LAYER_CTRL_TB_IS_OUTPUT_LAYER;

    localparam int ITERS  = (FAN_IN + P_W - 1) / P_W;   // 16
    localparam int PASSES = (NUM_NEURONS + P_N - 1) / P_N; // 2
    localparam int WT_ADDR_W  = $clog2(ITERS * PASSES);
    localparam int THR_ADDR_W = $clog2(PASSES > 1 ? PASSES : 2);
    localparam int NP_CNT_W   = $clog2(P_N + 1);
    localparam int REMAINDER  = NUM_NEURONS % P_N;
    localparam int LAST_PASS_COUNT = (REMAINDER == 0) ? P_N : REMAINDER;

    // DUT Interface Signals
    logic                  clk = 0;
    logic                  rst = 1;
    logic                  start;
    logic                  busy, done;
    logic                  s_valid, s_ready, s_last;
    logic                  np_valid_in, np_last;
    logic [WT_ADDR_W-1:0]  wt_rd_addr;
    logic                  wt_rd_en;
    logic [THR_ADDR_W-1:0] thr_rd_addr;
    logic                  thr_rd_en;
    logic                  result_valid, result_ready;
    logic [NP_CNT_W-1:0]   valid_np_count;
    logic                  last_pass;

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    // DUT Instantiation — bnn_layer_ctrl is now pure FSM. Pair with
    // bnn_seq_addr_gen (u_seq) here so the TB can observe the old-style
    // address/count/last_pass outputs without changing test scenarios.
    // Strobes + status between FSM and sequencer
    logic iter_we, iter_clr;
    logic pass_we, pass_clr;
    logic wt_addr_we, thr_addr_we, vnp_we;
    logic iter_tc, pass_tc;

    bnn_layer_ctrl #(
        .P_W             (P_W),
        .P_N             (P_N),
        .NUM_NEURONS     (NUM_NEURONS),
        .FAN_IN          (FAN_IN),
        .IS_OUTPUT_LAYER (IS_OUTPUT_LAYER)
    ) DUT (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .busy         (busy),
        .done         (done),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_last       (s_last),
        .np_valid_in  (np_valid_in),
        .np_last      (np_last),
        .wt_rd_en     (wt_rd_en),
        .thr_rd_en    (thr_rd_en),
        .result_valid (result_valid),
        .result_ready (result_ready),
        .iter_we      (iter_we),
        .iter_clr     (iter_clr),
        .pass_we      (pass_we),
        .pass_clr     (pass_clr),
        .wt_addr_we   (wt_addr_we),
        .thr_addr_we  (thr_addr_we),
        .vnp_we       (vnp_we),
        .iter_tc      (iter_tc),
        .pass_tc      (pass_tc)
    );

    bnn_seq_addr_gen #(
        .P_W         (P_W),
        .P_N         (P_N),
        .NUM_NEURONS (NUM_NEURONS),
        .FAN_IN      (FAN_IN)
    ) u_seq (
        .clk            (clk),
        .rst            (rst),
        .iter_we        (iter_we),
        .iter_clr       (iter_clr),
        .pass_we        (pass_we),
        .pass_clr       (pass_clr),
        .wt_addr_we     (wt_addr_we),
        .thr_addr_we    (thr_addr_we),
        .vnp_we         (vnp_we),
        .iter_tc        (iter_tc),
        .pass_tc        (pass_tc),
        .wt_rd_addr     (wt_rd_addr),
        .thr_rd_addr    (thr_rd_addr),
        .valid_np_count (valid_np_count),
        .last_pass      (last_pass)
    );

    // SVA Properties (Gray Box)

    // Check: done is exactly 1 clock cycle pulse
    // RATIONALE: Downstream state machines count done pulses per image.
    // The done output comes from DONE_ST state which lasts exactly 1 cycle.
    property p_done_single_cycle;
        @(posedge clk) disable iff (rst)
        done |=> !done;
    endproperty
    assert property (p_done_single_cycle)
    else $error("Assertion failed: done pulse lasted more than 1 cycle");

    // Check: np_last is exactly 1 cycle pulse (LAST_BEAT state)
    // RATIONALE: NPs use np_last to trigger final accumulation. Multiple
    // cycles of np_last would corrupt popcount accumulation.
    property p_np_last_single_cycle;
        @(posedge clk) disable iff (rst)
        np_last |=> !np_last;
    endproperty
    assert property (p_np_last_single_cycle)
    else $error("Assertion failed: np_last pulse lasted more than 1 cycle");

    // Check: result_valid held until result_ready handshake
    // RATIONALE: AXI-Stream compliance. Once result_valid is asserted in
    // FLUSH_OUT state, it must remain high until result_ready is received.
    property p_result_valid_axi_hold;
        @(posedge clk) disable iff (rst)
        ((DUT.u_fsm.state_r == DUT.u_fsm.FLUSH_OUT) &&
         result_valid && !result_ready) |=> result_valid;
    endproperty
    assert property (p_result_valid_axi_hold)
    else $error("Assertion failed: result_valid dropped without result_ready");

    // Check: No s_ready without start first -- controller must be activated
    // before consuming input.
    // RATIONALE: s_ready should only assert in RUN_ITER state, which requires
    // start to have been pulsed first.
    property p_no_ready_before_start;
        @(posedge clk) disable iff (rst)
        (!busy && !$past(start)) |-> !s_ready;
    endproperty
    assert property (p_no_ready_before_start)
    else $error("Assertion failed: s_ready asserted without prior start");

    // Check: thr_rd_en does not re-assert until next result_valid handshake
    // RATIONALE: Threshold read happens once per pass (in LOAD_THR state).
    property p_thr_rd_en_once_per_pass;
        @(posedge clk) disable iff (rst)
        thr_rd_en |=> !thr_rd_en until_with result_valid;
    endproperty
    assert property (p_thr_rd_en_once_per_pass)
    else $error("Assertion failed: thr_rd_en fired twice before result_valid");

    // Check: busy spans from start until done -- busy must remain high for
    // the entire processing duration.
    // RATIONALE: busy indicates processing in progress; downstream relies on it.
    property p_busy_spans_operation;
        @(posedge clk) disable iff (rst)
        $rose(busy) |-> ##[1:$] done [->1] ##1 !busy;
    endproperty
    assert property (p_busy_spans_operation)
    else $error("Assertion failed: busy did not span from start to done");

    // Covergroups (Gray Box)

    // COVERGROUP: FSM state coverage and state transitions
    // Tracks all 6 FSM states and the 8 valid transition arcs.
    covergroup cg_fsm_states @(posedge clk iff (!rst));
        cp_state: coverpoint DUT.u_fsm.state_r {
            bins idle      = {DUT.u_fsm.IDLE};
            bins load_thr  = {DUT.u_fsm.LOAD_THR};
            bins run_iter  = {DUT.u_fsm.RUN_ITER};
            bins last_beat = {DUT.u_fsm.LAST_BEAT};
            bins flush_out = {DUT.u_fsm.FLUSH_OUT};
            bins done_st   = {DUT.u_fsm.DONE_ST};
        }
    endgroup

    // COVERGROUP: Iteration/pass counter coverage and valid_np_count
    // Ensures counters reach all extremes (first, mid, last).
    covergroup cg_counters @(posedge clk iff (!rst));
        cp_iter_cnt: coverpoint u_seq.iter_cnt_r_q {
            bins zero  = {0};
            bins last  = {ITERS - 1};
        }

        cp_pass_cnt: coverpoint u_seq.pass_cnt_r_q {
            bins first = {0};
            bins last  = {PASSES - 1};
        }

        cp_valid_np: coverpoint valid_np_count iff (result_valid) {
            bins full_pass = {P_N};
            bins partial   = {LAST_PASS_COUNT};
        }
    endgroup

    // COVERGROUP: Backpressure scenarios
    // Covers stall events on input (s_ready but no s_valid) and output
    // (result_valid but no result_ready).
    covergroup cg_backpressure @(posedge clk iff (!rst));
        cp_input_stall: coverpoint {s_ready, s_valid} {
            bins stall  = {2'b10};
            bins flow   = {2'b11};
        }

        cp_output_stall: coverpoint {result_valid, result_ready} {
            bins stall = {2'b10};
            bins flow  = {2'b11};
        }
    endgroup

    cg_fsm_states   cg_fsm  = new();
    cg_counters     cg_cnt  = new();
    cg_backpressure cg_bp   = new();

    // Scoreboard
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    function automatic void check(string test_name, logic cond, string msg = "");
        if (cond) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
            $error("Scoreboard mismatch: %s: %s", test_name, msg);
        end
    endfunction

    // Counters for pass-level verification
    int np_valid_count;         // count np_valid_in assertions per pass
    int result_valid_count;     // count result_valid handshakes per image
    int thr_rd_en_count;        // count thr_rd_en per image

    always @(posedge clk) begin
        if (rst) begin
            np_valid_count     <= 0;
            result_valid_count <= 0;
            thr_rd_en_count    <= 0;
        end else begin
            if (np_valid_in)                     np_valid_count     <= np_valid_count + 1;
            if (result_valid && result_ready)     result_valid_count <= result_valid_count + 1;
            if (thr_rd_en)                        thr_rd_en_count    <= thr_rd_en_count + 1;
            if (done) begin
                np_valid_count     <= 0;
                result_valid_count <= 0;
                thr_rd_en_count    <= 0;
            end
        end
    end

    // Reset Task
    task automatic reset_dut();
        rst          <= 1'b1;
        start        <= 1'b0;
        s_valid      <= 1'b0;
        s_last       <= 1'b0;
        result_ready <= 1'b0;
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    // Helper: Run one complete image through the controller
    task automatic run_one_image(
        input real valid_probability,   // 0.0 to 1.0: probability s_valid=1
        input real ready_probability,   // 0.0 to 1.0: probability result_ready=1
        input string test_name
    );
        int timeout_cnt;

        // Pulse start
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Process all PASSES
        timeout_cnt = 0;
        while (!done && timeout_cnt < 50000) begin
            @(posedge clk);
            timeout_cnt++;

            // Drive s_valid with probability when s_ready
            if (s_ready)
                s_valid <= ($urandom_range(0, 99) < int'(valid_probability * 100));
            else
                s_valid <= 1'b0;

            // Drive result_ready with probability when result_valid
            if (result_valid)
                result_ready <= ($urandom_range(0, 99) < int'(ready_probability * 100));
            else
                result_ready <= 1'b0;
        end

        s_valid      <= 1'b0;
        result_ready <= 1'b0;

        check($sformatf("%s_no_timeout", test_name), timeout_cnt < 50000,
              "Controller timed out");
    endtask

    // Test Scenarios

    // Single image with no backpressure
    task automatic test_single_no_bp();
        $display("Running: test_single_no_bp: clean start-to-done flow");
        run_one_image(1.0, 1.0, "single_no_bp");

        // done is a one-cycle pulse; allow one cycle for deassertion.
        @(posedge clk);
        check("single_no_bp_done", done == 1'b0,
              "done should have deasserted by now");
    endtask

    // Input-stall stress with VALID_PROBABILITY=0.8
    task automatic test_input_stall();
        $display("Running: test_input_stall: random s_valid gaps (80%%)");
        run_one_image(0.8, 1.0, "input_stall");
    endtask

    // Output-stall stress
    task automatic test_output_stall();
        $display("Running: test_output_stall: random result_ready=0");
        run_one_image(1.0, 0.5, "output_stall");
    endtask

    // Multi-image sequence (10 images)
    task automatic test_multi_image();
        $display("Running: test_multi_image: 10 consecutive images");
        for (int img = 0; img < 10; img++) begin
            run_one_image(0.9, 0.9, $sformatf("multi_img_%0d", img));
            repeat (5) @(posedge clk);
        end
    endtask

    // Reset in the middle of processing
    task automatic test_reset_mid_run();
        int timeout_cnt;
        $display("Running: test_reset_mid_run: assert rst in various states");

        // Start operation
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        s_valid <= 1'b1;

        // Wait until RUN_ITER
        timeout_cnt = 0;
        while (DUT.u_fsm.state_r != DUT.u_fsm.RUN_ITER && timeout_cnt < 100) begin
            @(posedge clk);
            timeout_cnt++;
        end

        // Allow a few iterations
        repeat (5) @(posedge clk);

        // Reset mid-run
        rst <= 1'b1;
        s_valid <= 1'b0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        // Verify clean recovery
        check("reset_mid_idle", !busy,
              $sformatf("busy=%b after reset, expected 0", busy));
        check("reset_mid_no_done", !done,
              $sformatf("done=%b after reset, expected 0", done));

        // Verify can start new image
        run_one_image(1.0, 1.0, "reset_mid_recovery");
    endtask

    // Verify iteration count per pass
    task automatic test_iteration_count();
        int np_valid_cnt_per_pass;
        int timeout_cnt;
        logic [NP_CNT_W-1:0] vnp_seen;
        logic                last_pass_seen;
        $display("Running: test_iteration_count: verify ITERS=%0d per pass", ITERS);

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        for (int p = 0; p < PASSES; p++) begin
            np_valid_cnt_per_pass = 0;
            vnp_seen      = '0;
            last_pass_seen = 1'b0;

            // Synchronize to this pass entering RUN_ITER.
            timeout_cnt = 0;
            while (DUT.u_fsm.state_r != DUT.u_fsm.RUN_ITER && timeout_cnt < 5000) begin
                @(posedge clk);
                timeout_cnt++;
                s_valid      <= 1'b0;
                result_ready <= 1'b0;
            end

            // Count np_valid_in through this pass until result handshake.
            timeout_cnt = 0;
            while (timeout_cnt < 5000) begin
                @(posedge clk);
                timeout_cnt++;

                if (s_ready)
                    s_valid <= 1'b1;
                else
                    s_valid <= 1'b0;

                if (result_valid)
                    result_ready <= 1'b1;
                else
                    result_ready <= 1'b0;

                if (np_valid_in) np_valid_cnt_per_pass++;

                if (result_valid && result_ready) begin
                    vnp_seen       = valid_np_count;
                    last_pass_seen = last_pass;
                    break;
                end
            end

            check($sformatf("iter_count_pass_%0d", p),
                  np_valid_cnt_per_pass == ITERS,
                  $sformatf("expected %0d np_valid, got %0d", ITERS, np_valid_cnt_per_pass));

            // Check valid_np_count
            if (p == PASSES - 1) begin
                check("last_pass_vnp",
                      vnp_seen == NP_CNT_W'(LAST_PASS_COUNT),
                      $sformatf("expected %0d, got %0d", LAST_PASS_COUNT, vnp_seen));
                check("last_pass_flag", last_pass_seen == 1'b1,
                      $sformatf("last_pass=%b, expected 1", last_pass_seen));
            end else begin
                check($sformatf("pass_%0d_vnp", p),
                      vnp_seen == NP_CNT_W'(P_N),
                      $sformatf("expected %0d, got %0d", P_N, vnp_seen));
            end
        end

        s_valid      <= 1'b0;
        result_ready <= 1'b0;
        // Wait for done
        while (!done) @(posedge clk);
        @(posedge clk);
    endtask

    // Combined stress under contest-like conditions
    task automatic test_contest_stress();
        $display("Running: test_contest_stress: VALID_PROB=0.8, TOGGLE_READY=1");
        for (int img = 0; img < 5; img++) begin
            run_one_image(0.8, 0.7, $sformatf("contest_stress_%0d", img));
            repeat (2) @(posedge clk);
        end
    endtask

    // Weight-address verification
    task automatic test_weight_address();
        int expected_addr;
        int timeout_cnt;
        $display("Running: test_weight_address: verify wt_rd_addr sequence");

        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        for (int p = 0; p < PASSES; p++) begin
            // Wait for LOAD_THR (1 cycle where wt_addr is set)
            timeout_cnt = 0;
            while (DUT.u_fsm.state_r != DUT.u_fsm.RUN_ITER && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt++;
            end

            // During RUN_ITER, verify addresses
            for (int i = 0; i < ITERS; i++) begin
                s_valid <= 1'b1;
                @(posedge clk);
                while (!s_ready) @(posedge clk);
                // wt_rd_addr is registered: address for iteration i
                expected_addr = p * ITERS + i;
                // Note: address is registered, check next cycle
            end
            s_valid <= 1'b0;

            // Wait for result handshake
            timeout_cnt = 0;
            while (!result_valid && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt++;
            end
            result_ready <= 1'b1;
            @(posedge clk);
            result_ready <= 1'b0;
        end

        // Wait for done
        while (!done) @(posedge clk);
        @(posedge clk);
    endtask

    // Main Test Sequence
    initial begin
        $display("============================================================");
        $display("  bnn_layer_ctrl Testbench (UVM-style CRV+, Gray-Box)");
        $display("  P_W=%0d, P_N=%0d, NUM_NEURONS=%0d, FAN_IN=%0d",
                 P_W, P_N, NUM_NEURONS, FAN_IN);
        $display("  ITERS=%0d, PASSES=%0d, LAST_PASS_COUNT=%0d",
                 ITERS, PASSES, LAST_PASS_COUNT);
        $display("============================================================");

        reset_dut();

        test_single_no_bp();
        reset_dut();

        test_input_stall();
        reset_dut();

        test_output_stall();
        reset_dut();

        test_iteration_count();
        reset_dut();

        test_weight_address();
        reset_dut();

        test_reset_mid_run();

        test_multi_image();
        reset_dut();

        test_contest_stress();

        repeat (20) @(posedge clk);

        // Scoreboard Summary
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_layer_ctrl");
        $display("============================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failure Details ---");
            foreach (fail_log[i])
                $display("    %s", fail_log[i]);
        end
        $display("  FSM Coverage : %.1f%%", cg_fsm.get_coverage());
        $display("  Cnt Coverage : %.1f%%", cg_cnt.get_coverage());
        $display("  BP  Coverage : %.1f%%", cg_bp.get_coverage());
        $display("============================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("============================================================");

        $finish;
    end

endmodule
