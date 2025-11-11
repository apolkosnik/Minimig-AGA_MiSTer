# Phase 5: Instruction Cache (Stub)

## Overview

**Phase:** 5 of 15
**Goal:** Implement instruction cache stub with proper interface
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-18 (7 days)

## Objectives

1. ⏳ Design instruction cache interface
2. ⏳ Implement cache stub (always hit)
3. ⏳ Add cache control signals
4. ⏳ Integrate with instruction fetch stage
5. ⏳ Add cache statistics tracking
6. ⏳ Create cache unit tests
7. ⏳ Prepare for real cache implementation (Phase 7)

## MC68040 Instruction Cache

### Real MC68040 I-Cache Specifications

- **Size:** 4KB (4096 bytes)
- **Organization:** 4-way set-associative
- **Line Size:** 16 bytes (4 longwords)
- **Total Lines:** 256 lines (64 sets × 4 ways)
- **Replacement:** LRU (Least Recently Used)
- **Write Policy:** Not applicable (read-only for instructions)
- **Cache Control:** CACR register controls enable/disable

### Cache Organization

```
4KB I-Cache Organization (Real MC68040):
┌─────────────────────────────────────────────────────────┐
│  64 Sets × 4 Ways × 16 bytes = 4096 bytes               │
├─────────────────────────────────────────────────────────┤
│  Address Breakdown (32-bit):                            │
│  ┌────────────┬───────────┬─────────┬────────┐          │
│  │ Tag (22)   │ Set (6)   │ Word(2) │ Byte(2)│          │
│  └────────────┴───────────┴─────────┴────────┘          │
│                                                           │
│  Tag: Bits 31-10 (22 bits) - Uniquely identify line     │
│  Set: Bits 9-4 (6 bits) - Select one of 64 sets         │
│  Word: Bits 3-2 (2 bits) - Select word within line      │
│  Byte: Bits 1-0 (2 bits) - Byte offset (always 00)      │
└─────────────────────────────────────────────────────────┘
```

## Phase 5 Approach: Stub Implementation

Phase 5 implements a **cache stub** that:
1. **Always hits** - Returns data immediately (1-cycle latency)
2. **Proper interface** - Same signals as real cache will use
3. **Statistics tracking** - Count hits, misses (always 0), accesses
4. **Easy replacement** - Can swap in real cache (Phase 7) without pipeline changes

### Why a Stub?

1. **Incremental development** - Test pipeline with cache interface before complexity
2. **Interface validation** - Ensure cache signals are correct
3. **Performance baseline** - Measure ideal performance (100% hit rate)
4. **Simplicity** - Focus on integration, not cache algorithm

## Phase 5A: Cache Interface Design (Days 1-2)

**Deliverables:**
- Cache interface specification
- Signal definitions
- State machine design

**Cache Interface:**
```vhdl
entity TG68040_ICache is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;                      -- Enable I-cache
        cache_freeze   : in std_logic;                      -- Freeze cache (no updates)
        cache_invalidate : in std_logic;                    -- Invalidate all lines

        -- Instruction fetch interface (from IF stage)
        fetch_req      : in std_logic;                      -- Fetch request
        fetch_addr     : in std_logic_vector(31 downto 0);  -- Address to fetch
        fetch_data     : out std_logic_vector(15 downto 0); -- Instruction data
        fetch_ready    : out std_logic;                     -- Data ready

        -- Memory interface (for cache misses - unused in stub)
        mem_req        : out std_logic;                     -- Memory request
        mem_addr       : out std_logic_vector(31 downto 0); -- Memory address
        mem_data       : in std_logic_vector(127 downto 0); -- Memory data (line)
        mem_ready      : in std_logic;                      -- Memory ready

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0); -- Cache hits
        miss_count     : out std_logic_vector(31 downto 0); -- Cache misses
        access_count   : out std_logic_vector(31 downto 0)  -- Total accesses
    );
end TG68040_ICache;
```

