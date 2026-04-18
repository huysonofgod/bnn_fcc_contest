# Engineering Journey — BNN_FCC Technical Evolution
**Date:** April 17, 2026

This document chronicles the technical evolution of the Fully Connected BNN (BNN_FCC) design from the original contest baseline to the current timing-optimized and fully verified submission.

## 1. Initial State: The Contest Baseline
The journey began with a set of modular building blocks:
- A basic `neuron_processor` capable of XNOR-accumulate operations.
- The AXI4-Stream protocol skeleton for configuration and image ingress.
- A "shipped" correctness testbench (`bnn_fcc_tb.sv`) to ensure functional compliance with the MNIST dataset.

## 2. Phase 4: Architectural Composition
The first major engineering milestone was the structural integration of the top-level `bnn_fcc` module.
- **Config Management**: Development of the `bnn_config_manager` (M4) to parse weights and thresholds.
- **Input Binarization**: Implementation of the `bnn_input_binarizer` (M6) to convert 8-bit stream beats into 1-bit parallel words.
- **Layer Engines**: Designing the `bnn_layer_engine` as a reusable, parameterized wrapper around the `neuron_processor` banks and inter-layer buffers.

## 3. Phase 5: Timing Closure & Optimization
With functional parity achieved, the focus shifted to the 500–600 MHz timing target on the Virtex UltraScale+ (XCU250).

### 3.1 Breaking the Critical Paths
Initial synthesis runs hovered around 400 MHz. Bottlenecks were identified in the configuration ingress and BRAM address generation:
- **M10 Refactor**: The `bnn_weight_unpacker` was refactored to use static "words-per-neuron" parameters, removing complex dynamic calculations from the critical path.
- **Config-Manager Pipeline**: The `bnn_config_manager` was updated to perform constant-based indexing for layer routing, breaking the long combinational paths from the header parser to the per-layer RAM ports.
- **Down-Counters**: Iteration and byte counters were converted to down-counters with zero-detection logic, which synthesized more efficiently at high frequencies.

### 3.2 The Results
Through iterative timing analysis using OpenFlex, the design achieved a consistent **543 MHz**, comfortably exceeding the contest requirements.

## 4. Phase 5D: Verification Rigor
Verification was expanded from simple correctness to comprehensive coverage evidence:
- **UVM Implementation**: A full UVM environment was introduced in `bnn_fcc_cov_pkg.sv` to support randomized stress testing.
- **Additive Coverage**: The `bnn_fcc_coverage_tb.sv` was authored to meet the judge's mandate for Apple's scoring script, covering:
    - AXI protocol corner cases (stall/burst patterns).
    - Configuration diversity (message sizes, bad types).
    - Computational stimulus (consecutive classes, stress levels).
    - Reset scenarios (mid-config, mid-image interrupts).

## 5. Final Convergence: The Official Sync
The final step was the surgical synchronization performed today. By porting the "functional truth" from the testing ground back to the official repository, we have delivered a high-performance, robustly verified BNN accelerator that respects all contest mandates while maximizing device capability.

---
*The result is a design that is not just correct, but engineering-hardened for high-frequency FPGA implementation.*

---

## 6. Lab Machine Hardware Profile & Tool Parallelism

**Profiled 2026-04-17** — applies to all synthesis and simulation runs.

| Resource | Value |
|---|---|
| CPU | Intel Xeon Gold 6146, 2×12 = **24 physical cores**, no HT, 3.20 GHz |
| RAM | **93 GB total**, ~24 GB typically available (shared machine) |
| Swap | 39 GB; often fully exhausted — don't run two simultaneous Vivado instances |
| Typical load | ~11–12 avg (multiple users run Vivado/Questa) |

### Vivado (OpenFlex)
Already configured at `set_param general.maxThreads 8` in `vivado_flow.tcl:118`. **8 is the Vivado maximum for P&R** — no further tuning needed.

### Questa
- `modelsim.ini`: `ParallelJobs = 8` — parallel code-gen processes during vlog/vopt
- All `scripts/*.sh`: `-voptargs="+acc -O5"` applied — maximum Questa vopt optimization; `-O5` compiles a faster simulation binary while preserving `+acc` debug visibility

---

## 7. Phase 6: Fmax Push — 543 MHz → 600 MHz (WIP, April 17 2026)

