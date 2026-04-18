#!/usr/bin/env bash
# run_bnn_fcc_shipped_sfc.sh — Shipped bnn_fcc_tb in SFC/MNIST mode
#
# Uses the provided verification/ and python/ folders. This is the Phase 5B/5C
# correctness gate path; adjust NUM_TEST_IMAGES and probabilities through env.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TARGET="bnn_fcc_shipped_sfc"
MODULE_DIR="$ROOT_DIR/rtl"
LOG_DIR="$ROOT_DIR/logs/$TARGET"

# shellcheck source=/dev/null
source /apps/reconfig/enable_pro

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$LOG_DIR/run_$STAMP"
mkdir -p "$RUN_DIR"

FILELIST="$RUN_DIR/filelist.f"
COMPILE_LOG="$RUN_DIR/compile.log"
SIM_LOG="$RUN_DIR/sim.log"
SUMMARY_LOG="$RUN_DIR/summary.log"
DO_FILE="$RUN_DIR/run.do"
UCDB_FILE="$RUN_DIR/coverage.ucdb"
COV_REPORT="$RUN_DIR/coverage.txt"
WORK_LIB="$RUN_DIR/work"

{
  echo "$ROOT_DIR/verification/axi4_stream_if.sv"
  echo "$ROOT_DIR/verification/bnn_fcc_tb_pkg.sv"
  find "$MODULE_DIR" -type f -name '*.sv' | sort
  if [[ -f "$MODULE_DIR/deps.f" ]]; then
    while IFS= read -r DEP_LINE || [[ -n "$DEP_LINE" ]]; do
      [[ -z "${DEP_LINE// }" || "${DEP_LINE#\#}" != "$DEP_LINE" ]] && continue
      [[ "$DEP_LINE" = /* ]] && echo "$DEP_LINE" || echo "$ROOT_DIR/$DEP_LINE"
    done < "$MODULE_DIR/deps.f"
  fi
  echo "$ROOT_DIR/verification/bnn_fcc_tb.sv"
} > "$FILELIST"

cat > "$DO_FILE" <<EOF
onerror {quit -code 1}
coverage save -onexit "$UCDB_FILE"
run -all
quit -code 0
EOF

echo "[INFO] target=$TARGET" | tee "$SUMMARY_LOG"
echo "[INFO] run_dir=$RUN_DIR" | tee -a "$SUMMARY_LOG"

rm -rf "$WORK_LIB"
vlib "$WORK_LIB" >/dev/null
vmap work "$WORK_LIB" >/dev/null

set +e
vlog -sv +cover=bcesft -work work -f "$FILELIST" 2>&1 | tee "$COMPILE_LOG"
VLOG_RC=${PIPESTATUS[0]}
set -e
if [[ $VLOG_RC -ne 0 ]]; then
  echo "[FAIL] Compilation failed" | tee -a "$SUMMARY_LOG"
  exit "$VLOG_RC"
fi

set +e
vsim -c -coverage -voptargs="+acc -O5" work.bnn_fcc_tb \
  -GUSE_CUSTOM_TOPOLOGY=0 \
  -GBASE_DIR="${BASE_DIR:-python}" \
  -GNUM_TEST_IMAGES="${NUM_TEST_IMAGES:-5}" \
  -GTOGGLE_DATA_OUT_READY="${TOGGLE_DATA_OUT_READY:-1}" \
  -GCONFIG_VALID_PROBABILITY="${CONFIG_VALID_PROBABILITY:-0.8}" \
  -GDATA_IN_VALID_PROBABILITY="${DATA_IN_VALID_PROBABILITY:-0.8}" \
  -do "$DO_FILE" 2>&1 | tee "$SIM_LOG"
VSIM_RC=${PIPESTATUS[0]}
set -e

SIM_ERR_COUNT="$(grep -cE '^# \*\* (Error|Fatal):|^\*\* (Error|Fatal):' "$SIM_LOG" || true)"
if [[ $VSIM_RC -ne 0 || "${SIM_ERR_COUNT:-0}" -ne 0 ]]; then
  echo "[FAIL] Simulation failed" | tee -a "$SUMMARY_LOG"
  exit "${VSIM_RC:-1}"
fi

vcover report -summary "$UCDB_FILE" | tee "$COV_REPORT" >/dev/null
echo "[PASS] Compile + shipped SFC simulation passed" | tee -a "$SUMMARY_LOG"
