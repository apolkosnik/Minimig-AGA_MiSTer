# Phase 2: New Instructions (Simple)

## Overview

**Phase:** 2 of 15
**Goal:** Implement 68040-specific integer instructions that don't exist in 68020
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-18 (7 days)

## Objectives

1. ⏳ Decode new 68040-specific opcodes (MOVE16, CINV, CPUSH)
2. ⏳ Implement MOVE16 for memory-to-memory transfers
3. ⏳ Add cache control instruction stubs (CINV, CPUSH)
4. ⏳ Update instruction decoder with new opcodes
5. ⏳ Create comprehensive unit tests

## New Instructions

### 1. MOVE16 - Move 16-Byte Block

**Opcode Format:**
```
1111 0110 00xx xxxx
```

**Description:** Moves 16 bytes (cache line size) between memory locations using aligned transfers. This instruction is optimized for cache-line operations.

**Addressing Modes:**
- `MOVE16 (An)+, (xxx).L` - Postincrement source
- `MOVE16 (xxx).L, (An)+` - Postincrement destination
- `MOVE16 (An), (xxx).L` - Absolute addressing
- `MOVE16 (xxx).L, (An)` - Absolute addressing

**Key Features:**
- Transfers exactly 16 bytes (128 bits)
- Addresses must be 16-byte aligned (bits 3-0 = 0)
- If misaligned, address error exception occurs
- Atomic operation (bus locked during transfer)
- Bypasses data cache (operates on cache lines)

**Timing:**
- Best case: 2-3 bus cycles (with burst)
- Worst case: 8 bus cycles (without burst)

### 2. CINV - Cache Invalidate

**Opcode Format:**
```
1111 0100 0xx0 1xxx
Scope: 01=line, 10=page, 11=all
Cache: bit 6: 0=data, 1=instruction, both if in supervisor
```

**Description:** Invalidates cache entries without writing them back (data is lost if modified).

**Variants:**
- `CINVL <cache>, (An)` - Invalidate line containing address in An
- `CINVP <cache>, (An)` - Invalidate all lines in page containing An
- `CINVA <cache>` - Invalidate all lines

**Cache Selectors:**
- `DC` - Data cache
- `IC` - Instruction cache
- `BC` - Both caches (supervisor only)

**Key Features:**
- Supervisor only instruction
- Does not write back modified data
- Use CPUSH to write back first if needed
- Immediate effect (no delayed invalidation)

**Use Cases:**
- DMA buffer invalidation
- Self-modifying code
- Memory-mapped I/O coherency

### 3. CPUSH - Cache Push

**Opcode Format:**
```
1111 0100 0xx1 0xxx
Scope: 01=line, 10=page, 11=all
Cache: bit 6: 0=data, 1=instruction
```

**Description:** Writes back modified cache lines to memory, then invalidates them.

**Variants:**
- `CPUSHL <cache>, (An)` - Push line containing address in An
- `CPUSHP <cache>, (An)` - Push all lines in page containing An
- `CPUSHA <cache>` - Push all lines

**Cache Selectors:**
- `DC` - Data cache
- `IC` - Instruction cache (no effect, I-cache is not write-back)
- `BC` - Both caches (supervisor only)

**Key Features:**
- Supervisor only instruction
- Writes back dirty lines before invalidating
- Safe for coherency (preserves modified data)
- I-cache push is a no-op (read-only cache)

**Use Cases:**
- DMA buffer preparation
- Context switches
- Debugger breakpoint insertion

## Deliverables

### Source Files

| File | Status | Description |
|------|--------|-------------|
| `TG68040_Decoder.vhd` | ⏳ Planned | Instruction decoder extension |
| `TG68040_MOVE16.vhd` | ⏳ Planned | MOVE16 execution logic |
| `TG68040_CacheOps.vhd` | ⏳ Planned | CINV/CPUSH execution logic |

### Test Files

| File | Status | Description |
|------|--------|-------------|
| `test_TG68040_Decoder.vhd` | ⏳ Planned | Decoder unit tests |
| `test_MOVE16.vhd` | ⏳ Planned | MOVE16 instruction tests |
| `test_CacheOps.vhd` | ⏳ Planned | CINV/CPUSH tests |

### Documentation

