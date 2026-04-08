module bnn_input_binarizer_dp #(
    parameter int BUS_WIDTH = 64,
    parameter int P_W       = 8           // = BUS_WIDTH / 8 pixels per beat
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

    // Registers 
    logic [P_W-1:0] m_data_r_q;
    logic           m_last_r_q;
    logic           m_valid_r_q;

    //  Binarization 
    // For each pixel i: binary = MSB of pixel byte AND keep bit
    logic [P_W-1:0] binary_bits;
    genvar i;
    generate
        for (i = 0; i < P_W; i++) begin : gen_binarize
            assign binary_bits[i] = s_data[i*8 + 7] & s_keep[i];
        end
    endgenerate

    // Skid buffer control 
    logic slot_free;
    logic accept;
    logic m_valid_next;

    // slot_free: output slot is empty or being consumed this cycle
    assign slot_free = ~m_valid_r_q | m_ready;
    assign accept    = s_valid & slot_free;
    assign s_ready   = slot_free;  // combinational (safe: depends on registered m_valid_r_q)

    // m_valid next-state logic
    always_comb begin
        if (accept)
            m_valid_next = 1'b1;
        else if (m_ready & m_valid_r_q)
            m_valid_next = 1'b0;
        else
            m_valid_next = m_valid_r_q;  // hold
    end

    //  output registers 
    always_ff @(posedge clk) begin
        m_valid_r_q <= m_valid_next;

        if (accept) begin
            m_data_r_q <= binary_bits;
            m_last_r_q <= s_last;
        end

        // Reset at END of block — only control signals
        if (rst) begin
            m_valid_r_q <= 1'b0;
            m_last_r_q  <= 1'b0;
        end
    end

    //  Output assignments 
    assign m_valid = m_valid_r_q;
    assign m_data  = m_data_r_q;
    assign m_last  = m_last_r_q;

endmodule
