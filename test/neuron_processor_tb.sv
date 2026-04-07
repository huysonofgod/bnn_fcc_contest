`timescale 1ns / 10ps


module neuron_processor_tb;

    localparam int P_W = 8;
    localparam int MAX_NEURON_INPUTS = 784;
    localparam int ACC_W = $clog2(MAX_NEURON_INPUTS + 1);

    localparam logic [1:0] FSM_IDLE = 2'd0;
    localparam logic [1:0] FSM_COMPUTE = 2'd1;
    localparam logic [1:0] FSM_RESET = 2'd2;

    typedef struct {
        string name;
        int    id;
        int    expected_popcount;
        logic  expected_act;
        int    neuron_size_bits;
        logic  expected_mode_olm;
    } exp_pkt_t;

    typedef struct {
        int   observed_popcount;
        logic observed_act;
        time  sample_time;
    } act_pkt_t;

    mailbox                     exp_mb;
    mailbox                     act_mb;

    logic                       clk;
    logic                       rst;

    logic   [          P_W-1:0] x_in;
    logic   [          P_W-1:0] w_in;
    logic   [        ACC_W-1:0] threshold_in;
    logic                       valid_in;
    logic                       last;
    logic                       mode_output_layer_sel;

    logic   [        ACC_W-1:0] popcount_out;
    logic                       act_out;
    logic                       valid_out;

    logic   [          P_W-1:0] dbg_xnor_bits;
    logic   [$clog2(P_W+1)-1:0] dbg_beat_popcount;
    logic   [        ACC_W-1:0] dbg_accum;
    logic                       dbg_neuron_done;
    logic                       dbg_accept_beat;

    bit                         in_flight;
    int                         compare_error_count;
    int                         assertion_error_count;

    // int                        expected_sum;
    // bit                        expected_act;
    // bit                        pending_check;
    // bit    [        ACC_W-1:0] pending_sum;
    // bit                        pending_act;
    // bit                        output_initialized;
    // string                     pending_case_name;

    int                         total_checks;
    int                         failed_checks;

    int                         unexpected_assert_fails;

    string passed_tests[$];
    string failed_tests[$];


    neuron_processor #(
        .P_W              (P_W),
        .MAX_NEURON_INPUTS(MAX_NEURON_INPUTS),
        .ACC_W            (ACC_W)
    ) dut (
        .clk                  (clk),
        .rst                  (rst),
        .x_in                 (x_in),
        .w_in                 (w_in),
        .threshold_in         (threshold_in),
        .valid_in             (valid_in),
        .last                 (last),
        .mode_output_layer_sel(mode_output_layer_sel),
        .popcount_out         (popcount_out),
        .act_out              (act_out),
        .valid_out            (valid_out),
        .dbg_xnor_bits        (dbg_xnor_bits),
        .dbg_beat_popcount    (dbg_beat_popcount),
        .dbg_accum            (dbg_accum),
        .dbg_neuron_done      (dbg_neuron_done),
        .dbg_accept_beat      (dbg_accept_beat)
    );

    // -----------------------
    // clk generation
    // -----------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // -----------------------
    // Assertion rules
    // -----------------------

    //  valid_out should pulse high for exactly one cycle when a neuron output is ready
    property p_valid_out_pulse;
        @(posedge clk) disable iff (rst) valid_out |=> !valid_out;
    endproperty

    // valid_out must be low while reset is asserted.
    property p_no_valid_out_in_rst;
        @(posedge clk) rst |-> !valid_out;
    endproperty

    // When mode_output_layer_sel is high, act_out should be 0 regardless of the accumulated sum and threshold
    property p_olm_forces_act0;
        @(posedge clk) disable iff (rst) (valid_out && mode_output_layer_sel) |-> (act_out === 1'b0);
    endproperty

    /////////////////////////////////////////////////////////
    // Reported popcount must remain within legal neuron-input range.
    property p_pc_in_range;
        @(posedge clk) disable iff (rst) valid_out |-> (popcount_out <= MAX_NEURON_INPUTS);
    endproperty

    // When RESET state drives acc clear controls, accumulator clears next cycle.
    property p_acc_clears;
        @(posedge clk) disable iff (rst)
            (dut.u_fsm.acc_we && dut.u_fsm.acc_sel) |=> (dut.u_dp.acc_r_q === '0);
    endproperty

    // During valid gaps (acc_we=0), accumulator value must hold.
    property p_acc_frozen;
        @(posedge clk) disable iff (rst) 
            (!dut.u_fsm.acc_we && !$isunknown(dut.u_dp.acc_r_q)) |=> (dut.u_dp.acc_r_q == $past(dut.u_dp.acc_r_q));
    endproperty

    // SVA-7: valid_out is only legal while FSM is in RESET state.
    property p_valid_out_only_in_reset;
        @(posedge clk) disable iff (rst) valid_out |-> (dut.u_fsm.state_r == FSM_RESET);
    endproperty

    // SVA-8: RESET state must transition back to IDLE on the next cycle.
    property p_reset_exits_to_idle;
        @(posedge clk) disable iff (rst) 
            (dut.u_fsm.state_r == FSM_RESET) |=> (dut.u_fsm.state_r == FSM_IDLE);
    endproperty

    // A legal last beat must produce valid_out on the next cycle.
    property p_valid_out_follows_last;
        @(posedge clk) disable iff (rst) (valid_in && last) |=> valid_out;
    endproperty

    // act_out must never be X when valid_out is asserted.
    property p_act_not_x;
        @(posedge clk) disable iff (rst) valid_out |-> !$isunknown(act_out);
    endproperty

    // popcount_out must never be X when valid_out is asserted.
    property p_pc_not_x;
        @(posedge clk) disable iff (rst) valid_out |-> !$isunknown(popcount_out);
    endproperty

    // act_out remain stable right after valid_out deassert
    property p_act_stable_after_valid_out;
        @(posedge clk) disable iff (rst) $fell(valid_out) |-> $stable(act_out);
    endproperty

    // threshold must not change on the final beat (contract on last beat).
    property p_threshold_stable_on_last;
        @(posedge clk) disable iff (rst)
            (valid_in && last && $past(valid_in)) |-> $stable(threshold_in);
    endproperty
    

    A_OLM_FORCES_ACT0 :
    assert property (p_olm_forces_act0)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_OLM_FORCES_ACT0 check='OLM forces act_out=0 when valid_out=1' scope=%m time=%0t", $time);
    end

    A_P_VALID_OUT_PULSE :
    assert property (p_valid_out_pulse)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_VALID_OUT_PULSE valid_out pulse is not one cycle at t=%0t", $time);
    end

    A_P_PC_IN_RANGE :
    assert property (p_pc_in_range)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_PC_IN_RANGE popcount_out=%0d exceeds MAX_NEURON_INPUTS at t=%0t",popcount_out, $time);
    end

    A_P_ACC_CLEARS :
    assert property (p_acc_clears)
    else begin
        unexpected_assert_fails++;
        $error( "[FAILED][SVA] A_P_ACC_CLEARS Accumulator did not clear on acc_we=1 and acc_sel=1 at t=%0t", $time);
    end

    A_P_ACC_FROZEN :
    assert property (p_acc_frozen)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_ACC_FROZEN Accumulator changed value during valid_in gap at t=%0t", $time);
    end

    A_P_VALID_OUT_ONLY_IN_RESET :
    assert property (p_valid_out_only_in_reset)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_VALID_OUT_ONLY_IN_RESET valid_out was asserted outside of RESET state at t=%0t", $time);
    end

    A_P_RESET_EXITS_TO_IDLE :
    assert property (p_reset_exits_to_idle)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_RESET_EXITS_TO_IDLE FSM did not exit RESET state to IDLE on the next cycle at t=%0t", $time);
    end

    A_P_VALID_OUT_FOLLOWS_LAST :
    assert property (p_valid_out_follows_last)
    else begin
        unexpected_assert_fails++;
        $error( "[FAILED][SVA] A_P_VALID_OUT_FOLLOWS_LAST valid_out did not follow a valid_in with last beat on the next cycle at t=%0t", $time);
    end

    A_P_ACT_NOT_X :
    assert property (p_act_not_x)
    else begin
        unexpected_assert_fails++;    
        $error("[FAILED][SVA] A_P_ACT_NOT_X act_out is X when valid_out is 1 at t=%0t", $time);
    end

    A_P_PC_NOT_X :
    assert property (p_pc_not_x)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_PC_NOT_X popcount_out is X when valid_out is 1 at t=%0t", $time);
    end
    
    A_P_ACT_STABLE_AFTER_VALID_OUT :
    assert property (p_act_stable_after_valid_out)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_P_ACT_STABLE_AFTER_VALID_OUT failed at t=%0t", $time);
    end

    A_THR_STABLE_ON_LAST: 
    assert property (p_threshold_stable_on_last)
    else begin
        unexpected_assert_fails++;
        $error("[FAILED][SVA] A_THR_STABLE_ON_LAST check='threshold stable on final beat' scope=%m time=%0t", $time);
    end
    // ------------------------
    //Monitors task block
    // ------------------------
    task automatic monitor_main();
        act_pkt_t act_pkt;
        forever begin
            @(posedge clk);
            if (valid_out) begin
                act_pkt.observed_popcount = popcount_out;
                act_pkt.observed_act      = act_out;
                act_pkt.sample_time       = $time;
                act_mb.put(act_pkt);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Scoreboard component: compares expected packet vs observed packet
    // -------------------------------------------------------------------------
    task automatic scoreboard_main();
        exp_pkt_t exp_pkt;
        act_pkt_t act_pkt;
        forever begin
            exp_mb.get(exp_pkt);
            act_mb.get(act_pkt);

            total_checks++;
            if ((act_pkt.observed_popcount !== exp_pkt.expected_popcount) ||
                (act_pkt.observed_act      !== exp_pkt.expected_act)) begin
                failed_checks++;
                failed_tests.push_back($sformatf("[TEST %02d] %s", exp_pkt.id, exp_pkt.name));
                $error("[FAILED][TEST %02d] %s check='scoreboard compare popcount/act' exp(pc=%0d,act=%0b) got(pc=%0d,act=%0b) scope=%m time=%0t",
                       exp_pkt.id, exp_pkt.name, exp_pkt.expected_popcount, exp_pkt.expected_act,
                       act_pkt.observed_popcount, act_pkt.observed_act, act_pkt.sample_time);
            end else begin
                passed_tests.push_back($sformatf("[TEST %02d] %s", exp_pkt.id, exp_pkt.name));
                $display("PASS %s : pc=%0d act=%0b", exp_pkt.name, act_pkt.observed_popcount,
                         act_pkt.observed_act);
            end
        end
    endtask

    // ------------------------
    // Helper reference modeling function
    // ------------------------

    // This function calculates the popcount of matching bits between two bit arrays (x_bits and w_bits) up to n_bits.
    function automatic int calc_popcount_match(input bit x_bits[0:MAX_NEURON_INPUTS-1],
                                               input bit w_bits[0:MAX_NEURON_INPUTS-1], 
                                               input int n_bits);
        int k;
        int cnt;
        begin
            cnt = 0;
            for (k = 0; k < n_bits; k++) begin
                if (x_bits[k] == w_bits[k]) cnt++;
            end
            return cnt;
        end
    endfunction

    // This function packs a segment of bits from the input arrays into a word of width MAIN_P_W, applying padding rules if the segment exceeds n_bits.
    function automatic logic [P_W-1:0] pack_main_beat(input bit bits[0:MAX_NEURON_INPUTS-1],
                                                      input int n_bits,
                                                      input int beat_idx,
                                                      input bit is_w_bus);
    int b;
    int abs_idx;
    logic [P_W-1:0] word;
    begin
        word = '0;
        for (b = 0; b < P_W; b++) begin
            abs_idx = beat_idx * P_W + b;
            if (abs_idx < n_bits) begin
                word[b] = bits[abs_idx];
            end else begin
                // Padding rule from handoff:
                // x pad bit = 0, w pad bit = 1 so XNOR pad contributes 0.
                word[b] = (is_w_bus) ? 1'b1 : 1'b0;
            end
        end
        return word;
    end
    endfunction


    task automatic clear_vectors(
        output bit x_bits [0:MAX_NEURON_INPUTS-1],
        output bit w_bits [0:MAX_NEURON_INPUTS-1]
    );
        int i;
        begin
            for (i = 0; i < MAX_NEURON_INPUTS; i++) begin
                x_bits[i] = 1'b0;
                w_bits[i] = 1'b0;
            end
        end
    endtask


    
    // ------------------------------
    // Driver component for main DUT
    // ------------------------------
    task automatic drive_main_neuron(input int test_id,
                                     input string test_name,
                                     input bit x_bits[0:MAX_NEURON_INPUTS-1],
                                     input bit w_bits[0:MAX_NEURON_INPUTS-1],
                                     input int n_bits,
                                     input logic [ACC_W-1:0] threshold,
                                     input bit mode_olm);
        int beats;
        int beat;
        exp_pkt_t exp_pkt;
        int expected_pc;
        logic expected_act;

        beats                     = (n_bits + P_W - 1) / P_W;
        expected_pc               = calc_popcount_match(x_bits, w_bits, n_bits);
        expected_act              = mode_olm ? 1'b0 : (expected_pc >= threshold);
        exp_pkt.id                = test_id;
        exp_pkt.name              = test_name;
        exp_pkt.expected_popcount = expected_pc;
        exp_pkt.expected_act      = expected_act;
        exp_pkt.neuron_size_bits  = n_bits;
        exp_pkt.expected_mode_olm = mode_olm;

        // Push expected before driving so scoreboard can pair with monitor output.
        exp_mb.put(exp_pkt);

        // Drive beats only at posedge with nonblocking assignments.
        for (beat = 0; beat < beats; beat++) begin
            @(posedge clk);
            valid_in              <= 1'b1;
            last                  <= (beat == beats - 1);
            x_in                  <= pack_main_beat(x_bits, n_bits, beat, 1'b0);
            w_in                  <= pack_main_beat(w_bits, n_bits, beat, 1'b1);
            threshold_in          <= threshold;
            mode_output_layer_sel <= mode_olm;
        end

        // Return interface to idle cleanly on the next edge.
        @(posedge clk);
        valid_in <= 1'b0;
        last     <= 1'b0;
        // Wait for DUT to finish processing and return to idle before exiting task to avoid inter-test interference.
        wait (valid_out == 1'b0); 
        @(posedge clk);
    endtask

    // Reset helper
    task automatic apply_reset(input int cycles);
        int c;
        begin
            @(posedge clk);
            rst <= 1'b1;
            valid_in <= 1'b0;
            last <= 1'b0;
            x_in <= '0;
            w_in <= '0;
            threshold_in <= '0;
            mode_output_layer_sel <= 1'b0;

            for (c = 0; c < cycles - 1; c++) begin
                @(posedge clk);
                rst <= 1'b1;
            end

            @(posedge clk);
            rst <= 1'b0;
        end
    endtask

    // This test checks that changing the threshold mid-neuron does not affect the final output,
    // as long as the threshold is stable on the last beat.
    // This verifies that the FSM correctly register the threshold on the first beat and uses the registered value for all
    // beats of the neuron, rather than allowing the threshold to change mid-computation which would be a bug.
    task automatic drive_threshold_contract_test();
        exp_pkt_t exp_pkt;
        int beat;
        begin
            // Expected: popcount=32, act=0 because threshold on LAST beat is 40.
            exp_pkt.name              = "threshold contract: mid-neuron change, stable on last beat";
            exp_pkt.id                = 16;
            exp_pkt.expected_popcount = 32;
            exp_pkt.expected_act      = 1'b0;
            exp_mb.put(exp_pkt);

            for (beat = 0; beat < 4; beat++) begin
                @(posedge clk);
                valid_in <= 1'b1;
                last <= (beat == 3);
                x_in <= 8'hFF;
                w_in <= 8'hFF;
                mode_output_layer_sel <= 1'b0;

                // Mid-neuron threshold change, then stabilize before last beat.
                // This keeps Section 1 functional-only while still exercising
                // non-last threshold movement.
                if (beat == 1)      threshold_in <= 1;
                else if (beat == 2) threshold_in <= 40;
                else                threshold_in <= 40;
            end

            @(posedge clk);
            valid_in <= 1'b0;
            last <= 1'b0;

            wait (valid_out === 1'b1);
            @(posedge clk);
        end
    endtask

    task automatic run_directed_main_suite();
        bit x_bits[0:MAX_NEURON_INPUTS-1];
        bit w_bits[0:MAX_NEURON_INPUTS-1];
        int i;
        logic act_at_valid;
        logic act_after_valid;

        // Always initialize vectors before each test so old values do not leak.
        // for (i = 0; i < MAX_NEURON_INPUTS; i++) begin
        //     x_bits[i] = 1'b0;
        //     w_bits[i] = 1'b0;
        // end
        clear_vectors(x_bits, w_bits);
        x_bits[4] = 1'b1; x_bits[5] = 1'b1; x_bits[6] = 1'b1; x_bits[7] = 1'b1;
        w_bits[4] = 1'b1; w_bits[5] = 1'b1; w_bits[6] = 1'b1; w_bits[7] = 1'b1;
        drive_main_neuron(1, "thr boundary low: pc=8 thr=3 expect fire", x_bits, w_bits, 8, 3, 1'b0);
        drive_main_neuron(2, "thr boundary equal: pc=8 thr=4 expect fire", x_bits, w_bits, 8, 4, 1'b0);
        drive_main_neuron(3, "thr boundary high: pc=8 thr=5 expect fire", x_bits, w_bits, 8, 5, 1'b0);
        
        // [1] n=1 (single-bit degenerate neuron)
        x_bits[0] = 1'b1;
        w_bits[0] = 1'b1;  // expected popcount=1
        drive_main_neuron(4, "Neuron size n=1. 1 beat (P_W=8). Single bit. ", x_bits,
                          w_bits, 1, 1, 1'b0);

        // [2] n=7 (padding-sensitive)
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 7; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end  // expected popcount=7
        drive_main_neuron(5,
            "Neuron size n=7. 1 beat with 1 padded bit (P_W=8). Only 7 bits are real x[7]=0, w[7]=1, padded bit contributes 0 to popcount.",
            x_bits, w_bits, 7, 7, 1'b0);

        // [3] n=8 (full beat, no padding)
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 8; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end  // expected popcount=8
        drive_main_neuron(6, "n8_one_full_beat", x_bits, w_bits, 8, 8, 1'b0);

        // [4] n=13 (2 beats, last beat partially real bits)
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 13; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end  // expected popcount=13
        drive_main_neuron(7, "Neuron size n=13. 2 beats (P_W=8). Beat 0 is full (8 real bits). Beat 1 \
        has 5 real bits and 3 padded bits (x[7:5]=0, w[7:5]=1) ", x_bits, w_bits, 13, 13, 1'b0);

        // [5] n=16
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 16; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end  // expected popcount=16
        drive_main_neuron(8, "Neuron size n=16. 2 full beats (P_W=8). No padding. Exact multiple.", x_bits,
                          w_bits, 16, 16, 1'b0);
    
        // [6] n=32
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 32; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end  // expected popcount=32
        drive_main_neuron(9, "Neuron size n=32. 4 full beats (P_W=8). Medium accumulation.", x_bits, w_bits, 32,
                          20, 1'b0);

        // [7] n=256 with explicit hand-computed expected=128
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 128; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end
        for (i = 128; i < 256; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b0;
        end
        drive_main_neuron(10,"Neuron size n=256. 32 full beats (P_W=8). Layer 1/2 full topology.", x_bits, w_bits, 256, 128, 1'b0);

        // [8] n=784 with explicit hand-computed expected=393
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 393; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end
        for (i = 393; i < 784; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b0;
        end
        drive_main_neuron(11,"Neuron size n=784. 98 full beats (P_W=8). Layer 0 full topology", x_bits, w_bits, 784, 393, 1'b0);

        // [9] n=7 strict padding neutrality check (thr=8, expected act=0 only if pc=7)
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < MAX_NEURON_INPUTS; i++) begin
            x_bits[i] = 1'b0;
            w_bits[i] = 1'b0;
        end
        for (i = 0; i < 7; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end
        drive_main_neuron(12,
            "Neuron size n=7, thr=8. 1 beat with 1 padded bit (P_W=8). Only 7 bits are real x[7]=0, w[7]=1, padded bit contributes 0 to popcount.",
            x_bits, w_bits, 7, 8, 1'b0);

        // [10] n=13 strict padding neutrality check (thr=14, expected act=0 only if pc=13)
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < MAX_NEURON_INPUTS; i++) begin
            x_bits[i] = 1'b0;
            w_bits[i] = 1'b0;
        end
        for (i = 0; i < 13; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end
        drive_main_neuron(13,
            "Neuron size n=13. thr=14. 2 beats (P_W=8). Beat 0 is full (8 real bits). Beat 1 has 5 real bits and 3 padded bits (x[7:5]=0, w[7:5]=1) ",
            x_bits, w_bits, 13, 14, 1'b0);

        // [11] n=8 ACT_POST_VALID_STABILITY directed test
        clear_vectors(x_bits, w_bits);
        for (i = 0; i < MAX_NEURON_INPUTS; i++) begin
            x_bits[i] = 1'b0;
            w_bits[i] = 1'b0;
        end
        for (i = 0; i < 8; i++) begin
            x_bits[i] = 1'b1;
            w_bits[i] = 1'b1;
        end
        drive_main_neuron(14, "Neuron size n=8. 1 beat (P_W=8). Act post valid stability probe.", x_bits, w_bits,
                          8, 4, 1'b0);

        clear_vectors(x_bits, w_bits);
        for (i = 0; i < 32; i++) begin x_bits[i] = 1'b1; w_bits[i] = 1'b1; end
        drive_main_neuron(15, "OLM suppresses activation output", x_bits, w_bits, 32, 0, 1'b1);
        
        // wait (valid_out == 1'b1);
        // @(posedge clk);
        // act_at_valid = act_out;
        // @(posedge clk);
        // act_after_valid = act_out;
        // total_checks++;
        // if (act_at_valid !== act_after_valid) begin
        //     failed_checks++;
        //     $error("[FAILED] act_out changed after valid_out fell (act@valid=%0b, act@after=%0b)",
        //            act_at_valid, act_after_valid);
        // end

        drive_threshold_contract_test();
    endtask


    // -------------------------------------------------------------------------
    // Testbench control flow
    // -------------------------------------------------------------------------
    initial begin
        int k;

        exp_mb = new();
        act_mb = new();
        
        total_checks = 0;
        failed_checks = 0;
        unexpected_assert_fails = 0;
        // Start monitor+scoreboard components in parallel.
        
        apply_reset(4);
        fork
            monitor_main();
            scoreboard_main();
        join_none


        run_directed_main_suite();

        // Let monitor/scoreboard settle and report.
        repeat (10) @(posedge clk);

        $display("-----------------------------------------------");
        $display("--------------SUMMARY SCOREBOARD--------------");
        $display("[SUMMARY]total_testcases=%0d passed=%0d failed=%0d", total_checks, passed_tests.size(), failed_tests.size());
        $display("-----------------------------------------------");

        if (passed_tests.size() > 0) begin
            $display("[SUMMARY][PASSED_TESTS]");
            for (k = 0; k < passed_tests.size(); k++) begin
                $display("  %s", passed_tests[k]);
            end
        end

        if (failed_tests.size() > 0) begin
            $display("[SUMMARY][FAILED_TESTS]");
            for (k = 0; k < failed_tests.size(); k++) begin
                $display("  %s", failed_tests[k]);
            end
        end

        $display("[SUMMARY][SVA] unexpected_assert_fails=%0d", unexpected_assert_fails);

        if ((failed_checks == 0) && (unexpected_assert_fails == 0)) begin
            // Success path is intentionally silent by user request.
        end else begin
            $display("[FAILED][SUMMARY] total_checks=%0d failed_checks=%0d unexpected_assert_fails=%0d",
                     total_checks, failed_checks, unexpected_assert_fails);
            $fatal(1, "TESTBENCH FAIL");
        end

        $finish;
    end


endmodule
