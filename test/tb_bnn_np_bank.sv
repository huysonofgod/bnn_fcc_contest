`timescale 1ns/10ps

`ifndef NPBANK_TB_P_W
`define NPBANK_TB_P_W 8
`endif
`ifndef NPBANK_TB_P_N
`define NPBANK_TB_P_N 8
`endif
`ifndef NPBANK_TB_ACC_W
`define NPBANK_TB_ACC_W 10
`endif
`ifndef NPBANK_TB_FAN_IN
`define NPBANK_TB_FAN_IN 784
`endif
`ifndef NPBANK_TB_FANOUT_STAGES
`define NPBANK_TB_FANOUT_STAGES 0
`endif

module tb_bnn_np_bank;

    //==========================================================================
    // Parameters
    //==========================================================================
    parameter int P_W           = `NPBANK_TB_P_W;
    parameter int P_N           = `NPBANK_TB_P_N;
    parameter int ACC_W         = `NPBANK_TB_ACC_W;
    parameter int FAN_IN        = `NPBANK_TB_FAN_IN;
    parameter int FANOUT_STAGES = `NPBANK_TB_FANOUT_STAGES;

    localparam int ITERS = (FAN_IN + P_W - 1) / P_W;
    localparam int SCORE_MULTI_LO = (FAN_IN > 1) ? 2 : 1;
    localparam int SCORE_MULTI_HI = (FAN_IN > 1) ? FAN_IN : 1;
    // NP latency: 1 cycle after np_last for valid_out to fire.
    // Additional latency from fanout buffer.
    localparam int MAX_NP_LATENCY = FANOUT_STAGES + 10; // conservative
    localparam int B2B_IMAGES     = 24;
    localparam int STRESS_IMAGES  = 64;

    //==========================================================================
    // DUT interface signals
    //==========================================================================
    logic                     clk = 1'b0;
    logic                     rst = 1'b1;

    logic [P_W-1:0]           x_in    = '0;
    logic [P_N*P_W-1:0]       w_flat  = '0;
    logic [P_N*ACC_W-1:0]     thr_flat= '0;

    logic                     np_valid_in            = 1'b0;
    logic                     np_last                = 1'b0;
    logic                     mode_output_layer_sel  = 1'b0;

    logic [P_N-1:0]           y_out;
    logic [P_N*ACC_W-1:0]     score_out;
    logic                     np_valid_out;

    //==========================================================================
    // Clock generation — 100 MHz
    //==========================================================================
    always #5 clk = ~clk;

    //==========================================================================
    // DUT instantiation
    //==========================================================================
    bnn_np_bank #(
        .P_W           (P_W),
        .P_N           (P_N),
        .ACC_W         (ACC_W),
        .FAN_IN        (FAN_IN),
        .FANOUT_STAGES (FANOUT_STAGES)
    ) DUT (
        .clk                  (clk),
        .rst                  (rst),
        .x_in                 (x_in),
        .w_flat               (w_flat),
        .thr_flat             (thr_flat),
        .np_valid_in          (np_valid_in),
        .np_last              (np_last),
        .mode_output_layer_sel(mode_output_layer_sel),
        .y_out                (y_out),
        .score_out            (score_out),
        .np_valid_out         (np_valid_out)
    );

    //==========================================================================
    // Scoreboard
    //==========================================================================
    int pass_count = 0;
    int fail_count = 0;
    string fail_log[$];

    function automatic void check(string name, logic cond, string msg = "");
        if (cond) begin
            pass_count++;
        end else begin
            fail_count++;
            fail_log.push_back($sformatf("[FAIL] %s: %s", name, msg));
            $error("[SB] %s: %s", name, msg);
        end
    endfunction

    //==========================================================================
    // SVA — Lane alignment check [H5]
    //
    // This is the #1 silent failure mode: one NP's valid_out drifts from the
    // others.  bnn_np_bank exposes only lane[0]; if any other lane differs,
    // the error is invisible without this gray-box assertion.
    //
    // Access via hierarchical reference: DUT.g_np[j].u_np.valid_out
    //==========================================================================
    genvar gk;
    generate
        for (gk = 1; gk < P_N; gk++) begin : g_lane_align_sva
            property p_lane_align;
                @(posedge clk) disable iff (rst)
                DUT.np_valid_lane[0] === DUT.np_valid_lane[gk];
            endproperty
            assert property (p_lane_align)
            else $error("[SVA-1] FAIL a_lane_align: lane[0].valid=%0b != lane[%0d].valid=%0b",
                        DUT.np_valid_lane[0], gk, DUT.np_valid_lane[gk]);
        end
    endgenerate

    //--------------------------------------------------------------------------
    // SVA-2: No X on outputs when np_valid_out is asserted.
    //--------------------------------------------------------------------------
    property p_no_x_on_valid_out;
        @(posedge clk) disable iff (rst)
        np_valid_out |-> (!$isunknown(y_out) && !$isunknown(score_out));
    endproperty
    assert property (p_no_x_on_valid_out)
    else $error("[SVA-2] FAIL: X on y_out or score_out when np_valid_out=1");

    //==========================================================================
    // Covergroups
    //==========================================================================

    //--------------------------------------------------------------------------
    // cg_bank: sampled on np_valid_out — covers mode, popcount range,
    // activation pattern, and mode × activation cross.
    // score_out[ACC_W-1:0] = lane 0's popcount (representative).
    //--------------------------------------------------------------------------
    covergroup cg_bank @(posedge clk iff np_valid_out);
        cp_mode : coverpoint mode_output_layer_sel;

        cp_score_range : coverpoint score_out[ACC_W-1:0] {
            bins zero = {0};
            bins one   = {1};
            // Collapse gracefully for FAN_IN=1 so the degenerate sweep stays legal.
            bins multi = {[SCORE_MULTI_LO:SCORE_MULTI_HI]};
        }

        cp_act_pattern : coverpoint y_out {
            bins all_zero = {{P_N{1'b0}}};
            bins all_one  = {{P_N{1'b1}}};
            bins mixed    = default;
        }

        x_mode_act : cross cp_mode, cp_act_pattern;
    endgroup

    //--------------------------------------------------------------------------
    // cg_ctrl: covers np_valid_in, np_last, and mode at every posedge.
    // Ensures all control combinations are exercised.
    //--------------------------------------------------------------------------
    covergroup cg_ctrl @(posedge clk);
        cp_valid_in : coverpoint np_valid_in;
        cp_last     : coverpoint np_last;
        cp_mode     : coverpoint mode_output_layer_sel;
        x_valid_last : cross cp_valid_in, cp_last;
    endgroup

    cg_bank cg_b = new();
    cg_ctrl cg_c = new();

    //==========================================================================
    // Golden reference model
    //
    // Per-image computation: accumulate XNOR popcount per lane, then compare
    // to threshold (hidden) or return raw popcount (output).
    //
    // The NP computes: accum[j] = sum_{beat} popcount(x_in[beat] XNOR w[j][beat])
    //   - Hidden: act[j]   = (accum[j] >= threshold[j])
    //   - Output: score[j] = accum[j]
    //==========================================================================

    // Storage for the current image being driven
    logic [P_W-1:0]   img_x     [ITERS];  // input beats
    logic [P_W-1:0]   img_w     [P_N][ITERS]; // weights per lane per beat
    logic [ACC_W-1:0] img_thr   [P_N];    // thresholds per lane

    function automatic int popcount_pw(logic [P_W-1:0] v);
        int cnt = 0;
        for (int b = 0; b < P_W; b++)
            if (v[b]) cnt++;
        return cnt;
    endfunction

    // Compute golden output for one image already stored in img_*
    task automatic compute_and_check_golden(
        input logic is_output_mode,
        input string test_name
    );
        int accum[P_N];
        // Wait for np_valid_out with timeout
        int timeout = ITERS * 2 + MAX_NP_LATENCY + 50;
        int t = 0;

        while (!np_valid_out && t < timeout) begin
            @(posedge clk);
            t++;
        end
        check($sformatf("%s_np_valid_out_seen", test_name),
              np_valid_out == 1'b1,
              $sformatf("np_valid_out never asserted (t=%0d)", t));
        if (!np_valid_out) return;

        // Compute expected values
        for (int j = 0; j < P_N; j++) begin
            accum[j] = 0;
            for (int i = 0; i < ITERS; i++) begin
                logic [P_W-1:0] xnor_bits;
                xnor_bits = img_x[i] ~^ img_w[j][i];
                accum[j] += popcount_pw(xnor_bits);
            end
        end

        if (!is_output_mode) begin
            // Hidden mode: activation = (popcount >= threshold)
            for (int j = 0; j < P_N; j++) begin
                logic exp_act = (ACC_W'(accum[j]) >= img_thr[j]);
                check($sformatf("%s_y_out_%0d", test_name, j),
                      y_out[j] == exp_act,
                      $sformatf("lane=%0d DUT=%0b expected=%0b (accum=%0d thr=%0d)",
                                j, y_out[j], exp_act, accum[j], img_thr[j]));
            end
        end else begin
            // Output mode: raw popcount preserved in score_out
            for (int j = 0; j < P_N; j++) begin
                logic [ACC_W-1:0] exp_sc = ACC_W'(accum[j]);
                check($sformatf("%s_score_%0d", test_name, j),
                      score_out[j*ACC_W +: ACC_W] == exp_sc,
                      $sformatf("lane=%0d DUT=%0d expected=%0d",
                                j, score_out[j*ACC_W +: ACC_W], exp_sc));
            end
        end
    endtask

    //==========================================================================
    // Reset task
    //==========================================================================
    task automatic reset_dut(int cycles = 10);
        rst               <= 1'b1;
        x_in              <= '0;
        w_flat            <= '0;
        thr_flat          <= '0;
        np_valid_in       <= 1'b0;
        np_last           <= 1'b0;
        mode_output_layer_sel <= 1'b0;
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //==========================================================================
    // Image driver
    //
    // Drives one complete image:
    //   - ITERS beats of x_in and w_flat with np_valid_in=1
    //   - np_last=1 on the last beat
    //   - Stores x, w, thr in img_* arrays for the golden model
    //   - Optional valid_probability: randomly drops np_valid_in (stress)
    //==========================================================================
    task automatic drive_image(
        input logic [P_W-1:0]   x_vec  [ITERS],
        input logic [P_W-1:0]   w_mat  [P_N][ITERS],
        input logic [ACC_W-1:0] thr_vec[P_N],
        input logic              is_out_mode,
        input real               valid_prob = 1.0
    );
        // Store for golden model
        for (int i = 0; i < ITERS; i++)  img_x[i] = x_vec[i];
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) img_w[j][i] = w_mat[j][i];
            img_thr[j] = thr_vec[j];
        end

        // Set mode and thresholds (held constant for the image)
        @(posedge clk);
        mode_output_layer_sel <= is_out_mode;
        for (int j = 0; j < P_N; j++)
            thr_flat[j*ACC_W +: ACC_W] <= thr_vec[j];

        // Drive beats
        for (int i = 0; i < ITERS; i++) begin
            // Optional stall gap
            if (valid_prob < 1.0) begin
                while ($urandom_range(0,99) >= int'(valid_prob * 100)) begin
                    @(posedge clk);
                    np_valid_in <= 1'b0;
                    np_last     <= 1'b0;
                end
            end
            @(posedge clk);
            // Build w_flat from per-lane weight words for this beat
            for (int j = 0; j < P_N; j++)
                w_flat[j*P_W +: P_W] <= w_mat[j][i];
            x_in        <= x_vec[i];
            np_valid_in <= 1'b1;
            np_last     <= (i == ITERS - 1);
        end
        @(posedge clk);
        np_valid_in <= 1'b0;
        np_last     <= 1'b0;
    endtask

    //==========================================================================
    // Helper: build image arrays with all-same weights
    //==========================================================================
    task automatic make_uniform_image(
        output logic [P_W-1:0]   x_vec  [ITERS],
        output logic [P_W-1:0]   w_mat  [P_N][ITERS],
        output logic [ACC_W-1:0] thr_vec[P_N],
        input  logic [P_W-1:0]   x_val,
        input  logic [P_W-1:0]   w_val,
        input  logic [ACC_W-1:0] thr_val
    );
        for (int i = 0; i < ITERS; i++)    x_vec[i] = x_val;
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) w_mat[j][i] = w_val;
            thr_vec[j] = thr_val;
        end
    endtask

    //==========================================================================
    // T01 — Single image, all lanes same weights and inputs
    //==========================================================================
    task automatic test_t01_uniform();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T01: uniform image, all lanes identical");
        reset_dut();
        // All inputs = 0xFF, all weights = 0xFF → XNOR = 0xFF → popcount = P_W per beat
        // Total accum = P_W * ITERS = FAN_IN; threshold = FAN_IN/2 → activation = 1
        make_uniform_image(xv, wm, tv, P_W'('1), P_W'('1), ACC_W'(FAN_IN/2));
        drive_image(xv, wm, tv, 1'b0);
        compute_and_check_golden(1'b0, "T01_hidden");
    endtask

    //==========================================================================
    // T02 — Per-lane unique weights; hidden mode
    //==========================================================================
    task automatic test_t02_unique_lanes();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T02: per-lane unique weights, hidden mode");
        reset_dut();
        // Each lane has a different weight pattern to produce different popcounts
        for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
            tv[j] = ACC_W'(FAN_IN / 4);  // low threshold → most activate
        end
        drive_image(xv, wm, tv, 1'b0);
        compute_and_check_golden(1'b0, "T02_unique");
    endtask

    //==========================================================================
    // T03 — Hidden mode: threshold sweep (all activate vs none activate)
    //==========================================================================
    task automatic test_t03_threshold_sweep();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T03: hidden mode threshold sweep");
        reset_dut();

        // All-ones input and all-ones weights → maximum popcount = FAN_IN
        for (int i = 0; i < ITERS; i++) xv[i] = '1;
        for (int j = 0; j < P_N; j++)
            for (int i = 0; i < ITERS; i++) wm[j][i] = '1;

        // Threshold = 0: all lanes should activate
        for (int j = 0; j < P_N; j++) tv[j] = '0;
        drive_image(xv, wm, tv, 1'b0);
        compute_and_check_golden(1'b0, "T03_thr0_all_on");

        reset_dut();

        // Threshold = MAX: no lanes should activate
        for (int j = 0; j < P_N; j++) tv[j] = {ACC_W{1'b1}};
        drive_image(xv, wm, tv, 1'b0);
        compute_and_check_golden(1'b0, "T03_thr_max_all_off");
    endtask

    //==========================================================================
    // T04 — Output mode: raw popcount preserved, threshold irrelevant
    //==========================================================================
    task automatic test_t04_output_mode();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T04: output mode, score_out = raw popcount");
        reset_dut();
        for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
            tv[j] = '0;  // threshold irrelevant in output mode
        end
        drive_image(xv, wm, tv, 1'b1);  // is_output_mode=1
        compute_and_check_golden(1'b1, "T04_output");
    endtask

    //==========================================================================
    // T05 — FANOUT_STAGES latency invariance
    // The TB is compiled for a specific FANOUT_STAGES. Run two images and
    // verify both produce correct results (the fan-out latency is transparent
    // to the golden model since we wait for np_valid_out each time).
    //==========================================================================
    task automatic test_t05_fanout_latency();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T05: FANOUT_STAGES=%0d latency invariance", FANOUT_STAGES);
        reset_dut();
        for (int img = 0; img < 2; img++) begin
            for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
            for (int j = 0; j < P_N; j++) begin
                for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
                tv[j] = ACC_W'(FAN_IN / 3);
            end
            drive_image(xv, wm, tv, 1'b0);
            compute_and_check_golden(1'b0, $sformatf("T05_img%0d", img));
            repeat (5) @(posedge clk);
        end
    endtask

    //==========================================================================
    // T06 — Back-to-back images: no state leakage
    //==========================================================================
    task automatic test_t06_back_to_back();
        int n_imgs = B2B_IMAGES;
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T06: %0d back-to-back images", n_imgs);
        reset_dut();
        for (int img = 0; img < n_imgs; img++) begin
            for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
            for (int j = 0; j < P_N; j++) begin
                for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
                tv[j] = ACC_W'($urandom_range(0, FAN_IN));
            end
            drive_image(xv, wm, tv, (img % 2 == 1));  // alternate modes
            compute_and_check_golden((img % 2 == 1), $sformatf("T06_img%0d", img));
        end
    endtask

    //==========================================================================
    // T07 — np_valid_in gaps during an image (stall behavior)
    //==========================================================================
    task automatic test_t07_valid_gaps();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T07: np_valid_in gaps (70%% probability)");
        reset_dut();
        for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
            tv[j] = ACC_W'(FAN_IN / 2);
        end
        drive_image(xv, wm, tv, 1'b0, 0.7);  // 70% valid probability
        compute_and_check_golden(1'b0, "T07_gaps");
    endtask

    //==========================================================================
    // T08 — Reset mid-image: clean recovery
    //==========================================================================
    task automatic test_t08_reset_mid_image();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        $display("[TEST] T08: Reset mid-image, then clean image");
        reset_dut();

        // Start driving an image but reset halfway through
        for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
            tv[j] = ACC_W'(FAN_IN / 2);
        end

        // Drive partial image (half of ITERS beats)
        @(posedge clk);
        mode_output_layer_sel <= 1'b0;
        for (int j = 0; j < P_N; j++) thr_flat[j*ACC_W +: ACC_W] <= tv[j];
        for (int i = 0; i < ITERS/2; i++) begin
            @(posedge clk);
            for (int j = 0; j < P_N; j++) w_flat[j*P_W +: P_W] <= wm[j][i];
            x_in        <= xv[i];
            np_valid_in <= 1'b1;
            np_last     <= 1'b0;
        end
        @(posedge clk); np_valid_in <= 1'b0;

        // Assert reset
        rst <= 1'b1;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        // Verify np_valid_out is not spuriously high after reset
        check("T08_no_stale_valid", np_valid_out == 1'b0,
              $sformatf("np_valid_out=%0b expected 0 after reset", np_valid_out));

        // Now run a clean complete image and verify
        for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
        for (int j = 0; j < P_N; j++) begin
            for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
            tv[j] = ACC_W'(FAN_IN / 4);
        end
        drive_image(xv, wm, tv, 1'b0);
        compute_and_check_golden(1'b0, "T08_clean_after_reset");
    endtask

    //==========================================================================
    // T09 — Large random stress: many images, alternating modes and gaps
    //==========================================================================
    task automatic test_t09_random_stress();
        logic [P_W-1:0]   xv[ITERS];
        logic [P_W-1:0]   wm[P_N][ITERS];
        logic [ACC_W-1:0] tv[P_N];
        bit mode_sel;
        real valid_prob;
        $display("[TEST] T09: %0d-image random stress with mixed modes/gaps", STRESS_IMAGES);
        reset_dut();
        for (int img = 0; img < STRESS_IMAGES; img++) begin
            mode_sel   = (img % 2);
            valid_prob = (img % 3 == 0) ? 0.65 : 0.9;
            for (int i = 0; i < ITERS; i++) xv[i] = P_W'($urandom());
            for (int j = 0; j < P_N; j++) begin
                for (int i = 0; i < ITERS; i++) wm[j][i] = P_W'($urandom());
                tv[j] = ACC_W'($urandom_range(0, FAN_IN));
            end
            drive_image(xv, wm, tv, mode_sel, valid_prob);
            compute_and_check_golden(mode_sel, $sformatf("T09_img%0d", img));
        end
    endtask

    //==========================================================================
    // Main test sequence
    //==========================================================================
    initial begin
        $display("=====================================================");
        $display(" tb_bnn_np_bank — Level-1 CRV-lite");
        $display(" P_W=%0d P_N=%0d ACC_W=%0d FAN_IN=%0d FANOUT=%0d",
                 P_W, P_N, ACC_W, FAN_IN, FANOUT_STAGES);
        $display(" ITERS=%0d", ITERS);
        $display("=====================================================");

        test_t01_uniform();
        test_t02_unique_lanes();
        test_t03_threshold_sweep();
        test_t04_output_mode();
        test_t05_fanout_latency();
        test_t06_back_to_back();
        test_t07_valid_gaps();
        test_t08_reset_mid_image();
        test_t09_random_stress();

        repeat (20) @(posedge clk);

        $display("");
        $display("=====================================================");
        $display(" SCOREBOARD SUMMARY — tb_bnn_np_bank");
        $display("=====================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failures ---");
            foreach (fail_log[i]) $display("    %s", fail_log[i]);
        end
        $display("  Bank CG      : %.1f%%", cg_b.get_coverage());
        $display("  Ctrl CG      : %.1f%%", cg_c.get_coverage());
        $display("=====================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("=====================================================");

        $finish;
    end

endmodule
