# Phase 7: Real Caches (4-Way Set-Associative)

## Overview

**Phase:** 7 of 15
**Goal:** Replace cache stubs with real 4-way set-associative caches
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-18 (7 days)

## Objectives

1. ⏳ Design 4-way set-associative cache structure
2. ⏳ Implement LRU replacement algorithm
3. ⏳ Implement real I-cache (4-way set-associative)
4. ⏳ Implement real D-cache with write-back
5. ⏳ Add cache miss handling (multi-cycle)
6. ⏳ Implement bus interface for memory access
7. ⏳ Create comprehensive cache tests
8. ⏳ Measure realistic performance

## MC68040 Cache Architecture

### Real MC68040 Cache Specifications

Both I-cache and D-cache have identical organization:

- **Size:** 4KB (4096 bytes)
- **Organization:** 4-way set-associative
- **Line Size:** 16 bytes (4 longwords)
- **Number of Sets:** 64 sets
- **Lines per Set:** 4 ways
- **Total Lines:** 256 lines (64 sets × 4 ways)
- **Replacement:** Pseudo-LRU (tree-based)
- **Write Policy (D-cache):** Write-back with write-allocate

### Cache Organization Diagram

```
4-Way Set-Associative Cache (4KB):
┌────────────────────────────────────────────────────────────┐
│  64 Sets × 4 Ways × 16 bytes = 4096 bytes                  │
├────────────────────────────────────────────────────────────┤
│                                                              │
│  Set 0:  [Way 0][Way 1][Way 2][Way 3]                      │
│  Set 1:  [Way 0][Way 1][Way 2][Way 3]                      │
│  ...                                                         │
│  Set 63: [Way 0][Way 1][Way 2][Way 3]                      │
│                                                              │
│  Each Way contains:                                          │
│    - Valid bit (1 bit)                                       │
│    - Tag (22 bits)                                           │
│    - Data (16 bytes = 128 bits)                             │
│    - Dirty bit (1 bit, D-cache only)                        │
└────────────────────────────────────────────────────────────┘
```

### Address Breakdown

```
32-bit Address Format:
┌────────────┬───────────┬─────────┬────────┐
│ Tag (22)   │ Set (6)   │ Word(2) │ Byte(2)│
│ 31─────10  │ 9──────4  │ 3────2  │ 1────0 │
└────────────┴───────────┴─────────┴────────┘

Tag:  Bits 31-10 (22 bits) - Uniquely identify cache line
Set:  Bits 9-4   (6 bits)  - Select one of 64 sets
Word: Bits 3-2   (2 bits)  - Select word within line (0-3)
Byte: Bits 1-0   (2 bits)  - Byte offset within word

Example Address: 0x12345678
  Tag:  0x048D1  (bits 31-10 = 0001 0010 0011 0100 0101)
  Set:  0x19     (bits 9-4   = 011001 = 25)
  Word: 0x1      (bits 3-2   = 01 = word 1)
  Byte: 0x2      (bits 1-0   = 10 = byte 2)
```

## Phase 7 Approach: Real Cache Implementation

Phase 7 replaces the stubs (Phases 5-6) with real caches:

### Differences from Stubs (Phases 5-6)

| Feature | Phase 5-6 (Stub) | Phase 7 (Real) |
|---------|------------------|----------------|
| Hit Rate | 100% (always hit) | 85-95% (realistic) |
| Miss Penalty | 0 cycles | 4-8 cycles |
| Organization | Single array | 4-way set-associative |
| Replacement | N/A | LRU (Least Recently Used) |
| Valid Bits | Implicit | Explicit per line |
| Tags | No tags | 22-bit tags per line |
| Write Policy | Write-through | Write-back (D-cache) |
| Dirty Bits | None | Per line (D-cache) |
| Bus Access | None | Multi-cycle memory access |
| Line Fills | N/A | 4 longword burst |

### Why Real Caches?

1. **Realistic Performance** - Model actual MC68040 behavior
2. **Miss Handling** - Test pipeline under realistic conditions
3. **Bus Interface** - Required for system integration
4. **Write-Back** - Reduces bus traffic (D-cache)
5. **Associativity** - Reduces conflict misses
6. **Completeness** - Required for Phase 8+ (branches, exceptions)