## Phase 5B: Stub Implementation (Days 3-4)

**Deliverables:**
- Cache stub implementation
- Always-hit behavior
- Statistics tracking

**Stub Behavior:**
```vhdl
-- Phase 5 Stub: Always hit with 1-cycle latency
process(clk)
begin
    if rising_edge(clk) then
        if reset = '1' then
            fetch_ready <= '0';
            hit_count <= (others => '0');
            access_count <= (others => '0');

        elsif cache_enable = '1' and fetch_req = '1' then
            -- Stub: Always hit, return data from internal memory
            fetch_data <= instr_memory(to_integer(unsigned(fetch_addr(9 downto 1))));
            fetch_ready <= '1';

            -- Update statistics
            hit_count <= hit_count + 1;
            access_count <= access_count + 1;

        else
            fetch_ready <= '0';
        end if;
    end if;
end process;

-- Stub: Never request memory (always hit)
mem_req <= '0';
miss_count <= (others => '0');  -- Always 0 in stub
```

**Cache States (Stub):**
```
┌─────────┐
│  IDLE   │ ← Initial state
└────┬────┘
     │
     ├─ fetch_req = '1'
     │
     ↓
┌─────────┐
│   HIT   │ ← Always hit (stub)
└────┬────┘
     │
     └─ fetch_ready = '1' (1 cycle)
```

## Phase 5C: Pipeline Integration (Days 5-6)

**Deliverables:**
- Integrate I-cache with IF stage
- Update pipeline to use cache interface
- Remove internal instruction memory from pipeline

**IF Stage Update:**
```vhdl
-- Before (Phase 4): Direct instruction memory
if_id.instruction <= instr_memory(to_integer(pc(9 downto 1)));

-- After (Phase 5): Via I-cache
icache_fetch_req <= '1';
icache_fetch_addr <= std_logic_vector(pc);
wait until icache_fetch_ready = '1';
if_id.instruction <= icache_fetch_data;
```

**Integration Points:**
1. IF stage sends fetch request to cache
2. Cache returns data (always 1 cycle in stub)
3. IF stage proceeds when `fetch_ready` asserted
4. Statistics tracked automatically

## Phase 5D: Testing (Days 7)

**Unit Tests:**
1. Cache enable/disable test
2. Always-hit behavior test
3. Statistics tracking test
4. Cache invalidate test
5. Interface timing test
6. Integration with pipeline test

**Test Scenarios:**

**Test 1: Cache Always Hits**
```vhdl
-- Request instruction at address 0x1000
fetch_req <= '1';
fetch_addr <= x"00001000";
wait until rising_edge(clk);

-- Should hit immediately (1 cycle)
assert fetch_ready = '1';
assert hit_count = 1;
assert miss_count = 0;
```

**Test 2: Cache Disabled**
```vhdl
-- Disable cache
cache_enable <= '0';
fetch_req <= '1';
fetch_addr <= x"00001000";
wait until rising_edge(clk);

-- Should fall through to memory (not implemented in stub)
-- For Phase 5, fetch_ready stays '0' when disabled
assert fetch_ready = '0';
```

**Test 3: Statistics Tracking**
```vhdl
-- Make 10 requests
for i in 0 to 9 loop
    fetch_req <= '1';
    fetch_addr <= std_logic_vector(to_unsigned(i * 2, 32));
    wait until rising_edge(clk);
end loop;

-- Check statistics
assert hit_count = 10;
assert miss_count = 0;
assert access_count = 10;
```

## Cache Control Register (CACR) Integration

The MC68040 CACR (Cache Control Register) controls cache behavior:

```
CACR Bits (Instruction Cache):
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ 31 │... │ 15 │ 14 │ 13 │ 12 │... │  0 │
└────┴────┴────┴────┴────┴────┴────┴────┘
         │    │    │    │
         │    │    │    └─ IE: I-Cache Enable
         │    │    └────── FI: Freeze I-Cache
         │    └─────────── No Allocate
         └──────────────── (other bits)
```

