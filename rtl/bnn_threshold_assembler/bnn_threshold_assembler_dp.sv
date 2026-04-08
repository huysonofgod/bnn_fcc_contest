module bnn_threshold_assembler_dp (
    input  logic       clk,
    input  logic       rst,
    // Byte input
    input  logic       byte_valid,
    output logic       byte_ready,
    input  logic [7:0] byte_data,
    // Threshold output
    output logic       thresh_valid,
    input  logic       thresh_ready,
    output logic [31:0] thresh_data
);

    //  Registers 
    logic [31:0] shift_reg_r_q;
    logic [1:0]  byte_cnt_r_q;
    logic [31:0] thresh_data_r_q;
    logic        thresh_vld_r_q;

    //  Combinational datapath 
    logic [31:0] shift_next;
    logic        is_last_byte;
    logic        shift_we;        // byte_valid & byte_ready
    logic        assembly_done;
    logic [1:0]  byte_cnt_next;
    logic        thresh_valid_next;

    // Right-shift: new byte at MSB, old MSB shifts toward LSB
    assign shift_next  = {byte_data, shift_reg_r_q[31:8]};

    // Byte counter terminal: 4th byte (index 3) triggers output
    assign is_last_byte = (byte_cnt_r_q == 2'd3);

    // Accept condition: not stalled by unacknowledged output
    assign byte_ready = ~thresh_vld_r_q | thresh_ready;
    assign shift_we   = byte_valid & byte_ready;

    // Assembly complete when last byte is accepted
    assign assembly_done = is_last_byte & shift_we;

    // Byte counter next: wrap to 0 on last byte, else increment
    assign byte_cnt_next = (is_last_byte & shift_we) ? 2'd0 : byte_cnt_r_q + 2'd1;

    // Thresh valid next-state
    always_comb begin
        if (assembly_done)
            thresh_valid_next = 1'b1;
        else if (thresh_ready)
            thresh_valid_next = 1'b0;
        else
            thresh_valid_next = thresh_vld_r_q;  // hold
    end

    // shift register 
    always_ff @(posedge clk) begin
        if (shift_we)
            shift_reg_r_q <= shift_next;

        // No reset needed: data masked by thresh_valid gate
        if (rst)
            shift_reg_r_q <= 32'h0;
    end

    // byte counter 
    always_ff @(posedge clk) begin
        if (shift_we)
            byte_cnt_r_q <= byte_cnt_next;

        // Reset at END — counter is a control signal
        if (rst)
            byte_cnt_r_q <= 2'd0;
    end

    // output threshold register 
    // Capture shift_next (the fully assembled value, not shift_reg_r_q)
    always_ff @(posedge clk) begin
        if (assembly_done)
            thresh_data_r_q <= shift_next;

        // No reset required: data masked by thresh_valid gate
        if (rst)
            thresh_data_r_q <= 32'h0;
    end

    //  valid register 
    always_ff @(posedge clk) begin
        thresh_vld_r_q <= thresh_valid_next;

        // Reset at END — valid is a control signal
        if (rst)
            thresh_vld_r_q <= 1'b0;
    end

    //  Output assignments 
    assign thresh_valid = thresh_vld_r_q;
    assign thresh_data  = thresh_data_r_q;

endmodule
