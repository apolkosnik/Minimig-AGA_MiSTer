# TG68K CPU Deep Audit Report

## Scope
Audited 68030 implementation (~24,700 lines across 7 VHDL files). Heavy technical debt: 368 `BUG #` comments in kernel (numbered 1–443), 170 in PMMU. Systemic patching suggests the original TG68K wasn't designed for 68030 and extensions were retrofitted.

## Critical architectural observations

### 1. Pipeline: 1-word pseudo-queue vs real 68030's 2-word queue
The kernel uses `last_opc_read` as a 1-stage register approximating a prefetch queue. Real 68030 has a 2-word queue feeding the decoder. This causes recurring "1-cycle stale opcode" bugs (see BUG #54/84/228/326/377/387) where `opcode` gets overwritten by prefetch of the next instruction while PMMU/MOVES/extension processing still needs it. The fix pattern used is `fline_opcode_latch` — essentially a shadow queue for specific paths. **Risk: every multi-cycle instruction touching extension words is vulnerable** unless explicitly latched.

### 2. State machine: passive idle/nop
States `idle` and `nop` have no explicit WHEN handlers. They rely on the combinational `next_micro_state <= idle` default plus `setstate <= "00"` default. This inverts normal FSM discipline — if any combinational path fails to override defaults mid-cycle, idle persists silently. No assertion guards exist.

### 3. Three PC-write paths aren't interlocked
- `writePC='1'` → `data_write_tmp <= TG68_PC` (line 2149)
- `exec(writePC_add)='1'` → `data_write_tmp <= TG68_PC_add` (line 2164)
- `exec(directPC)='1'` → `TG68_PC <= data_read` (line 2948, vector load)

Guarded via ELSIF priority, but BUG #443/#387 comments reveal historical breakage when stale trap_chk/trap_trap opcode bits from a just-retired instruction fire during trap stack push.

### 4. skipFetch works only through TG68K.vhd wrapper, not the kernel
`skipFetch` suppresses external bus assertions but does NOT stop internal TG68_PC advancement (line 2948: PC advances on `state="00"`). In direct-kernel testbenches it has no effect. On real hardware it blocks AS but PC is already corrupted if code relies on its value.

## Specific bugs / hot spots

| # | Area | Line | Issue |
|---|------|------|-------|
| 1 | EA builder | kernel 4050 (WHEN "101") | JMP/JSR with d16,An does an extra internal PC advance during ld_dAn1 — partially masked by `ea_to_pc` overwrite |
| 2 | DIVL.L flags | ALU 1411–1425 | DIVU.L / DIVS.L overflow paths use full-4-bit assignments that clear C. Hardware-verification needed via real cputest captures (C may be preserved) |
| 3 | A7 byte increment | ALU 642–663 | Byte op with A7 correctly gives +2, but through an implicit fall-through, not an explicit guard — maintenance hazard |
| 4 | PCbase latch | kernel 3582 | `PCbase <= set_PCbase OR PCbase` never explicitly cleared between instructions; cleared only on `setstate(1)='1' AND state(1)='0'`. Exception-interrupted PC-relative instructions could leak PCbase into the next instruction's EA |
| 5 | last_opc_read | kernel 3351 | Only updated on `state="10"` (read). Write cycles (state="11") stall it, creating windows where `last_data_read` is stale during write-then-fetch multi-word moves |
| 6 | rte_saved_mbit | kernel 4087 | Deferred M-bit SP swap uses `interrupt_mode='1' OR rte_saved_mbit='0'` — potential race when directSR and changeMode fire same cycle |
| 7 | Double-fault detection | kernel 3135/3181/3211 | Three separate HALT_CTX branches with overlapping conditions, all logging different context strings. Indicates historical uncertainty about which path actually triggers |
| 8 | `TG68KdotC_Kernel copy.vhd` | — | Stale 395KB backup file in the RTL directory — should be removed (or moved out of `rtl/`) to avoid accidentally compiling |

## Items that audit agents flagged but verified as non-issues

- **`BS_X` vs `bs_X` case sensitivity (ALU 1404)**: VHDL identifiers are case-insensitive. Not a bug.
- **berr_long_frame polarity (kernel 3235)**: Code correctly maps reads→Format $B, writes→Format $A per M68030UM Section 8.5.5.
- **PMMU ld_nn vs CPU ld_nn "asymmetry"**: The pass-1 guard is PMMU-specific because only PMMU has a 2-pass (xxx).L sequence feeding into register load. CPU ld_nn is single-pass and correct.

## Highest-leverage follow-ups

1. **Build a prefetch queue abstraction**: replacing `last_opc_read` with a proper 2-word queue would retire dozens of BUG # entries at once. High effort but high payoff.
2. **Remove the stale `TG68KdotC_Kernel copy.vhd`** from the tree.
3. **Capture real-hardware cputest bus traces** for the failing basic/jmp and basic/divl.l cases — the current work is blocked on guessing what the real 68030 does. Without this data, further flag/ordering fixes risk regressions like the DIVU.L overflow ones we just reverted.
4. **Add assertions to the micro-state machine**: at minimum, a single "illegal setstate/next_micro_state combination" check would catch silent idle-persistence bugs.
5. **Audit the three writePC paths** for mutual exclusion under every trap/exception. Convert them into an explicit priority mux rather than ELSIF chain.

## Test posture (current)
All local testbenches pass (18k+ assertions across arch-suite and basic-cputest). Passing local tests don't imply hardware correctness — the failing cputest `basic/jmp`, `basic/divl.l`, and T1 "lost unused SR bits" cases aren't covered by the VHDL TB suite.
