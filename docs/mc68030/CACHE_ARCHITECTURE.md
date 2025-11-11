# MC68030 Cache Architecture Specification

## Document Purpose

This document specifies the MC68030 on-chip cache architecture, including both the 256-byte instruction cache and 256-byte data cache.

---

## Overview

The MC68030 features two independent on-chip caches:
- **Instruction Cache**: 256 bytes, direct-mapped
- **Data Cache**: 256 bytes, direct-mapped

Both caches improve performance by reducing external bus cycles for frequently accessed code and data.

### Key Characteristics

| Feature | Instruction Cache | Data Cache |
|---------|-------------------|------------|
| **Size** | 256 bytes | 256 bytes |
| **Organization** | Direct-mapped | Direct-mapped |
| **Line Size** | 16 bytes (4 longwords) | 16 bytes (4 longwords) |
| **Number of Lines** | 16 lines | 16 lines |
| **Write Policy** | N/A (read-only) | Write-through |
| **Invalidation** | CACR bits CI, CEI | CACR bits CD, CDE |
| **Freeze Mode** | CACR bit FI | CACR bit FD |
| **Burst Fill** | CACR bit IBE | CACR bit DBE |

---

## Cache Organization

### Direct-Mapped Structure

Both caches use **direct-mapped** organization:
- Each memory address maps to exactly one cache line
- Cache line determined by address bits [7:4] (16 possible lines)
- Fast lookup (no associative search needed)
- Simple implementation
- Potential for thrashing if accessing addresses with same index

### Cache Line Structure

Each cache line contains:
- **Data**: 16 bytes (4 longwords)
- **Tag**: Upper address bits for match detection
- **Valid**: Indicates line contains valid data

```
Cache Line Format (per line):
┌─────────────────────────────────────────────────────────┐
│ Valid (1 bit) │ Tag (24 bits) │ Data (16 bytes / 128 bits) │
└─────────────────────────────────────────────────────────┘
```

### Address Breakdown

For a 32-bit address accessing the cache:

```
 31  30  29  28  27  ...  8   7   6   5   4   3   2   1   0
┌─────────────────────────────┬───────────────┬───────────────┐
│         Tag (24 bits)       │ Index (4 bits)│ Offset (4 bits)│
└─────────────────────────────┴───────────────┴───────────────┘
                                      │              │
                                      │              └─ Word within line (0-3)
                                      │                  + byte within word
                                      └─ Cache line number (0-15)
```

- **Tag [31:8]**: Upper 24 bits for matching (determines if this is the right data)
- **Index [7:4]**: Selects which of 16 cache lines to use
- **Offset [3:0]**: Byte position within the 16-byte cache line

---

## Instruction Cache

### Purpose

Cache frequently executed instructions to reduce bus cycles.

### Characteristics

- **Read-Only**: Instructions are never written through the I-cache
- **Demand Fill**: Loaded on instruction fetch miss
- **Burst Fill**: Optional 4-longword burst read (if IBE=1)
- **Invalidation**: Via CACR bits (CI for all, CEI for one entry)
- **Freeze**: Can freeze to prevent updates (FI bit)

### Operation

**Cache Hit (Fast Path)**
```
1. CPU requests instruction fetch at address A
2. Extract index from A[7:4] → line N
3. Read tag and valid from line N
4. IF valid=1 AND tag matches A[31:8] THEN
      HIT: Return data from cache (1 cycle)
   ELSE
      MISS: Proceed to cache fill
   END IF
```

**Cache Miss (Fill)**
```
1. Request longword from external bus at address A
2. Wait for bus cycle to complete
3. Store data in cache line N
4. Store tag A[31:8] in line N
5. Set valid bit for line N
6. Return data to CPU
```

**Burst Fill (Optional)**
```
1. Request 4-longword burst from external bus at address A
2. Fill entire 16-byte cache line
3. Set tag and valid
4. Return requested longword to CPU
```

### Enable/Disable

Controlled by **CACR.EI** (Enable Instruction cache):
- **EI=0**: Cache disabled, all fetches go to bus
- **EI=1**: Cache enabled, use cache for fetch hits

### Freeze Mode