## Phase 7A: Cache Structure Design (Days 1-2)

**Deliverables:**
- Cache line structure definition
- Set organization
- Tag comparison logic
- LRU replacement algorithm
- Cache state machine

### Cache Line Structure

```vhdl
-- Cache line (one way in a set)
type cache_line_t is record
    valid       : std_logic;                        -- Valid bit
    dirty       : std_logic;                        -- Dirty bit (D-cache only)
    tag         : std_logic_vector(21 downto 0);    -- Tag (bits 31-10 of address)
    data        : std_logic_vector(127 downto 0);   -- 16 bytes (4 longwords)
end record;

-- One set (4 ways)
type cache_set_t is array (0 to 3) of cache_line_t;

-- Entire cache (64 sets)
type cache_array_t is array (0 to 63) of cache_set_t;
```

### LRU Replacement (Pseudo-LRU Tree)

The MC68040 uses a **3-bit pseudo-LRU** tree for each set:

```
Tree Structure for 4 Ways:
                 bit0
                /    \
              /        \
           bit1        bit2
          /    \      /    \
        Way0  Way1  Way2  Way3

LRU Encoding:
  bit0: 0 = left subtree more recently used, 1 = right subtree
  bit1: 0 = Way0 more recent than Way1, 1 = Way1 more recent
  bit2: 0 = Way2 more recent than Way3, 1 = Way3 more recent

To find LRU way:
  if bit0 = 0 then                    -- Replace from right subtree
    if bit2 = 0 then way = 2
    else way = 3
  else                                 -- Replace from left subtree
    if bit1 = 0 then way = 0
    else way = 1
```

**Update on Access:**
```vhdl
procedure update_lru(
    signal lru_bits : inout std_logic_vector(2 downto 0);
    way_accessed : integer range 0 to 3
) is
begin
    case way_accessed is
        when 0 => lru_bits(0) <= '1'; lru_bits(1) <= '1';  -- Way 0 accessed
        when 1 => lru_bits(0) <= '1'; lru_bits(1) <= '0';  -- Way 1 accessed
        when 2 => lru_bits(0) <= '0'; lru_bits(2) <= '1';  -- Way 2 accessed
        when 3 => lru_bits(0) <= '0'; lru_bits(2) <= '0';  -- Way 3 accessed
    end case;
end procedure;

function get_lru_way(lru_bits : std_logic_vector(2 downto 0)) return integer is
begin
    if lru_bits(0) = '0' then
        if lru_bits(2) = '0' then
            return 2;  -- Replace Way 2
        else
            return 3;  -- Replace Way 3
        end if;
    else
        if lru_bits(1) = '0' then
            return 0;  -- Replace Way 0
        else
            return 1;  -- Replace Way 1
        end if;
    end if;
end function;
```

### Cache State Machine

**I-Cache States:**
```
IDLE → LOOKUP → HIT / MISS
                  ↓      ↓
                 READY  ALLOCATE → LINE_FILL (4 cycles) → READY
```

**D-Cache States:**
```
IDLE → LOOKUP → HIT / MISS
                  ↓      ↓
                 READY  WRITE_BACK (if dirty) → ALLOCATE → LINE_FILL → READY
```

## Phase 7B: I-Cache Implementation (Days 3-4)

**Deliverables:**
- Real I-cache with 4-way set-associative organization
- Tag comparison and hit detection
- LRU replacement on miss
- Line fill from memory (4-longword burst)
- Miss penalty: 4-8 cycles

### I-Cache Architecture

