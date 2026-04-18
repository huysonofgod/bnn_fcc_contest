#!/usr/bin/env bash
# run_bnn_fcc_post_synth_sim.sh — Phase 5E post-synthesis simulation
#
# Procedure (per SYSTEM_SPEC §9.11.2):
#   1. Synthesize a functional SFC top, not the OpenFlex OOC timing wrapper,
#      and emit a functional post-synthesis Verilog netlist.
#   2. Compile Vivado simulation libraries (unisims_ver / xpm / secureip) for
#      Questa if not already compiled.
#   3. Run the shipped `verification/bnn_fcc_tb.sv` against the netlist with
#      the same parameters as the pre-synth SFC run, plus glbl.v for primitive
#      initialization.
#   4. Expect: "SUCCESS: all N tests completed successfully."
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TARGET="bnn_fcc_post_synth_sim"
LOG_DIR="$ROOT_DIR/logs/$TARGET"
SIMLIB_DIR="$ROOT_DIR/.work/vivado_simlib"

NUM_TEST_IMAGES="${NUM_TEST_IMAGES:-5}"

# shellcheck source=/dev/null
source /apps/reconfig/enable_pro

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$LOG_DIR/run_$STAMP"
mkdir -p "$RUN_DIR"

SFC_TOP_SV="$RUN_DIR/bnn_fcc_sfc_top.sv"
RTL_FILELIST="$RUN_DIR/rtl_filelist.f"
NETLIST_V="$RUN_DIR/bnn_fcc_sfc_postsynth.v"
SYNTH_TCL="$RUN_DIR/synth_bnn_fcc_sfc.tcl"
VIVADO_LOG="$RUN_DIR/vivado_synth_func_top.log"
COMPILE_LOG="$RUN_DIR/compile.log"
SIM_LOG="$RUN_DIR/sim.log"
SUMMARY_LOG="$RUN_DIR/summary.log"
DO_FILE="$RUN_DIR/run.do"
WORK_LIB="$RUN_DIR/work"

echo "[INFO] target=$TARGET"                  | tee "$SUMMARY_LOG"
echo "[INFO] top=bnn_fcc_sfc_top"             | tee -a "$SUMMARY_LOG"
echo "[INFO] run_dir=$RUN_DIR"                | tee -a "$SUMMARY_LOG"

