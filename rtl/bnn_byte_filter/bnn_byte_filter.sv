module bnn_byte_filter #(
    parameter int BUS_WIDTH = 64
)(
    input  logic                    clk,
    input  logic                    rst,
    // AXI4-Stream slave
    input  logic                    s_valid,
    output logic                    s_ready,
    input  logic [BUS_WIDTH-1:0]    s_data,
    input  logic [BUS_WIDTH/8-1:0]  s_keep,
    input  logic                    s_last,
    // Byte-stream master
    output logic                    m_valid,
    output logic [7:0]              m_data,
    output logic                    m_last,
    input  logic                    m_ready
);

    //  Internal wires 
    logic accept_word;
    logic idx_we;
    logic idx_clr;
    logic in_serialize;
    logic at_end;

    //  FSM 
    bnn_byte_filter_fsm u_fsm (
        .clk         (clk),
        .rst         (rst),
        .s_valid     (s_valid),
        .s_ready     (s_ready),
        .m_valid     (m_valid),
        .m_ready     (m_ready),
        .at_end      (at_end),
        .accept_word (accept_word),
        .idx_we      (idx_we),
        .idx_clr     (idx_clr),
        .in_serialize(in_serialize)
    );

    //  Datapath 
    bnn_byte_filter_dp #(
        .BUS_WIDTH (BUS_WIDTH)
    ) u_dp (
        .clk         (clk),
        .rst         (rst),
        .accept_word (accept_word),
        .s_data      (s_data),
        .s_keep      (s_keep),
        .s_last      (s_last),
        .idx_we      (idx_we),
        .idx_clr     (idx_clr),
        .in_serialize(in_serialize),
        .at_end      (at_end),
        .m_ready     (m_ready),
        .m_valid     (m_valid),
        .m_data      (m_data),
        .m_last      (m_last)
    );

endmodule
