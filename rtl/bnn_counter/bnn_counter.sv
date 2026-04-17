`timescale 1ns/1ps

module bnn_counter #(
    parameter int WIDTH     = 8,
    parameter int RESET_VAL = 0
)(
    input  logic               clk,
    input  logic               rst,
    // Control
    input  logic               en,         // count enable
    input  logic               load,       // synchronous parallel load
    input  logic [WIDTH-1:0]   load_val,   // value to load
    input  logic [WIDTH-1:0]   max_val,    // terminal count target
    // Status
    output logic [WIDTH-1:0]   count,      // current count (registered)
    output logic               tc,         // combinational: count == max_val
    output logic               tc_pulse    // registered 1-cycle strobe
);

    bnn_counter_dp #(
        .WIDTH     (WIDTH),
        .RESET_VAL (RESET_VAL)
    ) u_dp (
        .clk      (clk),
        .rst      (rst),
        .en       (en),
        .load     (load),
        .load_val (load_val),
        .max_val  (max_val),
        .count    (count),
        .tc       (tc),
        .tc_pulse (tc_pulse)
    );

endmodule
