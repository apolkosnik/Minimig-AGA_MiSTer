# MC68040 Control Register Map

## Overview

This document describes the MC68040 control registers accessible via the MOVEC instruction. These registers control cache operation, memory management, and other system-level functions.

## Register Summary

| Register | MOVEC Code | Width | Access | 68000 | 68010 | 68020 | 68040 | Description |
|----------|------------|-------|--------|-------|-------|-------|-------|-------------|
| SFC | 0x000 | 3-bit | S RW | - | ✓ | ✓ | ✓ | Source Function Code |
| DFC | 0x001 | 3-bit | S RW | - | ✓ | ✓ | ✓ | Destination Function Code |
| CACR | 0x002 | 16/32-bit | S RW | - | - | ✓(16) | ✓(32) | Cache Control Register |
| TC | 0x003 | 32-bit | S RW | - | - | - | ✓ | Translation Control |
| ITT0 | 0x004 | 32-bit | S RW | - | - | - | ✓ | Instruction Transparent Translation 0 |
| ITT1 | 0x005 | 32-bit | S RW | - | - | - | ✓ | Instruction Transparent Translation 1 |
| DTT0 | 0x006 | 32-bit | S RW | - | - | - | ✓ | Data Transparent Translation 0 |
| DTT1 | 0x007 | 32-bit | S RW | - | - | - | ✓ | Data Transparent Translation 1 |
| USP | 0x800 | 32-bit | S RW | ✓ | ✓ | ✓ | ✓ | User Stack Pointer |
| VBR | 0x801 | 32-bit | S RW | - | ✓ | ✓ | ✓ | Vector Base Register |
| MSP | 0x803 | 32-bit | S RW | - | ✓ | ✓ | ✓ | Master Stack Pointer |
| ISP | 0x804 | 32-bit | S RW | - | ✓ | ✓ | ✓ | Interrupt Stack Pointer |
| MMUSR | 0x805 | 16-bit | S RO | - | - | - | ✓ | MMU Status Register |
| URP | 0x806 | 32-bit | S RW | - | - | - | ✓ | User Root Pointer |
| SRP | 0x807 | 32-bit | S RW | - | - | - | ✓ | Supervisor Root Pointer |

**Access:** S = Supervisor only, RW = Read/Write, RO = Read Only

## Detailed Register Descriptions

### SFC - Source Function Code (0x000)

**Width:** 3 bits (bits 2-0 significant)
**Access:** Supervisor Read/Write
**Reset Value:** 0

Controls the function code used by the MOVES instruction when reading from memory.

**Bit Fields:**
```
Bits 31-3: Reserved (read as 0, write ignored)
Bits 2-0: Function Code
```

**Function Code Values:**
- 000 = Reserved
- 001 = User Data
- 010 = User Program
- 011 = Reserved
- 100 = Reserved
- 101 = Supervisor Data
- 110 = Supervisor Program
- 111 = CPU Space

### DFC - Destination Function Code (0x001)

**Width:** 3 bits (bits 2-0 significant)
**Access:** Supervisor Read/Write
**Reset Value:** 0

Controls the function code used by the MOVES instruction when writing to memory.

**Bit Fields:** Same as SFC

### CACR - Cache Control Register (0x002)

**Width:** 32 bits (68040), 16 bits (68020)
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000

Controls the operation of the instruction and data caches.

**MC68040 Bit Fields:**

```
Bit 31 (DE):  Data Cache Enable
             0 = Data cache disabled
             1 = Data cache enabled

Bit 30 (DF):  Data Cache Freeze
             0 = Data cache updates normally
             1 = Data cache frozen (no new lines loaded)

Bit 29 (DBE): Data Burst Enable
             0 = Data burst transfers disabled
             1 = Data burst transfers enabled

Bits 28-26: Reserved

Bits 25-24 (WA): Write Allocation
             00 = No write allocation
             01 = Reserved
             10 = Reserved
             11 = Write allocation enabled

Bits 23-16: Reserved

Bit 15 (IE):  Instruction Cache Enable
             0 = Instruction cache disabled
             1 = Instruction cache enabled

Bit 14 (IF):  Instruction Cache Freeze
             0 = Instruction cache updates normally
             1 = Instruction cache frozen

Bit 13 (IBE): Instruction Burst Enable
             0 = Instruction burst transfers disabled
             1 = Instruction burst transfers enabled

Bits 12-4: Reserved

Bit 3 (CDE):  Clear Data Cache Entry (write-only, auto-clears)
             Write 1 to clear D-cache entry

Bit 2 (CIE):  Clear Instruction Cache Entry (write-only, auto-clears)
             Write 1 to clear I-cache entry

Bit 1 (CD):   Clear Data Cache (write-only, auto-clears)
             Write 1 to invalidate entire D-cache

Bit 0 (CI):   Clear Instruction Cache (write-only, auto-clears)
             Write 1 to invalidate entire I-cache
```