| Document | Status | Description |
|----------|--------|-------------|
| PHASE2_README.md | ✅ Complete | This file |
| INSTRUCTION_SPEC.md | ⏳ Planned | Detailed instruction specifications |
| TEST_REPORT.md | ⏳ Planned | Phase 2 test results |

## Implementation Strategy

### Phase 2A: Instruction Decoder (Days 1-2)

**Tasks:**
1. Extend TG68K decoder to recognize new opcodes
2. Add opcode constants to TG68040_Pack
3. Implement privilege checking for cache ops
4. Create decode state machine extensions

**Outputs:**
- Decoded instruction type
- Addressing mode information
- Cache selector (IC/DC/BC)
- Scope (line/page/all)

### Phase 2B: MOVE16 Implementation (Days 3-4)

**Tasks:**
1. Implement alignment checking
2. Create 16-byte transfer state machine
3. Add bus lock mechanism
4. Implement postincrement addressing
5. Handle address error exceptions

**State Machine:**
```
IDLE → ALIGN_CHECK → LOCK_BUS → TRANSFER_0_3 → TRANSFER_4_7 →
       TRANSFER_8_11 → TRANSFER_12_15 → UNLOCK_BUS → UPDATE_REGS → DONE
```

**Error Handling:**
- Misaligned address → Address Error exception (vector 3)
- Bus error → Bus Error exception (vector 2)

### Phase 2C: Cache Operations Implementation (Days 5-6)

**Tasks:**
1. Implement cache line/page/all invalidation
2. Add privilege checking (supervisor only)
3. Create cache push logic (write-back + invalidate)
4. Interface with CACR register

**For Phase 2 (Stub Implementation):**
- CINV: Set flag in CACR to trigger invalidation
- CPUSH: Set flag in CACR to trigger push
- Actual cache logic deferred to Phase 5-7

**Cache Control Interface:**
```vhdl
-- To cache controller (future)
signal cache_op_enable : std_logic;
signal cache_op_type   : std_logic_vector(1 downto 0); -- 00=none, 01=inv, 10=push
signal cache_op_scope  : std_logic_vector(1 downto 0); -- 00=line, 01=page, 10=all
signal cache_op_which  : std_logic_vector(1 downto 0); -- 00=DC, 01=IC, 10=both
signal cache_op_addr   : std_logic_vector(31 downto 0); -- Address for line/page ops
signal cache_op_done   : std_logic; -- From cache controller
```

### Phase 2D: Testing (Day 7)

**Unit Tests:**
1. Decoder tests for all new opcodes
2. MOVE16 aligned transfer tests
3. MOVE16 misaligned error tests
4. CINV privilege and scope tests
5. CPUSH privilege and scope tests

**Integration Tests:**
1. MOVE16 with real memory
2. Cache op sequence testing
3. Exception handling verification

## Instruction Details

### MOVE16 Encoding

```
Format 1: MOVE16 (An)+, (xxx).L
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 1│ 0│ 0│ 0│ 0│ 0│ 0│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
  Absolute Long Address (32 bits follows)

Format 2: MOVE16 (xxx).L, (An)+
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 1│ 0│ 0│ 0│ 0│ 0│ 1│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
  Absolute Long Address (32 bits follows)

Format 3: MOVE16 (An), (xxx).L
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 1│ 0│ 0│ 0│ 1│ 0│ 0│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
  Absolute Long Address (32 bits follows)

Format 4: MOVE16 (xxx).L, (An)
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 1│ 0│ 0│ 0│ 1│ 0│ 1│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
  Absolute Long Address (32 bits follows)
```

### CINV Encoding

```
CINVL: Invalidate Line
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 0│ 1│cs│ 0│ 1│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
  cs: 0=DC, 1=IC

CINVP: Invalidate Page
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 1│ 0│cs│ 0│ 1│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘

CINVA: Invalidate All
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 1│ 1│cs│ 0│ 1│ 0│ 0│ 0│
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
```

### CPUSH Encoding

```
CPUSHL: Push Line
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 0│ 1│cs│ 1│ 0│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘

CPUSHP: Push Page
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 1│ 0│cs│ 1│ 0│   An  │
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘

CPUSHA: Push All
  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
  │ 1│ 1│ 1│ 1│ 0│ 1│ 0│ 0│ 1│ 1│cs│ 1│ 0│ 0│ 0│ 0│
  └──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
```

