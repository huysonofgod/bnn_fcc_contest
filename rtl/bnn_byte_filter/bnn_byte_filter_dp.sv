`timescale 1ns/10ps

module bnn_byte_filter_dp #(
    parameter int BUS_WIDTH = 64
)(
    input  logic                    clk,
    input  logic                    rst,
    // Capture inputs
    input  logic                    accept_word,     // from FSM
    input  logic [BUS_WIDTH-1:0]    s_data,
    input  logic [BUS_WIDTH/8-1:0]  s_keep,
    input  logic                    s_last,
    // Byte index counter control (from FSM)
    input  logic                    idx_we,
    input  logic                    idx_clr,
    // State flag (from FSM)
    input  logic                    in_serialize,   // 1 when state==SERIALIZE
    // Datapath status outputs (to FSM)
    output logic                    at_end,
    // Downstream handshake
    input  logic                    m_ready,
    output logic                    m_valid,
    output logic [7:0]              m_data,
    output logic                    m_last
);

    localparam int NUM_BYTES = BUS_WIDTH / 8;  // 8
    localparam int IDX_W     = (NUM_BYTES > 1) ? $clog2(NUM_BYTES) : 1;

    //  Capture registers 
    logic [BUS_WIDTH-1:0]    data_r_q;
    logic [NUM_BYTES-1:0]    keep_r_q;
    logic                    last_r_q;
    logic [IDX_W-1:0]        last_valid_idx_r_q;

    //  Byte index counter register 
    logic [IDX_W-1:0] byte_idx_r_q;
    logic [IDX_W-1:0] byte_idx_next;
    assign byte_idx_next = idx_clr ? '0 : (byte_idx_r_q + 1'b1);

    //  Priority encoder: find highest set bit in keep 
    // Scans from MSB (index 7) down to LSB (index 0)
    // Returns index of last valid byte (highest set keep bit)
    logic [IDX_W-1:0] last_valid_idx_comb;
    always_comb begin
        last_valid_idx_comb = '0;
        for (int k = 0; k < NUM_BYTES; k++) begin
            if (s_keep[k])
                last_valid_idx_comb = IDX_W'(k);
        end
        // After loop, holds highest index where keep is set
    end

    //  Sequential: capture registers 
    always_ff @(posedge clk) begin
        if (accept_word) begin
            data_r_q          <= s_data;
            keep_r_q          <= s_keep;
            last_r_q          <= s_last;
            last_valid_idx_r_q <= last_valid_idx_comb;
        end

        // Reset at END of block — only control/index signals
        if (rst) begin
            keep_r_q          <= '0;
            last_r_q          <= 1'b0;
            last_valid_idx_r_q <= '0;
        end
    end

    //  Sequential: byte index counter 
    always_ff @(posedge clk) begin
        if (idx_we)
            byte_idx_r_q <= byte_idx_next;

        if (rst)
            byte_idx_r_q <= '0;
    end

    //  Combinational datapath outputs 
    logic       keep_bit;
    logic       at_last_valid;
    logic [7:0] m_data_comb;

    assign m_data_comb  = data_r_q[byte_idx_r_q * 8 +: 8];
    assign keep_bit     = keep_r_q[byte_idx_r_q];
    assign at_last_valid = (byte_idx_r_q == last_valid_idx_r_q);
    assign at_end       = (byte_idx_r_q == IDX_W'(NUM_BYTES - 1));

    // m_valid: combinational (keep_bit gated by serialize state)
    assign m_valid = keep_bit & in_serialize;
    // m_last: combinational (only on an emitted valid byte that is the last valid lane)
    assign m_last  = last_r_q & at_last_valid & in_serialize & keep_bit;
    assign m_data  = m_data_comb;

endmodule
