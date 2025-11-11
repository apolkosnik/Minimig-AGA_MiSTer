# MC68030 MMU Registers Specification

## Document Purpose

This document specifies the Memory Management Unit (MMU) control registers introduced in the MC68030. These registers control address translation, transparent translation, and MMU status.

## Overview

The MC68030 MMU includes six new control registers:

| Register | Size | Access | Purpose |
|----------|------|--------|---------|
| **TC** | 32-bit | Supervisor | Translation Control - MMU enable and configuration |
| **TT0** | 32-bit | Supervisor | Transparent Translation Register 0 |
| **TT1** | 32-bit | Supervisor | Transparent Translation Register 1 |
| **CRP** | 64-bit | Supervisor | CPU Root Pointer - points to root of page tables |
| **SRP** | 64-bit | Supervisor | Supervisor Root Pointer - alternate root pointer |
| **MMUSR** | 16-bit | Supervisor | MMU Status Register - translation test results |

All registers are **supervisor only** - accessing from user mode causes a privilege violation exception.

## Register Descriptions

### TC - Translation Control Register (32-bit)

Controls overall MMU operation and translation parameters.

#### Bit Layout
```
 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ E │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │SRE│FCL│PS │       IS          │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│      TIA      │      TIB      │      TIC      │      TID      │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

#### Bit Definitions

| Bit(s) | Name | Description |
|--------|------|-------------|
| 31 | **E** | Enable - 1=MMU enabled, 0=MMU disabled |
| 30-24 | - | Reserved (must be 0) |
| 23 | **SRE** | Supervisor Root Enable - 1=use SRP, 0=use CRP in supervisor mode |
| 22 | **FCL** | Function Code Lookup - 1=function code in table, 0=function code ignored |
| 21-20 | **PS** | Page Size - 00=256B, 01=512B, 10=1KB, 11=2KB-32KB (from descriptor) |
| 19-16 | **IS** | Initial Shift - Number of bits to shift logical address for first table lookup |
| 15-12 | **TIA** | Table Index A - Number of bits for first-level table index |
| 11-8 | **TIB** | Table Index B - Number of bits for second-level table index |
| 7-4 | **TIC** | Table Index C - Number of bits for third-level table index |
| 3-0 | **TID** | Table Index D - Number of bits for fourth-level table index |

#### Reset Value
`0x00000000` - MMU disabled, all fields zero

#### Usage
```
Example: Enable MMU with 4KB pages, 2-level translation
TC = 0x80A08000
     E=1 (enabled)
     PS=10 (4KB pages from descriptor)
     IS=10 (shift 10 bits)
     TIA=8 (256-entry first table)
     TIB=0, TIC=0, TID=0 (single level)