**Target:** 600 MHz on XCU250-FIGD2104-2L-E  
**Baseline entering this phase:** 543 MHz (FANOUT_STAGES=1, pre-opt)  
**Validation command:** `NUM_TEST_IMAGES=50 bash scripts/run_bnn_fcc_shipped_sfc.sh` (must PASS after every change)

### 6.1 Critical Path Analysis

All failing paths at baseline had 64–68% routing delay share (not logic). This means simple flattening or logic restructuring helps only by giving the placer more freedom — it does not directly reduce net delay. The key strategy is: **create static structure that constrains the placement problem**.

OpenFlex runs showed three independent path families dominating WNS (-0.887 ns → 1.113 ns period):

| Path family | Module | Root cause |
|---|---|---|
| NP broadcast fanout | `bnn_np_bank` / `NP_datapath` | Shared `u_x_align` reg driving all 8 NPs from central location → 1.1 ns cross-NP route |
| M10 word_rem comparator | `bnn_unpack_datapath` | `word_rem_r_q[8]` on 16-bit counter driving `last_word` comparator |
| M10 neuron_byte_rem path | `bnn_unpack_datapath` | `neuron_byte_rem_r_q[14+]` on 16-bit counter driving zero-detect / reload paths |

### 6.2 Optimization 1: LOCAL_X_REG — Per-NP x Pipeline Register

**Problem:** `bnn_np_bank` uses `bnn_fanout_buf` with PIPE_STAGES=1 to pipeline `x_in` before broadcasting to all 8 NPs. This creates ONE central register (`u_x_align/q_r_q[7:0]`) that drives 8 separate `acc_r_q` flip-flops scattered across the fabric. Vivado cannot co-locate them → 1.1 ns routing on every beat.

**Fix:** Introduced `LOCAL_X_REG` parameter chain:
- `NP_datapath.sv`: Added `parameter int LOCAL_X_REG = 0`. When 1, instantiates `x_r_q` locally so Vivado packs it adjacent to `acc_r_q`.
- `neuron_processor.sv`: Pass-through `LOCAL_X_REG` parameter.
- `bnn_np_bank.sv`: Added `localparam int NP_LOCAL_X_REG = (FANOUT_STAGES > 0) ? 1 : 0`. Reduced `u_x_align` PIPE_STAGES by 1 (so total latency preserved). Passes `NP_LOCAL_X_REG` to each neuron_processor.

**Result:** After LOCAL_X_REG run, NP broadcast paths were eliminated from route_paths.rpt. New top path became M10[1] `neuron_byte_rem_r_q_reg[3]/C → neuron_byte_rem_r_q_reg[0]/R`.

**Files changed:**
- `rtl/bnn_neuron_processor/NP_datapath.sv` — LOCAL_X_REG param + x_r_q generate block
- `rtl/bnn_neuron_processor/neuron_processor.sv` — LOCAL_X_REG pass-through
- `rtl/bnn_np_bank/bnn_np_bank.sv` — NP_LOCAL_X_REG localparam, u_x_align PIPE_STAGES-1, LOCAL_X_REG→neuron_processor

### 6.3 Optimization 2: WPN_BITS — Bound word_rem_r_q Counter Width

**Problem:** `word_rem_r_q` in `bnn_unpack_datapath` was declared as 16-bit. For STATIC_WORDS_PER_NEURON=98 (layer 0), only 7 bits are needed. The extra bits (especially bit[8]) appear on the `last_word` comparator → neuron_byte_rem reload path.

**Fix:** Added `localparam int WPN_BITS = (STATIC_WORDS_PER_NEURON > 0) ? $clog2(STATIC_WORDS_PER_NEURON + 1) : 16`. Changed `word_rem_r_q`, `word_rem_dec_w`, and `word_rem_next` to `[WPN_BITS-1:0]`. All comparisons cast to `WPN_BITS'(...)`.

**Files changed:** `rtl/bnn_unpack_datapath/bnn_unpack_datapath.sv`

### 6.4 Optimization 3: BPN_BITS — Bound neuron_byte_rem_r_q Counter Width

**Problem:** `neuron_byte_rem_r_q` was 16-bit. For STATIC_BYTES_PER_NEURON=32 (layer 2 of M10), only 6 bits are needed. Bit[14] appeared on two paths: neuron_byte_rem → neuron_idx/CE, and internal reload path neuron_byte_rem[3..8] → reload mux.

