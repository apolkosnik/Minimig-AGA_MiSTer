# MMU Pipeline Integration Plan

## Overview

This document outlines the integration of the TG68040 MMU with the pipeline for Phase 9B.

## Integration Points

### 1. Instruction Fetch (IF Stage)

**Current Flow:**
```
PC → I-Cache → Instruction
```

**New Flow with MMU:**
```
PC (logical) → I-ATC → Physical Address → I-Cache → Instruction
```

**Changes Required:**
- Add I-ATC lookup between PC and I-Cache
- Logical PC from pipeline → I-ATC translation request
- Physical address from I-ATC → I-Cache fetch address
- Handle translation ready signal (1 cycle for stub)

### 2. Data Access (EA/MEM Stages)

**Current Flow:**
```
EA Address → D-Cache → Data
```

**New Flow with MMU:**
```
EA Address (logical) → D-ATC → Physical Address → D-Cache → Data
```

**Changes Required:**
- Add D-ATC lookup between EA and D-Cache
- Logical EA address → D-ATC translation request
- Physical address from D-ATC → D-Cache access
- Handle translation ready signal (1 cycle for stub)
- Pass access type (read/write) to D-ATC

## Signal Additions to Pipeline

### MMU Instance Signals

```vhdl
-- MMU control registers
signal mmu_tc_reg : tc_register_t;
signal mmu_srp_reg : root_pointer_t;
signal mmu_urp_reg : root_pointer_t;
signal mmu_mmusr_reg : mmusr_register_t;

-- I-ATC signals
signal mmu_itrans_req : translation_request_t;
signal mmu_itrans_resp : translation_response_t;

-- D-ATC signals
signal mmu_dtrans_req : translation_request_t;
signal mmu_dtrans_resp : translation_response_t;

-- Control signals
signal mmu_invalidate_all : std_logic;
signal mmu_invalidate_i : std_logic;
signal mmu_invalidate_d : std_logic;
signal mmu_flush_d : std_logic;
```

### Statistics Signals

```vhdl
-- MMU statistics
signal mmu_iatc_lookups : std_logic_vector(31 downto 0);
signal mmu_iatc_hits : std_logic_vector(31 downto 0);
signal mmu_iatc_misses : std_logic_vector(31 downto 0);
signal mmu_datc_lookups : std_logic_vector(31 downto 0);
signal mmu_datc_hits : std_logic_vector(31 downto 0);
signal mmu_datc_misses : std_logic_vector(31 downto 0);
```

## Pipeline Changes

### IF Stage Modifications

**Before:**
```vhdl
icache_fetch_addr <= std_logic_vector(pc);
```

**After:**
```vhdl
-- Create translation request
mmu_itrans_req.logical_addr <= std_logic_vector(pc);
mmu_itrans_req.access_type <= ACCESS_EXECUTE;
mmu_itrans_req.supervisor <= '1';  -- From status register
mmu_itrans_req.enable <= '1';

-- Use translated address for I-Cache
icache_fetch_addr <= mmu_itrans_resp.physical_addr;

-- Stall if translation not ready (shouldn't happen with stub)
if mmu_itrans_resp.ready = '0' then
    ctrl.stall_if <= '1';
end if;
```

### EA/MEM Stage Modifications

**Before:**
```vhdl
dcache_mem_addr <= ea_address;
```

**After:**
```vhdl
-- Create translation request
mmu_dtrans_req.logical_addr <= ea_address;
mmu_dtrans_req.access_type <= mem_write ? ACCESS_WRITE : ACCESS_READ;
mmu_dtrans_req.supervisor <= supervisor_mode;
mmu_dtrans_req.enable <= mem_req;

-- Use translated address for D-Cache
dcache_mem_addr <= mmu_dtrans_resp.physical_addr;

-- Check for translation faults
if mmu_dtrans_resp.fault /= FAULT_NONE then
    -- Generate exception
    exception <= '1';
    exc_vector <= MMU_FAULT_VECTOR;
end if;

-- Stall if translation not ready
if mmu_dtrans_req.enable = '1' and mmu_dtrans_resp.ready = '0' then
    ctrl.stall_ea <= '1';
end if;
```

## MMU Control Register Initialization

For Phase 9B stub, initialize with sensible defaults:

```vhdl
-- TC Register (MMU initially disabled)
mmu_tc_reg.enable <= '0';  -- MMU disabled by default
mmu_tc_reg.page_size <= x"0";  -- 4KB pages
mmu_tc_reg.fcl_enable <= '0';
mmu_tc_reg.supervisor_mode <= '1';  -- Start in supervisor mode

-- Root Pointers (not used in stub)
mmu_srp_reg <= ROOT_POINTER_INIT;
mmu_urp_reg <= ROOT_POINTER_INIT;
```

## Cache Coordination

### I-Cache + I-ATC
- I-ATC lookup happens before I-Cache access
- Physical address from I-ATC used for cache lookup
- Cache inhibit bit from I-ATC controls caching

### D-Cache + D-ATC
- D-ATC lookup happens before D-Cache access
- Physical address from D-ATC used for cache access
- Cache inhibit bit from D-ATC controls caching
- Modified bit updated in D-ATC on writes
- Cache flush triggers D-ATC flush

## Performance Considerations

### Phase 9B (Current - Stub)
- Translation latency: 1 cycle (combinational + 1 register)
- No additional pipeline stalls (ready in same cycle)
- I-ATC and D-ATC operate independently (no conflicts)

### Future (Phase 9C - Table Walk)
- Translation latency: 2-4 cycles (table walk)
- Pipeline stall during table walk
- Speculative translation for predictable accesses

## Testing Strategy

### Unit Tests
1. MMU disabled (passthrough mode)
2. MMU enabled (1:1 translation)
3. I-ATC hit/miss scenarios
4. D-ATC hit/miss scenarios
5. Protection violations
6. Invalidation and flush

### Integration Tests
1. Simple program execution with MMU disabled
2. Simple program execution with MMU enabled
3. Read and write operations through D-ATC
4. Instruction fetch through I-ATC
5. Cache + MMU coordination

## Implementation Steps

1. **Add MMU Instance to Pipeline**
   - Declare component
   - Add signals
   - Instantiate with port map

2. **Connect I-ATC to IF Stage**
   - Create translation request from PC
   - Use physical address for I-Cache
   - Handle ready signal

3. **Connect D-ATC to EA Stage**
   - Create translation request from EA
   - Use physical address for D-Cache
   - Handle faults and ready signal

4. **Add Stall Logic**
   - Stall IF on I-ATC not ready
   - Stall EA on D-ATC not ready
   - Coordinate with existing stall logic

5. **Initialize Control Registers**
   - Default values on reset
   - Future: Add register write interface

6. **Test Integration**
   - Compile and verify
   - Run unit tests
   - Run integration tests

## Expected Results

After integration:
- Pipeline runs with MMU disabled (1:1 passthrough)
- Pipeline runs with MMU enabled (1:1 translation through ATC)
- I-Cache sees physical addresses from I-ATC
- D-Cache sees physical addresses from D-ATC
- Statistics show ATC hits and misses
- Protection faults detected and reported

## Next Phase (9C)

After baseline integration is complete:
- Implement table walk state machine
- Add real page table support
- Multi-cycle translation handling
- Advanced fault scenarios

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Author:** Claude AI (Anthropic)
