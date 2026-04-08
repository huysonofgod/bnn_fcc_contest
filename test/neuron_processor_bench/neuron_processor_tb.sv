`timescale 1ns / 10ps
module neuron_processor_tb;

    logic done_pw1;
    logic done_pw2;
    logic done_pw4;
    logic done_pw8;
    logic done_pw16;

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi++) begin : GEN_PW_SWEEP
            if (gi == 0) begin : DUT_PW_1
                neuron_processor_tb_worker #(.P_W(1)) u_tb_pw1 (.done(done_pw1));
            end
            if (gi == 1) begin : DUT_PW_2
                neuron_processor_tb_worker #(.P_W(2)) u_tb_pw2 (.done(done_pw2));
            end
            if (gi == 2) begin : DUT_PW_4
                neuron_processor_tb_worker #(.P_W(4)) u_tb_pw4 (.done(done_pw4));
            end
            if (gi == 3) begin : DUT_PW_8
                neuron_processor_tb_worker #(.P_W(8)) u_tb_pw8 (.done(done_pw8));
            end
            if (gi == 4) begin : DUT_PW_16
                neuron_processor_tb_worker #(.P_W(16)) u_tb_pw16 (.done(done_pw16));
            end
        end
    endgenerate

    initial begin
        fork
            begin wait (done_pw1);  $display("[TOP] DUT_PW_1 complete");  end
            begin wait (done_pw2);  $display("[TOP] DUT_PW_2 complete");  end
            begin wait (done_pw4);  $display("[TOP] DUT_PW_4 complete");  end
            begin wait (done_pw8);  $display("[TOP] DUT_PW_8 complete");  end
            begin wait (done_pw16); $display("[TOP] DUT_PW_16 complete"); end
        join

        $display("[TOP] All concurrent P_W workers completed");
        $finish;
    end

endmodule
