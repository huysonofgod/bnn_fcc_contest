module NP_fsm(
    input  logic clk,
    input  logic rst,
    input  logic valid_in,
    input  logic last_beat_in,

    output logic acc_we,
    output logic acc_sel,
    output logic activation_r_we,
    output logic out_score_r_we,
    output logic valid_out_we,
    // Debug signals for bring-up; remove after verification
    //TODO: comment out the debug signals once verified correct to save on routing congestion and potential timing issues
    output logic dbg_accept_beat,
    output logic dbg_neuron_done
);

typedef enum logic [1:0] {
    IDLE,
    COMPUTE,
    RESET
} state_t;

state_t state_r, state_next;

always_ff @(posedge clk) begin
    if (rst) begin
        state_r <= IDLE;
    end else begin
        state_r <= state_next;
    end
end

always_comb begin
    // Safe defaults: no register write pulses unless explicitly enabled by state/input.
    state_next       = state_r;
    acc_we           = 1'b0;
    acc_sel          = 1'b0;
    activation_r_we  = 1'b0;
    out_score_r_we   = 1'b0;
    valid_out_we     = 1'b0;

    //TODO: Remove debug signals for final version
    dbg_neuron_done  = 1'b0;
    dbg_accept_beat  = 1'b0;

    case (state_r)
        IDLE: begin
            if (valid_in) begin
                // First accepted beat of a neuron.
                acc_we = 1'b1;
                //TODO: remove dbg_accept_beat once verified correct
                dbg_accept_beat = 1'b1;

                if (last_beat_in) begin
                    //TODO: remove dbg_neuron_done once verified correct
                    dbg_neuron_done = 1'b1;

                    // Single-beat neuron: capture outputs immediately, clear next cycle.
                    activation_r_we = 1'b1;
                    out_score_r_we  = 1'b1;
                    valid_out_we    = 1'b1;
                    state_next      = RESET;
                end else begin
                    state_next = COMPUTE;
                end
            end
        end

        COMPUTE: begin
            // Hold in COMPUTE on valid gaps until another beat arrives.
            if (valid_in) begin
                acc_we = 1'b1;
                //TODO: remove dbg_accept_beat once verified correct
                dbg_accept_beat = 1'b1;

                if (last_beat_in) begin
                    //TODO: remove dbg_neuron_done once verified correct
                    dbg_neuron_done = 1'b1;

                    // accept final beat of this neuron
                    activation_r_we = 1'b1;
                    out_score_r_we  = 1'b1;
                    valid_out_we    = 1'b1;
                    state_next      = RESET;
                end
            end
        end

        RESET: begin
            // One-cycle clear between neurons.
            acc_we     = 1'b1;
            acc_sel    = 1'b1;
            // Commenting out the following line to fix the bug where activation_r_we is incorrectly asserted during RESET
            // activation_r_we = 1'b1;
            state_next = IDLE;
        end

        default: begin
            state_next = IDLE;
        end
    endcase
end

endmodule
