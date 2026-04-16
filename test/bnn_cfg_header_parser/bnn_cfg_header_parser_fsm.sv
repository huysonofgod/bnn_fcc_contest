`timescale 1ns/1ps

module bnn_cfg_header_parser_fsm (
    input  logic clk,
    input  logic rst,
    // Byte stream input
    input  logic byte_valid,
    output logic byte_ready,
    input  logic byte_last,
    // Payload downstream
    input  logic payload_ready,
    output logic payload_valid,
    output logic payload_last_byte,  // combinational pulse
    output logic msg_done,           // combinational pulse
    // Header pulse
    output logic hdr_valid,          // combinational pulse
    // Datapath control outputs
    output logic hdr_sr_we,
    output logic hdr_byte_we,
    output logic hdr_byte_clr,
    output logic total_bytes_we,
    output logic pld_byte_we,
    output logic pld_byte_clr,
    output logic saw_last_set,
    output logic in_payload,         // flag to datapath gating
    // Datapath status inputs
    input  logic hdr_complete,
    input  logic payload_done,
    input  logic saw_last_r_q,
    input  logic [31:0] hdr_total_bytes  // for empty-payload check
);

    typedef enum logic [1:0] {
        IDLE          = 2'd0,
        PARSE_HEADER  = 2'd1,
        ROUTE_PAYLOAD = 2'd2
    } state_t;

    state_t state_r, next_state;

    // ─── Process 1: State register ──────────────────────────────────────
    always_ff @(posedge clk) begin
        state_r <= next_state;

        if (rst)
            state_r <= IDLE;
    end

    // ─── Process 2: Next state + output logic ──────────────────────────
    always_comb begin
        next_state       = state_r;
        byte_ready       = 1'b0;
        payload_valid    = 1'b0;
        payload_last_byte= 1'b0;
        msg_done         = 1'b0;
        hdr_valid        = 1'b0;
        hdr_sr_we        = 1'b0;
        hdr_byte_we      = 1'b0;
        hdr_byte_clr     = 1'b0;
        total_bytes_we   = 1'b0;
        pld_byte_we      = 1'b0;
        pld_byte_clr     = 1'b0;
        saw_last_set     = 1'b0;
        in_payload       = 1'b0;

        case (state_r)

            IDLE: begin
                byte_ready  = 1'b0;
                // Unconditional: reset header counter and move to PARSE_HEADER
                hdr_byte_we  = 1'b1;
                hdr_byte_clr = 1'b1;
                next_state   = PARSE_HEADER;
            end

            PARSE_HEADER: begin
                byte_ready    = 1'b1;
                payload_valid = 1'b0;
                in_payload    = 1'b0;

                if (byte_valid) begin
                    hdr_sr_we    = 1'b1;
                    hdr_byte_we  = 1'b1;
                    hdr_byte_clr = 1'b0;  // advance
                    saw_last_set = 1'b1;   // capture byte_last

                    if (hdr_complete) begin
                        total_bytes_we = 1'b1;
                        hdr_valid      = 1'b1;  // pulse: header available
                        pld_byte_we    = 1'b1;
                        pld_byte_clr   = 1'b1;  // reset payload counter

                        if (hdr_total_bytes == 32'd0) begin
                            // Empty payload (shouldn't happen, but safe)
                            msg_done = 1'b1;
                            if (saw_last_r_q || byte_last)
                                next_state = IDLE;
                            else begin
                                hdr_byte_we  = 1'b1;
                                hdr_byte_clr = 1'b1;
                                next_state   = PARSE_HEADER;
                            end
                        end else begin
                            next_state = ROUTE_PAYLOAD;
                        end
                    end
                    // else: stay in PARSE_HEADER
                end
            end

            ROUTE_PAYLOAD: begin
                // Pass backpressure through to upstream
                byte_ready    = payload_ready;
                payload_valid = byte_valid;
                in_payload    = 1'b1;

                if (byte_valid & payload_ready) begin
                    pld_byte_we  = 1'b1;
                    pld_byte_clr = 1'b0;  // advance
                    saw_last_set = 1'b1;

                    if (payload_done) begin
                        payload_last_byte = 1'b1;
                        msg_done          = 1'b1;

                        if (saw_last_r_q || byte_last) begin
                            next_state = IDLE;
                        end else begin
                            // More messages follow in this stream
                            hdr_byte_we  = 1'b1;
                            hdr_byte_clr = 1'b1;
                            next_state   = PARSE_HEADER;
                        end
                    end
                    // else: stay in ROUTE_PAYLOAD
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule
