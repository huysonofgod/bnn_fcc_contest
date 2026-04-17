`timescale 1ns/10ps

module bnn_score_collector #(
    parameter int P_N         = 8,
    parameter int NUM_NEURONS = 10,
    parameter int ACC_W       = 8,
    localparam int PASSES   = (NUM_NEURONS + P_N - 1) / P_N,
    localparam int SCORE_W  = NUM_NEURONS * ACC_W,
    localparam int NP_CNT_W = $clog2(P_N + 1)
)(
    input  logic                  clk,
    input  logic                  rst,
    // Input
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic [P_N*ACC_W-1:0]  s_scores,
    input  logic [NP_CNT_W-1:0]   s_count,
    input  logic                  s_last_pass,
    // Output
    output logic                  m_valid,
    input  logic                  m_ready,
    output logic [SCORE_W-1:0]    m_scores,
    output logic                  m_last
);

    logic store_we;
    logic pass_cnt_we;
    logic pass_cnt_clr;
    logic output_we;
    logic m_valid_d;

    logic pass_tc;

    //  FSM 
    bnn_score_collector_fsm u_fsm (
        .clk         (clk),
        .rst         (rst),
        .s_valid     (s_valid),
        .s_ready     (s_ready),
        .s_last_pass (s_last_pass),
        .m_ready     (m_ready),
        .pass_tc     (pass_tc),
        .store_we    (store_we),
        .pass_cnt_we (pass_cnt_we),
        .pass_cnt_clr(pass_cnt_clr),
        .output_we   (output_we),
        .m_valid_d   (m_valid_d)
    );

    //  Datapath 
    bnn_score_collector_dp #(
        .P_N         (P_N),
        .NUM_NEURONS (NUM_NEURONS),
        .ACC_W       (ACC_W)
    ) u_dp (
        .clk         (clk),
        .rst         (rst),
        .s_scores    (s_scores),
        .s_count     (s_count),
        .store_we    (store_we),
        .pass_cnt_we (pass_cnt_we),
        .pass_cnt_clr(pass_cnt_clr),
        .output_we   (output_we),
        .m_valid_d   (m_valid_d),
        .pass_tc     (pass_tc),
        .m_valid     (m_valid),
        .m_scores    (m_scores),
        .m_last      (m_last)
    );

endmodule
