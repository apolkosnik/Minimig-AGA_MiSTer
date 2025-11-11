# Phase 6: Data Cache (Stub)

## Overview

**Phase:** 6 of 15
**Goal:** Implement data cache stub with proper interface and load-use hazard detection
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-18 (7 days)

## Objectives

1. ⏳ Design data cache interface
2. ⏳ Implement D-cache stub (always hit)
3. ⏳ Add load-use hazard detection
4. ⏳ Integrate with memory operations (load/store)
5. ⏳ Add D-cache statistics tracking
6. ⏳ Create D-cache unit tests
7. ⏳ Test cache coherency with I-cache

## MC68040 Data Cache

### Real MC68040 D-Cache Specifications

- **Size:** 4KB (4096 bytes)
- **Organization:** 4-way set-associative
- **Line Size:** 16 bytes (4 longwords)
- **Total Lines:** 256 lines (64 sets × 4 ways)
- **Replacement:** LRU (Least Recently Used)
- **Write Policy:** Write-back with write-allocate
- **Cache Control:** CACR register controls enable/disable
- **Transparency:** Supports bus snooping for cache coherency

### Cache Organization

```
4KB D-Cache Organization (Real MC68040):
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
│  Byte: Bits 1-0 (2 bits) - Byte offset                  │
└─────────────────────────────────────────────────────────┘
```

### Write Policy Details

The MC68040 D-cache uses **write-back** with **write-allocate**:

- **Write Hit:** Update cache line, mark as dirty (write-back later)
- **Write Miss:** Allocate line, fetch from memory, update cache
- **Dirty Line Eviction:** Write back to memory before replacement
- **Cache Coherency:** Bus snooping invalidates stale lines

## Phase 6 Approach: Stub Implementation

Phase 6 implements a **D-cache stub** that:
1. **Always hits** - Returns data immediately (1-cycle latency for reads)
2. **Proper interface** - Same signals as real cache will use
3. **Statistics tracking** - Count hits, misses (always 0), reads, writes
4. **Load-use hazard detection** - 1-cycle stall when load followed by use
5. **Easy replacement** - Can swap in real cache (Phase 7) without pipeline changes

### Why a Stub?

1. **Incremental development** - Test pipeline with cache interface before complexity
2. **Interface validation** - Ensure cache signals are correct
3. **Performance baseline** - Measure ideal performance (100% hit rate)
4. **Hazard testing** - Validate load-use hazard detection separately
5. **Simplicity** - Focus on integration, not cache algorithm

## Phase 6A: Cache Interface Design (Days 1-2)

**Deliverables:**
- D-cache interface specification
- Signal definitions
- State machine design
- Load-use hazard logic

**Cache Interface:**
```vhdl
entity TG68040_DCache is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Cache control (from CACR)
        cache_enable   : in std_logic;                      -- Enable D-cache
        cache_freeze   : in std_logic;                      -- Freeze cache (no updates)
        cache_invalidate : in std_logic;                    -- Invalidate all lines
        cache_flush    : in std_logic;                      -- Flush dirty lines

        -- Memory operation interface (from EX stage)
        mem_req        : in std_logic;                      -- Memory request
        mem_write      : in std_logic;                      -- Write (1) or read (0)
        mem_size       : in std_logic_vector(1 downto 0);   -- 00=byte, 01=word, 10=long
        mem_addr       : in std_logic_vector(31 downto 0);  -- Address
        mem_data_in    : in std_logic_vector(31 downto 0);  -- Data to write
        mem_data_out   : out std_logic_vector(31 downto 0); -- Data read
        mem_ready      : out std_logic;                     -- Operation complete

        -- Bus interface (for cache misses - unused in stub)
        bus_req        : out std_logic;                     -- Bus request
        bus_write      : out std_logic;                     -- Bus write
        bus_addr       : out std_logic_vector(31 downto 0); -- Bus address
        bus_data_in    : out std_logic_vector(127 downto 0);-- Bus data (write)
        bus_data_out   : in std_logic_vector(127 downto 0); -- Bus data (read)
        bus_ready      : in std_logic;                      -- Bus ready

        -- Statistics
        hit_count      : out std_logic_vector(31 downto 0); -- Cache hits
        miss_count     : out std_logic_vector(31 downto 0); -- Cache misses
        read_count     : out std_logic_vector(31 downto 0); -- Total reads
        write_count    : out std_logic_vector(31 downto 0)  -- Total writes
    );
end TG68040_DCache;
```

