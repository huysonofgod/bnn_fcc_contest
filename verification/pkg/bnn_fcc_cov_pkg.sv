`timescale 1ns/10ps

package bnn_fcc_cov_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import bnn_fcc_tb_pkg::*;

    typedef bit [63:0] axi64_data_t;
    typedef bit [7:0]  axi64_keep_t;
    typedef bit [7:0]  axi8_data_t;

    // -------------------------------------------------------------------------
    // Configuration object shared by all UVM components.
    // Review note:
    //   Top-level parameters are copied into dynamic arrays because UVM objects
    //   cannot directly carry unpacked parameter arrays through the factory.
    // -------------------------------------------------------------------------
    class bnn_fcc_cov_cfg extends uvm_object;
        `uvm_object_utils(bnn_fcc_cov_cfg)

        int    use_custom_topology;
        int    num_test_images;
        int    total_layers;
        int    topology[$];
        int    parallel_inputs;
        int    parallel_neurons[$];
        real   config_valid_probability;
        real   data_in_valid_probability;
        bit    toggle_data_out_ready;
        bit    enable_l2_thr_probe;
        bit    enable_per_msg_tlast_probe;
        string base_dir;
        realtime clk_period;

        function new(string name = "bnn_fcc_cov_cfg");
            super.new(name);
            use_custom_topology = 1;
            num_test_images = 10;
            config_valid_probability = 0.8;
            data_in_valid_probability = 0.8;
            toggle_data_out_ready = 1'b1;
            enable_l2_thr_probe = 1'b0;
            enable_per_msg_tlast_probe = 1'b0;
            base_dir = "../python";
            clk_period = 10ns;
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Generic 64-bit AXI item used for config and image streams.
    // -------------------------------------------------------------------------
    class axi64_item extends uvm_sequence_item;
        `uvm_object_utils(axi64_item)
        rand axi64_data_t data;
        rand axi64_keep_t keep;
        rand bit          last;

        function new(string name = "axi64_item");
            super.new(name);
            data = '0;
            keep = '0;
            last = 1'b0;
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Output transaction observed by the output monitor.
    // -------------------------------------------------------------------------
    class out_item extends uvm_sequence_item;
        `uvm_object_utils(out_item)
        bit [7:0] data;
        bit       last;
        bit       keep0;

        function new(string name = "out_item");
            super.new(name);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Common probability helper.
    // -------------------------------------------------------------------------
    function automatic bit chance(real p);
        if (p > 1.0 || p < 0.0)
            `uvm_fatal("CHANCE", $sformatf("Invalid probability %0f", p))
        return ($urandom < (p * (2.0 ** 32)));
    endfunction

    // -------------------------------------------------------------------------
    // AXI config driver.
    // Drives on posedge with NBA and holds valid/data/keep/last until handshake.
    // -------------------------------------------------------------------------
    class cfg_axi_driver extends uvm_component;
        `uvm_component_utils(cfg_axi_driver)
        virtual axi4_stream_if #(.DATA_WIDTH(64)) vif;
        bnn_fcc_cov_cfg cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::get(this, "", "cfg_vif", vif))
                `uvm_fatal("NOVIF", "cfg_axi_driver missing cfg_vif")
            if (!uvm_config_db#(bnn_fcc_cov_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "cfg_axi_driver missing cfg object")
        endfunction

        task drive_stream(ref bit [63:0] data_stream[], ref bit [7:0] keep_stream[]);
            for (int i = 0; i < data_stream.size(); i++) begin
                while (!chance(cfg.config_valid_probability)) begin
                    vif.tvalid <= 1'b0;
                    @(posedge vif.aclk);
                end

                vif.tvalid <= 1'b1;
                vif.tdata  <= data_stream[i];
                vif.tkeep  <= keep_stream[i];
                vif.tlast  <= (i == data_stream.size() - 1);
                do @(posedge vif.aclk); while (!vif.tready);
            end

            vif.tvalid <= 1'b0;
            vif.tdata  <= '0;
            vif.tkeep  <= '0;
            vif.tlast  <= 1'b0;
        endtask
    endclass

    // -------------------------------------------------------------------------
    // AXI image driver.
    // Packs one image into 64-bit beats exactly like the shipped TB.
    // -------------------------------------------------------------------------
    class image_axi_driver extends uvm_component;
        `uvm_component_utils(image_axi_driver)
        virtual axi4_stream_if #(.DATA_WIDTH(64)) vif;
        bnn_fcc_cov_cfg cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::get(this, "", "img_vif", vif))
                `uvm_fatal("NOVIF", "image_axi_driver missing img_vif")
            if (!uvm_config_db#(bnn_fcc_cov_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "image_axi_driver missing cfg object")
        endfunction

        task drive_image(bit [7:0] img[]);
            localparam int INPUTS_PER_CYCLE = 8;
            for (int j = 0; j < img.size(); j += INPUTS_PER_CYCLE) begin
                bit [63:0] data_word;
                bit [7:0]  keep_word;
                data_word = '0;
                keep_word = '0;

                for (int k = 0; k < INPUTS_PER_CYCLE; k++) begin
                    if (j + k < img.size()) begin
                        data_word[k*8 +: 8] = img[j+k];
                        keep_word[k] = 1'b1;
                    end
                end

                while (!chance(cfg.data_in_valid_probability)) begin
                    vif.tvalid <= 1'b0;
                    @(posedge vif.aclk);
                end

                vif.tvalid <= 1'b1;
                vif.tdata  <= data_word;
                vif.tkeep  <= keep_word;
                vif.tlast  <= (j + INPUTS_PER_CYCLE >= img.size());
                do @(posedge vif.aclk); while (!vif.tready);
            end

            vif.tvalid <= 1'b0;
            vif.tdata  <= '0;
            vif.tkeep  <= '0;
            vif.tlast  <= 1'b0;
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Output ready driver.
    // Runs independently so output backpressure is present during all tests.
    // -------------------------------------------------------------------------
    class output_ready_driver extends uvm_component;
        `uvm_component_utils(output_ready_driver)
        virtual axi4_stream_if #(.DATA_WIDTH(8)) vif;
        bnn_fcc_cov_cfg cfg;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(8)))::get(this, "", "out_vif", vif))
                `uvm_fatal("NOVIF", "output_ready_driver missing out_vif")
            if (!uvm_config_db#(bnn_fcc_cov_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "output_ready_driver missing cfg object")
        endfunction

        task run_phase(uvm_phase phase);
            vif.tready <= 1'b1;
            @(posedge vif.aclk);
            forever begin
                if (cfg.toggle_data_out_ready)
                    vif.tready <= $urandom();
                else
                    vif.tready <= 1'b1;
                @(posedge vif.aclk);
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Output monitor.
    // Emits one analysis transaction per accepted classification beat.
    // -------------------------------------------------------------------------
    class output_monitor extends uvm_component;
        `uvm_component_utils(output_monitor)
        virtual axi4_stream_if #(.DATA_WIDTH(8)) vif;
        uvm_analysis_port #(out_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(8)))::get(this, "", "out_vif", vif))
                `uvm_fatal("NOVIF", "output_monitor missing out_vif")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.aclk);
                if (vif.tvalid && vif.tready) begin
                    out_item item = out_item::type_id::create("item");
                    item.data = vif.tdata;
                    item.last = vif.tlast;
                    item.keep0 = vif.tkeep[0];
                    ap.write(item);
                end
            end
        endtask
    endclass

    `uvm_analysis_imp_decl(_out)

    // -------------------------------------------------------------------------
    // Scoreboard.
    // Holds expected predictions generated from BNN_FCC_Model and compares them
    // FIFO-order against observed output beats.
    // -------------------------------------------------------------------------
    class bnn_fcc_scoreboard extends uvm_component;
        `uvm_component_utils(bnn_fcc_scoreboard)
        uvm_analysis_imp_out #(out_item, bnn_fcc_scoreboard) out_imp;
        int expected_q[$];
        int pass_count;
        int fail_count;
        uvm_event all_outputs_seen;
        int expected_total;
        int last_tie_count_at_output;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            out_imp = new("out_imp", this);
            all_outputs_seen = new("all_outputs_seen");
        endfunction

        function void push_expected(int pred, int tie_count);
            expected_q.push_back(pred);
            last_tie_count_at_output = tie_count;
            expected_total++;
        endfunction

        function void write_out(out_item item);
            int exp;
            if (expected_q.size() == 0) begin
                fail_count++;
                `uvm_error("SB", "Observed output with no expected prediction")
                return;
            end

            exp = expected_q.pop_front();
            if (item.data[3:0] === exp[3:0]) begin
                pass_count++;
            end else begin
                fail_count++;
                `uvm_error("SB", $sformatf("Output mismatch actual=%0d expected=%0d", item.data[3:0], exp))
            end

            if (!item.last)
                `uvm_error("SB", "data_out_last was not asserted on classification output")
            if (!item.keep0)
                `uvm_error("SB", "data_out_keep[0] was not asserted on classification output")

            if ((pass_count + fail_count) == expected_total)
                all_outputs_seen.trigger();
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Coverage subscriber.
    // Implements the five top-level coverage categories from the draft plan.
    // -------------------------------------------------------------------------
    class bnn_fcc_cov_subscriber extends uvm_component;
        `uvm_component_utils(bnn_fcc_cov_subscriber)

        bit cfg_valid, cfg_ready, cfg_last;
        bit img_valid, img_ready, img_last, img_partial_keep;
        bit out_valid, out_ready, out_last;
        int predicted_class;
        int tie_count;
        int config_count;
        int images_since_cfg;
        int reset_phase;

        covergroup cg_axi_protocol;
            option.per_instance = 1;
            cp_cfg_v: coverpoint cfg_valid;
            cp_cfg_r: coverpoint cfg_ready;
            cp_cfg_l: coverpoint cfg_last;
            x_cfg: cross cp_cfg_v, cp_cfg_r;
            cp_img_v: coverpoint img_valid;
            cp_img_r: coverpoint img_ready;
            cp_img_l: coverpoint img_last;
            cp_img_k: coverpoint img_partial_keep;
            x_img: cross cp_img_v, cp_img_r, cp_img_l, cp_img_k;
            cp_out_v: coverpoint out_valid;
            cp_out_r: coverpoint out_ready;
            cp_out_l: coverpoint out_last;
            x_out: cross cp_out_v, cp_out_r, cp_out_l;
        endgroup

        covergroup cg_config_diversity;
            option.per_instance = 1;
            cp_config_count: coverpoint config_count {
                bins first = {1};
                bins multi = {[2:16]};
            }
        endgroup

        covergroup cg_compute_stimulus;
            option.per_instance = 1;
            cp_predicted_class: coverpoint predicted_class {
                bins classes[] = {[0:15]};
            }
            cp_tie_count: coverpoint tie_count {
                bins no_tie = {1};
                bins tie2 = {2};
                bins many = {[3:16]};
            }
            x_class_tie: cross cp_predicted_class, cp_tie_count;
        endgroup

        covergroup cg_cfg_img_sequencing;
            option.per_instance = 1;
            cp_cfg_count: coverpoint config_count {
                bins first = {1};
                bins second = {2};
                bins multi = {[3:16]};
            }
            cp_images_since_cfg: coverpoint images_since_cfg {
                bins few = {[1:10]};
                bins many = {[11:100]};
                bins stress = {[101:1000]};
            }
            x_cfg_img: cross cp_cfg_count, cp_images_since_cfg;
        endgroup

        covergroup cg_reset_scenarios;
            option.per_instance = 1;
            cp_reset_phase: coverpoint reset_phase {
                bins pre_config = {0};
                bins post_config = {1};
                bins mid_image = {2};
                bins out_phase = {3};
            }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_axi_protocol = new();
            cg_config_diversity = new();
            cg_compute_stimulus = new();
            cg_cfg_img_sequencing = new();
            cg_reset_scenarios = new();
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Top-level UVM environment.
    // Owns model/stimulus setup and the phase-level test flow.
    // -------------------------------------------------------------------------
    class bnn_fcc_env extends uvm_env;
        `uvm_component_utils(bnn_fcc_env)

        virtual axi4_stream_if #(.DATA_WIDTH(64)) cfg_vif;
        virtual axi4_stream_if #(.DATA_WIDTH(64)) img_vif;
        virtual axi4_stream_if #(.DATA_WIDTH(8))  out_vif;
        virtual bnn_fcc_reset_if rst_vif;

        bnn_fcc_cov_cfg cfg;
        cfg_axi_driver cfg_drv;
        image_axi_driver img_drv;
        output_ready_driver ready_drv;
        output_monitor out_mon;
        bnn_fcc_scoreboard sb;
        bnn_fcc_cov_subscriber cov;
        BNN_FCC_Model #(64) model;
        BNN_FCC_Stimulus #(8) stim;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(bnn_fcc_cov_cfg)::get(this, "", "cfg", cfg))
                `uvm_fatal("NOCFG", "bnn_fcc_env missing cfg")
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::get(this, "", "cfg_vif", cfg_vif))
                `uvm_fatal("NOVIF", "bnn_fcc_env missing cfg_vif")
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::get(this, "", "img_vif", img_vif))
                `uvm_fatal("NOVIF", "bnn_fcc_env missing img_vif")
            if (!uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(8)))::get(this, "", "out_vif", out_vif))
                `uvm_fatal("NOVIF", "bnn_fcc_env missing out_vif")
            if (!uvm_config_db#(virtual bnn_fcc_reset_if)::get(this, "", "rst_vif", rst_vif))
                `uvm_fatal("NOVIF", "bnn_fcc_env missing rst_vif")

            uvm_config_db#(bnn_fcc_cov_cfg)::set(this, "*", "cfg", cfg);
            uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::set(this, "cfg_drv", "cfg_vif", cfg_vif);
            uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(64)))::set(this, "img_drv", "img_vif", img_vif);
            uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(8)))::set(this, "ready_drv", "out_vif", out_vif);
            uvm_config_db#(virtual axi4_stream_if#(.DATA_WIDTH(8)))::set(this, "out_mon", "out_vif", out_vif);

            cfg_drv = cfg_axi_driver::type_id::create("cfg_drv", this);
            img_drv = image_axi_driver::type_id::create("img_drv", this);
            ready_drv = output_ready_driver::type_id::create("ready_drv", this);
            out_mon = output_monitor::type_id::create("out_mon", this);
            sb = bnn_fcc_scoreboard::type_id::create("sb", this);
            cov = bnn_fcc_cov_subscriber::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            out_mon.ap.connect(sb.out_imp);
        endfunction

        task reset_dut();
            cfg_vif.tvalid <= 1'b0;
            cfg_vif.tdata  <= '0;
            cfg_vif.tkeep  <= '0;
            cfg_vif.tlast  <= 1'b0;
            img_vif.tvalid <= 1'b0;
            img_vif.tdata  <= '0;
            img_vif.tkeep  <= '0;
            img_vif.tlast  <= 1'b0;
            rst_vif.rst <= 1'b1;
            repeat (5) @(posedge cfg_vif.aclk);
            rst_vif.rst <= 1'b0;
            repeat (5) @(posedge cfg_vif.aclk);
        endtask

        function int tie_count_for_last_output();
            int last;
            int max_val;
            int count;
            last = model.num_layers - 1;
            max_val = -1;
            count = 0;
            for (int i = 0; i < model.layer_outputs[last].size(); i++) begin
                if (model.layer_outputs[last][i] > max_val) begin
                    max_val = model.layer_outputs[last][i];
                    count = 1;
                end else if (model.layer_outputs[last][i] == max_val) begin
                    count++;
                end
            end
            return count;
        endfunction

        task run_phase(uvm_phase phase);
            bit [63:0] cfg_data[];
            bit [7:0]  cfg_keep[];
            bit [7:0]  current_img[];
            string path;

            phase.raise_objection(this);
            reset_dut();

            model = new();
            stim = new(cfg.topology[0]);

            if (cfg.use_custom_topology) begin
                model.create_random(cfg.topology);
                stim.generate_random_vectors(cfg.num_test_images);
            end else begin
                path = $sformatf("%s/model_data", cfg.base_dir);
                model.load_from_file(path, cfg.topology);
                path = $sformatf("%s/test_vectors/inputs.hex", cfg.base_dir);
                stim.load_from_file(path, cfg.num_test_images);
            end

            model.encode_configuration(cfg_data, cfg_keep);
            cov.config_count++;
            cov.cg_config_diversity.sample();
            cfg_drv.drive_stream(cfg_data, cfg_keep);

            wait (img_vif.tready);
            repeat (5) @(posedge img_vif.aclk);

            for (int i = 0; i < cfg.num_test_images; i++) begin
                int pred;
                stim.get_vector(i, current_img);
                pred = model.compute_reference(current_img);
                sb.push_expected(pred, tie_count_for_last_output());
                cov.predicted_class = pred;
                cov.tie_count = tie_count_for_last_output();
                cov.cg_compute_stimulus.sample();
                img_drv.drive_image(current_img);
                cov.images_since_cfg = i + 1;
                cov.cg_cfg_img_sequencing.sample();
            end

            wait (sb.pass_count + sb.fail_count == cfg.num_test_images);
            repeat (5) @(posedge out_vif.aclk);

            if (sb.fail_count != 0)
                `uvm_error("SUMMARY", $sformatf("FAILED outputs: pass=%0d fail=%0d", sb.pass_count, sb.fail_count))
            else
                `uvm_info("SUMMARY", $sformatf("SUCCESS outputs: pass=%0d", sb.pass_count), UVM_LOW)

            phase.drop_objection(this);
        endtask
    endclass

    class bnn_fcc_base_test extends uvm_test;
        `uvm_component_utils(bnn_fcc_base_test)
        bnn_fcc_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = bnn_fcc_env::type_id::create("env", this);
        endfunction
    endclass

endpackage