```vhdl
entity TG68040_ICache_Real is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;
        cache_freeze   : in std_logic;
        cache_invalidate : in std_logic;

        -- Fetch interface (from IF stage)
        fetch_req      : in std_logic;
        fetch_addr     : in std_logic_vector(31 downto 0);
        fetch_data     : out std_logic_vector(15 downto 0);
        fetch_ready    : out std_logic;

        -- Memory bus interface (for cache misses)
        mem_req        : out std_logic;
        mem_burst      : out std_logic;                     -- Burst transfer
        mem_addr       : out std_logic_vector(31 downto 0);
        mem_data       : in std_logic_vector(31 downto 0);  -- One longword per cycle
        mem_ready      : in std_logic;

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0);
        miss_count     : out std_logic_vector(31 downto 0);
        access_count   : out std_logic_vector(31 downto 0)
    );
end TG68040_ICache_Real;
```

### I-Cache Operation

**Cache Lookup (1 cycle):**
```vhdl
-- Extract address fields
set_index := to_integer(unsigned(fetch_addr(9 downto 4)));
tag := fetch_addr(31 downto 10);
word_offset := to_integer(unsigned(fetch_addr(3 downto 2)));

-- Check all 4 ways in parallel
for way in 0 to 3 loop
    if cache_array(set_index)(way).valid = '1' and
       cache_array(set_index)(way).tag = tag then
        hit_way := way;
        hit := '1';
        exit;
    end if;
end loop;
```

**Cache Hit (1 cycle):**
```vhdl
if hit = '1' then
    -- Extract requested word
    word_data := cache_array(set_index)(hit_way).data(word_offset * 32 + 31 downto word_offset * 32);
    fetch_data <= word_data(15 downto 0);  -- Return low 16 bits (instruction)
    fetch_ready <= '1';

    -- Update LRU
    update_lru(lru_array(set_index), hit_way);

    -- Update statistics
    hits <= hits + 1;
end if;
```

**Cache Miss (4-8 cycles):**
```vhdl
if hit = '0' then
    -- Find LRU way
    victim_way := get_lru_way(lru_array(set_index));

    -- Allocate line (no write-back needed for I-cache)
    state <= LINE_FILL;
    fill_addr <= fetch_addr(31 downto 4) & "0000";  -- Align to 16-byte boundary
    fill_count <= 0;

    -- Update statistics
    misses <= misses + 1;
end if;
```

**Line Fill (4 cycles):**
```vhdl
case fill_count is
    when 0 =>
        mem_req <= '1';
        mem_burst <= '1';
        mem_addr <= fill_addr;
        if mem_ready = '1' then
            cache_array(set_index)(victim_way).data(31 downto 0) <= mem_data;
            fill_count <= 1;
            fill_addr <= std_logic_vector(unsigned(fill_addr) + 4);
        end if;

    when 1 =>
        if mem_ready = '1' then
            cache_array(set_index)(victim_way).data(63 downto 32) <= mem_data;
            fill_count <= 2;
            fill_addr <= std_logic_vector(unsigned(fill_addr) + 4);
        end if;

    when 2 =>
        if mem_ready = '1' then
            cache_array(set_index)(victim_way).data(95 downto 64) <= mem_data;
            fill_count <= 3;
            fill_addr <= std_logic_vector(unsigned(fill_addr) + 4);
        end if;

    when 3 =>
        if mem_ready = '1' then
            cache_array(set_index)(victim_way).data(127 downto 96) <= mem_data;
            cache_array(set_index)(victim_way).valid <= '1';
            cache_array(set_index)(victim_way).tag <= tag;
            state <= READY;
            fetch_ready <= '1';
        end if;
end case;
```

## Phase 7C: D-Cache Implementation (Days 5-6)

**Deliverables:**
- Real D-cache with 4-way set-associative organization
- Write-back policy with dirty bit tracking
- Write-allocate on write miss
- LRU replacement
- Dirty line write-back before replacement
- Miss penalty: 4-8 cycles (read), 8-12 cycles (write-back + read)

### D-Cache Architecture