### Load-Use Hazard Detection

**Problem:** A load instruction followed immediately by an instruction using the loaded value creates a hazard:

```assembly
MOVE.L (A0), D0    ; Load D0 from memory (takes 1 cycle in stub)
ADD.L  D0, D1      ; Use D0 immediately (hazard!)
```

**Solution:** Detect in hazard unit and stall pipeline for 1 cycle:

```vhdl
-- In TG68040_HazardUnit
if (of_ex.mem_read = '1' and of_ex.dst_reg_write = '1') then
    -- Load in EX stage
    if (id_ea.src_reg1 = of_ex.dst_reg or id_ea.src_reg2 = of_ex.dst_reg) then
        -- Instruction in ID/EA uses loaded value
        load_use_hazard <= '1';
        stall_pipeline <= '1';  -- Stall for 1 cycle
    end if;
end if;
```

**Timing Diagram:**
```
Cycle:   1    2    3    4    5    6
-------------------------------------------
MOVE:    IF   ID   EA   OF   EX   WB    ; Load D0
ADD:          IF   ID   --   EA   OF    ; Stall (--) due to load-use
                             ↑
                             Load data available
```

## Phase 6B: Stub Implementation (Days 3-4)

**Deliverables:**
- D-cache stub implementation
- Always-hit behavior (reads and writes)
- Statistics tracking
- Simple data storage

**Stub Behavior:**
```vhdl
-- Phase 6 Stub: Always hit with 1-cycle latency
architecture stub of TG68040_DCache is
    -- Simple data memory (for stub - 256 longwords = 1KB)
    type data_mem_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal data_memory : data_mem_t := (others => (others => '0'));

    signal hits : unsigned(31 downto 0) := (others => '0');
    signal reads : unsigned(31 downto 0) := (others => '0');
    signal writes : unsigned(31 downto 0) := (others => '0');

begin
    cache_proc: process(clk)
        variable addr_index : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                mem_ready <= '0';
                hits <= (others => '0');
                reads <= (others => '0');
                writes <= (others => '0');

            elsif cache_invalidate = '1' then
                -- Reset statistics
                hits <= (others => '0');
                reads <= (others => '0');
                writes <= (others => '0');

            elsif cache_enable = '1' and mem_req = '1' then
                addr_index := to_integer(unsigned(mem_addr(9 downto 2)));

                if mem_write = '1' then
                    -- Write operation (always hit)
                    data_memory(addr_index) <= mem_data_in;
                    mem_ready <= '1';
                    hits <= hits + 1;
                    writes <= writes + 1;
                else
                    -- Read operation (always hit)
                    mem_data_out <= data_memory(addr_index);
                    mem_ready <= '1';
                    hits <= hits + 1;
                    reads <= reads + 1;
                end if;
            else
                mem_ready <= '0';
            end if;
        end if;
    end process;

    -- Stub: Never request bus (always hit)
    bus_req <= '0';
    miss_count <= (others => '0');  -- Always 0 in stub
end stub;
```

**Cache States (Stub):**
```
┌─────────┐
│  IDLE   │ ← Initial state
└────┬────┘
     │
     ├─ mem_req = '1' and mem_write = '0' (READ)
     │
     ↓
┌─────────┐
│   HIT   │ ← Always hit (stub)
└────┬────┘ ← Return data
     │
     └─ mem_ready = '1' (1 cycle)

┌─────────┐
│  IDLE   │
└────┬────┘
     │
     ├─ mem_req = '1' and mem_write = '1' (WRITE)
     │
     ↓
┌─────────┐
│   HIT   │ ← Always hit (stub)
└────┬────┘ ← Update memory
     │
     └─ mem_ready = '1' (1 cycle)
```