**Notes:**
- Bits 3-0 are write-only and automatically clear after one cycle
- Writing to these bits triggers cache invalidation operations
- Cache must be disabled before clearing

### TC - Translation Control (0x003)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000
**68040 Only**

Controls the MMU translation mechanism.

**Bit Fields:**

```
Bit 31 (E):   Enable Translation
             0 = Address translation disabled (all accesses bypass MMU)
             1 = Address translation enabled

Bits 30-16: Reserved

Bit 15 (P):   Page Size
             0 = 4 KB pages
             1 = 8 KB pages

Bits 14-0: Reserved
```

**Notes:**
- TG68040 currently only supports 4 KB pages (bit 15 = 0)
- When E=0, all accesses use physical addresses

### ITT0, ITT1 - Instruction Transparent Translation (0x004, 0x005)

**Width:** 32 bits each
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000
**68040 Only**

Define address ranges that bypass normal MMU translation for instruction accesses.

**Bit Fields:**

```
Bits 31-24 (BASE):  Logical Address Base
                   Upper 8 bits of address range

Bits 23-16 (MASK):  Logical Address Mask
                   Address mask (1 = don't care bit)

Bit 15 (E):        Enable
                   0 = This TTR disabled
                   1 = This TTR enabled

Bits 14-13: Reserved

Bits 12-10 (FCB):  Function Code Base
                   Required function code

Bits 9-8 (FCM):    Function Code Mask
                   Function code mask (1 = don't care)

Bits 7-5: Reserved

Bit 4 (S):         Supervisor Mode
                   0 = Do not match supervisor mode
                   1 = Match supervisor mode

Bit 3 (U):         User Mode
                   0 = Do not match user mode
                   1 = Match user mode

Bit 2 (CI):        Cache Inhibit
                   0 = Caching allowed for this range
                   1 = Caching inhibited for this range

Bit 1 (WP):        Write Protect
                   0 = Writes allowed
                   1 = Writes generate access fault

Bit 0: Reserved
```

**Address Matching:**
```
if ((logical_addr[31:24] & ~MASK) == (BASE & ~MASK)) and
   ((FC & ~FCM) == (FCB & ~FCM)) and
   (S and supervisor) or (U and user) then
       Use transparent translation
```

### DTT0, DTT1 - Data Transparent Translation (0x006, 0x007)

**Width:** 32 bits each
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000
**68040 Only**

Define address ranges that bypass normal MMU translation for data accesses.

**Bit Fields:** Same as ITT0/ITT1

**Notes:**
- DTT registers are checked for data accesses
- ITT registers are checked for instruction fetches
- Transparent translation has priority over normal translation

### USP - User Stack Pointer (0x800)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** Undefined

Holds the user mode A7 stack pointer when in supervisor mode.

**Notes:**
- Automatically swapped with A7 on mode changes
- Must be explicitly saved/restored in exception handlers

### VBR - Vector Base Register (0x801)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000

Provides the base address for the exception vector table.

**Bit Fields:**
```
Bits 31-0: Vector table base address
```

**Exception Vector Address Calculation:**
```
vector_address = VBR + (vector_number × 4)
```

**Notes:**
- 68000 uses fixed vector table at address 0
- 68010+ use VBR for relocatable vectors
- VBR should be aligned to at least 4-byte boundary

### MSP - Master Stack Pointer (0x803)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** Undefined

Alternative supervisor stack pointer (when using separate stacks).

### ISP - Interrupt Stack Pointer (0x804)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** Undefined

Interrupt handler stack pointer (when using separate stacks).

### MMUSR - MMU Status Register (0x805)

**Width:** 16 bits (bits 15-0 significant)
**Access:** Supervisor Read Only
**Reset Value:** 0x0000
**68040 Only**

Reports the status of the last MMU operation or table search.

**Bit Fields:**

```
Bit 15 (B):   Bus Error
             1 = Bus error occurred during table search

Bit 14 (L):   Limit Violation
             1 = Table limit exceeded

Bit 13 (S):   Supervisor Violation
             1 = Supervisor protection violation

Bit 12 (W):   Write Protect Violation
             1 = Write to write-protected page

Bit 11 (I):   Invalid
             1 = Invalid descriptor encountered

Bit 10 (M):   Modified
             1 = Page has been modified

Bits 9-8 (T): Transparent Translation Hit
             00 = No transparent hit
             01 = TTR0 hit
             10 = TTR1 hit
             11 = Reserved

Bits 7-0: Reserved
```

**Notes:**
- Read-only register, updated by MMU hardware
- Used by operating system after page faults

