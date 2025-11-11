# MC68030 MMU Translation Architecture

## Document Purpose

This document specifies the MC68030 Memory Management Unit (MMU) address translation architecture, including the Address Translation Cache (ATC), transparent translation, and page table walk logic.

---

## Overview

The MC68030 MMU translates virtual (logical) addresses to physical addresses, providing:
- Virtual memory support
- Memory protection
- Multiple address spaces
- Demand-paged memory

### Key Components

| Component | Description | Size |
|-----------|-------------|------|
| **ATC** | Address Translation Cache | 22 entries |
| **TT0/TT1** | Transparent Translation Registers | 2 registers |
| **TC** | Translation Control Register | Configuration |
| **CRP/SRP** | Root Pointers | Point to page tables |
| **Table Walk** | Hardware page table walker | Multi-level |

---

## Translation Flow

### High-Level Flow

```
Virtual Address
    ↓
1. Check TT0/TT1 (Transparent Translation)
    → If match: Use address directly (bypass MMU)
    ↓
2. Check ATC (Translation Cache)
    → If hit: Use cached translation (fast)
    ↓
3. Page Table Walk (on ATC miss)
    → Traverse page tables
    → Load translation
    → Store in ATC
    ↓
Physical Address
```

### Translation Steps

```
IF TC.E = 0 THEN
    -- MMU disabled, use virtual address as physical
    physical_address = virtual_address
    RETURN
END IF

-- Check transparent translation
IF TT0_matches(virtual_address, function_code) THEN
    physical_address = virtual_address  -- Bypass MMU
    RETURN
ELSIF TT1_matches(virtual_address, function_code) THEN
    physical_address = virtual_address  -- Bypass MMU
    RETURN
END IF

-- Check ATC
IF ATC_hit(virtual_address, function_code) THEN
    physical_address = ATC_translate(virtual_address)
    RETURN  -- Fast path (1-2 cycles)
END IF

-- ATC miss: Perform table walk
physical_address = table_walk(virtual_address, function_code)
ATC_load(virtual_address, physical_address, attributes)
RETURN
```

---

## Address Translation Cache (ATC)

### Purpose

The ATC caches recent address translations to avoid repeated table walks.

### Characteristics

| Property | Value |
|----------|-------|
| **Entries** | 22 |
| **Organization** | Fully associative |
| **Replacement** | Random or FIFO |
| **Invalidation** | Via PFLUSH instruction |
| **Load** | On table walk completion |

### ATC Entry Structure

Each ATC entry contains:

```vhdl
type atc_entry_t is record
    valid       : std_logic;                      -- Entry valid
    logical_addr: std_logic_vector(31 downto 8);  -- Virtual address tag (24 bits)
    physical_addr:std_logic_vector(31 downto 8);  -- Physical address (24 bits)
    function_code:std_logic_vector(2 downto 0);   -- Function code

    -- Attributes (from page descriptor)
    write_protect: std_logic;                     -- Write protected
    supervisor   : std_logic;                     -- Supervisor only
    cache_inhibit: std_logic;                     -- Don't cache
    modified     : std_logic;                     -- Page modified
    used         : std_logic;                     -- Page accessed
end record;
```

### ATC Lookup

```vhdl
PROCEDURE atc_lookup(
    virtual_addr : std_logic_vector(31 downto 0);
    fc           : std_logic_vector(2 downto 0);
    OUT hit      : std_logic;
    OUT entry    : atc_entry_t
) IS
BEGIN
    FOR i IN 0 TO 21 LOOP
        IF atc(i).valid = '1' AND
           atc(i).logical_addr = virtual_addr(31 DOWNTO 8) AND
           atc(i).function_code = fc THEN
            hit := '1';
            entry := atc(i);
            RETURN;
        END IF;
    END LOOP;

    hit := '0';
END PROCEDURE;
```

### ATC Load

```vhdl
PROCEDURE atc_load(
    virtual_addr  : std_logic_vector(31 downto 0);
    physical_addr : std_logic_vector(31 downto 0);
    fc            : std_logic_vector(2 downto 0);
    attributes    : descriptor_attributes_t
) IS
    VARIABLE victim : integer RANGE 0 TO 21;
BEGIN
    -- Find victim entry (random or FIFO)
    victim := find_victim_entry();

    -- Load new entry
    atc(victim).valid        := '1';
    atc(victim).logical_addr := virtual_addr(31 DOWNTO 8);
    atc(victim).physical_addr:= physical_addr(31 DOWNTO 8);
    atc(victim).function_code:= fc;
    atc(victim).write_protect:= attributes.wp;
    atc(victim).supervisor   := attributes.s;
    atc(victim).cache_inhibit:= attributes.ci;
    atc(victim).modified     := attributes.m;
    atc(victim).used         := attributes.u;
END PROCEDURE;
```