## Phase 6C: Hazard Unit Update (Days 5)

**Deliverables:**
- Update TG68040_HazardUnit.vhd
- Add load-use hazard detection
- Add stall logic for loads

**Hazard Unit Extension:**
```vhdl
-- Extended hazard_info_t (in TG68040_Pipeline_Regs.vhd)
type hazard_info_t is record
    raw_hazard      : std_logic;
    waw_hazard      : std_logic;
    war_hazard      : std_logic;
    load_use_hazard : std_logic;  -- NEW
    forward_ex_a    : std_logic;
    forward_ex_b    : std_logic;
    forward_wb_a    : std_logic;
    forward_wb_b    : std_logic;
    stall_for_load  : std_logic;  -- NEW
end record;

-- In TG68040_HazardUnit.vhd
process(clk)
begin
    if rising_edge(clk) then
        -- Existing RAW/WAW/WAR detection...

        -- Load-use hazard detection
        if of_ex_valid = '1' and of_ex_mem_read = '1' then
            -- There's a load in EX stage
            if (id_ea_src_reg1 = of_ex_dst_reg and of_ex_dst_write = '1') or
               (id_ea_src_reg2 = of_ex_dst_reg and of_ex_dst_write = '1') then
                -- ID/EA stage needs the loaded value
                load_use_hazard <= '1';
                stall_for_load <= '1';
            else
                load_use_hazard <= '0';
                stall_for_load <= '0';
            end if;
        else
            load_use_hazard <= '0';
            stall_for_load <= '0';
        end if;

        -- Overall stall decision
        stall_pipeline <= stall_for_load or structural_hazard;
    end if;
end process;
```

## Phase 6D: Pipeline Integration (Days 6)

**Deliverables:**
- Integrate D-cache with EX stage
- Update pipeline to use D-cache for memory operations
- Handle load-use stalls

**Pipeline Update:**
```vhdl
-- In TG68040_Pipeline.vhd

-- D-cache signals
signal dcache_mem_req : std_logic;
signal dcache_mem_write : std_logic;
signal dcache_mem_size : std_logic_vector(1 downto 0);
signal dcache_mem_addr : std_logic_vector(31 downto 0);
signal dcache_mem_data_in : std_logic_vector(31 downto 0);
signal dcache_mem_data_out : std_logic_vector(31 downto 0);
signal dcache_mem_ready : std_logic;

-- D-cache component instantiation
dcache: TG68040_DCache
    port map(
        clk => clk,
        reset => reset,
        cache_enable => '1',
        cache_freeze => '0',
        cache_invalidate => cache_invalidate,
        cache_flush => cache_flush,
        mem_req => dcache_mem_req,
        mem_write => dcache_mem_write,
        mem_size => dcache_mem_size,
        mem_addr => dcache_mem_addr,
        mem_data_in => dcache_mem_data_in,
        mem_data_out => dcache_mem_data_out,
        mem_ready => dcache_mem_ready,
        ...
    );

-- EX stage memory operations
process(clk)
begin
    if rising_edge(clk) then
        if ea_of.mem_read = '1' or ea_of.mem_write = '1' then
            -- Memory operation
            dcache_mem_req <= '1';
            dcache_mem_write <= ea_of.mem_write;
            dcache_mem_size <= ea_of.mem_size;
            dcache_mem_addr <= ea_of.effective_addr;
            dcache_mem_data_in <= ea_of.operand_b;  -- Data to write

            -- Wait for D-cache
            if dcache_mem_ready = '1' then
                if ea_of.mem_read = '1' then
                    ex_wb.result <= dcache_mem_data_out;
                end if
                ex_wb.valid <= '1';
            end if;
        else
            dcache_mem_req <= '0';
        end if;
    end if;
end process;

-- Handle load-use stalls
if hazard_info.stall_for_load = '1' then
    ctrl.stall_id <= '1';
    ctrl.stall_ea <= '1';
end if;
```

