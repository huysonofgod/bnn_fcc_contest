`timescale 1ns/10ps

module bnn_unpack_datapath #(
    parameter int P_W    = 8,
    parameter int P_N    = 8,
    parameter int LID_W  = 4,
    parameter int NPID_W = 8,
    parameter int ADDR_W = 16,
    parameter int STATIC_WORDS_PER_NEURON = 0,
    parameter int STATIC_BYTES_PER_NEURON = 0,
    localparam int ACCUM_W = P_W + 8,
    localparam int BIA_W   = $clog2(ACCUM_W + 1)
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic [15:0]           cfg_fan_in,
    input  logic [15:0]           cfg_bytes_per_neuron,
    input  logic [15:0]           cfg_num_neurons,
    input  logic [LID_W-1:0]      cfg_layer_id,
    input  logic                  cfg_we,
    input  logic [7:0]            byte_data,
    input  logic                  wr_ready,
    input  logic                  accum_we,
    input  logic [1:0]            accum_sel,
    input  logic                  bits_we,
    input  logic [1:0]            bits_sel,
    input  logic                  neur_byte_we,
    input  logic                  neur_byte_clr,
    input  logic                  neuron_we,
    input  logic                  neuron_clr,
    input  logic                  word_we,
    input  logic                  word_clr,
    input  logic                  txn_we,
    input  logic                  pad_sel,
    output logic [BIA_W-1:0]      bits_after_byte,
    output logic [BIA_W-1:0]      bits_after_emit,
    output logic                  neuron_bytes_done,
    output logic                  neuron_bytes_complete,
    output logic                  last_word,
    output logic                  last_neuron,
    output logic                  wr_valid,
    output logic [LID_W-1:0]      wr_layer,
    output logic [NPID_W-1:0]     wr_np,
    output logic [ADDR_W-1:0]     wr_addr,
    output logic [P_W-1:0]        wr_data,
    output logic                  wr_last_word,
    output logic                  wr_last_neuron,
    output logic                  wr_last_msg
);

    localparam bit P_N_IS_POW2 = (P_N > 0) && ((P_N & (P_N - 1)) == 0);
    localparam int NP_SHIFT    = (P_N > 1) ? $clog2(P_N) : 1;
    localparam bit P_W_IS_POW2 = (P_W > 0) && ((P_W & (P_W - 1)) == 0);
    localparam int PW_SHIFT    = (P_W > 1) ? $clog2(P_W) : 1;

    
    logic [15:0]      fan_in_r_q;
    logic [15:0]      bpn_r_q;
    logic [15:0]      nneur_r_q;
    logic [LID_W-1:0] lid_r_q;
    logic [15:0]      wpn_r_q;
    logic [15:0]      wpn_load;
    logic [15:0]      bpn_load;

    // Words-per-neuron: topology-derived static constant when possible so
    // wpn_r_q does not depend on live header bits (STATIC_WORDS_PER_NEURON).
    generate
        if (STATIC_WORDS_PER_NEURON > 0) begin : g_wpn_static
            assign wpn_load = 16'(STATIC_WORDS_PER_NEURON);
        end else if (P_W == 1) begin : g_wpn_pw1
            assign wpn_load = cfg_fan_in;
        end else if (P_W_IS_POW2) begin : g_wpn_pow2
            assign wpn_load = (cfg_fan_in + 16'(P_W - 1)) >> PW_SHIFT;
        end else begin : g_wpn_div
            assign wpn_load = (cfg_fan_in + 16'(P_W - 1)) / 16'(P_W);
        end
    endgenerate

    // Bytes-per-neuron: static constant eliminates cfg_bytes_per_neuron from
    // bpn_r_q, bounding neuron_byte_rem_r_q to STATIC_BYTES_PER_NEURON bits so
    // Vivado optimizes the rem==1 / rem==0 comparisons to fewer LUTs.
    generate
        if (STATIC_BYTES_PER_NEURON > 0) begin : g_bpn_static
            assign bpn_load = 16'(STATIC_BYTES_PER_NEURON);
        end else begin : g_bpn_dyn
            assign bpn_load = cfg_bytes_per_neuron;
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (cfg_we) begin
            fan_in_r_q <= cfg_fan_in;
            bpn_r_q    <= bpn_load;
            nneur_r_q  <= cfg_num_neurons;
            lid_r_q    <= cfg_layer_id;
            wpn_r_q    <= wpn_load;
        end

        if (rst) begin
            fan_in_r_q <= '0;
            bpn_r_q    <= '0;
            nneur_r_q  <= '0;
            lid_r_q    <= '0;
            wpn_r_q    <= '0;
        end
    end

    
    logic [ACCUM_W-1:0] accum_r_q;
    logic [ACCUM_W-1:0] shifted_byte;
    logic [ACCUM_W-1:0] merged_accum;
    logic [ACCUM_W-1:0] drained_accum;
    logic [P_W-1:0]     pad_mask;
    logic [P_W-1:0]     padded_word;
    logic [ACCUM_W-1:0] accum_next;
    logic [BIA_W-1:0]   bits_in_r_q;
    logic [BIA_W-1:0]   bits_in_next;
    logic [BIA_W-1:0]   byte_valid_bits;
    logic [7:0]         byte_mask;
    logic [7:0]         masked_byte;

    always_comb begin
        if (neuron_bytes_done) begin
            if (fan_in_r_q[2:0] == 3'd0)
                byte_valid_bits = BIA_W'(8);
            else
                byte_valid_bits = BIA_W'(fan_in_r_q[2:0]);
        end else begin
            byte_valid_bits = BIA_W'(8);
        end

        if (byte_valid_bits >= BIA_W'(8))
            byte_mask = 8'hFF;
        else
            byte_mask = 8'((9'h1 << byte_valid_bits) - 1);
    end

    assign masked_byte  = byte_data & byte_mask;
    assign shifted_byte = ACCUM_W'(masked_byte) << bits_in_r_q;
    assign merged_accum = accum_r_q | shifted_byte;
    assign drained_accum = accum_r_q >> P_W;
    assign pad_mask = ({P_W{1'b1}} << bits_in_r_q);
    assign padded_word = accum_r_q[P_W-1:0] | pad_mask;

    always_comb begin
        case (accum_sel)
            2'b00:   accum_next = merged_accum;
            2'b01:   accum_next = drained_accum;
            2'b10:   accum_next = '0;
            default: accum_next = accum_r_q;
        endcase
    end

    always_ff @(posedge clk) begin
        if (cfg_we)
            accum_r_q <= '0;
        else if (accum_we)
            accum_r_q <= accum_next;

        if (rst)
            accum_r_q <= '0;
    end

    
    assign bits_after_byte = bits_in_r_q + byte_valid_bits;
    assign bits_after_emit = bits_in_r_q - BIA_W'(P_W);

    always_comb begin
        case (bits_sel)
            2'b00:   bits_in_next = bits_after_byte;
            2'b01:   bits_in_next = bits_after_emit;
            2'b10:   bits_in_next = '0;
            default: bits_in_next = bits_in_r_q;
        endcase
    end

    always_ff @(posedge clk) begin
        if (cfg_we)
            bits_in_r_q <= '0;
        else if (bits_we)
            bits_in_r_q <= bits_in_next;

        if (rst)
            bits_in_r_q <= '0;
    end

    
    // neuron_byte_rem_r_q: bounded to BPN_BITS so comparators and path from
    // bit[14+] (present in 16-bit version) no longer appear in M10 timing paths.
    // For STATIC_BPN=98 → 7 bits; STATIC_BPN=32 → 6 bits.
    localparam int BPN_BITS = (STATIC_BYTES_PER_NEURON > 0)
                              ? $clog2(STATIC_BYTES_PER_NEURON + 1) : 16;
    (* max_fanout = 2 *) logic [BPN_BITS-1:0] neuron_byte_rem_r_q;
    logic [BPN_BITS-1:0] neuron_byte_rem_dec_w;
    logic [BPN_BITS-1:0] neuron_byte_rem_next;

    // Down-counter: steady-state control checks rem==1/rem==0 (no bpn compare).
    assign neuron_bytes_done     = (neuron_byte_rem_r_q == BPN_BITS'(1));
    assign neuron_bytes_complete = (neuron_byte_rem_r_q == '0);
    assign neuron_byte_rem_dec_w = (neuron_byte_rem_r_q != '0)
                                 ? (neuron_byte_rem_r_q - BPN_BITS'(1))
                                 : '0;

    always_comb begin
        if (cfg_we)
            neuron_byte_rem_next = BPN_BITS'(bpn_load);
        else if (neur_byte_we && neur_byte_clr)
            neuron_byte_rem_next = BPN_BITS'(bpn_r_q);
        else if (neur_byte_we)
            neuron_byte_rem_next = neuron_byte_rem_dec_w;
        else
            neuron_byte_rem_next = neuron_byte_rem_r_q;
    end

    always_ff @(posedge clk) begin
        neuron_byte_rem_r_q <= neuron_byte_rem_next;

        if (rst)
            neuron_byte_rem_r_q <= '0;
    end

    
    logic [15:0] neuron_idx_r_q;
    logic [15:0] neuron_idx_next;

    // word_idx: bounded up-counter for address (0..WPN-1). With STATIC_WORDS_PER_NEURON
    // Vivado bounds the counter to WPN_BITS wide, shortening the address adder carry chain.
    localparam int WPN_BITS = (STATIC_WORDS_PER_NEURON > 0)
                              ? $clog2(STATIC_WORDS_PER_NEURON + 1) : 16;
    logic [WPN_BITS-1:0] word_idx_r_q;
    // word_rem_r_q: same WPN_BITS bound as word_idx so the MSBs above WPN_BITS-1
    // are absent. This eliminates word_rem_r_q[8] (which was on the M10 critical
    // path to neuron_byte_rem_r_q/R) when STATIC_WORDS_PER_NEURON <= 127.
    logic [WPN_BITS-1:0] word_rem_r_q;
    logic [WPN_BITS-1:0] word_rem_dec_w;
    logic [WPN_BITS-1:0] word_rem_next;

    assign last_neuron = (nneur_r_q != 16'd0) &&
                         (neuron_idx_r_q == (nneur_r_q - 16'd1));
    // last_word fires when rem==1; comparator now bounded to WPN_BITS.
    assign last_word   = (word_rem_r_q == WPN_BITS'(1));

    assign neuron_idx_next = neuron_clr ? 16'd0 : (neuron_idx_r_q + 16'd1);
    assign word_rem_dec_w  = (word_rem_r_q != '0) ? (word_rem_r_q - WPN_BITS'(1)) : '0;

    always_comb begin
        if (cfg_we)
            word_rem_next = WPN_BITS'(wpn_load);
        else if (word_we && word_clr)
            word_rem_next = WPN_BITS'(wpn_r_q);
        else if (word_we)
            word_rem_next = word_rem_dec_w;
        else
            word_rem_next = word_rem_r_q;
    end

    always_ff @(posedge clk) begin
        if (cfg_we)
            neuron_idx_r_q <= '0;
        else if (neuron_we)
            neuron_idx_r_q <= neuron_idx_next;

        if (rst)
            neuron_idx_r_q <= '0;
    end

    always_ff @(posedge clk) begin
        word_rem_r_q <= word_rem_next;

        if (rst)
            word_rem_r_q <= '0;
    end

    // word_idx up-counter: mirrors word_rem resets but counts up for address.
    // addr = base + word_idx (simple addition, no subtraction on critical path).
    always_ff @(posedge clk) begin
        if (cfg_we || (word_we && word_clr))
            word_idx_r_q <= '0;
        else if (word_we)
            word_idx_r_q <= word_idx_r_q + WPN_BITS'(1);

        if (rst)
            word_idx_r_q <= '0;
    end

    
    logic [NPID_W-1:0]    np_id_r_q;
    logic [ADDR_W-1:0]    addr_base_r_q;
    logic [ADDR_W-1:0]    wr_addr_comb;

    always_ff @(posedge clk) begin
        if (cfg_we) begin
            np_id_r_q     <= '0;
            addr_base_r_q <= '0;
        end else if (neuron_we) begin
            if (neuron_clr) begin
                np_id_r_q     <= '0;
                addr_base_r_q <= '0;
            end else if (P_N == 1) begin
                np_id_r_q     <= '0;
                addr_base_r_q <= addr_base_r_q + ADDR_W'(wpn_r_q);
            end else begin
                if (np_id_r_q == NPID_W'(P_N - 1)) begin
                    np_id_r_q     <= '0;
                    addr_base_r_q <= addr_base_r_q + ADDR_W'(wpn_r_q);
                end else begin
                    np_id_r_q     <= np_id_r_q + NPID_W'(1);
                end
            end
        end

        if (rst) begin
            np_id_r_q     <= '0;
            addr_base_r_q <= '0;
        end
    end

    // addr = base + word_idx: simple addition, word_idx bounded to WPN_BITS.
    assign wr_addr_comb = addr_base_r_q + ADDR_W'(word_idx_r_q);

    
    logic [P_W-1:0]    wr_data_r_q;
    logic [LID_W-1:0]  wr_layer_r_q;
    logic [NPID_W-1:0] wr_np_r_q;
    logic [ADDR_W-1:0] wr_addr_r_q;
    logic              wr_last_word_r_q;
    logic              wr_last_neuron_r_q;
    logic              wr_last_msg_r_q;
    logic              wr_valid_r_q;
    logic              wr_valid_next;

    always_ff @(posedge clk) begin
        if (txn_we) begin
            wr_data_r_q        <= pad_sel ? padded_word : accum_r_q[P_W-1:0];
            wr_layer_r_q       <= lid_r_q;
            wr_np_r_q          <= np_id_r_q;
            wr_addr_r_q        <= wr_addr_comb;
            wr_last_word_r_q   <= last_word;
            wr_last_neuron_r_q <= last_word & last_neuron;
            wr_last_msg_r_q    <= last_word & last_neuron;
        end

        if (rst) begin
            wr_data_r_q        <= '0;
            wr_layer_r_q       <= '0;
            wr_np_r_q          <= '0;
            wr_addr_r_q        <= '0;
            wr_last_word_r_q   <= 1'b0;
            wr_last_neuron_r_q <= 1'b0;
            wr_last_msg_r_q    <= 1'b0;
        end
    end

    always_comb begin
        if (txn_we)
            wr_valid_next = 1'b1;
        else if (wr_ready)
            wr_valid_next = 1'b0;
        else
            wr_valid_next = wr_valid_r_q;
    end

    always_ff @(posedge clk) begin
        wr_valid_r_q <= wr_valid_next;

        if (rst)
            wr_valid_r_q <= 1'b0;
    end

    
    assign wr_valid       = wr_valid_r_q;
    assign wr_layer       = wr_layer_r_q;
    assign wr_np          = wr_np_r_q;
    assign wr_addr        = wr_addr_r_q;
    assign wr_data        = wr_data_r_q;
    assign wr_last_word   = wr_last_word_r_q;
    assign wr_last_neuron = wr_last_neuron_r_q;
    assign wr_last_msg    = wr_last_msg_r_q;

endmodule