### ATC Invalidation

**PFLUSHA**: Invalidate all entries
```vhdl
FOR i IN 0 TO 21 LOOP
    atc(i).valid := '0';
END LOOP;
```

**PFLUSH FC**: Invalidate entries matching function code
```vhdl
FOR i IN 0 TO 21 LOOP
    IF atc(i).function_code = fc THEN
        atc(i).valid := '0';
    END IF;
END LOOP;
```

**PFLUSH FC,EA**: Invalidate specific entry
```vhdl
FOR i IN 0 TO 21 LOOP
    IF atc(i).logical_addr = virtual_addr(31 DOWNTO 8) AND
       atc(i).function_code = fc THEN
        atc(i).valid := '0';
    END IF;
END LOOP;
```

---

## Transparent Translation

### Purpose

Transparent translation allows certain address ranges to bypass the MMU entirely, useful for:
- I/O regions (always physical addresses)
- ROM (no translation needed)
- Fast access to known physical memory

### TT0 and TT1 Registers

Two transparent translation registers (see `registers/MMU_REGISTERS.md`):

```
 31  30  29  28  27  26  25  24  23-16      15-8        7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───────┬───────────┬───┬───┬───┬───┬───┬───┬───┬───┐
│ E │ S/U CI │R/W│ 0   0 │Logical│Logical│FC │FC │FC │FC │ 0   0   0   0   0   0   0 │
│   │     │  │   │       │Address│ Mask  │Base│Mask│   │   │                           │
└───┴───┴───┴───┴───┴───┴───┴───┴───────┴───────────┴───┴───┴───┴───┴───┴───┴───┴───┘
```

- **E (bit 31)**: Enable transparent translation
- **S/U (bit 30)**: Supervisor (1) or User (0) mode
- **CI (bit 29)**: Cache inhibit
- **R/W (bit 28)**: Read/Write (0 = read-only, 1 = read/write)
- **Logical Address (bits 23-16)**: Address bits to match
- **Logical Mask (bits 15-8)**: Which address bits to compare
- **FC Base (bits 7-4)**: Function code to match
- **FC Mask (bits 3-0)**: Which FC bits to compare

### Transparent Translation Match

```vhdl
FUNCTION tt_match(
    tt_reg       : std_logic_vector(31 downto 0);
    virtual_addr : std_logic_vector(31 downto 0);
    fc           : std_logic_vector(2 downto 0)
) RETURN boolean IS
    VARIABLE tt_enable   : std_logic;
    VARIABLE tt_addr     : std_logic_vector(7 downto 0);
    VARIABLE tt_mask     : std_logic_vector(7 downto 0);
    VARIABLE tt_fc_base  : std_logic_vector(3 downto 0);
    VARIABLE tt_fc_mask  : std_logic_vector(3 downto 0);
BEGIN
    tt_enable  := tt_reg(31);
    tt_addr    := tt_reg(23 downto 16);
    tt_mask    := tt_reg(15 downto 8);
    tt_fc_base := tt_reg(7 downto 4);
    tt_fc_mask := tt_reg(3 downto 0);

    -- Check if enabled
    IF tt_enable = '0' THEN
        RETURN false;
    END IF;

    -- Check address match (with mask)
    FOR i IN 0 TO 7 LOOP
        IF tt_mask(i) = '1' THEN
            IF virtual_addr(24+i) /= tt_addr(i) THEN
                RETURN false;
            END IF;
        END IF;
    END LOOP;

    -- Check function code match (with mask)
    FOR i IN 0 TO 2 LOOP
        IF tt_fc_mask(i) = '1' THEN
            IF fc(i) /= tt_fc_base(i) THEN
                RETURN false;
            END IF;
        END IF;
    END LOOP;

    RETURN true;
END FUNCTION;
```

### Example: Map I/O Region

```assembly
; Map 0x00FF0000-0x00FFFFFF (1MB I/O space) transparent
; Any access in this range bypasses MMU

; TT0: E=1, S=1 (supervisor), CI=1 (cache inhibit), R/W=1 (read/write)
;      Address=0xFF (match bits 31-24), Mask=0xFF (compare all 8 bits)
;      FC=5 (supervisor data), FC_Mask=7 (compare all 3 bits)

MOVE.L  #$E3FF_FF57,D0    ; Build TT0 value
MOVEC   D0,TT0            ; Load TT0

; Now accesses to 0x00FFxxxx in supervisor data space
; use virtual address as physical (bypass MMU)
```

---

## Page Table Walk

### Purpose

When translation not in ATC or transparent, perform table walk to find translation in page tables.

