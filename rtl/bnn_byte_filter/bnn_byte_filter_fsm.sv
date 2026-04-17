`timescale 1ns/10ps

module bnn_byte_filter_fsm (
    input  logic clk,
    input  logic rst,
    // Upstream handshake
    input  logic s_valid,
    output logic s_ready,       // registered
    // Downstream handshake status
    input  logic m_valid,       // from datapath (combinational)
    input  logic m_ready,
    // Datapath status
    input  logic at_end,
    // Datapath control outputs
    output logic accept_word,   // WE for capture registers
    output logic idx_we,
    output logic idx_clr,
    output logic in_serialize   // state flag to datapath
);

    
    typedef enum logic [0:0] {
        EMPTY     = 1'b0,
        SERIALIZE = 1'b1
    } state_t;

    state_t state_r, next_state;

    
    always_ff @(posedge clk) begin
        state_r <= next_state;

        // Reset at END of block — only state register
        if (rst)
            state_r <= EMPTY;
    end

    
    // Intermediate signals
    logic advance;
    assign advance = (~m_valid) | (m_valid & m_ready);
    // accept fires when we're in EMPTY and upstream has valid data
    assign accept_word = (state_r == EMPTY) & s_valid;

    always_comb begin
        // Default outputs
        next_state   = state_r;
        idx_we       = 1'b0;
        idx_clr      = 1'b0;
        in_serialize = 1'b0;
        s_ready      = 1'b0;

        case (state_r)

            EMPTY: begin
                s_ready      = 1'b1;
                in_serialize = 1'b0;
                if (s_valid) begin
                    // accept_word fires → capture registers load
                    idx_we     = 1'b1;
                    idx_clr    = 1'b1;  // reset byte_idx to 0
                    next_state = SERIALIZE;
                end
            end

            SERIALIZE: begin
                s_ready      = 1'b0;
                in_serialize = 1'b1;
                if (advance) begin
                    idx_we  = 1'b1;
                    idx_clr = 1'b0;  // increment
                    if (at_end)
                        next_state = EMPTY;
                    else
                        next_state = SERIALIZE;
                end else begin
                    idx_we  = 1'b0;  // stall
                end
            end

            default: next_state = EMPTY;
        endcase
    end

endmodule
