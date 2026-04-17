`timescale 1ns/10ps

module bnn_unpack_ctrl #(
    parameter int P_W = 8,
    localparam int ACCUM_W = P_W + 8,
    localparam int BIA_W   = $clog2(ACCUM_W + 1)
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  cfg_load,
    input  logic                  byte_valid,
    output logic                  byte_ready,
    input  logic                  wr_valid,
    input  logic                  wr_ready,
    input  logic [BIA_W-1:0]      bits_after_byte,
    input  logic [BIA_W-1:0]      bits_after_emit,
    input  logic                  neuron_bytes_done,
    input  logic                  neuron_bytes_complete,
    input  logic                  last_word,
    input  logic                  last_neuron,
    output logic                  cfg_we,
    output logic                  accum_we,
    output logic [1:0]            accum_sel,
    output logic                  bits_we,
    output logic [1:0]            bits_sel,
    output logic                  neur_byte_we,
    output logic                  neur_byte_clr,
    output logic                  neuron_we,
    output logic                  neuron_clr,
    output logic                  word_we,
    output logic                  word_clr,
    output logic                  txn_we,
    output logic                  pad_sel
);

    typedef enum logic [1:0] {
        IDLE       = 2'd0,
        ACCUMULATE = 2'd1,
        EMIT       = 2'd2,
        PAD_EMIT   = 2'd3
    } state_t;

    state_t state_r, next_state;
    logic output_slot_open;

    assign output_slot_open = ~wr_valid | wr_ready;

    //  state register 
    always_ff @(posedge clk) begin
        state_r <= next_state;

        if (rst)
            state_r <= IDLE;
    end

    // next state + output logic
    always_comb begin
        next_state      = state_r;
        byte_ready      = 1'b0;
        cfg_we          = 1'b0;
        accum_we        = 1'b0;
        accum_sel       = 2'b00;
        bits_we         = 1'b0;
        bits_sel        = 2'b00;
        neur_byte_we    = 1'b0;
        neur_byte_clr   = 1'b0;
        neuron_we       = 1'b0;
        neuron_clr      = 1'b0;
        word_we         = 1'b0;
        word_clr        = 1'b0;
        txn_we          = 1'b0;
        pad_sel         = 1'b0;

        case (state_r)

            IDLE: begin
                if (cfg_load && output_slot_open) begin
                    cfg_we     = 1'b1;
                    next_state = ACCUMULATE;
                end
            end

            ACCUMULATE: begin
                byte_ready = output_slot_open;

                if (byte_valid && output_slot_open) begin
                    accum_we      = 1'b1;
                    accum_sel     = 2'b00;
                    bits_we       = 1'b1;
                    bits_sel      = 2'b00;
                    neur_byte_we  = 1'b1;
                    neur_byte_clr = 1'b0;

                    if (bits_after_byte >= BIA_W'(P_W)) begin
                        next_state = EMIT;
                    end else if (neuron_bytes_done && (bits_after_byte > '0)) begin
                        next_state = PAD_EMIT;
                    end else if (neuron_bytes_done) begin
                        neur_byte_clr = 1'b1;
                        neuron_we     = 1'b1;
                        word_we       = 1'b1;
                        word_clr      = 1'b1;

                        if (last_neuron)
                            next_state = IDLE;
                        else
                            next_state = ACCUMULATE;
                    end
                end
            end

            EMIT: begin
                pad_sel = 1'b0;

                if (output_slot_open) begin
                    txn_we    = 1'b1;
                    accum_we  = 1'b1;
                    accum_sel = 2'b01;
                    bits_we   = 1'b1;
                    bits_sel  = 2'b01;
                    word_we   = 1'b1;
                    word_clr  = 1'b0;

                    if (last_word) begin
                        accum_sel     = 2'b10;
                        bits_sel      = 2'b10;
                        neuron_we     = 1'b1;
                        neur_byte_we  = 1'b1;
                        neur_byte_clr = 1'b1;
                        word_clr      = 1'b1;

                        if (last_neuron)
                            next_state = IDLE;
                        else
                            next_state = ACCUMULATE;
                    end else if (bits_after_emit >= BIA_W'(P_W)) begin
                        next_state = EMIT;
                    end else if (neuron_bytes_complete && (bits_after_emit > '0)) begin
                        next_state = PAD_EMIT;
                    end else begin
                        next_state = ACCUMULATE;
                    end
                end
            end

            PAD_EMIT: begin
                pad_sel = 1'b1;

                if (output_slot_open) begin
                    txn_we        = 1'b1;
                    accum_we      = 1'b1;
                    accum_sel     = 2'b10;
                    bits_we       = 1'b1;
                    bits_sel      = 2'b10;
                    word_we       = 1'b1;
                    word_clr      = 1'b1;
                    neuron_we     = 1'b1;
                    neur_byte_we  = 1'b1;
                    neur_byte_clr = 1'b1;

                    if (last_neuron)
                        next_state = IDLE;
                    else
                        next_state = ACCUMULATE;
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule
