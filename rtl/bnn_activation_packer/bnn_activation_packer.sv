`timescale 1ns/10ps

module bnn_activation_packer #(
    parameter int IN_BITS  = 8,   // P_N (activations per NP pass)
    parameter int OUT_BITS = 8    // P_W_NEXT (weight width of next layer)
)(
    input  logic               clk,
    input  logic               rst,
    // Input: activation groups from layer_ctrl
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [IN_BITS-1:0] s_data,
    input  logic [$clog2(IN_BITS+1)-1:0] s_count,  // valid bit count
    input  logic               s_last_group,        // final pass
    // Output: packed binary vectors
    output logic               m_valid,
    input  logic               m_ready,
    output logic [OUT_BITS-1:0] m_data,
    output logic               m_last
);

    localparam int ACCUM_W   = IN_BITS + OUT_BITS;
    localparam int BIT_CNT_W = $clog2(ACCUM_W + 1);

    
    logic        accum_we;
    logic [1:0]  accum_sel;
    logic        bits_we;
    logic [1:0]  bits_sel;
    logic        out_we;
    logic        out_valid_d;
    logic        m_last_d;
    logic        flush_set;
    logic        flush_clr;

    
    logic                  can_emit;
    logic                  has_residual;
    logic [BIT_CNT_W-1:0]  bits_after_merge;
    logic [BIT_CNT_W-1:0]  bits_after_emit;
    logic                  flushing_r_q;

    
    bnn_activation_packer_fsm #(
        .IN_BITS  (IN_BITS),
        .OUT_BITS (OUT_BITS)
    ) u_fsm (
        .clk             (clk),
        .rst             (rst),
        .s_valid         (s_valid),
        .s_ready         (s_ready),
        .s_last_group    (s_last_group),
        .m_valid         (m_valid),
        .m_ready         (m_ready),
        .m_last          (m_last),
        .bits_after_merge(bits_after_merge),
        .bits_after_emit (bits_after_emit),
        .can_emit        (can_emit),
        .has_residual    (has_residual),
        .flushing_r_q    (flushing_r_q),
        .accum_we        (accum_we),
        .accum_sel       (accum_sel),
        .bits_we         (bits_we),
        .bits_sel        (bits_sel),
        .out_we          (out_we),
        .out_valid_d     (out_valid_d),
        .m_last_d        (m_last_d),
        .flush_set       (flush_set),
        .flush_clr       (flush_clr)
    );

    
    bnn_activation_packer_dp #(
        .IN_BITS  (IN_BITS),
        .OUT_BITS (OUT_BITS)
    ) u_dp (
        .clk             (clk),
        .rst             (rst),
        .s_data          (s_data),
        .s_count         (s_count),
        .accum_we        (accum_we),
        .accum_sel       (accum_sel),
        .bits_we         (bits_we),
        .bits_sel        (bits_sel),
        .out_we          (out_we),
        .out_valid_d     (out_valid_d),
        .flush_set       (flush_set),
        .flush_clr       (flush_clr),
        .m_last_d        (m_last_d),
        .m_ready         (m_ready),
        .can_emit        (can_emit),
        .has_residual    (has_residual),
        .bits_after_merge(bits_after_merge),
        .bits_after_emit (bits_after_emit),
        .flushing_r_q    (flushing_r_q),
        .m_valid         (m_valid),
        .m_data          (m_data),
        .m_last          (m_last)
    );

endmodule