**Fix:** Added `localparam int BPN_BITS = (STATIC_BYTES_PER_NEURON > 0) ? $clog2(STATIC_BYTES_PER_NEURON + 1) : 16`. Changed `neuron_byte_rem_r_q` and derived signals to `[BPN_BITS-1:0]`.

**Files changed:** `rtl/bnn_unpack_datapath/bnn_unpack_datapath.sv`

### 6.5 Attempted: STATIC_NUM_NEURONS — Bound neuron_idx_r_q

**Attempted:** Adding `STATIC_NUM_NEURONS` parameter chain (bnn_config_manager → bnn_weight_unpacker → bnn_unpack_datapath) to bound `neuron_idx_r_q` from 16 bits to `$clog2(STATIC_NUM_NEURONS + 1)` bits.

**Outcome: REVERTED.** Caused simulation deadlock (10ms timeout, no output). Root cause: For M10[2] (NNEUR=1), `NNEUR_BITS = $clog2(1+1) = 1`. A 1-bit `neuron_idx_r_q` likely causes a subtle FSM interaction where `last_neuron` fires incorrectly. All parameter chains removed, `neuron_idx_r_q` restored to 16-bit, and `last_neuron` restored to `(nneur_r_q != 16'd0) && (neuron_idx_r_q == (nneur_r_q - 16'd1))`.

**Future investigation:** Would need special-casing for NNEUR=1 or using `$clog2(max(STATIC_NUM_NEURONS, 2) + 1)` to guarantee at least 2 bits.

### 6.6 Known Remaining Path: M7→M10 Barrel Shift

**Path:** `bnn_config_manager` M7 `byte_idx_r_q` → byte data mux (`payload_data`) → `bnn_unpack_datapath` M10 `masked_byte` → barrel shift → `accum_r_q`.

**Analysis:** 64–68% routing, NOT safely pipelined with simple register insertion. `accum_we` and `accum_sel` are combinational FSM outputs — inserting a data register in the datapath requires also registering FSM control outputs, which changes the FSM protocol contract. Needs careful FSM restructuring (register accum_we/accum_sel one cycle earlier, shift data register into the path).

**Status:** Deferred. Will surface as top path after LOCAL_X_REG + bounded counters.

### 6.7 Timing Run History (Phase 6)

| Run | FANOUT_STAGES | Key changes | fMax (MHz) | WNS (ns) |
|---|---|---|---|---|
| Baseline | 1 | Pre-opt | 543 | -0.887 |
| FANOUT_STAGES=2 test | 2 | Extra fanout stage | 499 | — (regression) |
| **LOCAL_X_REG + WPN_BITS + BPN_BITS** | **1** | **All three opts** | **556.5** | **-0.797** |

**Run completed 2026-04-17 18:35 UTC. +13.5 MHz gain. 43.5 MHz remaining to target.**

### 6.8 New Critical Paths After Combined Run (route_paths.rpt, 2026-04-17 18:35)

Three distinct path families. Need **0.130 ns more improvement** (WNS -0.797 → -0.667) to reach 600 MHz.

#### Family A — NP accumulate → final_score (logic-depth dominated)
- **Source:** `g_np[0].u_np/u_dp/acc_r_q[3]_i_5__19_psbram_1/C` (BRAM weight output reg, layer 2)
- **Destination:** `g_np[4].u_np/u_dp/final_score_r_q_reg[7]/D` (cross-NP lane)
- **WNS:** -0.797 ns | Logic: 0.796 ns (**47%**) | Routing: 0.894 ns (53%)
- **Depth:** 6 LUTs (LUT2, LUT3, LUT6×4)
- **Root cause:** `w_in → xnor_bits → beat_popcount → acc_next → final_score_r_q` is COMBINATIONAL. `valid_out_we` fires on the same cycle as the last beat, so `final_score_r_q <= acc_next = acc_r_q + beat_popcount` must traverse the full adder chain in one cycle.
- **Fix:** Capture `acc_r_q` (already a register) into `final_score_r_q` during the RESET state (cycle after last beat), not `acc_next` on the last beat. `acc_r_q` at RESET entry holds the complete sum. Path becomes **register → register = ~0.2 ns, zero logic depth**.
- **FSM change required:** In `NP_fsm.sv`, move `valid_out_we=1` to the RESET state. In `NP_datapath.sv`, change `final_score_r_q <= acc_next` to `final_score_r_q <= acc_r_q`. The timing of `final_result_valid_r_q` shifts by 1 cycle (harmless — downstream just sees valid one cycle later).

