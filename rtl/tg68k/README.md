# TG68K Infrastructure Changes Summary (030_mmu vs MiSTer)

This document summarizes the structural and architectural changes to the TG68K CPU implementation in the 030_mmu branch compared to the original MiSTer branch.

## Files Modified

| File | Lines Changed |
|------|---------------|
| TG68KdotC_Kernel.vhd | +3889/-939 |
| TG68K_PMMU_030.vhd | +2957 (new) |
| TG68K_Cache_030.vhd | +374 (new) |
| TG68K.vhd | +371 |
| TG68K_Pack.vhd | +28 |
| TG68K_ALU.vhd | +28 |

---

## 1. NEW EXEC BITS (TG68K_Pack.vhd)

**lastOpcBit: 88 -> 103** (+15 bits)

| Bit | Name | Purpose |
|-----|------|---------|
| 89 | `pmmu_rd` | PMOVE MMU->Dn |
| 90 | `pmmu_wr` | PMOVE Dn->MMU |
| 91 | `pmmu_ptest` | PTEST instruction |
| 92 | `pmmu_pflush` | PFLUSH instruction |
| 93 | `pmmu_pload` | PLOAD instruction |
| 94-99 | `to/from_SSP/MSP/ISP` | Stack pointer save/restore |
| 100-101 | `use_sfc_dfc`, `sfc_not_dfc` | MOVES FC control |
| 102-103 | `pmmu_addr_inc`, `pmmu_dbl` | PMOVE 64-bit addressing |

---

## 2. NEW MICRO-STATES

```
pmove_decode, pmove_mem_to_mmu_hi/lo, pmove_mmu_to_mem_hi/lo,
pmove_dn_hi/lo, pmmu_dn_read_wait, ptest1/2, pflush1, pload1,
moves0, moves1
```

---

## 3. KEY SIGNAL ADDITIONS (~105 new signals)

### Stack Pointers
- `SSP`, `MSP`, `ISP` (32-bit each), `interrupt_mode`

### PMMU Register Interface
- `pmmu_reg_sel_d`, `pmmu_reg_we_d`, `pmmu_reg_re_d`, `pmmu_reg_wdat_d`, `pmmu_reg_rdat`
- `pmmu_reg_part_d`, `pmmu_reg_fd_d`

### F-Line Context Latch (critical for PMMU decode)
- `fline_opcode_latch`, `fline_brief_latch`, `fline_context_valid`
- `fline_is_pmmu`, `fline_is_fpu`, `fline_has_brief`

### PMOVE Addressing
- `pmove_disp_latched`, `pmove_ea_latched`, `pmove_ea_captured`
- `pmmu_dn_mode`, `pmmu_dn_regnum`, `pmmu_dn_data`

### MOVES Support
- `moves_bus_pending`, `moves_ea_areg`, `moves_ea_regnum`
- `moves_d16_phase`, `moves_writeback_pending`

### Cache Control
- `CACR` expanded: 4-bit -> 32-bit
- `cacr_ie`, `cacr_de`, `cacr_ibe`, `cacr_dbe`, `cacr_wa`, `cacr_ifreeze`, `cacr_dfreeze`

### MMU Exceptions
- `trap_mmu_config`, `trap_mmu_berr`, `trap_format_error`, `make_mmu_berr`

---

## 4. PORT ADDITIONS (TG68KdotC_Kernel)

### PMMU Interface
- `pmmu_reg_we/re`, `pmmu_reg_sel[4:0]`, `pmmu_reg_wdat[31:0]`, `pmmu_reg_part`
- `pmmu_addr_log[31:0]`, `pmmu_addr_phys[31:0]`, `pmmu_cache_inhibit`

### Walker Memory Interface
- `pmmu_walker_req/we/ack`, `pmmu_walker_addr/wdat/data[31:0]`, `pmmu_walker_berr`

### Cache Operations
- `cache_inv_req`, `cache_op_scope[1:0]`, `cache_op_cache[1:0]`, `cache_op_addr[31:0]`

---

## 5. ALU CHANGES

- Added `exec(pmmu_addr_inc)` for +4 increment (PMOVE 64-bit transfers)
- Added `exec(pmmu_dbl)` for +8 increment ((An)+/-(An) with CRP/SRP)

---

## 6. TG68K.vhd WRAPPER

### New Component
- `TG68K_Cache_030` instantiation with I/D cache interfaces

### Cache Fill Buffer
- 128-bit buffer for 8-word sequential reads
- `cache_fill_count[2:0]`, `cache_fill_active`, `cache_fill_complete`

### Byte Enables
- Dynamic `byte_enables[3:0]` based on UDS/LDS

---

## 7. CPU MODE ENCODING

- `CPU="10"`-> 68030 mode (with PMMU)
- `cpu(1)='1'` checks enable 68020/68030 features

---

## 8. NEW FILES

### TG68K_PMMU_030.vhd (2957 lines)
Complete MC68030-compatible Paged Memory Management Unit:
- **Registers:** TC, CRP, SRP, TT0, TT1, MMUSR
- **Instructions:** PMOVE, PTEST, PFLUSH, PLOAD
- **Page Table Walker:** Multi-level (W_ROOT->W_PTR1->W_PTR2->W_PTR3->W_PAGE)
- **ATC:** 8-entry Address Translation Cache
- **Transparent Translation:** TT0/TT1 bypass logic
- **Fault Handling:** Invalid descriptors, write protection, privilege violations

### TG68K_Cache_030.vhd (374 lines)
256-byte instruction and data caches:
- Direct-mapped, 16 lines x 16 bytes
- PIPT (Physically Indexed, Physically Tagged)
- Burst mode support (IBE/DBE from CACR)
- Cache invalidation/freeze support

---

## 9. ARCHITECTURAL CHANGES

### Register File Enhancements
- Support for 3 separate stack pointers (SSP/MSP/ISP) with mode switching
- Interrupt mode tracking for proper stack pointer selection

### Memory Interface Extensions
- PMMU walker memory interface for page table walks (separate from CPU data bus)
- Logical-to-physical address translation with cache inhibit signals
- Support for MC68030 U/M bit updates during table walks

### Instruction Decode Pipeline
- F-line context latch captures opcode/brief at decode time for stable PMMU/FPU parameters
- Prevents register selector corruption across clock cycles

### MOVES Instruction Implementation (68010+)
- Separate bus access tracking for address register modes
- Displacement word fetching for (d16,An) mode
- Destination register write-back persistence guard
- SFC/DFC function code selection

### Cache Integration
- Separate instruction and data cache instances
- 128-bit cache fill buffer (supports 8-word sequential reads for cache lines)
- Cache operation support (CINV/CPUSH with scope/target selection)
- Burst mode enable signals (IBE/DBE from CACR)