```vhdl
entity TG68040_DCache_Real is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;
        cache_freeze   : in std_logic;
        cache_invalidate : in std_logic;
        cache_flush    : in std_logic;

        -- Memory operation interface (from EX stage)
        mem_req        : in std_logic;
        mem_write      : in std_logic;
        mem_size       : in std_logic_vector(1 downto 0);
        mem_addr       : in std_logic_vector(31 downto 0);
        mem_data_in    : in std_logic_vector(31 downto 0);
        mem_data_out   : out std_logic_vector(31 downto 0);
        mem_ready      : out std_logic;

        -- Bus interface (for cache misses/write-backs)
        bus_req        : out std_logic;
        bus_write      : out std_logic;
        bus_burst      : out std_logic;
        bus_addr       : out std_logic_vector(31 downto 0);
        bus_data_in    : out std_logic_vector(31 downto 0);  -- Write data (one longword per cycle)
        bus_data_out   : in std_logic_vector(31 downto 0);   -- Read data (one longword per cycle)
        bus_ready      : in std_logic;

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0);
        miss_count     : out std_logic_vector(31 downto 0);
        read_count     : out std_logic_vector(31 downto 0);
        write_count    : out std_logic_vector(31 downto 0);
        writeback_count : out std_logic_vector(31 downto 0)
    );
end TG68040_DCache_Real;
```

### D-Cache Write-Back Policy

**Write Hit:**
```vhdl
if hit = '1' and mem_write = '1' then
    -- Update cache line
    case mem_size is
        when "00" =>  -- Byte
            byte_offset := to_integer(unsigned(mem_addr(1 downto 0)));
            cache_array(set_index)(hit_way).data(word_offset * 32 + byte_offset * 8 + 7 downto
                                                  word_offset * 32 + byte_offset * 8) <= mem_data_in(7 downto 0);

        when "01" =>  -- Word
            word_in_line := to_integer(unsigned(mem_addr(1)));
            cache_array(set_index)(hit_way).data(word_offset * 32 + word_in_line * 16 + 15 downto
                                                  word_offset * 32 + word_in_line * 16) <= mem_data_in(15 downto 0);

        when "10" =>  -- Longword
            cache_array(set_index)(hit_way).data(word_offset * 32 + 31 downto
                                                  word_offset * 32) <= mem_data_in;
    end case;

    -- Mark line as dirty
    cache_array(set_index)(hit_way).dirty <= '1';

    -- Update LRU
    update_lru(lru_array(set_index), hit_way);

    mem_ready <= '1';
    hits <= hits + 1;
    writes <= writes + 1;
end if;
```

**Write Miss (Write-Allocate):**
```vhdl
if hit = '0' and mem_write = '1' then
    -- Find LRU way
    victim_way := get_lru_way(lru_array(set_index));

    -- Check if victim is dirty
    if cache_array(set_index)(victim_way).dirty = '1' then
        -- Write back dirty line first
        state <= WRITE_BACK;
        wb_addr <= cache_array(set_index)(victim_way).tag & set_index_vec & "0000";
        wb_count <= 0;
    else
        -- No write-back needed, go directly to line fill
        state <= LINE_FILL;
        fill_addr <= mem_addr(31 downto 4) & "0000";
        fill_count <= 0;
    end if;

    misses <= misses + 1;
end if;
```

**Dirty Line Write-Back (4 cycles):**
```vhdl
case wb_count is
    when 0 to 3 =>
        bus_req <= '1';
        bus_write <= '1';
        bus_burst <= '1';
        bus_addr <= wb_addr;
        bus_data_in <= cache_array(set_index)(victim_way).data(wb_count * 32 + 31 downto wb_count * 32);

        if bus_ready = '1' then
            wb_count <= wb_count + 1;
            wb_addr <= std_logic_vector(unsigned(wb_addr) + 4);

            if wb_count = 3 then
                -- Write-back complete, proceed to line fill
                cache_array(set_index)(victim_way).dirty <= '0';
                state <= LINE_FILL;
                writebacks <= writebacks + 1;
            end if;
        end if;
end case;
```

## Phase 7D: Testing (Day 7)

**Unit Tests:**
1. Cache organization test (4-way, 64 sets)
2. Tag comparison test
3. Hit detection test (all 4 ways)
4. Miss detection test
5. LRU replacement test
6. I-cache line fill test
7. D-cache write-back test
8. D-cache dirty bit test
9. Byte/word/longword write test
10. Cache invalidate test
11. Cache flush test (write-back all dirty lines)
12. Performance benchmark (hit rate, miss penalty)

