# Phase 9: Memory Management Unit (MMU)

## Overview

**Phase:** 9 of 15
**Goal:** Implement the MC68040 Memory Management Unit for address translation and protection
**Status:** 🔨 IN PROGRESS
**Start Date:** 2025-11-11

## Objectives

Implement a complete MMU subsystem that provides:
1. Virtual to physical address translation
2. Separate instruction and data Address Translation Caches (ATCs)
3. Translation table walking
4. Page-level memory protection
5. Access control and privilege checking
6. TLB miss handling

## MC68040 MMU Architecture

### Address Translation Cache (ATC)

The MC68040 has separate ATCs for instruction and data accesses:

**I-ATC (Instruction ATC):**
- 64 entries
- Fully associative
- Caches instruction address translations
- Invalidated on instruction cache invalidation

**D-ATC (Data ATC):**
- 64 entries
- Fully associative
- Caches data address translations
- Invalidated on data cache flush

**ATC Entry Format:**
```
Logical Address Tag: [31:12] (20 bits)
Physical Page Frame: [31:12] (20 bits)
Valid bit
Modified bit
User/Supervisor
Write Protected
Cache Inhibit
Cache Mode (2 bits)
```

### Translation Table Structure

The MC68040 uses a 3-level or 4-level page table structure:

**Page Table Levels:**
1. **Root Pointer** - Points to top-level table
2. **Pointer Tables** - Point to next level
3. **Page Tables** - Point to actual pages
4. **Page Descriptors** - Describe individual pages

**Descriptor Types:**
- **Table Descriptor** - Points to next table level
- **Page Descriptor** - Maps to physical page
- **Invalid Descriptor** - Access fault

**Page Sizes:**
- 4KB pages (most common)
- 8KB pages
- Variable page sizes via descriptor

### Translation Process

1. **ATC Lookup:**
   - Check if virtual address is in ATC
   - If hit: Use cached translation
   - If miss: Perform table walk

2. **Table Walk:**
   - Start from Root Pointer (in TC register)
   - Index into appropriate table level
   - Follow pointers to next level
   - Retrieve page descriptor
   - Cache result in ATC

3. **Address Translation:**
   - Extract page frame from descriptor
   - Combine with page offset
   - Return physical address

### Protection and Access Control

**Protection Bits:**
- **Write Protect (WP)** - Page is read-only
- **User/Supervisor (U/S)** - Access level required
- **Modified (M)** - Page has been written
- **Used (U)** - Page has been accessed

**Access Checks:**
- Supervisor vs User mode
- Read vs Write access
- Privilege level matching
- Write protection enforcement

**Fault Conditions:**
- Invalid descriptor (page not present)
- Protection violation (insufficient privilege)
- Write to read-only page
- Bus error on table walk

### Cache Control

**Cache Inhibit (CI):**
- Prevents caching of this page
- Used for I/O mapped regions

**Cache Mode:**
- Writethrough
- Copyback
- Non-cacheable
- Writethrough with allocate

## Implementation Strategy

### Phase 9.1: ATC Implementation (Stub)

Create basic ATC structures with simple lookup:

**TG68040_ATC.vhd:**
- 64-entry fully associative cache
- Tag comparison logic
- LRU replacement
- Invalidation support

**Features:**
- Direct translation (1:1 virtual to physical)
- Always-hit behavior initially
- Statistics tracking

### Phase 9.2: MMU Control Registers

**TC (Translation Control):**
- Enable bit
- Page size
- Function code matching

**Root Pointers:**
- SRP (Supervisor Root Pointer)
- URP (User Root Pointer)

**Status Registers:**
- MMUSR (MMU Status Register)
- Fault address
- Fault status

### Phase 9.3: Table Walk Logic

**TG68040_TableWalk.vhd:**
- State machine for multi-cycle table walk
- Descriptor fetch from memory
- Descriptor decoding
- Multi-level traversal

**Table Walk States:**
1. IDLE - Waiting for request
2. FETCH_L1 - Fetch level 1 descriptor
3. FETCH_L2 - Fetch level 2 descriptor
4. FETCH_L3 - Fetch level 3 descriptor
5. UPDATE_ATC - Update ATC with result
6. FAULT - Handle translation fault

### Phase 9.4: Protection Logic

**TG68040_MMU_Protection.vhd:**
- Access permission checking
- Privilege level enforcement
- Write protection
- Modified/Used bit handling

### Phase 9.5: Pipeline Integration

**Integration Points:**
- **IF Stage:** I-ATC lookup for instruction fetch
- **EA Stage:** D-ATC lookup for memory operands
- **Memory Access:** Physical address generation

**Pipeline Impact:**
- ATC hit: 0 cycle penalty
- ATC miss: Table walk (2-4 cycles)
- TLB fault: Exception handling

## Deliverables

### Source Code

1. **TG68040_MMU_Pack.vhd** - MMU types and constants
   - ATC entry type
   - Descriptor types
   - MMU register definitions
   - Protection bits

2. **TG68040_ATC.vhd** - Address Translation Cache
   - 64-entry fully associative
   - Tag comparison
   - LRU replacement
   - Invalidation

3. **TG68040_IATC.vhd** - Instruction ATC wrapper
   - Specialized for instruction addresses
   - Integrated with I-Cache

4. **TG68040_DATC.vhd** - Data ATC wrapper
   - Specialized for data addresses
   - Integrated with D-Cache

5. **TG68040_MMU.vhd** - Complete MMU unit
   - Combines I-ATC and D-ATC
   - Control registers
   - Table walk logic (stub)
   - Protection checking