## Phase 6E: Testing (Days 7)

**Unit Tests:**
1. D-cache enable/disable test
2. Always-hit behavior test (reads)
3. Always-hit behavior test (writes)
4. Read-after-write test (cache coherency)
5. Statistics tracking test
6. Cache invalidate test
7. Load-use hazard detection test
8. Multiple memory operations test
9. Different access sizes test (byte, word, long)
10. Integration with pipeline test

**Test Scenarios:**

**Test 1: Read Always Hits**
```vhdl
-- Request data at address 0x1000
mem_req <= '1';
mem_write <= '0';
mem_addr <= x"00001000";
wait until rising_edge(clk);

-- Should hit immediately (1 cycle)
assert mem_ready = '1';
assert hit_count = 1;
assert miss_count = 0;
assert read_count = 1;
```

**Test 2: Write Always Hits**
```vhdl
-- Write data to address 0x2000
mem_req <= '1';
mem_write <= '1';
mem_addr <= x"00002000";
mem_data_in <= x"12345678";
wait until rising_edge(clk);

-- Should hit immediately (1 cycle)
assert mem_ready = '1';
assert hit_count = 1;
assert write_count = 1;
```

**Test 3: Read-After-Write**
```vhdl
-- Write data
mem_req <= '1';
mem_write <= '1';
mem_addr <= x"00003000";
mem_data_in <= x"DEADBEEF";
wait until rising_edge(clk);

-- Read same address
mem_req <= '1';
mem_write <= '0';
mem_addr <= x"00003000";
wait until rising_edge(clk);

-- Should return written data
assert mem_data_out = x"DEADBEEF";
```

**Test 4: Load-Use Hazard**
```vhdl
-- Simulate load instruction
of_ex.mem_read <= '1';
of_ex.dst_reg <= x"0";  -- D0
of_ex.dst_write <= '1';

-- Next instruction uses D0
id_ea.src_reg1 <= x"0";  -- D0
wait until rising_edge(clk);

-- Should detect load-use hazard
assert hazard_info.load_use_hazard = '1';
assert hazard_info.stall_for_load = '1';
```

## Cache Control Register (CACR) Integration

The MC68040 CACR (Cache Control Register) controls both caches:

```
CACR Bits (Data Cache):
┌────┬────┬────┬────┬────┬────┬────┬────┐
│ 31 │ 30 │... │ 15 │ 14 │ 13 │... │  0 │
└────┴────┴────┴────┴────┴────┴────┴────┘
  │    │         │    │    │
  │    │         │    │    └─ DE: D-Cache Enable
  │    │         │    └────── FD: Freeze D-Cache
  │    │         └─────────── No Allocate
  │    └───────────────────── WA: Write Allocate
  └────────────────────────── (other bits)
```

**Phase 6 CACR Integration:**
- `cache_enable` ← CACR bit 31 (DE)
- `cache_freeze` ← CACR bit 29 (FD)
- `cache_invalidate` ← Pulse from CINV instruction
- `cache_flush` ← Pulse from CPUSH instruction

## Deliverables

### Source Files

| File | Status | Description |
|------|--------|-------------|
| `TG68040_DCache.vhd` | ⏳ Planned | Data cache stub |
| `TG68040_HazardUnit.vhd` (updated) | ⏳ Planned | Add load-use hazard detection |
| `TG68040_Pipeline_Regs.vhd` (updated) | ⏳ Planned | Extended hazard_info_t |
| `TG68040_Pipeline.vhd` (updated) | ⏳ Planned | Integrate D-cache with EX stage |

### Test Files

| File | Status | Description |
|------|--------|-------------|
| `test_DCache.vhd` | ⏳ Planned | D-cache unit tests |
| `test_LoadUseHazard.vhd` | ⏳ Planned | Load-use hazard tests |
| `test_Pipeline_DCache.vhd` | ⏳ Planned | Pipeline with D-cache integration |

