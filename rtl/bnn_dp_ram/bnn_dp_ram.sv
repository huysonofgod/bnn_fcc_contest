`timescale 1ns / 100ps

module bnn_dp_ram #(
    parameter int  WIDTH      = 8,
    parameter int  DEPTH      = 256,
    parameter int  OUTPUT_REG = 0,           // 0 = 1-cycle, 1 = 2-cycle read
    parameter      MEM_STYLE  = "block",     // "block" | "distributed" | "ultra"
    // Derived — do not override
    localparam int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                              clk,
    input  logic                              rst,

    // ---- Write Port (Port A) ----
    input  logic                              wr_en,
    input  logic [ADDR_W-1:0]                 wr_addr,
    input  logic [WIDTH-1:0]                  wr_data,

    // ---- Read Port (Port B) ----
    input  logic                              rd_en,
    input  logic [ADDR_W-1:0]                 rd_addr,
    output logic [WIDTH-1:0]                  rd_data
);

    // -------------------------------------------------------------------------
    // Memory array
    // -------------------------------------------------------------------------
    (* ram_style = MEM_STYLE *)
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // -------------------------------------------------------------------------
    // Write port (Port A) — synchronous, 1-cycle
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // Read port (Port B) — stage 1: BRAM internal read register
    // -------------------------------------------------------------------------
    logic [WIDTH-1:0] rd_data_stage1_r_q;

    always_ff @(posedge clk) begin
        if (rst)         rd_data_stage1_r_q <= '0;
        else if (rd_en)  rd_data_stage1_r_q <= mem[rd_addr];
    end

    // -------------------------------------------------------------------------
    // Read port — stage 2: optional output pipeline register
    // -------------------------------------------------------------------------
    generate
        if (OUTPUT_REG == 1) begin : g_output_reg
            logic [WIDTH-1:0] rd_data_stage2_r_q;

            always_ff @(posedge clk) begin
                if (rst)  rd_data_stage2_r_q <= '0;
                else      rd_data_stage2_r_q <= rd_data_stage1_r_q;
            end

            assign rd_data = rd_data_stage2_r_q;
        end else begin : g_no_output_reg
            assign rd_data = rd_data_stage1_r_q;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Assertions (disabled during reset per project style)
    // -------------------------------------------------------------------------

    // A1. Write address must be in range
    property p_wr_addr_in_range;
        @(posedge clk) disable iff (rst)
            wr_en |-> (wr_addr < DEPTH);
    endproperty
    a_wr_addr_in_range: assert property (p_wr_addr_in_range)
        else $error("bnn_dp_ram: wr_addr=%0d >= DEPTH=%0d", wr_addr, DEPTH);

    // A2. Read address must be in range
    property p_rd_addr_in_range;
        @(posedge clk) disable iff (rst)
            rd_en |-> (rd_addr < DEPTH);
    endproperty
    a_rd_addr_in_range: assert property (p_rd_addr_in_range)
        else $error("bnn_dp_ram: rd_addr=%0d >= DEPTH=%0d", rd_addr, DEPTH);

    // A3. No X/Z on write data when write is enabled
    property p_no_x_on_wr;
        @(posedge clk) disable iff (rst)
            wr_en |-> !$isunknown(wr_data);
    endproperty
    a_no_x_on_wr: assert property (p_no_x_on_wr)
        else $error("bnn_dp_ram: X/Z on wr_data while wr_en asserted");

endmodule
