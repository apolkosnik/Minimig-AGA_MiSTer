# MC68030 Cache Control Registers Specification

## Document Purpose

This document specifies the cache control registers for the MC68030 processor. The MC68030 has on-chip instruction and data caches controlled via these registers.

## Overview

The MC68030 cache system includes two control registers:

| Register | Size | Access | Purpose |
|----------|------|--------|---------|
| **CACR** | 32-bit | Supervisor | Cache Control Register - enable/disable/control caches |
| **CAAR** | 32-bit | Supervisor | Cache Address Register - for cache entry operations |

## Cache Architecture Summary

- **Instruction Cache**: 256 bytes, direct-mapped, 16 lines × 16 bytes
- **Data Cache**: 256 bytes, direct-mapped, 16 lines × 16 bytes
- **Write Policy**: Write-through (data cache)
- **Line Size**: 16 bytes (4 longwords)
- **Organization**: Direct-mapped (one cache line per address range)

---

## CACR - Cache Control Register (32-bit)

Controls cache enable/disable and cache operations.

### Bit Layout
```
 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │WA │DBE│ 0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0 │ 0 │ 0 │CD │CDE│FD │ ED│ 0 │IBE│ 0 │ 0 │ CI │CEI│ FI│ EI│ 0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

### Bit Definitions

| Bit | Name | R/W | Description |
|-----|------|-----|-------------|
| 31-14 | - | R | Reserved (read as 0) |
| 13 | **WA** | R/W | Write Allocate - 1=allocate line on write miss, 0=no allocate (typically 0 for MC68030) |
| 12 | **DBE** | R/W | Data Burst Enable - 1=enable burst fills for data cache, 0=disable |
| 11 | **CD** | W | Clear Data Cache - Write 1 to invalidate entire data cache (self-clearing) |
| 10 | **CDE** | W | Clear Data Cache Entry - Write 1 to clear entry specified by CAAR (self-clearing) |
| 9 | **FD** | R/W | Freeze Data Cache - 1=freeze (no updates), 0=normal operation |
| 8 | **ED** | R/W | Enable Data Cache - 1=data cache enabled, 0=disabled |
| 7 | - | R | Reserved (read as 0) |
| 6 | - | R | Reserved (read as 0) |
| 5 | - | R | Reserved (read as 0) |
| 4 | **IBE** | R/W | Instruction Burst Enable - 1=enable burst fills for I-cache, 0=disable |
| 3 | **CI** | W | Clear Instruction Cache - Write 1 to invalidate entire I-cache (self-clearing) |
| 2 | **CEI** | W | Clear Instruction Cache Entry - Write 1 to clear entry specified by CAAR (self-clearing) |
| 1 | **FI** | R/W | Freeze Instruction Cache - 1=freeze (no updates), 0=normal operation |
| 0 | **EI** | R/W | Enable Instruction Cache - 1=instruction cache enabled, 0=disabled |

### Self-Clearing Bits

The following bits are **write-only** and self-clearing (always read as 0):
- **CI** (bit 3) - Clear Instruction Cache
- **CEI** (bit 2) - Clear Instruction Cache Entry
- **CD** (bit 11) - Clear Data Cache
- **CDE** (bit 10) - Clear Data Cache Entry

When you write 1 to these bits, the operation executes, then the bit automatically clears. Reading them always returns 0.

### Reset Value
`0x00000000` - Both caches disabled, all control bits clear

### Usage Examples

**Example 1: Enable both caches**
```assembly
MOVE.L  #$00000101,D0   ; EI=1 (enable I-cache), ED=1 (enable D-cache)
MOVEC   D0,CACR         ; Write to CACR
```

**Example 2: Clear instruction cache**
```assembly
MOVE.L  #$00000008,D0   ; CI=1 (clear I-cache)
MOVEC   D0,CACR         ; Invalidate I-cache (CI self-clears)
```

**Example 3: Enable caches with burst mode**
```assembly
MOVE.L  #$00001111,D0   ; EI=1, FI=0, CEI=0, CI=0, IBE=1
                        ; ED=1, FD=0, CDE=0, CD=0, DBE=1
