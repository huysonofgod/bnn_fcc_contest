`timescale 1ns/100ps

module bnn_dp_ram_tb;

    parameter int WIDTH  = 8;
    parameter int DEPTH  = 32;
    parameter int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    logic               clk = 0;
    logic               rst = 1;
    logic               wr_en;
    logic [ADDR_W-1:0]  wr_addr;
    logic [WIDTH-1:0]   wr_data;
    logic               rd_en;
    logic [ADDR_W-1:0]  rd_addr;
    logic [WIDTH-1:0]   rd_data;

    always #5 clk = ~clk;

    bnn_dp_ram #(
        .WIDTH      (WIDTH),
        .DEPTH      (DEPTH),
        .OUTPUT_REG (0),
        .MEM_STYLE  ("block")
    ) DUT (
        .clk     (clk),
        .rst     (rst),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    logic               wr_en_1;
    logic [ADDR_W-1:0]  wr_addr_1;
    logic [WIDTH-1:0]   wr_data_1;
    logic               rd_en_1;
    logic [ADDR_W-1:0]  rd_addr_1;
    logic [WIDTH-1:0]   rd_data_1;

    bnn_dp_ram #(
        .WIDTH      (WIDTH),
        .DEPTH      (DEPTH),
        .OUTPUT_REG (1),
        .MEM_STYLE  ("distributed")
    ) DUT1 (
        .clk     (clk),
        .rst     (rst),
        .wr_en   (wr_en_1),
        .wr_addr (wr_addr_1),
        .wr_data (wr_data_1),
        .rd_en   (rd_en_1),
        .rd_addr (rd_addr_1),
        .rd_data (rd_data_1)
    );

    logic [WIDTH-1:0] golden_mem [DEPTH];

    //
    // Functional coverage
    //
    logic rd_en_d_q;
    always_ff @(posedge clk) begin
        if (rst) rd_en_d_q <= 1'b0;
        else     rd_en_d_q <= rd_en;
    end

    covergroup cg_functional @(posedge clk iff (!rst));
        cp_wr_addr: coverpoint wr_addr iff (wr_en) {
            bins lo  = {0};
            bins mid = {[1:DEPTH-2]};
            bins hi  = {DEPTH-1};
        }
        cp_rd_addr: coverpoint rd_addr iff (rd_en) {
            bins lo  = {0};
            bins mid = {[1:DEPTH-2]};
            bins hi  = {DEPTH-1};
        }
        cp_controls: coverpoint {wr_en, rd_en} {
            bins idle       = {2'b00};
            bins write_only = {2'b10};
            bins read_only  = {2'b01};
            bins both       = {2'b11};
        }
        cp_rd_gated: coverpoint {rd_en, rd_en_d_q} iff (!rst) {
            bins en_to_dis  = {2'b01};
            bins dis_to_en  = {2'b10};
            bins continuous = {2'b11};
        }
        cx_dual_port: cross cp_wr_addr, cp_rd_addr, cp_controls {
            ignore_bins no_op = binsof(cp_controls.idle);
        }
    endgroup
    cg_functional cg_inst = new();

    //
    // Scoreboard
    //
    int pass_count = 0;
    int fail_count = 0;
    int test_count = 0;

    task automatic check(input string label,
                         input logic [WIDTH-1:0] expected,
                         input logic [WIDTH-1:0] actual);
        test_count++;
        if (actual === expected) pass_count++;
        else begin
            fail_count++;
            $error("[FAIL] %s: expected=0x%0h actual=0x%0h", label, expected, actual);
        end
    endtask

    //
    // SVAs (white-box)
    //
    property p_wr_addr_in_range;
        @(posedge clk) disable iff (rst) wr_en |-> (wr_addr < DEPTH);
    endproperty
    a_wr_addr_in_range: assert property (p_wr_addr_in_range)
        else $error("SVA A1: wr_addr=%0d out of range", wr_addr);

    property p_rd_addr_in_range;
        @(posedge clk) disable iff (rst) rd_en |-> (rd_addr < DEPTH);
    endproperty
    a_rd_addr_in_range: assert property (p_rd_addr_in_range)
        else $error("SVA A2: rd_addr=%0d out of range", rd_addr);

    property p_wr_data_no_x;
        @(posedge clk) disable iff (rst) wr_en |-> !$isunknown(wr_data);
    endproperty
    a_wr_data_no_x: assert property (p_wr_data_no_x)
        else $error("SVA A3: wr_data contains X when wr_en asserted");

    //
    // Reset task
    //
    task automatic reset_dut();
        @(posedge clk);
        rst       <= 1'b1;
        wr_en     <= 1'b0;
        wr_addr   <= '0;
        wr_data   <= '0;
        rd_en     <= 1'b0;
        rd_addr   <= '0;
        wr_en_1   <= 1'b0;
        wr_addr_1 <= '0;
        wr_data_1 <= '0;
        rd_en_1   <= 1'b0;
        rd_addr_1 <= '0;
        foreach (golden_mem[i]) golden_mem[i] = '0;
        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //
    // Helpers — DUT 0
    //
    // Drive a single write (1 cycle drive), then idle cycle.
    task automatic do_write(input logic [ADDR_W-1:0] a, input logic [WIDTH-1:0] d);
        @(posedge clk);
        wr_en   <= 1'b1;
        wr_addr <= a;
        wr_data <= d;
        rd_en   <= 1'b0;
        golden_mem[a] = d;
        @(posedge clk);
        wr_en <= 1'b0;
    endtask

    // Drive a single read, wait enough edges, check result.
    task automatic do_read_check(input string label,
                                 input logic [ADDR_W-1:0] a,
                                 input logic [WIDTH-1:0] expected);
        @(posedge clk);
        rd_en   <= 1'b1;
        rd_addr <= a;
        wr_en   <= 1'b0;
        @(posedge clk); // DUT latches stage1 <= mem[a] in NBA
        @(posedge clk); // now TB sees rd_data = mem[a]
        check(label, expected, rd_data);
        rd_en <= 1'b0;
    endtask

    //
    // Main Test Sequence
    //
    initial begin : main_test
        logic [WIDTH-1:0] v;
        logic [WIDTH-1:0] held_val;

        $timeformat(-9, 0, " ns", 0);
        $display("============================================");
        $display("  bnn_dp_ram Testbench (CRV)");
        $display("  WIDTH=%0d  DEPTH=%0d", WIDTH, DEPTH);
        $display("============================================");

        reset_dut();

        //
        // DT1: write_then_read_same_addr
        //
        $display("[DT1] write_then_read_same_addr - start");
        begin
            v = 8'hA5;
            do_write(5'd3, v);
            do_read_check("DT1_read_after_write", 5'd3, v);
        end
        $display("[DT1] done");

        //
        // DT2: write_walk_address_space + readback
        //
        $display("[DT2] write_walk_address_space - start");
        begin
            for (int a = 0; a < DEPTH; a++) begin
                v = $urandom();
                @(posedge clk);
                wr_en   <= 1'b1;
                wr_addr <= a[ADDR_W-1:0];
                wr_data <= v;
                rd_en   <= 1'b0;
                golden_mem[a] = v;
            end
            @(posedge clk);
            wr_en <= 1'b0;
            @(posedge clk);

            for (int a = 0; a < DEPTH; a++) begin
                do_read_check($sformatf("DT2_addr%0d", a),
                              a[ADDR_W-1:0], golden_mem[a]);
            end
        end
        $display("[DT2] done");

        //
        // DT3: interleaved write-read different addresses (pipelined)
        //   drive (wr=i, rd=DEPTH-1-i) each cycle. Expected rd = golden[rd_a]
        //   at drive time (pre-update), since (a) same-cycle w-r-to-same-addr
        //   gives old data, and (b) writes happen at wr_a != rd_a.
        //   Actual rd_data is visible 2 edges after drive.
        //
        $display("[DT3] interleaved_write_read - start");
        begin
            // Sliding pipe of depth 2
            logic [WIDTH-1:0] exp_q [0:1];
            logic             exp_v [0:1];
            int rd_a;
            exp_q[0] = '0; exp_q[1] = '0;
            exp_v[0] = 0;  exp_v[1] = 0;

            for (int i = 0; i < DEPTH; i++) begin
                rd_a = DEPTH - 1 - i;
                v    = $urandom();
                @(posedge clk);
                wr_en   <= 1'b1;
                wr_addr <= i[ADDR_W-1:0];
                wr_data <= v;
                rd_en   <= 1'b1;
                rd_addr <= rd_a[ADDR_W-1:0];

                // Check the oldest pipe slot (drove 2 iters ago)
                if (exp_v[1])
                    check($sformatf("DT3_iter%0d", i-2), exp_q[1], rd_data);

                // Shift pipe
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_q[0] = golden_mem[rd_a]; exp_v[0] = 1;
                // Now update golden for the write
                golden_mem[i] = v;
            end
            // Drain — 2 more edges to flush the pipe
            for (int d = 0; d < 2; d++) begin
                @(posedge clk);
                wr_en <= 1'b0;
                rd_en <= 1'b0;
                if (exp_v[1])
                    check($sformatf("DT3_drain%0d", d), exp_q[1], rd_data);
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_v[0] = 0;
            end
            @(posedge clk);
        end
        $display("[DT3] done");

        //
        // DT4: back-to-back reads (no writes)
        //
        $display("[DT4] back_to_back_reads - start");
        begin
            logic [WIDTH-1:0] exp_q [0:1];
            logic             exp_v [0:1];
            exp_q[0] = '0; exp_q[1] = '0;
            exp_v[0] = 0;  exp_v[1] = 0;

            for (int a = 0; a < DEPTH; a++) begin
                @(posedge clk);
                wr_en   <= 1'b0;
                rd_en   <= 1'b1;
                rd_addr <= a[ADDR_W-1:0];

                if (exp_v[1])
                    check($sformatf("DT4_b2b_addr%0d", a-2), exp_q[1], rd_data);

                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_q[0] = golden_mem[a]; exp_v[0] = 1;
            end
            for (int d = 0; d < 2; d++) begin
                @(posedge clk);
                rd_en <= 1'b0;
                if (exp_v[1])
                    check($sformatf("DT4_b2b_drain%0d", d), exp_q[1], rd_data);
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_v[0] = 0;
            end
            @(posedge clk);
        end
        $display("[DT4] done");

        //
        // DT5: rd_en gated — output must hold previous value
        //
        $display("[DT5] rd_en_gated - start");
        begin
            // Load rd_data with golden_mem[0]
            @(posedge clk);
            rd_en   <= 1'b1;
            rd_addr <= '0;
            wr_en   <= 1'b0;
            @(posedge clk);   // DUT latches
            @(posedge clk);   // rd_data visible
            held_val = golden_mem[0];
            check("DT5_initial_load", held_val, rd_data);

            // Drop rd_en, verify hold for 8 cycles
            @(posedge clk);
            rd_en <= 1'b0;
            for (int g = 0; g < 8; g++) begin
                @(posedge clk);
                check($sformatf("DT5_hold_%0d", g), held_val, rd_data);
            end
        end
        $display("[DT5] done");

        //
        // DT6: max value at max addr
        //
        $display("[DT6] max_value_at_max_addr - start");
        begin
            v = {WIDTH{1'b1}};
            do_write((DEPTH-1), v);
            do_read_check("DT6_max_at_max", (DEPTH-1), v);
        end
        $display("[DT6] done");

        //
        // DT10: random stress
        //
        $display("[DT10] random_stress - start");
        begin
            logic [WIDTH-1:0] exp_q [0:1];
            logic             exp_v [0:1];
            logic [WIDTH-1:0] last_rd_val;
            int               r_wr, r_rd;
            logic [ADDR_W-1:0] r_wa, r_ra;

            exp_q[0] = '0; exp_q[1] = '0;
            exp_v[0] = 0;  exp_v[1] = 0;
            last_rd_val = '0;

            for (int r = 0; r < 200; r++) begin
                r_wr = $urandom_range(0, 1);
                r_rd = $urandom_range(0, 1);
                r_wa = $urandom_range(0, DEPTH-1);
                r_ra = $urandom_range(0, DEPTH-1);
                v    = $urandom();

                @(posedge clk);
                wr_en   <= r_wr[0];
                wr_addr <= r_wa;
                wr_data <= v;
                rd_en   <= r_rd[0];
                rd_addr <= r_ra;

                if (exp_v[1])
                    check($sformatf("DT10_r%0d", r-2), exp_q[1], rd_data);

                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                if (r_rd[0]) begin
                    exp_q[0] = golden_mem[r_ra];
                    last_rd_val = golden_mem[r_ra];
                    exp_v[0] = 1;
                end else begin
                    // rd_en deasserted: stage1 holds; rd_data = last_rd_val
                    exp_q[0] = last_rd_val;
                    exp_v[0] = 1;
                end

                if (r_wr[0]) golden_mem[r_wa] = v;
            end
            for (int d = 0; d < 2; d++) begin
                @(posedge clk);
                wr_en <= 1'b0;
                rd_en <= 1'b0;
                if (exp_v[1])
                    check($sformatf("DT10_drain%0d", d), exp_q[1], rd_data);
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_v[0] = 0;
            end
            @(posedge clk);
        end
        $display("[DT10] done");

        //
        // DT7: reset clears output register
        //
        $display("[DT7] reset_clears_output - start");
        begin
            // Ensure rd_data has something to clear
            @(posedge clk);
            rd_en   <= 1'b1;
            rd_addr <= '0;
            @(posedge clk);
            @(posedge clk);
            rd_en <= 1'b0;
            @(posedge clk);
            // Assert reset
            rst <= 1'b1;
            repeat (3) @(posedge clk);
            check("DT7_rst_clears_out", '0, rd_data);
            rst <= 1'b0;
            repeat (3) @(posedge clk);
        end
        $display("[DT7] done");

        //
        // DT8: memory survives reset
        //
        $display("[DT8] mem_survives_reset - start");
        begin
            do_read_check("DT8_mem_survives_rst", '0, golden_mem[0]);
        end
        $display("[DT8] done");

        //
        // DT9: DUT1 (OUTPUT_REG=1) — 2-cycle read latency
        //   Visible to TB 3 edges after drive.
        //
        $display("[DT9] OUTPUT_REG=1 two_cycle_latency - start");
        begin
            logic [WIDTH-1:0] exp_q [0:2];
            logic             exp_v [0:2];
            exp_q[0] = '0; exp_q[1] = '0; exp_q[2] = '0;
            exp_v[0] = 0;  exp_v[1] = 0;  exp_v[2] = 0;

            // Fill DUT1 with same data as golden_mem
            for (int a = 0; a < DEPTH; a++) begin
                @(posedge clk);
                wr_en_1   <= 1'b1;
                wr_addr_1 <= a[ADDR_W-1:0];
                wr_data_1 <= golden_mem[a];
            end
            @(posedge clk);
            wr_en_1 <= 1'b0;
            @(posedge clk);
            @(posedge clk);

            // Pipelined back-to-back reads with depth-3 pipe
            for (int a = 0; a < DEPTH; a++) begin
                @(posedge clk);
                rd_en_1   <= 1'b1;
                rd_addr_1 <= a[ADDR_W-1:0];

                if (exp_v[2])
                    check($sformatf("DT9_addr%0d", a-3), exp_q[2], rd_data_1);

                exp_q[2] = exp_q[1]; exp_v[2] = exp_v[1];
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_q[0] = golden_mem[a]; exp_v[0] = 1;
            end
            // Drain
            for (int d = 0; d < 3; d++) begin
                @(posedge clk);
                rd_en_1 <= 1'b0;
                if (exp_v[2])
                    check($sformatf("DT9_drain%0d", d), exp_q[2], rd_data_1);
                exp_q[2] = exp_q[1]; exp_v[2] = exp_v[1];
                exp_q[1] = exp_q[0]; exp_v[1] = exp_v[0];
                exp_v[0] = 0;
            end
            @(posedge clk);
        end
        $display("[DT9] done");

        //
        // Final report
        //
        repeat (5) @(posedge clk);
        $display("============================================");
        $display("  Pass: %0d  Fail: %0d  Total: %0d", pass_count, fail_count, test_count);
        $display("  Coverage: %.1f%%", cg_inst.get_coverage());
        if (fail_count == 0)
            $display("  STATUS: *** PASSED ***");
        else
            $display("  STATUS: *** FAILED ***");
        $display("============================================");

        $finish;
    end

    //
    // Safety timeout
    //
    initial begin
        #500000;
        $error("TIMEOUT: simulation exceeded 500 us");
        $finish;
    end

endmodule
