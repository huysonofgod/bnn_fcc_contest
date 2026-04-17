`timescale 1ns/10ps

module bnn_layer_ctrl_fsm #(
    parameter int RESULT_WAIT_CYCLES = 0
) (
    input  logic clk,
    input  logic rst,
    // External control
    input  logic start,
    input  logic s_valid,
    input  logic s_last,        // unused by ctrl; info only
    input  logic result_ready,
    // Datapath status
    input  logic iter_tc,
    input  logic pass_tc,
    // Datapath counter controls
    output logic iter_we,
    output logic iter_clr,
    output logic pass_we,
    output logic pass_clr,
    // Datapath register controls
    output logic wt_addr_we,
    output logic thr_addr_we,
    output logic vnp_we,
    // Datapath output register D-inputs
    output logic np_valid_d,
    output logic np_last_d,
    output logic wt_rd_en_d,
    output logic thr_rd_en_d,
    output logic result_valid_d,
    output logic last_pass_d,
    output logic busy_d,
    output logic done_d,
    // s_ready: consuming input
    output logic s_ready
);

    // State encoding
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        LOAD_THR  = 3'd1,
        RUN_ITER  = 3'd2,
        LAST_BEAT = 3'd3,
        WAIT_RESULT = 3'd4,
        FLUSH_OUT = 3'd5,
        DONE_ST   = 3'd6
    } state_t;

    state_t state_r, next_state;
    localparam int WAIT_W = (RESULT_WAIT_CYCLES > 0) ? $clog2(RESULT_WAIT_CYCLES + 1) : 1;
    localparam int WAIT_RELOAD = (RESULT_WAIT_CYCLES > 0) ? (RESULT_WAIT_CYCLES - 1) : 0;
    logic [WAIT_W-1:0] wait_cnt_r_q;

    // State register (sequential)
    always_ff @(posedge clk) begin
        state_r <= next_state;
        if (state_r != WAIT_RESULT)
            wait_cnt_r_q <= WAIT_W'(WAIT_RELOAD);
        else if (wait_cnt_r_q != 0)
            wait_cnt_r_q <= wait_cnt_r_q - 1'b1;

        if (rst) begin
            state_r <= IDLE;
            wait_cnt_r_q <= '0;
        end
    end

    // Next-state and output logic (combinational)
    always_comb begin
        // Default all outputs off
        next_state      = state_r;
        iter_we         = 1'b0;
        iter_clr        = 1'b0;
        pass_we         = 1'b0;
        pass_clr        = 1'b0;
        wt_addr_we      = 1'b0;
        thr_addr_we     = 1'b0;
        vnp_we          = 1'b0;
        np_valid_d      = 1'b0;
        np_last_d       = 1'b0;
        wt_rd_en_d      = 1'b0;
        thr_rd_en_d     = 1'b0;
        result_valid_d  = 1'b0;
        last_pass_d     = 1'b0;
        busy_d          = 1'b0;
        done_d          = 1'b0;
        s_ready         = 1'b0;

        case (state_r)

            IDLE: begin
                // All outputs at reset default (0)
                if (start) begin
                    // Clear counters and go to LOAD_THR
                    pass_we    = 1'b1;
                    pass_clr   = 1'b1;
                    iter_we    = 1'b1;
                    iter_clr   = 1'b1;
                    busy_d     = 1'b1;
                    next_state = LOAD_THR;
                end
            end

            LOAD_THR: begin
                // Issue threshold RAM read + prefetch first weight address
                thr_rd_en_d  = 1'b1;
                thr_addr_we  = 1'b1;   // latch pass_cnt into thr_addr
                wt_addr_we   = 1'b1;   // prefetch: addr = pass_cnt*ITERS + 0
                wt_rd_en_d   = 1'b1;   // start prefetch read for iter 0
                vnp_we       = 1'b1;   // latch valid_np_count for this pass
                last_pass_d  = pass_tc;
                busy_d       = 1'b1;
                // 1-cycle state
                next_state   = RUN_ITER;
            end

            RUN_ITER: begin
                s_ready  = 1'b1;
                busy_d   = 1'b1;

                if (s_valid) begin
                    np_valid_d  = 1'b1;  // NPs compute this cycle
                    wt_rd_en_d  = 1'b1;
                    iter_we     = 1'b1;
                    iter_clr    = 1'b0;  // advance
                    wt_addr_we  = 1'b1;  // update address for next iteration

                    if (iter_tc) begin
                        // Tag the final accepted beat so the registered
                        // np_valid/np_last pair reaches the NP bank together.
                        np_last_d  = 1'b1;
                        next_state = LAST_BEAT;
                    end else begin
                        np_last_d  = 1'b0;
                        next_state = RUN_ITER;
                    end
                end else begin
                    np_valid_d = 1'b0;
                    wt_rd_en_d = 1'b0;
                    next_state = RUN_ITER;  // wait
                end
            end

            LAST_BEAT: begin
                // Bubble after the tagged final beat; result_valid is delayed
                // further in WAIT_RESULT when the NP-bank inserts extra latency.
                wt_rd_en_d   = 1'b0;
                busy_d       = 1'b1;
                if (RESULT_WAIT_CYCLES == 0)
                    next_state = FLUSH_OUT;
                else
                    next_state = WAIT_RESULT;
            end

            WAIT_RESULT: begin
                busy_d = 1'b1;
                if (wait_cnt_r_q == 0)
                    next_state = FLUSH_OUT;
                else
                    next_state = WAIT_RESULT;
            end

            FLUSH_OUT: begin
                // Present results to downstream; hold until consumed
                result_valid_d = 1'b1;
                busy_d         = 1'b1;

                if (result_ready) begin
                    if (pass_tc) begin
                        next_state = DONE_ST;
                    end else begin
                        pass_we    = 1'b1;
                        pass_clr   = 1'b0;  // advance pass
                        iter_we    = 1'b1;
                        iter_clr   = 1'b1;  // reset iter for next pass
                        next_state = LOAD_THR;
                    end
                end else begin
                    next_state = FLUSH_OUT;  // hold, backpressure
                end
            end

            DONE_ST: begin
                // Single-cycle done pulse
                done_d     = 1'b1;
                busy_d     = 1'b0;
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

endmodule
