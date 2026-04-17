`timescale 1ns/10ps

module bnn_score_collector_dp #(
    parameter int P_N         = 8,
    parameter int NUM_NEURONS = 10,
    parameter int ACC_W       = 8,
    localparam int PASSES    = (NUM_NEURONS + P_N - 1) / P_N,
    localparam int SCORE_W   = NUM_NEURONS * ACC_W,
    localparam int NP_CNT_W  = $clog2(P_N + 1),
    localparam int PASS_W    = $clog2(PASSES > 1 ? PASSES : 2)
)(
    input  logic                      clk,
    input  logic                      rst,

    // Input score data
    input  logic [P_N*ACC_W-1:0]     s_scores,
    input  logic [NP_CNT_W-1:0]      s_count,

    // FSM control inputs
    input  logic                      store_we,       // write score bank
    input  logic                      pass_cnt_we,    // advance/clear pass counter
    input  logic                      pass_cnt_clr,   // select clear (D1=0)
    input  logic                      output_we,      // latch flat_scores → m_scores
    input  logic                      m_valid_d,      // D-input for M_VALID REG

    // FSM status outputs
    output logic                      pass_tc,        // pass counter at PASSES-1

    // Downstream outputs
    output logic                      m_valid,
    output logic [SCORE_W-1:0]        m_scores,
    output logic                      m_last           // = m_valid (1 result per image)
);

    
    logic [ACC_W-1:0] score_bank [0:NUM_NEURONS-1];

    
    logic [PASS_W-1:0] pass_cnt_r_q;
    logic [PASS_W-1:0] pass_cnt_next;

    assign pass_tc       = (pass_cnt_r_q == PASS_W'(PASSES - 1));
    assign pass_cnt_next = pass_cnt_clr ? '0 : (pass_cnt_r_q + 1'b1);

    always_ff @(posedge clk) begin
        if (pass_cnt_we)
            pass_cnt_r_q <= pass_cnt_next;

        if (rst)
            pass_cnt_r_q <= '0;
    end

    
    // base_idx = pass_cnt_r_q * P_N
    logic [$clog2(NUM_NEURONS > 1 ? NUM_NEURONS : 2)-1:0] base_idx;
    assign base_idx = $clog2(NUM_NEURONS > 1 ? NUM_NEURONS : 2)'(pass_cnt_r_q) *
                      $clog2(NUM_NEURONS > 1 ? NUM_NEURONS : 2)'(P_N);

    // Generate parallel write ports for each NP slot
    always_ff @(posedge clk) begin
        if (store_we) begin
            for (int i = 0; i < P_N; i++) begin
                // Only write if this slot is within s_count valid entries
                if (NP_CNT_W'(i) < s_count) begin
                    if ((base_idx + i) < NUM_NEURONS)
                        score_bank[base_idx + i] <= s_scores[i*ACC_W +: ACC_W];
                end
            end
        end

        if (rst) begin
            for (int i = 0; i < NUM_NEURONS; i++)
                score_bank[i] <= '0;
        end
    end

    
    logic [SCORE_W-1:0] flat_scores;
    generate
        genvar j;
        for (j = 0; j < NUM_NEURONS; j++) begin : gen_flatten
            assign flat_scores[j*ACC_W +: ACC_W] = score_bank[j];
        end
    endgenerate

    // When output_we and store_we happen together on the final pass,
    // m_scores must include scores written in that same cycle.
    logic [SCORE_W-1:0] flat_scores_post_store;
    always_comb begin
        int base_idx_int;
        base_idx_int = int'(base_idx);

        for (int j = 0; j < NUM_NEURONS; j++) begin
            logic [ACC_W-1:0] score_j;
            score_j = score_bank[j];

            if (store_we) begin
                for (int i = 0; i < P_N; i++) begin
                    if ((NP_CNT_W'(i) < s_count) && ((base_idx_int + i) == j))
                        score_j = s_scores[i*ACC_W +: ACC_W];
                end
            end

            flat_scores_post_store[j*ACC_W +: ACC_W] = score_j;
        end
    end

    
    logic [SCORE_W-1:0] m_scores_r_q;

    always_ff @(posedge clk) begin
        if (output_we)
            m_scores_r_q <= flat_scores_post_store;

        if (rst)
            m_scores_r_q <= '0;
    end

    
    logic m_valid_r_q;

    always_ff @(posedge clk) begin
        m_valid_r_q <= m_valid_d;

        if (rst)
            m_valid_r_q <= 1'b0;
    end

    
    assign m_valid  = m_valid_r_q;
    assign m_scores = m_scores_r_q;
    assign m_last   = m_valid_r_q;  // always 1 when valid (one result per image)

endmodule
