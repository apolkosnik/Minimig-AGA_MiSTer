# MC68030 MMU Edge vs Level Triggering Analysis

**Date:** 2025-11-19
**Branch:** claude/fix-mmu-instructions-01FeSFg5YjABjafwLUUHT4xP
**Analysis Scope:** Edge-triggered vs level-triggered signal handling in MMU operations

---

## Executive Summary

The MMU implementation uses a **mixed approach** with both edge-triggered and level-triggered signals. After thorough analysis, I found **one potential edge case issue** but the overall design is sound.

**Key Findings:**
- ✅ PMMU instructions (PTEST/PFLUSH/PLOAD) properly edge-triggered
- ✅ Register writes/reads properly edge-triggered
- ✅ Translation requests level-triggered by design (correct)
- ⚠️ **One edge case**: req staying high after walker fault could trigger unwanted retry

---

## 1. PMMU Instruction Triggering ✅

### Implementation: **Edge-Triggered** (CORRECT)

**Code:** TG68K_PMMU_030.vhd, lines 2387-2428

```vhdl
-- Update previous values for edge detection
ptest_req_prev <= ptest_req;
pflush_req_prev <= pflush_req;
pload_req_prev <= pload_req;

-- PTEST: Set flag on rising edge only (prevents multiple triggers)
if ptest_req = '1' and ptest_req_prev = '0' then
  ptest_update_mmusr <= '1';
else
  ptest_update_mmusr <= '0';
end if;

-- PFLUSH: Edge detection and parameter capture
if pflush_req = '1' and pflush_req_prev = '0' then
  pflush_active <= '1';
  pflush_addr <= pmmu_addr;
  pflush_fc <= pmmu_fc;
  pflush_mode <= pmmu_brief(12 downto 8);
  pflush_clear_atc <= '1';
elsif pflush_active = '1' then
  pflush_active <= '0';
  pflush_clear_atc <= '0';
end if;

-- PLOAD: Edge detection and implementation
if pload_req = '1' and pload_req_prev = '0' then
  pload_active <= '1';
  pload_addr <= pmmu_addr;
  pload_fc <= pmmu_fc;
  pload_rw <= pmmu_brief(9);
elsif pload_active = '1' then
  pload_active <= '0';
end if;
```

**Analysis:** ✅ **CORRECT**
- Uses `_prev` signals to detect rising edge
- Prevents multiple triggers from sustained signal
- Latches parameters (addr, fc, mode) on edge
- One-cycle pulse for execution

**Why Edge-Triggered?**
- PMMU instructions execute once per invocation
- CPU asserts req for multiple cycles during execution
- Edge detection ensures instruction executes exactly once

---

## 2. PMMU Register Access Triggering ✅

### Implementation: **Edge-Triggered** (CORRECT)

**Code:** TG68K_PMMU_030.vhd, lines 770, 931

```vhdl
-- BUG #16 FIX: Use edge detection instead of level (prevents multi-cycle writes)
if reg_we = '1' and reg_we_prev = '0' then
  -- MC68030 Specification: MMU register access requires supervisor mode
  case reg_sel is
    when "00010" => TT0 <= reg_wdat and TTR_WRITE_MASK;
    when "00011" => TT1 <= reg_wdat and TTR_WRITE_MASK;
    -- ... other registers
  end case;
end if;

-- BUG #16 FIX: Use edge detection instead of level (prevents multi-cycle reads)
if reg_re = '1' and reg_re_prev = '0' then
  case reg_sel is
    when "00010" => reg_rdat <= TT0;
    when "00011" => reg_rdat <= TT1;
    -- ... other registers
  end case;
end if;
```

**Analysis:** ✅ **CORRECT**
- Labeled as "BUG #16 FIX" - was previously level-triggered
- Edge detection prevents multi-cycle writes to same register
- Prevents register corruption from sustained signals

**Why Edge-Triggered?**
- PMOVE instruction should write register exactly once
- reg_we may be asserted for multiple cycles during instruction execution
- Edge detection ensures single write per PMOVE

---

## 3. Translation Request Triggering 🟡

### Implementation: **Level-Triggered** (BY DESIGN, mostly correct)

**Code:** TG68K_PMMU_030.vhd, lines 1114-1340

