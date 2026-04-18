#!/usr/bin/env bash
# run_bnn_fcc_coverage_final.sh — FINAL lightweight (non-UVM) bnn_fcc coverage bench
#
# Phase 5D runner per BNN_FCC_VERIFICATION_PLAN_FINAL.md.
#   - Compiles shipped verification/bnn_fcc_tb_pkg.sv + axi4_stream_if.sv
#     + bnn_fcc module tree + verification/bnn_fcc_coverage_tb.sv (core)
#     + 6 profile wrappers under verification/profiles/
#   - Runs each profile (SFC_CT, TINY_A, TINY_B, ODD, DEG1, DEG2) sequentially.
#   - Saves per-profile UCDB + sim/compile logs, merges to one UCDB, emits
#     vcover summary/details reports.
#
# Per-profile failure (compile or simulation) is logged but does not stop the
# sweep so all profiles report their status. Exit code is non-zero if any
# mandatory-minimum profile (SFC_CT, DEG2) fails.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
TARGET="bnn_fcc_coverage_final"
MODULE_DIR="$ROOT_DIR/rtl"
LOG_DIR="$ROOT_DIR/logs/$TARGET"

# shellcheck source=/dev/null
source /apps/reconfig/enable_pro

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$LOG_DIR/run_$STAMP"
mkdir -p "$RUN_DIR"

FILELIST="$RUN_DIR/filelist.f"
COMPILE_LOG="$RUN_DIR/compile.log"
SUMMARY_LOG="$RUN_DIR/summary.log"
WORK_LIB="$RUN_DIR/work"
MERGED_UCDB="$RUN_DIR/bnn_fcc_coverage_merged.ucdb"
MERGED_REPORT="$RUN_DIR/coverage_merged.txt"
MERGED_DETAILS="$RUN_DIR/coverage_merged_details.txt"

PROFILES=(sfc_ct tiny_a tiny_b odd deg1 deg2)
MANDATORY=(sfc_ct deg2)

# ── Build file list (order: pkg/ifaces → DUT → core TB → profile wrappers) ──
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
  echo "$ROOT_DIR/verification/bnn_fcc_coverage_tb.sv"
  for p in "${PROFILES[@]}"; do
    echo "$ROOT_DIR/verification/profiles/bnn_fcc_coverage_tb_${p}.sv"
  done
} > "$FILELIST"

echo "[INFO] target=$TARGET"                 | tee "$SUMMARY_LOG"
echo "[INFO] run_dir=$RUN_DIR"                | tee -a "$SUMMARY_LOG"
echo "[INFO] profiles=${PROFILES[*]}"         | tee -a "$SUMMARY_LOG"

# ── Compile once ────────────────────────────────────────────────────────────
rm -rf "$WORK_LIB"
vlib "$WORK_LIB" >/dev/null
vmap work "$WORK_LIB" >/dev/null

set +e
vlog -sv +cover=bcesft -work work -f "$FILELIST" 2>&1 | tee "$COMPILE_LOG"
VLOG_RC=${PIPESTATUS[0]}
set -e
if [[ $VLOG_RC -ne 0 ]]; then
  echo "[FAIL] Compilation failed"            | tee -a "$SUMMARY_LOG"
  exit "$VLOG_RC"
fi
echo "[INFO] compile ok"                      | tee -a "$SUMMARY_LOG"

# ── Simulate each profile ──────────────────────────────────────────────────
declare -A PROFILE_STATUS
declare -a UCDB_FILES=()
OVERALL_FAIL=0

for p in "${PROFILES[@]}"; do
  TOP="bnn_fcc_coverage_tb_${p}"
  SIM_LOG="$RUN_DIR/sim_${p}.log"
  DO_FILE="$RUN_DIR/run_${p}.do"
  UCDB_FILE="$RUN_DIR/cov_${p}.ucdb"

  cat > "$DO_FILE" <<EOF
onerror {quit -code 1}
coverage save -onexit "$UCDB_FILE"
run -all
quit -code 0
EOF

  echo "[INFO] ──── running profile: $p ($TOP) ────"  | tee -a "$SUMMARY_LOG"

  set +e
  vsim -c -coverage -voptargs="+acc -O5" "work.$TOP" \
    -do "$DO_FILE" 2>&1 | tee "$SIM_LOG"
  VSIM_RC=${PIPESTATUS[0]}
  set -e

  SIM_ERR_COUNT="$(grep -cE '^# \*\* (Error|Fatal):|^\*\* (Error|Fatal):' "$SIM_LOG" || true)"
  SUCCESS_LINE="$(grep -c 'SUCCESS: all tests passed' "$SIM_LOG" || true)"

  if [[ $VSIM_RC -ne 0 || "${SIM_ERR_COUNT:-0}" -ne 0 || "${SUCCESS_LINE:-0}" -eq 0 ]]; then
    PROFILE_STATUS[$p]="FAIL (rc=$VSIM_RC err=$SIM_ERR_COUNT success=$SUCCESS_LINE)"
    echo "[FAIL] $p"                           | tee -a "$SUMMARY_LOG"
    for m in "${MANDATORY[@]}"; do
      if [[ "$p" == "$m" ]]; then OVERALL_FAIL=1; fi
    done
  else
    PROFILE_STATUS[$p]="PASS"
    echo "[PASS] $p"                           | tee -a "$SUMMARY_LOG"
  fi

  if [[ -f "$UCDB_FILE" ]]; then
    UCDB_FILES+=("$UCDB_FILE")
  fi
done

# ── Merge UCDBs + generate reports ─────────────────────────────────────────
if [[ ${#UCDB_FILES[@]} -gt 0 ]]; then
  set +e
  vcover merge -out "$MERGED_UCDB" "${UCDB_FILES[@]}" 2>&1 | tee -a "$SUMMARY_LOG"
  MERGE_RC=${PIPESTATUS[0]}
  set -e
  if [[ $MERGE_RC -eq 0 && -f "$MERGED_UCDB" ]]; then
    vcover report -summary "$MERGED_UCDB" > "$MERGED_REPORT" 2>&1 || true
    vcover report -details "$MERGED_UCDB" > "$MERGED_DETAILS" 2>&1 || true
    echo "[INFO] merged UCDB: $MERGED_UCDB"     | tee -a "$SUMMARY_LOG"
    echo "[INFO] coverage summary: $MERGED_REPORT" | tee -a "$SUMMARY_LOG"
  else
    echo "[WARN] UCDB merge failed (rc=$MERGE_RC)" | tee -a "$SUMMARY_LOG"
  fi
else
  echo "[WARN] no UCDBs produced"              | tee -a "$SUMMARY_LOG"
fi

# ── Per-profile status summary ─────────────────────────────────────────────
echo ""                                         | tee -a "$SUMMARY_LOG"
echo "=== Profile Status ==="                   | tee -a "$SUMMARY_LOG"
for p in "${PROFILES[@]}"; do
  printf "  %-8s %s\n" "$p" "${PROFILE_STATUS[$p]:-UNKNOWN}" | tee -a "$SUMMARY_LOG"
done
echo "======================="                  | tee -a "$SUMMARY_LOG"

if [[ $OVERALL_FAIL -ne 0 ]]; then
  echo "[FAIL] one or more mandatory-minimum profiles (SFC_CT, DEG2) failed" | tee -a "$SUMMARY_LOG"
  exit 2
fi

echo "[PASS] mandatory-minimum profiles passed (SFC_CT, DEG2); see summary for full list" | tee -a "$SUMMARY_LOG"
exit 0
