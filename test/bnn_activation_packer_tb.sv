`timescale 1ns/10ps

module bnn_activation_packer_tb;

    //Parameters
    parameter int IN_BITS  = 8;
    parameter int OUT_BITS = 8;

    localparam int ACCUM_W   = IN_BITS + OUT_BITS;
    localparam int BIT_CNT_W = $clog2(ACCUM_W + 1);
    localparam int CNT_W     = $clog2(IN_BITS + 1);
    localparam int RANDOM_GROUPS = 10000;

    //DUT Interface Signals
    logic               clk = 0;
    logic               rst = 1;
    logic               s_valid;
    logic               s_ready;
    logic [IN_BITS-1:0] s_data;
    logic [CNT_W-1:0]   s_count;
    logic               s_last_group;
    logic               m_valid;
    logic               m_ready;
    logic [OUT_BITS-1:0] m_data;
    logic               m_last;

    //Clock Generation (100 MHz)
    always #5 clk = ~clk;

    //DUT Instantiation
    bnn_activation_packer #(
        .IN_BITS  (IN_BITS),
        .OUT_BITS (OUT_BITS)
    ) DUT (
        .clk          (clk),
        .rst          (rst),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_data       (s_data),
        .s_count      (s_count),
        .s_last_group (s_last_group),
        .m_valid      (m_valid),
        .m_ready      (m_ready),
        .m_data       (m_data),
        .m_last       (m_last)
    );

    //SVA Properties (Gray Box)

    //AXI-Stream valid-hold on master interface -- once m_valid asserts,
    //it stays high until m_ready completes the handshake.
    //RATIONALE: AXI4-Stream protocol compliance for downstream consumers.
    property p_m_valid_hold;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> m_valid;
    endproperty
    assert property (p_m_valid_hold)
    else $error("[assertion] FAIL: m_valid dropped without m_ready handshake");

    //m_data stable during m_valid && !m_ready -- data must not change
    //while the handshake is stalled.
    //RATIONALE: AXI4-Stream data stability requirement.
    property p_m_data_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> $stable(m_data);
    endproperty
    assert property (p_m_data_stable)
    else $error("[assertion] FAIL: m_data changed during backpressure");

    //bits_in_r_q never exceeds ACCUM_W -- the accumulator bit counter
    //must stay within the defined width to prevent data corruption.
    //RATIONALE: Accumulator overflow would cause bits to be lost or aliased.
    property p_no_accumulator_overflow;
        @(posedge clk) disable iff (rst)
        DUT.u_dp.bits_in_r_q <= BIT_CNT_W'(ACCUM_W);
    endproperty
    assert property (p_no_accumulator_overflow)
    else $error("[assertion] FAIL: bits_in_r_q=%0d exceeded ACCUM_W=%0d",
                DUT.u_dp.bits_in_r_q, ACCUM_W);

    //m_last stable during backpressure
    //RATIONALE: Like m_data, m_last must hold until consumed.
    property p_m_last_stable;
        @(posedge clk) disable iff (rst)
        (m_valid && !m_ready) |=> $stable(m_last);
    endproperty
    assert property (p_m_last_stable)
    else $error("[assertion] FAIL: m_last changed during backpressure");

    //s_ready deasserts during EMIT and FLUSH states -- packer cannot
    //accept new input while emitting output.
    //RATIONALE: Prevents accumulator corruption from overlapping merge/drain.
    property p_s_ready_deassert_emit;
        @(posedge clk) disable iff (rst)
        (DUT.u_fsm.state_r == DUT.u_fsm.EMIT ||
         DUT.u_fsm.state_r == DUT.u_fsm.FLUSH) |-> !s_ready;
    endproperty
    assert property (p_s_ready_deassert_emit)
    else $error("[assertion] FAIL: s_ready asserted during EMIT/FLUSH state");

    //Covergroups (Gray Box)

    //COVERGROUP: Bit accumulation levels, s_count values, s_last_group,
    //and emit backpressure events.
    covergroup cg_packer @(posedge clk iff (!rst));
        //Cover bits_in accumulator levels
        cp_bits_in: coverpoint DUT.u_dp.bits_in_r_q {
            bins empty    = {0};
            bins partial  = {[1:OUT_BITS-1]};
            //By construction the packer emits once OUT_BITS are available,
            //so ACCUM_W itself is not a reachable steady-state count.
            bins can_emit = {[OUT_BITS:ACCUM_W-1]};
        }

        //Cover s_count values
        cp_s_count: coverpoint s_count iff (s_valid && s_ready) {
            bins full_count = {IN_BITS};
            bins partial    = {[1:IN_BITS-1]};
        }

        //Cover s_last_group
        cp_last_group: coverpoint s_last_group iff (s_valid && s_ready) {
            bins normal = {0};
            bins final_g = {1};
        }

        //Cover emit backpressure
        cp_emit_stall: coverpoint {m_valid, m_ready} {
            bins stall = {2'b10};
            bins flow  = {2'b11};
        }

        //Cover FSM states
        cp_state: coverpoint DUT.u_fsm.state_r {
            bins idle    = {DUT.u_fsm.IDLE};
            bins accept  = {DUT.u_fsm.ACCEPT};
            bins emit    = {DUT.u_fsm.EMIT};
            bins flush_s = {DUT.u_fsm.FLUSH};
            bins done_s  = {DUT.u_fsm.DONE};
        }
    endgroup

    cg_packer cg_inst = new();

    //Reference Model: Bit-accurate packing
    //Collect all input bits, then extract OUT_BITS words from the stream.
    //A queue avoids artificial overflow in long stress runs.
    logic                ref_bit_stream[$];
    logic [OUT_BITS-1:0] ref_output_queue[$];
    logic                ref_last_queue[$];

    //Call after all inputs sent to build expected output queue
    task automatic build_ref_output(
        input logic [IN_BITS-1:0] data_q[$],
        input int                 count_q[$],
        input logic               last_group_q[$]
    );
        int bit_pos;
        int total_bits;
        ref_bit_stream = {};
        bit_pos = 0;

        //Accumulate all input bits
        for (int g = 0; g < data_q.size(); g++) begin
            for (int b = 0; b < count_q[g]; b++)
                ref_bit_stream.push_back(data_q[g][b]);
        end
        total_bits = ref_bit_stream.size();

        //Extract OUT_BITS words
        ref_output_queue = {};
        ref_last_queue   = {};
        bit_pos = 0;
        while (bit_pos + OUT_BITS <= total_bits) begin
            logic [OUT_BITS-1:0] word;
            for (int b = 0; b < OUT_BITS; b++)
                word[b] = ref_bit_stream[bit_pos + b];
            ref_output_queue.push_back(word);
            ref_last_queue.push_back(1'b0);
            bit_pos += OUT_BITS;
        end

        //Handle residual bits (flush with zero-padding)
        if (bit_pos < total_bits) begin
            logic [OUT_BITS-1:0] word;
            word = '0;
            for (int b = 0; b < (total_bits - bit_pos); b++)
                word[b] = ref_bit_stream[bit_pos + b];
            ref_output_queue.push_back(word);
            ref_last_queue.push_back(1'b1);
        end else if (ref_output_queue.size() > 0) begin
            //Mark last full word as m_last
            ref_last_queue[ref_last_queue.size()-1] = 1'b1;
        end
    endtask

    //Scoreboard
    int pass_count_sb = 0;
    int fail_count_sb = 0;
    string fail_log[$];

    function automatic void check(string test_name, logic cond, string msg = "");
        if (cond) begin
            pass_count_sb++;
        end else begin
            fail_count_sb++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", test_name, msg));
            $error("[SB] %s: %s", test_name, msg);
        end
    endfunction

    //Monitor: collect actual output
    logic [OUT_BITS-1:0] actual_data_q[$];
    logic                actual_last_q[$];

    always @(posedge clk) begin
        if (!rst && m_valid && m_ready) begin
            actual_data_q.push_back(m_data);
            actual_last_q.push_back(m_last);
        end
    end

    //Compare actual vs expected
    task automatic compare_output(string test_name);
        int min_size;
        check($sformatf("%s_output_count", test_name),
              actual_data_q.size() == ref_output_queue.size(),
              $sformatf("expected %0d outputs, got %0d",
                        ref_output_queue.size(), actual_data_q.size()));

        min_size = (actual_data_q.size() < ref_output_queue.size()) ?
                    actual_data_q.size() : ref_output_queue.size();

        for (int i = 0; i < min_size; i++) begin
            check($sformatf("%s_data_%0d", test_name, i),
                  actual_data_q[i] === ref_output_queue[i],
                  $sformatf("exp=0x%02h got=0x%02h", ref_output_queue[i], actual_data_q[i]));
            check($sformatf("%s_last_%0d", test_name, i),
                  actual_last_q[i] === ref_last_queue[i],
                  $sformatf("exp_last=%b got_last=%b", ref_last_queue[i], actual_last_q[i]));
        end

        //Clear for next test
        actual_data_q = {};
        actual_last_q = {};
    endtask

    //Reset Task
    task automatic reset_dut();
        rst          <= 1'b1;
        s_valid      <= 1'b0;
        s_data       <= '0;
        s_count      <= '0;
        s_last_group <= 1'b0;
        m_ready      <= 1'b0;
        actual_data_q = {};
        actual_last_q = {};
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);
    endtask

    //Helper: Send a sequence of groups through the packer
    task automatic send_groups(
        input logic [IN_BITS-1:0] data_q[$],
        input int                 count_q[$],
        input logic               last_group_q[$],
        input real                ready_prob
    );
        int timeout;
        for (int g = 0; g < data_q.size(); g++) begin
            //Wait for ACCEPT state
            timeout = 0;
            while (!s_ready && timeout < 5000) begin
                @(posedge clk);
                m_ready <= ($urandom_range(0, 99) < int'(ready_prob * 100));
                timeout++;
            end

            @(posedge clk);
            s_valid      <= 1'b1;
            s_data       <= data_q[g];
            s_count      <= CNT_W'(count_q[g]);
            s_last_group <= last_group_q[g];
            m_ready      <= ($urandom_range(0, 99) < int'(ready_prob * 100));

            @(posedge clk);
            while (!s_ready) begin
                m_ready <= ($urandom_range(0, 99) < int'(ready_prob * 100));
                @(posedge clk);
            end
            s_valid      <= 1'b0;
            s_last_group <= 1'b0;
        end
        //Drain remaining outputs. Do not break early on ACCEPT/IDLE;
        //the final flush/result can appear a cycle later.
        repeat (64) begin
            @(posedge clk);
            m_ready <= 1'b1;
        end
        repeat (5) @(posedge clk);
        m_ready <= 1'b0;
    endtask

    //Test Scenarios

    // Exact alignment (IN_BITS == OUT_BITS, full count)
    task automatic test_exact_alignment();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_exact_alignment: 1:1 packing");

        data_q = {8'hA5, 8'h3C, 8'hFF};
        count_q = {IN_BITS, IN_BITS, IN_BITS};
        last_group_q = {1'b0, 1'b0, 1'b1};

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 1.0);
        compare_output("exact_align");
    endtask

    // Partial final pass (s_count < IN_BITS with s_last_group)
    task automatic test_partial_final();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_partial_final: s_count=5 on last group");

        data_q = {8'hFF, 8'hAA};
        count_q = {IN_BITS, 5};  // second group only 5 valid bits
        last_group_q = {1'b0, 1'b1};

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 1.0);
        compare_output("partial_final");
    endtask

    // Flush with zero residual
    task automatic test_flush_zero_residual();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_flush_zero_residual: exact multiple of OUT_BITS");

        //2 groups of 8 bits = 16 bits total = 2 output words, no residual
        data_q = {8'hAB, 8'hCD};
        count_q = {IN_BITS, IN_BITS};
        last_group_q = {1'b0, 1'b1};

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 1.0);
        compare_output("flush_zero_residual");
    endtask

    // Backpressure during emit
    task automatic test_backpressure_emit();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_backpressure_emit: m_ready toggling");

        data_q = {8'hFF, 8'h00, 8'hAA, 8'h55};
        count_q = {IN_BITS, IN_BITS, IN_BITS, IN_BITS};
        last_group_q = {1'b0, 1'b0, 1'b0, 1'b1};

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 0.5);
        compare_output("bp_emit");
    endtask

    // Single group with s_last_group
    task automatic test_single_group();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_single_group");

        data_q = {8'hCA};
        count_q = {IN_BITS};
        last_group_q = {1'b1};

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 1.0);
        compare_output("single_group");
    endtask

    // Count sweep closure -- walk partial accumulation states
    task automatic test_count_sweep();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        $display("[TEST] test_count_sweep: counts 1..IN_BITS");

        data_q = {};
        count_q = {};
        last_group_q = {};

        for (int c = 1; c <= IN_BITS; c++) begin
            data_q.push_back({IN_BITS{1'b1}} >> (IN_BITS - c));
            count_q.push_back(c);
            last_group_q.push_back((c == IN_BITS));
        end

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 1.0);
        compare_output("count_sweep");
    endtask

    // Many groups (stress)
    task automatic test_stress();
        logic [IN_BITS-1:0] data_q[$];
        int count_q[$];
        logic last_group_q[$];
        int num_groups = RANDOM_GROUPS;
        $display("[TEST] test_stress: %0d groups, random backpressure", num_groups);

        data_q = {};
        count_q = {};
        last_group_q = {};
        for (int g = 0; g < num_groups; g++) begin
            data_q.push_back($urandom());
            count_q.push_back($urandom_range(1, IN_BITS));
            last_group_q.push_back((g == num_groups - 1));
        end

        build_ref_output(data_q, count_q, last_group_q);
        send_groups(data_q, count_q, last_group_q, 0.7);
        compare_output("stress");
    endtask

    // Multiple images back-to-back
    task automatic test_multi_image();
        $display("[TEST] test_multi_image: 5 images back-to-back");

        for (int img = 0; img < 5; img++) begin
            logic [IN_BITS-1:0] data_q[$];
            int count_q[$];
            logic last_group_q[$];
            int ngroups = $urandom_range(2, 8);

            data_q = {};
            count_q = {};
            last_group_q = {};
            for (int g = 0; g < ngroups; g++) begin
                data_q.push_back($urandom());
                count_q.push_back($urandom_range(1, IN_BITS));
                last_group_q.push_back((g == ngroups - 1));
            end

            build_ref_output(data_q, count_q, last_group_q);
            send_groups(data_q, count_q, last_group_q, 0.8);
            compare_output($sformatf("multi_img_%0d", img));

            //Wait for IDLE
            repeat (10) @(posedge clk);
        end
    endtask

    //Main Test Sequence
    initial begin
        $display("============================================================");
        $display("  bnn_activation_packer Testbench (CRV+, Gray-Box)");
        $display("  IN_BITS=%0d, OUT_BITS=%0d, ACCUM_W=%0d",
                 IN_BITS, OUT_BITS, ACCUM_W);
        $display("============================================================");

        reset_dut();

        test_exact_alignment();
        reset_dut();

        test_partial_final();
        reset_dut();

        test_flush_zero_residual();
        reset_dut();

        test_single_group();
        reset_dut();

        test_backpressure_emit();
        reset_dut();

        test_count_sweep();
        reset_dut();

        test_stress();
        reset_dut();

        test_multi_image();

        repeat (20) @(posedge clk);

        //Scoreboard Summary
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_activation_packer");
        $display("============================================================");
        $display("  Total checks : %0d", pass_count_sb + fail_count_sb);
        $display("  PASS         : %0d", pass_count_sb);
        $display("  FAIL         : %0d", fail_count_sb);
        if (fail_count_sb > 0) begin
            $display("  --- Failure Details ---");
            foreach (fail_log[i])
                $display("    %s", fail_log[i]);
        end
        $display("  Coverage     : %.1f%%", cg_inst.get_coverage());
        $display("============================================================");
        if (fail_count_sb == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count_sb);
        $display("============================================================");

        $finish;
    end

endmodule
