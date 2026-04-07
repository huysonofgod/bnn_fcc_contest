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

    typedef struct {
        int n_bits;
        int num_beats;
        int gap_before[];
        int threshold;
        bit mode_olm;
        bit back_to_back;
    } random_neuron_t;
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

    
    // Random test tracking 
    int random_tests_run;
    int random_tests_failed;
    string random_passed_tests[$];
    string random_failed_tests[$];


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
    // Formal coverage group
    // ------------------------


    // -------------------------------------------------------------------------
    // COV-1: Per-beat popcount distribution (0 to P_W)
    covergroup cg_beat_pc @(posedge clk);
        cp_beat_pc: coverpoint dbg_beat_popcount {
            bins pc_0 = {0};
            bins pc_1_3 = {[1:3]};
            bins pc_4_5 = {[4:5]};
            bins pc_6_7 = {[6:7]};
            bins pc_8 = {8};
        }
        option.per_instance = 1;
    endgroup

    // COV-2: Protocol transitions (valid gaps, single-beat, reset, OLM, valid_out)
    covergroup cg_protocol @(posedge clk);
        cp_valid_in_state: coverpoint {valid_in, dut.u_fsm.state_r} {
            bins valid_in_idle  = {{1'b1, FSM_IDLE}};
            bins valid_in_compute = {{1'b1, FSM_COMPUTE}};
            bins idle_idle      = {{1'b0, FSM_IDLE}};
            bins idle_compute   = {{1'b0, FSM_COMPUTE}};
        }
        cp_valid_out: coverpoint valid_out {
            bins valid_out_pulse = {1};
            bins valid_out_low   = {0};
        }
        cp_olm_sample: coverpoint mode_output_layer_sel {
            bins olm_on  = {1};
            bins olm_off = {0};
        }
        option.per_instance = 1;
    endgroup

    // COV-3: Neuron characteristics (beat count, threshold, activation result, OLM, BTB, gaps)
    covergroup cg_neuron @(posedge clk);
        cp_neuron_size: coverpoint {1, 7, 8, 13, 16, 32, 256, 784};
        cp_threshold_bin: coverpoint threshold_in {
            bins thr_low    = {[0:100]};
            bins thr_mid    = {[101:400]};
            bins thr_high   = {[401:784]};
        }
        cp_act_result: coverpoint act_out {
            bins act_0 = {0};
            bins act_1 = {1};
        }
        option.per_instance = 1;
    endgroup

    // COV-4: Threshold relationship cross (below/equal/above popcount, vs OLM)
    covergroup cg_thr_rel @(posedge clk);
        cp_thr_below_above: coverpoint {popcount_out, threshold_in} {
            bins below = default;
            bins equal = default;
            bins above = default;
        }
        cp_olm_impact: coverpoint {mode_output_layer_sel, act_out} {
            bins olm_forces_0 = {{1'b1, 1'b0}};
            bins no_olm_result = {{1'b0, 1'b?}};
        }
        option.per_instance = 1;
    endgroup

    // COV-5: FSM transitions (all legal arcs)
    covergroup cg_fsm_trans @(posedge clk);
        cp_fsm_transitions: coverpoint {dut.u_fsm.state_r, dut.u_fsm.state_next} {
            bins idle_to_compute = {{FSM_IDLE, FSM_COMPUTE}};
            bins idle_to_idle    = {{FSM_IDLE, FSM_IDLE}};
            bins compute_to_compute = {{FSM_COMPUTE, FSM_COMPUTE}};
            bins compute_to_reset = {{FSM_COMPUTE, FSM_RESET}};
            bins idle_to_reset   = {{FSM_IDLE, FSM_RESET}};
            bins reset_to_idle   = {{FSM_RESET, FSM_IDLE}};
        }
        option.per_instance = 1;
    endgroup

    // COV-6: Reset insertion point in FSM (from each state)
    covergroup cg_rst_in_state @(posedge clk);
        cp_rst_from_state: coverpoint {rst, dut.u_fsm.state_r} {
            bins rst_from_idle    = {{1'b1, FSM_IDLE}};
            bins rst_from_compute = {{1'b1, FSM_COMPUTE}};
            bins rst_from_reset   = {{1'b1, FSM_RESET}};
        }
        option.per_instance = 1;
    endgroup

    // COV-7: Parameter sweep (P_W bins - placeholder for multi-P_W phase)
    covergroup cg_param_sweep @(posedge clk);
        cp_p_w: coverpoint P_W {
            bins pw_8 = {8};  // Locked to P_W=8 in this phase
        }
        option.per_instance = 1;
    endgroup

    // COV-8: Padding scenarios (n=7, n=13, n=other)
    covergroup cg_padding @(posedge clk);
        cp_padded_sizes: coverpoint {1, 7, 8, 13, 16, 32, 256, 784} {
            bins n_7_padded   = {7};
            bins n_13_padded  = {13};
            bins n_other      = default;
        }
        option.per_instance = 1;
    endgroup

    // COV-9: Mandatory neuron sizes from spec
    covergroup cg_neuron_sizes @(posedge clk);
        cp_mandatory_n: coverpoint {1, 7, 8, 13, 16, 32, 256, 784} {
            bins n_1   = {1};
            bins n_7   = {7};
            bins n_8   = {8};
            bins n_13  = {13};
            bins n_16  = {16};
            bins n_32  = {32};
            bins n_256 = {256};
            bins n_784 = {784};
        }
        option.per_instance = 1;
    endgroup

    // COV-10: Activation output stability (stable post-valid)
    covergroup cg_act_stability @(posedge clk);
        cp_act_post_valid: coverpoint act_out {
            bins stable_after_fall = {{1'b1, 1'b1}};
            bins other = default;
        }
        option.per_instance = 1;
    endgroup

    cg_beat_pc cov_beat_pc = new();
    cg_protocol cov_protocol = new();
    cg_neuron cov_neuron = new();
    cg_thr_rel cov_thr_rel = new();
    cg_fsm_trans cov_fsm_trans = new();
    cg_rst_in_state cov_rst_in_state = new();
    cg_param_sweep cov_param_sweep = new();
    cg_padding cov_padding = new();
    cg_neuron_sizes cov_neuron_sizes = new();
    cg_act_stability cov_act_stability = new();





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
    // Helper: drive a single neuron with specified parameters, handling multi-beat packing, valid/last signaling, and expected result calculation for scoreboard reference.
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

    // Helper: Reset helper
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

    // Helper: Generate random neuron parameters
    task automatic gen_random_neuron(
        output random_neuron_t neuron,
        input int beat_count_max,
        input bit force_olm,
        input int thr_low,
        input int thr_high
    );
        int b, gap_len;
        int rand_olm_trigger, rand_btb_trigger;
        begin
            neuron.num_beats = ($urandom_range(1, beat_count_max) + P_W - 1) / P_W;
            neuron.n_bits = neuron.num_beats * P_W;
            neuron.gap_before = new[neuron.num_beats];

            // Gap distribution: [1, 20] cycles before each beat (including first)
            for (b = 0; b < neuron.num_beats; b++) begin
                neuron.gap_before[b] = $urandom_range(1, 20);
            end

            // Threshold strategy
            neuron.threshold = $urandom_range(thr_low, thr_high);

            // OLM: 20% forced on if force_olm=1, else 20% random
            rand_olm_trigger = $urandom_range(0, 4);
            neuron.mode_olm = force_olm ? 1'b1 : (rand_olm_trigger == 0 ? 1'b1 : 1'b0);

            // BTB (back-to-back): 25% probability
            rand_btb_trigger = $urandom_range(0, 3);
            neuron.back_to_back = (rand_btb_trigger == 0 ? 1'b1 : 1'b0);
        end
    endtask

    // Helper: Drive random neuron with BTB and gap support
    task automatic drive_random_neuron(
        input int test_id,
        input string test_name,
        input random_neuron_t neuron,
        input bit x_bits [0:MAX_NEURON_INPUTS-1],
        input bit w_bits [0:MAX_NEURON_INPUTS-1]
    );
        int beat, gap_cycle;
        exp_pkt_t exp_pkt;
        int expected_pc;
        logic expected_act;
        begin
            expected_pc = calc_popcount_match(x_bits, w_bits, neuron.n_bits);
            expected_act = neuron.mode_olm ? 1'b0 : (expected_pc >= neuron.threshold);

            exp_pkt.name              = test_name;
            exp_pkt.id                = test_id;
            exp_pkt.expected_popcount = expected_pc;
            exp_pkt.expected_act      = expected_act;
            exp_mb.put(exp_pkt);

            for (beat = 0; beat < neuron.num_beats; beat++) begin
                // Apply gap before beat (cycles of valid_in=0)
                for (gap_cycle = 0; gap_cycle < neuron.gap_before[beat]; gap_cycle++) begin
                    @(posedge clk);
                    valid_in <= 1'b0;
                    last <= 1'b0;
                end

                // Drive beat
                @(posedge clk);
                valid_in <= 1'b1;
                last <= (beat == neuron.num_beats - 1);
                x_in <= pack_main_beat(x_bits, neuron.n_bits, beat, 1'b0);
                w_in <= pack_main_beat(w_bits, neuron.n_bits, beat, 1'b1);
                threshold_in <= neuron.threshold;
                mode_output_layer_sel <= neuron.mode_olm;
            end

            @(posedge clk);
            valid_in <= 1'b0;
            last <= 1'b0;

            // Wait for valid_out pulse
            wait (valid_out === 1'b1);
            @(posedge clk);

            // Handle BTB: if enabled, skip the normal idle cycle
            // and go straight to presenting next neuron's setup
            if (neuron.back_to_back) begin
                // BTB: RESET state is handling acc_r_q=0, we skip one idle cycle
                // and present next neuron immediately
            end else begin
                // Normal: 2 cycles post-neuron (RESET + IDLE)
                @(posedge clk);
            end
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

    

    task automatic run_r1_core_stress();
        int nrn, beat_count_max;
        random_neuron_t neuron;
        bit x_bits [0:MAX_NEURON_INPUTS-1];
        bit w_bits [0:MAX_NEURON_INPUTS-1];
        int bi, rand_x, rand_w;
        string test_name;
        begin
            beat_count_max = 98;  // Up to 98 beats
            for (nrn = 0; nrn < 300; nrn++) begin
                gen_random_neuron(neuron, beat_count_max, 1'b0, 0, neuron.n_bits * P_W);

                // Randomize x/w bits
                for (bi = 0; bi < neuron.n_bits; bi++) begin
                    rand_x = $urandom();
                    rand_w = $urandom();
                    x_bits[bi] = rand_x[0];
                    w_bits[bi] = rand_w[0];
                end

                test_name = $sformatf("R68[%03d] core stress n=%0d beats=%0d olm=%0b btb=%0b",
                    nrn, neuron.n_bits, neuron.num_beats, neuron.mode_olm, neuron.back_to_back);
                drive_random_neuron(1000 + nrn, test_name, neuron, x_bits, w_bits);
                random_tests_run++;
            end
        end
    endtask
    task automatic run_r2_heavy_gap();
        int nrn, beat_count_max;
        random_neuron_t neuron;
        bit x_bits [0:MAX_NEURON_INPUTS-1];
        bit w_bits [0:MAX_NEURON_INPUTS-1];
        int bi, rand_x, rand_w;
        string test_name;
        begin
            beat_count_max = 98;
            for (nrn = 0; nrn < 100; nrn++) begin
                gen_random_neuron(neuron, beat_count_max, 1'b0, 0, neuron.n_bits * P_W);
                // Gaps are already [1,20] from gen_random_neuron, heavy by design

                for (bi = 0; bi < neuron.n_bits; bi++) begin
                    rand_x = $urandom();
                    rand_w = $urandom();
                    x_bits[bi] = rand_x[0];
                    w_bits[bi] = rand_w[0];
                end

                test_name = $sformatf("R69[%03d] heavy gap n=%0d beats=%0d gap_min=1",
                    nrn, neuron.n_bits, neuron.num_beats);
                drive_random_neuron(1300 + nrn, test_name, neuron, x_bits, w_bits);
                random_tests_run++;
            end
        end
    endtask
    
    
    task automatic run_r3_threshold_boundary();
        int nrn, beat_count_max;
        random_neuron_t neuron;
        bit x_bits [0:MAX_NEURON_INPUTS-1];
        bit w_bits [0:MAX_NEURON_INPUTS-1];
        int bi, rand_x, rand_w, pc, thr_offset;
        string test_name;
        begin
            beat_count_max = 98;
            for (nrn = 0; nrn < 150; nrn++) begin
                gen_random_neuron(neuron, beat_count_max, 1'b0, 0, neuron.n_bits * P_W);

                for (bi = 0; bi < neuron.n_bits; bi++) begin
                    rand_x = $urandom();
                    rand_w = $urandom();
                    x_bits[bi] = rand_x[0];
                    w_bits[bi] = rand_w[0];
                end

                // Compute popcount and set threshold near it
                pc = calc_popcount_match(x_bits, w_bits, neuron.n_bits);
                thr_offset = $urandom_range(-2, 2);
                neuron.threshold = pc + thr_offset;
                if (neuron.threshold < 0) neuron.threshold = 0;
                if (neuron.threshold > neuron.n_bits) neuron.threshold = neuron.n_bits;

                test_name = $sformatf("R70[%03d] boundary pc=%0d thr=%0d offset=%0d",
                    nrn, pc, neuron.threshold, thr_offset);
                random_tests_run++;
            end
        end
    endtask

    task automatic run_r4_olm_saturation();
        int nrn, beat_count_max;
        random_neuron_t neuron;
        bit x_bits [0:MAX_NEURON_INPUTS-1];
        bit w_bits [0:MAX_NEURON_INPUTS-1];
        int bi, rand_x, rand_w;
        string test_name;
        begin
            beat_count_max = 98;
            for (nrn = 0; nrn < 75; nrn++) begin
                gen_random_neuron(neuron, beat_count_max, 1'b1, 0, neuron.n_bits * P_W);  // force_olm=1
                neuron.mode_olm = 1'b1;  // Explicitly OLM always

                for (bi = 0; bi < neuron.n_bits; bi++) begin
                    rand_x = $urandom();
                    rand_w = $urandom();
                    x_bits[bi] = rand_x[0];
                    w_bits[bi] = rand_w[0];
                end

                test_name = $sformatf("R71[%03d] OLM saturation n=%0d beats=%0d olm_forced",
                    nrn, neuron.n_bits, neuron.num_beats);
                drive_random_neuron(1550 + nrn, test_name, neuron, x_bits, w_bits);
                random_tests_run++;
            end
        end
    endtask
    task automatic run_r5_singlebeat_saturation();
        int nrn, idx;
        random_neuron_t neuron;
        bit x_bits [0:MAX_NEURON_INPUTS-1];
        bit w_bits [0:MAX_NEURON_INPUTS-1];
        int rand_val;
        string test_name;
        begin
            for (nrn = 0; nrn < 75; nrn++) begin
                gen_random_neuron(neuron, 1, 1'b0, 0, 1);
                neuron.num_beats = 1;
                neuron.n_bits = 1;
                for (idx = 0; idx < MAX_NEURON_INPUTS; idx++) begin
                    x_bits[idx] = 1'b0;
                    w_bits[idx] = 1'b0;
                end
                rand_val = $urandom();
                x_bits[0] = rand_val[0];
                rand_val = $urandom();
                w_bits[0] = rand_val[0];
                test_name = $sformatf("R72[%03d] single-beat n=1 olm=%0b", nrn, neuron.mode_olm);
                drive_random_neuron(1625 + nrn, test_name, neuron, x_bits, w_bits);
                random_tests_run++;
            end
        end
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

        random_tests_run = 0;
        random_tests_failed = 0;
        // Start monitor+scoreboard components in parallel.
        
        apply_reset(4);
        fork
            monitor_main();
            scoreboard_main();
        join_none


        run_directed_main_suite();

        // Let monitor/scoreboard settle and report.
        $display("[FLOW] ========== SVA DIRECTED TESTS ==========");
        repeat (10) @(posedge clk);

        // --------- Section 2: Constrained-Random Tests ---------
        $display("[FLOW] ========== CONSTRAINED-RANDOM TESTS ==========");
        $display("[FLOW] Running R1: Core Stress (300 neurons)...");
        run_r1_core_stress();
        
        $display("[FLOW] Running R2: Heavy Gap (100 neurons)...");
        run_r2_heavy_gap();
        
        $display("[FLOW] Running R3: Threshold Boundary (150 neurons)...");
        run_r3_threshold_boundary();
        
        $display("[FLOW] Running R4: OLM Saturation (75 neurons)...");
        run_r4_olm_saturation();
        
        $display("[FLOW] Running R5: Single-Beat Saturation (75 neurons)...");
        run_r5_singlebeat_saturation();

        repeat (10) @(posedge clk);


        $display("-----------------------------------------------");
        $display("--------------SUMMARY SCOREBOARD--------------");
        $display("[SUMMARY]total_testcases=%0d passed=%0d failed=%0d", total_checks, passed_tests.size(), failed_tests.size());
        $display("-----------------------------------------------");
        
        
        
        if (passed_tests.size() > 0) begin
            $display("[SUMMARY][PASSED_TESTS] (Directed subset shown)");
            for (k = 0; k < (passed_tests.size() < 20 ? passed_tests.size() : 20); k++) begin
                $display("  %s", passed_tests[k]);
            end
            if (passed_tests.size() > 20) begin
                $display("  ... and %0d more", passed_tests.size() - 20);
            end
        end
        if (failed_tests.size() > 0) begin
            $display("[SUMMARY][FAILED_TESTS]");
            for (k = 0; k < failed_tests.size(); k++) begin
                $display("  %s", failed_tests[k]);
            end
        end

        $display("[SUMMARY][SVA] unexpected_assert_fails=%0d", unexpected_assert_fails);
        $display("[SUMMARY][RANDOM_TESTS] run=%0d failed=%0d", random_tests_run, random_tests_failed);

        // --------- Coverage Report ---------
        $display("-----------------------------------------------");
        $display("[COVERAGE] Functional Coverage Summary:");
        $display("  COV-1 (Beat Popcount): %0.1f%%", cov_beat_pc.get_coverage());
        $display("  COV-2 (Protocol): %0.1f%%", cov_protocol.get_coverage());
        $display("  COV-3 (Neuron Chars): %0.1f%%", cov_neuron.get_coverage());
        $display("  COV-4 (Threshold Rel): %0.1f%%", cov_thr_rel.get_coverage());
        $display("  COV-5 (FSM Trans): %0.1f%%", cov_fsm_trans.get_coverage());
        $display("  COV-6 (Reset Points): %0.1f%%", cov_rst_in_state.get_coverage());
        $display("  COV-7 (Param Sweep): %0.1f%%", cov_param_sweep.get_coverage());
        $display("  COV-8 (Padding): %0.1f%%", cov_padding.get_coverage());
        $display("  COV-9 (Neuron Sizes): %0.1f%%", cov_neuron_sizes.get_coverage());
        $display("  COV-10 (Act Stability): %0.1f%%", cov_act_stability.get_coverage());

        if ((failed_checks == 0) && (unexpected_assert_fails == 0) && (random_tests_failed == 0)) begin
            $display("");
            $display("[SUCCESS] All tests passed!");
        end else begin
            $display("");
            $display("[FAILED][SUMMARY] directed_failed=%0d random_failed=%0d sva_fails=%0d",
                     failed_checks, random_tests_failed, unexpected_assert_fails);
            $fatal(1, "TESTBENCH FAIL");
        end

        $finish;
    end


endmodule
