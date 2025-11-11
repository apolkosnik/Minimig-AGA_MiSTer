# MC68030 Bus Interface Architecture

**Document Version:** 1.0
**Date:** 2025-11-11
**Phase:** Phase 6 - Bus Interface Enhancements

---

## Overview

The MC68030 bus interface handles all memory accesses from the CPU, integrating the MMU for address translation, caches for performance, and supporting burst mode for efficient cache line fills.

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                       CPU Core                                │
│  ┌────────┐  ┌────────┐  ┌────────┐                         │
│  │ Decode │  │Execute │  │ Memory │                          │
│  └────┬───┘  └────────┘  └───┬────┘                         │
│       │                       │                               │
│       │  Virtual Address      │                               │
│       └───────────────────────┘                               │
└───────────────────────┬───────────────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │   Bus Interface Controller    │
        │                               │
        │  ┌─────────────────────────┐ │
        │  │ Address Translation     │ │
        │  │ (MMU Integration)       │ │
        │  └────────┬────────────────┘ │
        │           │                   │
        │           ▼                   │
        │  ┌─────────────────────────┐ │
        │  │ Cache Lookup            │ │
        │  │ (I-Cache / D-Cache)     │ │
        │  └────────┬────────────────┘ │
        │           │                   │
        │      Hit  │  Miss             │
        │           │                   │
        │           ▼                   │
        │  ┌─────────────────────────┐ │
        │  │ Bus Arbiter             │ │
        │  │ - CPU requests          │ │
        │  │ - MMU table walks       │ │
        │  │ - Cache fills           │ │
        │  └────────┬────────────────┘ │
        └───────────┼───────────────────┘
                    │
                    ▼
        ┌───────────────────────────┐
        │   External Memory Bus     │
        │  - Normal (single cycle)  │
        │  - Burst (4-beat)         │
        │  - DSACK (dynamic sizing) │
        └───────────────────────────┘
                    │
                    ▼
            ┌───────────────┐
            │    Memory     │
            └───────────────┘
```

---

## Components

### 1. Bus Interface Controller

**Module:** `TG68K030_BusInterface.vhd`

Central controller that manages all bus transactions:
- Receives memory requests from CPU
- Coordinates MMU translation
- Checks caches (I-cache for instructions, D-cache for data)
- Arbitrates between multiple bus masters
- Generates external bus cycles

**Key Responsibilities:**
- Request queuing
- Priority management
- Bus protocol generation
- Error handling

### 2. Address Translation Unit

**Integration with MMU**

All virtual addresses pass through the MMU for translation:

```vhdl
-- Virtual to Physical Translation
virt_addr (CPU) → MMU Translation → phys_addr (Memory)
                        ↓
                   Cache Inhibit Flag
```

**Flow:**
1. CPU presents virtual address
2. MMU performs translation:
   - Check Transparent Translation (TT0/TT1)
   - Check ATC cache
   - Perform table walk if needed
3. MMU returns:
   - Physical address
   - Cache inhibit flag
   - Protection flags
4. Bus interface uses physical address for memory access

### 3. Cache Integration

**I-Cache (Instruction Cache)**

```
CPU Instruction Fetch → Virtual Address
    ↓
MMU Translation → Physical Address
    ↓
I-Cache Lookup (if CI = 0)
    ↓
  Hit: Return cached data
  Miss: Perform cache fill (burst mode)
```

**D-Cache (Data Cache)**

```
CPU Data Access → Virtual Address
    ↓
MMU Translation → Physical Address
    ↓
D-Cache Lookup (if CI = 0)
    ↓
  Hit: Return/Write cached data
  Miss: Perform memory access
  Write: Write-through to memory
```

**Cache Inhibit:**
- When MMU returns CI = 1, bypass cache
- Go directly to external bus
- Used for I/O regions, DMA buffers

### 4. Bus Arbiter

**Bus Masters:**
1. **CPU** - Normal instruction/data accesses
2. **MMU** - Page table walks
3. **I-Cache** - Line fills (burst mode)
4. **D-Cache** - Line fills (burst mode)

**Priority (highest to lowest):**
1. MMU table walks (critical for forward progress)
2. CPU data access (performance critical)
3. CPU instruction fetch
4. Cache fills (background)

**Arbitration Logic:**
```
if mmu_table_walk_pending then
    grant_mmu()
elsif cpu_data_request then
    grant_cpu_data()
elsif cpu_instruction_request then
    grant_cpu_instruction()
elsif cache_fill_pending then
    grant_cache_fill()
end if
```

---

## Burst Mode Support

### MC68030 Burst Protocol

The MC68030 supports **4-beat burst transfers** for cache line fills:

```
Beat 1: Address + BURST asserted
Beat 2: Data 1
Beat 3: Data 2
Beat 4: Data 3
Beat 5: Data 4 (BURST deasserted)
```

**Timing:**
- Each beat is 1-3 cycles depending on memory speed
- Total: 4-12 cycles for 16-byte cache line
- vs. 16-48 cycles for 4 separate accesses

### Cache Line Fill

**16-byte cache line = 4 longwords**

```
I-Cache Miss at address 0x10000004:

