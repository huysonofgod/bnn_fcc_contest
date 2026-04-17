`timescale 1ns/10ps

module bnn_activation_packer_dp #(
    parameter int IN_BITS  = 8,   // P_N
    parameter int OUT_BITS = 8,   // P_W_NEXT
    localparam int ACCUM_W    = IN_BITS + OUT_BITS,
    localparam int CNT_W      = $clog2(IN_BITS + 1),
    localparam int BIT_CNT_W  = $clog2(ACCUM_W + 1)
)(
    input  logic                  clk,
    input  logic                  rst,

    // Datapath inputs
    input  logic [IN_BITS-1:0]   s_data,
    input  logic [CNT_W-1:0]     s_count,

    // FSM control inputs
    input  logic                  accum_we,
    input  logic [1:0]            accum_sel,    // 0=merge,1=drain,2=clear
    input  logic                  bits_we,
    input  logic [1:0]            bits_sel,     // 0=after_merge,1=after_emit,2=clear
    input  logic                  out_we,       // WE for m_data/m_last regs
    input  logic                  out_valid_d,  // D-input of m_valid reg
    input  logic                  flush_set,    // set flushing_r_q
    input  logic                  flush_clr,    // clear flushing_r_q
    input  logic                  m_last_d,     // D-input for m_last reg (from FSM)
    input  logic                  m_ready,

    // FSM status outputs
    output logic                  can_emit,     // bits_in >= OUT_BITS
    output logic                  has_residual, // bits_in > 0
    output logic [BIT_CNT_W-1:0]  bits_after_merge,
    output logic [BIT_CNT_W-1:0]  bits_after_emit,
    output logic                  flushing_r_q,

    // Downstream outputs
    output logic                  m_valid,
    output logic [OUT_BITS-1:0]   m_data,
    output logic                  m_last
);

    // Registers
    logic [ACCUM_W-1:0]   accum_r_q;
    logic [BIT_CNT_W-1:0] bits_in_r_q;
    logic [OUT_BITS-1:0]  m_data_r_q;
    logic                 m_valid_r_q;
    logic                 m_last_r_q;
    // flushing_r_q is declared in the port list

    logic flushing_next;

    // Input alignment (left barrel shift)
    logic [IN_BITS-1:0]  s_data_masked;
    logic [ACCUM_W-1:0]  shifted_input;
    always_comb begin
        s_data_masked = '0;
        for (int i = 0; i < IN_BITS; i++) begin
            if (i < s_count)
                s_data_masked[i] = s_data[i];
        end
    end
    assign shifted_input = ACCUM_W'(s_data_masked) << bits_in_r_q;

    // Accumulator combinational paths
    logic [ACCUM_W-1:0] merge_result;
    logic [ACCUM_W-1:0] drained_accum;
    logic [ACCUM_W-1:0] accum_next;

    assign merge_result  = accum_r_q | shifted_input;
    assign drained_accum = accum_r_q >> OUT_BITS;

    always_comb begin
        case (accum_sel)
            2'b00:   accum_next = merge_result;   // accumulate
            2'b01:   accum_next = drained_accum;  // after emit
            2'b10:   accum_next = '0;             // clear
            default: accum_next = accum_r_q;
        endcase
    end

    always_ff @(posedge clk) begin
        if (accum_we)
            accum_r_q <= accum_next;

        if (rst)
            accum_r_q <= '0;
    end

    // Bit counter
    logic [BIT_CNT_W-1:0] bits_in_next;

    assign bits_after_merge = bits_in_r_q + BIT_CNT_W'(s_count);
    assign bits_after_emit  = bits_in_r_q - BIT_CNT_W'(OUT_BITS);
    assign can_emit         = (bits_in_r_q >= BIT_CNT_W'(OUT_BITS));
    assign has_residual     = (bits_in_r_q > '0);

    always_comb begin
        case (bits_sel)
            2'b00:   bits_in_next = bits_after_merge;  // after accept
            2'b01:   bits_in_next = bits_after_emit;   // after emit
            2'b10:   bits_in_next = '0;                // clear
            default: bits_in_next = bits_in_r_q;
        endcase
    end

    always_ff @(posedge clk) begin
        if (bits_we)
            bits_in_r_q <= bits_in_next;

        if (rst)
            bits_in_r_q <= '0;
    end

    // Output registers     // m_data and m_last: gated by out_we
    always_ff @(posedge clk) begin
        if (out_we) begin
            if (!(m_valid_r_q && !m_ready)) begin
                m_data_r_q <= accum_r_q[OUT_BITS-1:0]; // extract_word
                m_last_r_q <= m_last_d;
            end
        end

        if (rst) begin
            m_data_r_q <= '0;
            m_last_r_q <= 1'b0;
        end
    end

    // m_valid is always clocked (FSM drives out_valid_d every cycle)
    always_ff @(posedge clk) begin
        if (m_valid_r_q) begin
            if (m_ready)
                m_valid_r_q <= out_valid_d;
            else
                m_valid_r_q <= 1'b1;
        end else begin
            m_valid_r_q <= out_valid_d;
        end

        if (rst)
            m_valid_r_q <= 1'b0;
    end

    // Flushing flag set/clear by FSM
    always_comb begin
        if (flush_set)
            flushing_next = 1'b1;
        else if (flush_clr)
            flushing_next = 1'b0;
        else
            flushing_next = flushing_r_q;
    end

    always_ff @(posedge clk) begin
        flushing_r_q <= flushing_next;

        if (rst)
            flushing_r_q <= 1'b0;
    end

    // Output assignments
    assign m_valid = m_valid_r_q;
    assign m_data  = m_data_r_q;
    assign m_last  = m_last_r_q;

endmodule