### Translation Control (TC Register)

Controls table walk behavior:

```
 31  30  29-24  23-20  19-16  15-12  11-8   7-4    3-0
┌───┬───┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ E │SRE│  0   │  IS  │  TIA │  TIB │  TIC │  TID │ PS   │
└───┴───┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

- **E**: Enable MMU
- **SRE**: Supervisor Root pointer Enable (use SRP in supervisor mode)
- **IS**: Initial Shift (page size = 256 bytes × 2^IS)
- **TIA, TIB, TIC, TID**: Table Index bits for each level
- **PS**: Page Size (256, 512, 1K, 2K, 4K, 8K, 16K, 32K)

### Table Levels

MC68030 supports up to 4 table levels (A, B, C, D):

```
Virtual Address
    ↓
Root Pointer (CRP or SRP)
    ↓
Level A Table (if TIA > 0)
    ↓
Level B Table (if TIB > 0)
    ↓
Level C Table (if TIC > 0)
    ↓
Level D Table / Page Descriptor
    ↓
Physical Address
```

### Typical 3-Level Configuration

```
TIA = 7 bits  (128 entries in A-table)
TIB = 7 bits  (128 entries in B-table)
TIC = 7 bits  (128 entries in C-table)
PS  = 4K page

Virtual Address [31:0]:
  [31:24] = A-table index (8 bits, use lower 7)
  [23:16] = B-table index (8 bits, use lower 7)
  [15:12] = C-table index (upper 4 of 8 bits)
  [11:0]  = Offset within page (4K = 12 bits)
```

### Page Table Walk Algorithm

```vhdl
FUNCTION table_walk(
    virtual_addr : std_logic_vector(31 downto 0);
    fc           : std_logic_vector(2 downto 0)
) RETURN std_logic_vector(31 downto 0) IS
    VARIABLE descriptor_addr : std_logic_vector(31 downto 0);
    VARIABLE descriptor      : std_logic_vector(31 downto 0);
    VARIABLE table_index     : integer;
BEGIN
    -- Start with root pointer (CRP or SRP based on FC)
    IF fc(2) = '1' AND tc.sre = '1' THEN
        descriptor_addr := srp(63 DOWNTO 32);  -- Use SRP
    ELSE
        descriptor_addr := crp(63 DOWNTO 32);  -- Use CRP
    END IF;

    -- Level A (if TIA > 0)
    IF tc.tia > 0 THEN
        table_index := extract_index(virtual_addr, tc.is, tc.tia);
        descriptor_addr := descriptor_addr + (table_index * 4);
        descriptor := read_memory(descriptor_addr);

        IF descriptor.dt = invalid THEN
            RAISE invalid_descriptor_exception;
        END IF;

        descriptor_addr := descriptor(31 DOWNTO 4) & "0000";
    END IF;

    -- Level B (if TIB > 0)
    IF tc.tib > 0 THEN
        table_index := extract_index(virtual_addr, tc.is + tc.tia, tc.tib);
        descriptor_addr := descriptor_addr + (table_index * 4);
        descriptor := read_memory(descriptor_addr);

        IF descriptor.dt = invalid THEN
            RAISE invalid_descriptor_exception;
        END IF;

        descriptor_addr := descriptor(31 DOWNTO 4) & "0000";
    END IF;

    -- Level C (if TIC > 0)
    IF tc.tic > 0 THEN
        table_index := extract_index(virtual_addr, tc.is + tc.tia + tc.tib, tc.tic);
        descriptor_addr := descriptor_addr + (table_index * 4);
        descriptor := read_memory(descriptor_addr);

        IF descriptor.dt = invalid THEN
            RAISE invalid_descriptor_exception;
        END IF;

        descriptor_addr := descriptor(31 DOWNTO 4) & "0000";
    END IF;

    -- Final page descriptor
    table_index := extract_index(virtual_addr, tc.is + tc.tia + tc.tib + tc.tic,
                                  page_size_bits);
    descriptor_addr := descriptor_addr + (table_index * 4);
    descriptor := read_memory(descriptor_addr);

    IF descriptor.dt /= page THEN
        RAISE invalid_descriptor_exception;
    END IF;

    -- Check protection
    IF descriptor.wp = '1' AND is_write_access THEN
        RAISE write_protect_exception;
    END IF;

    IF descriptor.s = '1' AND fc(2) = '0' THEN
        RAISE supervisor_violation_exception;
    END IF;

    -- Build physical address
    physical_address := descriptor(31 DOWNTO page_size_bits) &
                        virtual_addr(page_size_bits-1 DOWNTO 0);

    RETURN physical_address;