1. Calculate line base: 0x10000000 (aligned to 16 bytes)
2. Assert BURST signal
3. Request 4 longwords:
   - 0x10000000
   - 0x10000004
   - 0x10000008
   - 0x1000000C
4. Write all 4 longwords to cache line
5. Deassert BURST, return requested word
```

### Burst State Machine

```
IDLE
  ↓ (cache miss)
BURST_START
  ├─ Assert address
  ├─ Assert BURST signal
  ├─ Assert AS (Address Strobe)
  └─ Wait DSACK
  ↓
BURST_BEAT1
  ├─ Capture data[0]
  └─ Wait DSACK
  ↓
BURST_BEAT2
  ├─ Capture data[1]
  └─ Wait DSACK
  ↓
BURST_BEAT3
  ├─ Capture data[2]
  └─ Wait DSACK
  ↓
BURST_BEAT4
  ├─ Capture data[3]
  ├─ Deassert BURST
  └─ Write cache line
  ↓
COMPLETE
```

---

## Bus Signals

### MC68030 External Bus Signals

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| A[31:0] | Out | 32 | Address bus |
| D[31:0] | InOut | 32 | Data bus |
| SIZ[1:0] | Out | 2 | Transfer size (byte/word/long) |
| R/W | Out | 1 | Read=1, Write=0 |
| AS | Out | 1 | Address strobe |
| DS | Out | 1 | Data strobe |
| DSACK[1:0] | In | 2 | Data transfer acknowledge |
| BERR | In | 1 | Bus error |
| HALT | In | 1 | Halt request |
| BURST | Out | 1 | Burst transfer indicator |
| FC[2:0] | Out | 3 | Function code |

### DSACK Encoding (Dynamic Sizing)

| DSACK[1:0] | Meaning |
|------------|---------|
| 11 | No acknowledge (wait) |
| 10 | 8-bit port |
| 01 | 16-bit port |
| 00 | 32-bit port |

### Burst Mode Signals

**BURST = 1** indicates burst transfer in progress:
- Memory should prepare for sequential accesses
- Address increments by 4 each beat
- Faster acknowledge expected

---

## Memory Access Types

### 1. CPU Instruction Fetch

```
1. CPU requests instruction at virtual address
2. MMU translates to physical address
3. Check I-cache (if not CI)
   - Hit: Return from cache (1 cycle)
   - Miss: Perform burst fill
4. If CI or cache disabled:
   - Perform single-cycle bus access
5. Return instruction to CPU
```

**Performance:**
- I-cache hit: ~1 cycle
- I-cache miss (burst): ~8 cycles
- I-cache disabled: ~3-5 cycles

### 2. CPU Data Access

```
1. CPU requests data at virtual address
2. MMU translates to physical address
3. Check D-cache (if not CI)
   - Read hit: Return from cache (1 cycle)
   - Read miss: Fetch from memory, update cache
   - Write hit: Update cache + write-through
   - Write miss: Write to memory (no allocate)
4. If CI or cache disabled:
   - Perform single-cycle bus access
5. Return data to CPU (read) or complete (write)
```

**Performance:**
- D-cache read hit: ~1 cycle
- D-cache read miss: ~5 cycles
- D-cache write: ~3-5 cycles (write-through)

### 3. MMU Table Walk

```
1. MMU needs descriptor from page table
2. Request bus access (high priority)
3. Perform single-cycle read:
   - Assert address (physical)
   - Assert AS, DS
   - Wait for DSACK
   - Capture descriptor
4. Return to MMU for processing
```

**Performance:**
- Table walk fetch: ~3-5 cycles per descriptor
- 4-level walk: ~12-20 cycles total

### 4. Cache Fill (Burst)

```
1. Cache miss detected
2. Request burst access
3. Calculate line base address (align to 16 bytes)
4. Perform 4-beat burst:
   - Beat 1: base + 0
   - Beat 2: base + 4
   - Beat 3: base + 8
   - Beat 4: base + 12
