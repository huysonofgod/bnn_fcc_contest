module bnn_counter_dp #(
    parameter int WIDTH     = 8,
    parameter int RESET_VAL = 0
)(
    input  logic               clk,
    input  logic               rst,
    input  logic               en,
    input  logic               load,
    input  logic [WIDTH-1:0]   load_val,
    input  logic [WIDTH-1:0]   max_val,
    output logic [WIDTH-1:0]   count,
    output logic               tc,
    output logic               tc_pulse
);

    //  Registers 
    logic [WIDTH-1:0] count_r_q;
    logic             tc_pulse_r_q;

    //  Combinational datapath 
    logic [WIDTH-1:0] count_plus_1;
    logic             tc_comb;
    logic             tc_and_en;
    logic [WIDTH-1:0] count_next;
    logic             count_we;


    assign count_plus_1 = count_r_q + 1'b1;

    assign tc_comb   = (count_r_q == max_val);
    assign tc_and_en = tc_comb & en;

    // tc_and_en → RESET_VAL, load → load_val, default → count_plus_1
    always_comb begin
        if (load)
            count_next = load_val;
        else if (tc_and_en)
            count_next = WIDTH'(RESET_VAL);
        else
            count_next = count_plus_1;
    end

    // Write-enable gate: only update count register when meaningful
    assign count_we = en | load;

    //   COUNT register 
    always_ff @(posedge clk) begin
        if (count_we)
            count_r_q <= count_next;
        // Reset at END of always_ff block (control signals only)
        if (rst)
            count_r_q <= WIDTH'(RESET_VAL);
    end

    // TC_PULSE register 
    always_ff @(posedge clk) begin
        tc_pulse_r_q <= tc_and_en;

        // Reset at END of always_ff block
        if (rst)
            tc_pulse_r_q <= 1'b0;
    end

    //  Output assignments 
    assign count    = count_r_q;
    assign tc       = tc_comb;        // combinational (secondary)
    assign tc_pulse = tc_pulse_r_q;   // registered (primary)

endmodule
