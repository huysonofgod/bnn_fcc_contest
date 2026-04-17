`timescale 1ns/100ps

module bnn_fanout_buf_tb;

    //
    // Parameters
    //
    parameter int WIDTH = 8;

    //
    // DUT Interface Signals — PIPE_STAGES=0
    //
    logic             clk = 0;
    logic             rst = 1;
    logic [WIDTH-1:0] d0;
    logic [WIDTH-1:0] q0;

    //
    // DUT Interface Signals — PIPE_STAGES=1
    //
    logic [WIDTH-1:0] d1;
    logic [WIDTH-1:0] q1;

    //
    // DUT Interface Signals — PIPE_STAGES=2
    //
    logic [WIDTH-1:0] d2;
    logic [WIDTH-1:0] q2;

    //
    // Clock Generation (100 MHz)
    //
    always #5 clk = ~clk;

    //
    // DUT Instantiation — PIPE_STAGES=0 (passthrough)
    //
    bnn_fanout_buf #(
        .WIDTH       (WIDTH),
        .PIPE_STAGES (0)
    ) DUT0 (
        .clk (clk),
        .rst (rst),
        .d   (d0),
        .q   (q0)
    );

    //
    // DUT Instantiation — PIPE_STAGES=1 (1-cycle registered)
    //
    bnn_fanout_buf #(
        .WIDTH       (WIDTH),
        .PIPE_STAGES (1)
    ) DUT1 (
        .clk (clk),
        .rst (rst),
        .d   (d1),
        .q   (q1)
    );

    //
    // DUT Instantiation — PIPE_STAGES=2 (2-cycle pipeline)
    //
    bnn_fanout_buf #(
        .WIDTH       (WIDTH),
        .PIPE_STAGES (2)
    ) DUT2 (
        .clk (clk),
        .rst (rst),
        .d   (d2),
        .q   (q2)
    );

    //
    // Transaction Type Definition
    //
    typedef struct {
        logic [WIDTH-1:0] data;       // Stimulus driven to d
        logic [WIDTH-1:0] expected;   // Expected value at q
        int               pipe_id;    // Which DUT: 0, 1, or 2
    } trans_t;

    //
    // Communication Channels (Mailboxes)
    //
    mailbox #(trans_t) gen2drv = new();
    mailbox #(trans_t) drv2sb  = new();
    mailbox #(trans_t) mon2sb  = new();

    //
    // Functional Coverage
    //
    logic [WIDTH-1:0] cov_d0, cov_q0;
    logic [WIDTH-1:0] cov_d1, cov_q1;
    logic [WIDTH-1:0] cov_d2, cov_q2;
    logic             cov_rst;

    // Sample coverage signals at posedge
    always @(posedge clk) begin
        cov_d0  = d0;
        cov_q0  = q0;
        cov_d1  = d1;
        cov_q1  = q1;
        cov_d2  = d2;
        cov_q2  = q2;
        cov_rst = rst;
    end

    covergroup cg_functional @(posedge clk iff (!rst));
        // Data value bins: exercise zero, max, mid-range
        cp_d0_val: coverpoint cov_d0 {
            bins zero    = {0};
            bins max_val = {{WIDTH{1'b1}}};
            bins mid     = {[1:{WIDTH{1'b1}}-1]};
        }
        cp_d1_val: coverpoint cov_d1 {
            bins zero    = {0};
            bins max_val = {{WIDTH{1'b1}}};
            bins mid     = {[1:{WIDTH{1'b1}}-1]};
        }
        cp_d2_val: coverpoint cov_d2 {
            bins zero    = {0};
            bins max_val = {{WIDTH{1'b1}}};
            bins mid     = {[1:{WIDTH{1'b1}}-1]};
        }
        // Reset-to-active transition observed
        cp_rst_transition: coverpoint cov_rst {
            bins active  = {1'b0};
            bins in_rst  = {1'b1};
        }
    endgroup
    cg_functional cg_inst = new();

    //
    // Test Counters
    //
    int pass_count = 0;
    int fail_count = 0;
    int test_count = 0;
    int directed_tests_done = 0;

    //
    // Reset Task (Timing Rule 3: NBA at posedge)
    //
    task automatic reset_dut();
        rst <= 1'b1;
        d0  <= '0;
        d1  <= '0;
        d2  <= '0;
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //
    // Assertion Helper: Check and report
    //
    task automatic check(string test_name, logic [WIDTH-1:0] expected, logic [WIDTH-1:0] actual);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $error("[FAIL] %s: expected=%0h, actual=%0h", test_name, expected, actual);
        end
    endtask

    //
    // DT1: passthrough_zero_stages
    // PIPE_STAGES=0: output equals input same cycle (combinational)
    //
    task automatic test_dt1_passthrough();
        logic [WIDTH-1:0] val;
        $display("[DT1] passthrough_zero_stages — start");

        // Drive known values and check same-cycle passthrough
        for (int i = 0; i < 10; i++) begin
            val = $urandom();
            @(posedge clk);
            d0 <= val;
            @(posedge clk);
            // After this posedge, d0 has settled via NBA from prior edge,
            // q0 = d0 combinationally, so q0 should equal val
            check("DT1_passthrough", val, q0);
        end

        $display("[DT1] passthrough_zero_stages — done");
    endtask

    //
    // DT2: one_stage_delay
    // PIPE_STAGES=1: output equals input 1 cycle later
    //
    task automatic test_dt2_one_stage();
        logic [WIDTH-1:0] val;
        logic [WIDTH-1:0] prev_val;
        $display("[DT2] one_stage_delay — start");

        prev_val = '0;  // After reset, pipe is cleared to 0
        for (int i = 0; i < 10; i++) begin
            val = $urandom();
            @(posedge clk);
            d1 <= val;
            @(posedge clk);
            // q1 should be the value that was present at d1 one cycle ago
            check("DT2_one_stage", prev_val, q1);
            prev_val = val;
        end
        // One more cycle to check last driven value appears
        @(posedge clk);
        check("DT2_one_stage_final", prev_val, q1);

        $display("[DT2] one_stage_delay — done");
    endtask

    //
    // DT3: two_stage_delay
    // PIPE_STAGES=2. TB rhythm is `@; drive; @; check` (one drive per iter).
    // At check time the DUT has shifted exactly once since this iter's drive
    // (DUT's NBA for the drive edge fires BEFORE the check-edge Active region,
    //  but the check-edge NBA has not yet completed the second shift), so q2
    // holds the value driven in the PREVIOUS iteration. This matches DT2's
    // scalar pattern; a 2-entry FIFO would mis-model the timing.
    //
    task automatic test_dt3_two_stage();
        logic [WIDTH-1:0] val;
        logic [WIDTH-1:0] prev_val;
        $display("[DT3] two_stage_delay — start");

        prev_val = '0;  // pipe is cleared to 0 after reset
        for (int i = 0; i < 10; i++) begin
            val = $urandom();
            @(posedge clk);
            d2 <= val;
            @(posedge clk);
            check("DT3_two_stage", prev_val, q2);
            prev_val = val;
        end
        // Drain: two more iters driving 0 to flush the pipeline.
        for (int j = 0; j < 2; j++) begin
            @(posedge clk);
            d2 <= '0;
            @(posedge clk);
            check(j == 0 ? "DT3_two_stage_drain0" : "DT3_two_stage_drain1",
                  prev_val, q2);
            prev_val = '0;
        end

        $display("[DT3] two_stage_delay — done");
    endtask

    //
    // DT4: alignment_preserved
    // Drive random pattern through all three DUTs simultaneously,
    // verify each DUT's output matches input delayed by its PIPE_STAGES.
    //
    task automatic test_dt4_alignment();
        localparam int NUM_BEATS = 20;
        logic [WIDTH-1:0] input_stream [NUM_BEATS];
        logic [WIDTH-1:0] exp0, exp1, exp2;
        $display("[DT4] alignment_preserved — start");

        // Generate random input stream
        for (int i = 0; i < NUM_BEATS; i++)
            input_stream[i] = $urandom();

        // Drive all three DUTs with the same stream
        for (int i = 0; i < NUM_BEATS; i++) begin
            @(posedge clk);
            d0 <= input_stream[i];
            d1 <= input_stream[i];
            d2 <= input_stream[i];
        end

        // Wait for pipeline to drain, then verify alignment via final value
        @(posedge clk);
        d0 <= '0;
        d1 <= '0;
        d2 <= '0;

        // At this point:
        // q0 = input_stream[NUM_BEATS-1] (0-delay, same cycle)
        // q1 = input_stream[NUM_BEATS-2] (1-delay, shows prev cycle's value)
        // q2 = input_stream[NUM_BEATS-3] (2-delay, shows 2-ago value)
        exp0 = input_stream[NUM_BEATS-1];
        exp1 = input_stream[NUM_BEATS-2];
        exp2 = input_stream[NUM_BEATS-3];

        check("DT4_align_pipe0", exp0, q0);
        check("DT4_align_pipe1", exp1, q1);
        check("DT4_align_pipe2", exp2, q2);

        // Drain pipe1 and pipe2 — one more cycle
        @(posedge clk);
        check("DT4_align_pipe1_drain", input_stream[NUM_BEATS-1], q1);
        check("DT4_align_pipe2_shift", input_stream[NUM_BEATS-2], q2);

        @(posedge clk);
        check("DT4_align_pipe2_drain", input_stream[NUM_BEATS-1], q2);

        $display("[DT4] alignment_preserved — done");
    endtask

    //
    // DT5: reset_mid_pipe
    // Assert reset while pipeline stages hold data; verify all stages
    // clear to 0 and pipeline resumes correctly after deassertion.
    //
    task automatic test_dt5_reset_mid_pipe();
        logic [WIDTH-1:0] val;
        $display("[DT5] reset_mid_pipe — start");

        // Fill pipes with known non-zero data
        val = {WIDTH{1'b1}};
        @(posedge clk);
        d1 <= val;
        d2 <= val;
        @(posedge clk);
        d1 <= val ^ {WIDTH{1'b1}} >> 1;  // Different pattern
        d2 <= val ^ {WIDTH{1'b1}} >> 1;
        @(posedge clk);
        // Now pipe1 has data in stage 0, pipe2 has data in stages 0 and 1

        // Assert reset mid-pipe
        rst <= 1'b1;
        repeat (3) @(posedge clk);

        // Verify outputs cleared
        check("DT5_pipe1_cleared", '0, q1);
        check("DT5_pipe2_cleared", '0, q2);

        // Deassert reset
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        // Drive new data and verify pipeline works correctly post-reset.
        // TB drives d via NBA at edge A, so d sees `val` only starting at
        // preponed of A+1. Pipe1 therefore takes 2 edges from drive to observe
        // `val` at q1 (Active of A+2); pipe2 takes 3 edges.
        val = 8'hA5;
        @(posedge clk);                 // edge A: schedule d<=val
        d1 <= val;
        d2 <= val;
        @(posedge clk);                 // edge A+1: pipe shifts once
        @(posedge clk);                 // edge A+2: q1 now reflects val
        check("DT5_pipe1_post_reset", val, q1);
        @(posedge clk);                 // edge A+3: q2 now reflects val
        check("DT5_pipe2_post_reset", val, q2);

        $display("[DT5] reset_mid_pipe — done");
    endtask

    //
    // DT6: burst_then_idle
    // 10 cycles of driven data, then idle (hold d constant). Verify the
    // pipeline drains correctly for PIPE_STAGES=1 and PIPE_STAGES=2.
    //
    task automatic test_dt6_burst_then_idle();
        localparam int BURST_LEN = 10;
        logic [WIDTH-1:0] burst_data [BURST_LEN];
        $display("[DT6] burst_then_idle — start");

        // Generate burst data
        for (int i = 0; i < BURST_LEN; i++)
            burst_data[i] = i[WIDTH-1:0] + 1;  // 1, 2, 3, ... BURST_LEN

        // Drive burst into DUT1 (PIPE_STAGES=1). The drive-edge NBA makes the
        // last burst value appear at q1 two edges after it was scheduled.
        for (int i = 0; i < BURST_LEN; i++) begin
            @(posedge clk);
            d1 <= burst_data[i];
        end
        @(posedge clk);                 // hold idle value & shift pipe once
        d1 <= '0;
        @(posedge clk);                 // q1 now shows last burst value
        check("DT6_pipe1_last_burst", burst_data[BURST_LEN-1], q1);

        // Drive same burst into DUT2 (PIPE_STAGES=2).
        for (int i = 0; i < BURST_LEN; i++) begin
            @(posedge clk);
            d2 <= burst_data[i];
        end
        @(posedge clk);                 // drive idle; pipe shifts once
        d2 <= '0;
        @(posedge clk);                 // q2 = burst[BURST_LEN-2]
        check("DT6_pipe2_penultimate", burst_data[BURST_LEN-2], q2);
        @(posedge clk);                 // q2 = burst[BURST_LEN-1]
        check("DT6_pipe2_last_burst", burst_data[BURST_LEN-1], q2);

        $display("[DT6] burst_then_idle — done");
    endtask

    //
    // Random Stress (single-thread, mirrors DT2 timing)
    //
    // Drives 200 random values into DUT1 (PIPE_STAGES=1) with the same
    // `@; drive; @; check` rhythm as DT2. At check time q1 holds the
    // previously driven value, so the scoreboard tracks `prev_val`.
    //
    localparam int NUM_RANDOM_TX = 200;
    int random_done = 0;

    initial begin : random_stress
        logic [WIDTH-1:0] val;
        logic [WIDTH-1:0] prev_val;

        wait (directed_tests_done);
        @(posedge clk);
        wait (!rst);
        repeat (5) @(posedge clk);

        prev_val = '0;
        for (int i = 0; i < NUM_RANDOM_TX; i++) begin
            val = $urandom();
            @(posedge clk);
            d1 <= val;
            @(posedge clk);
            if (q1 !== prev_val) begin
                fail_count++;
                $error("[SB] Mismatch: exp=%0h obs=%0h (pipe1)", prev_val, q1);
            end else begin
                pass_count++;
            end
            test_count++;
            prev_val = val;
        end
        random_done = 1;
    end

    //
    // SVA Properties (Gray Box — White Box Layer)
    //
    // Registered reset-delay shifts so alignment SVAs skip the 1-cycle (pipe1)
    // or 2-cycle (pipe2) transient where stage regs were just force-cleared
    // but $past(d) still samples pre-reset d.
    //
    // 4-deep rst shift covers all alignment transients: during reset stage
    // regs are forced to 0, but $past(d) still samples pre-reset d for up to
    // `PIPE_STAGES` cycles after deassert. 4 is a safe blanket for PIPE_STAGES=2.
    logic [3:0] rst_shift_q;
    always_ff @(posedge clk) begin
        rst_shift_q <= {rst_shift_q[2:0], rst};
    end
    wire rst_recent = rst || |rst_shift_q;

    // A1: After reset deasserts, PIPE_STAGES=1 output must be 0 for at least 1 cycle
    property p_pipe1_reset_clears;
        @(posedge clk) $fell(rst) |-> (q1 == '0);
    endproperty
    a_pipe1_reset_clears: assert property (p_pipe1_reset_clears)
        else $error("SVA: DUT1 output not cleared after reset");

    // A2: After reset deasserts, PIPE_STAGES=2 output must be 0 for at least 1 cycle
    property p_pipe2_reset_clears;
        @(posedge clk) $fell(rst) |-> (q2 == '0);
    endproperty
    a_pipe2_reset_clears: assert property (p_pipe2_reset_clears)
        else $error("SVA: DUT2 output not cleared after reset");

    // A3: PIPE_STAGES=0 output always equals input (combinational passthrough)
    property p_pipe0_passthrough;
        @(posedge clk) disable iff (rst)
            (q0 == d0);
    endproperty
    a_pipe0_passthrough: assert property (p_pipe0_passthrough)
        else $error("SVA: DUT0 passthrough violated: d0=%0h q0=%0h", d0, q0);

    // A4: PIPE_STAGES=1 output equals prior-cycle input (data alignment).
    // Disabled for 1 cycle after rst deasserts so the reset-cleared q1 isn't
    // compared against pre-reset $past(d1).
    property p_pipe1_data_alignment;
        @(posedge clk) disable iff (rst_recent)
            (q1 == $past(d1, 1));
    endproperty
    a_pipe1_data_alignment: assert property (p_pipe1_data_alignment)
        else $error("SVA: DUT1 alignment violated: q1=%0h, past(d1)=%0h", q1, $past(d1,1));

    // A5: PIPE_STAGES=2 output equals 2-cycles-ago input (data alignment).
    // Disabled for 2 cycles after rst deasserts.
    property p_pipe2_data_alignment;
        @(posedge clk) disable iff (rst_recent)
            (q2 == $past(d2, 2));
    endproperty
    a_pipe2_data_alignment: assert property (p_pipe2_data_alignment)
        else $error("SVA: DUT2 alignment violated: q2=%0h, past(d2,2)=%0h", q2, $past(d2,2));

    //
    // Main Test Sequence
    //
    initial begin
        $display("============================================");
        $display("  bnn_fanout_buf Testbench (CRV)");
        $display("  WIDTH=%0d, PIPE_STAGES swept: 0, 1, 2", WIDTH);
        $display("============================================");

        reset_dut();

        // ----- Directed Tests -----
        test_dt1_passthrough();
        test_dt2_one_stage();
        test_dt3_two_stage();
        test_dt4_alignment();
        test_dt5_reset_mid_pipe();

        // Re-reset to clean state before DT6
        reset_dut();
        test_dt6_burst_then_idle();

        $display("--------------------------------------------");
        $display("  Directed tests complete: %0d pass, %0d fail",
                 pass_count, fail_count);
        $display("--------------------------------------------");

        // Signal directed tests done, start random stress
        directed_tests_done = 1;

        // Re-reset for clean random stress
        reset_dut();

        // Wait for random stress to complete or timeout
        fork
            begin
                wait (random_done);
                repeat (50) @(posedge clk);
            end
            begin
                repeat (10000) @(posedge clk);
                $display("[TIMEOUT] Random stress did not complete in time");
            end
        join_any
        disable fork;

        // ----- Final Report -----
        $display("============================================");
        $display("  RESULTS: %0d pass, %0d fail (total %0d)",
                 pass_count, fail_count, test_count);
        $display("  Coverage: %.1f%%", cg_inst.get_coverage());
        $display("============================================");

        if (fail_count == 0)
            $display("*** TEST PASSED ***");
        else
            $display("*** TEST FAILED ***");

        $finish;
    end

endmodule
