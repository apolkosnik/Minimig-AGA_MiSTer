# TG68K PMMU (MC68030) Deep Audit

_Last refresh 2026-04-17. All citations into [TG68K_PMMU_030.vhd](rtl/tg68k/TG68K_PMMU_030.vhd) (4202 lines, **179** `BUG #` comments), [TG68KdotC_Kernel.vhd](rtl/tg68k/TG68KdotC_Kernel.vhd), [TG68K_Pack.vhd](rtl/tg68k/TG68K_Pack.vhd), and [cpu_wrapper.v](rtl/cpu_wrapper.v)._

## Executive summary

The MMU is a mostly-functional MC68030 PMMU built around:

- a 6-register control-surface (`TC`, `CRP`, `SRP`, `TT0`, `TT1`, `MMUSR`) with strict write-masks;
- a **22-entry** address translation cache (ATC, pseudo-LRU);
- a multi-level walker with dedicated states for short (4-byte) and long (8-byte) descriptors, early-termination page descriptors, indirect descriptors, limit checking, U/M bit write-back, and a 500-cycle walker watchdog;
- combinational TTR bypass to sidestep stale `addr_phys_reg`;
- a fault pipeline that feeds the kernel with logical address, FC, RW, and insn-flag latched _at fault time_ (BUG #414/#415);
- an MMU-Configuration-Exception path (vector 56) for illegal TC / DT=00 root pointers, distinct from the bus-error (vector 2) path — with a **sticky** `mmu_config_error` latch (BUG #445) that cannot be silently cleared by a subsequent valid write;
- **observable + trapped** illegal-PMOVE-reg_sel behavior (BUG #446) — previously silent ignores now raise a sim assertion, set a sticky `debug_illegal_reg_sel` port, **and** raise a vector-56 hardware trap via the existing `mmu_config_error` path.

The `CAL`, `VAL`, `SCC`, `AC` registers are deliberately not implemented. PMOVE is the sole PMMU-register access path; the kernel's MOVEC whitelist does **not** include MMU registers (so software using MOVEC for TC/TT0/TT1/MMUSR traps as privilege violation in this tree). This deviation from the spec is documented in the updated file header ([PMMU:100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L100-L106)).

New since prior refresh (2026-04-16):
- Header comment fixed: "22-entry ATC" and PMOVE-only access note ([PMMU:3, 100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L3)).
- `mmu_config_error` is a true sticky latch (BUG #445) — no more race against repeated TC writes.
- Illegal PMOVE reg_sel is observable (BUG #446) — sim asserts + sticky latch + debug port.
- New wrapper-level bench [tests/tg68k_030/tb_cpu_wrapper_pmmu.v](tests/tg68k_030/tb_cpu_wrapper_pmmu.v) (+ `test-cpu-wrapper-pmmu` Makefile target) exercises walker ownership, BUG #422 stale-ready, BUG #439 RAM-gap, BUG #424 watchdog escape, BUG #417 physical-address routing.

## 1. Register surface

All register signals are declared at [PMMU:105-112](rtl/tg68k/TG68K_PMMU_030.vhd#L105-L112). Write masks are at [PMMU:123-133](rtl/tg68k/TG68K_PMMU_030.vhd#L123-L133). Writes happen in the `case reg_sel` block at [PMMU:1061-1207](rtl/tg68k/TG68K_PMMU_030.vhd#L1061-L1207); reads are combinational at [PMMU:1226-1234](rtl/tg68k/TG68K_PMMU_030.vhd#L1226-L1234).

### TC — Translation Control ([PMMU:105](rtl/tg68k/TG68K_PMMU_030.vhd#L105))
32-bit. Write mask `TC_WRITE_MASK = 0x83FFFFFF` ([PMMU:123](rtl/tg68k/TG68K_PMMU_030.vhd#L123)) — preserves E, SRE, FCL, all PS/IS/TI fields, forces reserved bits 30:26 to zero (bit 23 is the PS MSB; all valid PS values 8–15 have it set).

| Bits | Field | Notes |
|---|---|---|
| 31 | E | Enable — gated by `mmu_config_error` (`tc_en <= TC(31) and not mmu_config_error`, [PMMU:1275](rtl/tg68k/TG68K_PMMU_030.vhd#L1275)) — MMU stays disabled as long as the sticky BUG #445 latch is held |
| 30:26 | Reserved | Forced 0 |
| 25 | SRE | Supervisor Root Enable |
| 24 | FCL | Function Code Lookup (adds one walk level) |
| 23:20 | PS | Page Size (8–15 valid; 0–7 raises config error at [PMMU:1087-1092](rtl/tg68k/TG68K_PMMU_030.vhd#L1087-L1092)) |
| 19:16 | IS | Initial Shift |
| 15:12 | TIA | Table Index A |
| 11:8 | TIB | Table Index B |
| 7:4 | TIC | Table Index C |
| 3:0 | TID | Table Index D |

Field-sum check `tc_total_bits(reg_wdat) /= 32` raises `mmu_config_error` ([PMMU:1101-1120](rtl/tg68k/TG68K_PMMU_030.vhd#L1101-L1120)). **BUG #445** ([PMMU:1094-1099](rtl/tg68k/TG68K_PMMU_030.vhd#L1094-L1099)): a valid TC write does not clear the latch — only `mmu_config_ack` (the kernel acknowledging vector 56) or async reset does. This closes the race where `pmmu_config_err` could drop before `trap_mmu_config` was registered.

### CRP / SRP — CPU / Supervisor Root Pointers ([PMMU:106-109](rtl/tg68k/TG68K_PMMU_030.vhd#L106-L109))
Each is a 64-bit register stored as two 32-bit halves (`*_H`, `*_L`). Accessed via PMOVE with `reg_part='1'` for HIGH and `'0'` for LOW.

- HIGH mask `CRP_HIGH_MASK = 0xFFFF0003` ([PMMU:130](rtl/tg68k/TG68K_PMMU_030.vhd#L130)): preserves `L/U[31]`, `LIMIT[30:16]`, `DT[1:0]`; zeros reserved [15:2].
- LOW mask `CRP_LOW_MASK = 0xFFFFFFF0` ([PMMU:133](rtl/tg68k/TG68K_PMMU_030.vhd#L133)): preserves table address [31:4]; zeros reserved [3:0].
- Writing HIGH with `DT=00` raises `mmu_config_error` ([PMMU:1132-1141, 1158-1167](rtl/tg68k/TG68K_PMMU_030.vhd#L1132-L1141)). The register is still loaded first, per spec. BUG #445 applies here too — a subsequent valid CRP/SRP write does not clear the latch.
- Any write (unless `reg_fd='1'` = PMOVEFD) raises `atc_flush_req` to invalidate cached translations ([PMMU:1148-1150, 1177-1179](rtl/tg68k/TG68K_PMMU_030.vhd#L1148-L1150)).

### TT0 / TT1 — Transparent Translation ([PMMU:110-111](rtl/tg68k/TG68K_PMMU_030.vhd#L110-L111))
Write mask `TTR_WRITE_MASK = 0xFFFF8777` ([PMMU:127](rtl/tg68k/TG68K_PMMU_030.vhd#L127)):

| Bits | Field |
|---|---|
| 31:24 | Logical Address Base |
| 23:16 | Logical Address Mask |
| 15 | E (enable) |
| 14:11 | Reserved |
| 10 | CI (cache inhibit) |
| 9 | RW (read/write match value) |
| 8 | RWM (mask: 1 = ignore RW, match both) |
| 7 | Reserved |
| 6:4 | FC Base |
| 3 | Reserved |
| 2:0 | FC Mask |

Match logic is `ttr_check()` ([PMMU:472-583](rtl/tg68k/TG68K_PMMU_030.vhd#L472-L583)); **BUG #421** ([PMMU:4030](rtl/tg68k/TG68K_PMMU_030.vhd#L4030)) notes the caller must pass the actual `rw` signal, not the hard-coded read case, so RWM=0 writes get properly rejected.

### MMUSR — MMU Status Register ([PMMU:112](rtl/tg68k/TG68K_PMMU_030.vhd#L112))
32-bit storage, but only the low 16 bits are meaningful. PMOVE to MMUSR is a **direct 16-bit store** ([PMMU:1185-1188](rtl/tg68k/TG68K_PMMU_030.vhd#L1185-L1188), MC68030UM §9.6.3.4). PMOVE read returns `X"0000" & MMUSR(15 downto 0)` ([PMMU:1233](rtl/tg68k/TG68K_PMMU_030.vhd#L1233)).

As-implemented bit layout ([PMMU:825-836, 852-862, 882-888](rtl/tg68k/TG68K_PMMU_030.vhd#L825-L836)):

| Bit | Field |
|---|---|
| 15 | B — external BERR during walk (BUG #153 restricts this to external BERR only, [PMMU:2478](rtl/tg68k/TG68K_PMMU_030.vhd#L2478)) |
| 14 | L — limit violation |
| 13 | S — supervisor-only violation |
| 12 | Reserved (0) |
| 11 | W — write protect |
| 10 | I — invalid descriptor |
| 9 | M — modified |
| 8:7 | Reserved (0) |
| 6 | T — transparent (TTR match) |
| 5:3 | Reserved (0) |
| 2:0 | N — level count |

The layout above matches MC68030 UM §9.7.1 Table 9-1 (B[15], L[14], S[13], W[11], I[10], M[9], T[6], N[2:0]). Encoder/decoder functions `encode_mmusr_fault` / `encode_mmusr_success` ([PMMU:837-890](rtl/tg68k/TG68K_PMMU_030.vhd#L837-L890)) are consistent with the spec.

### CAL / VAL / SCC / AC — deliberately absent
[PMMU:113-114](rtl/tg68k/TG68K_PMMU_030.vhd#L113-L114): "defined in MC68030 but not implemented … removed as unused signals." No signal declarations; any PMOVE targeting a reg_sel outside the six encodings enters the `when others` arm at [PMMU:1189-1206](rtl/tg68k/TG68K_PMMU_030.vhd#L1189-L1206), which now (BUG #446) raises a sim `assert … severity error` and sets the sticky `pmmu_illegal_reg_sel_seen` latch exposed on port `debug_illegal_reg_sel`.

## 2. Access paths

### reg_sel → register map
`reg_sel` is `brief[14:10]` ([PMMU:17](rtl/tg68k/TG68K_PMMU_030.vhd#L17)). Verified via the write `case` at [PMMU:1061-1207](rtl/tg68k/TG68K_PMMU_030.vhd#L1061-L1207) and read mux at [PMMU:1226-1234](rtl/tg68k/TG68K_PMMU_030.vhd#L1226-L1234). **BUG #178** ([PMMU:1223-1225](rtl/tg68k/TG68K_PMMU_030.vhd#L1223-L1225)) explicitly calls out that these are the correct extension-word selectors:

| reg_sel | P-reg | Register |
|---|---|---|
| `00010` | 0x02 | TT0 |
| `00011` | 0x03 | TT1 |
| `10000` | 0x10 | TC |
| `10010` | 0x12 | SRP (with reg_part) |
| `10011` | 0x13 | CRP (with reg_part) |
| `11000` | 0x18 | MMUSR |
| any other | — | **observable + trapped** (BUG #446): sim assert + sticky `pmmu_illegal_reg_sel_seen` latch + vector-56 trap via `mmu_config_error`; read mux still returns `(others => '0')` |

### PMOVE vs MOVEC
The file header ([PMMU:100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L100-L106)) now correctly documents that all PMMU registers are **PMOVE-only in this tree**. The kernel's `movec1` whitelist is SFC/DFC/CACR/CAAR/USP/VBR/MSP/ISP only; MOVEC to any PMMU register traps as privilege violation. MC68030 spec lists TC/TT0/TT1/MMUSR as MOVEC-accessible, but that path is deliberately not wired here. (See [CPU_AUDIT.md §Instructions](CPU_AUDIT.md), which documents the kernel whitelist.)

### 64-bit CRP/SRP sequencing
Two PMOVE cycles per transfer, driven by kernel micro-states `pmove_mem_to_mmu_hi/lo` and `pmove_mmu_to_mem_hi/lo` ([Pack:35](rtl/tg68k/TG68K_Pack.vhd#L35)), plus `pmove_dn_hi/lo` for Dn operand ([Pack:36](rtl/tg68k/TG68K_Pack.vhd#L36)). Address auto-increment in memory modes via `pmmu_addr_inc`; the 64-bit flag is `pmmu_dbl` ([Pack:144-145](rtl/tg68k/TG68K_Pack.vhd#L144-L145)). **BUG #70** ([PMMU:181](rtl/tg68k/TG68K_PMMU_030.vhd#L181)) simplified Dn capture to two signals (`pmove_dn_mode`, `pmove_dn_regnum`). **BUG #53** ([PMMU:650](rtl/tg68k/TG68K_PMMU_030.vhd#L650)) retired a prior 2-stage pipeline in favor of single-stage brief capture.

## 3. PMMU instructions

### PMOVE (opcodes `pmmu_rd`, `pmmu_wr` — [Pack:131-132](rtl/tg68k/TG68K_Pack.vhd#L131-L132))
- Write: kernel asserts `reg_we`; PMMU handles the `case reg_sel` in the clocked process at [PMMU:1044](rtl/tg68k/TG68K_PMMU_030.vhd#L1044).
- Read: `reg_re` → combinational `reg_rdat` mux at [PMMU:1226](rtl/tg68k/TG68K_PMMU_030.vhd#L1226). **BUG #83** captures that the read path must be combinational — a prior registered version returned zero on the first read.
- PMOVEFD distinguishes itself via `reg_fd='1'`, which suppresses the `atc_flush_req` pulse (sites in the TT0/TT1/TC/SRP/CRP write arms).
- Register-write context bump (`xlat_cfg_seq`) fires on any of TT0/TT1/TC/SRP/CRP writes ([PMMU:1049-1054](rtl/tg68k/TG68K_PMMU_030.vhd#L1049-L1054)) so the translation pipeline can detect stale results.
- **BUG #446** illegal-reg_sel observability + hardware trap: the `when others` arm latches `pmmu_illegal_reg_sel_seen`, raises a sim `severity error`, **and** sets `mmu_config_error <= '1'` for both writes ([PMMU:1189-1207](rtl/tg68k/TG68K_PMMU_030.vhd#L1189-L1207)) and reads ([PMMU:1208-1219](rtl/tg68k/TG68K_PMMU_030.vhd#L1208-L1219)); the translate-off read-side assertion is at [PMMU:1242-1261](rtl/tg68k/TG68K_PMMU_030.vhd#L1242-L1261). The sticky flag is exposed on port `debug_illegal_reg_sel` ([PMMU:85-88, 1240](rtl/tg68k/TG68K_PMMU_030.vhd#L85-L88)); the vector-56 trap uses the existing `mmu_config_err`/`mmu_config_ack` handshake.

### PTEST ([Pack:133](rtl/tg68k/TG68K_Pack.vhd#L133); pmmu state `ptest1`)
- Brief fields: `brief[9]` = R/W (0=PTESTW, 1=PTESTR); `brief[12:10]` = level (BUG #413 [PMMU:271](rtl/tg68k/TG68K_PMMU_030.vhd#L271)).
- `ptest_level="000"` performs an ATC-only probe; non-zero walks up to that level (handled by the walker's level-capped termination).
- Handshake: `ptest_done` ([PMMU:267](rtl/tg68k/TG68K_PMMU_030.vhd#L267)) pulses from the translation process; the kernel-facing `ptest_active` clears on that pulse ([PMMU:1028-1031](rtl/tg68k/TG68K_PMMU_030.vhd#L1028-L1031)).
- `ptest_walk_pending` ([PMMU:276](rtl/tg68k/TG68K_PMMU_030.vhd#L276)) gates all MMUSR-updating sites in the walker: MMUSR is written for a PTEST walk but the ATC is not populated. **BUG #396** ([PMMU:272-275](rtl/tg68k/TG68K_PMMU_030.vhd#L272-L275)) extended this to keep `instr_walk_pending` asserted through the whole walk so `addr_phys_reg` isn't clobbered.
- `ptest_desc_addr` port exposes the physical address of the last descriptor visited ([PMMU:59](rtl/tg68k/TG68K_PMMU_030.vhd#L59)) for software that wants to fetch the A-bit.

### PLOAD ([Pack:135](rtl/tg68k/TG68K_Pack.vhd#L135); pmmu state `pload1`)
- Brief fields: `brief[9]` = R/W (0=PLOADW, 1=PLOADR).
- `pload_flush_pending` ([PMMU:283](rtl/tg68k/TG68K_PMMU_030.vhd#L283)) enters walker state `W_PLOAD_FLUSH` before `W_FILL` so any existing ATC entry for the same page is invalidated before the new entry is written.
- PLOAD does **not** update MMUSR (the write sites are guarded on `ptest_walk_pending='1'`).

### PFLUSH ([Pack:134](rtl/tg68k/TG68K_Pack.vhd#L134); pmmu state `pflush1`)
Brief fields: `pflush_mode <= brief[12:8]`, `pflush_mask <= brief[7:5]`. The flush dispatch lives around [PMMU:3952-4006](rtl/tg68k/TG68K_PMMU_030.vhd#L3952-L4006):

| Mode | Variant | Behavior |
|---|---|---|
| `001`, A=0 | PFLUSHA | Clear all ATC entries ([PMMU:3952](rtl/tg68k/TG68K_PMMU_030.vhd#L3952)) |
| `001`, A=1 | PFLUSHAN | Clear non-global entries only (keep `atc_global(i)='1'`) ([PMMU:3960](rtl/tg68k/TG68K_PMMU_030.vhd#L3960)) |
| `100` | PFLUSH FC,MASK | Match FC via `((atc_fc(i) xor pflush_fc) and pflush_mask) = "000"` ([PMMU:3971-3988](rtl/tg68k/TG68K_PMMU_030.vhd#L3971-L3988)) |
| `110` | PFLUSH FC,MASK,〈ea〉 | FC match + page-aligned address match ([PMMU:3990-4006](rtl/tg68k/TG68K_PMMU_030.vhd#L3990-L4006)) |

PFLUSHR (read a translation), PFLUSHS (not per spec on 68030), and PFLUSHN with level are not decoded.

## 4. Translation pipeline

### Layers (in priority order)
1. **Combinational TTR bypass** ([PMMU:946-965](rtl/tg68k/TG68K_PMMU_030.vhd#L946-L965)). `ttr0_match_comb`, `ttr1_match_comb`, `ttr0_ci_comb/wp_comb`, `ttr1_ci_comb/wp_comb` are driven by a process sensitive to TT0/TT1/addr_log/fc/is_insn/rw. **BUG #371** ([PMMU:136-143](rtl/tg68k/TG68K_PMMU_030.vhd#L136-L143)) motivates this: when E first flips to 1, `addr_phys_reg` holds stale identity bits; TTR identity bypass routes the log address combinationally at [PMMU:1327-1330](rtl/tg68k/TG68K_PMMU_030.vhd#L1327-L1330).
2. **ATC lookup** ([PMMU:1530-1563](rtl/tg68k/TG68K_PMMU_030.vhd#L1530-L1563)). Linear scan over 22 entries; hit when `atc_valid AND fc matches AND align_addr(addr_log, shift) == atc_log_base`. **BUG #415** ([PMMU:1531](rtl/tg68k/TG68K_PMMU_030.vhd#L1531)) gates the lookup during the 1-cycle `atc_flush_req` pulse.
3. **Walker invocation** on miss (see §5).

### Staleness-window protection
- `addr_phys_reg` is registered; the combinational `addr_log` can change on the same edge that updates it. **BUG #416** ([PMMU:144-157, 4039](rtl/tg68k/TG68K_PMMU_030.vhd#L144-L157)) maintains `translated_addr`, `translated_fc`, `translated_rw`, `translated_cfg_seq`. `busy` stays HIGH while any of these disagree with the current combinational request, suppressing bus access until the next edge realigns them.
- `xlat_cfg_seq` increments on every TC/CRP/SRP/TT0/TT1 write ([PMMU:1043](rtl/tg68k/TG68K_PMMU_030.vhd#L1043)) so a post-PMOVE translation cannot reuse a pre-PMOVE result.

### Translation result latches ([PMMU:159-167](rtl/tg68k/TG68K_PMMU_030.vhd#L159-L167))
`addr_phys_reg`, `cache_inhibit_reg`, `write_protect_reg`, `fault_reg`, `fault_status_reg`, `fault_addr_reg`, `fault_fc_reg`, `fault_rw_reg`, `fault_is_insn_reg`. **BUG #414/#415** names the latches for the fault context that downstream exception code needs.

### "busy" semantics
`busy` is HIGH whenever the translation result is not yet trustworthy for the currently-presented logical address. Drivers ([PMMU:4030-4048](rtl/tg68k/TG68K_PMMU_030.vhd#L4030-L4048)):
- `req='1'` and ATC miss and walker active;
- translated-context mismatch;
- 1-cycle `atc_flush_req` window;
- MMU config error (blocks translation until software ack, [PMMU:55-57](rtl/tg68k/TG68K_PMMU_030.vhd#L55-L57));
- **BUG #428** ([PMMU:4048](rtl/tg68k/TG68K_PMMU_030.vhd#L4048)) — when `fault_reg='1'` translation is considered "done" (faulted) and `busy` drops so the kernel can take the exception.

## 5. Walker FSM

State enum `walk_state_t` at [PMMU:243](rtl/tg68k/TG68K_PMMU_030.vhd#L243) — 20 states. State register `wstate` ([PMMU:244](rtl/tg68k/TG68K_PMMU_030.vhd#L244)). Debugged via `debug_wstate` ([PMMU:1208](rtl/tg68k/TG68K_PMMU_030.vhd#L1208)).

| State | Purpose | Bus op | Exit |
|---|---|---|---|
| `W_IDLE` | Idle; validate CRP/SRP DT on `walk_req`. Invalid root DT → W_FAULT | — | W_ROOT or W_FAULT |
| `W_ROOT` ([PMMU:2359](rtl/tg68k/TG68K_PMMU_030.vhd#L2359)) | Read root/level-0 descriptor (HIGH word) | `mem_req=1`, `mem_addr=root_table+index*stride` | W_ROOT_LOW / W_PTR1 / W_PAGE / W_FAULT |
| `W_ROOT_LOW` ([PMMU:2540](rtl/tg68k/TG68K_PMMU_030.vhd#L2540)) | Long-format LOW word | `mem_req=1`, `+4` | W_PTR1 / W_FAULT |
| `W_PTR1..4` (+ `_LOW`) ([PMMU:2613,2770,…,3300-3395](rtl/tg68k/TG68K_PMMU_030.vhd#L2613)) | Levels 1–4 walks. Level 4 only reachable with FCL=1 | `mem_req=1`, stride per parent DT | Next level / W_PAGE / W_TABLE_UPDATE / W_FAULT |
| `W_INDIRECT`, `W_INDIRECT_LOW` ([PMMU:3428,3497](rtl/tg68k/TG68K_PMMU_030.vhd#L3428)) | DT=11 indirect chase (BUG #164 added LOW variant [PMMU:241](rtl/tg68k/TG68K_PMMU_030.vhd#L241)) | `mem_req=1` | W_PAGE / W_FAULT |
| `W_PAGE` ([PMMU:3521](rtl/tg68k/TG68K_PMMU_030.vhd#L3521)) | Page descriptor resolved; validate access, extract attrs | — | W_TABLE_UPDATE / W_UPDATE_DESC / W_PLOAD_FLUSH / W_FILL / W_FAULT |
| `W_TABLE_UPDATE` ([PMMU:3694](rtl/tg68k/TG68K_PMMU_030.vhd#L3694)) | Write U-bit back into a table descriptor | `mem_req=1, mem_we=1, mem_wdat=desc_update_data` | `walk_next_state` or W_FAULT |
| `W_UPDATE_DESC` ([PMMU:3734](rtl/tg68k/TG68K_PMMU_030.vhd#L3734)) | Write U (and optionally M) back into page descriptor | `mem_req=1, mem_we=1` | W_FILL / W_PLOAD_FLUSH / W_FAULT |
| `W_PLOAD_FLUSH` ([PMMU:3778](rtl/tg68k/TG68K_PMMU_030.vhd#L3778)) | PLOAD: invalidate existing ATC entry for this page | — | W_FILL |
| `W_FILL` ([PMMU:3791](rtl/tg68k/TG68K_PMMU_030.vhd#L3791)) | Populate ATC entry; pseudo-LRU replace | — | W_COMPLETE |
| `W_COMPLETE` ([PMMU:3844](rtl/tg68k/TG68K_PMMU_030.vhd#L3844)) | Raise `walker_completed`; result visible | — | W_IDLE |
| `W_FAULT` ([PMMU:3859](rtl/tg68k/TG68K_PMMU_030.vhd#L3859)) | Cache fault in ATC (unless PTEST) and raise `walker_fault` | — | W_IDLE |

### Stride selection
**BUG #409** ([PMMU:304, 2295, 2328, 2419, 2618, 2852, 3093, 3305](rtl/tg68k/TG68K_PMMU_030.vhd#L304)): the _parent_ DT field decides entry stride for the current level — DT=10 ⇒ 4-byte entries, DT=11 ⇒ 8-byte (with a LOW word). `walk_parent_dt_long` carries this between levels.

### FCL=0 vs FCL=1
- FCL=0: up to 4 table levels (TIA→TIB→TIC→TID) before the page descriptor.
- FCL=1: a synthetic function-code level precedes them → up to 5 levels, hence `W_PTR4`/`W_PTR4_LOW`.
- Index extraction helper: `get_fcl_table_index()` ([PMMU:672](rtl/tg68k/TG68K_PMMU_030.vhd#L672)).

### Watchdog
**BUG #387** ([PMMU:305-307](rtl/tg68k/TG68K_PMMU_030.vhd#L305-L307)). `walker_timeout_counter` (0..1023) with `WALKER_TIMEOUT_CYCLES = 500` aborts a walk if `mem_ack` never arrives. Prevents CPU deadlock when the arbiter in [cpu_wrapper.v](rtl/cpu_wrapper.v) drops a walker request.

### Early termination
Handled within `W_ROOT` and `W_PTR*` when the fetched descriptor has `DT=01` (page descriptor). `calc_effective_page_shift()` ([PMMU:896-938](rtl/tg68k/TG68K_PMMU_030.vhd#L896-L938)) sums the unused TI fields into the shift so the ATC entry covers a super-page.

### Descriptor bookkeeping
`ptr1_desc_addr_reg`/`ptr1_desc_data_reg` through level 3 ([PMMU:297-302](rtl/tg68k/TG68K_PMMU_030.vhd#L297-L302)) capture every descriptor read during a walk. Exposed via `debug_ptr*_*` ports ([PMMU:1219-1224](rtl/tg68k/TG68K_PMMU_030.vhd#L1219-L1224)) for SignalTap/fault forensics; kernel does not read them.

## 6. ATC

### Geometry
- `ATC_ENTRIES = 22` ([PMMU:191](rtl/tg68k/TG68K_PMMU_030.vhd#L191)). The header comment at [PMMU:3](rtl/tg68k/TG68K_PMMU_030.vhd#L3) now correctly says "22-entry ATC".
- Per-entry storage ([PMMU:192-215](rtl/tg68k/TG68K_PMMU_030.vhd#L192-L215)):

| Array | Purpose |
|---|---|
| `atc_log_base[22]` | Page-aligned logical address |
| `atc_phys_base[22]` | Page-aligned physical address |
| `atc_attr[22]` (4 bits) | `{U_ACC, CI, M, WP}` where `U_ACC = NOT(S)` |
| `atc_fc[22]` (3 bits) | Function code |
| `atc_shift[22]` (0..32) | Effective page shift (may exceed TC.PS) |
| `atc_page_size[22]` (0..15) | Original TC.PS value at fill |
| `atc_level[22]` (3 bits) | Walk depth for MMUSR N field (BUG #412) |
| `atc_global[22]` | G bit — survives PFLUSHAN |
| `atc_valid[22]` | Valid flag |
| `atc_buserr[22]` | Cached-fault marker |
| `atc_fault_status[22]` (16 bits) | Cached MMUSR value for sticky faults |
| `atc_mru[22]` | Pseudo-LRU history bit |

### Lookup
[PMMU:1530-1589](rtl/tg68k/TG68K_PMMU_030.vhd#L1530-L1589). `align_addr(addr_log, atc_shift(i))` at [PMMU:403](rtl/tg68k/TG68K_PMMU_030.vhd#L403) page-aligns per-entry. On hit, `atc_mru_update_req` pulses to mark MRU. On _write_ hit, **BUG #410** ([PMMU:1547-1560](rtl/tg68k/TG68K_PMMU_030.vhd#L1547-L1560)) invalidates entries with M=0 AND WP=0 so the next walk sets M (per WinUAE `cpummu30.cpp:2086`).

### Replacement
Pseudo-LRU ([PMMU:3803-3839, 3908-3923](rtl/tg68k/TG68K_PMMU_030.vhd#L3803-L3839)): pick the first invalid entry, else first entry with `atc_mru=0`; when all MRU bits are set, reset all except the current entry.

### Sticky faults
`W_FAULT` ([PMMU:3859-3901](rtl/tg68k/TG68K_PMMU_030.vhd#L3859-L3901)) caches the faulting translation with `atc_buserr=1` and fault class in `atc_fault_status`. ATC-hit logic replays the cached fault without re-walking. Cleared on any successful walk ([PMMU:3822](rtl/tg68k/TG68K_PMMU_030.vhd#L3822)) — **BUG #436**.

### Invalidation flows
- `atc_flush_req` pulse — 1-cycle, drives `atc_valid(i) <= '0'` for the matching subset in the main process.
- Direct clears in PFLUSH* variants (see §3).
- `atc_mbit_inval_req` / `atc_mbit_inval_idx` ([PMMU:218-219](rtl/tg68k/TG68K_PMMU_030.vhd#L218-L219)) — targeted invalidation for the BUG #410 write-hit case.

## 7. Fault handling

### Sources and MMUSR bit effects

| Source | Detected at | MMUSR bits set |
|---|---|---|
| Invalid root pointer DT=00 | W_IDLE ([PMMU:2299-2343](rtl/tg68k/TG68K_PMMU_030.vhd#L2299-L2343)) and register write ([PMMU:1127,1155](rtl/tg68k/TG68K_PMMU_030.vhd#L1127)) | `mmu_config_error` (vector 56, not MMUSR) |
| Invalid descriptor (DT=00 mid-walk) | W_ROOT/W_PTR*/W_PAGE | I |
| Limit violation | W_ROOT/W_PTR* bounds check ([PMMU:2375-2416](rtl/tg68k/TG68K_PMMU_030.vhd#L2375-L2416)) | L, I |
| Supervisor violation | W_PAGE ([PMMU:3541-3556](rtl/tg68k/TG68K_PMMU_030.vhd#L3541-L3556)) | S |
| Write-protect violation | W_PAGE accumulates WP across levels (BUG #438) | W |
| External BERR during walk | `mem_berr='1'` at any descriptor fetch; enters W_FAULT ([PMMU:2438, 2548+](rtl/tg68k/TG68K_PMMU_030.vhd#L2438)) | B (per BUG #153 [PMMU:2478](rtl/tg68k/TG68K_PMMU_030.vhd#L2478), **only** external BERR sets B) |
| Walker timeout | `walker_timeout_counter >= 500` (BUG #387) | B |
| Illegal TC (PS<8 or field-sum≠32) | Register write ([PMMU:1087-1104](rtl/tg68k/TG68K_PMMU_030.vhd#L1087-L1104)) | `mmu_config_error` (vector 56) |
| Illegal PMOVE reg_sel (BUG #446) | Write or read with undecoded `brief[14:10]` ([PMMU:1189-1219](rtl/tg68k/TG68K_PMMU_030.vhd#L1189-L1219)) | `mmu_config_error` (vector 56) + sticky `pmmu_illegal_reg_sel_seen` |

### Fault context latching (BUG #414/#415)
On fault entry, these latch exactly once ([PMMU:164-167, 1614-1617, 1651-1654, and other walker fault sites](rtl/tg68k/TG68K_PMMU_030.vhd#L164-L167)):
- `fault_addr_reg` — faulting logical address (port `fault_addr` ([PMMU:41](rtl/tg68k/TG68K_PMMU_030.vhd#L41))).
- `fault_fc_reg`, `fault_rw_reg`, `fault_is_insn_reg` — context at fault (ports [PMMU:42-44](rtl/tg68k/TG68K_PMMU_030.vhd#L42-L44)).

These feed the kernel's exception-frame builder, which selects Format $B (long, all reads) vs Format $A (short, mid-instruction writes) — see [CPU_AUDIT.md](CPU_AUDIT.md) for the kernel-side stacking sites.

### Vector routing
- **Vector 2** (Access Fault): normal translation faults. Kernel latches `berr_external_rw/fc` at first BERR fire (BUG #431/#433b/#434); note **BUG #435** ([PMMU:2385](rtl/tg68k/TG68K_PMMU_030.vhd#L2385)) emits vector 2 for internal PMMU BERRs too — the differentiation is Format $A vs $B, not the vector number.
- **Vector 56** (MMU Configuration Error): `mmu_config_err` port ([PMMU:55-57](rtl/tg68k/TG68K_PMMU_030.vhd#L55-L57)) with `mmu_config_ack` handshake. Raised on illegal TC.PS, TC field-sum mismatch, and CRP/SRP HIGH write with DT=00. Register is still loaded before the trap.
- **BUG #445 sticky latch semantics**: `mmu_config_error` is cleared only by `mmu_config_ack` or async reset — a subsequent valid TC/CRP/SRP write does **not** silently clear it. The kernel acknowledges via `pmmu_config_ack` on the first cycle of `trap_mmu_config` ([TG68KdotC_Kernel.vhd:5971-5975](rtl/tg68k/TG68KdotC_Kernel.vhd#L5971-L5975)). MMU translation stays disabled (`tc_en` clamps to 0) until the ack clears the latch, guaranteeing one trap per illegal config.

## 8. Descriptors and U/M writeback

### Root pointer DT (bits 1:0 of CRP_H / SRP_H)
- `00`: invalid → config error on write, walk fault if reached.
- `01`: root-level page descriptor (early termination, no walk). `walk_is_root_pointer` ([PMMU:315](rtl/tg68k/TG68K_PMMU_030.vhd#L315)) skips S/WP/U/M checks for this case.
- `10`: short-format table (4-byte entries).
- `11`: long-format table (8-byte entries); also enables indirect interpretation.

### Table descriptor — short format (32 bits)
```
[31:8] = next-table base address (aligned)
[7:4]  = reserved
[3]    = U (Used)
[2]    = WP (Write Protect, accumulates)
[1:0]  = DT (=10 table, =01 page, =11 long)
```
No limit field (**BUG #155** [PMMU:318-321](rtl/tg68k/TG68K_PMMU_030.vhd#L318-L321); `walk_limit_valid='0'` for short tables).

### Table descriptor — long format (64 bits, HIGH word)
```
[31]    = L/U — 1=lower-limit check (idx ≥ LIMIT), 0=upper-limit (idx ≤ LIMIT)
[30:16] = LIMIT (15 bits)
[15:11] = reserved
[10]    = G (Global)
[8]     = S (supervisor-only, cumulative with parent — BUG #157 [PMMU:313])
[6]     = CI (Cache Inhibit)
[4]     = M (Modified)
[3]     = U (Used)
[2]     = WP (Write Protect, accumulates — BUG #438)
[1:0]   = DT
[63:32] = LOW word — next-table base
```

### Page descriptor (short and long)
Short: `[31:8]` physical base, `[3]` U, `[2]` WP, `[1:0]=01`.
Long HIGH: adds L/U + LIMIT (for early-termination limit), G, S, CI, M, U, WP, DT=01; LOW is the physical base.

### Indirect descriptor
When a HIGH word has DT=11 but is intended as a redirect, bits `[31:4]` point at another descriptor. `W_INDIRECT`/`W_INDIRECT_LOW` fetch and interpret it. **BUG #164** ([PMMU:241, 317](rtl/tg68k/TG68K_PMMU_030.vhd#L241)) added `indirect_target_long` so a long-format target is handled correctly.

### Limit checking
- `walk_limit_valid`, `walk_limit_lu`, `walk_limit_value` ([PMMU:321-326](rtl/tg68k/TG68K_PMMU_030.vhd#L321-L326)).
- Comparison done at the start of the _next_ level's index computation.
- Out-of-range index → W_FAULT with L=1, I=1.

### U / M writeback
- **W_TABLE_UPDATE**: sets U=1 on a table descriptor that was previously U=0. Skipped if `ptest_walk_no_update='1'` ([PMMU:277](rtl/tg68k/TG68K_PMMU_030.vhd#L277)). On completion resumes at `walk_next_state`.
- **W_UPDATE_DESC**: sets U=1 and (for writes) M=1 on a page descriptor. **BUG #437** ([PMMU:3557, 3664](rtl/tg68k/TG68K_PMMU_030.vhd#L3557)): M may only be written when `rw=0` AND page WP=0 AND accumulated table WP=0 AND not a PTEST/PLOAD walk. Writes to a WP page still _complete_ the walk and seed the ATC with WP=1 so the next translation takes a clean vector-2 fault rather than aborting mid-writeback.

### WP accumulation (BUG #438)
Across every descriptor level the walker ORs descriptor bit 2 into `walk_write_protect` ([PMMU:314, 2515, 2531, 2605, 2745, 2765, 2839, 2986, 3006, 3080, 3199, 3218, 3305](rtl/tg68k/TG68K_PMMU_030.vhd#L2515)); page-level WP is OR'd at W_PAGE ([PMMU:3622](rtl/tg68k/TG68K_PMMU_030.vhd#L3622)). Final MMUSR.W reflects the union.

## 9. Top-numbered `BUG #` entries (PMMU, abridged)

| # | Lines | One-liner |
|---|---|---|
| 446 | [85-88, 245-246, 1003, 1189-1216, 1237, 1239-1258](rtl/tg68k/TG68K_PMMU_030.vhd#L85-L88) | Illegal PMOVE reg_sel: sim assert + sticky latch + debug port |
| 445 | [1094-1099, 1138-1141, 1164-1168](rtl/tg68k/TG68K_PMMU_030.vhd#L1094-L1099) | `mmu_config_error` is sticky — only `mmu_config_ack`/reset clears it |
| 438 | [2515, 2531, 2745, 2765, 2986, 3006, 3199, 3218, 3305](rtl/tg68k/TG68K_PMMU_030.vhd#L2515) | WP OR-accumulates across all descriptor levels |
| 437 | [3557, 3664](rtl/tg68k/TG68K_PMMU_030.vhd#L3557) | M-bit writeback requires WP=0 (WinUAE parity) |
| 436 | [214, 3822](rtl/tg68k/TG68K_PMMU_030.vhd#L3822) | Clear sticky-fault ATC flag on successful walk |
| 435 | [2385](rtl/tg68k/TG68K_PMMU_030.vhd#L2385) | Internal PMMU berr uses vector 2 (not differentiated from external) |
| 428 | [4048](rtl/tg68k/TG68K_PMMU_030.vhd#L4048) | `fault_reg='1'` ⇒ translation considered done, drop busy |
| 421 | [4030](rtl/tg68k/TG68K_PMMU_030.vhd#L4030) | TTR check must use actual RW; catches RWM=0 writes |
| 416 | [144-157, 4039](rtl/tg68k/TG68K_PMMU_030.vhd#L144-L157) | Stale `addr_phys_reg` window; gate with `busy` |
| 415 | [41, 164, 1349, 1531, 1614, 2000, 2037](rtl/tg68k/TG68K_PMMU_030.vhd#L41) | Latch faulting logical address; skip ATC during flush window |
| 414 | [42-44, 165-167, 1350-1352, 1615-1617, 2001-2003, 2038-2040](rtl/tg68k/TG68K_PMMU_030.vhd#L42-L44) | Latch FC/RW/insn-flag at fault time |
| 413 | [271, 4079, 4097](rtl/tg68k/TG68K_PMMU_030.vhd#L271) | PTEST level from `brief[12:10]` |
| 412 | [201, 212, 1610, 1707, 2079, 2167](rtl/tg68k/TG68K_PMMU_030.vhd#L201) | Walk level captured in ATC for MMUSR N field |
| 410 | [1547-1560](rtl/tg68k/TG68K_PMMU_030.vhd#L1547-L1560) | Write-hit with M=0, WP=0 ⇒ invalidate ATC entry |
| 409 | [304, 2295, 2328, 2419, 2618, 2852, 3093, 3305](rtl/tg68k/TG68K_PMMU_030.vhd#L304) | Parent DT determines child stride (4 vs 8 bytes) |
| 408 | [96-105](rtl/cpu_wrapper.v) | Suppress CPU ramsel when walker active (wrapper-side) |
| 396 | [272-275, 3033](rtl/tg68k/TG68K_PMMU_030.vhd#L272-L275) | PTEST/PLOAD walks must not update `addr_phys_reg`/ATC |
| 387 | [305-307, 2210](rtl/tg68k/TG68K_PMMU_030.vhd#L305-L307) | 500-cycle walker watchdog |
| 371 | [136-143](rtl/tg68k/TG68K_PMMU_030.vhd#L136-L143) | TTR combinational bypass avoids stale `addr_phys_reg` at MMU-enable |
| 178 | [1187-1189](rtl/tg68k/TG68K_PMMU_030.vhd#L1187-L1189) | Correct extension-word P-register selectors |
| 164 | [241, 317, 3497](rtl/tg68k/TG68K_PMMU_030.vhd#L241) | Added `W_INDIRECT_LOW` for long-format indirect targets |
| 157 | [313](rtl/tg68k/TG68K_PMMU_030.vhd#L313) | Cumulative S bit from table descriptors |
| 155 | [318-321](rtl/tg68k/TG68K_PMMU_030.vhd#L318-L321) | Short-format tables have no limit field |
| 153 | [2478](rtl/tg68k/TG68K_PMMU_030.vhd#L2478) | MMUSR.B set only by external BERR, not internal faults |
| 83  | [1183-1186](rtl/tg68k/TG68K_PMMU_030.vhd#L1183-L1186) | PMOVE register read must be combinational |
| 70  | [181](rtl/tg68k/TG68K_PMMU_030.vhd#L181) | Simplified Dn capture via 2 signals |
| 53  | [650](rtl/tg68k/TG68K_PMMU_030.vhd#L650) | Retired 2-stage PMOVE capture pipeline |
| 16  | [262-264](rtl/tg68k/TG68K_PMMU_030.vhd#L262-L264) | Edge detection for PMOVE reg access |
| 12  | [1033-1036](rtl/tg68k/TG68K_PMMU_030.vhd#L1033-L1036) | Register writes must be parallel with MMUSR updates |

## 10. Integration with cpu_wrapper.v

`cpu_wrapper.v` (2196 lines, ~73 `BUG #` comments) is the real Minimig 68030 integration layer. The PMMU itself is inside [TG68KdotC_Kernel.vhd](rtl/tg68k/TG68KdotC_Kernel.vhd) (which instantiates [TG68K_PMMU_030.vhd](rtl/tg68k/TG68K_PMMU_030.vhd)); the wrapper owns everything around it — bus arbitration, walker memory access, fault routing, cache coordination, and the physical-address decode fabric. The standalone [TG68K.vhd](rtl/tg68k/TG68K.vhd) wrapper ties these walker ports off (`pmmu_walker_* => open/'0'`) and is **not** the integration path; no maintained bench wraps this layer.

### 10.1 PMMU / walker wire inventory
Declared in [cpu_wrapper.v:385-445](rtl/cpu_wrapper.v#L385-L445):

| Wire/reg | Width | Direction | Purpose |
|---|---|---|---|
| `pmmu_addr_log_p` | 32 | kernel→wrapper | logical address (cache indexing) |
| `pmmu_addr_phys_p` | 32 | kernel→wrapper | translated/identity address — drives all bus decode |
| `pmmu_cache_inhibit_p` | 1 | kernel→wrapper | BUG #126 — CI per page/TTR |
| `pmmu_walker_req_p` | 1 | kernel→wrapper | walker needs a descriptor fetch/update |
| `pmmu_walker_we_p` | 1 | kernel→wrapper | U/M writeback |
| `pmmu_walker_addr_p` | 32 | kernel→wrapper | descriptor address |
| `pmmu_walker_wdat_p` | 32 | kernel→wrapper | descriptor write data |
| `pmmu_walker_ack_p` | 1 | wrapper→kernel | one transfer done |
| `pmmu_walker_data_p` | 32 | wrapper→kernel | descriptor returned |
| `pmmu_walker_berr_p` | 1 | wrapper→kernel | BUG #156 — walk bus-error (sets MMUSR.B) |
| `pmmu_busy_p` | 1 | kernel→wrapper | BUG #407 — translation pending |
| `pmmu_fault_p` | 1 | kernel→wrapper | translation fault (drops busy so kernel exception can advance) |

SignalTap copies are in the `stp_pmmu_*` set ([cpu_wrapper.v:458-477](rtl/cpu_wrapper.v#L458-L477)) with `(* noprune, preserve *)` to keep them alive through synthesis.

### 10.2 Walker memory arbiter — FSM
Implemented inside `generate if (USE_68030_CACHE)` around [cpu_wrapper.v:1352-1862](rtl/cpu_wrapper.v#L1352-L1862). 12 states encoded in `walker_state[3:0]`:

| # | State | Role | Bus ops |
|---|---|---|---|
| 0 | `WALKER_IDLE` | wait for `pmmu_walker_req_p` | — |
| 1 | `WALKER_START` | latch descriptor address, assert `walker_active` | — |
| 2 | `WALKER_READ_LOW` | drive low-word address (A1=0) | `chip_*` or `ram*` |
| 3 | `WALKER_WAIT_LOW` | wait for ready/berr/timeout | poll |
| 4 | `WALKER_READ_HIGH` | drive high-word address (A1=1) | `chip_*` or `ram*` |
| 5 | `WALKER_WAIT_HIGH` | wait for second ready | poll |
| 6 | `WALKER_DONE` | pulse ack/berr, release bus | — |
| 7 | `WALKER_WRITE_LOW` | U/M-bit writeback low half | write |
| 8 | `WALKER_WAIT_WR_LOW` | wait write ready | poll |
| 9 | `WALKER_WRITE_HIGH` | U/M-bit writeback high half | write |
| 10 | `WALKER_WAIT_WR_HIGH` | wait write ready | poll |
| 11 | `WALKER_RAM_GAP` | one-cycle gap so SDRAM's `cpu_cs` clears — BUG #439 | `walker_fast_ram=0` |

Phase encoding ([cpu_wrapper.v:196-201](rtl/cpu_wrapper.v#L196-L201)): low-phase for states 2/3 (read) or 7/8 (write); `walker_addr_word = {walker_addr_latch[31:2], walker_low_phase ? 1'b0 : 1'b1}`. **BUG #405** ([cpu_wrapper.v:149, 317, 1748](rtl/cpu_wrapper.v#L149)) — big-endian 32-bit descriptor assembly (low address = high word).

### 10.3 Walker routes: chip RAM, Fast RAM (Z2/Z3), SDRAM/DDR3

**Chip RAM ($000000–$1FFFFF)** — [cpu_wrapper.v:1950-1969](rtl/cpu_wrapper.v#L1950-L1969):
- Detection: `walker_addr_is_chipram = !walker_addr_latch[31:21]`.
- `walker_chip_ram = USE_68030_CACHE & (walker_reading | walker_writing) & walker_addr_is_chipram` ([cpu_wrapper.v:1962](rtl/cpu_wrapper.v#L1962)).
- OR'd into `chipreq` ([cpu_wrapper.v:1969](rtl/cpu_wrapper.v#L1969)).
- Chip address mux: [cpu_wrapper.v:1590-1592](rtl/cpu_wrapper.v#L1590-L1592) — low/high word select via `walker_low_phase`.
- Chip-bus AS cycling owned by chip SM via `c_as` — BUG #423 ([cpu_wrapper.v:296, 312](rtl/cpu_wrapper.v#L296)).
- Stale-`chipready` guard: waits for `chip_stage==0` — BUG #422 read-side ([cpu_wrapper.v:1665-1667, 1788-1790](rtl/cpu_wrapper.v#L1665-L1667)).
- Data strobes: walker holds both `chip_lds`/`chip_uds` active for 16-bit transfers, assembled into the 32-bit descriptor.

**Z2/Z3 Fast RAM** — [cpu_wrapper.v:204-225](rtl/cpu_wrapper.v#L204-L225):
- Zorro decodes (`sel_z3ram0_walker`, `sel_z3ram1_walker`, `sel_z2ram_walker`) run on `walker_addr_word[31:1]` — not the CPU path. Combined as `sel_zram_walker`.
- `walker_fast_ram = USE_68030_CACHE && walker_active && sel_zram_walker && (walker_state != 4'd11)` ([cpu_wrapper.v:217-218](rtl/cpu_wrapper.v#L217-L218)) — BUG #192 (use `walker_active` for clean handoff) + BUG #439 (deassert during `WALKER_RAM_GAP`).
- Fast RAM data strobes forced active: `ramlds = walker_fast_ram ? 1'b0 : …` / `ramuds = …` — BUG #137 ([cpu_wrapper.v:147-148](rtl/cpu_wrapper.v#L147-L148)).
- Write-data mux: `ramdin = (walker_fast_ram && walker_writing) ? (low? wdat[31:16] : wdat[15:0]) : …` ([cpu_wrapper.v:150](rtl/cpu_wrapper.v#L150)).
- `ramaddr[28:1]` walker override when `walker_fast_ram` ([cpu_wrapper.v:169-175](rtl/cpu_wrapper.v#L169-L175)) reuses the CPU's encoder logic but on `walker_ramaddr` ([cpu_wrapper.v:222-225](rtl/cpu_wrapper.v#L222-L225)) — BUG #136 / BUG #128.
- `ramsel = (cpu_req & …) | walker_fast_ram` ([cpu_wrapper.v:106](rtl/cpu_wrapper.v#L106)).

**SDRAM/DDR3 stale-ready protection** — [cpu_wrapper.v:1542-1550, 1668-1670, 1713-1722](rtl/cpu_wrapper.v#L1542-L1550):
- `stale_ram_pending` latches that a CPU SDRAM access is still in flight; walker refuses to consume `ramready` until it clears — BUG #422.
- `WALKER_RAM_GAP` (state 11) is inserted between low and high reads specifically so the SDRAM cache sees `walker_fast_ram=0` for one cycle and drops `cpu_cs`, preventing a stale ready from being latched by the high-word read — BUG #439.

**Chip-bus output mux** — [cpu_wrapper.v:293-336](rtl/cpu_wrapper.v#L293-L336): when `walker_chip_ram && walker_reading`, `chip_addr_req = walker_chip_addr`; when writing, also drives `chip_din_req = walker_wdata_latch[31:16]` or `[15:0]` by phase. Otherwise uses `pmmu_addr_phys_p[23:1]`.

**CPU data-in mux** — [cpu_wrapper.v:263-266](rtl/cpu_wrapper.v#L263-L266): `cpu_din = (USE_68030_CACHE & cache_hit & ~walker_active) ? cache_data_out_16 : walker_chip_ram ? chip_data : …` — walker chip-RAM descriptor is explicitly excluded from cache-hit substitution.

### 10.4 Wrapper-level watchdog (separate from PMMU's 500-cycle one)

[cpu_wrapper.v:1521-1531, 1642-1710, 1776-1850](rtl/cpu_wrapper.v#L1521-L1531):
- 12-bit `walker_timeout_cnt`, limit `WALKER_TIMEOUT_LIMIT = 2048` cycles (~18µs @ 114MHz).
- Counter increments in every read/write wait state and is **not** reset per successful ready — BUG #424 ([cpu_wrapper.v:1642, 1651, 1776](rtl/cpu_wrapper.v#L1642)) — so a truly stuck memory eventually escapes rather than counter-resetting forever.
- On expiry: `walker_timeout_error <= 1`, `pmmu_walker_berr_p <= 1`, data returned as zero, transitions to `WALKER_DONE` ([cpu_wrapper.v:1653-1656, 1689-1692, 1740-1743](rtl/cpu_wrapper.v#L1653-L1656)).
- **PMMU-internal timeout detection** — BUG #419 ([cpu_wrapper.v:1647, 1675-1681, 1733, 1798, 1829](rtl/cpu_wrapper.v#L1647)): if `pmmu_walker_req_p` drops mid-walk (PMMU's own 500-cycle watchdog fired), wrapper aborts the current bus transaction and races straight to `WALKER_DONE` so the kernel can write its bus-error frame without the wrapper timeout stalling it again.
- Recovery gating — BUG #139 ([cpu_wrapper.v:1170-1179](rtl/cpu_wrapper.v#L1170-L1179)): `clkena_in` includes `walker_timeout_error | ~reset` so CPU clock is unblocked even if the usual `pmmu_busy_p` stall term is still asserted.

### 10.5 Bus suppression, clock gating, DTACK qualification
- `pmmu_suppress_bus = cpucfg[1] & (pmmu_busy_p | pmmu_fault_p | walker_timeout_error)` ([cpu_wrapper.v:105](rtl/cpu_wrapper.v#L105)).
- `ramsel` and `chipreq` are gated by `~pmmu_suppress_bus` and `~walker_active` ([cpu_wrapper.v:106, 1969](rtl/cpu_wrapper.v#L106)) — i.e. CPU bus requests are suppressed either when MMU is translating/faulting/timed-out **or** when the walker currently owns the bus.
- `clkena_in` ([cpu_wrapper.v:1179](rtl/cpu_wrapper.v#L1179)) combines the usual CPU ready + `(~pmmu_busy_p | pmmu_fault_p | walker_timeout_error | ~reset)` so the kernel is held on ATC miss but advances the instant a fault or timeout fires. Fault specifically **bypasses** the busy stall so the exception can be dispatched.
- `cpu_ready_qualified = (ramsel & ramready) | (fastchip_selack & fastchip_ready) | (~ramsel & ~fastchip_selack & chipready)` ([cpu_wrapper.v:1150-1155](rtl/cpu_wrapper.v#L1150-L1155)) — per-bus qualification so a delayed ready from a prior region can't accidentally complete a pending MMU-gated cycle — BUG #408.
- Fastchip / IDE gate: `fastchip_sel = cpu_req & !pmmu_addr_phys_p[31:24] & ~walker_active` ([cpu_wrapper.v:348](rtl/cpu_wrapper.v#L348)) — BUG #425, walker activity also suppresses IDE/fastchip select.
- SDRAM cache handshakes — BUG #426/#427 ([cpu_wrapper.v:90-92](rtl/cpu_wrapper.v#L90-L92)): `walker_active_out` and `walker_writing_out` are exported for the SDRAM cache state machine to deassert `cpu_cs` and override `cpustate` during walker cycles.

### 10.6 Physical vs logical address routing
- Decoder input: `bus_addr = cpucfg[1] ? pmmu_addr_phys_p : cpu_addr` ([cpu_wrapper.v:123](rtl/cpu_wrapper.v#L123)) — BUG #417.
- All chip-selects ([cpu_wrapper.v:125-137](rtl/cpu_wrapper.v#L125-L137)) are keyed off `bus_addr`: `sel_chipram`, `sel_zram`, `sel_z3ram0/1`, `sel_z2ram`, `sel_dd`, `sel_kickram`, `sel_rtg`, etc. When the OS remaps e.g. WhichAmiga's logical `$D0xxxxxx` → physical `$00xxxxxx`, the chip bus sees the remapped address and the access lands in chip RAM ([cpu_wrapper.v:293-334](rtl/cpu_wrapper.v#L293-L334)).
- No hard-coded "always identity" bypass region in the wrapper — everything goes through PMMU translation. When MMU is disabled (`TC.E=0`), the PMMU itself emits identity; the wrapper needs no separate path.
- Cache-fill addressing: physical from `pmmu_addr_phys_p`, logical from `pmmu_addr_log_p` (lines around [cpu_wrapper.v:1381-1409](rtl/cpu_wrapper.v#L1381-L1409)); `i_cache_inhibit` / `d_cache_inhibit` fed from `pmmu_cache_inhibit_p` ([cpu_wrapper.v:1383, 1395](rtl/cpu_wrapper.v#L1383-L1395)).

### 10.7 Fault and config-error routing
- `pmmu_fault_p` ([cpu_wrapper.v:400](rtl/cpu_wrapper.v#L400)) feeds `pmmu_suppress_bus` but also bypasses the busy-stall term in `clkena_in` so the kernel's fault handler can run.
- `pmmu_walker_berr_p` ([cpu_wrapper.v:445, 1599, 1613, 1687, 1739, 1804, 1835, 1880, 1888](rtl/cpu_wrapper.v#L445)) — BUG #156 — signals a walker-side BERR back to PMMU, which in turn sets MMUSR.B and raises vector-2 via the kernel.
- MMU-config-error (vector 56): there is no separate wrapper wire; the kernel surfaces it, and the wrapper's bus suppression just keeps the bus idle while software handles it.
- SignalTap fault capture: [cpu_wrapper.v:579-615, 943, 1038, 1040](rtl/cpu_wrapper.v#L579-L615) — on the first `pmmu_fault_p`, TC/TTR/CRP/SRP/walker-state/descriptor chain are latched into persistent registers (`stp_fault_status_w`, `stp_saved_addr_w`, `stp_ptr1_*`, etc.) and kept until reset.

### 10.8 Cache / walker coherence
- Cache-fill request gating: `cache_req = fill_active | ((fill_pending_i | fill_pending_d) & ~pmmu_busy_p & ~pmmu_walker_req_p & ~walker_active)` (around [cpu_wrapper.v:1452](rtl/cpu_wrapper.v#L1452)) — BUG #408. Fills cannot launch while the MMU is busy or the walker is in flight, keeping the bus single-owner.
- Cache-hit data path explicitly excludes walker-owned cycles ([cpu_wrapper.v:263-266](rtl/cpu_wrapper.v#L263-L266)).
- The data cache honors `pmmu_cache_inhibit_p` directly; TTR identity translations with CI=1 flow through the combinational BUG #371 bypass on the PMMU side, and the D-cache skips the fill.

### 10.9 Reset behavior
- PMMU shares the kernel's `nreset` — there is no dedicated PMMU reset strobe.
- Walker registers reset to `WALKER_IDLE` and ack/berr cleared in the walker process ([cpu_wrapper.v:1595-1608](rtl/cpu_wrapper.v#L1595-L1608)).
- Reset escape — BUG #139 ([cpu_wrapper.v:1170-1179](rtl/cpu_wrapper.v#L1170-L1179)): `clkena_in` includes `~reset`, guaranteeing that a reset release resumes the CPU even if walker stall / ATC miss / fault were asserted when reset fired.

### 10.10 Wrapper-side `BUG #` comments that concern MMU/walker

| # | Lines | Summary |
|---|---|---|
| 124 | [1103, 1109, 1873, 1882](rtl/cpu_wrapper.v#L1103) | walker visibility in bus mux; 4-bit walker-state for write path |
| 126 | [387, 1211](rtl/cpu_wrapper.v#L387) | `pmmu_cache_inhibit_p` was unconnected — now wired to both caches |
| 128 | [177](rtl/cpu_wrapper.v#L177) | cache-fill ramaddr encoding for Z3 RAM |
| 135 | [1950, 1966](rtl/cpu_wrapper.v#L1950) | walker chip-RAM access ⇒ `chipreq` |
| 136 | [96, 136, 167, 190](rtl/cpu_wrapper.v#L96) | walker Fast-RAM path in `ramsel`/`ramaddr` |
| 137 | [145-148](rtl/cpu_wrapper.v#L145) | force both byte strobes for walker reads/writes |
| 138 | [1521, 1604, 1615, 1685, 1708, 1726, 1737, 1756](rtl/cpu_wrapper.v#L1521) | wrapper-side 2048-cycle escape |
| 139 | [1170-1179](rtl/cpu_wrapper.v#L1170-L1179) | reset/timeout bypass for walker stall |
| 156 | [445, 1599, 1613, 1687, 1739, 1804, 1835, 1880, 1888](rtl/cpu_wrapper.v#L445) | `pmmu_walker_berr_p` back to PMMU — sets MMUSR.B |
| 178 | — (PMMU side) | — |
| 192 | [209-212](rtl/cpu_wrapper.v#L209) | use `walker_active` (not reading\|writing) for clean bus handoff |
| 194 | [290](rtl/cpu_wrapper.v#L290) | walker only drives chip bus for chip-RAM, never Fast-RAM |
| 405 | [149, 317, 1748](rtl/cpu_wrapper.v#L149) | big-endian 32-bit descriptor assembly |
| 407 | [105, 392, 1172, 1221](rtl/cpu_wrapper.v#L105) | `pmmu_busy_p` gating of `clkena_in` |
| 408 | [98, 260, 320, 408, 1526](rtl/cpu_wrapper.v#L98) | suppress CPU ramsel / use correct ready per region |
| 417 | [114, 123, 330, 343](rtl/cpu_wrapper.v#L114) | physical address for all bus routing (fixes WhichAmiga) |
| 419 | [1647, 1675-1681, 1733, 1798, 1829](rtl/cpu_wrapper.v#L1647) | detect PMMU internal timeout (walker_req_p drop) |
| 422 | [1533, 1658, 1787](rtl/cpu_wrapper.v#L1533) | stale SDRAM/chip ready guard |
| 423 | [296, 312](rtl/cpu_wrapper.v#L296) | chip-bus AS cycling via `c_as` |
| 424 | [1642, 1651, 1776](rtl/cpu_wrapper.v#L1642) | timeout counter does not reset per cycle |
| 425 | [344-348](rtl/cpu_wrapper.v#L344) | suppress `fastchip_sel` during walker |
| 426 | [90](rtl/cpu_wrapper.v#L90) | `walker_active_out` for SDRAM cache SM |
| 427 | [92](rtl/cpu_wrapper.v#L92) | `walker_writing_out` for SDRAM `cpustate` override |
| 439 | [213, 217-218, 1713-1722](rtl/cpu_wrapper.v#L213) | `WALKER_RAM_GAP` drops `walker_fast_ram` so SDRAM clears `cpu_cs` |

### 10.11 Things the wrapper does **not** do
- **No TTR fast-path**: TTR matching is entirely in the PMMU (via `ttr_match_comb`); the wrapper has no parallel decode.
- **No identity-mapped MMU bypass regions**: there is no "RTC is always identity" carve-out. If software maps RTC through the MMU, the wrapper routes via `pmmu_addr_phys_p` like everything else. This is consistent with the commit-log observation that RTC visibility depends on OS-driven MMU mappings rather than hardware hard-coding.
- **No independent PMMU reset**: the PMMU relies on the kernel's `nreset`. A partial reset that leaves PMMU state but clears the walker (or vice versa) is not possible from the wrapper.
- **No MMU-config-error specific wire**: vector-56 is surfaced inside the kernel only. The wrapper's bus-suppression logic still keeps the bus idle while it is being dispatched.
- **Wrapper-level testbench now exists** (2026-04-16): [tests/tg68k_030/tb_cpu_wrapper_pmmu.v](tests/tg68k_030/tb_cpu_wrapper_pmmu.v), Makefile target `test-cpu-wrapper-pmmu`. Instantiates `cpu_wrapper.v` (mixed-language via ModelSim), forces Zorro-config regs, runs a pre-loaded 68030 program that enables the MMU then accesses remapped and Fast-RAM-backed pages. Self-checks walker ownership (via `walker_active`/`ramsel` invariant), BUG #417 (`bus_addr` never shows logical $D0xxxxxx while walker active), BUG #422 (stale-ready injection), BUG #439 (RAM-gap state count), BUG #424 (never-ready → walker_timeout_error). The bench is pragmatic rather than exhaustive — it validates the architectural invariants but does not enumerate every corner.

## 11. Gaps, stubs, dead code

### Deliberately absent
- **CAL / VAL / SCC / AC** registers ([PMMU:113-114](rtl/tg68k/TG68K_PMMU_030.vhd#L113-L114)).
- **MOVEC access to PMMU registers** (kernel whitelist excludes them — header now correctly documents this, [PMMU:100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L100-L106)).
- **PFLUSHN / PFLUSHR / PFLUSHS variants** not decoded.
- **Illegal PMOVE reg_sel**: no hardware trap (privilege check is upstream in the kernel), but BUG #446 now makes it observable via sim assertion + sticky `debug_illegal_reg_sel` latch.

### Stale or contradictory documentation in the RTL
- ~~File header advertises 8-entry ATC~~ — fixed, now reads "22-entry" ([PMMU:3](rtl/tg68k/TG68K_PMMU_030.vhd#L3)).
- ~~Header claims MOVEC access to TC/TT0/TT1/MMUSR~~ — fixed, replaced with a PMOVE-only note that calls out the deliberate spec deviation ([PMMU:100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L100-L106)).
- `tests/tg68k_030/tb_movec_pmmu.vhd` still drives MOVEC-to-PMMU and even uses `cpu_mode="11"` (outside the encoded 00/01/10). Bench is not wired into maintained Makefile targets — audit candidate for removal.
- Several inline debug comments tag "BUG E FIX" / "BUG F FIX" ([PMMU:3972-3977](rtl/tg68k/TG68K_PMMU_030.vhd#L3972-L3977)) without corresponding `BUG #` numbers.

### Dead-ish code
- `W_INDIRECT` / `W_INDIRECT_LOW` paths are rare in practice (Amiga MMU flows seldom emit indirect descriptors); exercised only by targeted unit benches.
- `cache_op_scope="01"` page-invalidate in [TG68K_Cache_030.vhd](rtl/tg68k/TG68K_Cache_030.vhd) is never driven by the kernel; effectively dead from the live command path (noted in [CPU_AUDIT.md](CPU_AUDIT.md)).
- `debug_ptr*_desc_addr/data` ports ([PMMU:77-83, 1219-1224](rtl/tg68k/TG68K_PMMU_030.vhd#L77-L83)) are for SignalTap only; no RTL consumer.
- Commented-out `slv_to_hstring` / `report` scaffolding throughout (e.g. [PMMU:334-390, 1045-1050, 1063-1064, 2427-2431](rtl/tg68k/TG68K_PMMU_030.vhd#L334-L390)) — disabled for Quartus / sim speed.

### Verification gaps
- ~~No guard for PTEST level > actual walk depth~~ — **false positive, retracted 2026-04-17**. Re-inspection shows every MMUSR-success site in a PTEST path reports `walk_level + 1` (the level actually reached), not `ptest_level` (the level requested). See e.g. [PMMU:2586](rtl/tg68k/TG68K_PMMU_030.vhd#L2586), [PMMU:3717](rtl/tg68k/TG68K_PMMU_030.vhd#L3717), [PMMU:3745](rtl/tg68k/TG68K_PMMU_030.vhd#L3745). Per MC68030 UM §9.7.2 the walker terminates at either a page descriptor _or_ the requested level, whichever is earlier, and reports the level reached — which is what this code does. Behavior is spec-compliant.
- ~~Illegal PMOVE reg_sel does not raise a hardware trap~~ — **closed 2026-04-17**. BUG #446 now also routes to `mmu_config_error` ([PMMU:1207, 1217](rtl/tg68k/TG68K_PMMU_030.vhd#L1207)), so an undecoded P-register selector raises vector 56 alongside the sim assertion and the sticky `debug_illegal_reg_sel` latch. Kernel processes via the existing `pmmu_config_err` / `pmmu_config_ack` handshake.
- The new wrapper bench is count/invariant-based, not exhaustive. Edge cases not covered:
  - walker U/M write-back while a CPU SDRAM cycle is in flight (race between `WALKER_WRITE_LOW` and `stale_ram_pending`);
  - repeated back-to-back walks across the `WALKER_DONE → WALKER_IDLE → WALKER_START` boundary;
  - PMMU-internal 500-cycle timeout firing _before_ the wrapper's 2048-cycle timeout (BUG #419 path).

## 12. Highest-leverage follow-ups (MMU-specific)

Items completed since the 2026-04-15 audit:
- ~~Fix the header comment (8-entry → 22-entry) and the MOVEC whitelist claim~~ — done 2026-04-16 ([PMMU:3, 100-106](rtl/tg68k/TG68K_PMMU_030.vhd#L3)).
- ~~Add a wrapper-level PMMU bench~~ — done 2026-04-16 ([tests/tg68k_030/tb_cpu_wrapper_pmmu.v](tests/tg68k_030/tb_cpu_wrapper_pmmu.v), Makefile target `test-cpu-wrapper-pmmu`). Exercises walker ownership, BUG #422 stale-ready, BUG #439 RAM-gap, BUG #424 watchdog escape, BUG #417 physical-address routing.
- ~~Make illegal PMOVE reg_sel observable~~ — done 2026-04-16, extended 2026-04-17 (BUG #446). Sim assertions + sticky `pmmu_illegal_reg_sel_seen` latch on port `debug_illegal_reg_sel` + **hardware trap via `mmu_config_error` → vector 56** (reuses BUG #445 ack handshake).
- ~~Expose `mmu_config_error` as a latched signal that doesn't race on repeated TC writes~~ — done 2026-04-16 (BUG #445). Sticky until `mmu_config_ack` or async reset.

Still open:

1. **Remove or mark `tb_movec_pmmu.vhd` as stale** — it exercises a MOVEC-to-PMMU path that the kernel now traps. Bench is not in the maintained Makefile targets.
2. **Retire or wire up `cache_op_scope="01"`** in the cache block (page-invalidate) — currently dead logic from the kernel's command path (see [CPU_AUDIT.md](CPU_AUDIT.md)).
3. **Document the walker timeout hierarchy**: 500-cycle PMMU internal (sets MMUSR.B from the walker's view) vs 2048-cycle wrapper escape (BUG #138) vs PMMU-timeout-detection (BUG #419). Three watchdogs with overlapping conditions; easy to confuse which one fires first.
4. **Broaden wrapper-level bench**: add cases for walker U/M write-back race with CPU SDRAM cycle, back-to-back walks, and the BUG #419 PMMU-internal-timeout path (currently only the BUG #424 wrapper watchdog is exercised).