5. Write entire line to cache
6. Return requested word to CPU
```

**Performance:**
- Burst fill: ~8-12 cycles (4 longwords)
- vs. ~12-20 cycles (4 separate accesses)
- Speedup: ~40-60%

---

## Bus Arbitration Example

**Scenario:** Multiple simultaneous requests

```
Time    CPU     MMU     I-Cache  D-Cache  Bus State
----    ---     ---     -------  -------  ----------
T0      Fetch   Idle    Idle     Idle     CPU granted (I-fetch)
T1      Fetch   Walk    Miss     Idle     CPU completes
T2      Exec    Walk    Miss     Idle     MMU granted (priority)
T3      Exec    Walk    Miss     Idle     MMU reading descriptor
T4      Data    Walk    Miss     Idle     MMU reading descriptor
T5      Data    Walk    Miss     Hit      MMU completes
T6      Data    Idle    Miss     Hit      CPU data granted
T7      Data    Idle    Miss     Hit      CPU reading data
T8      Idle    Idle    Miss     Hit      CPU completes
T9      Idle    Idle    Miss     Hit      I-Cache fill granted
T10-13  Idle    Idle    Fill     Hit      Burst transfer (4 beats)
T14     Idle    Idle    Idle     Hit      All idle
```

---

## Error Handling

### Bus Errors (BERR)

**Causes:**
- Invalid physical address
- Memory not responding
- Protection violation
- Parity error

**Handling:**
1. Detect BERR assertion during bus cycle
2. Abort current transfer
3. Signal exception to CPU
4. CPU enters exception processing:
   - Push PC, SR to stack
   - Vector to bus error handler

### MMU Exceptions

**Causes:**
- Invalid descriptor
- Write to protected page
- Supervisor violation

**Handling:**
1. MMU detects error during translation
2. Set MMUSR error bits
3. Signal exception to CPU
4. CPU enters MMU exception processing

### Cache Consistency

**Problem:** Multiple masters updating memory

**Solutions:**
- Write-through D-cache ensures memory is always current
- External bus snooping (advanced feature)
- Software cache flush when needed

---

## Performance Optimization

### 1. Speculative I-Cache Fills

Start cache fill before instruction decode confirms address:
- Reduces latency
- Can abort if branch taken

### 2. Write Buffering

Buffer writes to allow CPU to continue:
- D-cache write completes immediately
- Write-through happens in background
- Up to 4 writes buffered

### 3. Burst Priority

Optimize burst transfers:
- Once started, complete without interruption
- Prevents bus thrashing
- Improves overall bandwidth

### 4. MMU TLB Optimization

Minimize table walks:
- 22-entry ATC provides good hit rate
- Transparent translation bypasses ATC entirely
- Most accesses hit ATC (>95%)

---

## Implementation Notes

### Module Hierarchy

```
TG68K030_BusInterface (top-level)
├── TG68K030_BusArbiter
│   ├── Priority encoder
│   └── Grant logic
├── TG68K030_BurstController
│   ├── State machine
│   └── Address generator
├── TG68K030_CacheController
│   ├── I-cache interface
│   ├── D-cache interface
│   └── Fill logic
└── TG68K030_BusProtocol
    ├── Signal generation (AS, DS, R/W)
    ├── DSACK handling
    └── Error detection
```

### State Management

**Bus cycle states:**
- IDLE: No transaction
- ADDRESS: Assert address and control
- DATA: Wait for DSACK, capture/drive data
- COMPLETE: Cycle done
- ERROR: BERR detected

### Timing

**Critical timing constraints:**
- AS to DSACK: max 8 clock cycles
- BURST beat-to-beat: max 3 clock cycles
- MMU translation: max 2 clock cycles (ATC hit)

---

## Testing Strategy

### Unit Tests

1. **Burst controller**: Verify 4-beat sequence
2. **Bus arbiter**: Verify priority and fairness
3. **Cache interface**: Verify fill logic
4. **Error handling**: Verify BERR response

### Integration Tests

1. **CPU + MMU + Cache**: End-to-end access
2. **Simultaneous requests**: Arbitration under load
3. **Burst vs. single**: Performance comparison
4. **Error injection**: Bus error recovery

### System Tests

1. **Boot sequence**: Real software
2. **Cache stress**: Random accesses
3. **MMU stress**: Many translations
4. **Performance**: Bandwidth and latency

---

## Future Enhancements

### 1. Dynamic Bus Sizing

Support 8/16-bit buses:
- Auto-detect via DSACK
- Split 32-bit accesses
- Handle misalignment

### 2. Write Posting

More sophisticated write buffering:
- Larger write buffer
- Coalescing of adjacent writes
- Out-of-order completion

### 3. Bus Snooping

Cache coherency:
- Monitor external bus
- Invalidate cache on write by other master
- Support multiprocessor systems

### 4. Pipelined Bus

Overlap transactions:
- Start next address phase while completing data
- Improves burst throughput
- Requires careful state management

---

## Conclusion

The MC68030 bus interface integrates MMU translation, dual caches, and burst mode support to provide high-performance memory access. Key features:

- ✅ MMU integration for virtual memory
- ✅ Dual cache support (I-cache, D-cache)
- ✅ Burst mode for cache fills (4-beat)
- ✅ Bus arbitration (CPU, MMU, caches)
- ✅ Error handling (BERR, MMU exceptions)
- ✅ Performance optimization (write-through, speculative)

The design balances performance, complexity, and FPGA resource usage for the MiSTer/Minimig platform.

---

## References

- MC68030 User's Manual, Section 7: Bus Operation
- MC68030 User's Manual, Section 8: Signal Description
- TG68K_Kernel.vhd - Existing bus interface
- PHASE5_PROGRESS_REPORT.md - MMU implementation
- CACHE_ARCHITECTURE.md - Cache design

---

**Document Status:** Complete
**Next:** Implement bus interface controller