```vhdl
-- Process translation requests first
if req = '1' then  -- ⚠️ LEVEL-TRIGGERED
  -- Clear previous fault state for new translation request
  if walker_fault = '0' and walker_fault_ack_pending = '0' then
    fault_reg <= '0';
    fault_status_reg <= (others => '0');
  end if;

  if tc_en = '0' then
    -- MMU disabled - identity translation (COMBINATIONAL)
    addr_phys_reg <= addr_log;
    cache_inhibit_reg <= '0';
    write_protect_reg <= '0';
    fault_reg <= '0';
    translation_pending <= '0';
  else
    -- MMU enabled - check TTR (COMBINATIONAL)
    ttr_check(TT0, addr_log, fc, is_insn, rw, tmatch0, tci0, twp0);
    ttr_check(TT1, addr_log, fc, is_insn, rw, tmatch1, tci1, twp1);

    if tmatch0 = '1' or tmatch1 = '1' then
      -- TTR hit (COMBINATIONAL)
      addr_phys_reg <= addr_log;
      cache_inhibit_reg <= tci0 or tci1;
      -- ...
    else
      -- Check ATC (COMBINATIONAL LOOKUP)
      for i in 0 to ATC_ENTRIES-1 loop
        if atc_valid(i) = '1' and atc_fc(i) = fc and ... then
          hit := '1';
          hit_idx := i;
        end if;
      end loop;

      if hit = '1' then
        -- ATC hit (COMBINATIONAL)
        phys_base := unsigned(atc_phys_base(hit_idx));
        offset := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
        addr_phys_reg <= std_logic_vector(phys_base + offset);
        -- ...
      else
        -- ATC miss - start walker (ONLY IF NOT PENDING)
        if tmatch0 = '0' and tmatch1 = '0' and translation_pending = '0' then
          saved_addr_log <= addr_log;
          saved_fc <= fc;
          saved_is_insn <= is_insn;
          saved_rw <= rw;
          walk_req <= '1';
          translation_pending <= '1';  -- ⚠️ Prevents re-trigger
        end if;
      end if;
    end if;
  end if;
end if;
```

**Analysis:** ✅ **MOSTLY CORRECT** (by design)

**Design Intent:**
- `req` is level-triggered to allow **combinational response** for fast paths
- Comment (line 34): "Translation request (combinational response acceptable for identity)"
- Fast paths (MMU disabled, TTR hit, ATC hit) respond every cycle
- Slow path (ATC miss) triggers walker **once** via `translation_pending` flag

**Flow Timeline:**

```
Cycle 1: req='1', ATC miss
  → walk_req='1'
  → translation_pending='1'
  → Walker starts

Cycles 2-N: req='1' (still high), translation_pending='1'
  → ATC lookup runs every cycle (combinational)
  → Walker hasn't filled ATC yet, so still miss
  → translation_pending='1' prevents re-triggering walker
  → No harm, just repeated ATC lookups

Cycle M: Walker completes
  → Fills ATC in W_FILL state
  → Goes to W_COMPLETE
  → Sets walker_completed='1'

Cycle M+1: req='1', walker_completed='1'
  → Clears translation_pending='0'
  → ATC lookup finds entry just filled by walker
  → **HIT!** Returns translated address
  → CPU gets response
```

**Why Level-Triggered Works:**
1. Combinational paths (MMU off, TTR, ATC) need to respond every cycle req is high
2. `translation_pending` flag prevents walker re-trigger during walk
3. After walker fills ATC, next cycle with req='1' becomes an ATC hit
4. This allows single-cycle turnaround after walker completion

---

## 4. ⚠️ POTENTIAL ISSUE: req High After Walker Fault

### Scenario

What if `req` stays high after a **walker fault**?

**Timeline:**
```
Cycle 1: req='1', ATC miss
  → walk_req='1', translation_pending='1'
  → Walker starts

Cycle N: Walker faults (invalid descriptor, write protect, etc.)
  → walker_fault='1'
  → walker_completed='1' (even on fault!)
  → Stays in W_IDLE

Cycle N+1: req='1' (CPU hasn't seen fault yet), walker_completed='1'
  → Main process sees walker_fault='1'
  → Sets fault_reg='1', fault_status_reg
  → Clears translation_pending='0'  (line 1449)
  → walker_fault_ack='1'

Cycle N+2: req='1' (CPU STILL hasn't deasserted req), walker_fault='0' (cleared by ack)
  → req='1' and translation_pending='0'
  → ⚠️ COULD TRIGGER ANOTHER WALKER!
```

**Code:** Lines 1117-1120, 1449
```vhdl
-- Clear previous fault state for new translation request ONLY if not from walker
if walker_fault = '0' and walker_fault_ack_pending = '0' then
  fault_reg <= '0';  -- Clears fault!
  fault_status_reg <= (others => '0');
end if;

-- ... later, on walker fault:
translation_pending <= '0';  -- ⚠️ Allows re-trigger!
```

