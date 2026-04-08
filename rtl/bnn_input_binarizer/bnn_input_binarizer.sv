module bnn_input_binarizer #(
    parameter int BUS_WIDTH = 64,
    parameter int P_W       = 8
)(
    input  logic               clk,
    input  logic               rst,
    // AXI4-Stream slave
    input  logic               s_valid,
    input  logic [BUS_WIDTH-1:0] s_data,
    input  logic [P_W-1:0]    s_keep,
    input  logic               s_last,
    output logic               s_ready,
    // AXI4-Stream master
    output logic               m_valid,
    output logic [P_W-1:0]    m_data,
    output logic               m_last,
    input  logic               m_ready
);

    bnn_input_binarizer_dp #(
        .BUS_WIDTH (BUS_WIDTH),
        .P_W       (P_W)
    ) u_dp (
        .clk     (clk),
        .rst     (rst),
        .s_valid (s_valid),
        .s_data  (s_data),
        .s_keep  (s_keep),
        .s_last  (s_last),
        .s_ready (s_ready),
        .m_valid (m_valid),
        .m_data  (m_data),
        .m_last  (m_last),
        .m_ready (m_ready)
    );

endmodule