Controlled by **CACR.FI** (Freeze Instruction cache):
- **FI=0**: Normal operation, update on miss
- **FI=1**: Frozen, no updates (hits still work)
- **Use Case**: Lock critical code in cache (interrupt handlers, etc.)

### Invalidation

**Clear All (CACR.CI)**
```assembly
MOVEC   D0,CACR     ; Write CACR with CI=1
; All 16 I-cache lines marked invalid (valid=0)
; CI bit self-clears after operation
```

**Clear Entry (CACR.CEI + CAAR)**
```assembly
MOVE.L  #$00001000,D0
MOVEC   D0,CAAR         ; Set address
MOVE.L  #<CACR_CEI>,D0
MOVEC   D0,CACR         ; Invalidate entry at address
; I-cache line for index [7:4] of CAAR marked invalid
; CEI bit self-clears
```

---

## Data Cache

### Purpose

Cache frequently accessed data to reduce bus cycles for reads and writes.

### Characteristics

- **Read/Write**: Both loads and stores can use cache
- **Write-Through**: Writes always go to external bus
- **No Write Allocate (default)**: Write miss doesn't load line (unless WA=1)
- **Demand Fill**: Loaded on read miss
- **Burst Fill**: Optional 4-longword burst read (if DBE=1)
- **Invalidation**: Via CACR bits (CD for all, CDE for one entry)
- **Freeze**: Can freeze to prevent updates (FD bit)

### Write-Through Policy

**Write-Through** means all writes go to external memory:
- Write Hit: Update cache AND write to bus
- Write Miss: Write to bus only (unless WA=1, then allocate line)

**Advantage**: Memory always consistent with cache (no write-back needed)
**Disadvantage**: All writes take bus cycles (slower than write-back)

### Write Allocate (Optional)

Controlled by **CACR.WA** (Write Allocate):
- **WA=0**: Write miss doesn't allocate cache line (default)
- **WA=1**: Write miss allocates cache line (fetch before write)

**Write Allocate Operation (WA=1)**
```
1. CPU writes to address A
2. D-cache miss (tag doesn't match or invalid)
3. Read 4 longwords from bus to fill cache line
4. Update cache with new write data
5. Write data to external bus
```

### Operation

**Read Hit**
```
1. CPU reads from address A
2. Extract index from A[7:4]
3. Compare tag with A[31:8]
4. IF hit THEN return data from cache (1 cycle)
5. ELSE miss, proceed to fill
```

**Read Miss**
```
1. Request longword(s) from bus
2. Fill cache line
3. Set valid and tag
4. Return data to CPU
```

**Write Hit**
```
1. CPU writes to address A
2. D-cache hit detected
3. Update cache line data
4. Write to external bus (write-through)
```

**Write Miss (WA=0)**
```
1. CPU writes to address A
2. D-cache miss detected
3. Write to external bus only
4. Do NOT update cache
```

**Write Miss (WA=1)**
```
1. CPU writes to address A
2. D-cache miss detected
3. Read cache line from bus (fill)
4. Update cache with write data
5. Write to external bus
```

### Enable/Disable

Controlled by **CACR.ED** (Enable Data cache):
- **ED=0**: Cache disabled, all accesses go to bus
- **ED=1**: Cache enabled, use cache for hits

### Freeze Mode

Controlled by **CACR.FD** (Freeze Data cache):
- **FD=0**: Normal operation
- **FD=1**: Frozen, no updates
- **Use Case**: Lock frequently accessed data (page tables, etc.)

### Invalidation

**Clear All (CACR.CD)**
```assembly
MOVEC   D0,CACR     ; Write CACR with CD=1
; All 16 D-cache lines marked invalid
; CD bit self-clears
```

**Clear Entry (CACR.CDE + CAAR)**
```assembly
MOVE.L  #$00002000,D0
MOVEC   D0,CAAR         ; Set address
MOVE.L  #<CACR_CDE>,D0
MOVEC   D0,CACR         ; Invalidate entry
; D-cache line for index [7:4] of CAAR marked invalid
; CDE bit self-clears
```

---

## Cache Control via CACR

The **CACR** (Cache Control Register) controls both caches. See `CACHE_REGISTERS.md` for complete register specification.

### CACR Bit Summary

