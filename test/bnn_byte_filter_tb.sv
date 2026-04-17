`timescale 1ns/10ps

module bnn_byte_filter_tb;

    //==========================================================================
    // Parameters
    //==========================================================================
    parameter int BUS_WIDTH = 64;
    localparam int NUM_BYTES = BUS_WIDTH / 8;  // 8

    //==========================================================================
    // DUT Interface Signals
    //==========================================================================
    logic                   clk = 0;
    logic                   rst = 1;
    // Slave interface
    logic                   s_valid;
    logic                   s_ready;
    logic [BUS_WIDTH-1:0]   s_data;
    logic [NUM_BYTES-1:0]   s_keep;
    logic                   s_last;
    // Master interface
    logic                   m_valid;
    logic [7:0]             m_data;
    logic                   m_last;
    logic                   m_ready;

    //==========================================================================
    // Clock Generation (100 MHz)
    //==========================================================================
    always #5 clk = ~clk;

    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    bnn_byte_filter #(
        .BUS_WIDTH (BUS_WIDTH)
    ) DUT (
        .clk     (clk),
        .rst     (rst),
        .s_valid (s_valid),
        .s_ready (s_ready),
        .s_data  (s_data),
        .s_keep  (s_keep),
        .s_last  (s_last),
        .m_valid (m_valid),
        .m_data  (m_data),
        .m_last  (m_last),
        .m_ready (m_ready)
    );

    //==========================================================================
    // SVA Properties (Gray Box)
    //==========================================================================

    //--------------------------------------------------------------------------
    // After entering SERIALIZE, byte index eventually reaches 7.
    // RATIONALE: the design must iterate all byte positions (0..7); stalls may
    // extend total cycles under backpressure, so this uses a bounded eventuality.
    //--------------------------------------------------------------------------
    property p_serialize_duration;
        @(posedge clk) disable iff (rst)
        $rose(DUT.u_fsm.state_r == DUT.u_fsm.SERIALIZE) |->
            ##[0:64] ((DUT.u_fsm.state_r == DUT.u_fsm.SERIALIZE) &&
                      (DUT.u_dp.byte_idx_r_q == 3'd7));
    endproperty
    assert property (p_serialize_duration)
    else $error("[assertion] FAIL: serialize did not complete in 8 cycles");

    //--------------------------------------------------------------------------
    // m_valid = keep_bit when in SERIALIZE -- valid output is directly
    // gated by the captured keep bit at the current byte index.
    // RATIONALE: Invalid bytes (keep=0) must produce m_valid=0.
    //--------------------------------------------------------------------------
    property p_m_valid_follows_keep;
        @(posedge clk) disable iff (rst)
        (DUT.u_fsm.state_r == DUT.u_fsm.SERIALIZE) |->
            (m_valid == (DUT.u_dp.keep_r_q[DUT.u_dp.byte_idx_r_q] & DUT.u_fsm.in_serialize));
    endproperty
    assert property (p_m_valid_follows_keep)
    else $error("[assertion] FAIL: m_valid does not match keep bit in SERIALIZE");

    //--------------------------------------------------------------------------
    // m_last only on last valid byte -- m_last asserts only when the
    // byte index matches last_valid_idx and the captured s_last was high.
    // RATIONALE: m_last marks the final valid byte of the entire stream.
    //--------------------------------------------------------------------------
    property p_m_last_on_last_valid;
        @(posedge clk) disable iff (rst)
        m_last |-> (DUT.u_dp.last_r_q &&
                    DUT.u_dp.byte_idx_r_q == DUT.u_dp.last_valid_idx_r_q);
    endproperty
    assert property (p_m_last_on_last_valid)
    else $error("[assertion] FAIL: m_last asserted at wrong byte index");

    //--------------------------------------------------------------------------
    // AXI-Stream valid-hold when m_valid && !m_ready -- data and valid
    // must remain stable during backpressure.
    // RATIONALE: AXI4-Stream protocol compliance.
    // NOTE: This module has combinational m_valid tied to FSM state. The FSM
    // stalls idx advancement when m_valid && !m_ready (advance signal is 0),
    // so m_valid and m_data remain stable.
    //--------------------------------------------------------------------------
    property p_m_valid_hold;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> (m_valid && $stable(m_data));
    endproperty
    assert property (p_m_valid_hold)
    else $error("[assertion] FAIL: m_valid/m_data changed during backpressure");

    //--------------------------------------------------------------------------
    // s_ready only in EMPTY state -- upstream cannot push data while
    // the byte filter is serializing.
    // RATIONALE: Prevents data corruption from accepting a new word mid-serialize.
    //--------------------------------------------------------------------------
    property p_s_ready_only_empty;
        @(posedge clk) disable iff (rst)
        s_ready |-> (DUT.u_fsm.state_r == DUT.u_fsm.EMPTY);
    endproperty
    assert property (p_s_ready_only_empty)
    else $error("[assertion] FAIL: s_ready asserted outside EMPTY state");

    //==========================================================================
    // Covergroups
    //==========================================================================

    //--------------------------------------------------------------------------
    // COVERGROUP: Covers s_keep patterns (all, none, single bytes, alternating),
    // byte index coverage, valid byte count per word, and s_last at various
    // last_valid_idx positions.
    //--------------------------------------------------------------------------
    covergroup cg_byte_filter @(posedge clk iff (!rst));
        // Cover s_keep patterns (sampled at slave handshake)
        cp_keep_patterns: coverpoint s_keep iff (s_valid && s_ready) {
            bins all_valid   = {8'hFF};
            bins none_valid  = {8'h00};
            bins single_0    = {8'h01};
            bins single_1    = {8'h02};
            bins single_2    = {8'h04};
            bins single_3    = {8'h08};
            bins single_4    = {8'h10};
            bins single_5    = {8'h20};
            bins single_6    = {8'h40};
            bins single_7    = {8'h80};
            bins alternating = {8'hAA, 8'h55};
            bins partial     = default;
        }

        // Cover byte_idx (gray-box)
        cp_byte_idx: coverpoint DUT.u_dp.byte_idx_r_q
                iff (DUT.u_fsm.state_r == DUT.u_fsm.SERIALIZE) {
            bins all_indices[] = {[0:7]};
        }

        // Cover valid byte count per word
        cp_valid_count: coverpoint $countones(s_keep) iff (s_valid && s_ready) {
            bins zero_v = {0};
            bins some   = {[1:7]};
            bins all_v  = {8};
        }

        // Cover s_last
        cp_last: coverpoint s_last iff (s_valid && s_ready) {
            bins not_last = {0};
            bins last_v   = {1};
        }
    endgroup

    cg_byte_filter cg_inst = new();

    //==========================================================================
    // Scoreboard
    //==========================================================================
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

    //==========================================================================
    // Reference Model: expected byte stream from a word
    // Returns queue of {data, m_last} for valid bytes only
    //==========================================================================
    typedef struct {
        logic [7:0] data;
        logic       last;
    } byte_expect_t;

    function automatic void ref_byte_filter(
        input  logic [63:0]   data,
        input  logic [7:0]    keep,
        input  logic          s_last_f,
        output byte_expect_t  expected[$]
    );
        int last_valid_idx;
        expected = {};

        // Find highest set bit in keep
        last_valid_idx = -1;
        for (int k = 0; k < 8; k++)
            if (keep[k]) last_valid_idx = k;

        for (int i = 0; i < 8; i++) begin
            if (keep[i]) begin
                byte_expect_t e;
                e.data = data[i*8 +: 8];
                e.last = s_last_f && (i == last_valid_idx);
                expected.push_back(e);
            end
        end
    endfunction

    // Expected output queue
    byte_expect_t exp_queue[$];

    // Push expected bytes when slave handshake occurs
    always @(posedge clk) begin
        if (!rst && s_valid && s_ready) begin
            byte_expect_t word_bytes[$];
            ref_byte_filter(s_data, s_keep, s_last, word_bytes);
            foreach (word_bytes[i])
                exp_queue.push_back(word_bytes[i]);
        end
    end

    // Monitor: compare on master handshake
    int mon_idx = 0;
    always @(posedge clk) begin
        if (!rst && m_valid && m_ready) begin
            if (exp_queue.size() > 0) begin
                byte_expect_t e;
                e = exp_queue.pop_front();
                check($sformatf("byte_%0d_data", mon_idx),
                      m_data === e.data,
                      $sformatf("exp=0x%02h got=0x%02h", e.data, m_data));
                check($sformatf("byte_%0d_last", mon_idx),
                      m_last === e.last,
                      $sformatf("exp_last=%b got_last=%b", e.last, m_last));
                mon_idx++;
            end
        end
    end

    //==========================================================================
    // Reset Task
    //==========================================================================
    task automatic reset_dut();
        rst     <= 1'b1;
        s_valid <= 1'b0;
        s_data  <= '0;
        s_keep  <= '0;
        s_last  <= 1'b0;
        m_ready <= 1'b0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    //==========================================================================
    // Helper: Send one word to slave interface, wait for accept
    //==========================================================================
    task automatic send_word(
        input logic [63:0]  data,
        input logic [7:0]   keep,
        input logic         last
    );
        @(posedge clk);
        s_valid <= 1'b1;
        s_data  <= data;
        s_keep  <= keep;
        s_last  <= last;
        @(posedge clk);
        while (!s_ready) @(posedge clk);
        s_valid <= 1'b0;
        s_last  <= 1'b0;
    endtask

    //==========================================================================
    // Helper: Drain all output bytes from current word (8 cycles)
    //==========================================================================
    task automatic drain_word();
        repeat (12) @(posedge clk);  // 8 serialize + margin
    endtask

    //==========================================================================
    // Test Scenarios
    //==========================================================================

    // All bytes valid (s_keep=0xFF)
    task automatic test_all_valid();
        $display("[TEST] test_all_valid: keep=0xFF");
        m_ready <= 1'b1;
        send_word(64'h0807060504030201, 8'hFF, 1'b1);
        drain_word();
    endtask

    // No bytes valid (s_keep=0x00, edge case)
    task automatic test_no_valid();
        $display("[TEST] test_no_valid: keep=0x00 (edge case)");
        m_ready <= 1'b1;
        send_word(64'hDEADBEEFCAFEBABE, 8'h00, 1'b0);
        drain_word();
        // No m_valid should fire -- just verifying FSM doesn't hang
        send_word(64'h0102030405060708, 8'hFF, 1'b1);
        drain_word();
    endtask

    // Single byte patterns -- test each single-bit s_keep
    task automatic test_single_byte_patterns();
        $display("[TEST] test_single_byte_patterns");
        m_ready <= 1'b1;

        for (int b = 0; b < 8; b++) begin
            logic [7:0] keep;
            logic [63:0] data;
            keep = 8'(1 << b);
            data = 64'h0807060504030201;
            send_word(data, keep, (b == 7));
            drain_word();
        end
    endtask

    // Alternating patterns (0xAA, 0x55)
    task automatic test_alternating();
        $display("[TEST] test_alternating: keep=0xAA then 0x55");
        m_ready <= 1'b1;
        send_word(64'hAABBCCDD11223344, 8'hAA, 1'b0);
        drain_word();
        send_word(64'hAABBCCDD11223344, 8'h55, 1'b1);
        drain_word();
    endtask

    // s_last at various positions -- last_valid_idx calculation
    task automatic test_last_positions();
        $display("[TEST] test_last_positions: verify last_valid_idx");
        m_ready <= 1'b1;

        // s_last=1 with keep=0x01 -> last_valid_idx=0
        send_word(64'h00000000000000FF, 8'h01, 1'b1);
        drain_word();
        reset_dut();
        m_ready <= 1'b1;

        // s_last=1 with keep=0x80 -> last_valid_idx=7
        send_word(64'hFF00000000000000, 8'h80, 1'b1);
        drain_word();
        reset_dut();
        m_ready <= 1'b1;

        // s_last=1 with keep=0x18 -> last_valid_idx=4
        send_word(64'h0000FF00FF000000, 8'h18, 1'b1);
        drain_word();
    endtask

    // Backpressure during serialize -- m_ready toggling
    task automatic test_backpressure();
        $display("[TEST] test_backpressure: toggling m_ready");
        send_word(64'h0102030405060708, 8'hFF, 1'b1);

        // Toggle m_ready randomly during serialize
        repeat (30) begin
            @(posedge clk);
            m_ready <= $urandom_range(0, 1);
        end
        m_ready <= 1'b1;
        repeat (20) @(posedge clk);
    endtask

    // Back-to-back words -- continuous word stream
    task automatic test_back_to_back();
        $display("[TEST] test_back_to_back: 10 consecutive words");
        m_ready <= 1'b1;

        for (int w = 0; w < 10; w++) begin
            logic [63:0] data;
            data = {8'(w*8+7), 8'(w*8+6), 8'(w*8+5), 8'(w*8+4),
                    8'(w*8+3), 8'(w*8+2), 8'(w*8+1), 8'(w*8+0)};
            send_word(data, 8'hFF, (w == 9));
            drain_word();
        end
    endtask

    // Random stress -- 100 words with random keep/data
    task automatic test_random_stress();
        int num_words = 100;
        $display("[TEST] test_random_stress: %0d words", num_words);
        m_ready <= 1'b1;

        for (int w = 0; w < num_words; w++) begin
            logic [63:0] rand_data;
            logic [7:0]  rand_keep;
            rand_data = {$urandom(), $urandom()};
            rand_keep = $urandom();
            // Keep sink ready in this loop to avoid deadlock with blocking
            // send_word helper; backpressure is covered in test 6.
            m_ready <= 1'b1;
            send_word(rand_data, rand_keep, (w == num_words - 1));
            drain_word();
        end
        m_ready <= 1'b1;
        repeat (20) @(posedge clk);
    endtask

    //==========================================================================
    // Main Test Sequence
    //==========================================================================
    initial begin
        $display("============================================================");
        $display("  bnn_byte_filter Testbench (CRV, Gray-Box)");
        $display("  BUS_WIDTH=%0d", BUS_WIDTH);
        $display("============================================================");

        reset_dut();

        test_all_valid();
        reset_dut();

        test_no_valid();
        reset_dut();

        test_single_byte_patterns();
        reset_dut();

        test_alternating();
        reset_dut();

        test_last_positions();
        reset_dut();

        test_backpressure();
        reset_dut();

        test_back_to_back();
        reset_dut();

        test_random_stress();

        repeat (20) @(posedge clk);

        //======================================================================
        // Scoreboard Summary
        //======================================================================
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_byte_filter");
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
