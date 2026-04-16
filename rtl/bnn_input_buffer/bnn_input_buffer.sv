`timescale 1ns/1ps

module bnn_input_buffer #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 4
)(
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        s_valid,
    input  logic [WIDTH-1:0]            s_data,
    input  logic                        s_last,
    output logic                        s_ready,
    output logic                        m_valid,
    output logic [WIDTH-1:0]            m_data,
    output logic                        m_last,
    input  logic                        m_ready,
    output logic [$clog2(DEPTH+1)-1:0]  count
);

    localparam int PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam int CNT_W = $clog2(DEPTH + 1);

    logic [WIDTH:0] mem [0:DEPTH-1];

    logic [PTR_W-1:0] wr_ptr_r_q;
    logic [PTR_W-1:0] rd_ptr_r_q;
    logic [CNT_W-1:0] fill_r_q;
    logic             s_ready_r_q;
    logic             m_valid_r_q;

    logic wr_en;
    logic rd_en;
    logic wr_wrap;
    logic rd_wrap;
    logic [PTR_W-1:0] wr_ptr_inc;
    logic [PTR_W-1:0] rd_ptr_inc;
    logic [CNT_W-1:0] fill_next;
    logic [WIDTH:0]   rd_word;

    assign wr_en = s_valid & s_ready_r_q;
    assign rd_en = m_valid_r_q & m_ready;

    assign wr_wrap   = (wr_ptr_r_q == PTR_W'(DEPTH - 1));
    assign rd_wrap   = (rd_ptr_r_q == PTR_W'(DEPTH - 1));
    assign wr_ptr_inc = wr_wrap ? '0 : (wr_ptr_r_q + PTR_W'(1));
    assign rd_ptr_inc = rd_wrap ? '0 : (rd_ptr_r_q + PTR_W'(1));

    always_comb begin
        unique case ({wr_en, rd_en})
            2'b10:   fill_next = fill_r_q + CNT_W'(1);
            2'b01:   fill_next = fill_r_q - CNT_W'(1);
            default: fill_next = fill_r_q;
        endcase
    end

    assign rd_word = mem[rd_ptr_r_q];
    assign {m_last, m_data} = rd_word;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr_r_q  <= '0;
            rd_ptr_r_q  <= '0;
            fill_r_q    <= '0;
            s_ready_r_q <= 1'b0;
            m_valid_r_q <= 1'b0;
        end else begin
            if (wr_en)
                mem[wr_ptr_r_q] <= {s_last, s_data};

            if (wr_en)
                wr_ptr_r_q <= wr_ptr_inc;
            if (rd_en)
                rd_ptr_r_q <= rd_ptr_inc;

            fill_r_q <= fill_next;

            s_ready_r_q <= (fill_next < CNT_W'(DEPTH));
            m_valid_r_q <= (fill_next > CNT_W'(0));
        end
    end

    assign s_ready = s_ready_r_q;
    assign m_valid = m_valid_r_q;
    assign count   = fill_r_q;

    initial begin
        if (DEPTH < 2)
            $error("bnn_input_buffer: DEPTH must be >= 2. Got %0d", DEPTH);
    end

    property p_no_write_when_full;
        @(posedge clk) disable iff (rst)
            (fill_r_q == CNT_W'(DEPTH)) |-> !wr_en;
    endproperty
    a_no_write_when_full: assert property (p_no_write_when_full);

    property p_no_read_when_empty;
        @(posedge clk) disable iff (rst)
            (fill_r_q == '0) |-> !rd_en;
    endproperty
    a_no_read_when_empty: assert property (p_no_read_when_empty);

    property p_count_in_range;
        @(posedge clk) disable iff (rst)
            fill_r_q <= CNT_W'(DEPTH);
    endproperty
    a_count_in_range: assert property (p_count_in_range);

endmodule
