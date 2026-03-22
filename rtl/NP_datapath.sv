module NP_datapath #(
    parameter int P_W               = 8,
    parameter int MAX_NEURON_INPUTS = 784,
    parameter int BEAT_PC_W         = $clog2(P_W + 1),
    parameter int ACC_W             = $clog2(MAX_NEURON_INPUTS + 1)
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [P_W-1:0]       x_in,
    input  logic [P_W-1:0]       w_in,
    input  logic [ACC_W-1:0]     threshold_in,

    input  logic                 acc_we,
    input  logic                 acc_clr,
    input  logic                 out_we,

    output logic [ACC_W-1:0]     popcount_out,
    output logic                 act_out,
    output logic                 valid_out,
    //DEBUG SIGNALS ---delete once verified correct---
    output logic [P_W-1:0]       dbg_xnor_bits,
    output logic [BEAT_PC_W-1:0] dbg_beat_popcount,
    output logic [ACC_W-1:0]     dbg_accum
);

    logic [P_W-1:0]       xnor_bits;
    logic [BEAT_PC_W-1:0] beat_popcount;
    logic [ACC_W-1:0]     beat_popcount_ext;
    logic [ACC_W-1:0]     final_sum;
    logic [ACC_W-1:0]     accum_q;

    // Compute XNOR and popcount
    assign xnor_bits = ~(x_in ^ w_in);
    assign beat_popcount = $countones(xnor_bits);
    // Extend popcount to match accumulator width and compute final sum
    assign beat_popcount_ext = ACC_W'(beat_popcount);

    // Sequential logic for accumulator and output registers
    always_ff @(posedge clk) begin
        // Update accumulator
        if (acc_we) begin
            if (acc_clr)
                accum_q <= '0;
            else
                accum_q <= final_sum;
        end
        // Update output registers
        if (out_we) begin
            popcount_out <= final_sum;
            act_out      <= (final_sum >= threshold_in);
        end
        valid_out <= out_we;
        // Reset logic
        if (rst) begin
            accum_q      <= '0;
            popcount_out <= '0;
            act_out      <= 1'b0;
            valid_out    <= 1'b0;
        end
    end

    // Compute final sum for the current beat
    assign final_sum = accum_q + beat_popcount_ext;

    //DEBUG SIGNALS
    assign dbg_xnor_bits     = xnor_bits;
    assign dbg_beat_popcount = beat_popcount;
    assign dbg_accum         = accum_q;

endmodule