END FUNCTION;
```

### Descriptor Formats

**Table Descriptor** (points to next table):
```
 31-4: Pointer to next table (16-byte aligned)
 3: U (Used)
 2: WP (Write Protected)
 1-0: DT (00=invalid, 01=page, 10=valid4, 11=valid8)
```

**Page Descriptor** (final translation):
```
 31-8: Physical page address
 7: M (Modified)
 6: U (Used)
 5: WP (Write Protected)
 4: S (Supervisor)
 3: CI (Cache Inhibit)
 2-0: DT (01=page descriptor)
```

---

## Translation Exceptions

### Exception Types

| Exception | Vector | Cause |
|-----------|--------|-------|
| **Invalid Descriptor** | $31 | DT field invalid |
| **Write Protect** | $2A | Write to WP page |
| **Supervisor Violation** | $2B | User access to S page |
| **Limit Violation** | $31 | Index exceeds table limit |
| **Bus Error** | $02 | Error reading descriptor |

### MMUSR Update

On exception or PTEST, update MMUSR:

```vhdl
mmusr(15) := bus_error;           -- B bit
mmusr(14) := limit_violation;     -- L bit
mmusr(13) := supervisor_violation;-- S bit
mmusr(12) := write_protect;       -- W bit
mmusr(11) := invalid_descriptor;  -- I bit
mmusr(10) := modified;            -- M bit
mmusr(9)  := '0';                 -- G bit (not used)
mmusr(8 downto 7) := transparent; -- T bits
mmusr(6)  := atc_hit;             -- C bit
mmusr(5)  := resident;            -- R bit
```

---

## Integration with Instructions

### PMOVE Integration

PMOVE (Phase 3) reads/writes MMU registers:
- **TC**: Configure table walk
- **TT0/TT1**: Configure transparent translation
- **CRP/SRP**: Set root pointers
- **MMUSR**: Read translation status

### PFLUSH Integration

PFLUSH (Phase 3) invalidates ATC entries:
- **PFLUSHA**: Invalidate all 22 entries
- **PFLUSH FC**: Invalidate entries matching FC
- **PFLUSH FC,EA**: Invalidate specific entry

### PTEST Integration

PTEST (Phase 3) tests translation:
- Perform table walk (or check ATC)
- Update MMUSR with results
- Return descriptor address (if requested)
- No exceptions (safe testing)

---

## Implementation Modules

### TG68K030_ATC.vhd
- 22-entry fully associative ATC
- Lookup logic (parallel search)
- Load logic (victim selection)
- Invalidation logic (PFLUSH interface)

### TG68K030_TransparentTranslation.vhd
- TT0 and TT1 match logic
- Address and FC comparison with masks
- Priority: TT0 first, then TT1

### TG68K030_TableWalk.vhd
- Multi-level page table walker
- Descriptor fetch and validation
- Exception generation
- ATC loading on success

### TG68K030_MMU.vhd (Top-level)
- Combines ATC, transparent translation, and table walk
- Translation request interface
- Physical address output
- Exception signaling

---

## Performance Characteristics

### Translation Latency

| Scenario | Cycles (Typical) |
|----------|------------------|
| Transparent translation | 0 cycles (bypass) |
| ATC hit | 1-2 cycles |
| ATC miss, 1-level walk | 3-5 cycles |
| ATC miss, 2-level walk | 6-10 cycles |
| ATC miss, 3-level walk | 9-15 cycles |

### ATC Hit Rates

Typical ATC hit rates:
- **Well-tuned OS**: 95-98%
- **Average workload**: 85-95%
- **Pathological (thrashing)**: 50-70%

With 95% hit rate and 2-cycle ATC lookup vs 10-cycle table walk:
- Average translation time: 0.95 × 2 + 0.05 × 10 = 2.4 cycles
- vs no ATC: 10 cycles
- **Speedup: 4.2x**

---

## Summary

The MC68030 MMU provides:
- ✅ 22-entry ATC for fast translations
- ✅ Transparent translation for I/O and ROM
- ✅ Flexible page table walking (1-4 levels)
- ✅ Memory protection (WP, S bits)
- ✅ Multiple address spaces (CRP/SRP)
- ✅ Software control (TC, TT0, TT1, PMOVE, PFLUSH, PTEST)

**Next**: Implement ATC, transparent translation, and table walk modules.

---

## References

- MC68030 User's Manual, Section 6 (MMU)
- MC68030 User's Manual, Section 6.1 (Translation)
- MC68030 User's Manual, Section 6.1.3 (ATC)
- MC68030 User's Manual, Section 6.1.4 (Table Walk)
- MMU_REGISTERS.md (TC, TT0, TT1, CRP, SRP, MMUSR)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | MMU translation architecture specification |