#### Family B — NP cross-lane x_r_q → acc/final_score (routing dominated)
- **Source:** `g_np[0].u_np/u_dp/g_x_local.x_r_q_reg[N]` (LOCAL_X_REG register, layers 0/1/2)
- **Destination:** `g_np[3/4/7/9].u_np/u_dp/acc_r_q_reg[M]` or `final_score_r_q_reg[M]`
- **WNS:** -0.791 to -0.747 ns | Logic: 30-35% | Routing: **65-70%**
- **Root cause:** Vivado merges LUTs across NP lanes (cross-lane fanout on `acc_r_q[6]_i_3__19_n_0` with fo=5). The LOCAL_X_REG keeps x_r_q local but the COMPUTE result (adder intermediate LUTs) still fans cross-NP.
- **Fix option:** Add `(* keep_hierarchy = "yes" *)` attribute on `NP_datapath` module. This stops synthesis from sharing logic across NP instances. Low-risk, 1-line change, no functional impact.
- **Fix option 2 (if keep_hierarchy fails):** Pblock constraints to explicitly place each NP in separate SLR columns. Requires a `.xdc` file.

#### Family C — M7 byte_idx_r_q → M10[1] counters (barrel shift, routing dominated)
- **Source:** `u_m7/u_dp/byte_idx_r_q_reg[1]/C`
- **Destinations:** M10[1] `word_idx_r_q_reg[N]/R`, `addr_base_r_q_reg[N]/CE`, `neuron_byte_rem_r_q_reg[N]/R`, `accum_r_q_reg[N]/D`
- **WNS:** -0.784 to -0.750 ns | Logic: 36-37% | Routing: **63-64%**
- **Root cause:** M7 `byte_idx_r_q` feeds M10's barrel-shift mux. The mux output feeds `accum_r_q` and reset signals for counters. Long cross-module route.
- **Fix:** Register `masked_byte` in `bnn_unpack_datapath.sv` (1-cycle data pipeline). Co-register `accum_we`, `accum_sel`, `pad_sel` in `bnn_unpack_ctrl.sv` (move from comb outputs to registered outputs). FSM internal timing shifts by 1 cycle — safe since all consumer paths are within the same FSM protocol.

### 6.8 Next Steps (Priority Order)

1. **Inspect results** of the LOCAL_X_REG + WPN_BITS + BPN_BITS combined run (in-flight as of 2026-04-17).
2. **M7→M10 barrel shift path**: If it surfaces as top path, consider registering `accum_we`/`accum_sel` one cycle earlier in `bnn_unpack_ctrl` and inserting one data pipeline stage.
3. **STATIC_NUM_NEURONS retry**: Fix corner case for NNEUR=1 (use `$clog2(max(STATIC_NUM_NEURONS,2)+1)` or special-case the comparison).
4. **Floorplan constraints** (`.xdc` pblock): If routing is still dominant after logic improvements, constraining M10 instances to adjacent SLR columns may reduce cross-die routing.
5. **Full milestone gate** at 600 MHz: `NUM_TEST_IMAGES=50 bash scripts/run_bnn_fcc_shipped_sfc.sh` + `bash scripts/run_bnn_fcc_coverage_final.sh` + `NUM_TEST_IMAGES=1 bash scripts/run_bnn_fcc_post_synth_sim.sh`.

### 6.9 phys_opt Note

`phys_opt_design` only engages when post-route WNS > -0.5 ns. At -0.887 ns it is a no-op. The `route_design -tns_cleanup` in the phys_opt block may cause `get_timing_paths` to return empty `$wns`, resulting in fMax="n/a" in the CSV despite a valid implementation. To diagnose: check `openflex/route_paths.rpt` directly — timestamp indicates whether a fresh run completed.

### 6.10 Closure Update: 556.5 MHz -> 617.665 MHz

**Completed 2026-04-17 19:50 EDT.** The 600 MHz target is now closed on
`XCU250-FIGD2104-2L-E`.

OpenFlex result:
- Latest `openflex/bnn_fcc.csv` row: `617.6652254478073 MHz`.
- Routed WNS: `-0.619 ns` against a 1.000 ns push clock.
- 600 MHz needs WNS no worse than about `-0.667 ns`, so the design has about
  `48 ps` of margin.