### Analysis

**Problem:**
1. Walker faults and sets `walker_fault='1'`
2. Main process acknowledges with `walker_fault_ack='1'`
3. Walker clears `walker_fault='0'` on ack (line 2344)
4. Main process clears `translation_pending='0'` (line 1449)
5. If `req` is STILL '1', the code at line 1326 could trigger walker again
6. But line 1117 says `if walker_fault = '0'`, so fault is cleared
7. This means **the fault from the previous walk is cleared and walker re-triggered for the SAME address that just faulted!**

**Is This a Bug?**

Not necessarily - it depends on CPU behavior:
- **If CPU deasserts `req` when it sees a fault**: No problem
- **If CPU keeps `req='1'` after fault**: Infinite retry loop!

**Current Mitigation:**

Looking at line 1238-1240:
```vhdl
if walker_fault = '1' and walker_fault_ack_pending = '1' then
  -- Walker fault is pending - don't overwrite with ATC results
  report "ATC_SKIP: Skipping ATC processing due to pending walker fault" severity note;
```

And line 1117:
```vhdl
if walker_fault = '0' and walker_fault_ack_pending = '0' then
  fault_reg <= '0';
  fault_status_reg <= (others => '0');
end if;
```

So there's `walker_fault_ack_pending` flag that should prevent this... let me check if it works.

Looking at lines 1462-1463:
```vhdl
walker_fault_ack <= '1';
walker_fault_ack_pending <= '1';
```

And line 1595-1598:
```vhdl
if walker_fault = '0' and walker_fault_ack_pending = '1' then
  walker_fault_ack <= '0';
  walker_fault_ack_pending <= '0';
end if;
```

So the logic is:
1. Walker faults → walker_fault='1'
2. Main sets walker_fault_ack='1', walker_fault_ack_pending='1'
3. Walker sees ack, clears walker_fault='0'
4. Main sees walker_fault='0', clears walker_fault_ack='0', walker_fault_ack_pending='0'
5. Now line 1117 condition becomes true: walker_fault='0' AND walker_fault_ack_pending='0'
6. Fault is cleared!
7. If req='1', walker could re-trigger

**Hmm, this could be an issue if req stays high!**

But practically, the CPU should:
1. See fault_reg='1' or fault output signal
2. Deassert req
3. Handle the fault (exception, retry with different parameters, etc.)

So this is probably fine in practice, but it's an **assumption about CPU behavior**.

### Severity

- **Severity**: 🟡 **MODERATE**
- **Likelihood**: Low (requires CPU to keep req='1' after fault)
- **Consequence**: Infinite retry loop for faulting address

### Recommended Fix

Add edge detection for `req` or add explicit check to prevent walker trigger immediately after fault:

```vhdl
signal req_prev : std_logic := '0';
signal walker_fault_latched : std_logic := '0';

-- In main process:
req_prev <= req;

-- When walker faults:
if walker_fault = '1' then
  walker_fault_latched <= '1';
end if;

-- Clear latched fault only when req goes low
if req = '0' then
  walker_fault_latched <= '0';
end if;

-- Modify walker trigger condition:
if tmatch0 = '0' and tmatch1 = '0' and
   translation_pending = '0' and
   walker_fault_latched = '0' and  -- NEW: Don't re-trigger immediately after fault
   req = '1' and req_prev = '0' then  -- NEW: Optional edge trigger
  walk_req <= '1';
  translation_pending <= '1';
end if;
```

**Alternative:** Assume CPU properly deasserts req on fault (document this requirement)

---

## 5. Summary of Edge vs Level Triggering