| Bit | Name | Description |
|-----|------|-------------|
| 0 | **EI** | Enable Instruction cache |
| 1 | **FI** | Freeze Instruction cache |
| 2 | **CI** | Clear Instruction cache (self-clearing) |
| 3 | **CEI** | Clear Instruction cache Entry (self-clearing) |
| 4 | **IBE** | Instruction Burst Enable |
| 8 | **ED** | Enable Data cache |
| 9 | **FD** | Freeze Data cache |
| 10 | **CD** | Clear Data cache (self-clearing) |
| 11 | **CDE** | Clear Data cache Entry (self-clearing) |
| 12 | **DBE** | Data Burst Enable |
| 13 | **WA** | Write Allocate |

---

## Burst Mode

Both caches support **burst mode** for faster cache line fills.

### Normal Fill (Burst Disabled)

Without burst, filling a cache line requires 4 separate bus cycles:
```
1. Read longword 0 from address A+0
2. Read longword 1 from address A+4
3. Read longword 2 from address A+8
4. Read longword 3 from address A+12
Total: 4 bus cycles
```

### Burst Fill (Burst Enabled)

With burst (IBE=1 or DBE=1), a single burst transfer reads 4 longwords:
```
1. Start burst read at address A
2. Bus returns 4 consecutive longwords
3. Fill entire cache line in one operation
Total: 1 burst cycle (faster)
```

**Requirements:**
- External bus must support burst mode
- Memory must support consecutive reads
- Typically requires DRAM with burst capability

**Control:**
- **CACR.IBE**: Instruction cache burst enable
- **CACR.DBE**: Data cache burst enable

---

## Cache Coherency

### Self-Modifying Code

**Problem**: CPU writes to memory that contains cached instructions

**Solution**: Software must invalidate I-cache after modifying code
```assembly
; Modify code in memory
MOVE.L  #$4E714E71,(A0)  ; Write NOP instructions

; Invalidate I-cache for that address
MOVE.L  A0,D0
MOVEC   D0,CAAR          ; Set address
MOVE.W  #CACR_CEI,D0
MOVEC   D0,CACR          ; Clear I-cache entry

; Or flush entire I-cache
MOVE.W  #CACR_CI,D0
MOVEC   D0,CACR
```

### DMA and External Bus Masters

**Problem**: DMA writes to memory, bypassing D-cache

**Solution**:
1. Disable D-cache during DMA (ED=0)
2. Or invalidate D-cache after DMA (CD=1)
3. Or don't cache DMA regions (use uncached access)

### Multiprocessor Systems

MC68030 caches are **not** automatically coherent in multiprocessor systems:
- No bus snooping
- No automatic invalidation on external writes
- Software must manage coherency

---

## Performance Characteristics

### Hit Rate

Typical hit rates for well-tuned code:
- **I-cache**: 90-95% (code has good locality)
- **D-cache**: 70-85% (data access more random)

### Cycle Savings

**Instruction Cache Hit:**
- Without cache: 2-4 bus cycles per instruction fetch
- With cache: 0 cycles (internal access)
- **Savings**: 2-4 cycles per hit

**Data Cache Hit:**
- Without cache: 2-4 bus cycles per data access
- With cache read: 0 cycles
- With cache write: Still 2-4 cycles (write-through)
- **Savings**: 2-4 cycles per read hit

### Overall Performance

With typical hit rates and code mix:
- **Expected speedup**: 1.3x to 1.8x vs no cache
- **Best case** (high hit rate): 2x speedup
- **Worst case** (thrashing): Same as no cache

---

## Implementation Details

### Cache Line State

Each cache line has:
```vhdl
type cache_line_t is record
    valid : std_logic;                      -- Line contains valid data
    tag   : std_logic_vector(23 downto 0);  -- Upper address bits
    data  : std_logic_vector(127 downto 0); -- 16 bytes = 4 longwords
end record;
```

### Cache Array

Each cache (I-cache and D-cache) has:
```vhdl
type cache_array_t is array (0 to 15) of cache_line_t;
signal icache : cache_array_t;
signal dcache : cache_array_t;
```

### Lookup Logic

