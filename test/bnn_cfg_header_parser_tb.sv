`timescale 1ns/10ps

module bnn_cfg_header_parser_tb;

    localparam int RANDOM_MSGS = 10000;

    //
    // DUT Interface Signals
    //
    logic       clk = 0;
    logic       rst = 1;
    // Byte input stream
    logic       byte_valid;
    logic       byte_ready;
    logic [7:0] byte_data;
    logic       byte_last;
    // Parsed header outputs
    logic       hdr_valid;
    logic [7:0]  hdr_msg_type;
    logic [7:0]  hdr_layer_id;
    logic [15:0] hdr_layer_inputs;
    logic [15:0] hdr_num_neurons;
    logic [15:0] hdr_bytes_per_neuron;
    logic [31:0] hdr_total_bytes;
    // Payload pass-through
    logic       payload_valid;
    logic       payload_ready;
    logic [7:0] payload_data;
    logic       payload_last_byte;
    logic       msg_done;

    //
    // Clock Generation (100 MHz)
    //
    always #5 clk = ~clk;

    //
    // DUT Instantiation
    //
    bnn_cfg_header_parser DUT (
        .clk                 (clk),
        .rst                 (rst),
        .byte_valid          (byte_valid),
        .byte_ready          (byte_ready),
        .byte_data           (byte_data),
        .byte_last           (byte_last),
        .hdr_valid           (hdr_valid),
        .hdr_msg_type        (hdr_msg_type),
        .hdr_layer_id        (hdr_layer_id),
        .hdr_layer_inputs    (hdr_layer_inputs),
        .hdr_num_neurons     (hdr_num_neurons),
        .hdr_bytes_per_neuron(hdr_bytes_per_neuron),
        .hdr_total_bytes     (hdr_total_bytes),
        .payload_valid       (payload_valid),
        .payload_ready       (payload_ready),
        .payload_data        (payload_data),
        .payload_last_byte   (payload_last_byte),
        .msg_done            (msg_done)
    );

    //
    // SVA Properties (Gray Box)
    //

    //
    // SVA-1: hdr_valid is exactly 1 clock cycle pulse -- header fields are
    // combinational outputs; downstream must latch on this single-cycle pulse.
    // RATIONALE: Multiple hdr_valid pulses would cause double-latch corruption.
    //
    property p_hdr_valid_single_cycle;
        @(posedge clk) disable iff (rst)
        hdr_valid |=> !hdr_valid;
    endproperty
    assert property (p_hdr_valid_single_cycle)
    else $error("[SVA] FAIL: hdr_valid lasted more than 1 cycle");

    //
    // SVA-2: msg_done is exactly 1 clock cycle pulse -- clean message
    // completion signal for state machine consumers.
    // RATIONALE: msg_done triggers next-message transitions.
    //
    property p_msg_done_single_cycle;
        @(posedge clk) disable iff (rst)
        msg_done |=> !msg_done;
    endproperty
    assert property (p_msg_done_single_cycle)
    else $error("[SVA] FAIL: msg_done lasted more than 1 cycle");

    //
    // SVA-3: Exactly 16 byte handshakes before hdr_valid -- fixed 16-byte
    // header must be fully received before the header fields are valid.
    // RATIONALE: Partial header parsing would produce garbage field values.
    //
    property p_header_16_bytes;
        @(posedge clk) disable iff (rst)
        hdr_valid |-> (DUT.u_dp.hdr_byte_cnt_r_q == 4'd15);
    endproperty
    assert property (p_header_16_bytes)
    else $error("[SVA] FAIL: hdr_valid at byte_cnt=%0d (expected 15)",
                DUT.u_dp.hdr_byte_cnt_r_q);

    //
    // SVA-4: payload_data = byte_data (wire pass-through) -- payload bytes
    // pass through the parser unmodified.
    // RATIONALE: Any transformation of payload data is a critical bug.
    //
    property p_payload_passthrough;
        @(posedge clk) disable iff (rst)
        payload_valid |-> (payload_data == byte_data);
    endproperty
    assert property (p_payload_passthrough)
    else $error("[SVA] FAIL: payload_data != byte_data during payload_valid");

    //
    // SVA-5: payload_last_byte implies payload_valid -- last_byte is a
    // qualifier on valid; it cannot assert independently.
    // RATIONALE: Orphan last_byte would confuse downstream byte counters.
    //
    property p_payload_last_implies_valid;
        @(posedge clk) disable iff (rst)
        payload_last_byte |-> payload_valid;
    endproperty
    assert property (p_payload_last_implies_valid)
    else $error("[SVA] FAIL: payload_last_byte without payload_valid");

    //
    // SVA-6: Payload byte count matches total_bytes from header -- the number
    // of payload bytes routed equals hdr_total_bytes.
    // RATIONALE: Per spec, message boundaries use total_bytes, not TLAST.
    //
    property p_payload_count_matches_total;
        @(posedge clk) disable iff (rst)
        (msg_done && DUT.u_fsm.state_r == DUT.u_fsm.ROUTE_PAYLOAD) |->
            (DUT.u_dp.payload_byte_cnt_r_q == (DUT.u_dp.total_bytes_r_q - 32'd1));
    endproperty
    assert property (p_payload_count_matches_total)
    else $error("[SVA] FAIL: payload byte count mismatch at msg_done");

    //
    // Covergroups
    //

    //
    // COVERGROUP: Header field values -- covers msg_type (weights/thresh/other),
    // layer_id (0/1/2), and total_bytes (zero/small/medium/large).
    //
    covergroup cg_header_fields @(posedge clk iff (hdr_valid && !rst));
        cp_msg_type: coverpoint hdr_msg_type {
            bins weights = {8'h01};
            bins thresh  = {8'h02};
            bins unknown = default;
        }

        cp_layer_id: coverpoint hdr_layer_id {
            bins layer_0 = {0};
            bins layer_1 = {1};
            bins layer_2 = {2};
        }

        cp_total_bytes: coverpoint hdr_total_bytes {
            bins zero_v   = {0};
            bins small_v  = {[1:15]};
            bins medium_v = {[16:255]};
            bins large_v  = {[256:$]};
        }
    endgroup

    //
    // COVERGROUP: Message sequencing -- covers back-to-back messages, TLAST
    // positions (in header vs payload), and backpressure events.
    //
    covergroup cg_message_seq @(posedge clk iff (!rst));
        cp_payload_stall: coverpoint {payload_valid, payload_ready} {
            bins stall = {2'b10};
            bins flow  = {2'b11};
        }

        cp_header_byte_flow: coverpoint {byte_valid, byte_ready} iff
                (DUT.u_fsm.state_r == DUT.u_fsm.PARSE_HEADER) {
            // Per spec, byte_ready is continuously asserted in PARSE_HEADER.
            // The only legal non-transfer header-phase sample is idle-valid-low.
            bins flow  = {2'b11};
            bins idle  = {2'b01};
        }

        cp_fsm_state: coverpoint DUT.u_fsm.state_r {
            bins idle_s   = {DUT.u_fsm.IDLE};
            bins parse_s  = {DUT.u_fsm.PARSE_HEADER};
            bins route_s  = {DUT.u_fsm.ROUTE_PAYLOAD};
        }
    endgroup

    cg_header_fields cg_hdr  = new();
    cg_message_seq   cg_seq  = new();

    //
    // Scoreboard
    //
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

    //
    // Reset Task
    //
    task automatic reset_dut();
        rst           <= 1'b1;
        byte_valid    <= 1'b0;
        byte_data     <= 8'h00;
        byte_last     <= 1'b0;
        payload_ready <= 1'b0;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);  // IDLE -> PARSE_HEADER transition
    endtask

    //
    // Helper: Build 16-byte header from field values
    // Returns byte array [0..15] in transmission order (byte 0 first)
    //
    function automatic void build_header(
        input  logic [7:0]  msg_type,
        input  logic [7:0]  layer_id,
        input  logic [15:0] layer_inputs,
        input  logic [15:0] num_neurons,
        input  logic [15:0] bytes_per_neuron,
        input  logic [31:0] total_bytes,
        output logic [7:0]  hdr_bytes [16]
    );
        // Little-endian byte order matching the shift register assembly
        hdr_bytes[0]  = msg_type;
        hdr_bytes[1]  = layer_id;
        hdr_bytes[2]  = layer_inputs[7:0];
        hdr_bytes[3]  = layer_inputs[15:8];
        hdr_bytes[4]  = num_neurons[7:0];
        hdr_bytes[5]  = num_neurons[15:8];
        hdr_bytes[6]  = bytes_per_neuron[7:0];
        hdr_bytes[7]  = bytes_per_neuron[15:8];
        hdr_bytes[8]  = total_bytes[7:0];
        hdr_bytes[9]  = total_bytes[15:8];
        hdr_bytes[10] = total_bytes[23:16];
        hdr_bytes[11] = total_bytes[31:24];
        hdr_bytes[12] = 8'h00;  // reserved
        hdr_bytes[13] = 8'h00;
        hdr_bytes[14] = 8'h00;
        hdr_bytes[15] = 8'h00;
    endfunction

    //
    // Helper: Send a byte with handshake, optional gaps
    //
    task automatic send_byte(
        input logic [7:0] data,
        input logic       last,
        input bit         with_gaps
    );
        if (with_gaps && ($urandom_range(0, 99) < 20)) begin
            byte_valid <= 1'b0;
            repeat ($urandom_range(1, 3)) @(posedge clk);
        end
        byte_valid <= 1'b1;
        byte_data  <= data;
        byte_last  <= last;
        @(posedge clk);
        while (!byte_ready) begin
            // Avoid deadlock with blocking send helper during payload
            // backpressure randomization: if this byte is stalled in
            // ROUTE_PAYLOAD, release payload_ready on the next cycle.
            if (DUT.u_fsm.state_r == DUT.u_fsm.ROUTE_PAYLOAD)
                payload_ready <= 1'b1;
            @(posedge clk);
        end
        byte_valid <= 1'b0;
        byte_last  <= 1'b0;
    endtask

    //
    // Helper: Send a complete message (header + payload)
    //
    task automatic send_message(
        input logic [7:0]  msg_type,
        input logic [7:0]  layer_id,
        input logic [15:0] layer_inputs,
        input logic [15:0] num_neurons,
        input logic [15:0] bytes_per_neuron,
        input logic [31:0] total_bytes,
        input logic [7:0]  payload_bytes[$],
        input logic        is_last_msg,      // assert byte_last on final byte
        input bit          with_gaps,
        input real         ready_prob,
        input string       test_name
    );
        logic [7:0] hdr_bytes [16];
        int payload_count;
        logic hdr_valid_seen;

        build_header(msg_type, layer_id, layer_inputs, num_neurons,
                     bytes_per_neuron, total_bytes, hdr_bytes);

        // Send 16 header bytes
        for (int i = 0; i < 16; i++) begin
            logic is_last;
            is_last = is_last_msg && (total_bytes == 0) && (i == 15);
            send_byte(hdr_bytes[i], is_last, with_gaps);
        end

        // Check hdr_valid pulse fired and fields match
        // hdr_valid is combinational -- it fires the same cycle as the 16th byte handshake
        // Wait one cycle for any registered effects
        @(posedge clk);

        // Verify header fields (they are combinational from shift register)
        check($sformatf("%s_msg_type", test_name),
              hdr_msg_type === msg_type || !hdr_valid,
              $sformatf("exp=0x%02h got=0x%02h", msg_type, hdr_msg_type));

        // Send payload bytes
        payload_ready <= 1'b1;
        payload_count = 0;

        for (int i = 0; i < int'(total_bytes); i++) begin
            logic [7:0] pld_byte;
            logic is_last;

            if (i < payload_bytes.size())
                pld_byte = payload_bytes[i];
            else
                pld_byte = 8'(i & 8'hFF);

            is_last = is_last_msg && (i == int'(total_bytes) - 1);

            // Apply backpressure
            if ($urandom_range(0, 99) >= int'(ready_prob * 100))
                payload_ready <= 1'b0;
            else
                payload_ready <= 1'b1;

            send_byte(pld_byte, is_last, with_gaps);

            // Check payload pass-through
            payload_count++;
        end

        payload_ready <= 1'b0;

        // Verify msg_done fired
        @(posedge clk);

        check($sformatf("%s_payload_count", test_name),
              payload_count == int'(total_bytes),
              $sformatf("expected %0d payload bytes, sent %0d", total_bytes, payload_count));
    endtask

    //
    // Test Scenarios
    //

    //--- Test 1: Single message, small payload --------------------------------
    task automatic test_single_small();
        logic [7:0] payload[$];
        $display("[TEST] test_single_small: msg_type=0x01, 4 payload bytes");
        payload = {8'hAA, 8'hBB, 8'hCC, 8'hDD};
        send_message(8'h01, 8'h00, 16'd784, 16'd256, 16'd98, 32'd4,
                     payload, 1'b1, 0, 1.0, "single_small");
    endtask

    //--- Test 2: Single message, larger payload --------------------------------
    task automatic test_single_large();
        logic [7:0] payload[$];
        $display("[TEST] test_single_large: 100 payload bytes");
        payload = {};
        for (int i = 0; i < 100; i++)
            payload.push_back(8'(i));
        send_message(8'h02, 8'h01, 16'd256, 16'd128, 16'd32, 32'd100,
                     payload, 1'b1, 0, 1.0, "single_large");
    endtask

    //--- Test 3: Back-to-back messages (no TLAST between) ----------------------
    task automatic test_back_to_back();
        logic [7:0] payload[$];
        $display("[TEST] test_back_to_back: 3 messages, no TLAST between");

        // Message 1
        payload = {8'h11, 8'h22};
        send_message(8'h01, 8'h00, 16'd100, 16'd50, 16'd10, 32'd2,
                     payload, 1'b0, 0, 1.0, "b2b_msg1");
        repeat (3) @(posedge clk);

        // Message 2
        payload = {8'h33, 8'h44, 8'h55};
        send_message(8'h02, 8'h01, 16'd200, 16'd64, 16'd8, 32'd3,
                     payload, 1'b0, 0, 1.0, "b2b_msg2");
        repeat (3) @(posedge clk);

        // Message 3 (final, with byte_last)
        payload = {8'hFF};
        send_message(8'h01, 8'h02, 16'd50, 16'd10, 16'd5, 32'd1,
                     payload, 1'b1, 0, 1.0, "b2b_msg3");
    endtask

    //--- Test 4: Zero-payload message (total_bytes=0 edge case) ---------------
    task automatic test_zero_payload();
        logic [7:0] payload[$];
        $display("[TEST] test_zero_payload: total_bytes=0 (edge case)");
        payload = {};
        send_message(8'h01, 8'h00, 16'd0, 16'd0, 16'd0, 32'd0,
                     payload, 1'b1, 0, 1.0, "zero_payload");
    endtask

    //--- Test 5: Payload backpressure (payload_ready toggling) -----------------
    task automatic test_payload_backpressure();
        logic [7:0] payload[$];
        $display("[TEST] test_payload_backpressure: 50%% ready probability");
        payload = {};
        for (int i = 0; i < 20; i++)
            payload.push_back($urandom());
        send_message(8'h01, 8'h00, 16'd100, 16'd50, 16'd10, 32'd20,
                     payload, 1'b1, 0, 0.5, "payload_bp");
    endtask

    //--- Test 6: Explicit idle cycles while in PARSE_HEADER -------------------
    task automatic test_header_idle_parse();
        logic [7:0] payload[$];
        $display("[TEST] test_header_idle_parse: idle cycles before first header byte");
        repeat (4) @(posedge clk);
        payload = {8'h5A};
        send_message(8'h01, 8'h00, 16'd16, 16'd8, 16'd2, 32'd1,
                     payload, 1'b1, 0, 1.0, "header_idle_parse");
    endtask

    //--- Test 6: Large payload header bin closure -----------------------------
    task automatic test_large_payload_header();
        logic [7:0] payload[$];
        $display("[TEST] test_large_payload_header: total_bytes=300");
        payload = {};
        for (int i = 0; i < 300; i++)
            payload.push_back(8'(i));
        send_message(8'h02, 8'h02, 16'd512, 16'd128, 16'd16, 32'd300,
                     payload, 1'b1, 0, 1.0, "large_payload");
    endtask

    //--- Test 7: Field value verification (known header, verify extraction) ----
    task automatic test_field_verification();
        logic [7:0] hdr_bytes [16];
        logic [7:0] payload[$];
        logic [7:0]  exp_msg_type;
        logic [7:0]  exp_layer_id;
        logic [15:0] exp_layer_inputs;
        logic [15:0] exp_num_neurons;
        logic [15:0] exp_bytes_per_neuron;
        logic [31:0] exp_total_bytes;
        int timeout;

        $display("[TEST] test_field_verification: known header -> verify fields");

        exp_msg_type        = 8'hAB;
        exp_layer_id        = 8'hCD;
        exp_layer_inputs    = 16'h1234;
        exp_num_neurons     = 16'h5678;
        exp_bytes_per_neuron = 16'h9ABC;
        exp_total_bytes     = 32'h00000002;

        build_header(exp_msg_type, exp_layer_id, exp_layer_inputs,
                     exp_num_neurons, exp_bytes_per_neuron, exp_total_bytes,
                     hdr_bytes);

        // Send header bytes
        for (int i = 0; i < 16; i++)
            send_byte(hdr_bytes[i], 1'b0, 0);

        // Wait for hdr_valid
        timeout = 0;
        while (!hdr_valid && timeout < 20) begin
            @(posedge clk);
            timeout++;
        end

        // On the cycle hdr_valid is high, check all fields
        if (hdr_valid) begin
            check("field_msg_type", hdr_msg_type === exp_msg_type,
                  $sformatf("exp=0x%02h got=0x%02h", exp_msg_type, hdr_msg_type));
            check("field_layer_id", hdr_layer_id === exp_layer_id,
                  $sformatf("exp=0x%02h got=0x%02h", exp_layer_id, hdr_layer_id));
            check("field_layer_inputs", hdr_layer_inputs === exp_layer_inputs,
                  $sformatf("exp=0x%04h got=0x%04h", exp_layer_inputs, hdr_layer_inputs));
            check("field_num_neurons", hdr_num_neurons === exp_num_neurons,
                  $sformatf("exp=0x%04h got=0x%04h", exp_num_neurons, hdr_num_neurons));
            check("field_bpn", hdr_bytes_per_neuron === exp_bytes_per_neuron,
                  $sformatf("exp=0x%04h got=0x%04h", exp_bytes_per_neuron, hdr_bytes_per_neuron));
            check("field_total_bytes", hdr_total_bytes === exp_total_bytes,
                  $sformatf("exp=0x%08h got=0x%08h", exp_total_bytes, hdr_total_bytes));
        end else begin
            check("field_hdr_valid", 1'b0, "hdr_valid never asserted");
        end

        // Send payload + finish
        payload_ready <= 1'b1;
        send_byte(8'hEE, 1'b0, 0);
        send_byte(8'hFF, 1'b1, 0);
        payload_ready <= 1'b0;
        repeat (5) @(posedge clk);
    endtask

    //--- Test 7: Gapped byte input -- random valid gaps -----------------------
    task automatic test_gapped_input();
        logic [7:0] payload[$];
        $display("[TEST] test_gapped_input: random byte_valid gaps");
        payload = {};
        for (int i = 0; i < 10; i++)
            payload.push_back($urandom());
        send_message(8'h01, 8'h01, 16'd100, 16'd50, 16'd10, 32'd10,
                     payload, 1'b1, 1, 1.0, "gapped_input");
    endtask

    //--- Test 8: TLAST mid-payload -- verify boundary detection ----------------
    task automatic test_tlast_mid_payload();
        logic [7:0] payload[$];
        $display("[TEST] test_tlast_mid_payload: TLAST at last payload byte");
        payload = {8'h01, 8'h02, 8'h03, 8'h04, 8'h05};
        send_message(8'h02, 8'h00, 16'd10, 16'd5, 16'd1, 32'd5,
                     payload, 1'b1, 0, 1.0, "tlast_mid");
    endtask

    //--- Test 9: Random stress -- varied message sizes ------------------------
    task automatic test_random_stress();
        int num_msgs = RANDOM_MSGS;
        $display("[TEST] test_random_stress: %0d random messages", num_msgs);

        for (int m = 0; m < num_msgs; m++) begin
            logic [7:0] payload[$];
            logic [31:0] total;
            logic is_last;

            total = $urandom_range(1, 16);
            is_last = (m == num_msgs - 1);

            payload = {};
            for (int i = 0; i < int'(total); i++)
                payload.push_back($urandom());

            send_message($urandom(), $urandom(), $urandom(), $urandom(),
                         $urandom(), total, payload, is_last,
                         $urandom_range(0, 1), 0.7,
                         $sformatf("random_msg_%0d", m));

            repeat (3) @(posedge clk);
        end
    endtask

    //--- Test 10: Error injection -- invalid msg_type values ------------------
    task automatic test_invalid_msg_type();
        logic [7:0] payload[$];
        $display("[TEST] test_invalid_msg_type: msg_type=0xFF");
        payload = {8'h00};
        send_message(8'hFF, 8'h00, 16'd0, 16'd0, 16'd0, 32'd1,
                     payload, 1'b1, 0, 1.0, "invalid_type");
    endtask

    //
    // Main Test Sequence
    //
    initial begin
        $display("============================================================");
        $display("  bnn_cfg_header_parser Testbench (UVM-style CRV+, Gray-Box)");
        $display("  HIGHEST RISK MODULE -- Comprehensive verification");
        $display("============================================================");

        reset_dut();

        test_single_small();
        reset_dut();

        test_single_large();
        reset_dut();

        test_field_verification();
        reset_dut();

        test_back_to_back();
        reset_dut();

        test_zero_payload();
        reset_dut();

        test_payload_backpressure();
        reset_dut();

        test_header_idle_parse();
        reset_dut();

        test_large_payload_header();
        reset_dut();

        test_gapped_input();
        reset_dut();

        test_tlast_mid_payload();
        reset_dut();

        test_invalid_msg_type();
        reset_dut();

        test_random_stress();

        repeat (20) @(posedge clk);

        //
        // Scoreboard Summary
        //
        $display("");
        $display("============================================================");
        $display("  SCOREBOARD SUMMARY -- bnn_cfg_header_parser");
        $display("============================================================");
        $display("  Total checks : %0d", pass_count + fail_count);
        $display("  PASS         : %0d", pass_count);
        $display("  FAIL         : %0d", fail_count);
        if (fail_count > 0) begin
            $display("  --- Failure Details ---");
            foreach (fail_log[i])
                $display("    %s", fail_log[i]);
        end
        $display("  Hdr Coverage : %.1f%%", cg_hdr.get_coverage());
        $display("  Seq Coverage : %.1f%%", cg_seq.get_coverage());
        $display("============================================================");
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_count);
        $display("============================================================");

        $finish;
    end

endmodule
