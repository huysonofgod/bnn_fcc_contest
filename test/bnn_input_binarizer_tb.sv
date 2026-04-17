`timescale 1ns/10ps

module bnn_input_binarizer_tb;

    //==========================================================================
    // Parameters
    //==========================================================================
    parameter int BUS_WIDTH = 64;
    parameter int P_W       = 8;

    //==========================================================================
    // DUT Interface Signals
    //==========================================================================
    logic               clk = 0;
    logic               rst = 1;
    // Slave interface
    logic               s_valid;
    logic [BUS_WIDTH-1:0] s_data;
    logic [P_W-1:0]     s_keep;
    logic               s_last;
    logic               s_ready;
    // Master interface
    logic               m_valid;
    logic [P_W-1:0]     m_data;
    logic               m_last;
    logic               m_ready;

    //==========================================================================
    // Clock Generation (100 MHz)
    //==========================================================================
    always #5 clk = ~clk;

    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    bnn_input_binarizer #(
        .BUS_WIDTH (BUS_WIDTH),
        .P_W       (P_W)
    ) DUT (
        .clk     (clk),
        .rst     (rst),
        .s_valid (s_valid),
        .s_data  (s_data),
        .s_keep  (s_keep),
        .s_last  (s_last),
        .s_ready (s_ready),
        .m_valid (m_valid),
        .m_data  (m_data),
        .m_last  (m_last),
        .m_ready (m_ready)
    );

    //==========================================================================
    // SVA Properties
    //==========================================================================

    //--------------------------------------------------------------------------
    // AXI-Stream valid-hold on master interface -- once m_valid is
    // asserted, it must stay high until m_ready completes the handshake.
    //--------------------------------------------------------------------------
    property p_m_valid_hold;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> m_valid;
    endproperty
    assert property (p_m_valid_hold)
    else $error("[assertion] FAIL: m_valid dropped without m_ready handshake");

    //--------------------------------------------------------------------------
    // m_data stable during backpressure -- when m_valid && !m_ready,
    // the data output must not change.
    //--------------------------------------------------------------------------
    property p_m_data_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> $stable(m_data);
    endproperty
    assert property (p_m_data_stable)
    else $error("[assertion] FAIL: m_data changed during backpressure");

    //--------------------------------------------------------------------------
    // 1-cycle pipeline latency (skid buffer) -- when a slave handshake
    // occurs (s_valid & s_ready), m_valid must be high in the next cycle.
    //--------------------------------------------------------------------------
    property p_pipeline_latency;
        @(posedge clk) disable iff (rst)
        (s_valid && s_ready) |=> m_valid;
    endproperty
    assert property (p_pipeline_latency)
    else $error("[assertion] FAIL: m_valid not asserted 1 cycle after s handshake");

    //--------------------------------------------------------------------------
    // m_last follows s_last by 1 cycle -- when a beat with s_last=1
    // is accepted, the corresponding output beat must have m_last=1.
    //--------------------------------------------------------------------------
    property p_last_propagation;
        @(posedge clk) disable iff (rst)
        (s_valid && s_ready && s_last) |=> m_last;
    endproperty
    assert property (p_last_propagation)
    else $error("[assertion] FAIL: m_last did not follow s_last by 1 cycle");

    //--------------------------------------------------------------------------
    // m_last stable during backpressure
    // RATIONALE: Like m_data, m_last must hold until consumed.
    //--------------------------------------------------------------------------
    property p_m_last_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> $stable(m_last);
    endproperty
    assert property (p_m_last_stable)
    else $error("[assertion] FAIL: m_last changed during backpressure");

    //==========================================================================
    // Reference Model: Binarization
    // pixel >= 128 -> 1, else -> 0. Implementation: MSB of each byte & keep.
    //==========================================================================
    function automatic logic [P_W-1:0] ref_binarize(
        input logic [BUS_WIDTH-1:0] data,
        input logic [P_W-1:0]       keep
    );
        logic [P_W-1:0] result;
        for (int i = 0; i < P_W; i++)
            result[i] = data[i*8 + 7] & keep[i];
        return result;
    endfunction

    //==========================================================================
    // Covergroups
    //==========================================================================

    //--------------------------------------------------------------------------
    // COVERGROUP: Covers pixel threshold boundary (byte 0: <128, =128, >128),
    // s_keep patterns (all, none, partial), s_last, and backpressure states.
    //--------------------------------------------------------------------------
    covergroup cg_binarizer @(posedge clk iff (!rst));
        // Cover input pixel values at threshold boundary (first byte)
        cp_pixel_threshold: coverpoint s_data[7:0] iff (s_valid && s_ready) {
            bins below_threshold  = {[0:127]};
            bins at_threshold     = {128};
            bins above_threshold  = {[129:255]};
        }

        // Cover s_keep patterns
        cp_keep: coverpoint s_keep iff (s_valid && s_ready) {
            bins all_valid  = {8'hFF};
            bins none_valid = {8'h00};
            bins partial    = default;
        }

        // Cover s_last
        cp_last: coverpoint s_last iff (s_valid && s_ready) {
            bins not_last = {0};
            bins last_v   = {1};
        }

        // Cover backpressure on master
        cp_backpressure: coverpoint {m_valid, m_ready} {
            bins flow  = {2'b11};
            bins stall = {2'b10};
        }
    endgroup

    cg_binarizer cg_inst = new();

    // Scoreboard: Monitor + Expected Queue
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

    // Expected output queue for monitor-based checking
    typedef struct {
        logic [P_W-1:0] data;
        logic            last;
    } expected_t;
    expected_t exp_queue[$];

    // Push expected result when slave handshake occurs
    always @(posedge clk) begin
        if (!rst && s_valid && s_ready) begin
            expected_t e;
            e.data = ref_binarize(s_data, s_keep);
            e.last = s_last;
            exp_queue.push_back(e);
        end
    end

    // Monitor: compare on master handshake
    int mon_check_idx = 0;
    always @(posedge clk) begin
        if (!rst && m_valid && m_ready) begin
            if (exp_queue.size() > 0) begin
                expected_t e;
                e = exp_queue.pop_front();
                check($sformatf("monitor_%0d_data", mon_check_idx),
                      m_data === e.data,
                      $sformatf("exp=0x%02h got=0x%02h", e.data, m_data));
                check($sformatf("monitor_%0d_last", mon_check_idx),
                      m_last === e.last,
                      $sformatf("exp_last=%b got_last=%b", e.last, m_last));
                mon_check_idx++;
            end
        end
    end

    // Reset Task
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

    // Helper: Send one AXI-Stream beat
    task automatic send_beat(
        input logic [BUS_WIDTH-1:0] data,
        input logic [P_W-1:0]       keep,
        input logic                  last
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
    // Test Scenarios
    //==========================================================================

    // Threshold boundary -- pixels at 127, 128, 129
    task automatic test_threshold_boundary();
        logic [63:0] data;
        $display("[TEST] test_threshold_boundary");
        m_ready <= 1'b1;

        // All pixels at 127 (0x7F) -> all below threshold -> all 0
        data = {8{8'h7F}};
        send_beat(data, 8'hFF, 1'b0);
        @(posedge clk);

        // All pixels at 128 (0x80) -> all at threshold -> all 1
        data = {8{8'h80}};
        send_beat(data, 8'hFF, 1'b0);
        @(posedge clk);

        // All pixels at 129 (0x81) -> all above threshold -> all 1
        data = {8{8'h81}};
        send_beat(data, 8'hFF, 1'b1);
        repeat (5) @(posedge clk);
    endtask

    // All zeros -- 64-bit bus all pixels < 128
    task automatic test_all_zeros();
        $display("[TEST] test_all_zeros");
        m_ready <= 1'b1;
        send_beat(64'h0000000000000000, 8'hFF, 1'b1);
        repeat (5) @(posedge clk);
    endtask

    // All ones -- 64-bit bus all pixels >= 128
    task automatic test_all_ones();
        $display("[TEST] test_all_ones");
        m_ready <= 1'b1;
        send_beat(64'hFFFFFFFFFFFFFFFF, 8'hFF, 1'b1);
        repeat (5) @(posedge clk);
    endtask

    // Mixed patterns
    task automatic test_mixed_patterns();
        logic [63:0] data;
        $display("[TEST] test_mixed_patterns");
        m_ready <= 1'b1;

        // Alternating: 0x00, 0xFF, 0x00, 0xFF, ... -> expected: 8'b10101010
        data = {8'hFF, 8'h00, 8'hFF, 8'h00, 8'hFF, 8'h00, 8'hFF, 8'h00};
        send_beat(data, 8'hFF, 1'b0);

        // Reverse: 0xFF, 0x00, 0xFF, 0x00, ... -> expected: 8'b01010101
        data = {8'h00, 8'hFF, 8'h00, 8'hFF, 8'h00, 8'hFF, 8'h00, 8'hFF};
        send_beat(data, 8'hFF, 1'b1);
        repeat (5) @(posedge clk);
    endtask

    // s_keep patterns -- all valid, none valid, partial
    task automatic test_keep_patterns();
        $display("[TEST] test_keep_patterns");
        m_ready <= 1'b1;

        // All pixels 0xFF but keep = 0x00 -> all masked -> result = 0x00
        send_beat(64'hFFFFFFFFFFFFFFFF, 8'h00, 1'b0);

        // All pixels 0xFF, keep = 0xAA (alternating) -> only odd bytes valid
        send_beat(64'hFFFFFFFFFFFFFFFF, 8'hAA, 1'b0);

        // Single byte valid (keep=0x01), high pixel
        send_beat(64'h00000000000000FF, 8'h01, 1'b0);

        // Single byte valid at position 7 (keep=0x80)
        send_beat(64'hFF00000000000000, 8'h80, 1'b1);
        repeat (5) @(posedge clk);
    endtask

    // Backpressure -- m_ready toggling
    task automatic test_backpressure();
        $display("[TEST] test_backpressure: toggling m_ready");

        for (int i = 0; i < 20; i++) begin
            @(posedge clk);
            s_valid <= 1'b1;
            s_data  <= $urandom();
            s_keep  <= 8'hFF;
            s_last  <= (i == 19);
            m_ready <= $urandom_range(0, 1);
            if (s_ready) begin
                // Handshake happened
            end
        end
        s_valid <= 1'b0;
        m_ready <= 1'b1;
        repeat (10) @(posedge clk);
    endtask

    // s_last propagation -- verify 1-cycle delay
    task automatic test_last_propagation();
        $display("[TEST] test_last_propagation");
        m_ready <= 1'b1;

        // Send 3 normal beats then 1 with s_last
        for (int i = 0; i < 4; i++) begin
            send_beat($urandom(), 8'hFF, (i == 3));
        end
        repeat (5) @(posedge clk);
    endtask

    // Random stress -- 200 random beats
    task automatic test_random_stress();
        int num_beats = 200;
        $display("[TEST] test_random_stress: %0d beats", num_beats);
        m_ready <= 1'b1;

        for (int i = 0; i < num_beats; i++) begin
            logic [63:0] rand_data;
            logic [7:0]  rand_keep;
            rand_data = {$urandom(), $urandom()};
            rand_keep = $urandom();
            // Keep sink ready in this stress loop to avoid deadlock with the
            // blocking send_beat helper; backpressure is exercised in test 6.
            m_ready <= 1'b1;

            send_beat(rand_data, rand_keep, (i == num_beats - 1));
        end
        m_ready <= 1'b1;
        repeat (10) @(posedge clk);
    endtask

    //==========================================================================
    // Main Test Sequence
    //==========================================================================
    initial begin
        $display("============================================================");
        $display("  bnn_input_binarizer Testbench (CRV, Gray-Box)");
        $display("  BUS_WIDTH=%0d, P_W=%0d", BUS_WIDTH, P_W);
        $display("============================================================");

        reset_dut();

        test_threshold_boundary();
        reset_dut();

        test_all_zeros();
        reset_dut();

        test_all_ones();
        reset_dut();

        test_mixed_patterns();
        reset_dut();

        test_keep_patterns();
        reset_dut();

        test_backpressure();
        reset_dut();

        test_last_propagation();
        reset_dut();

        test_random_stress();

        repeat (20) @(posedge clk);

        //======================================================================
        // Scoreboard Summary
        //======================================================================
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_input_binarizer");
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
