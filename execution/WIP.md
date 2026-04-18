---
name: Work-In-Progress — Phase 5 bnn_fcc
description: >
  Live WIP — Phase 6 timing closure reached 617.665 MHz on XCU250-FIGD2104-2L-E
  with RTL SFC, coverage, and functional-top post-synth gates green.
date: 2026-04-17
author: Claude (Opus 4.7 1M), Codex
---

# WIP — Phase 5 `bnn_fcc`
*Last updated: 2026-04-17 EDT*

## Status

| Sub-phase | Scope | Status | Evidence |
|---|---|---|---|
| 5A | Structural `bnn_fcc` RTL | ✅ closed | `.work/modules/bnn_fcc/bnn_fcc.sv` |
| 5B | Shipped SFC easy/stress | ✅ closed | `.work/logs/bnn_fcc_shipped_sfc/run_20260417_120400` |
| 5C | Shipped contest stress | ✅ closed | `.work/logs/bnn_fcc_shipped_sfc/run_20260417_120400` |
| 5D | Additive coverage TB | ✅ closed (re-confirmed 2026-04-17) | `.work/logs/bnn_fcc_coverage_final/run_20260417_120417` |
| 5E | openflex + post-syn sim | ✅ closed — fMax 541.13 MHz, post-synth sim PASS | `openflex/bnn_fcc.csv`, `openflex/build_vivado/outputs/`, `.work/logs/bnn_fcc_post_synth_sim/run_20260417_120257` |
| 6 | 600 MHz timing push | ✅ closed — fMax 617.665 MHz | `openflex/bnn_fcc.csv`, `logs/bnn_fcc_shipped_sfc/run_20260417_191759`, `logs/bnn_fcc_coverage_final/run_20260417_191810`, `logs/bnn_fcc_post_synth_sim/run_20260417_194827` |

## Phase 6 Closure — 2026-04-17 19:50 EDT

Current result:
- OpenFlex latest CSV row: `617.6652254478073 MHz`.
- Routed WNS: `-0.619 ns` against the 1.000 ns OpenFlex push clock.
- 600 MHz threshold requires WNS no worse than about `-0.667 ns`, so this run clears target by about `48 ps`.
- Previous 556.483 MHz result improved by `+61.182 MHz`.

RTL timing changes that closed 600 MHz:
- `rtl/bnn_neuron_processor/NP_fsm.sv`
  - Removed `valid_out_we`, `activation_r_we`, and `out_score_r_we` from IDLE/COMPUTE last-beat paths.
  - Asserted output capture enables in `RESET`, one cycle after the final beat has already accumulated.
- `rtl/bnn_neuron_processor/NP_datapath.sv`
  - Changed final score capture from `acc_next` to `acc_r_q`.
  - This removes the last-beat XNOR/popcount/add chain from `final_score_r_q` timing.
- Earlier Phase 6 changes kept in place:
  - `LOCAL_X_REG` in `NP_datapath.sv`, `neuron_processor.sv`, and `bnn_np_bank.sv`.
  - `WPN_BITS` and `BPN_BITS` counter-width bounding in `bnn_unpack_datapath.sv`.

Validation evidence after the 617.665 MHz run:
- Shipped SFC stress: `logs/bnn_fcc_shipped_sfc/run_20260417_191759`
  - `SUCCESS: all 50 tests completed successfully.`
- Coverage final sweep: `logs/bnn_fcc_coverage_final/run_20260417_191810`
  - all profiles PASS: `sfc_ct`, `tiny_a`, `tiny_b`, `odd`, `deg1`, `deg2`.
  - mandatory minima PASS: `SFC_CT`, `DEG2`.
  - merged UCDB: `logs/bnn_fcc_coverage_final/run_20260417_191810/bnn_fcc_coverage_merged.ucdb`.
- Functional-top post-synthesis sim: `logs/bnn_fcc_post_synth_sim/run_20260417_194827`
  - generated and synthesized a functional SFC top (`bnn_fcc_sfc_top`) instead of the OpenFlex OOC timing wrapper.
  - `SUCCESS: all 1 tests completed successfully.`

What failed and why:
- The first post-synth repair attempt simulated the `bnn_fcc_timing` OOC wrapper netlist.
- That wrapper has registered ready/data shell logic for timing closure, not a protocol-equivalent AXI skid boundary.
- It first stalled when stimulus began before `glbl` GSR release, then completed after deterministic handshakes but produced `actual=0` vs `expected=7`.
- Resolution: synthesize a functional pass-through SFC top for post-synth simulation and run the post-synth TB against that netlist.

Current top routed paths after 617.665 MHz:
- `u_m8` payload/header control: `payload_byte_cnt_r_q[11] -> hdr_byte_cnt_r_q[3]/CE`, WNS `-0.619 ns`, 72% route.
- `g_m10[2]` unpack control: `neuron_byte_rem_r_q[3] -> neuron_idx_r_q[13:15]/CE`, WNS `-0.618 ns`, 63% route.
- NP final-score capture is no longer the critical path family.