**Test Scenarios:**

**Test 1: Simple Hit**
```vhdl
-- Fill cache with known data
-- Request same address
-- Should hit in 1 cycle
```

**Test 2: Simple Miss**
```vhdl
-- Request address not in cache
-- Should miss, trigger line fill (4 cycles)
-- Subsequent access should hit
```

**Test 3: LRU Replacement**
```vhdl
-- Fill all 4 ways of a set
-- Access each way in order: 0, 1, 2, 3
-- Access new address (miss)
-- Should replace Way 0 (least recently used)
```

**Test 4: Write-Back**
```vhdl
-- Write to cache (hit)
-- Verify dirty bit set
-- Cause eviction (4 new addresses to same set)
-- Verify write-back occurs (4 bus writes)
```

**Test 5: Hit Rate Benchmark**
```vhdl
-- Sequential access pattern (good locality)
-- Expected hit rate: >90%
-- Random access pattern (poor locality)
-- Expected hit rate: ~70-80%
```

## Performance Expectations

### Phase 7 (Real Cache)

| Metric | I-Cache | D-Cache | Notes |
|--------|---------|---------|-------|
| Hit Rate | 90-95% | 85-90% | Depends on workload |
| Hit Latency | 1 cycle | 1 cycle | Same as stub |
| Miss Penalty | 4-8 cycles | 4-8 cycles | Line fill |
| Write-Back Penalty | N/A | 4 cycles | Dirty line eviction |
| Total Miss Cost | 4-8 cycles | 8-12 cycles | Write-back + fill |

### CPI Impact

| Scenario | CPI |
|----------|-----|
| All hits | 1.2 |
| 5% I-miss, 10% D-miss | 1.5-1.8 |
| 10% I-miss, 15% D-miss | 2.0-2.5 |

## Known Limitations (Phase 7)

1. **No Cache Coherency** - No bus snooping (Phase 9+)
2. **Simple Bus Interface** - No burst optimization (Phase 9+)
3. **No Prefetching** - Reactive line fills only (Phase 11+)
4. **Pseudo-LRU** - Approximate, not true LRU (matches MC68040)
5. **No PLRU Optimization** - Tree updated on every access (could optimize)
6. **No Cache Locking** - Can't lock critical code/data (Phase 11+)

## Integration with Previous Phases

### Phase 5-6 Integration (Cache Stubs)
- Replace TG68040_ICache (stub) with TG68040_ICache_Real
- Replace TG68040_DCache (stub) with TG68040_DCache_Real
- Same interface, drop-in replacement
- Pipeline unchanged (already handles multi-cycle latency)

### Phase 4 Integration (Hazards)
- Load-use hazards still detected (Phase 6)
- Cache misses add additional stall cycles
- Forwarding paths still work

### Phase 3 Integration (Pipeline)
- IF stage waits for I-cache ready
- EX stage waits for D-cache ready
- Pipeline control already has stall logic

## Success Criteria

- [ ] 4-way set-associative organization working
- [ ] LRU replacement working correctly
- [ ] I-cache hit/miss detection accurate
- [ ] D-cache hit/miss detection accurate
- [ ] Write-back policy working (dirty bits)
- [ ] Line fills completing correctly (4 cycles)
- [ ] Bus interface functional
- [ ] Hit rate realistic (85-95%)
- [ ] All unit tests pass
- [ ] Performance measured and documented

## Next Steps (Phase 8)

After Phase 7:
1. Implement branch prediction
2. Add branch target buffer (BTB)
3. Handle branch mispredictions
4. Flush pipeline on mispredicts
5. Test branch performance

## References

1. MC68040 User's Manual, Section 4: Caches
2. MC68040 User's Manual, Section 7: Bus Operation
3. Computer Architecture: A Quantitative Approach (Hennessy & Patterson) - Chapter 2: Memory Hierarchy
4. Cache Memory Book (Przybylski) - Chapter 4: Set-Associative Caches
5. "Pseudo-LRU: A Practical Implementation of LRU for Large Associativity" - IEEE

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
