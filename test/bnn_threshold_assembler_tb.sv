`timescale 1ns/10ps

module bnn_threshold_assembler_tb;

    localparam int RANDOM_THRESHOLDS = 10000;

    //
    // DUT Interface Signals
    //
    logic        clk = 0;
    logic        rst = 1;
    logic        byte_valid;
    logic        byte_ready;
    logic [7:0]  byte_data;
    logic        thresh_valid;
    logic        thresh_ready;
    logic [31:0] thresh_data;

    //
    // Clock Generation (100 MHz)
    //
    always #5 clk = ~clk;

    //
    // DUT Instantiation
    //
    bnn_threshold_assembler DUT (
        .clk          (clk),
        .rst          (rst),
        .byte_valid   (byte_valid),
        .byte_ready   (byte_ready),
        .byte_data    (byte_data),
        .thresh_valid (thresh_valid),
        .thresh_ready (thresh_ready),
        .thresh_data  (thresh_data)
    );

    //
    // SVA Properties (Gray Box)
    //

    //
    // SVA-1: thresh_valid asserts after exactly 4 byte handshakes
    // RATIONALE: 32-bit threshold = 4 bytes. The internal byte_cnt_r_q reaches
    // 3 (0-indexed) on the 4th byte, triggering assembly_done -> thresh_valid.
    //
    property p_valid_after_4_bytes;
        @(posedge clk) disable iff (rst)
        (DUT.u_dp.byte_cnt_r_q == 2'd3 && byte_valid && byte_ready) |=> thresh_valid;
    endproperty
    assert property (p_valid_after_4_bytes)
    else $error("[SVA] FAIL: thresh_valid did not assert after 4th byte handshake");

    //
    // SVA-2: AXI-Stream valid-hold on output -- once thresh_valid is asserted
    // and thresh_ready is low, thresh_valid must remain high until consumed.
    // RATIONALE: AXI4-Stream protocol compliance; dropping valid is illegal.
    //
    property p_thresh_valid_hold;
        @(posedge clk) disable iff (rst)
        (thresh_valid && !thresh_ready) |=> thresh_valid;
    endproperty
    assert property (p_thresh_valid_hold)
    else $error("[SVA] FAIL: thresh_valid dropped without thresh_ready handshake");

    //
    // SVA-3: thresh_data stable during backpressure -- when thresh_valid is
    // asserted but not consumed, data must not change.
    // RATIONALE: AXI4-Stream data stability requirement.
    //
    property p_thresh_data_stable;
        @(posedge clk) disable iff (rst)
        (thresh_valid && !thresh_ready) |=> $stable(thresh_data);
    endproperty
    assert property (p_thresh_data_stable)
    else $error("[SVA] FAIL: thresh_data changed during backpressure");

    //
    // SVA-4: byte_ready backpressure when output stalled -- when thresh_valid
    // is high and thresh_ready is low, byte_ready must be low to stop input.
    // RATIONALE: byte_ready = ~thresh_vld_r_q | thresh_ready. When stalled,
    // no new bytes should be accepted.
    //
    property p_byte_ready_backpressure;
        @(posedge clk) disable iff (rst)
        (thresh_valid && !thresh_ready) |-> !byte_ready;
    endproperty
    assert property (p_byte_ready_backpressure)
    else $error("[SVA] FAIL: byte_ready high while output stalled");

    //
    // Covergroups
    //

    //
    // COVERGROUP: Covers byte counter states (0..3), threshold value ranges,
    // output backpressure events, and byte-side handshake patterns.
    //
    covergroup cg_threshold @(posedge clk iff (!rst));
        // Cover byte counter states (gray-box into DUT datapath)
        cp_byte_cnt: coverpoint DUT.u_dp.byte_cnt_r_q {
            bins byte_0 = {0};
            bins byte_1 = {1};
            bins byte_2 = {2};
            bins byte_3 = {3};
        }

        // Cover threshold value ranges when valid
        cp_thresh_val: coverpoint thresh_data iff (thresh_valid) {
            bins zero   = {0};
            bins small_v  = {[1:255]};
            bins medium_v = {[256:65535]};
            bins large_v  = {[65536:32'hFFFFFFFE]};
            bins max_v  = {32'hFFFFFFFF};
        }

        // Cover backpressure on output
        cp_backpressure: coverpoint {thresh_valid, thresh_ready} {
            bins flow  = {2'b11};   // consumed immediately
            bins stall = {2'b10};   // backpressure
        }

        // Cover byte handshake patterns
        cp_byte_handshake: coverpoint {byte_valid, byte_ready} {
            bins transfer = {2'b11};  // actual handshake
            bins stall    = {2'b10};  // byte waiting
            bins idle     = {2'b00};  // no activity
        }
    endgroup

    cg_threshold cg_inst = new();

    //
    // Scoreboard
    //
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    // Check helper: only prints on failure
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
        rst        <= 1'b1;
        byte_valid <= 1'b0;
        byte_data  <= 8'h00;
        thresh_ready <= 1'b0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    //
    // Helper: Send 4 bytes and collect threshold (with optional gaps/backpressure)
    //   bytes[0] = LSB, bytes[3] = MSB
    //   Returns assembled threshold via output arg
    //
    task automatic send_threshold(
        input  logic [7:0] b0, b1, b2, b3,
        input  bit         with_gaps,        // insert random valid gaps
        input  bit         with_backpressure,// delay thresh_ready
        output logic [31:0] result
    );
        logic [7:0] bytes_arr [4];
        bytes_arr[0] = b0;
        bytes_arr[1] = b1;
        bytes_arr[2] = b2;
        bytes_arr[3] = b3;

        for (int i = 0; i < 4; i++) begin
            if (with_gaps && ($urandom_range(0,99) < 30)) begin
                byte_valid <= 1'b0;
                repeat ($urandom_range(1, 3)) @(posedge clk);
            end
            byte_valid <= 1'b1;
            byte_data  <= bytes_arr[i];
            @(posedge clk);
            while (!byte_ready) @(posedge clk);
            byte_valid <= 1'b0;
        end

        // Wait for thresh_valid
        if (with_backpressure) begin
            thresh_ready <= 1'b0;
            repeat ($urandom_range(1, 5)) @(posedge clk);
        end
        thresh_ready <= 1'b1;
        @(posedge clk);
        while (!thresh_valid) @(posedge clk);
        result = thresh_data;
        @(posedge clk);
        thresh_ready <= 1'b0;
    endtask

    //
    // Test Scenarios
    //

    //--- Test 1: Known value -- {0x78, 0x56, 0x34, 0x12} -> 0x12345678 --------
    task automatic test_known_value();
        logic [31:0] result;
        $display("[TEST] test_known_value: expect 0x12345678");
        send_threshold(8'h78, 8'h56, 8'h34, 8'h12, 0, 0, result);
        check("known_value", result == 32'h12345678,
              $sformatf("expected 0x12345678, got 0x%08h", result));
    endtask

    //--- Test 2: Zero threshold -- all zero bytes -> 0x00000000 ----------------
    task automatic test_zero_threshold();
        logic [31:0] result;
        $display("[TEST] test_zero_threshold");
        send_threshold(8'h00, 8'h00, 8'h00, 8'h00, 0, 0, result);
        check("zero_threshold", result == 32'h00000000,
              $sformatf("expected 0x00000000, got 0x%08h", result));
    endtask

    //--- Test 3: Maximum threshold -- all 0xFF -> 0xFFFFFFFF -------------------
    task automatic test_max_threshold();
        logic [31:0] result;
        $display("[TEST] test_max_threshold");
        send_threshold(8'hFF, 8'hFF, 8'hFF, 8'hFF, 0, 0, result);
        check("max_threshold", result == 32'hFFFFFFFF,
              $sformatf("expected 0xFFFFFFFF, got 0x%08h", result));
    endtask

    //--- Test 4: Backpressure test -- thresh_ready=0 after 4th byte -----------
    task automatic test_backpressure();
        logic [31:0] result;
        $display("[TEST] test_backpressure");
        send_threshold(8'hAA, 8'hBB, 8'hCC, 8'hDD, 0, 1, result);
        check("backpressure", result == 32'hDDCCBBAA,
              $sformatf("expected 0xDDCCBBAA, got 0x%08h", result));
    endtask

    //--- Test 5: Gapped bytes -- byte_valid gaps between bytes -----------------
    task automatic test_gapped_bytes();
        logic [31:0] result;
        $display("[TEST] test_gapped_bytes");
        send_threshold(8'h01, 8'h02, 8'h03, 8'h04, 1, 0, result);
        check("gapped_bytes", result == 32'h04030201,
              $sformatf("expected 0x04030201, got 0x%08h", result));
    endtask

    //--- Test 6: Back-to-back thresholds -- continuous 4-byte streams ----------
    task automatic test_back_to_back();
        logic [31:0] result;
        logic [31:0] expected;
        $display("[TEST] test_back_to_back: 10 consecutive thresholds");
        thresh_ready <= 1'b1;

        for (int t = 0; t < 10; t++) begin
            logic [7:0] b0, b1, b2, b3;
            b0 = 8'(t * 4);
            b1 = 8'(t * 4 + 1);
            b2 = 8'(t * 4 + 2);
            b3 = 8'(t * 4 + 3);
            expected = {b3, b2, b1, b0};

            for (int i = 0; i < 4; i++) begin
                byte_valid <= 1'b1;
                case (i)
                    0: byte_data <= b0;
                    1: byte_data <= b1;
                    2: byte_data <= b2;
                    3: byte_data <= b3;
                endcase
                @(posedge clk);
                while (!byte_ready) @(posedge clk);
            end
            byte_valid <= 1'b0;

            // Wait for valid
            @(posedge clk);
            while (!thresh_valid) @(posedge clk);
            check($sformatf("back2back_%0d", t), thresh_data == expected,
                  $sformatf("exp=0x%08h got=0x%08h", expected, thresh_data));
            @(posedge clk);
        end
        thresh_ready <= 1'b0;
    endtask

    //--- Test 7: Coverage closure -- explicit threshold value classes ---------
    task automatic test_value_range_closure();
        logic [31:0] result;
        $display("[TEST] test_value_range_closure");

        send_threshold(8'h01, 8'h00, 8'h00, 8'h00, 0, 0, result);
        check("range_small", result == 32'h00000001,
              $sformatf("expected 0x00000001, got 0x%08h", result));

        send_threshold(8'h00, 8'h01, 8'h00, 8'h00, 0, 0, result);
        check("range_medium", result == 32'h00000100,
              $sformatf("expected 0x00000100, got 0x%08h", result));

        send_threshold(8'h00, 8'h00, 8'h01, 8'h00, 0, 0, result);
        check("range_large", result == 32'h00010000,
              $sformatf("expected 0x00010000, got 0x%08h", result));
    endtask

    //--- Test 8: Byte-side stall while output is backpressured ----------------
    task automatic test_input_stall_during_output_backpressure();
        logic [31:0] result;
        $display("[TEST] test_input_stall_during_output_backpressure");

        thresh_ready <= 1'b0;
        byte_valid   <= 1'b1;
        byte_data    <= 8'h11; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_data    <= 8'h22; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_data    <= 8'h33; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_data    <= 8'h44; @(posedge clk); while (!byte_ready) @(posedge clk);

        byte_data    <= 8'hAA;
        repeat (3) begin
            @(posedge clk);
            check("input_stall_byte_ready_low", byte_ready == 1'b0,
                  $sformatf("byte_ready=%b expected 0 during output stall", byte_ready));
        end

        thresh_ready <= 1'b1;
        while (!thresh_valid) @(posedge clk);
        result = thresh_data;
        check("stalled_output_value", result == 32'h44332211,
              $sformatf("expected 0x44332211, got 0x%08h", result));
        @(posedge clk);

        while (!byte_ready) @(posedge clk);
        byte_data <= 8'hBB; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_data <= 8'hCC; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_data <= 8'hDD; @(posedge clk); while (!byte_ready) @(posedge clk);
        byte_valid <= 1'b0;

        @(posedge clk);
        while (!thresh_valid) @(posedge clk);
        check("stalled_input_resume", thresh_data == 32'hDDCCBBAA,
              $sformatf("expected 0xDDCCBBAA, got 0x%08h", thresh_data));
        @(posedge clk);
        thresh_ready <= 1'b0;
    endtask

    //--- Test 9: Random stress -- random byte values, random gaps/backpressure -
    task automatic test_random_stress();
        logic [31:0] result;
        logic [7:0] b [4];
        logic [31:0] expected;
        int num_thresh = RANDOM_THRESHOLDS;
        $display("[TEST] test_random_stress: %0d random thresholds", num_thresh);

        for (int t = 0; t < num_thresh; t++) begin
            for (int i = 0; i < 4; i++)
                b[i] = $urandom();
            expected = {b[3], b[2], b[1], b[0]};

            send_threshold(b[0], b[1], b[2], b[3],
                           $urandom_range(0,1), $urandom_range(0,1), result);
            check($sformatf("random_%0d", t), result == expected,
                  $sformatf("exp=0x%08h got=0x%08h", expected, result));
        end
    endtask

    //--- Test 8: LE reconstruction -- specific patterns for endianness ---------
    task automatic test_le_reconstruction();
        logic [31:0] result;
        $display("[TEST] test_le_reconstruction: verify {B3,B2,B1,B0}");

        // Pattern: B0=0x11, B1=0x22, B2=0x33, B3=0x44 -> 0x44332211
        send_threshold(8'h11, 8'h22, 8'h33, 8'h44, 0, 0, result);
        check("le_recon_1", result == 32'h44332211,
              $sformatf("expected 0x44332211, got 0x%08h", result));

        // Pattern: B0=0xEF, B1=0xBE, B2=0xAD, B3=0xDE -> 0xDEADBEEF
        send_threshold(8'hEF, 8'hBE, 8'hAD, 8'hDE, 0, 0, result);
        check("le_recon_deadbeef", result == 32'hDEADBEEF,
              $sformatf("expected 0xDEADBEEF, got 0x%08h", result));
    endtask

    //
    // Main Test Sequence
    //
    initial begin
        $display("============================================================");
        $display("  bnn_threshold_assembler Testbench (CRV, Gray-Box)");
        $display("============================================================");

        reset_dut();

        test_known_value();
        reset_dut();

        test_zero_threshold();
        reset_dut();

        test_max_threshold();
        reset_dut();

        test_backpressure();
        reset_dut();

        test_gapped_bytes();
        reset_dut();

        test_back_to_back();
        reset_dut();

        test_value_range_closure();
        reset_dut();

        test_input_stall_during_output_backpressure();
        reset_dut();

        test_le_reconstruction();
        reset_dut();

        test_random_stress();

        repeat (20) @(posedge clk);

        //
        // Scoreboard Summary
        //
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_threshold_assembler");
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