### Documentation

| Document | Status | Description |
|----------|--------|-------------|
| PHASE6_README.md | ✅ Complete | This file |
| DCACHE_INTERFACE_SPEC.md | ⏳ Planned | Detailed D-cache interface |
| PHASE6_SUMMARY.md | ⏳ Planned | Phase 6 completion report |

## Performance Expectations

### Phase 6 (Stub - Always Hit)

| Metric | Expected | Notes |
|--------|----------|-------|
| Hit Rate | 100% | Stub always hits |
| Miss Penalty | 0 cycles | No misses |
| Load Latency | 1 cycle | Immediate response |
| Store Latency | 1 cycle | Immediate response |
| Load-Use Penalty | +1 cycle | Required stall |
| CPI Impact | +0.2 | Due to load-use stalls |

### Phase 7 (Real Cache)

| Metric | Expected | Notes |
|--------|----------|-------|
| Hit Rate | >85% | Typical data access |
| Miss Penalty | 4-8 cycles | Memory latency |
| Load Latency | 1 cycle (hit) | 5-9 cycles (miss) |
| Store Latency | 1 cycle | Write-back |
| Write-back Penalty | 4-8 cycles | Dirty line eviction |
| CPI Impact | +0.3-0.5 | Due to occasional misses |

## Known Limitations (Phase 6)

1. **Always Hit** - Stub doesn't model real cache behavior (Phase 7)
2. **No Write-Back** - Writes go directly to stub memory (Phase 7)
3. **No Bus Access** - Doesn't fetch from memory (Phase 7)
4. **Fixed Data** - Uses internal data memory (Phase 7)
5. **No LRU** - No replacement algorithm (Phase 7)
6. **No Way Selection** - Not 4-way associative (Phase 7)
7. **No Dirty Bits** - No write-back tracking (Phase 7)
8. **No Snooping** - No cache coherency protocol (Phase 7+)

These are intentional Phase 6 limitations.

## Integration with Previous Phases

### Phase 1 Integration (Control Registers)
- CACR register controls D-cache enable/freeze
- CINV instruction triggers cache invalidate
- CPUSH instruction triggers cache flush
- Cache respects supervisor mode

### Phase 2 Integration (New Instructions)
- MOVE16 uses D-cache for block transfers
- CINV instruction invalidates D-cache
- CPUSH instruction flushes dirty D-cache lines

### Phase 3-4 Integration (Pipeline + Hazards)
- D-cache integrates with EX stage
- Load latency (1 cycle) fits pipeline timing
- Load-use hazards add 1-cycle stall
- Forwarding from WB stage handles most hazards

### Phase 5 Integration (I-Cache)
- I-cache and D-cache operate independently
- Both use same control signals (from CACR)
- Both invalidate together on CINV
- No coherency issues in Phase 6 (stubs)

## Success Criteria

- [ ] D-cache stub implemented
- [ ] Always-hit behavior working (reads and writes)
- [ ] Statistics tracking functional
- [ ] Load-use hazard detection working
- [ ] Integration with EX stage complete
- [ ] Cache enable/disable working
- [ ] Cache invalidate working
- [ ] All unit tests pass
- [ ] Pipeline performance acceptable (load-use stalls expected)
- [ ] Ready for real cache (Phase 7)

## Next Steps (Phase 7)

After Phase 6:
1. Implement real I-cache (4-way set-associative)
2. Implement real D-cache (4-way set-associative)
3. Add LRU replacement algorithm
4. Add write-back with dirty bit tracking
5. Add cache miss handling
6. Add bus interface for memory access
7. Test cache performance with benchmarks

## References

1. MC68040 User's Manual, Section 4: Caches
2. MC68040 User's Manual, Section 5: Cache Control Register
3. MC68040 User's Manual, Section 6: Memory Management
4. Computer Architecture: A Quantitative Approach (Hennessy & Patterson) - Chapter 5: Memory Hierarchy
5. Cache Memory Book (Przybylski)

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