## Testing Strategy

### MOVE16 Tests

**Alignment Tests:**
```assembly
; Test aligned transfer (should succeed)
MOVE.L  #$00001000, A0    ; 16-byte aligned source
MOVE.L  #$00002000, A1    ; 16-byte aligned dest
MOVE16  (A0)+, (A1)+      ; Transfer 16 bytes
; Verify A0 = $00001010, A1 = $00002010

; Test misaligned source (should trap)
MOVE.L  #$00001001, A0    ; NOT aligned
MOVE.L  #$00002000, A1
MOVE16  (A0)+, (A1)+      ; Should cause address error
```

**Data Transfer Tests:**
```assembly
; Fill source with pattern
LEA     source, A0
MOVE.L  #$11111111, (A0)+
MOVE.L  #$22222222, (A0)+
MOVE.L  #$33333333, (A0)+
MOVE.L  #$44444444, (A0)+

; Transfer with MOVE16
LEA     source, A0
LEA     dest, A1
MOVE16  (A0)+, (A1)+

; Verify all 16 bytes copied correctly
```

### Cache Operation Tests

**Privilege Tests:**
```assembly
; In user mode
CINVA   DC                ; Should trap (privilege violation)

; In supervisor mode
CINVA   DC                ; Should succeed
```

**Scope Tests:**
```assembly
; Test line invalidation
MOVE.L  #$00001000, A0
CINVL   DC, (A0)          ; Invalidate line containing $1000

; Test page invalidation
MOVE.L  #$00001000, A0
CINVP   DC, (A0)          ; Invalidate all lines in page

; Test all invalidation
CINVA   DC                ; Invalidate entire D-cache
```

## Verification Checklist

- [ ] Instruction decoder recognizes all new opcodes
- [ ] MOVE16 alignment checking works
- [ ] MOVE16 transfers 16 bytes correctly
- [ ] MOVE16 postincrement updates registers
- [ ] MOVE16 address error exception triggered correctly
- [ ] CINV privilege checking works
- [ ] CINV scope (line/page/all) decoded correctly
- [ ] CPUSH privilege checking works
- [ ] CPUSH scope decoded correctly
- [ ] Cache operation interface signals correct
- [ ] All unit tests pass
- [ ] Documentation complete

## Known Limitations (Phase 2)

1. **Cache Stubs Only:** CINV/CPUSH set control flags but don't actually manipulate cache (Phase 5-7)
2. **No Burst Transfers:** MOVE16 uses sequential transfers initially (burst support in Phase 13)
3. **Simplified Bus Lock:** Basic implementation, full arbitration in Phase 13
4. **No Performance Optimization:** Focus on correctness, optimize in Phase 14

## Integration with Existing Code

### TG68K Decoder Extension

The new instructions will be added to the TG68K decoder using a separate decode stage:

```vhdl
-- In TG68KdotC_Kernel decode logic
if opcode(15 downto 8) = x"F6" then
    -- MOVE16 family
    decode_move16 <= '1';
elsif opcode(15 downto 6) = "1111010001" or
      opcode(15 downto 6) = "1111010010" or
      opcode(15 downto 6) = "1111010011" then
    -- CINV/CPUSH family
    decode_cache_op <= '1';
    check_supervisor <= '1';
end if;
```

### Register File Integration

Cache operations interface with TG68040_RegFile:

```vhdl
-- Read CACR to determine if caches enabled
if cacr_out(CACR_DE) = '1' then
    -- D-cache enabled, execute CINV/CPUSH
else
    -- D-cache disabled, operation is no-op
end if;
```

## Success Criteria

1. All three instructions decode correctly
2. MOVE16 transfers data accurately
3. Alignment checking prevents misaligned MOVE16
4. Cache ops check privileges correctly
5. All unit tests pass (>80% coverage)
6. Documentation complete
7. Ready for Phase 3 (Pipeline)

## Next Steps (Phase 3)

After Phase 2:
1. Design 6-stage pipeline architecture
2. Implement pipeline registers
3. Add instruction flow control
4. Create pipeline visualization tests

## References

1. MC68040 User's Manual, Section 8: Instruction Set
2. MC68040 User's Manual, Section 6: Cache Operations
3. M68000 Family Programmer's Reference Manual
4. TG68K Decoder Implementation

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
