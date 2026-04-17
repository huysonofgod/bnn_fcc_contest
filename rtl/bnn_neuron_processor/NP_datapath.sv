module NP_datapath #(
    parameter int P_W               = 8,
    parameter int MAX_NEURON_INPUTS = 784,
//    parameter int THRES_W           = 32,
//    parameter int BEAT_PC_W         = $clog2(P_W + 1),
    parameter int ACC_W             = $clog2(MAX_NEURON_INPUTS + 1)
) (
    input  logic                 clk,
    input  logic                 rst,

    input  logic [P_W-1:0]       x_in,
    input  logic [P_W-1:0]       w_in,
    input  logic [ACC_W-1:0]     threshold_in,

    input  logic                 acc_we,
    input  logic                 acc_sel,
    input  logic                 mode_output_layer_sel,
    input  logic                 activation_r_we,
    input  logic                 out_score_r_we,
    input  logic                 valid_out_we,

    output logic [ACC_W-1:0]     acc_score_out,
    output logic                 activation_out,
    output logic                 valid_out,

    //DEBUG SIGNALS ---delete once verified correct---
    //TODO: comment out the debug signals once verified correct to save on routing congestion and potential timing issues
    output logic [P_W-1:0]       dbg_xnor_bits,
    output logic [$clog2(P_W + 1)-1:0] dbg_beat_popcount,
    output logic [ACC_W-1:0]     dbg_acc,
    output logic                 dbg_threshold_pass
);

    //TODO: potentially add clr signal to asynchronously clear the accumulator without resetting the entire module

    localparam int BEAT_PC_W = $clog2(P_W + 1);

    logic [P_W-1:0]       xnor_bits;
    logic [BEAT_PC_W-1:0] beat_popcount;
    logic [ACC_W-1:0]     beat_popcount_ext;
    logic [ACC_W-1:0]     acc_r_q;
    logic [ACC_W-1:0]     acc_next;
    logic [ACC_W-1:0]     acc_mux_o;
    logic                 threshold_pass_o;
    logic                 activation_r_q;
    logic [ACC_W-1:0]     out_score_r; // rename for acc_r clarity
    logic                 valid_out_r_q;
    logic [ACC_W-1:0]     final_score_r_q;
    logic [ACC_W-1:0]     final_threshold_r_q;
    logic                 final_output_mode_r_q;
    logic                 final_result_valid_r_q;
    logic                 final_threshold_pass_w;


    // Compute XNOR and popcount
    assign xnor_bits = ~(x_in ^ w_in);
    assign beat_popcount = $countones(xnor_bits);
    // Extend popcount to match accumulator width and compute final sum
    assign beat_popcount_ext = ACC_W'(beat_popcount);


    //Accumulator aggregatation
    assign acc_next = acc_r_q + beat_popcount_ext;
    //Choosing accumulator next value
    assign acc_mux_o = acc_sel ? '0 : acc_next; // Clear accumulator if acc_sel is high, otherwise keep accumulating


    always_ff @(posedge clk) begin
        if (acc_we) begin
            acc_r_q <= acc_mux_o;
        end

        // Final-beat score/threshold capture. The old implementation compared
        // acc_next against threshold_in and wrote activation_r_q in the same
        // cycle, putting XNOR/popcount/add/compare on one 1 ns path. This
        // stage keeps the final score exact while moving the threshold compare
        // to the following cycle from local registers.
        if (valid_out_we) begin
            final_score_r_q        <= acc_next;
            final_threshold_r_q    <= threshold_in;
            final_output_mode_r_q  <= mode_output_layer_sel;
            final_result_valid_r_q <= 1'b1;
        end else begin
            final_result_valid_r_q <= 1'b0;
        end

        if (final_result_valid_r_q) begin
            activation_r_q <= final_output_mode_r_q ? 1'b0 : final_threshold_pass_w;
            out_score_r    <= final_score_r_q;
        end
        valid_out_r_q <= final_result_valid_r_q;

        if (rst) begin
            // Minimal reset: reset the valid signal and the accumulator only.
            // - valid_out_r_q gates data validity (must be 0 after reset)
            // - acc_r_q must be 0 for first beat computation to work
            // - activation_r_q and out_score_r are don't-cares when valid=0
            acc_r_q <= '0;
            valid_out_r_q <= '0;
            final_result_valid_r_q <= 1'b0;
        end
    end

    //threshold comparison and output logic
    assign threshold_pass_o = (acc_next >= threshold_in);
    assign final_threshold_pass_w = (final_score_r_q >= final_threshold_r_q);
    //Assign outputs
    assign activation_out = activation_r_q;
    assign valid_out = valid_out_r_q;
    assign acc_score_out = out_score_r;
    //DEBUG SIGNALS
    assign dbg_xnor_bits     = xnor_bits;
    assign dbg_beat_popcount = beat_popcount;
    assign dbg_acc           = acc_r_q;
    assign dbg_threshold_pass = threshold_pass_o;

endmodule