The closing RTL change was the Priority 1 NP final-score repair:
- `rtl/bnn_neuron_processor/NP_fsm.sv`
  - Last-beat acceptance in IDLE/COMPUTE no longer asserts output capture.
  - `RESET` now asserts `valid_out_we`, `activation_r_we`, and `out_score_r_we`
    while clearing the accumulator.
- `rtl/bnn_neuron_processor/NP_datapath.sv`
  - `final_score_r_q <= acc_next` changed to `final_score_r_q <= acc_r_q`.
  - The captured value is correct because non-blocking assignments read the
    pre-clear accumulator value at the RESET edge.

Why it worked:
- Before the change, `final_score_r_q` captured `acc_next` on the same cycle as
  the final beat, so BRAM weight data could traverse XNOR/popcount/add logic
  into the final score register in one 1 ns cycle.
- After the change, the final beat is accumulated first, then the next RESET
  cycle copies a registered accumulator value into the final score pipeline.
- The previous NP final-score family disappeared from the top of
  `route_paths.rpt`.

Validation after closure:
- `NUM_TEST_IMAGES=50 bash scripts/run_bnn_fcc_shipped_sfc.sh`
  - PASS: `logs/bnn_fcc_shipped_sfc/run_20260417_191759`
  - `SUCCESS: all 50 tests completed successfully.`
- `bash scripts/run_bnn_fcc_coverage_final.sh`
  - PASS: `logs/bnn_fcc_coverage_final/run_20260417_191810`
  - all profiles PASS: `sfc_ct`, `tiny_a`, `tiny_b`, `odd`, `deg1`, `deg2`.
- `NUM_TEST_IMAGES=1 bash scripts/run_bnn_fcc_post_synth_sim.sh`
  - PASS: `logs/bnn_fcc_post_synth_sim/run_20260417_194827`
  - `SUCCESS: all 1 tests completed successfully.`

Post-synthesis gate repair:
- Failed attempt: simulating the OpenFlex `bnn_fcc_timing` OOC wrapper netlist.
  - First failure mode: stimulus began before `glbl` released GSR.
  - After delaying reset/stimulus and making handshakes deterministic, the
    timing-wrapper netlist completed but returned `actual=0` vs `expected=7`.
  - Root cause: `bnn_fcc_timing` is a timing shell with registered ready/data
    boundaries, not a behaviorally equivalent AXI skid wrapper for the shipped
    testbench.
- Working fix:
  - `scripts/run_bnn_fcc_post_synth_sim.sh` now generates a temporary
    `bnn_fcc_sfc_top` pass-through top with concrete SFC parameters
    (`TOPOLOGY={784,256,256,10}`, `PARALLEL_NEURONS={8,8,10}`).
  - The script synthesizes that functional top and emits a functional netlist.
  - `test/bnn_fcc_post_synth_tb.sv` instantiates `bnn_fcc_sfc_top` and waits
    past `glbl` startup before driving traffic.

Current remaining timing work for >620 MHz:
- Top path family 1: `u_cfg_mgr/u_m8/u_dp/payload_byte_cnt_r_q_reg[11]` to
  `u_cfg_mgr/u_m8/u_dp/hdr_byte_cnt_r_q_reg[3]/CE`, WNS `-0.619 ns`,
  5 LUT levels, 72% route.
- Top path family 2: `g_m10[2].u_m10/u_dp/neuron_byte_rem_r_q_reg[3]` to
  `neuron_idx_r_q[13:15]/CE`, WNS `-0.618 ns`, 5 LUT levels, 63% route.
- The next push should focus on `u_m8`/`g_m10` control paths, not NP final score.

Failed >620 MHz attempt:
- Tried to remove the `u_m8 payload_done -> hdr_byte_cnt CE` path by routing
  consecutive config messages through the existing IDLE bubble instead of
  clearing the header counter in the last payload byte cycle.
- Also tried `max_fanout=2` hints on `u_m8 payload_byte_cnt_r_q` and M10
  `neuron_byte_rem_r_q`.
- Functional RTL validation passed (`logs/bnn_fcc_shipped_sfc/run_20260417_195236`),
  but OpenFlex regressed to `524.3838489774515 MHz` with routed WNS around
  `-0.907 ns`.
- The exact attempt was reverted. Future >620 work should use a more explicit
  registered/pipelined M10 control strategy or floorplanning, not this
  inter-message bubble plus fanout-hint combination.
