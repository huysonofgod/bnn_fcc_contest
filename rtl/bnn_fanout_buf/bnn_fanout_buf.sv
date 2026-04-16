`timescale 1ns / 100ps

module bnn_fanout_buf #(
    parameter int WIDTH       = 8,
    parameter int PIPE_STAGES = 0    // 0 = passthrough, >=1 = registered
) (
    input  logic             clk,
    input  logic             rst,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

    generate
        if (PIPE_STAGES == 0) begin : g_passthrough
            // Zero-latency wire passthrough
            assign q = d;

        end else begin : g_pipe
            // Registered pipeline with PIPE_STAGES stages
            (* max_fanout = "auto" *)
            logic [WIDTH-1:0] pipe_r_q [PIPE_STAGES];

            // Stage 0: input capture
            always_ff @(posedge clk) begin
                if (rst)  pipe_r_q[0] <= '0;
                else      pipe_r_q[0] <= d;
            end

            // Stages 1..N-1: chain
            for (genvar i = 1; i < PIPE_STAGES; i++) begin : g_stage
                always_ff @(posedge clk) begin
                    if (rst)  pipe_r_q[i] <= '0;
                    else      pipe_r_q[i] <= pipe_r_q[i-1];
                end
            end

            assign q = pipe_r_q[PIPE_STAGES-1];
        end
    endgenerate

    // Compile-time sanity checks
    initial begin
        assert (PIPE_STAGES >= 0 && PIPE_STAGES <= 4)
            else $fatal(1, "bnn_fanout_buf: PIPE_STAGES=%0d out of range [0..4]",
                        PIPE_STAGES);
    end

endmodule