### URP - User Root Pointer (0x806)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000
**68040 Only**

Points to the root of the user page table tree.

**Bit Fields:**

```
Bits 31-0: Physical address of user root pointer table
```

**Notes:**
- Used when accessing user mode pages
- Should be page-aligned (4 KB)

### SRP - Supervisor Root Pointer (0x807)

**Width:** 32 bits
**Access:** Supervisor Read/Write
**Reset Value:** 0x00000000
**68040 Only**

Points to the root of the supervisor page table tree.

**Bit Fields:**

```
Bits 31-0: Physical address of supervisor root pointer table
```

**Notes:**
- Used when accessing supervisor mode pages
- Should be page-aligned (4 KB)

## Access Restrictions

### Privilege Levels

All control registers require supervisor privilege:
- **MOVEC** instruction can only execute in supervisor mode
- User mode attempts cause **Privilege Violation** exception
- Exception vector: 8 (privilege violation)

### CPU Mode Restrictions

Some registers are only available in specific CPU modes:

**68000 mode (CPU = "00"):**
- No control registers supported (MOVEC not implemented)

**68010 mode (CPU = "01"):**
- SFC, DFC, USP, VBR, MSP, ISP

**68020 mode (CPU = "11"):**
- All 68010 registers plus CACR (16-bit)

**68040 mode (CPU = "10"):**
- All registers listed in this document
- CACR extended to 32 bits
- TC, ITT0/1, DTT0/1, MMUSR, URP, SRP added

### Invalid Register Access

Attempting to access an invalid or unsupported register results in:
- `movec_valid` signal = 0
- Operation ignored
- May cause **Illegal Instruction** exception (implementation dependent)

## Usage Examples

### Initialize Caches (68040)

```assembly
; Enable both I-cache and D-cache
MOVE.L  #$80008000, D0     ; DE=1, IE=1
MOVEC   D0, CACR           ; Write to CACR
```

### Clear Instruction Cache

```assembly
; Clear I-cache
MOVE.L  #$00000001, D0     ; CI=1
MOVEC   D0, CACR           ; Write to CACR
; Bit auto-clears after one cycle
```

### Setup Transparent Translation

```assembly
; Map I/O region 0xFF000000-0xFFFFFFFF as transparent
; No caching, supervisor only
MOVE.L  #$FF00C040, D0     ; BASE=FF, MASK=00, E=1, S=1, CI=1
MOVEC   D0, DTT0           ; Write to DTT0
```

### Enable MMU

```assembly
; Set up root pointers first
MOVE.L  #PageTableBase, D0
MOVEC   D0, SRP            ; Supervisor root pointer
MOVEC   D0, URP            ; User root pointer (can be different)

; Enable translation with 4KB pages
MOVE.L  #$80000000, D0     ; E=1, P=0
MOVEC   D0, TC             ; Enable MMU
```

### Read MMU Status After Page Fault

```assembly
; In page fault handler
MOVEC   MMUSR, D0          ; Read MMU status
BTST    #11, D0            ; Test Invalid bit
BNE     page_not_present   ; Branch if page invalid
```

## Implementation Notes (TG68040)

### Current Implementation Status

**Phase 1 (Complete):**
- ✅ All control registers defined
- ✅ MOVEC read/write support
- ✅ Privilege checking
- ✅ CPU mode checking
- ✅ CACR auto-clear bits

**Future Phases:**
- ⏳ Actual cache control logic (Phase 5-7)
- ⏳ MMU translation logic (Phase 8-9)
- ⏳ TTR matching logic (Phase 8-9)

### Differences from Real MC68040

1. **TLB Size:** 16 entries vs 64 in real 68040
2. **Page Size:** 4 KB only initially (8 KB support deferred)
3. **Cache:** Direct-mapped initially (vs 4-way set-associative)
4. **MMUSR:** Simplified implementation

### Reset Values

| Register | Reset Value | Notes |
|----------|-------------|-------|
| SFC | 0 | |
| DFC | 0 | |
| CACR | 0x00000000 | Caches disabled |
| TC | 0x00000000 | MMU disabled |
| ITT0/1 | 0x00000000 | Transparent xlate disabled |
| DTT0/1 | 0x00000000 | Transparent xlate disabled |
| USP | Undefined | Should be initialized by software |
| VBR | 0x00000000 | Vectors at address 0 |
| MSP | Undefined | Should be initialized |
| ISP | Undefined | Should be initialized |
| MMUSR | 0x0000 | No status |
| URP | 0x00000000 | Page tables not initialized |
| SRP | 0x00000000 | Page tables not initialized |

## References

1. MC68040 User's Manual, Section 3: Control Registers
2. M68000 Family Programmer's Reference Manual
3. TG68040 Implementation Plan, Phase 1

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** Phase 1 Complete