```vhdl
-- Extract address fields
signal index : integer range 0 to 15 := to_integer(unsigned(address(7 downto 4)));
signal tag   : std_logic_vector(23 downto 0) := address(31 downto 8);

-- Check for hit
signal hit : std_logic;
hit <= '1' when (icache(index).valid = '1' and icache(index).tag = tag)
       else '0';
```

### Data Selection

```vhdl
-- Select longword within line (bits 3:2)
signal word_offset : integer range 0 to 3 := to_integer(unsigned(address(3 downto 2)));

-- Extract longword from cache line
case word_offset is
    when 0 => data_out <= icache(index).data(31 downto 0);
    when 1 => data_out <= icache(index).data(63 downto 32);
    when 2 => data_out <= icache(index).data(95 downto 64);
    when 3 => data_out <= icache(index).data(127 downto 96);
end case;
```

---

## Cache Initialization

### Reset Behavior

On reset:
- All cache lines marked **invalid** (valid=0)
- Tags and data undefined (don't care)
- CACR reset to 0 (both caches disabled)

### Startup Sequence

Typical startup:
```assembly
; 1. Clear both caches (redundant but safe)
MOVE.L  #(CACR_CI | CACR_CD),D0
MOVEC   D0,CACR

; 2. Enable both caches
MOVE.L  #(CACR_EI | CACR_ED),D0
MOVEC   D0,CACR

; 3. Optional: Enable burst mode if supported
MOVE.L  #(CACR_EI | CACR_ED | CACR_IBE | CACR_DBE),D0
MOVEC   D0,CACR
```

---

## Cache Testing

### Test Strategies

**1. Basic Fill Test**
```
- Access address with known pattern
- Verify cache miss occurs
- Verify data loaded correctly
- Access same address again
- Verify cache hit occurs
```

**2. All Lines Test**
```
- Access 16 different addresses (index 0-15)
- Verify each fills different cache line
- Verify all lines can be filled
```

**3. Replacement Test**
```
- Fill line N with address A (index N)
- Access address B with same index N
- Verify line replaced (old data gone)
```

**4. Invalidation Test**
```
- Fill cache with known data
- Issue clear command (CI or CD)
- Verify all lines invalid
- Verify next access causes miss
```

**5. Freeze Test**
```
- Fill cache line
- Set freeze bit (FI or FD)
- Access different address same index
- Verify cache NOT updated
- Clear freeze bit
- Verify cache updates normally
```

---

## Integration with TG68K030

### Cache Module Interface

```vhdl
entity TG68K030_ICache is
    port(
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Control from CACR
        enable      : in  std_logic;  -- EI bit
        freeze      : in  std_logic;  -- FI bit
        clear_all   : in  std_logic;  -- CI pulse
        clear_entry : in  std_logic;  -- CEI pulse
        burst_en    : in  std_logic;  -- IBE bit
        clear_addr  : in  std_logic_vector(31 downto 0);  -- From CAAR

        -- CPU interface
        cpu_addr    : in  std_logic_vector(31 downto 0);
        cpu_read    : in  std_logic;
        cpu_data    : out std_logic_vector(31 downto 0);
        cpu_ready   : out std_logic;  -- Data available
        cpu_hit     : out std_logic;  -- Cache hit

        -- Bus interface
        bus_req     : out std_logic;
        bus_addr    : out std_logic_vector(31 downto 0);
        bus_burst   : out std_logic;  -- Burst request
        bus_data    : in  std_logic_vector(127 downto 0);  -- 4 longwords
        bus_ready   : in  std_logic
    );
end entity;
```

---

## Summary

The MC68030 cache architecture provides:
- ✅ Dual 256-byte caches (instruction + data)
- ✅ Direct-mapped organization (simple, fast)
- ✅ 16-byte cache lines (4 longwords)
- ✅ Software control via CACR
- ✅ Flexible invalidation (all or single entry)
- ✅ Freeze mode for locking cache contents
- ✅ Optional burst mode for faster fills
- ✅ Write-through data cache policy

**Next Steps**: Implement I-cache and D-cache VHDL modules.

---

## References

- MC68030 User's Manual, Section 5 (Cache)
- MC68030 User's Manual, Section 4.2 (Cache Operation)
- CACHE_REGISTERS.md (CACR and CAAR specification)
- Phase 2 Summary (Cache register implementation)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Cache architecture specification |