```

#### Notes
- When E=0, all addresses pass through untranslated (except TT matches)
- TIA+TIB+TIC+TID+IS+PS must equal 32 (for full address coverage)
- Common configurations:
  - 2-level: IS=10, TIA=8, TIB=10 (256-entry L1, 1024-entry L2)
  - 3-level: IS=10, TIA=7, TIB=7, TIC=6 (balanced)

---

### TT0/TT1 - Transparent Translation Registers (32-bit each)

Allow certain address ranges to bypass MMU translation for performance or I/O access.

#### Bit Layout
```
 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│      Logical Address Base (bits 31-16)       │ 0 │ 0 │ 0 │ 0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│      Logical Address Mask (bits 31-16)       │ E │ 0 │CI │R/W│
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
     ↑                                           ↑       ↑    ↑
     Address Mask (1=don't care)                │       │    │
                                                 │       │    └─ FC match
                                                 │       └────── Cache Inhibit
                                                 └────────────── Enable
```

#### Bit Definitions

| Bit(s) | Name | Description |
|--------|------|-------------|
| 31-16 | **Base** | Logical address base (bits 31-16) |
| 15-12 | - | Reserved (must be 0) |
| 11-8 | **Mask** | Address mask (bits 31-28): 1=don't care, 0=must match |
| 7-4 | **Mask** | Address mask (bits 27-24) |
| 3 | **E** | Enable - 1=transparent translation enabled, 0=disabled |
| 2 | - | Reserved (must be 0) |
| 1 | **CI** | Cache Inhibit - 1=disable caching for this range, 0=allow caching |
| 0 | **R/W** | Read/Write - combined with FC for access control |

#### Function Code Matching (bits 2-0)

The R/W bit combines with function codes for access matching:

| R/W | FC2 | FC1 | FC0 | Matches |
|-----|-----|-----|-----|---------|
| 0 | - | - | - | Read access (any FC) |
| 1 | - | - | - | Write access (any FC) |

**Note**: MC68030 has simplified FC matching compared to 68851. Full implementation can match FC explicitly.

#### Reset Value
`0x00000000` - Transparent translation disabled

#### Usage Examples

**Example 1: Map entire I/O space (0xFF000000-0xFFFFFFFF)**
```
TT0 = 0xFF00FF07
      Base = 0xFF00 (I/O region)
      Mask = 0x00FF (bits 23-16 don't care, match 0xFF______)
      E = 1 (enabled)
      CI = 1 (cache inhibit)
```

**Example 2: Map 16MB ROM at 0xF0000000**
```
TT1 = 0xF000F007
      Base = 0xF000
      Mask = 0x0F00 (match 0xF0______)
      E = 1 (enabled)
      CI = 1 (cache inhibit for ROM)
```

#### Notes
- TT0 and TT1 are checked before MMU translation
- If address matches TT0 or TT1, MMU is bypassed
- Transparent translation works even when TC.E=0
- Useful for:
  - I/O device mapping
  - ROM access
  - Performance-critical regions
  - DMA-accessible memory

---

### CRP - CPU Root Pointer (64-bit)

Points to the root of the CPU's page table tree. Used for user and supervisor mode when TC.SRE=0.

#### Bit Layout
```
 63  62  61  60  59  58  57  56  55  54  53  52  51  50  49  48
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│        Upper Long Word (Descriptor Type and Limit)            │
│   DT  │   0   │              Limit                            │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│                  Root Pointer Address (High)                   │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│                  Root Pointer Address (Low)                    │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

#### Upper Long Word (bits 63-32)

| Bit(s) | Name | Description |
|--------|------|-------------|
| 63-62 | **DT** | Descriptor Type: 00=invalid, 01=page descriptor, 10=short table, 11=long table |
| 61-48 | - | Reserved (must be 0) |
| 47-32 | **Limit** | Upper limit for table index (bounds checking) |

#### Lower Long Word (bits 31-0)

| Bit(s) | Name | Description |
|--------|------|-------------|
| 31-4 | **Address** | Physical address of root table (must be aligned on 16-byte boundary) |
| 3-0 | - | Reserved (must be 0, enforces alignment) |

#### Reset Value
`0x0000000000000000` - Invalid descriptor, no root pointer

#### Usage
```
Example: Point to root table at physical address 0x00100000
CRP = 0x8000000000100000
      DT = 10 (short format table descriptor)
      Limit = 0x0000 (no limit check)
      Address = 0x00100000 (physical address)
```

#### Notes
- CRP is used when TC.SRE=0 (both supervisor and user mode)
- Table address must be 16-byte aligned
- DT field determines table format (short vs long descriptors)
- Limit field can restrict table size for bounds checking

---

### SRP - Supervisor Root Pointer (64-bit)

Alternate root pointer used in supervisor mode when TC.SRE=1. Format identical to CRP.

#### Bit Layout
Same as CRP (see above).

#### Reset Value
`0x0000000000000000` - Invalid descriptor, no root pointer

#### Usage
```
Example: Separate supervisor page tables at 0x00200000
SRP = 0x8000000000200000
TC.SRE = 1 (enable SRP for supervisor mode)

Now:
- Supervisor mode uses SRP (0x00200000)
- User mode uses CRP (different tree)
```

#### Notes
- Only used when TC.SRE=1
- Allows separate address spaces for supervisor and user
- Useful for operating systems with memory protection
- AmigaOS typically doesn't use SRP (uses single address space)

---

### MMUSR - MMU Status Register (16-bit)

Contains the results of the last PTEST instruction or MMU fault information.

#### Bit Layout
```
 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ B │ L │ S │ W │ I │ M │ G │ U │ 0 │ T │ R │   N   │ 0 │ 0 │ 0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

#### Bit Definitions

| Bit | Name | Description |
|-----|------|-------------|
| 15 | **B** | Bus Error - 1=bus error during table search |
| 14 | **L** | Limit Violation - 1=table index exceeds limit |
| 13 | **S** | Supervisor Violation - 1=supervisor-only page accessed in user mode |
| 12 | **W** | Write Protected - 1=write to write-protected page |
| 11 | **I** | Invalid - 1=invalid descriptor encountered |
| 10 | **M** | Modified - 1=page has been modified (M bit set in descriptor) |
| 9 | **G** | Global - 1=global page (not flushed by PFLUSH) |
| 8 | **U** | Used - 1=page has been accessed (U bit set in descriptor) |
| 7 | - | Reserved (0) |
| 6 | **T** | Transparent - 1=address matched TT0 or TT1 (bypassed MMU) |
| 5 | **R** | Resident - 1=all table lookups successful (page is resident) |
| 4-3 | **N** | Number of levels - 00=no levels, 01=1 level, 10=2 levels, etc. |
| 2-0 | - | Reserved (0) |

#### Reset Value
`0x0000` - All flags clear

#### Usage
After PTEST instruction:
```
PTEST (A0)        ; Test address translation
PMOVE MMUSR,D0    ; Read result
BTST #5,D0        ; Check R bit
BNE page_resident ; Branch if page is in memory
```

#### Fault Conditions

| Condition | MMUSR Bits |
|-----------|------------|
| Page not resident | R=0 |
| Invalid descriptor | I=1, R=0 |
| Supervisor violation | S=1 |
| Write protect violation | W=1 |
| Bus error in table walk | B=1 |
| Transparent translation | T=1, R=1 |

#### Notes
- Updated by PTEST instruction
- Also updated during MMU faults
- Software can read to determine fault type
- Essential for virtual memory page fault handlers

---

## Register Access

### PMOVE Instruction

All MMU registers are accessed via the PMOVE instruction:

```assembly
; Read MMU register to memory/register
PMOVE TC,D0          ; Read TC to D0
PMOVE CRP,-(A7)      ; Push CRP to stack

; Write MMU register from memory/register
PMOVE D0,TC          ; Write D0 to TC
PMOVE (A0),TT0       ; Write memory to TT0
```

**Privilege**: Supervisor only (privilege violation if executed in user mode)

### MOVEC Instruction

Some registers (TC, TT0, TT1) can also be accessed via MOVEC:

```assembly
MOVEC TC,D0          ; Read TC to D0
MOVEC D0,TC          ; Write D0 to TC
```

**Note**: CRP and SRP are 64-bit, so they use PMOVE, not MOVEC.

## Implementation Requirements

### Phase 2 (Current)
1. ✅ Create register storage (32-bit for TC/TT0/TT1, 64-bit for CRP/SRP, 16-bit for MMUSR)
2. ✅ Implement read/write access via PMOVE
3. ✅ Implement privilege checking (supervisor only)
4. ✅ Implement reset values
5. ✅ Add basic MOVEC support for TC/TT0/TT1

### Phase 3 (Instructions)
6. ⏳ Full PMOVE implementation with all addressing modes
7. ⏳ PFLUSH updates (affects ATC, not registers directly)
8. ⏳ PTEST updates MMUSR

### Phase 5 (MMU Functional)
9. ⏳ TC.E bit actually enables/disables MMU
10. ⏳ TT0/TT1 perform transparent translation
11. ⏳ CRP/SRP point to actual page tables
12. ⏳ MMUSR reflects real translation status

## Testing Requirements

### Unit Tests
- Read/write each register
- Verify reset values
- Test privilege violations (user mode access)
- Test reserved bit behavior (should read as 0)
- Test alignment (CRP/SRP addresses must be 16-byte aligned)

### Integration Tests
- PMOVE instruction with various addressing modes
- MOVEC for TC/TT0/TT1
- Register persistence across operations

### Compliance Tests
- Match MC68030 hardware behavior
- Undefined bits read as zero
- Reserved fields ignored on write

## Register Summary Table

| Register | Size | PMOVE | MOVEC | Reset Value | Key Purpose |
|----------|------|-------|-------|-------------|-------------|
| TC | 32-bit | ✅ | ✅ | 0x00000000 | Enable MMU, configure translation |
| TT0 | 32-bit | ✅ | ✅ | 0x00000000 | Transparent translation range 0 |
| TT1 | 32-bit | ✅ | ✅ | 0x00000000 | Transparent translation range 1 |
| CRP | 64-bit | ✅ | ❌ | 0x0000000000000000 | CPU root pointer |
| SRP | 64-bit | ✅ | ❌ | 0x0000000000000000 | Supervisor root pointer |
| MMUSR | 16-bit | ✅ | ❌ | 0x0000 | MMU status/test results |

## References

- MC68030 User's Manual, Section 6: Memory Management Unit
- MC68030 User's Manual, Section 9: Instruction Set
- MC68851 PMMU User's Manual (compatible subset)

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created MMU register specifications |

