`timescale 1ns/10ps

module bnn_unpack_datapath #(
    parameter int P_W    = 8,
    parameter int P_N    = 8,
    parameter int LID_W  = 4,
    parameter int NPID_W = 8,
    parameter int ADDR_W = 16,
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

    //  config registers 
    logic [15:0]      fan_in_r_q;
    logic [15:0]      bpn_r_q;
    logic [15:0]      nneur_r_q;
    logic [LID_W-1:0] lid_r_q;
    logic [15:0]      wpn_r_q;
    logic [15:0]      wpn_load;

    assign wpn_load = (cfg_fan_in + 16'(P_W - 1)) / 16'(P_W);

    always_ff @(posedge clk) begin
        if (cfg_we) begin
            fan_in_r_q <= cfg_fan_in;
            bpn_r_q    <= cfg_bytes_per_neuron;
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

    //   accumulator 
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

    //  bits-in counter 
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

    //  neuron byte counter 
    logic [15:0] neuron_byte_cnt_r_q;
    logic [15:0] neuron_byte_cnt_next;

    assign neuron_bytes_done = (bpn_r_q != 16'd0) &&
                               (neuron_byte_cnt_r_q == (bpn_r_q - 16'd1));
    assign neuron_bytes_complete = (bpn_r_q != 16'd0) &&
                                   (neuron_byte_cnt_r_q == bpn_r_q);
    assign neuron_byte_cnt_next = neur_byte_clr ? 16'd0
                                                : (neuron_byte_cnt_r_q + 16'd1);

    always_ff @(posedge clk) begin
        if (cfg_we)
            neuron_byte_cnt_r_q <= '0;
        else if (neur_byte_we)
            neuron_byte_cnt_r_q <= neuron_byte_cnt_next;

        if (rst)
            neuron_byte_cnt_r_q <= '0;
    end

    //  neuron / word counters 
    logic [15:0] neuron_idx_r_q;
    logic [15:0] word_idx_r_q;
    logic [15:0] neuron_idx_next;
    logic [15:0] word_idx_next;

    assign last_neuron = (nneur_r_q != 16'd0) &&
                         (neuron_idx_r_q == (nneur_r_q - 16'd1));
    assign last_word   = (wpn_r_q != 16'd0) &&
                         (word_idx_r_q == (wpn_r_q - 16'd1));

    assign neuron_idx_next = neuron_clr ? 16'd0 : (neuron_idx_r_q + 16'd1);
    assign word_idx_next   = word_clr ? 16'd0 : (word_idx_r_q + 16'd1);

    always_ff @(posedge clk) begin
        if (cfg_we)
            neuron_idx_r_q <= '0;
        else if (neuron_we)
            neuron_idx_r_q <= neuron_idx_next;

        if (rst)
            neuron_idx_r_q <= '0;
    end

    always_ff @(posedge clk) begin
        if (cfg_we)
            word_idx_r_q <= '0;
        else if (word_we)
            word_idx_r_q <= word_idx_next;

        if (rst)
            word_idx_r_q <= '0;
    end

    //  NP / address generation 
    logic [15:0]          local_neuron;
    logic [NPID_W-1:0]    np_id;
    logic [ADDR_W-1:0]    addr_base;
    logic [ADDR_W-1:0]    wr_addr_comb;

    always_comb begin
        np_id        = '0;
        local_neuron = '0;

        if (P_N == 1) begin
            np_id        = '0;
            local_neuron = neuron_idx_r_q;
        end else if (P_N_IS_POW2) begin
            np_id        = NPID_W'(neuron_idx_r_q[NP_SHIFT-1:0]);
            local_neuron = neuron_idx_r_q >> NP_SHIFT;
        end else begin
            np_id        = NPID_W'(neuron_idx_r_q % P_N);
            local_neuron = 16'((neuron_idx_r_q / P_N));
        end
    end

    assign addr_base   = ADDR_W'(local_neuron) * ADDR_W'(wpn_r_q);
    assign wr_addr_comb = addr_base + ADDR_W'(word_idx_r_q);

    //  output transaction slot 
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
            wr_np_r_q          <= np_id;
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

    //  Output assignments 
    assign wr_valid       = wr_valid_r_q;
    assign wr_layer       = wr_layer_r_q;
    assign wr_np          = wr_np_r_q;
    assign wr_addr        = wr_addr_r_q;
    assign wr_data        = wr_data_r_q;
    assign wr_last_word   = wr_last_word_r_q;
    assign wr_last_neuron = wr_last_neuron_r_q;
    assign wr_last_msg    = wr_last_msg_r_q;

endmodule
