`timescale 1ns/10ps

module bnn_argmax #(
    parameter int NUM_CLASSES = 10,
    parameter int ACC_W       = 10,
    localparam int IDX_W      = $clog2(NUM_CLASSES > 1 ? NUM_CLASSES : 2),
    localparam int STAGES     = $clog2(NUM_CLASSES > 1 ? NUM_CLASSES : 2)
)(
    input  logic                           clk,
    input  logic                           rst,

    
    input  logic                           s_valid,
    output logic                           s_ready,
    input  logic [NUM_CLASSES*ACC_W-1:0]   s_scores,
    input  logic                           s_last,

    
    output logic                           m_valid,
    input  logic                           m_ready,
    output logic [IDX_W-1:0]               m_idx,
    output logic                           m_last
);

    
    function automatic int stage_cnt(input int s);
        int c;
        c = NUM_CLASSES;
        for (int i = 0; i < s; i++)
            c = (c + 1) / 2;
        return c;
    endfunction

    
    // Every stage register array is sized to NUM_CLASSES lanes for simplicity;
    // only the first stage_cnt(s) lanes carry meaningful data at stage s.
    logic [IDX_W-1:0]  idx_r_q   [STAGES+1][NUM_CLASSES];
    logic [ACC_W-1:0]  score_r_q [STAGES+1][NUM_CLASSES];
    logic              valid_r_q [STAGES+1];
    logic              last_r_q  [STAGES+1];

    // Global pipeline enable (stall on occupied output slot).
    logic pipe_en;
    logic out_valid_r_q;
    logic [IDX_W-1:0] out_idx_r_q;
    logic out_last_r_q;

    assign pipe_en = ~out_valid_r_q | m_ready;
    assign s_ready = pipe_en;

    
    genvar gi, gs;
    generate
        for (gi = 0; gi < NUM_CLASSES; gi++) begin : g_stage0
            always_ff @(posedge clk) begin
                if (pipe_en) begin
                    score_r_q[0][gi] <= s_scores[gi*ACC_W +: ACC_W];
                    idx_r_q  [0][gi] <= IDX_W'(gi);
                end

                if (rst) begin
                    score_r_q[0][gi] <= '0;
                    idx_r_q  [0][gi] <= '0;
                end
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (pipe_en) begin
            valid_r_q[0] <= s_valid;
            last_r_q [0] <= s_last;
        end

        if (rst) begin
            valid_r_q[0] <= 1'b0;
            last_r_q [0] <= 1'b0;
        end
    end

    
    generate
        for (gs = 0; gs < STAGES; gs++) begin : g_stage
            localparam int CNT_IN  = stage_cnt(gs);
            localparam int PAIRS   = CNT_IN / 2;
            localparam int CARRY   = CNT_IN % 2;
            localparam int CNT_OUT = PAIRS + CARRY;

            for (gi = 0; gi < PAIRS; gi++) begin : g_pair
                logic [IDX_W-1:0] a_idx, b_idx, w_idx;
                logic [ACC_W-1:0] a_sc,  b_sc,  w_sc;

                assign a_idx = idx_r_q  [gs][2*gi];
                assign b_idx = idx_r_q  [gs][2*gi + 1];
                assign a_sc  = score_r_q[gs][2*gi];
                assign b_sc  = score_r_q[gs][2*gi + 1];

                // First-wins tie-break: a_idx < b_idx, so `>=` picks a on ties.
                assign w_idx = (a_sc >= b_sc) ? a_idx : b_idx;
                assign w_sc  = (a_sc >= b_sc) ? a_sc  : b_sc;

                always_ff @(posedge clk) begin
                    if (pipe_en) begin
                        idx_r_q  [gs+1][gi] <= w_idx;
                        score_r_q[gs+1][gi] <= w_sc;
                    end

                    if (rst) begin
                        idx_r_q  [gs+1][gi] <= '0;
                        score_r_q[gs+1][gi] <= '0;
                    end
                end
            end

            if (CARRY == 1) begin : g_carry
                always_ff @(posedge clk) begin
                    if (pipe_en) begin
                        idx_r_q  [gs+1][PAIRS] <= idx_r_q  [gs][CNT_IN - 1];
                        score_r_q[gs+1][PAIRS] <= score_r_q[gs][CNT_IN - 1];
                    end

                    if (rst) begin
                        idx_r_q  [gs+1][PAIRS] <= '0;
                        score_r_q[gs+1][PAIRS] <= '0;
                    end
                end
            end

            // Lanes above CNT_OUT at stage gs+1 are never read by later stages
            // or by the output; leaving them undriven lets synthesis prune them.

            always_ff @(posedge clk) begin
                if (pipe_en) begin
                    valid_r_q[gs+1] <= valid_r_q[gs];
                    last_r_q [gs+1] <= last_r_q [gs];
                end

                if (rst) begin
                    valid_r_q[gs+1] <= 1'b0;
                    last_r_q [gs+1] <= 1'b0;
                end
            end
        end
    endgenerate

    
    always_ff @(posedge clk) begin
        if (pipe_en) begin
            out_valid_r_q <= valid_r_q[STAGES];
            out_idx_r_q   <= idx_r_q  [STAGES][0];
            out_last_r_q  <= last_r_q [STAGES];
        end

        if (rst) begin
            out_valid_r_q <= 1'b0;
            out_idx_r_q   <= '0;
            out_last_r_q  <= 1'b0;
        end
    end

    assign m_valid = out_valid_r_q;
    assign m_idx   = out_idx_r_q;
    assign m_last  = out_last_r_q;

    
    initial begin
        assert (NUM_CLASSES >= 2) else $fatal(1, "bnn_argmax: NUM_CLASSES must be >= 2");
        assert (ACC_W >= 1) else $fatal(1, "bnn_argmax: ACC_W must be >= 1");
        $display("bnn_argmax: NUM_CLASSES=%0d ACC_W=%0d IDX_W=%0d STAGES=%0d",
                 NUM_CLASSES, ACC_W, IDX_W, STAGES);
    end

endmodule