# ── Step 1: synthesize functional SFC top and write post-synth netlist ─────
cat > "$SFC_TOP_SV" <<'EOF'
module bnn_fcc_sfc_top (
    input  logic        clk,
    input  logic        rst,

    input  logic        config_valid,
    output logic        config_ready,
    input  logic [63:0] config_data,
    input  logic [7:0]  config_keep,
    input  logic        config_last,

    input  logic        data_in_valid,
    output logic        data_in_ready,
    input  logic [63:0] data_in_data,
    input  logic [7:0]  data_in_keep,
    input  logic        data_in_last,

    output logic        data_out_valid,
    input  logic        data_out_ready,
    output logic [7:0]  data_out_data,
    output logic [0:0]  data_out_keep,
    output logic        data_out_last
);
    bnn_fcc #(
        .INPUT_DATA_WIDTH (8),
        .INPUT_BUS_WIDTH  (64),
        .CONFIG_BUS_WIDTH (64),
        .OUTPUT_DATA_WIDTH(4),
        .OUTPUT_BUS_WIDTH (8),
        .TOTAL_LAYERS     (4),
        .TOPOLOGY         ('{784, 256, 256, 10}),
        .PARALLEL_INPUTS  (8),
        .PARALLEL_NEURONS ('{8, 8, 10}),
        .FANOUT_STAGES    (1)
    ) DUT (
        .clk(clk),
        .rst(rst),
        .config_valid(config_valid),
        .config_ready(config_ready),
        .config_data(config_data),
        .config_keep(config_keep),
        .config_last(config_last),
        .data_in_valid(data_in_valid),
        .data_in_ready(data_in_ready),
        .data_in_data(data_in_data),
        .data_in_keep(data_in_keep),
        .data_in_last(data_in_last),
        .data_out_valid(data_out_valid),
        .data_out_ready(data_out_ready),
        .data_out_data(data_out_data),
        .data_out_keep(data_out_keep),
        .data_out_last(data_out_last)
    );
endmodule
EOF

if [[ -f "$ROOT_DIR/openflex/build_vivado/filelist.txt" ]]; then
  grep -v '/openflex/rtl/bnn_fcc_timing.sv$' "$ROOT_DIR/openflex/build_vivado/filelist.txt" > "$RTL_FILELIST"
else
  find "$ROOT_DIR/rtl" -type f -name '*.sv' | sort > "$RTL_FILELIST"
fi
echo "$SFC_TOP_SV" >> "$RTL_FILELIST"

cat > "$SYNTH_TCL" <<EOF
set filelist_path "$RTL_FILELIST"
set fileID [open \$filelist_path r]
set file_names [split [read \$fileID] "\\n"]
close \$fileID
foreach file \$file_names {
    if {![string is space \$file]} {
        read_verilog -sv \$file
    }
}
synth_design -top bnn_fcc_sfc_top -part XCU250-FIGD2104-2L-E -mode out_of_context
write_verilog -mode funcsim -force "$NETLIST_V"
close_project
exit
EOF

echo "[INFO] synthesizing functional post-synth netlist" | tee -a "$SUMMARY_LOG"
set +e
vivado -mode batch -source "$SYNTH_TCL" -log "$VIVADO_LOG" -journal "$RUN_DIR/vivado.jou" 2>&1 | tee -a "$SUMMARY_LOG"
VIVADO_RC=${PIPESTATUS[0]}
set -e
if [[ $VIVADO_RC -ne 0 || ! -f "$NETLIST_V" ]]; then
  echo "[FAIL] functional netlist synthesis failed (rc=$VIVADO_RC)" | tee -a "$SUMMARY_LOG"
  exit "$VIVADO_RC"
fi

# ── Step 2: compile Vivado simulation libraries if needed ──────────────────
if [[ ! -f "$SIMLIB_DIR/modelsim.ini" ]]; then
  echo "[INFO] compiling Vivado base simlib for Questa (one-time)" | tee -a "$SUMMARY_LOG"
  mkdir -p "$SIMLIB_DIR"
  COMPILE_SIMLIB_TCL="$RUN_DIR/compile_simlib.tcl"
  cat > "$COMPILE_SIMLIB_TCL" <<EOF
compile_simlib -simulator questa -simulator_exec_path "$(dirname "$(command -v vsim)")" -family virtexuplus -library unisim -library simprim -language verilog -no_ip_compile -dir "$SIMLIB_DIR" -force
exit
EOF
  vivado -mode batch -source "$COMPILE_SIMLIB_TCL" -log "$RUN_DIR/compile_simlib.log" -journal "$RUN_DIR/compile_simlib.jou" 2>&1 | tail -20 | tee -a "$SUMMARY_LOG"
fi

# ── Step 3: compile TB + netlist in Questa ─────────────────────────────────
FILELIST="$RUN_DIR/filelist.f"
{
  echo "$ROOT_DIR/verification/axi4_stream_if.sv"
  echo "$ROOT_DIR/verification/bnn_fcc_tb_pkg.sv"
  echo "$NETLIST_V"
  echo "$ROOT_DIR/test/bnn_fcc_post_synth_tb.sv"
} > "$FILELIST"

rm -rf "$WORK_LIB"
vlib "$WORK_LIB" >/dev/null

# Map simlib from Vivado-generated modelsim.ini before mapping `work`.
# Otherwise vmap can update the repo-root modelsim.ini while vlog/vsim later
# use the Vivado simlib modelsim.ini, making the compiled TB invisible.
if [[ -f "$SIMLIB_DIR/modelsim.ini" ]]; then
  export MODELSIM="$SIMLIB_DIR/modelsim.ini"
fi
vmap work "$WORK_LIB" >/dev/null

echo "[INFO] vlog starting"                    | tee -a "$SUMMARY_LOG"
set +e
vlog -sv -work work -f "$FILELIST" 2>&1 | tee "$COMPILE_LOG"
VLOG_RC=${PIPESTATUS[0]}
set -e
if [[ $VLOG_RC -ne 0 ]]; then
  echo "[FAIL] Compilation failed"             | tee -a "$SUMMARY_LOG"
  exit "$VLOG_RC"
fi

# ── Step 4: simulate functional post-synth netlist ─────────────────────────
cat > "$DO_FILE" <<EOF
onerror {quit -code 1}
run -all
quit -code 0
EOF

echo "[INFO] vsim starting"                    | tee -a "$SUMMARY_LOG"
SIM_LIBS="-L unisims_ver -L simprims_ver"
set +e
vsim -c -voptargs="+acc -O5" $SIM_LIBS work.bnn_fcc_post_synth_tb work.glbl \
  -GNUM_TEST_IMAGES="$NUM_TEST_IMAGES" \
  -GBASE_DIR=python \
  -GTOGGLE_DATA_OUT_READY=0 \
  -GCONFIG_VALID_PROBABILITY=1.0 \
  -GDATA_IN_VALID_PROBABILITY=1.0 \
  -do "$DO_FILE" 2>&1 | tee "$SIM_LOG"
VSIM_RC=${PIPESTATUS[0]}
set -e

SIM_ERR_COUNT="$(grep -cE '^# \*\* (Error|Fatal):|^\*\* (Error|Fatal):' "$SIM_LOG" || true)"
SUCCESS_HIT="$(grep -c 'SUCCESS: all' "$SIM_LOG" || true)"

if [[ $VSIM_RC -ne 0 || "${SIM_ERR_COUNT:-0}" -ne 0 || "${SUCCESS_HIT:-0}" -eq 0 ]]; then
  echo "[FAIL] post-synth sim failed (rc=$VSIM_RC err=$SIM_ERR_COUNT success=$SUCCESS_HIT)" | tee -a "$SUMMARY_LOG"
  exit "${VSIM_RC:-1}"
fi

echo "[PASS] post-synth simulation SUCCESS"    | tee -a "$SUMMARY_LOG"
