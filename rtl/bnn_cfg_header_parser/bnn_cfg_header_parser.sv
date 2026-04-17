`timescale 1ns/10ps

module bnn_cfg_header_parser (
    input  logic       clk,
    input  logic       rst,
    // Byte input stream
    input  logic       byte_valid,
    output logic       byte_ready,
    input  logic [7:0] byte_data,
    input  logic       byte_last,
    // Parsed header outputs (combinational, valid when hdr_valid pulses)
    output logic       hdr_valid,
    output logic [7:0]  hdr_msg_type,
    output logic [7:0]  hdr_layer_id,
    output logic [15:0] hdr_layer_inputs,
    output logic [15:0] hdr_num_neurons,
    output logic [15:0] hdr_bytes_per_neuron,
    output logic [31:0] hdr_total_bytes,
    // Payload pass-through
    output logic       payload_valid,
    input  logic       payload_ready,
    output logic [7:0] payload_data,
    output logic       payload_last_byte,  // last payload byte of message
    output logic       msg_done            // message complete pulse
);

    // FSM control signals
    logic hdr_sr_we;
    logic hdr_byte_we;
    logic hdr_byte_clr;
    logic total_bytes_we;
    logic pld_byte_we;
    logic pld_byte_clr;
    logic saw_last_set;
    logic in_payload;

    // FSM status signals
    logic hdr_complete;
    logic payload_done;
    logic saw_last_r_q;

    // FSM instance
    bnn_cfg_header_parser_fsm u_fsm (
        .clk              (clk),
        .rst              (rst),
        .byte_valid       (byte_valid),
        .byte_ready       (byte_ready),
        .byte_last        (byte_last),
        .payload_ready    (payload_ready),
        .payload_valid    (payload_valid),
        .payload_last_byte(payload_last_byte),
        .msg_done         (msg_done),
        .hdr_valid        (hdr_valid),
        .hdr_sr_we        (hdr_sr_we),
        .hdr_byte_we      (hdr_byte_we),
        .hdr_byte_clr     (hdr_byte_clr),
        .total_bytes_we   (total_bytes_we),
        .pld_byte_we      (pld_byte_we),
        .pld_byte_clr     (pld_byte_clr),
        .saw_last_set     (saw_last_set),
        .in_payload       (in_payload),
        .hdr_complete     (hdr_complete),
        .payload_done     (payload_done),
        .saw_last_r_q     (saw_last_r_q),
        .hdr_total_bytes  (hdr_total_bytes)
    );

    // Datapath instance
    bnn_cfg_header_parser_dp u_dp (
        .clk                 (clk),
        .rst                 (rst),
        .byte_data           (byte_data),
        .byte_last           (byte_last),
        .hdr_sr_we           (hdr_sr_we),
        .hdr_byte_we         (hdr_byte_we),
        .hdr_byte_clr        (hdr_byte_clr),
        .total_bytes_we      (total_bytes_we),
        .pld_byte_we         (pld_byte_we),
        .pld_byte_clr        (pld_byte_clr),
        .saw_last_set        (saw_last_set),
        .in_payload          (in_payload),
        .hdr_complete        (hdr_complete),
        .payload_done        (payload_done),
        .saw_last_r_q        (saw_last_r_q),
        .hdr_msg_type        (hdr_msg_type),
        .hdr_layer_id        (hdr_layer_id),
        .hdr_layer_inputs    (hdr_layer_inputs),
        .hdr_num_neurons     (hdr_num_neurons),
        .hdr_bytes_per_neuron(hdr_bytes_per_neuron),
        .hdr_total_bytes     (hdr_total_bytes),
        .payload_data        (payload_data)
    );

endmodule
