`timescale 1ns/10ps

package bnn_cfg_mgr_pkg;

    typedef enum logic [2:0] {
        CFG_ERR_NONE          = 3'd0,
        CFG_ERR_BAD_MSGTYPE   = 3'd1,
        CFG_ERR_BAD_LAYERID   = 3'd2,
        CFG_ERR_BAD_BPN0      = 3'd3,
        CFG_ERR_BAD_NNEUR0    = 3'd4,
        CFG_ERR_BAD_TOTALBYTES= 3'd5,
        CFG_ERR_EXTRA_T2      = 3'd6
    } dbg_error_class_t;

    typedef enum logic [1:0] {
        ROUTE_IDLE    = 2'd0,
        ROUTE_W       = 2'd1,
        ROUTE_T       = 2'd2,
        ROUTE_DISCARD = 2'd3
    } dbg_routing_state_t;

    typedef enum logic {
        EOS_LAST_BEAT    = 1'b0,
        EOS_AFTER_TRAILER= 1'b1
    } dbg_eos_strategy_t;

    function automatic int layer_pw_fn(
        input int p_in,
        input int p_n_arr[],
        input int idx
    );
        if (idx == 0)
            return p_in;
        if ((idx > 0) && (idx <= p_n_arr.size() - 1))
            return p_n_arr[idx - 1];
        return 1;
    endfunction

    function automatic int layer_pn_fn(
        input int p_n_arr[],
        input int idx
    );
        if ((idx >= 0) && (idx < p_n_arr.size()))
            return p_n_arr[idx];
        return 1;
    endfunction

    function automatic int max_pw_fn(
        input int p_in,
        input int p_n_arr[]
    );
        int m;
        m = p_in;
        foreach (p_n_arr[i]) begin
            if (i < (p_n_arr.size() - 1)) begin
                if (p_n_arr[i] > m)
                    m = p_n_arr[i];
            end
        end
        return m;
    endfunction

    function automatic logic [15:0] sat_inc16(input logic [15:0] val);
        if (val == 16'hFFFF)
            return val;
        return val + 16'd1;
    endfunction

endpackage
