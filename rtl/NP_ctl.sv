module NP_ctl(
    input  logic valid_in,
    input  logic last_in,

    output logic accept,
    output logic final_beat,
    output logic acc_we,
    output logic acc_clr,
    output logic out_we
);

    always_comb begin
        accept     = valid_in;
        final_beat = valid_in && last_in;

        acc_we     = accept;
        acc_clr    = final_beat;
        out_we     = final_beat;
    end

endmodule
