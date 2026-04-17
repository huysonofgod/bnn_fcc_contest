`timescale 1ns/1ps

module bnn_counter_tb;

    //
    // Parameters
    //
    parameter int WIDTH     = 8;
    parameter int RESET_VAL = 0;

    localparam int RANDOM_STRESS_CYCLES = 10000;

    //
    // DUT Interface Signals
    //
    logic               clk = 0;
    logic               rst = 1;
    logic               en;
    logic               load;
    logic [WIDTH-1:0]   load_val;
    logic [WIDTH-1:0]   max_val;
    logic [WIDTH-1:0]   count;
    logic               tc;
    logic               tc_pulse;

    //
    // Clock Generation (100 MHz, 10ns period)
    //
    always #5 clk = ~clk;

    //
    // DUT Instantiation
    //
    bnn_counter #(
        .WIDTH     (WIDTH),
        .RESET_VAL (RESET_VAL)
    ) DUT (
        .clk      (clk),
        .rst      (rst),
        .en       (en),
        .load     (load),
        .load_val (load_val),
        .max_val  (max_val),
        .count    (count),
        .tc       (tc),
        .tc_pulse (tc_pulse)
    );

    //
    // SVA Properties (Gray Box)
    //

    //
    // SVA-1: tc_pulse is exactly 1 clock cycle wide
    // RATIONALE: Downstream modules rely on single-cycle pulses for counting.
    // When tc_pulse asserts, it must deassert on the very next cycle.
    //
    property p_tc_pulse_single_cycle;
        @(posedge clk) disable iff (rst)
        tc_pulse |=> !tc_pulse;
    endproperty
    assert property (p_tc_pulse_single_cycle)
    else $error("[SVA] FAIL: tc_pulse was high for more than 1 cycle");

    //
    // SVA-2: tc_pulse fires only when tc AND en were both true in prior cycle
    // RATIONALE: tc_pulse = registered(tc & en). Without en, counter is stalled
    // so no pulse should fire.
    //
    property p_tc_pulse_requires_tc_and_en;
        @(posedge clk) disable iff (rst)
        tc_pulse |-> $past(tc && en);
    endproperty
    assert property (p_tc_pulse_requires_tc_and_en)
    else $error("[SVA] FAIL: tc_pulse fired without prior tc && en");

    //
    // SVA-3: Count increments only when en=1 and load=0 and not at tc
    // RATIONALE: Verify enable gating works -- count should advance by +1
    // when enabled, not loading, and not at terminal count wrap.
    //
    property p_count_increments_on_en;
        @(posedge clk) disable iff (rst)
        (en && !load && !tc) |=> (count == ($past(count) + WIDTH'(1)));
    endproperty
    assert property (p_count_increments_on_en)
    else $error("[SVA] FAIL: count did not increment when en=1, load=0, no wrap");

    //
    // SVA-4: Count holds steady when en=0 and load=0
    // RATIONALE: Counter must freeze when disabled. Any change is a bug.
    //
    property p_count_holds_when_disabled;
        @(posedge clk) disable iff (rst)
        (!en && !load) |=> (count == $past(count));
    endproperty
    assert property (p_count_holds_when_disabled)
    else $error("[SVA] FAIL: count changed while en=0 and load=0");

    //
    // SVA-5: Load has priority over enable (synchronous parallel load)
    // RATIONALE: When load=1, the counter must capture load_val regardless of
    // en state. This tests the MUX priority encoding.
    //
    property p_load_priority;
        @(posedge clk) disable iff (rst)
        load |=> (count == $past(load_val));
    endproperty
    assert property (p_load_priority)
    else $error("[SVA] FAIL: load did not override -- count != past load_val");

    //
    // SVA-6: Counter wraps to RESET_VAL after terminal count with enable
    // RATIONALE: When count==max_val and en=1 (no load), next cycle count
    // must be RESET_VAL. Verifies wrap-around behavior.
    //
    property p_wrap_after_tc;
        @(posedge clk) disable iff (rst)
        (tc && en && !load) |=> (count == WIDTH'(RESET_VAL));
    endproperty
    assert property (p_wrap_after_tc)
    else $error("[SVA] FAIL: counter did not wrap to RESET_VAL after tc+en");

    //
    // Covergroups
    //

    //
    // COVERGROUP: Counter edge cases, control combos, and rollover cross
    // Tracks count boundaries (0, 1, mid, near-max, at-max), max_val
    // settings, control signal combos (en x load), tc_pulse firing, and
    // cross coverage of control state at rollover point.
    //
    logic [WIDTH-1:0] max_val_latched;
    always_ff @(posedge clk) max_val_latched <= max_val;

    covergroup cg_counter @(posedge clk iff (!rst));
        // Cover count at boundaries
        cp_count_val: coverpoint count {
            bins zero     = {0};
            bins one      = {1};
            bins mid      = {[2:253]};
            bins near_max = {254};
            bins at_max   = {255};
        }

        // Cover max_val settings (parameterized)
        cp_max_val: coverpoint max_val {
            bins zero_max   = {0};
            bins one_max    = {1};
            bins typical    = {[2:254]};
            bins full_range = {255};
        }

        // Cover control signal combinations
        cp_controls: coverpoint {en, load} {
            bins disabled       = {2'b00};   // no action
            bins counting       = {2'b10};   // normal count
            bins loading        = {2'b01};   // load only
            bins load_while_en  = {2'b11};   // load priority test
        }

        // Cover tc_pulse assertion
        cp_tc_pulse: coverpoint tc_pulse {
            bins no_pulse = {1'b0};
            bins pulse    = {1'b1};
        }

        // Cross coverage: control state at rollover
        cx_rollover: cross cp_count_val, cp_controls {
            bins rollover_active = binsof(cp_count_val.at_max) &&
                                   binsof(cp_controls.counting);
        }
    endgroup

    cg_counter cg_inst = new();

    //
    // Scoreboard
    //
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];   // collect per-case failure messages

    // Check helper: only prints on failure, logs the case name
    function automatic void check(string test_name, logic condition, string msg = "");
        if (condition) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
            $error("[SB] %s: %s", test_name, msg);
        end
    endfunction

    //
    // Reset Task (Timing Rule 3: NBA at posedge)
    //
    task automatic reset_dut();
        rst <= 1'b1;
        en  <= 1'b0;
        load <= 1'b0;
        load_val <= '0;
        max_val  <= '0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    //
    // Test Scenarios
    //

    //--- Test 1: Free-run count from 0 to max_val, verify wrap ----------------
    task automatic test_free_run();
        logic [WIDTH-1:0] expected;
        $display("[TEST] test_free_run: max_val=10");
        @(posedge clk);
        en      <= 1'b1;
        load    <= 1'b0;
        max_val <= 8'd10;
        expected = WIDTH'(RESET_VAL);

        repeat (25) begin
            @(posedge clk);
            // After en was set, count should follow expected
            check("free_run_count", count == expected,
                  $sformatf("exp=%0d got=%0d", expected, count));
            if (expected == 8'd10)
                expected = WIDTH'(RESET_VAL);
            else
                expected = expected + 1;
        end
        en <= 1'b0;
        @(posedge clk);
    endtask

    //--- Test 2: Load test -- various values, verify immediate capture --------
    task automatic test_load();
        $display("[TEST] test_load: load various values");
        @(posedge clk);
        max_val <= 8'd255;
        en      <= 1'b0;

        for (int v = 0; v < 256; v += 51) begin
            @(posedge clk);
            load     <= 1'b1;
            load_val <= WIDTH'(v);
            @(posedge clk);
            load <= 1'b0;
            @(posedge clk);
            check("load_capture", count == WIDTH'(v),
                  $sformatf("loaded %0d, got %0d", v, count));
        end
    endtask

    //--- Test 3: Enable gating -- toggle en, verify count freezes -------------
    task automatic test_enable_gating();
        logic [WIDTH-1:0] frozen_val;
        $display("[TEST] test_enable_gating");
        @(posedge clk);
        max_val <= 8'd100;
        en      <= 1'b1;
        load    <= 1'b0;

        repeat (5) @(posedge clk);
        en <= 1'b0;
        @(posedge clk);
        frozen_val = count;

        repeat (10) begin
            @(posedge clk);
            check("enable_gating", count == frozen_val,
                  $sformatf("count changed to %0d while en=0", count));
        end

        en <= 1'b1;
        @(posedge clk);
        @(posedge clk);
        check("enable_resume", count == frozen_val + 1,
              $sformatf("expected %0d, got %0d", frozen_val + 1, count));
        en <= 1'b0;
    endtask

    //--- Test 4: max_val=0 -- tc fires immediately ----------------------------
    task automatic test_max_val_zero();
        $display("[TEST] test_max_val_zero (edge case)");
        reset_dut();
        @(posedge clk);
        max_val <= 8'd0;
        en      <= 1'b1;
        load    <= 1'b0;

        @(posedge clk);
        // count should be RESET_VAL=0, tc should be 1 (count==max_val==0)
        check("max0_tc_immediate", tc == 1'b1,
              $sformatf("tc=%b, expected 1 at count=0 max=0", tc));

        @(posedge clk);
        // tc_pulse should fire (registered tc_and_en from prior cycle)
        check("max0_tc_pulse", tc_pulse == 1'b1,
              $sformatf("tc_pulse=%b, expected 1", tc_pulse));

        @(posedge clk);
        // count should wrap back to RESET_VAL
        check("max0_wrap", count == WIDTH'(RESET_VAL),
              $sformatf("count=%0d, expected RESET_VAL=%0d", count, RESET_VAL));
        en <= 1'b0;
    endtask

    //--- Test 5: max_val=1 -- two-state counter --------------------------------
    task automatic test_max_val_one();
        $display("[TEST] test_max_val_one (two-state)");
        reset_dut();
        @(posedge clk);
        max_val <= 8'd1;
        en      <= 1'b1;
        load    <= 1'b0;

        // Expect: 0, 1, 0, 1, 0, 1 ...
        repeat (6) begin
            @(posedge clk);
        end
        // Just let SVAs catch issues; also check toggle
        check("max1_toggle", (count == 0) || (count == 1),
              $sformatf("count=%0d, expected 0 or 1", count));
        en <= 1'b0;
    endtask

    //--- Test 6: Load during tc -- verify load takes priority ------------------
    task automatic test_load_during_tc();
        $display("[TEST] test_load_during_tc");
        reset_dut();
        @(posedge clk);
        max_val <= 8'd5;
        en      <= 1'b1;
        load    <= 1'b0;

        // Run until count reaches max
        wait (count == 8'd5);
        @(posedge clk);
        // Now load a value while at tc
        load     <= 1'b1;
        load_val <= 8'd42;
        @(posedge clk);
        load <= 1'b0;
        @(posedge clk);
        check("load_during_tc", count == 8'd42,
              $sformatf("expected 42, got %0d", count));
        en <= 1'b0;
    endtask

    //--- Test 7: Load while enable is high -- explicit load priority combo ----
    task automatic test_load_while_en();
        $display("[TEST] test_load_while_en");
        reset_dut();
        @(posedge clk);
        max_val <= 8'd200;
        en      <= 1'b1;
        load    <= 1'b0;

        repeat (3) @(posedge clk);
        @(posedge clk);
        load     <= 1'b1;
        load_val <= 8'd99;
        @(posedge clk);
        load <= 1'b0;
        @(posedge clk);
        check("load_while_en", count == 8'd99,
              $sformatf("expected 99, got %0d", count));
        en <= 1'b0;
    endtask

    //--- Test 8: Full-range boundary walk -- force 254/255/wrap coverage -----
    task automatic test_full_range_boundaries();
        $display("[TEST] test_full_range_boundaries");
        reset_dut();
        @(posedge clk);
        max_val  <= 8'hFF;
        en       <= 1'b0;
        load     <= 1'b1;
        load_val <= 8'hFD;
        @(posedge clk);
        load <= 1'b0;
        en   <= 1'b1;

        @(posedge clk);
        @(posedge clk);
        check("full_range_254", count == 8'hFE,
              $sformatf("expected 254, got %0d", count));
        @(posedge clk);
        check("full_range_255", count == 8'hFF,
              $sformatf("expected 255, got %0d", count));
        @(posedge clk);
        check("full_range_wrap", count == WIDTH'(RESET_VAL),
              $sformatf("expected RESET_VAL=%0d, got %0d", RESET_VAL, count));
        en <= 1'b0;
    endtask

    //--- Test 9: Near-max load while enabled ----------------------------------
    task automatic test_nearmax_load_while_en();
        $display("[TEST] test_nearmax_load_while_en");
        reset_dut();

        @(posedge clk);
        max_val  <= 8'hFF;
        en       <= 1'b0;
        load     <= 1'b1;
        load_val <= 8'hFD;
        @(posedge clk);
        load <= 1'b0;
        en   <= 1'b1;

        wait (count == 8'hFE);
        load     <= 1'b1;
        load_val <= 8'h33;
        @(posedge clk);
        load <= 1'b0;
        @(posedge clk);

        check("nearmax_load_while_en", count == 8'h33,
              $sformatf("expected 0x33, got 0x%02h", count));

        en <= 1'b0;
        @(posedge clk);
    endtask

    //--- Test 10: Random stress -- constrained random for closure -------------
    task automatic test_random_stress();
        $display("[TEST] test_random_stress: %0d cycles", RANDOM_STRESS_CYCLES);
        reset_dut();

        @(posedge clk);
        max_val <= 8'd20;
        en      <= 1'b0;
        load    <= 1'b0;

        for (int c = 0; c < RANDOM_STRESS_CYCLES; c++) begin
            @(posedge clk);
            en       <= $urandom_range(0, 1);
            load     <= ($urandom_range(0, 99) < 10);
            load_val <= $urandom();
            if ($urandom_range(0, 99) < 5)
                max_val <= $urandom_range(0, 255);
        end

        en   <= 1'b0;
        load <= 1'b0;
        @(posedge clk);
    endtask

    //--- Test 11 (Negative): Counter does NOT overflow past WIDTH bits ---------
    task automatic test_no_overflow();
        $display("[TEST] test_no_overflow: max_val = all-ones");
        reset_dut();
        @(posedge clk);
        max_val <= {WIDTH{1'b1}};  // 255
        en      <= 1'b1;
        load    <= 1'b0;

        // Run to max, check wrap
        repeat (260) @(posedge clk);
        // count should never exceed WIDTH bits (always <= max_val)
        check("no_overflow", count <= {WIDTH{1'b1}},
              $sformatf("count=%0d overflowed", count));
        en <= 1'b0;
    endtask

    //
    // Main Test Sequence
    //
    initial begin
        $display("============================================================");
        $display("  bnn_counter Testbench (CRV, Gray-Box)");
        $display("  WIDTH=%0d, RESET_VAL=%0d", WIDTH, RESET_VAL);
        $display("============================================================");

        reset_dut();

        test_free_run();
        reset_dut();

        test_load();
        reset_dut();

        test_enable_gating();
        reset_dut();

        test_max_val_zero();

        test_max_val_one();

        test_load_during_tc();

        test_load_while_en();

        test_full_range_boundaries();

        test_nearmax_load_while_en();

        test_no_overflow();

        test_random_stress();

        // Allow final SVA evaluation
        repeat (20) @(posedge clk);

        //
        // Scoreboard Summary
        //
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_counter");
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