MOVEC   D0,CACR         ; Enable both caches with burst
```

**Example 4: Freeze data cache (for debugging)**
```assembly
MOVE.L  #$00000300,D0   ; FD=1, ED=1 (enabled but frozen)
MOVEC   D0,CACR
```

### Cache Control Operations

#### Invalidate Entire Instruction Cache
```assembly
MOVE.L  #$00000008,D0   ; CI=1
MOVEC   D0,CACR
```

#### Invalidate Entire Data Cache
```assembly
MOVE.L  #$00000800,D0   ; CD=1
MOVEC   D0,CACR
```

#### Invalidate Specific Cache Entry
```assembly
MOVE.L  #$12345678,D0   ; Address to invalidate
MOVEC   D0,CAAR         ; Load address into CAAR
MOVE.L  #$00000004,D0   ; CEI=1 (for I-cache) or CDE=1 (for D-cache)
MOVEC   D0,CACR         ; Clear the entry
```

#### Disable All Caching
```assembly
MOVE.L  #$00000000,D0   ; EI=0, ED=0
MOVEC   D0,CACR
```

### Operating Modes

| EI | FI | I-Cache State |
|----|----|---------------|
| 0 | X | Disabled (all fetches from memory) |
| 1 | 0 | Enabled, normal operation (updates on misses) |
| 1 | 1 | Enabled, frozen (uses existing data, no updates) |

Same applies for data cache with ED and FD bits.

### Burst Mode

When **IBE** or **DBE** are set:
- Cache line fills use burst transfers (4 longwords in rapid succession)
- Requires bus support for burst protocol
- Significantly faster than individual accesses
- MC68030 asserts CBREQ (Cache Burst Request) signal
- External logic responds with CBACK (Cache Burst Acknowledge)

**Note**: Burst mode is optional and depends on system hardware support.

---

## CAAR - Cache Address Register (32-bit)

Specifies which cache entry to operate on for single-entry operations (CEI, CDE).

### Bit Layout
```
 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│                         Address Bits 31-16                     │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│                         Address Bits 15-0                      │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

### Bit Definitions

| Bit(s) | Name | Description |
|--------|------|-------------|
| 31-0 | **Address** | Full 32-bit address of cache entry to operate on |

### Cache Entry Selection

The MC68030 caches are **direct-mapped**, so the address maps to a specific cache line:

**For 256-byte cache with 16-byte lines (16 lines total):**
- Bits 7-4: Select which of 16 cache lines (line index)
- Bits 31-8: Tag stored with cache line
- Bits 3-0: Offset within the 16-byte line (not used for entry selection)

When you write an address to CAAR and set CEI or CDE:
- Bits 7-4 select which line to invalidate
- The specified line is marked invalid
- Tag doesn't need to match (line is cleared regardless)

### Reset Value
`0x00000000` - No specific address selected

### Usage Examples

**Example 1: Invalidate I-cache entry for address 0x00001234**
```assembly
MOVE.L  #$00001234,D0   ; Address to invalidate
MOVEC   D0,CAAR         ; Load into CAAR
MOVE.L  #$00000004,D0   ; CEI=1
MOVEC   D0,CACR         ; Clear I-cache entry for line 3 (bits 7-4 = 0011)
```

**Example 2: Invalidate D-cache entry for stack access**
```assembly
MOVE.L  A7,D0           ; Current stack pointer
MOVEC   D0,CAAR         ; Use SP as address
MOVE.L  #$00000400,D0   ; CDE=1
MOVEC   D0,CACR         ; Clear D-cache entry
```

**Example 3: Clear multiple specific entries**
```assembly
; Clear I-cache entries for addresses 0x1000, 0x2000, 0x3000
LEA     addr_list,A0
MOVEQ   #2,D1           ; Count-1
.loop:
    MOVE.L  (A0)+,D0
    MOVEC   D0,CAAR
    MOVE.L  #$00000004,D2
    MOVEC   D2,CACR     ; Clear entry
    DBRA    D1,.loop
```

### Notes on CAAR

- Used **only** with CEI and CDE operations
- Has no effect on CI or CD (full cache clear) operations
- Bits 3-0 (offset within line) are don't-care for entry selection
- Writing to CAAR doesn't cause any cache operation by itself
- CAAR is readable (can read back last written value)

---

## Register Access

Both CACR and CAAR are accessed via the **MOVEC** instruction:

```assembly
; Read CACR
MOVEC   CACR,D0         ; Read CACR to D0

; Write CACR
MOVE.L  #$00000101,D0
MOVEC   D0,CACR         ; Write D0 to CACR

; Read CAAR
MOVEC   CAAR,D0         ; Read CAAR to D0

; Write CAAR
MOVE.L  #$12345678,D0
MOVEC   D0,CAAR         ; Write D0 to CAAR
```

**Privilege**: Both registers are supervisor only (privilege violation if accessed in user mode).

---

## Comparison with MC68020

The MC68020 had a simpler CACR with only instruction cache control:

### MC68020 CACR (4 bits)
```
Bit 0: Enable Cache (C)
Bit 1: Freeze Cache (F)
Bit 2: Clear Entry (CE)
Bit 3: Clear Cache (CL)
```

### MC68030 CACR (14 functional bits)
- Separate control for **instruction and data caches**
- **Burst mode** enable bits (IBE, DBE)
- **Write allocate** bit (WA)
- Same basic operations (enable, freeze, clear) but doubled for two caches

**Migration Path**: MC68020 code using CACR bits 0-3 will work on MC68030:
- Bit 0 maps to EI (enable instruction cache) ✅
- Bit 1 maps to FI (freeze instruction cache) ✅
- Bit 2 maps to CEI (clear I-cache entry) ✅
- Bit 3 maps to CI (clear instruction cache) ✅

So MC68020 software is **forward compatible** with MC68030!

---

## Implementation Requirements