### Test Code

1. **test_ATC.vhd** - ATC unit tests
   - Lookup hit/miss
   - Entry replacement
   - Invalidation
   - LRU verification

2. **test_MMU.vhd** - MMU integration tests
   - Address translation
   - Protection checks
   - ATC miss handling

### Documentation

1. **PHASE9_README.md** - This file
2. **PHASE9_SUMMARY.md** - Phase completion summary

## Implementation Phases

### Phase 9A: Basic ATC (Stub)

**Goal:** Create ATC structures with 1:1 translation

**Tasks:**
1. Create MMU package with types
2. Implement basic ATC (always hit)
3. Create I-ATC and D-ATC wrappers
4. Add ATC lookup in pipeline
5. Unit tests for ATC

**Estimated Time:** 2-3 days

### Phase 9B: MMU Control

**Goal:** Add MMU control registers and enable/disable

**Tasks:**
1. Implement TC register
2. Implement root pointers
3. Add MMU enable/disable logic
4. Add bypass mode for disabled MMU
5. Control register tests

**Estimated Time:** 1-2 days

### Phase 9C: Table Walk (Stub)

**Goal:** Basic table walk state machine (simplified)

**Tasks:**
1. Create table walk state machine
2. Implement descriptor fetch (stub)
3. Add ATC update on walk complete
4. Handle table walk misses
5. Table walk tests

**Estimated Time:** 2-3 days

### Phase 9D: Protection Logic

**Goal:** Access protection and privilege checking

**Tasks:**
1. Implement protection bit checking
2. Add privilege level enforcement
3. Implement write protection
4. Add fault generation
5. Protection tests

**Estimated Time:** 1-2 days

## MC68040 MMU Specifications

### Address Space

- **Logical Address Space:** 4GB (32-bit)
- **Physical Address Space:** 4GB (32-bit)
- **Page Size:** 4KB typical (4096 bytes)
- **Page Offset:** 12 bits [11:0]
- **Virtual Page Number:** 20 bits [31:12]

### Translation Table

**Root Pointer Descriptor:**
```
Bits [31:4] - Table Address (aligned to 16 bytes)
Bits [3:2]  - Reserved
Bits [1:0]  - Descriptor Type (01 = Valid, 00 = Invalid)
```

**Table Descriptor:**
```
Bits [31:4] - Next Table Address
Bits [3]    - Write Protect (WP)
Bits [2]    - Used (U)
Bits [1:0]  - Descriptor Type (01 = Valid Table)
```

**Page Descriptor:**
```
Bits [31:12] - Physical Page Frame
Bits [11:8]  - Reserved
Bit [7]      - Modified (M)
Bit [6]      - Used (U)
Bit [5]      - Write Protect (WP)
Bit [4]      - User/Supervisor (U/S)
Bits [3:2]   - Cache Mode
Bit [1]      - Cache Inhibit (CI)
Bit [0]      - Valid
```

### Cache Modes

- **00** - Writethrough, no allocate on write miss
- **01** - Copyback (writeback)
- **10** - Cache inhibited (non-cacheable)
- **11** - Writethrough with allocate on write

### MMU Faults

**Fault Types:**
1. **Invalid Descriptor** - Descriptor type = 00
2. **Protection Violation** - Insufficient privilege or write to RO page
3. **Bus Error** - Bus error during table walk
4. **ATC Fault** - ATC entry marked as fault

**Fault Handling:**
- Generate exception
- Save fault address in MMUSR
- Save fault status (read/write, supervisor/user)
- Vector to fault handler

## Performance Considerations

### ATC Hit Rate

Expected ATC hit rates:
- Sequential code: 95-98%
- Random access: 70-85%
- Context switches: 50-60% (until ATC refills)

### Translation Overhead

- **ATC Hit:** 0 cycles (parallel with cache access)
- **ATC Miss:** 2-4 cycles (simplified table walk)
- **TLB Fault:** 20+ cycles (exception handling)

### CPI Impact

With 90% ATC hit rate:
- Average translation overhead: 0.2-0.4 cycles per memory access
- Overall CPI impact: +0.1-0.3

## Testing Strategy

### Unit Tests

1. **ATC Tests:**
   - Basic lookup (hit/miss)
   - Entry replacement
   - Invalidation (single/all)
   - LRU behavior
   - Tag matching

2. **Protection Tests:**
   - User vs Supervisor
   - Read-only enforcement
   - Write protection
   - Cache inhibit

3. **Translation Tests:**
   - 1:1 translation
   - Page offset extraction
   - Physical address generation

### Integration Tests

1. **Pipeline Integration:**
   - I-ATC with instruction fetch
   - D-ATC with data access
   - Cache + ATC combined

2. **Performance Tests:**
   - ATC hit rate measurement
   - Translation overhead
   - Flush/invalidate impact

## Success Criteria

Phase 9 is complete when:

1. ✅ ATC structures implemented and tested
2. ✅ I-ATC and D-ATC wrappers created
3. ✅ MMU control registers functional
4. ✅ Basic 1:1 address translation working
5. ✅ Protection checking implemented (stub)
6. ✅ Pipeline integration complete
7. ✅ All unit tests passing
8. ✅ Documentation complete

## References

- MC68040 User's Manual, Chapter 3: Memory Management Unit
- MC68040 User's Manual, Section 3.1: Address Translation
- MC68040 User's Manual, Section 3.2: ATC Organization
- MC68040 User's Manual, Section 3.3: Table Search

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Author:** Claude AI (Anthropic)
