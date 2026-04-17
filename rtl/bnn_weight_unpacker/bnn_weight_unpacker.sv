`timescale 1ns/10ps

module bnn_weight_unpacker #(
    parameter int P_W    = 8,
    parameter int P_N    = 8,
    parameter int LID_W  = 4,
    parameter int NPID_W = 8,
    parameter int ADDR_W = 16
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic [15:0]           cfg_fan_in,
    input  logic [15:0]           cfg_bytes_per_neuron,
    input  logic [15:0]           cfg_num_neurons,
    input  logic [LID_W-1:0]      cfg_layer_id,
    input  logic                  cfg_load,
    input  logic                  byte_valid,
    output logic                  byte_ready,
    input  logic [7:0]            byte_data,
    output logic                  wr_valid,
    input  logic                  wr_ready,
    output logic [LID_W-1:0]      wr_layer,
    output logic [NPID_W-1:0]     wr_np,
    output logic [ADDR_W-1:0]     wr_addr,
    output logic [P_W-1:0]        wr_data,
    output logic                  wr_last_word,
    output logic                  wr_last_neuron,
    output logic                  wr_last_msg
);

    localparam int ACCUM_W = P_W + 8;
    localparam int BIA_W   = $clog2(ACCUM_W + 1);

    //  control wires 
    logic       cfg_we;
    logic       accum_we;
    logic [1:0] accum_sel;
    logic       bits_we;
    logic [1:0] bits_sel;
    logic       neur_byte_we;
    logic       neur_byte_clr;
    logic       neuron_we;
    logic       neuron_clr;
    logic       word_we;
    logic       word_clr;
    logic       txn_we;
    logic       pad_sel;

    logic [BIA_W-1:0] bits_after_byte;
    logic [BIA_W-1:0] bits_after_emit;
    logic             neuron_bytes_done;
    logic             neuron_bytes_complete;
    logic             last_word;
    logic             last_neuron;

    //  FSM 
    bnn_unpack_ctrl #(
        .P_W (P_W)
    ) u_ctrl (
        .clk              (clk),
        .rst              (rst),
        .cfg_load         (cfg_load),
        .byte_valid       (byte_valid),
        .byte_ready       (byte_ready),
        .wr_valid         (wr_valid),
        .wr_ready         (wr_ready),
        .bits_after_byte  (bits_after_byte),
        .bits_after_emit  (bits_after_emit),
        .neuron_bytes_done(neuron_bytes_done),
        .neuron_bytes_complete(neuron_bytes_complete),
        .last_word        (last_word),
        .last_neuron      (last_neuron),
        .cfg_we           (cfg_we),
        .accum_we         (accum_we),
        .accum_sel        (accum_sel),
        .bits_we          (bits_we),
        .bits_sel         (bits_sel),
        .neur_byte_we     (neur_byte_we),
        .neur_byte_clr    (neur_byte_clr),
        .neuron_we        (neuron_we),
        .neuron_clr       (neuron_clr),
        .word_we          (word_we),
        .word_clr         (word_clr),
        .txn_we           (txn_we),
        .pad_sel          (pad_sel)
    );

    //  Datapath
    bnn_unpack_datapath #(
        .P_W    (P_W),
        .P_N    (P_N),
        .LID_W  (LID_W),
        .NPID_W (NPID_W),
        .ADDR_W (ADDR_W)
    ) u_dp (
        .clk              (clk),
        .rst              (rst),
        .cfg_fan_in       (cfg_fan_in),
        .cfg_bytes_per_neuron(cfg_bytes_per_neuron),
        .cfg_num_neurons  (cfg_num_neurons),
        .cfg_layer_id     (cfg_layer_id),
        .cfg_we           (cfg_we),
        .byte_data        (byte_data),
        .wr_ready         (wr_ready),
        .accum_we         (accum_we),
        .accum_sel        (accum_sel),
        .bits_we          (bits_we),
        .bits_sel         (bits_sel),
        .neur_byte_we     (neur_byte_we),
        .neur_byte_clr    (neur_byte_clr),
        .neuron_we        (neuron_we),
        .neuron_clr       (neuron_clr),
        .word_we          (word_we),
        .word_clr         (word_clr),
        .txn_we           (txn_we),
        .pad_sel          (pad_sel),
        .bits_after_byte  (bits_after_byte),
        .bits_after_emit  (bits_after_emit),
        .neuron_bytes_done(neuron_bytes_done),
        .neuron_bytes_complete(neuron_bytes_complete),
        .last_word        (last_word),
        .last_neuron      (last_neuron),
        .wr_valid         (wr_valid),
        .wr_layer         (wr_layer),
        .wr_np            (wr_np),
        .wr_addr          (wr_addr),
        .wr_data          (wr_data),
        .wr_last_word     (wr_last_word),
        .wr_last_neuron   (wr_last_neuron),
        .wr_last_msg      (wr_last_msg)
    );

endmodule