### Phase 2 (Current - Register Implementation)
1. ✅ Create CACR storage (32-bit register)
2. ✅ Create CAAR storage (32-bit register)
3. ✅ Implement MOVEC read/write for CACR
4. ✅ Implement MOVEC read/write for CAAR
5. ✅ Implement privilege checking (supervisor only)
6. ✅ Handle self-clearing bits (CI, CEI, CD, CDE)
7. ✅ Implement reset values (all zeros)

### Phase 4 (Cache Implementation)
8. ⏳ EI/ED bits actually enable/disable caches
9. ⏳ FI/FD bits freeze cache updates
10. ⏳ CI/CD bits trigger full cache invalidation
11. ⏳ CEI/CDE bits trigger single entry invalidation using CAAR
12. ⏳ IBE/DBE bits enable burst mode (if bus supports it)
13. ⏳ WA bit controls write allocate policy

### Phase 6 (Bus Interface)
14. ⏳ Implement burst mode protocol (CBREQ/CBACK signals)
15. ⏳ Integrate with memory controller

---

## Cache Operation Flowcharts

### Full Cache Clear
```
1. Software writes CACR with CI=1 or CD=1
2. MMU/Cache module sees write
3. All valid bits in respective cache cleared
4. CI or CD bit self-clears
5. Operation complete
```

### Single Entry Clear
```
1. Software writes address to CAAR
2. Software writes CACR with CEI=1 or CDE=1
3. Cache module extracts line index from CAAR (bits 7-4)
4. Valid bit for that line cleared
5. CEI or CDE bit self-clears
6. Operation complete
```

### Cache Enable/Disable
```
1. Software writes CACR with EI or ED bit
2. If 1: Cache enabled, lookups begin
3. If 0: Cache disabled, all accesses go to memory
4. Cache contents preserved (not automatically cleared)
```

---

## Testing Requirements

### Unit Tests
- Read/write CACR via MOVEC
- Read/write CAAR via MOVEC
- Verify reset values
- Test privilege violations (user mode access)
- Test self-clearing bits (CI, CEI, CD, CDE)
- Test reserved bits read as zero
- Test burst mode bits
- Test freeze mode bits

### Integration Tests
- CACR enable/disable affects cache behavior
- CAAR selects correct cache line
- Self-clearing bits trigger operations
- Burst mode integration with bus

### Compliance Tests
- MC68020 CACR compatibility (bits 0-3)
- Self-clearing behavior matches hardware
- Reserved bits behavior

---

## Register Summary Table

| Register | Size | Access | Reset | Purpose |
|----------|------|--------|-------|---------|
| **CACR** | 32-bit | Supervisor (MOVEC) | 0x00000000 | Control I-cache and D-cache |
| **CAAR** | 32-bit | Supervisor (MOVEC) | 0x00000000 | Address for entry operations |

### CACR Bit Summary

| Bit | Name | Type | Function |
|-----|------|------|----------|
| 0 | EI | R/W | Enable Instruction Cache |
| 1 | FI | R/W | Freeze Instruction Cache |
| 2 | CEI | W | Clear Instruction Cache Entry |
| 3 | CI | W | Clear Instruction Cache |
| 4 | IBE | R/W | Instruction Burst Enable |
| 8 | ED | R/W | Enable Data Cache |
| 9 | FD | R/W | Freeze Data Cache |
| 10 | CDE | W | Clear Data Cache Entry |
| 11 | CD | W | Clear Data Cache |
| 12 | DBE | R/W | Data Burst Enable |
| 13 | WA | R/W | Write Allocate |

---

## Notes

### Important Implementation Details

1. **Self-Clearing Bits**: CI, CEI, CD, CDE automatically clear after operation completes. They always read as 0.

2. **Cache Disable**: Disabling cache (EI=0 or ED=0) does NOT automatically clear it. Contents remain but are not used.

3. **Freeze Mode**: Freeze (FI=1 or FD=1) with Enable (EI=1 or ED=1) means cache is consulted but not updated on misses.

4. **Burst Mode**: Requires external hardware support. If unsupported, burst requests are ignored and normal cycles used.

5. **Write-Through**: MC68030 data cache is always write-through. All writes go to both cache and memory.

6. **No CINV Instruction**: Unlike MC68040, the MC68030 does NOT have a CINV instruction. All cache control is via CACR/CAAR with MOVEC.

### Typical AmigaOS Usage

AmigaOS typically:
- Enables both caches (CACR = 0x00000101)
- Clears caches after loading code (CACR = 0x00000808, then 0x00000101)
- May disable caches temporarily for DMA operations
- Uses transparent translation (TT0/TT1) to mark I/O regions as cache-inhibited

---

## References

- MC68030 User's Manual, Section 5: On-Chip Cache Memory
- MC68030 User's Manual, Section 9: Instruction Descriptions (MOVEC)
- MC68020 User's Manual (for compatibility comparison)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created cache register specifications |
| 1.1 | 2025-11-11 | Update | Corrected CINV note (040 only, not 030) |