Failed >620 MHz attempt:
- Tried inserting an IDLE bubble between consecutive config messages in `bnn_cfg_header_parser_fsm.sv` to remove the direct `payload_done -> hdr_byte_cnt CE` path.
- Also tried `max_fanout=2` hints on `payload_byte_cnt_r_q` and `neuron_byte_rem_r_q`.
- RTL SFC validation passed: `logs/bnn_fcc_shipped_sfc/run_20260417_195236`.
- OpenFlex regressed to `524.3838489774515 MHz` with routed WNS about `-0.907 ns`.
- Regression was reverted and the CSV regression row was removed. Do not retry this exact combination.

Runner tracking decision:
- The ignored runner fixes are part of reproducing the post-synth gate and should be force-added if a validation commit includes the gate repair.
- Generated simlib side effects (`.Xil/`, `.cxl.*`, `compile_simlib.log*`, `modelsim.ini.bak`) are build artifacts and should remain untracked/overwritten.

## Evidence

### Shipped correctness

- `.work/logs/bnn_fcc_shipped_sfc/run_20260417_120400`
- `SUCCESS: all 50 tests completed successfully.`
- contest-stress settings:
  - `TOGGLE_DATA_OUT_READY=1`
  - `CONFIG_VALID_PROBABILITY=0.8`
  - `DATA_IN_VALID_PROBABILITY=0.8`

### Coverage sweep

- `.work/logs/bnn_fcc_coverage_final/run_20260417_120417`
- all profiles PASS:
  - `sfc_ct`
  - `tiny_a`
  - `tiny_b`
  - `odd`
  - `deg1`
  - `deg2`
- mandatory minima PASS:
  - `SFC_CT`
  - `DEG2`

Merged coverage:
- `.work/logs/bnn_fcc_coverage_final/run_20260417_120417/coverage_merged.txt`
- total filtered view `71.59%`

## Fixes applied in this phase

### Config done race

`bnn_config_manager.cfg_done` previously asserted before final M10 writes fully drained.
This caused the first image in ODD/DEG2 to prefetch stale RAM values.

Fixed by adding:
- `cfg_done_pending_r_q`
- `cfg_done_drain_r_q`
- `dispatch_idle`

### Coverage bench settle

Added `wait_post_config_settle()` after config delivery before image injection.
This remains public-boundary safe and avoids bench-side races.

## Phase 5E closure — 2026-04-17 12:05 EDT

Purpose: recover from the interrupted timing-optimization session, verify the
dirty RTL, complete deterministic timing closure, and rerun correctness gates.

Recovery finding:
- `last_known_log.md` existed but was 0 bytes, so the pasted log plus current
  Vivado reports were used as the recovery source.
- The interrupted proposed `cfg_load_*` edit had not landed.
- Pre-edit validation passed:
  - `.work/logs/bnn_fcc_shipped_sfc/run_20260417_112616` — shipped SFC 5-image PASS.
  - `.work/logs/bnn_config_manager_sweep/coverage_merged_20260417_112628.ucdb` — config-manager SW01-SW12 PASS.

Timing optimizations applied and validated:
- `.work/modules/bnn_cfg_header_parser/bnn_cfg_header_parser_dp.sv`
  - converted payload byte tracking to a down-counter and adjusted 16th-byte header extraction to use the pre-shift register view.
  - rationale: remove a wide `total_bytes_r_q - 1` compare from the payload-boundary path.
- `.work/modules/bnn_config_manager/bnn_config_manager.sv`
  - registered `cfg_load_w` and `cfg_load_t` before M10/M9 reset/control fanout.
  - rationale: break `hdr_is_error` / header decode path before it drives M10 and threshold-index clears.
- `.work/modules/bnn_unpack_datapath/bnn_unpack_datapath.sv`
  - converted M10 per-neuron byte tracking from count-up against `bpn_r_q` to a bytes-remaining down-counter.
  - rationale: remove `bpn_r_q` from the steady-state FSM/counter-clear compare cone.
- `.work/modules/bnn_neuron_processor/NP_datapath.sv`
  - added one-cycle final score/threshold capture before threshold comparison.
  - rationale: split `x_in -> XNOR/popcount/add/threshold compare -> activation` into registered stages.
- `.work/modules/bnn_layer_engine/bnn_layer_engine.sv`
  - changed layer result wait to `FANOUT_STAGES + 1` to align M4/M5 with the new NP final-result stage.

OpenFlex timing evidence:
- command: `source /apps/reconfig/enable_pro && source ~/envs/openflex/bin/activate && cd openflex && openflex bnn_fcc_timing.yml -c bnn_fcc.csv`
- latest CSV row in `openflex/bnn_fcc.csv`:
  - `fMax = 541.125541 MHz`
  - area: `2630 LUT`, `3073 REG`, `17 BRAM`, `0 DSP`
  - Vivado reported `0 Critical Warnings` and `0 Errors`.