| Signal | Triggering | Implementation | Status |
|--------|-----------|----------------|--------|
| `ptest_req` | Edge | `ptest_req='1' and ptest_req_prev='0'` | ✅ Correct |
| `pflush_req` | Edge | `pflush_req='1' and pflush_req_prev='0'` | ✅ Correct |
| `pload_req` | Edge | `pload_req='1' and pload_req_prev='0'` | ✅ Correct |
| `reg_we` | Edge | `reg_we='1' and reg_we_prev='0'` | ✅ Correct (BUG #16 fix) |
| `reg_re` | Edge | `reg_re='1' and reg_re_prev='0'` | ✅ Correct (BUG #16 fix) |
| `req` | Level | `if req='1' then` | ✅ Correct by design |
| `req` after fault | Level | No edge detection | ⚠️ Potential issue |

---

## 6. Detailed Flow Analysis

### 6.1 Normal Translation (ATC Miss → Walker → ATC Hit)

```
Cycle 1: req='1', ATC miss, translation_pending='0'
  Action: Start walker
  - walk_req='1'
  - translation_pending='1'
  - saved_addr_log, saved_fc, saved_is_insn, saved_rw latched

Cycle 2: req='1', translation_pending='1', wstate=W_ROOT
  Action: Walker requests root descriptor
  - mem_req='1'
  - ATC lookup runs (combinational) but still misses
  - translation_pending='1' prevents re-trigger

Cycle 3-N: Walker walks page tables
  Action: Multi-cycle table walk
  - W_ROOT → W_PTR1 → W_PTR2 → W_PAGE
  - Each state: mem_req='1', wait mem_ack='1', process descriptor
  - translation_pending='1' throughout

Cycle M: wstate=W_FILL
  Action: Walker fills ATC
  - atc_log_base(atc_rr) <= walk_log_base
  - atc_phys_base(atc_rr) <= walk_phys_base
  - atc_valid(atc_rr) <= '1'
  - wstate <= W_COMPLETE

Cycle M+1: wstate=W_COMPLETE
  Action: Signal completion
  - walker_completed <= '1'
  - wstate <= W_IDLE

Cycle M+2: req='1', walker_completed='1'
  Action: Main process sees completion
  - translation_pending <= '0'
  - walker_completed_ack <= '1'
  - ATC lookup (combinational)
  - **HIT!** (finds entry filled in cycle M)
  - addr_phys_reg <= phys_base + offset
  - CPU gets translated address

Cycle M+3: walker_completed='0' (cleared by ack)
  Action: Handshake complete
  - walker_completed_ack <= '0'
  - Ready for next request
```

### 6.2 Translation with Fault

```
Cycle 1: req='1', ATC miss
  Action: Start walker
  - walk_req='1', translation_pending='1'

Cycle 2-N: Walker walks tables
  Action: Table walk in progress

Cycle M: Walker encounters invalid descriptor
  Action: Fault detected
  - walker_fault <= '1'
  - walker_fault_status <= (bus_error=>'1', invalid=>'1', ...)
  - walker_completed <= '1' (even on fault!)
  - wstate <= W_FAULT → W_IDLE

Cycle M+1: req='1', walker_fault='1', walker_completed='1'
  Action: Main process sees fault
  - fault_reg <= '1'
  - fault_status_reg <= walker_fault_status
  - translation_pending <= '0'  ⚠️
  - walker_fault_ack <= '1'
  - walker_fault_ack_pending <= '1'

Cycle M+2: walker_fault='0' (cleared by ack)
  Action: Fault ack handshake
  - walker_fault_ack <= '0' (when walker_fault='0')
  - walker_fault_ack_pending <= '0'

Cycle M+3: req='1' (if CPU hasn't deasserted)
  Action: ⚠️ **POTENTIAL RE-TRIGGER**
  - translation_pending='0'
  - walker_fault='0'
  - walker_fault_ack_pending='0'
  - Line 1117: Clears fault_reg='0'!
  - Line 1326: Could trigger walker again!
  - **Same faulting address would be walked again → infinite loop!**
```

---

## 7. Conclusions

### What's Correct ✅

1. **PMMU Instructions**: Properly edge-triggered to execute once per invocation
2. **Register Access**: Properly edge-triggered after BUG #16 fix
3. **Translation Fast Paths**: Level-triggered by design for combinational response
4. **Walker State Machine**: Proper one-cycle delays for ATC visibility
5. **Walker Handshake**: Proper four-way handshake with completion ack

### Potential Issue ⚠️

**req staying high after walker fault could cause infinite retry loop**

**Mitigation Options:**
1. **Document requirement**: CPU must deassert req on fault (current approach)
2. **Add edge detection**: Trigger walker only on req rising edge
3. **Add fault latch**: Prevent re-trigger until req goes low

### Recommendation

**Option 1: Document Requirement** (Lowest risk, matches likely CPU behavior)
- Add comment in code: "CPU must deassert req when fault_reg='1'"
- Document in interface specification
- This is probably how CPU already behaves

**Option 2: Add Fault Latch** (Defense-in-depth)
```vhdl
signal req_after_fault_block : std_logic := '0';

-- Set block when fault occurs
if walker_fault = '1' then
  req_after_fault_block <= '1';
end if;

-- Clear block when req goes low
if req = '0' then
  req_after_fault_block <= '0';
end if;

-- Modify trigger condition
if ... and req_after_fault_block = '0' then
  walk_req <= '1';
end if;
```

---

**Analysis performed by:** Claude Code (Anthropic AI)
**Analysis date:** 2025-11-19
**Report version:** 1.0
