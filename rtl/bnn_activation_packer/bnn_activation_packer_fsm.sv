`timescale 1ns/10ps

module bnn_activation_packer_fsm #(
    parameter int IN_BITS  = 8,
    parameter int OUT_BITS = 8,
    localparam int ACCUM_W   = IN_BITS + OUT_BITS,
    localparam int BIT_CNT_W = $clog2(ACCUM_W + 1)
)(
    input  logic                  clk,
    input  logic                  rst,
    // Input handshake
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic                  s_last_group,
    // Output handshake
    input  logic                  m_valid,
    input  logic                  m_ready,
    input  logic                  m_last,
    // Datapath status
    input  logic [BIT_CNT_W-1:0]  bits_after_merge,
    input  logic [BIT_CNT_W-1:0]  bits_after_emit,
    input  logic                  can_emit,
    input  logic                  has_residual,
    input  logic                  flushing_r_q,
    // Datapath control outputs
    output logic                  accum_we,
    output logic [1:0]            accum_sel,
    output logic                  bits_we,
    output logic [1:0]            bits_sel,
    output logic                  out_we,
    output logic                  out_valid_d,
    output logic                  m_last_d,
    output logic                  flush_set,
    output logic                  flush_clr
);

    // State encoding
    typedef enum logic [2:0] {
        IDLE   = 3'd0,
        ACCEPT = 3'd1,
        EMIT   = 3'd2,
        FLUSH  = 3'd3,
        DONE   = 3'd4
    } state_t;

    state_t state_r, next_state;

    // State register
    always_ff @(posedge clk) begin
        state_r <= next_state;

        if (rst)
            state_r <= IDLE;
    end

    // Next-state and output logic
    always_comb begin
        // Defaults
        next_state  = state_r;
        s_ready     = 1'b0;
        accum_we    = 1'b0;
        accum_sel   = 2'b00;
        bits_we     = 1'b0;
        bits_sel    = 2'b00;
        out_we      = 1'b0;
        out_valid_d = 1'b0;
        m_last_d    = 1'b0;
        flush_set   = 1'b0;
        flush_clr   = 1'b0;

        case (state_r)

            IDLE: begin
                // Unconditional transition to ACCEPT
                next_state = ACCEPT;
            end

            ACCEPT: begin
                s_ready     = !m_valid;
                out_valid_d = 1'b0;

                if (m_valid) begin
                    // Pending output beat must be consumed before accepting
                    // another input group.
                    next_state = ACCEPT;
                end else if (s_valid) begin
                    // Merge s_data into accumulator
                    accum_we  = 1'b1;
                    accum_sel = 2'b00;  // merge
                    bits_we   = 1'b1;
                    bits_sel  = 2'b00;  // add s_count
                    flush_set = s_last_group;

                    // Transition based on bits_after_merge and s_last_group
                    if (bits_after_merge >= BIT_CNT_W'(OUT_BITS))
                        next_state = EMIT;
                    else if (s_last_group && (bits_after_merge > '0))
                        next_state = FLUSH;
                    else if (s_last_group && (bits_after_merge == '0))
                        next_state = DONE;
                    else
                        next_state = ACCEPT;
                end
                //else: hold in ACCEPT, wait
            end

            EMIT: begin
                s_ready     = 1'b0;
                //Service the output path when the register is empty or the
                //current beat is being consumed. Loading a beat and draining
                //the accumulator must happen together; otherwise a stalled
                //first beat would remain in the accumulator and be reloaded
                //as a duplicate later.
                if (!m_valid || m_ready) begin
                    out_we      = 1'b1;
                    out_valid_d = 1'b1;
                    m_last_d    = flushing_r_q && (bits_after_emit == '0);

                    accum_we  = 1'b1;
                    accum_sel = 2'b01;  // drain (shift right OUT_BITS)
                    bits_we   = 1'b1;
                    bits_sel  = 2'b01;  // subtract OUT_BITS

                    if (bits_after_emit >= BIT_CNT_W'(OUT_BITS))
                        next_state = EMIT;
                    else if (flushing_r_q && (bits_after_emit > '0))
                        next_state = FLUSH;
                    else if (flushing_r_q && (bits_after_emit == '0))
                        next_state = DONE;
                    else
                        next_state = ACCEPT;
                end else begin
                    // Stall with a visible beat already present: hold output.
                    out_we      = 1'b0;
                    out_valid_d = 1'b0;
                    m_last_d    = m_last;
                    accum_we    = 1'b0;
                    bits_we     = 1'b0;
                    next_state  = EMIT;
                end
            end

            FLUSH: begin
                // Emit final partial word with 0-padding; m_last=1.
                // On entry from EMIT, the output register can still hold the
                // previous non-last word. Wait for that beat to clear, then
                // load the true flush word, and only clear state once the
                // consumed beat is the flush word.
                s_ready = 1'b0;

                if (!m_valid) begin
                    out_we      = 1'b1;
                    out_valid_d = 1'b1;
                    m_last_d    = 1'b1;
                    next_state  = FLUSH;
                end else if (m_ready && m_last) begin
                    accum_we   = 1'b1;
                    accum_sel  = 2'b10;  // clear
                    bits_we    = 1'b1;
                    bits_sel   = 2'b10;  // clear
                    flush_clr  = 1'b1;
                    next_state = DONE;
                end else begin
                    next_state = FLUSH;
                end
            end

            DONE: begin
                // One-cycle cleanup
                accum_we   = 1'b1;
                accum_sel  = 2'b10;  // clear accumulator after final beat buffered
                bits_we    = 1'b1;
                bits_sel   = 2'b10;  // clear residual count
                flush_clr  = 1'b1;
                out_valid_d = 1'b0;
                next_state  = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

endmodule
