`timescale 1ns/10ps

`ifndef ARGMAX_TB_NUM_CLASSES
`define ARGMAX_TB_NUM_CLASSES 10
`endif
`ifndef ARGMAX_TB_ACC_W
`define ARGMAX_TB_ACC_W 10
`endif
`ifndef ARGMAX_TB_RANDOM_BEATS
`define ARGMAX_TB_RANDOM_BEATS 10000
`endif

module tb_bnn_argmax;

    //
    // Parameters
    //
    parameter int NUM_CLASSES = `ARGMAX_TB_NUM_CLASSES;
    parameter int ACC_W       = `ARGMAX_TB_ACC_W;

    localparam int IDX_W  = $clog2(NUM_CLASSES > 1 ? NUM_CLASSES : 2);
    localparam int STAGES = $clog2(NUM_CLASSES > 1 ? NUM_CLASSES : 2);
    // Total pipeline depth: 1 (input reg) + STAGES (reduction) + 1 (output reg)
    localparam int PIPE_DEPTH = STAGES + 2;

    //
    // DUT interface signals
    //
    logic                          clk = 1'b0;
    logic                          rst = 1'b1;

    logic                          s_valid = 1'b0;
    logic                          s_ready;
    logic [NUM_CLASSES*ACC_W-1:0]  s_scores = '0;
    logic                          s_last   = 1'b0;

    logic                          m_valid;
    logic                          m_ready = 1'b0;
    logic [IDX_W-1:0]              m_idx;
    logic                          m_last;

    //Clock generation — 100 MHz
    always #5 clk = ~clk;

    //DUT instantiation
    bnn_argmax #(
        .NUM_CLASSES (NUM_CLASSES),
        .ACC_W       (ACC_W)
    ) DUT (
        .clk      (clk),
        .rst      (rst),
        .s_valid  (s_valid),
        .s_ready  (s_ready),
        .s_scores (s_scores),
        .s_last   (s_last),
        .m_valid  (m_valid),
        .m_ready  (m_ready),
        .m_idx    (m_idx),
        .m_last   (m_last)
    );

    //Reference model — golden argmax with first-wins tie-break
    //Given a score vector, computes the expected winning index.
    //Tie-break: lowest index wins (first-wins, identical to DUT).
    function automatic logic [IDX_W-1:0] ref_argmax(
        input logic [NUM_CLASSES*ACC_W-1:0] scores
    );
        logic [ACC_W-1:0]  best_sc;
        logic [IDX_W-1:0]  best_idx;
        best_sc  = scores[ACC_W-1:0];   // start with index 0
        best_idx = '0;
        for (int k = 1; k < NUM_CLASSES; k++) begin
            logic [ACC_W-1:0] sc = scores[k*ACC_W +: ACC_W];
            //Strict >: only updates if STRICTLY greater — keeps lower index on tie.
            if (sc > best_sc) begin
                best_sc  = sc;
                best_idx = IDX_W'(k);
            end
        end
        return best_idx;
    endfunction

    function automatic logic [NUM_CLASSES*ACC_W-1:0] rand_scores();
        logic [NUM_CLASSES*ACC_W-1:0] tmp;
        for (int k = 0; k < NUM_CLASSES; k++)
            tmp[k*ACC_W +: ACC_W] = ACC_W'($urandom());
        return tmp;
    endfunction

    //Scoreboard mailboxes and counters
    //The driver pushes expected (idx, last) pairs into exp_mb as it presents
    //each input beat.  The monitor pops from exp_mb when m_valid&&m_ready and
    //compares.  This gives beat-accurate out-of-order-safe checking under
    //arbitrary backpressure.
    typedef struct {
        logic [IDX_W-1:0] idx;
        logic             last;
        logic [NUM_CLASSES*ACC_W-1:0] scores;  // kept for error messages
    } expected_t;

    expected_t exp_q[$];  // expected output queue (ordered)

    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    //Tie-count tracker — updated by driver for cg_tie coverage
    int tie_count_last = 0;

    function automatic void check(string name, logic cond, string msg = "");
        if (cond) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", name, msg));
            $error("[SB] %s: %s", name, msg);
        end
    endfunction

    //Monitor process — captures DUT output on m_valid && m_ready
    always @(posedge clk) begin
        if (!rst && m_valid && m_ready) begin
            if (exp_q.size() == 0) begin
                $error("[MON] Unexpected output: m_idx=%0d m_last=%0b (queue empty)",
                       m_idx, m_last);
                fail_count++;
            end else begin
                expected_t e;
                e = exp_q.pop_front();
                check($sformatf("argmax_idx_beat%0d", pass_count + fail_count),
                      m_idx == e.idx,
                      $sformatf("DUT idx=%0d expected=%0d", m_idx, e.idx));
                check($sformatf("argmax_last_beat%0d", pass_count + fail_count),
                      m_last == e.last,
                      $sformatf("DUT last=%0b expected=%0b", m_last, e.last));
            end
        end
    end

    //
    // Tie-count covergroup helper (updated by driver before push)
    //
    localparam int TIE_MANY_HI = (NUM_CLASSES >= 3) ? NUM_CLASSES : 3;

    covergroup cg_tie @(posedge clk iff (s_valid && s_ready));
        cp_tie : coverpoint tie_count_last {
            bins no_tie   = {1};
            bins tie2     = {2};
            bins tie_many = {[3:TIE_MANY_HI]};
        }
    endgroup

    //Covergroups

    //cg_argmax_out: Every output index class must be observed at least once.
    //The s_last passthrough is also verified here.
    covergroup cg_argmax_out @(posedge clk iff (m_valid && m_ready));
        cp_idx  : coverpoint m_idx {
            bins per_class[NUM_CLASSES] = {[0:NUM_CLASSES-1]};
        }
        cp_last : coverpoint m_last;
        x_idx_last : cross cp_idx, cp_last;
    endgroup

    //cg_pipe: Pipeline enable / output-valid cross.
    //(out_valid=1, m_ready=0) is the stall state.
    //(out_valid=1, m_ready=1) is the drain state.
    covergroup cg_pipe @(posedge clk);
        cp_pipe_en   : coverpoint DUT.pipe_en;
        cp_out_valid : coverpoint DUT.out_valid_r_q;
        cp_m_ready   : coverpoint m_ready;
        x_stall      : cross cp_out_valid, cp_m_ready;
    endgroup

    //cg_bp: All four corners of both handshake interfaces.
    covergroup cg_bp @(posedge clk);
        cp_sv : coverpoint s_valid;
        cp_sr : coverpoint s_ready;
        cp_mv : coverpoint m_valid;
        cp_mr : coverpoint m_ready;
        x_in  : cross cp_sv, cp_sr;
        x_out : cross cp_mv, cp_mr;
    endgroup

    cg_tie        cg_t  = new();
    cg_argmax_out cg_ao = new();
    cg_pipe       cg_pp = new();
    cg_bp         cg_b  = new();

    //SVAs

    //When output is valid and downstream is stalling, ALL output
    //signals must remain stable until m_ready is asserted.
    //This is the AXI-Stream stall contract.
    property p_pipe_stall_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> ($stable(m_idx) && $stable(m_last) && m_valid);
    endproperty
    assert property (p_pipe_stall_stable)
    else $error("[SVA] FAIL a_pipe_stall_stable: output changed while stalled");

    //
    // SVA-2: s_ready must equal pipe_en at all times (DUT architecture property).
    // pipe_en = ~out_valid_r_q | m_ready.
    //
    property p_s_ready_eq_pipe_en;
        @(posedge clk) disable iff (rst)
        s_ready == DUT.pipe_en;
    endproperty
    assert property (p_s_ready_eq_pipe_en)
    else $error("[SVA] FAIL: s_ready=%0b != pipe_en=%0b", s_ready, DUT.pipe_en);

    //
    // SVA-3: No X on output signals when m_valid is asserted.
    //
    property p_no_x_when_valid;
        @(posedge clk) disable iff (rst)
        m_valid |-> !$isunknown({m_idx, m_last});
    endproperty
    assert property (p_no_x_when_valid)
    else $error("[SVA] FAIL: X on output when m_valid=1");

    //Reset task
    task automatic reset_dut(int cycles = 10);
        rst     <= 1'b1;
        s_valid <= 1'b0;
        s_last  <= 1'b0;
        s_scores<= '0;
        m_ready <= 1'b0;
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //Driver: send one score vector, return when handshake completes
    //Pushes expected result into exp_q only after the input handshake occurs.
    //Under output backpressure, older results can still drain while a new
    //input is waiting for s_ready, so pre-queuing would misalign the monitor.
    task automatic send_beat(
        input logic [NUM_CLASSES*ACC_W-1:0] scores,
        input logic                          last
    );
        expected_t e;
        int        tie_cnt;
        logic [ACC_W-1:0] max_sc;

        // Compute reference index and tie count for scoreboard / coverage
        e.idx    = ref_argmax(scores);
        e.last   = last;
        e.scores = scores;

        // Count ties at max score
        max_sc  = scores[e.idx * ACC_W +: ACC_W];
        tie_cnt = 0;
        for (int k = 0; k < NUM_CLASSES; k++) begin
            if (scores[k*ACC_W +: ACC_W] == max_sc)
                tie_cnt++;
        end
        tie_count_last = tie_cnt;

        // Present to DUT and wait for handshake
        @(posedge clk);
        s_valid  <= 1'b1;
        s_scores <= scores;
        s_last   <= last;

        // Hold until an actual handshake cycle occurs.
        do @(posedge clk); while (!s_ready);

        exp_q.push_back(e);
        s_valid  <= 1'b0;
        s_last   <= 1'b0;
        s_scores <= '0;
    endtask

    //Drain: wait for all queued expected results to be consumed by monitor
    task automatic drain_all(int timeout_cyc = 5000);
        int t = 0;
        m_ready <= 1'b1;
        while (exp_q.size() > 0 && t < timeout_cyc) begin
            @(posedge clk);
            t++;
        end
        m_ready <= 1'b0;
        check("drain_complete", exp_q.size() == 0,
              $sformatf("exp_q still has %0d entries after timeout", exp_q.size()));
        repeat (PIPE_DEPTH + 2) @(posedge clk);
    endtask

    //Helper: build a score vector with all entries equal to v
    function automatic logic [NUM_CLASSES*ACC_W-1:0] all_equal(int v);
        logic [NUM_CLASSES*ACC_W-1:0] s;
        for (int k = 0; k < NUM_CLASSES; k++)
            s[k*ACC_W +: ACC_W] = ACC_W'(v);
        return s;
    endfunction

    //Helper: ascending scores [0, 1, 2, ..., NUM_CLASSES-1]
    function automatic logic [NUM_CLASSES*ACC_W-1:0] ascending();
        logic [NUM_CLASSES*ACC_W-1:0] s;
        for (int k = 0; k < NUM_CLASSES; k++)
            s[k*ACC_W +: ACC_W] = ACC_W'(k);
        return s;
    endfunction

    //Helper: descending scores [NUM_CLASSES-1, ..., 1, 0]
    function automatic logic [NUM_CLASSES*ACC_W-1:0] descending();
        logic [NUM_CLASSES*ACC_W-1:0] s;
        for (int k = 0; k < NUM_CLASSES; k++)
            s[k*ACC_W +: ACC_W] = ACC_W'(NUM_CLASSES - 1 - k);
        return s;
    endfunction

    //
    // T01 — All-zero scores: tie at 0 → first-wins → idx 0
    //
    task automatic test_t01_all_zero();
        $display("[TEST] T01: all-zero → expect idx 0");
        reset_dut();
        m_ready <= 1'b1;
        send_beat(all_equal(0), 1'b1);
        drain_all();
    endtask

    //
    // T02 — Ascending scores: max at last class
    //
    task automatic test_t02_ascending();
        $display("[TEST] T02: ascending → expect idx %0d", NUM_CLASSES-1);
        reset_dut();
        m_ready <= 1'b1;
        send_beat(ascending(), 1'b1);
        drain_all();
    endtask

    //
    // T03 — Descending scores: max at class 0
    //
    task automatic test_t03_descending();
        $display("[TEST] T03: descending → expect idx 0");
        reset_dut();
        m_ready <= 1'b1;
        send_beat(descending(), 1'b1);
        drain_all();
    endtask

    //
    // T04 — Tie at two indices: first-wins gives lower index
    // (skipped if NUM_CLASSES < 8)
    //
    task automatic test_t04_tie_lower_wins();
        logic [NUM_CLASSES*ACC_W-1:0] s;
        int tie_lo, tie_hi;
        $display("[TEST] T04: tie at idx 3 and 7 → expect idx 3");
        if (NUM_CLASSES < 8) begin
            $display("[T04] SKIPPED — NUM_CLASSES=%0d < 8", NUM_CLASSES);
            pass_count++;
            return;
        end
        reset_dut();
        m_ready <= 1'b1;
        // Build: all zeros except index 3 and 7 share the maximum score
        s = '0;
        tie_lo = 3; tie_hi = 7;
        for (int k = 0; k < NUM_CLASSES; k++)
            s[k*ACC_W +: ACC_W] = (k == tie_lo || k == tie_hi) ? ACC_W'((1 << ACC_W) - 1) : '0;
        send_beat(s, 1'b1);
        drain_all();
    endtask

    //
    // T05 — All-equal at maximum value: first-wins → idx 0
    //
    task automatic test_t05_all_equal_max();
        $display("[TEST] T05: all-equal at max → expect idx 0");
        reset_dut();
        m_ready <= 1'b1;
        send_beat(all_equal((1 << ACC_W) - 1), 1'b1);
        drain_all();
    endtask

    //
    // T06 — Back-to-back valid beats with m_ready=1: pipeline saturates
    //
    task automatic test_t06_back_to_back();
        int n = PIPE_DEPTH * 3;
        $display("[TEST] T06: %0d back-to-back beats, m_ready=1", n);
        reset_dut();
        m_ready <= 1'b1;
        for (int i = 0; i < n; i++) begin
            logic [NUM_CLASSES*ACC_W-1:0] s;
            // Vary the winning index to exercise all classes
            s = '0;
            s[((i % NUM_CLASSES) * ACC_W) +: ACC_W] = ACC_W'((1 << ACC_W) - 1);
            send_beat(s, (i == n-1));
        end
        drain_all();
    endtask

    //
    // T07 — Random m_ready toggling (50% probability): stall propagation
    //
    task automatic test_t07_random_ready();
        int n = 256;
        $display("[TEST] T07: %0d beats with random m_ready (50%%)", n);
        reset_dut();

        fork
            // Input driver
            begin
                for (int i = 0; i < n; i++) begin
                    logic [NUM_CLASSES*ACC_W-1:0] s;
                    s = rand_scores();
                    send_beat(s, (i == n-1));
                end
            end
            // Async ready toggler
            begin : ready_toggler
                for (int cyc = 0; cyc < n * (PIPE_DEPTH + 5); cyc++) begin
                    @(posedge clk);
                    m_ready <= ($urandom_range(0,1));
                end
                m_ready <= 1'b1;
            end
        join_any
        disable ready_toggler;
        drain_all();
    endtask

    //
    // T08 — m_ready held low then released: bubbles drain in order
    //
    task automatic test_t08_held_low_then_release();
        int hold_cyc = PIPE_DEPTH * 2;
        $display("[TEST] T08: m_ready held low %0d cycles then released", hold_cyc);
        reset_dut();
        m_ready <= 1'b0;

        // Send a few beats while ready is low
        fork
            begin
                for (int i = 0; i < 3; i++) begin
                    logic [NUM_CLASSES*ACC_W-1:0] s = rand_scores();
                    send_beat(s, (i == 2));
                end
            end
            begin : hold_low
                // Let them accumulate in the pipeline
                repeat (hold_cyc) @(posedge clk);
                m_ready <= 1'b1;
            end
        join_any
        disable hold_low;
        drain_all(2000);
    endtask

    //
    // T09 — s_last tracking through pipeline
    //
    task automatic test_t09_last_tracking();
        $display("[TEST] T09: s_last passthrough");
        reset_dut();
        m_ready <= 1'b1;

        // Alternate last=0 and last=1 beats
        for (int i = 0; i < 6; i++) begin
            logic [NUM_CLASSES*ACC_W-1:0] s = rand_scores();
            send_beat(s, (i % 2 == 1));
        end
        drain_all();
    endtask

    //
    // T10 — Reset mid-pipeline: next beat clean after reset
    //
    task automatic test_t10_reset_mid_pipe();
        $display("[TEST] T10: Reset mid-pipeline");
        reset_dut();
        m_ready <= 1'b1;

        // Send a beat, then reset before it drains
        @(posedge clk);
        s_valid  <= 1'b1;
        s_scores <= ascending();
        s_last   <= 1'b1;
        @(posedge clk);
        s_valid  <= 1'b0;

        // Partial pipeline fill — then reset
        repeat (STAGES / 2 + 1) @(posedge clk);
        exp_q.delete();   // discard old expectations (reset invalidates them)
        reset_dut();

        // Verify no stale output appears after reset
        repeat (PIPE_DEPTH + 5) @(posedge clk);
        check("T10_no_stale_valid", m_valid == 1'b0,
              $sformatf("m_valid=%0b expected 0 after reset", m_valid));

        // Send a fresh beat and verify it works correctly
        send_beat(descending(), 1'b1);
        drain_all();
    endtask

    //
    // T12 — Random scoreboard run: 10000 beats, mixed backpressure
    //
    // Generator creates fully-random score vectors. The reference model
    // computes expected idx. The scoreboard verifies every output beat.
    //
    task automatic test_t12_random_stress();
        int n = `ARGMAX_TB_RANDOM_BEATS;
        $display("[TEST] T12: Random scoreboard run %0d beats", n);
        reset_dut();

        fork
            // Input driver with random valid gaps
            begin
                for (int i = 0; i < n; i++) begin
                    // Occasionally add idle cycles between beats
                    if ($urandom_range(0, 3) == 0) begin
                        @(posedge clk); s_valid <= 1'b0;
                    end
                    send_beat(rand_scores(), (i == n-1));
                end
            end
            // Random m_ready
            begin : ready_rand
                forever begin
                    @(posedge clk);
                    m_ready <= ($urandom_range(0,1));
                end
            end
        join_any
        disable ready_rand;
        drain_all(n * (PIPE_DEPTH + 2) + 1000);
    endtask

    //
    // Main test sequence
    //
    initial begin
        $display("=====================================================");
        $display(" tb_bnn_argmax — Level-1 CRV-lite");
        $display(" NUM_CLASSES=%0d ACC_W=%0d IDX_W=%0d STAGES=%0d",
                 NUM_CLASSES, ACC_W, IDX_W, STAGES);
        $display(" PIPE_DEPTH=%0d", PIPE_DEPTH);
        $display("=====================================================");

        test_t01_all_zero();
        test_t02_ascending();
        test_t03_descending();
        test_t04_tie_lower_wins();
        test_t05_all_equal_max();
        test_t06_back_to_back();
        test_t07_random_ready();
        test_t08_held_low_then_release();
        test_t09_last_tracking();
        test_t10_reset_mid_pipe();
        test_t12_random_stress();

        repeat (20) @(posedge clk);

        $display("");
        $display("=====================================================");
        $display(" SCOREBOARD SUMMARY — tb_bnn_argmax");
        $display("=====================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failures ---");
            foreach (fail_log[i]) $display("    %s", fail_log[i]);
        end
        $display("  Tie CG       : %.1f%%", cg_t.get_coverage());
        $display("  Output CG    : %.1f%%", cg_ao.get_coverage());
        $display("  Pipe CG      : %.1f%%", cg_pp.get_coverage());
        $display("  BP CG        : %.1f%%", cg_b.get_coverage());
        $display("=====================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("=====================================================");

        $finish;
    end

endmodule