**Phase 5 CACR Integration:**
- `cache_enable` ← CACR bit 15 (IE)
- `cache_freeze` ← CACR bit 13 (FI)
- `cache_invalidate` ← Pulse from CINV instruction

## Deliverables

### Source Files

| File | Status | Description |
|------|--------|-------------|
| `TG68040_ICache.vhd` | ⏳ Planned | Instruction cache stub |
| `TG68040_Pipeline.vhd` (updated) | ⏳ Planned | Integrate I-cache with IF stage |

### Test Files

| File | Status | Description |
|------|--------|-------------|
| `test_ICache.vhd` | ⏳ Planned | I-cache unit tests |
| `test_Pipeline_ICache.vhd` | ⏳ Planned | Pipeline with I-cache integration |

### Documentation

| Document | Status | Description |
|----------|--------|-------------|
| PHASE5_README.md | ✅ Complete | This file |
| CACHE_INTERFACE_SPEC.md | ⏳ Planned | Detailed cache interface |
| PHASE5_SUMMARY.md | ⏳ Planned | Phase 5 completion report |

## Performance Expectations

### Phase 5 (Stub - Always Hit)

| Metric | Expected | Notes |
|--------|----------|-------|
| Hit Rate | 100% | Stub always hits |
| Miss Penalty | 0 cycles | No misses |
| Fetch Latency | 1 cycle | Immediate response |
| CPI Impact | 0 | No stalls |
| Throughput | 1 instr/cycle | Ideal |

### Phase 7 (Real Cache)

| Metric | Expected | Notes |
|--------|----------|-------|
| Hit Rate | >90% | Typical code |
| Miss Penalty | 3-6 cycles | Memory latency |
| Fetch Latency | 1 cycle (hit) | 4-7 cycles (miss) |
| CPI Impact | +0.1-0.3 | Due to occasional misses |
| Throughput | 0.9-1.0 instr/cycle | Slight degradation |

## Known Limitations (Phase 5)

1. **Always Hit** - Stub doesn't model real cache behavior (Phase 7)
2. **No Memory Access** - Doesn't fetch from memory (Phase 7)
3. **Fixed Data** - Uses internal instruction memory (Phase 7)
4. **No LRU** - No replacement algorithm (Phase 7)
5. **No Way Selection** - Not 4-way associative (Phase 7)

These are intentional Phase 5 limitations.

## Integration with Previous Phases

### Phase 1 Integration (Control Registers)
- CACR register controls cache enable/freeze
- CINV instruction triggers cache invalidate
- Cache respects supervisor mode

### Phase 2 Integration (New Instructions)
- CINV instruction invalidates I-cache
- Cache operations interface with stub

### Phase 3-4 Integration (Pipeline + Hazards)
- Cache integrates with IF stage
- Fetch latency (1 cycle) fits pipeline timing
- No additional stalls in Phase 5

## Success Criteria

- [ ] I-cache stub implemented
- [ ] Always-hit behavior working
- [ ] Statistics tracking functional
- [ ] Integration with IF stage complete
- [ ] Cache enable/disable working
- [ ] Cache invalidate working
- [ ] All unit tests pass
- [ ] Pipeline performance unchanged (stub is transparent)
- [ ] Ready for real cache (Phase 7)

## Next Steps (Phase 6)

After Phase 5:
1. Implement data cache stub (similar to I-cache)
2. Add load-use hazard detection
3. Integrate D-cache with memory operations
4. Add D-cache statistics
5. Test cache coherency

## References

1. MC68040 User's Manual, Section 4: Caches
2. MC68040 User's Manual, Section 5: Cache Control Register
3. Computer Architecture: A Quantitative Approach (Hennessy & Patterson) - Chapter 5: Memory Hierarchy
4. Cache Memory Book (Przybylski)

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
