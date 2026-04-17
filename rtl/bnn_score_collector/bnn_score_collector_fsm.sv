`timescale 1ns/10ps

module bnn_score_collector_fsm (
    input  logic clk,
    input  logic rst,
    // Input handshake
    input  logic s_valid,
    output logic s_ready,
    input  logic s_last_pass,
    // Output handshake
    input  logic m_ready,
    // Datapath status
    input  logic pass_tc,
    // Datapath control outputs
    output logic store_we,
    output logic pass_cnt_we,
    output logic pass_cnt_clr,
    output logic output_we,
    output logic m_valid_d
);

    typedef enum logic [1:0] {
        COLLECT = 2'd0,
        OUTPUT  = 2'd1,
        CLEAR   = 2'd2
    } state_t;

    state_t state_r, next_state;

    
    always_ff @(posedge clk) begin
        state_r <= next_state;

        if (rst)
            state_r <= COLLECT;
    end

    
    always_comb begin
        next_state   = state_r;
        s_ready      = 1'b0;
        store_we     = 1'b0;
        pass_cnt_we  = 1'b0;
        pass_cnt_clr = 1'b0;
        output_we    = 1'b0;
        m_valid_d    = 1'b0;

        case (state_r)

            COLLECT: begin
                s_ready   = 1'b1;
                m_valid_d = 1'b0;

                if (s_valid) begin
                    store_we    = 1'b1;
                    pass_cnt_we = 1'b1;
                    pass_cnt_clr = 1'b0;  // advance

                    if (s_last_pass) begin
                        // Latch all scores and preload the registered output so
                        // m_valid is already high when OUTPUT begins.
                        output_we  = 1'b1;
                        m_valid_d  = 1'b1;
                        next_state = OUTPUT;
                    end
                    // else stay in COLLECT
                end
            end

            OUTPUT: begin
                s_ready   = 1'b0;
                m_valid_d = !m_ready;  // hold until handshake, drop immediately after

                if (m_ready)
                    next_state = CLEAR;
                // else hold
            end

            CLEAR: begin
                s_ready      = 1'b0;
                m_valid_d    = 1'b0;
                pass_cnt_we  = 1'b1;
                pass_cnt_clr = 1'b1;  // reset pass counter to 0
                next_state   = COLLECT;
            end

            default: next_state = COLLECT;
        endcase
    end

endmodule
