`timescale 1ns/10ps

module bnn_cfg_header_parser_dp (
    input  logic       clk,
    input  logic       rst,

    // Byte input
    input  logic [7:0] byte_data,
    input  logic       byte_last,

    // FSM control inputs
    input  logic       hdr_sr_we,        // shift header register
    input  logic       hdr_byte_we,      // advance byte counter
    input  logic       hdr_byte_clr,     // reset byte counter
    input  logic       total_bytes_we,   // latch total_bytes
    input  logic       pld_byte_we,      // advance payload counter
    input  logic       pld_byte_clr,     // reset payload counter
    input  logic       saw_last_set,     // capture byte_last into saw_last_r_q
    input  logic       in_payload,       // state flag: 1 when ROUTE_PAYLOAD

    // FSM status outputs
    output logic       hdr_complete,     // (hdr_byte_cnt == 15)
    output logic       payload_done,     // (payload_byte_cnt == total_bytes - 1)
    output logic       saw_last_r_q,     // registered: have we seen byte_last

    // Header field outputs (combinational from hdr_sr_r_q)
    output logic [7:0]  hdr_msg_type,
    output logic [7:0]  hdr_layer_id,
    output logic [15:0] hdr_layer_inputs,
    output logic [15:0] hdr_num_neurons,
    output logic [15:0] hdr_bytes_per_neuron,
    output logic [31:0] hdr_total_bytes,

    // Payload pass-through
    output logic [7:0]  payload_data      // = byte_data (wire)
);

    // Header shift register
    logic [127:0] hdr_sr_r_q;
    logic [127:0] hdr_sr_next;
    logic [127:0] hdr_sr_view;

    // Right-shift: new byte at top (MSB); old bytes shift toward LSB
    assign hdr_sr_next = {byte_data, hdr_sr_r_q[127:8]};
    assign hdr_sr_view = hdr_sr_we ? hdr_sr_next : hdr_sr_r_q;

    always_ff @(posedge clk) begin
        if (hdr_sr_we)
            hdr_sr_r_q <= hdr_sr_next;

        // Optional reset: data is masked by hdr_valid
        if (rst)
            hdr_sr_r_q <= '0;
    end

    // Header byte counter (0..15)
    logic [3:0] hdr_byte_cnt_r_q;
    logic [3:0] hdr_byte_cnt_next;

    assign hdr_complete      = (hdr_byte_cnt_r_q == 4'd15);
    assign hdr_byte_cnt_next = hdr_byte_clr ? 4'd0 : (hdr_byte_cnt_r_q + 4'd1);

    always_ff @(posedge clk) begin
        if (hdr_byte_we)
            hdr_byte_cnt_r_q <= hdr_byte_cnt_next;

        if (rst)
            hdr_byte_cnt_r_q <= 4'd0;
    end

    // Header field extraction (combinational)
    // Byte 0 arrives first; after 16 right shifts, byte 0 is at [7:0]
    assign hdr_msg_type         = hdr_sr_view[7:0];
    assign hdr_layer_id         = hdr_sr_view[15:8];
    assign hdr_layer_inputs     = hdr_sr_view[31:16];
    assign hdr_num_neurons      = hdr_sr_view[47:32];
    assign hdr_bytes_per_neuron = hdr_sr_view[63:48];
    assign hdr_total_bytes      = hdr_sr_view[95:64];

    // Total bytes latch and payload byte counter
    logic [31:0] total_bytes_r_q;

    always_ff @(posedge clk) begin
        if (total_bytes_we)
            total_bytes_r_q <= hdr_sr_view[95:64];  // include current shifted byte

        if (rst)
            total_bytes_r_q <= 32'd0;
    end

    logic [31:0] payload_byte_cnt_r_q;
    logic [31:0] pld_byte_cnt_next;

    // payload_done: last payload byte (0-indexed up to total_bytes-1)
    assign payload_done    = (payload_byte_cnt_r_q == (total_bytes_r_q - 32'd1));
    assign pld_byte_cnt_next = pld_byte_clr ? 32'd0 : (payload_byte_cnt_r_q + 32'd1);

    always_ff @(posedge clk) begin
        if (pld_byte_we)
            payload_byte_cnt_r_q <= pld_byte_cnt_next;

        if (rst)
            payload_byte_cnt_r_q <= 32'd0;
    end

    // Payload pass-through
    // Zero-latency wire: payload bytes pass straight through
    assign payload_data = byte_data;

    // Stream-end tracking
    logic saw_last_next;
    assign saw_last_next = byte_last | saw_last_r_q;

    always_ff @(posedge clk) begin
        if (saw_last_set)
            saw_last_r_q <= saw_last_next;

        if (rst)
            saw_last_r_q <= 1'b0;
    end

endmodule
