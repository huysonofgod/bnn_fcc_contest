`timescale 1ns/10ps

module bnn_image_replay_buffer #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 98
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             image_start,
    input  logic             replay_restart,

    input  logic             in_valid,
    output logic             in_ready,
    input  logic [WIDTH-1:0] in_data,
    input  logic             in_last,

    output logic             out_valid,
    input  logic             out_ready,
    output logic [WIDTH-1:0] out_data,
    output logic             out_last
);

    localparam int ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    logic [WIDTH:0] mem [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr_r_q;
    logic [ADDR_W-1:0] rd_ptr_r_q;
    logic              image_captured_r_q;
    logic              replay_active_r_q;

    logic              capture_hs;
    logic              replay_hs;
    logic [WIDTH:0]    replay_word;

    assign replay_word = mem[rd_ptr_r_q];

    always_comb begin
        if (!image_captured_r_q) begin
            in_ready  = out_ready;
            out_valid = in_valid;
            out_data  = in_data;
            out_last  = in_last;
        end else begin
            in_ready  = 1'b0;
            out_valid = replay_active_r_q;
            out_data  = replay_word[WIDTH-1:0];
            out_last  = replay_word[WIDTH];
        end
    end

    assign capture_hs = !image_captured_r_q && in_valid && out_ready;
    assign replay_hs  = image_captured_r_q && replay_active_r_q && out_ready;

    always_ff @(posedge clk) begin
        if (rst || image_start) begin
            wr_ptr_r_q         <= '0;
            rd_ptr_r_q         <= '0;
            image_captured_r_q <= 1'b0;
            replay_active_r_q  <= 1'b0;
        end else begin
            if (!image_captured_r_q && capture_hs) begin
                mem[wr_ptr_r_q] <= {in_last, in_data};

                if (wr_ptr_r_q != ADDR_W'(DEPTH - 1))
                    wr_ptr_r_q <= wr_ptr_r_q + ADDR_W'(1);

                if (in_last || (wr_ptr_r_q == ADDR_W'(DEPTH - 1)))
                    image_captured_r_q <= 1'b1;
            end

            if (replay_restart && image_captured_r_q) begin
                rd_ptr_r_q        <= '0;
                replay_active_r_q <= 1'b1;
            end else if (replay_hs) begin
                if (out_last || (rd_ptr_r_q == ADDR_W'(DEPTH - 1))) begin
                    rd_ptr_r_q        <= '0;
                    replay_active_r_q <= 1'b0;
                end else begin
                    rd_ptr_r_q <= rd_ptr_r_q + ADDR_W'(1);
                end
            end
        end
    end

    initial begin
        assert (DEPTH >= 1)
            else $fatal(1, "bnn_image_replay_buffer: DEPTH must be >= 1");
        assert (WIDTH >= 1)
            else $fatal(1, "bnn_image_replay_buffer: WIDTH must be >= 1");
    end

endmodule
