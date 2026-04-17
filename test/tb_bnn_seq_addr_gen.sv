`timescale 1ns/10ps

//Compile-time parameter overrides — set by the sweep script via +define
`ifndef SAG_TB_P_W
`define SAG_TB_P_W 8
`endif
`ifndef SAG_TB_P_N
`define SAG_TB_P_N 8
`endif
`ifndef SAG_TB_FAN_IN
`define SAG_TB_FAN_IN 784
`endif
`ifndef SAG_TB_NUM_NEURONS
`define SAG_TB_NUM_NEURONS 256
`endif
`ifndef SAG_TB_RANDOM_CYCLES
`define SAG_TB_RANDOM_CYCLES 10000
`endif

module tb_bnn_seq_addr_gen;

    //Parameters — mirror DUT localparams exactly to stay in lock-step
    parameter int P_W         = `SAG_TB_P_W;
    parameter int P_N         = `SAG_TB_P_N;
    parameter int FAN_IN      = `SAG_TB_FAN_IN;
    parameter int NUM_NEURONS = `SAG_TB_NUM_NEURONS;

    localparam int ITERS      = (FAN_IN + P_W - 1) / P_W;
    localparam int PASSES     = (NUM_NEURONS + P_N - 1) / P_N;
    localparam int WT_ADDR_W  = $clog2((ITERS * PASSES) > 1 ? (ITERS * PASSES) : 2);
    localparam int THR_ADDR_W = $clog2(PASSES > 1 ? PASSES : 2);
    localparam int NP_CNT_W   = $clog2(P_N + 1);
    localparam int ITER_W     = $clog2(ITERS > 1 ? ITERS : 2);
    localparam int PASS_W     = $clog2(PASSES > 1 ? PASSES : 2);
    localparam int REMAINDER       = NUM_NEURONS % P_N;
    localparam int LAST_PASS_COUNT = (REMAINDER == 0) ? P_N : REMAINDER;
    localparam int WT_DEPTH   = ITERS * PASSES;
    localparam int WT_ADDR_MAX = WT_DEPTH - 1;
    localparam int WT_LOW_HI   = (WT_ADDR_MAX < 3) ? WT_ADDR_MAX : 3;
    localparam int WT_MID_LO   = (WT_ADDR_MAX < 4) ? WT_ADDR_MAX : 4;
    localparam int WT_MID_HI   = (WT_ADDR_MAX <= 4) ? WT_ADDR_MAX : (WT_DEPTH / 2);
    localparam int WT_HIGH_LO  = (WT_ADDR_MAX <= 4) ? WT_ADDR_MAX : ((WT_DEPTH / 2) + 1);
    localparam int WT_HIGH_HI  = WT_ADDR_MAX;

    //DUT interface signals
    logic                  clk  = 1'b0;
    logic                  rst  = 1'b1;

    logic                  iter_we     = 1'b0;
    logic                  iter_clr    = 1'b0;
    logic                  pass_we     = 1'b0;
    logic                  pass_clr    = 1'b0;
    logic                  wt_addr_we  = 1'b0;
    logic                  thr_addr_we = 1'b0;
    logic                  vnp_we      = 1'b0;

    //Combinational status outputs from DUT
    logic                  iter_tc;
    logic                  pass_tc;

    //Registered address / count outputs from DUT
    logic [WT_ADDR_W-1:0]  wt_rd_addr;
    logic [THR_ADDR_W-1:0] thr_rd_addr;
    logic [NP_CNT_W-1:0]   valid_np_count;
    logic                  last_pass;

    // Clock generation — 100 MHz
    always #5 clk = ~clk;

    // DUT instantiation
    bnn_seq_addr_gen #(
        .P_W         (P_W),
        .P_N         (P_N),
        .FAN_IN      (FAN_IN),
        .NUM_NEURONS (NUM_NEURONS)
    ) DUT (
        .clk            (clk),
        .rst            (rst),
        .iter_we        (iter_we),
        .iter_clr       (iter_clr),
        .pass_we        (pass_we),
        .pass_clr       (pass_clr),
        .wt_addr_we     (wt_addr_we),
        .thr_addr_we    (thr_addr_we),
        .vnp_we         (vnp_we),
        .iter_tc        (iter_tc),
        .pass_tc        (pass_tc),
        .wt_rd_addr     (wt_rd_addr),
        .thr_rd_addr    (thr_rd_addr),
        .valid_np_count (valid_np_count),
        .last_pass      (last_pass)
    );

    //Shadow model — cycle-accurate expected-state tracking
    //    //Mirrors every registered section (A–E) of the DUT using the identical
    //enable conditions and NBA semantics.  Both models see the same inputs,
    //so they evolve in lock-step.  The concurrent checker below compares
    //DUT outputs vs shadow on every active posedge.
    //    //Gray-box reads: DUT.iter_cnt_r_q, DUT.pass_cnt_r_q used in SVAs.
    logic [ITER_W-1:0]     sh_iter = '0;
    logic [PASS_W-1:0]     sh_pass = '0;
    logic [WT_ADDR_W-1:0]  sh_wt   = '0;
    logic [THR_ADDR_W-1:0] sh_thr  = '0;
    logic [NP_CNT_W-1:0]   sh_vnp  = NP_CNT_W'(P_N);
    logic                  sh_lp   = 1'b0;

    //Combinational pass_tc from shadow — mirrors DUT's assign pass_tc
    logic sh_pass_tc;
    assign sh_pass_tc = (sh_pass == PASS_W'(PASSES - 1));

    always_ff @(posedge clk) begin
        if (rst) begin
            sh_iter <= '0;
            sh_pass <= '0;
            sh_wt   <= '0;
            sh_thr  <= '0;
            sh_vnp  <= NP_CNT_W'(P_N);
            sh_lp   <= 1'b0;
        end else begin
            //iteration counter
            if (iter_we)
                sh_iter <= iter_clr ? '0 : ITER_W'(sh_iter + 1'b1);
            //pass counter
            if (pass_we)
                sh_pass <= pass_clr ? '0 : PASS_W'(sh_pass + 1'b1);
            //weight address — RUN_ITER publishes the NEXT
            //iteration address on non-terminal beats so BRAM output stays
            //aligned with the next accepted beat in bnn_layer_engine.
            if (wt_addr_we)
                sh_wt <= WT_ADDR_W'(sh_pass) * WT_ADDR_W'(ITERS)
                       + WT_ADDR_W'((iter_we && !(sh_iter == ITER_W'(ITERS - 1)))
                            ? (iter_clr ? '0 : (sh_iter + ITER_W'(1)))
                                                           : sh_iter);
            //threshold address
            if (thr_addr_we)
                sh_thr <= THR_ADDR_W'(sh_pass);
            //valid_np_count and last_pass, sampled from pass_tc
            if (vnp_we) begin
                sh_vnp <= sh_pass_tc ? NP_CNT_W'(LAST_PASS_COUNT) : NP_CNT_W'(P_N);
                sh_lp  <= sh_pass_tc;
            end
        end
    end

    //Concurrent output checker
    //Runs every active posedge and compares each DUT registered output with
    //the shadow model.  Reports via $error (visible in sim log and counted by
    //the master script) and also increments the shadow fail counter.
    int shadow_fail_cnt = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (wt_rd_addr !== sh_wt) begin
                $error("[SHADOW] wt_rd_addr: DUT=%0d shadow=%0d", wt_rd_addr, sh_wt);
                shadow_fail_cnt++;
            end
            if (thr_rd_addr !== sh_thr) begin
                $error("[SHADOW] thr_rd_addr: DUT=%0d shadow=%0d", thr_rd_addr, sh_thr);
                shadow_fail_cnt++;
            end
            if (valid_np_count !== sh_vnp) begin
                $error("[SHADOW] valid_np_count: DUT=%0d shadow=%0d", valid_np_count, sh_vnp);
                shadow_fail_cnt++;
            end
            if (last_pass !== sh_lp) begin
                $error("[SHADOW] last_pass: DUT=%0b shadow=%0b", last_pass, sh_lp);
                shadow_fail_cnt++;
            end
        end
    end

    // SVA — Protocol contracts
    // iter_clr is a NEXT-VALUE OVERRIDE, not an unconditional clear.
    // The FSM must NEVER assert iter_clr without also asserting iter_we.
    // Any violation is an FSM protocol bug. [H1], STATE.md §4.2.
    property p_iter_clr_req_we;
        @(posedge clk) disable iff (rst)
        iter_clr |-> iter_we;
    endproperty
    assert property (p_iter_clr_req_we)
    else $error("[SVA] iter_clr=1 but iter_we=0");

    //symmetric rule for pass_clr. [H1], STATE.md §4.2.
    property p_pass_clr_req_we;
        @(posedge clk) disable iff (rst)
        pass_clr |-> pass_we;
    endproperty
    assert property (p_pass_clr_req_we)
    else $error("[SVA] pass_clr=1 but pass_we=0");

    //When iter_clr fires WITHOUT iter_we, the counter must not change.
    //This is an RTL-regression guard: if someone re-wires iter_clr as
    //unconditional, this fires. Normal operation should never trigger this.
    property p_iter_no_change_clr_alone;
        @(posedge clk) disable iff (rst)
        (iter_clr && !iter_we) |=> $stable(DUT.iter_cnt_r_q);
    endproperty
    assert property (p_iter_no_change_clr_alone)
    else $error("[SVA] FAIL: iter_cnt changed on iter_clr without iter_we");

    //Weight address formula.
    //One cycle after wt_addr_we, wt_rd_addr must equal the pass counter value
    //from that cycle multiplied by ITERS, plus the prefetched iteration
    //address. RUN_ITER advances to the next iteration address only on
    //non-terminal beats; LOAD_THR and terminal beats keep the current
    //iteration/base address.
    property p_wt_addr_formula;
        @(posedge clk) disable iff (rst)
        wt_addr_we |=>
            (wt_rd_addr == (WT_ADDR_W'($past(DUT.pass_cnt_r_q)) * WT_ADDR_W'(ITERS)
                            + WT_ADDR_W'(($past(iter_we)
                                && !($past(DUT.iter_cnt_r_q) == ITER_W'(ITERS - 1)))
                                ? ($past(iter_clr) ? '0
                                                   : ($past(DUT.iter_cnt_r_q) + ITER_W'(1)))
                                : $past(DUT.iter_cnt_r_q))));
    endproperty
    assert property (p_wt_addr_formula)
    else $error("[SVA] FAIL a_wt_addr_formula: wt_rd_addr=%0d expected=%0d",
                wt_rd_addr,
                WT_ADDR_W'($past(DUT.pass_cnt_r_q))*WT_ADDR_W'(ITERS)
                + WT_ADDR_W'(($past(iter_we)
                    && !($past(DUT.iter_cnt_r_q) == ITER_W'(ITERS - 1)))
                    ? ($past(iter_clr) ? '0
                                       : ($past(DUT.iter_cnt_r_q) + ITER_W'(1)))
                    : $past(DUT.iter_cnt_r_q)));

    //Threshold address formula.
    //One cycle after thr_addr_we, thr_rd_addr must equal the pass counter.
    property p_thr_addr_formula;
        @(posedge clk) disable iff (rst)
        thr_addr_we |=> (thr_rd_addr == THR_ADDR_W'($past(DUT.pass_cnt_r_q)));
    endproperty
    assert property (p_thr_addr_formula)
    else $error("[SVA] FAIL: thr_rd_addr=%0d expected=%0d",
                thr_rd_addr, THR_ADDR_W'($past(DUT.pass_cnt_r_q)));

    //last_pass and valid_np_count consistency.
    //Whenever last_pass is asserted, valid_np_count must equal LAST_PASS_COUNT.
    //Covers [H4]: partial-tail semantics must be consistent pair.
    property p_last_pass_vnp_consistent;
        @(posedge clk) disable iff (rst)
        last_pass |-> (valid_np_count == NP_CNT_W'(LAST_PASS_COUNT));
    endproperty
    assert property (p_last_pass_vnp_consistent)
    else $error("[SVA] FAIL: last_pass=1 but valid_np_count=%0d != LAST_PASS_COUNT=%0d",
                valid_np_count, LAST_PASS_COUNT);

    //Covergroups

    //cg_strobes: Every strobe must fire at least once (bin 1 hit).
    //Crosses verify: (iter_we=1, iter_clr=1) for the legal clear path, and
    //(iter_tc=1, pass_tc=1) for the end-of-image event.
    covergroup cg_strobes @(posedge clk);
        cp_iter_we  : coverpoint iter_we;
        cp_iter_clr : coverpoint iter_clr;
        cp_pass_we  : coverpoint pass_we;
        cp_pass_clr : coverpoint pass_clr;
        cp_wt_we    : coverpoint wt_addr_we;
        cp_thr_we   : coverpoint thr_addr_we;
        cp_vnp_we   : coverpoint vnp_we;
        cp_iter_tc  : coverpoint iter_tc;
        cp_pass_tc  : coverpoint pass_tc;
        cp_last_p   : coverpoint last_pass;

        //Legal (we=1,clr=1) and legal (we=1,clr=0) and idle (we=0,clr=0).
        //The illegal (we=0,clr=1) bin exists but should never fire in
        //production; assertion enforces this constraint.
        x_iter_we_clr : cross cp_iter_we, cp_iter_clr;
        x_pass_we_clr : cross cp_pass_we, cp_pass_clr;

        //End-of-image: both TCs must assert in the same run.
        x_tc : cross cp_iter_tc, cp_pass_tc;
    endgroup

    //cg_addr: Weight address coverage, sampled only when wt_addr_we fires.
    //Bins collapse cleanly for tiny geometries so degenerate sweeps stay legal
    //without out-of-range coercion warnings.
    covergroup cg_addr @(posedge clk iff wt_addr_we);
        cp_wt_addr : coverpoint wt_rd_addr {
            bins low  = {[0:WT_LOW_HI]};
            bins mid  = {[WT_MID_LO:WT_MID_HI]};
            bins high = {[WT_HIGH_LO:WT_HIGH_HI]};
        }
    endgroup

    cg_strobes cg_str = new();
    cg_addr    cg_adr = new();

    //Scoreboard
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

    //Reset task
    task automatic reset_dut(int cycles = 10);
        // Deassert every strobe first so DUT starts clean.
        rst <= 1'b1;
        iter_we <= 1'b0;  iter_clr <= 1'b0;
        pass_we <= 1'b0;  pass_clr <= 1'b0;
        wt_addr_we <= 1'b0;  thr_addr_we <= 1'b0;  vnp_we <= 1'b0;
        repeat (cycles) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //Canonical strobe driver — mimics bnn_layer_ctrl FSM output
    //  For each pass p=0..PASSES-1:
    //  1. thr_addr_we (1 cycle)
    //  2. For each iter i=0..ITERS-1:
    //       wt_addr_we + iter_we in same cycle
    //       iter_clr=1 only at last iteration of pass
    //  3. vnp_we + pass_we in same cycle (STATE.md §4.3)
    //       pass_clr=1 at last pass
    //   After this task, both counters are back at 0 (pass_clr + iter_clr
    //on the final iteration/pass resets them).
    task automatic drive_canonical_run();
        for (int p = 0; p < PASSES; p++) begin
            //Load threshold address for this pass
            @(posedge clk);
            thr_addr_we <= 1'b1;
            @(posedge clk);
            thr_addr_we <= 1'b0;

            //Iterate — latch weight address and advance iter counter
            for (int i = 0; i < ITERS; i++) begin
                @(posedge clk);
                //wt_addr_we and iter_we co-assert: matches RUN_ITER FSM
                //behavior. The exported address is the NEXT iteration's
                //prefetched read address.
                wt_addr_we <= 1'b1;
                iter_we    <= 1'b1;
                iter_clr   <= (i == ITERS - 1) ? 1'b1 : 1'b0;
                @(posedge clk);
                wt_addr_we <= 1'b0;
                iter_we    <= 1'b0;
                iter_clr   <= 1'b0;
            end

            //End of pass: update vnp and advance pass counter.
            //vnp_we fires in the SAME cycle as pass_we per STATE.md §4.3.
            @(posedge clk);
            vnp_we   <= 1'b1;
            pass_we  <= 1'b1;
            pass_clr <= (p == PASSES - 1) ? 1'b1 : 1'b0;
            @(posedge clk);
            vnp_we   <= 1'b0;
            pass_we  <= 1'b0;
            pass_clr <= 1'b0;
        end
        repeat (5) @(posedge clk);
    endtask

    // Post-reset output values
    task automatic test_t01_reset_values();
        $display("[TEST] T01: Post-reset output values");
        reset_dut(10);
        @(posedge clk);
        check("T01_wt_zero",    wt_rd_addr    == '0,
              $sformatf("wt_rd_addr=%0d", wt_rd_addr));
        check("T01_thr_zero",   thr_rd_addr   == '0,
              $sformatf("thr_rd_addr=%0d", thr_rd_addr));
        check("T01_vnp_P_N",    valid_np_count == NP_CNT_W'(P_N),
              $sformatf("valid_np_count=%0d expected=%0d", valid_np_count, P_N));
        check("T01_lp_zero",    last_pass == 1'b0,
              $sformatf("last_pass=%0b", last_pass));
        // iter_tc is combinational; at iter_cnt=0 it is 1 only if ITERS==1
        check("T01_iter_tc",    iter_tc == (ITERS == 1 ? 1'b1 : 1'b0),
              $sformatf("iter_tc=%0b ITERS=%0d", iter_tc, ITERS));
    endtask

    //
    // T02 — Drive iter_we until iter_tc fires; verify exact boundary
    //
    task automatic test_t02_iter_tc();
        logic saw_tc;
        $display("[TEST] T02: iter_tc fires exactly at ITERS-1 = %0d", ITERS-1);
        reset_dut();
        saw_tc = 1'b0;

        if (ITERS == 1) begin
            check("T02_iter_tc_degenerate", iter_tc == 1'b1,
                  "iter_tc must be high immediately when ITERS==1");
            saw_tc = 1'b1;
        end

        //Step counter from 0 to ITERS-1 without clearing so the
        //terminal condition fires at exactly iter_cnt == ITERS-1.
        for (int i = 0; i < ITERS; i++) begin
            @(posedge clk);
            iter_we <= 1'b1;
            @(posedge clk);
            iter_we <= 1'b0;
            //After advancing, iter_cnt == i+1 (mod ITERS_width).
            //iter_tc is combinational: fires when iter_cnt == ITERS-1.
            @(posedge clk);
            if (DUT.iter_cnt_r_q == ITER_W'(ITERS-1)) begin
                check("T02_iter_tc_at_boundary", iter_tc == 1'b1,
                      $sformatf("Expected iter_tc=1 at iter=%0d", ITERS-1));
                saw_tc = 1'b1;
            end
        end

        check("T02_iter_tc_seen", saw_tc == 1'b1, "iter_tc never asserted");
    endtask

    //
    // T03 — Full canonical run: address formula and pass_tc verified end-to-end
    //
    task automatic test_t03_full_run();
        logic saw_pass_tc;
        int   timeout_cnt;
        $display("[TEST] T03: Full canonical run — wt_rd_addr and pass_tc");
        reset_dut();
        saw_pass_tc = 1'b0;

        // Fork: run the driver and in parallel watch for pass_tc.
        fork
            drive_canonical_run();
            begin : watch_pass_tc
                timeout_cnt = 0;
                while (timeout_cnt < (ITERS + 3) * PASSES * 2) begin
                    @(posedge clk);
                    timeout_cnt++;
                    if (pass_tc) begin
                        saw_pass_tc = 1'b1;
                        break;
                    end
                end
            end
        join

        check("T03_pass_tc_seen", saw_pass_tc,
              "pass_tc never asserted during full run");

        // After the run both counters must have wrapped back to 0 via *_clr.
        @(posedge clk);
        check("T03_iter_cnt_zero", DUT.iter_cnt_r_q == '0,
              $sformatf("iter_cnt=%0d after run", DUT.iter_cnt_r_q));
        check("T03_pass_cnt_zero", DUT.pass_cnt_r_q == '0,
              $sformatf("pass_cnt=%0d after run", DUT.pass_cnt_r_q));
        // The shadow checker verifies the address formula on every cycle.
        // shadow_fail_cnt will be non-zero if any mismatch occurred.
        check("T03_shadow_clean", shadow_fail_cnt == 0,
              $sformatf("shadow mismatch count=%0d", shadow_fail_cnt));
    endtask

    
    // T05 — iter_clr AND iter_we: counter must load 0
    task automatic test_t05_clr_with_we();
        $display("[TEST] T05: iter_clr AND iter_we — counter loads 0");
        reset_dut();
        // Advance to non-zero state
        repeat (3) begin
            @(posedge clk); iter_we <= 1'b1;
            @(posedge clk); iter_we <= 1'b0;
        end
        // Now assert both signals in the same cycle
        @(posedge clk);
        iter_we  <= 1'b1;
        iter_clr <= 1'b1;
        @(posedge clk);
        iter_we  <= 1'b0;
        iter_clr <= 1'b0;
        @(posedge clk);
        check("T05_iter_zero_after_clr_we", DUT.iter_cnt_r_q == '0,
              $sformatf("iter_cnt=%0d expected 0", DUT.iter_cnt_r_q));
    endtask

    // T06 — vnp_we at every pass boundary: valid_np_count and last_pass correct
    // Drives the full PASSES sequence one pass at a time and checks
    // valid_np_count / last_pass after each vnp_we strobe.
    task automatic test_t06_vnp_sequence();
        $display("[TEST] T06: vnp_we at pass boundaries — VNP=%0d LPC=%0d PASSES=%0d",
                 P_N, LAST_PASS_COUNT, PASSES);
        reset_dut();

        for (int p = 0; p < PASSES; p++) begin
            @(posedge clk); thr_addr_we <= 1'b1;
            @(posedge clk); thr_addr_we <= 1'b0;

            for (int i = 0; i < ITERS; i++) begin
                @(posedge clk);
                wt_addr_we <= 1'b1; iter_we <= 1'b1;
                iter_clr   <= (i == ITERS-1);
                @(posedge clk);
                wt_addr_we <= 1'b0; iter_we <= 1'b0;
                iter_clr   <= 1'b0;
            end

            //vnp_we and pass_we co-assert (STATE.md §4.3)
            @(posedge clk);
            vnp_we   <= 1'b1;
            pass_we  <= 1'b1;
            pass_clr <= (p == PASSES-1);
            @(posedge clk);
            vnp_we   <= 1'b0;
            pass_we  <= 1'b0;
            pass_clr <= 1'b0;

            //One cycle later: registered outputs have been updated
            @(posedge clk);
            if (p == PASSES - 1) begin
                check($sformatf("T06_last_pass_p%0d", p), last_pass == 1'b1,
                      $sformatf("last_pass=%0b expected 1", last_pass));
                check($sformatf("T06_vnp_lpc_p%0d", p),
                      valid_np_count == NP_CNT_W'(LAST_PASS_COUNT),
                      $sformatf("vnp=%0d expected %0d", valid_np_count, LAST_PASS_COUNT));
            end else begin
                check($sformatf("T06_last_pass_clear_p%0d", p), last_pass == 1'b0,
                      $sformatf("last_pass=%0b expected 0", last_pass));
                check($sformatf("T06_vnp_P_N_p%0d", p),
                      valid_np_count == NP_CNT_W'(P_N),
                      $sformatf("vnp=%0d expected %0d (P_N)", valid_np_count, P_N));
            end
        end
    endtask

    // LAST_PASS_COUNT == P_N when NUM_NEURONS % P_N == 0
    //(geometry-conditional: skip if REMAINDER != 0)
    task automatic test_t07_full_pass_no_remainder();
        $display("[test] LAST_PASS_COUNT==P_N when remainder==0");
        if (REMAINDER != 0) begin
            $display("[test] SKIPPED (REMAINDER=%0d ≠ 0 for this geometry)", REMAINDER);
            pass_count++;  // count as implicit pass (skip)
            return;
        end
        check("T07_lpc_eq_pn",
              LAST_PASS_COUNT == P_N,
              $sformatf("LAST_PASS_COUNT=%0d P_N=%0d", LAST_PASS_COUNT, P_N));
        // Run a full cycle and verify the shadow stays consistent (shadow_fail_cnt).
        reset_dut();
        drive_canonical_run();
        check("T07_shadow_clean", shadow_fail_cnt == 0,
              $sformatf("shadow mismatches=%0d", shadow_fail_cnt));
    endtask

    // T08 — Degenerate single-pass geometry: last_pass must assert on first vnp_we
    // (geometry-conditional: skip if PASSES != 1)
    task automatic test_t08_single_pass();
        $display("[test] Single-pass geometry (PASSES=%0d)", PASSES);
        if (PASSES != 1) begin
            $display("[test] SKIPPED (PASSES=%0d ≠ 1)", PASSES);
            pass_count++;
            return;
        end
        reset_dut();
        @(posedge clk); thr_addr_we <= 1'b1;
        @(posedge clk); thr_addr_we <= 1'b0;

        for (int i = 0; i < ITERS; i++) begin
            @(posedge clk);
            wt_addr_we <= 1'b1; iter_we <= 1'b1;
            iter_clr   <= (i == ITERS-1);
            @(posedge clk);
            wt_addr_we <= 1'b0; iter_we <= 1'b0;
            iter_clr   <= 1'b0;
        end

        @(posedge clk);
        vnp_we  <= 1'b1; pass_we <= 1'b1; pass_clr <= 1'b1;
        @(posedge clk);
        vnp_we  <= 1'b0; pass_we <= 1'b0; pass_clr <= 1'b0;
        @(posedge clk);

        check("T08_last_pass_on_first_vnp", last_pass == 1'b1,
              $sformatf("last_pass=%0b expected 1 for PASSES=1", last_pass));
        check("T08_vnp_lpc", valid_np_count == NP_CNT_W'(LAST_PASS_COUNT),
              $sformatf("vnp=%0d expected=%0d", valid_np_count, LAST_PASS_COUNT));
    endtask

    // T09 — Reset mid-counting: all state returns to reset values
    task automatic test_t09_reset_mid_run();
        $display("[TEST] T09: Reset mid-counting");
        reset_dut();

        //Advance counters to non-zero state
        repeat (3) begin
            @(posedge clk); iter_we <= 1'b1;
            @(posedge clk); iter_we <= 1'b0;
        end
        @(posedge clk); pass_we <= 1'b1;
        @(posedge clk); pass_we <= 1'b0;
        @(posedge clk); vnp_we  <= 1'b1;
        @(posedge clk); vnp_we  <= 1'b0;

        //Assert reset mid-flight
        rst <= 1'b1;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        check("T09_iter_zero",  DUT.iter_cnt_r_q == '0, "iter not 0 after reset");
        check("T09_pass_zero",  DUT.pass_cnt_r_q == '0, "pass not 0 after reset");
        check("T09_wt_zero",    wt_rd_addr  == '0,      "wt_rd_addr not 0");
        check("T09_thr_zero",   thr_rd_addr == '0,      "thr_rd_addr not 0");
        check("T09_vnp_pn",     valid_np_count == NP_CNT_W'(P_N),
              $sformatf("vnp=%0d expected P_N=%0d", valid_np_count, P_N));
        check("T09_lp_zero",    last_pass == 1'b0,      "last_pass not 0");
    endtask

    // T10 — Random strobe stress (constrained: no clr without we)
    // Fires random strobe combinations for 10000 cycles.  The shadow model
    // and SVAs continuously verify correctness.  Pass criterion: zero shadow
    // mismatches and zero SVA violations.

    task automatic test_t10_random_stress();
        int n = `SAG_TB_RANDOM_CYCLES;
        logic next_iter_we;
        logic next_iter_clr;
        logic next_pass_we;
        logic next_pass_clr;
        logic next_wt_addr_we;
        logic next_thr_addr_we;
        logic next_vnp_we;
        $display("[test] Random strobe stress (%0d cycles)", n);
        reset_dut();
        for (int c = 0; c < n; c++) begin
            @(posedge clk);
            //~25% probability per strobe, clr only fires alongside we
            next_iter_we     = ($urandom_range(0,3) == 0);
            next_pass_we     = ($urandom_range(0,3) == 0);
            next_iter_clr    = next_iter_we && ($urandom_range(0,3) == 0);
            next_pass_clr    = next_pass_we && ($urandom_range(0,3) == 0);
            next_wt_addr_we  = ($urandom_range(0,3) == 0);
            next_thr_addr_we = ($urandom_range(0,5) == 0);
            next_vnp_we      = ($urandom_range(0,5) == 0);

            iter_we     <= next_iter_we;
            iter_clr    <= next_iter_clr;
            pass_we     <= next_pass_we;
            pass_clr    <= next_pass_clr;
            wt_addr_we  <= next_wt_addr_we;
            thr_addr_we <= next_thr_addr_we;
            vnp_we      <= next_vnp_we;
        end
        @(posedge clk);
        iter_we <= 1'b0; iter_clr <= 1'b0;
        pass_we <= 1'b0; pass_clr <= 1'b0;
        wt_addr_we <= 1'b0; thr_addr_we <= 1'b0; vnp_we <= 1'b0;
        repeat (5) @(posedge clk);
        check("T10_shadow_clean", shadow_fail_cnt == 0,
              $sformatf("shadow mismatches=%0d after random stress", shadow_fail_cnt));
    endtask

    //Main test sequence
    initial begin
        $display("=====================================================");
        $display(" tb_bnn_seq_addr_gen — Level-0 Primitive TB");
        $display(" P_W=%0d P_N=%0d FAN_IN=%0d NUM_NEURONS=%0d",
                 P_W, P_N, FAN_IN, NUM_NEURONS);
        $display(" ITERS=%0d PASSES=%0d LAST_PASS_COUNT=%0d",
                 ITERS, PASSES, LAST_PASS_COUNT);
        $display(" RANDOM_STRESS_CYCLES=%0d", `SAG_TB_RANDOM_CYCLES);
        $display("=====================================================");

        test_t01_reset_values();
        reset_dut();
        test_t02_iter_tc();
        reset_dut();
        test_t03_full_run();
        reset_dut();
        test_t05_clr_with_we();
        reset_dut();
        test_t06_vnp_sequence();
        reset_dut();
        test_t07_full_pass_no_remainder();
        reset_dut();
        test_t08_single_pass();
        reset_dut();
        test_t09_reset_mid_run();
        reset_dut();
        test_t10_random_stress();

        repeat (20) @(posedge clk);

        $display("");
        $display("=====================================================");
        $display(" SCOREBOARD SUMMARY — tb_bnn_seq_addr_gen");
        $display("=====================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        $display("  Shadow fails : %0d", shadow_fail_cnt);
        if (fail_count > 0) begin
            $display("  --- Failures ---");
            foreach (fail_log[i]) $display("    %s", fail_log[i]);
        end
        $display("  Strobes CG   : %.1f%%", cg_str.get_coverage());
        $display("  Addr CG      : %.1f%%", cg_adr.get_coverage());
        $display("=====================================================");
        if (fail_count == 0 && shadow_fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d DIRECTED + %0d SHADOW FAILURE(S) ***",
                     fail_count, shadow_fail_cnt);
        $display("=====================================================");

        $finish;
    end

endmodule