- post-route report:
  - `WNS = -0.848 ns` against the 1 ns OpenFlex pushdown clock.
  - `WHS = +0.010 ns`.
  - setup target is still intentionally over-constrained at 1 ns; computed fMax is in the SYSTEM_SPEC §9.11.1 500–600 MHz target band.

Final simulation evidence after timing edits:
- `.work/logs/bnn_fcc_shipped_sfc/run_20260417_120400`
  - shipped SFC contest-stress PASS.
  - `SUCCESS: all 50 tests completed successfully.`
- `.work/logs/bnn_fcc_coverage_final/run_20260417_120417`
  - coverage sweep PASS for all six profiles: `sfc_ct`, `tiny_a`, `tiny_b`, `odd`, `deg1`, `deg2`.
  - mandatory minima PASS: `SFC_CT`, `DEG2`.
- `.work/logs/bnn_fcc_post_synth_sim/run_20260417_120257`
  - post-synthesis functional netlist simulation PASS.
  - `SUCCESS: all 1 tests completed successfully.`

Environment caveat:
- Evidence was generated with Vivado 2021.2 on `XCU250-FIGD2104-2L-E`.
- SYSTEM_SPEC still names Vivado 2025.1 as the desired contest tool version; rerun on a 2025.1 host if strict version matching is required.

Remaining work:
- No blocking Phase 5E work remains in this environment.
- Optional: rerun OpenFlex/Vivado on a host with Vivado 2025.1 for contest-version parity.
- Optional: continue timing polish toward the upper 600 MHz bound; current 541.13 MHz satisfies the target band.

## 2026-04-17 04:36 Pre-Optimization Reconfirmation

Purpose: before starting Phase 5E timing optimization, rerun `bnn_fcc` and related verification to ensure previous-agent changes did not break the current source.

Current-source fixes applied during reconfirmation:
- `.work/modules/bnn_config_manager/bnn_config_manager.sv`: `cfg_done_pending_r_q` now has priority over new `final_cfg_seen` detection so the drain counter cannot be reloaded indefinitely.
- `.work/modules/bnn_config_manager/bnn_config_manager.sv`: `final_cfg_seen` now treats accepted public `config_last` as the authoritative end-of-config marker, then still waits for the drain/dispatch-idle sequence before asserting `cfg_done`.
- `.work/modules/bnn_config_manager/bnn_config_manager.sv`: post-TLAST drain widened from 16 cycles to 512 cycles (`cfg_done_drain_r_q` widened to 10 bits) to cover synthesized/netlist dispatch visibility.
- `.work/verification/bnn_fcc_coverage_tb.sv`: fixed signed class coverage bins and monotonic latency IDs, removing prior coverage-bin and latency tracker warnings.
- `.work/verification/bnn_fcc_coverage_tb.sv`: SV09 `MAX_CFG_TO_IMG_CYCLES` increased to 2048 cycles to match the intentional 512-cycle RTL drain margin.
- `.work/scripts/run_bnn_fcc_post_synth_sim.sh`: fixed `MODELSIM`/`work` mapping order and removed duplicate `glbl.v` compilation.
- `.work/verification/bnn_fcc_post_synth_tb.sv`: added progress diagnostics for config/image/output handshakes.

Final pre-synthesis evidence after the 512-cycle drain:
- Shipped SFC stress: `.work/logs/bnn_fcc_shipped_sfc/run_20260417_043341` — PASS, `SUCCESS: all 50 tests completed successfully.`
- Shipped custom stress: `.work/logs/bnn_fcc_shipped_custom/run_20260417_043405` — PASS, `SUCCESS: all 30 tests completed successfully.`
- Coverage final sweep: `.work/logs/bnn_fcc_coverage_final/run_20260417_043534` — PASS, all six profiles pass (`sfc_ct`, `tiny_a`, `tiny_b`, `odd`, `deg1`, `deg2`) and mandatory minima (`SFC_CT`, `DEG2`) pass.

Post-synthesis status:
- Rebuilt OpenFlex once after the `config_last` fix, but before the final 512-cycle drain. That DCP is now stale and must be rebuilt again before post-synth evidence is valid.
- Stale post-synth 1-image run `.work/logs/bnn_fcc_post_synth_sim/run_20260417_043225` no longer stalls at `data_in_ready`, but mismatched one output (`actual=0 expected=8`). Do not use it as closure evidence because it predates the final 512-cycle drain RTL.
- Next required step: rerun `source /apps/reconfig/enable_pro && source ~/envs/openflex/bin/activate && cd openflex && openflex bnn_fcc_timing.yml -c bnn_fcc.csv`, then rerun `NUM_TEST_IMAGES=1 bash .work/scripts/run_bnn_fcc_post_synth_sim.sh`.
