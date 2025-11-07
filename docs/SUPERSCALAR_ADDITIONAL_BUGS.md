# Additional Critical Bugs Found in Superscalar Implementation

## Beyond the Original 22 Issues

### 23. 🚨 **CRITICAL: Issue Logic Uses Wrong IQ Entry**
**File:** fx68k_superscalar.sv:271-294
**Severity:** CRITICAL - Will execute wrong instructions

**Problem:**
- Issue logic scans ALL IQ entries (i = 0 to 7) to find ready instruction
- Finds ready instruction at position `i`
- But ALU is fed `inst_queue[iq_head].inst` (NOT `inst_queue[i].inst`)

**Code:**
```systemverilog
// Lines 271-279: Scan finds ready instruction at position i
for (int i = 0; i < IQ_ENTRIES; i++) begin
    if (inst_queue[i].valid && ...) begin
        can_issue[0] = 1'b1;
        issue_to_eu[0] = inst_queue[i].inst.exec_unit;
        break;  // Found at position i
    end
end

// Lines 293-294: But ALU gets instruction from iq_head!
fx68k_ss_alu alu0 (
    .inst(inst_queue[iq_head].inst),  // WRONG! Should be inst_queue[i].inst
    ...
);
```

**Impact:**
- Executes instruction at iq_head instead of the ready instruction at position i
- Complete chaos - wrong instructions execute
- Data corruption, crashes

**Fix:** Must track which IQ entry is being issued and pass that instruction

---

### 24. 🚨 **CRITICAL: Both ALUs Execute Same Instruction**
**File:** fx68k_superscalar.sv:293, 306
**Severity:** CRITICAL - Dual-issue broken

**Problem:**
```systemverilog
// ALU0 gets this instruction:
.inst(inst_queue[iq_head].inst),

// ALU1 ALSO gets the same instruction:
.inst(inst_queue[iq_head].inst),
```

**Impact:**
- Both ALUs execute identical instruction
- Wastes execution unit
- Can never achieve dual-issue

**Fix:** ALU1 should get inst_queue[iq_head + 1].inst (or different entry)

---

### 25. 🚨 **CRITICAL: Conditional Enqueue Logic Bug**
**File:** fx68k_superscalar.sv:225-250
**Severity:** CRITICAL - Creates holes in IQ

**Problem:**
```systemverilog
if (decoded[0].valid && iq_count < IQ_ENTRIES) begin
    inst_queue[iq_tail] <= {...};      // Write to position iq_tail
    iq_tail <= iq_tail + 1;
}

if (decoded[1].valid && iq_count < (IQ_ENTRIES - 1)) begin
    inst_queue[iq_tail + 1] <= {...};  // Write to position iq_tail + 1
    iq_tail <= iq_tail + 2;
}
```

**Scenario:** What if decoded[0] is INVALID but decoded[1] is VALID?
- First if: SKIPPED (decoded[0] not valid)
- Second if: Writes to inst_queue[iq_tail + 1], sets iq_tail <= iq_tail + 2
- Result: inst_queue[iq_tail] is LEFT EMPTY! (hole in queue)
- iq_head will advance to empty slot and try to execute garbage

**Impact:** Executes invalid instructions, crashes

**Fix:** Second instruction should only enqueue if first also enqueued

---

### 26. ⚠️ **HIGH: Write-After-Write Hazard in ROB**
**File:** fx68k_superscalar.sv:318-365
**Severity:** HIGH - Race conditions

**Problem:** Single always_ff block does:
1. ROB allocation (line 329-340)
2. Completion marking (line 343-349)
3. Commit/writeback (line 352-365)

All in same cycle! Multiple non-blocking assignments to same ROB entries:

```systemverilog
always_ff @(posedge clk) begin
    // Allocate
    reorder_buffer[rob_tail] <= {...};

    // Mark complete
    reorder_buffer[eu_rob_id[i]].complete <= 1'b1;

    // Commit
    reorder_buffer[rob_head].valid <= 1'b0;
end
```

**Conflict scenarios:**
- If rob_tail == eu_rob_id[i]: Allocation vs completion
- If rob_head == eu_rob_id[i]: Commit vs completion
- If rob_tail == rob_head: Allocation vs commit (buffer full!)

**Impact:**
- Non-deterministic behavior
- Last write wins, creating race conditions
- ROB corruption

**Fix:** Separate allocation/completion/commit into different stages or add conflict detection

---

### 27. ⚠️ **HIGH: ALU State Machine Complete Signal Bug**
**File:** fx68k_superscalar.sv:507-535
**Severity:** HIGH - Lost completions

**Problem:**
```systemverilog
IDLE: begin
    complete <= 1'b0;  // Clear on entry to IDLE
    if (issue) begin
        state <= EXEC;
        busy <= 1'b1;
    end
end

EXEC: begin
    // Execute...
    state <= DONE;
end

DONE: begin
    complete <= 1'b1;  // Set for ONE cycle only!
    busy <= 1'b0;
    state <= IDLE;     // Next cycle: complete goes to 0
end
```

**Issue:** `complete` is high for only ONE cycle (DONE state)
- Main module checks `eu_complete[i]` at line 345
- If main module misses that one cycle, completion is lost
- No handshaking or acknowledgment

**Impact:**
- Lost completions
- Instructions never commit
- Hangs

**Fix:** Hold `complete` high until acknowledged by main module

---

### 28. ⚠️ **HIGH: ALU Busy Signal Allows Double-Issue**
**File:** fx68k_superscalar.sv:502, 511, 533
**Severity:** HIGH - Unit conflicts

**Timeline:**
- Cycle 0 (IDLE): busy = 0, complete = 0
- Cycle 1 (EXEC): busy = 1, complete = 0
- Cycle 2 (DONE): busy = 0, complete = 1
- Cycle 3 (IDLE): busy = 0, complete = 0

**Problem:** In cycle 2 (DONE state):
- busy = 0
- Issue logic checks `!eu_busy`
- Issue logic sees unit as available
- Can re-issue to same unit while previous instruction is completing!

**Impact:**
- Multiple instructions issued to same unit
- Overwrites results
- Lost completions

**Fix:** Keep busy = 1 until IDLE state, or check `busy || complete`

---

### 29. ⚠️ **HIGH: IQ Entry Not Invalidated After Issue**
**File:** fx68k_superscalar.sv:253-259
**Severity:** HIGH - Instructions execute multiple times

**Problem:**
```systemverilog
if (can_issue[0]) begin
    inst_queue[iq_head].valid <= 1'b0;  // Invalidate at iq_head
    iq_head <= iq_head + 1;
    iq_count <= iq_count - 1;
end
```

But issue logic found instruction at position `i` (not necessarily iq_head):
```systemverilog
for (int i = 0; i < IQ_ENTRIES; i++) begin
    if (inst_queue[i].valid && ...) begin
        can_issue[0] = 1'b1;
        break;  // Found at position i
    end
end
```

**Impact:**
- Invalidates wrong IQ entry (iq_head instead of i)
- Ready instruction at position i remains valid
- Will be issued again next cycle
- Instructions execute multiple times!

**Fix:** Invalidate inst_queue[i], not inst_queue[iq_head]

---

### 30. 📝 **MEDIUM: Scoreboard Read-Before-Write Hazard**
**File:** fx68k_superscalar.sv:230-233
**Severity:** MEDIUM - Stale dependency info

**Problem:**
```systemverilog
always_ff @(posedge clk) begin
    // Enqueue uses scoreboard
    inst_queue[iq_tail] <= '{
        src1_ready: check_operand_ready(...),  // Reads scoreboard
        src2_ready: check_operand_ready(...),  // Reads scoreboard
        ...
    };

    // But scoreboard is ALSO updated in same cycle (when fixed)
    scoreboard[reg] <= {ready: 1'b0, producer: rob_tail};
end
```

**Issue:**
- Function reads scoreboard in sequential block
- Scoreboard might be updated same cycle
- Reads stale value before write completes

**Impact:**
- Dependency check uses old scoreboard state
- May incorrectly mark operands as ready

**Fix:** Use combinational logic for dependency check, or ensure scoreboard is stable

---

### 31. 📝 **MEDIUM: Counter Increment Race Condition**
**File:** fx68k_superscalar.sv:225-250
**Severity:** MEDIUM - Counter corruption

**Problem:** Both decoded[0] and decoded[1] enqueue paths modify iq_count:
```systemverilog
if (decoded[0].valid && iq_count < IQ_ENTRIES) begin
    iq_count <= iq_count + 1;  // First write
end

if (decoded[1].valid && iq_count < (IQ_ENTRIES - 1)) begin
    iq_count <= iq_count + 2;  // Second write (overwrites first)
end
```

**Analysis:**
- If both valid: Second write overwrites first → iq_count + 2 (CORRECT)
- If only [0] valid: Only first write → iq_count + 1 (CORRECT)
- If only [1] valid: Only second write → iq_count + 2 (BUG!)
  - Should be +1 (only one instruction enqueued)
  - But increments by +2

**Impact:**
- iq_count becomes incorrect
- fetch_stall calculation wrong
- Queue overflow/underflow

**Fix:** Conditional increment based on how many actually enqueued

---

### 32. 📝 **MEDIUM: Fetch Doesn't Wait for Memory**
**File:** fx68k_superscalar.sv:165-187
**Severity:** MEDIUM - Invalid fetches

**Problem:**
```systemverilog
always_ff @(posedge clk) begin
    if (!fetch_stall) begin
        fetch_packet[0].opcode <= data_in;  // Uses data_in immediately!
    end
end
```

- No read_req signal set
- No checking of data_valid
- Just blindly reads data_in
- No address output to `addr` port

**Impact:**
- Fetches garbage/stale data
- Invalid instructions decoded
- Crashes

**Fix:** Implement proper fetch FSM with memory handshaking

---

### 33. 📝 **MEDIUM: PC Increment Wrong for 68000**
**File:** fx68k_superscalar.sv:175
**Severity:** MEDIUM - Address errors

**Problem:**
```systemverilog
pc_fetch <= pc_fetch + 4;  // Increments by 4 bytes
```

**Issue:**
- 68000 instructions are 16-bit (2 bytes) minimum
- Dual-fetch of 2 instructions = 2 × 2 = 4 bytes (OK)
- But some instructions are 32-bit (4 bytes) or 48-bit (6 bytes)
- Fixed +4 assumes all instructions are 16-bit

**Impact:**
- Skips instruction bytes
- Misaligned fetches
- Invalid decode

**Fix:** Variable PC increment based on actual instruction sizes

---

### 34. 📝 **MEDIUM: Register File Not Initialized**
**File:** fx68k_superscalar.sv:140-145
**Severity:** MEDIUM - Undefined behavior

**Problem:**
```systemverilog
// Register File
logic [31:0] data_regs[8];  // Never initialized!
logic [31:0] addr_regs[8];  // Never initialized!
logic [31:0] usp, ssp;      // Never initialized!
```

**Impact:**
- Registers start with X (undefined) values
- First reads return garbage
- Simulation vs synthesis mismatch

**Fix:** Initialize in reset block

---

### 35. 📝 **MEDIUM: Second Instruction Fetch Hardcoded to 0**
**File:** fx68k_superscalar.sv:185
**Severity:** MEDIUM - Second decode path broken

**Problem:**
```systemverilog
fetch_packet[1].opcode <= 16'h0;  // Hardcoded! Comment says "would need second fetch"
```

**Impact:**
- Second instruction is always 0x0000 (invalid/NOP)
- Dual-fetch doesn't work
- Can never decode second instruction

**Fix:** Implement proper dual-port fetch or sequential fetch

---

## Summary of Additional Bugs

| # | Severity | Issue | Impact |
|---|----------|-------|--------|
| 23 | CRITICAL | Wrong IQ entry executed | Executes wrong instructions |
| 24 | CRITICAL | Both ALUs get same inst | No dual-issue |
| 25 | CRITICAL | Holes in IQ on partial enqueue | Executes garbage |
| 26 | HIGH | ROB write-after-write hazard | Race conditions |
| 27 | HIGH | Complete signal only 1 cycle | Lost completions |
| 28 | HIGH | Busy allows double-issue | Unit conflicts |
| 29 | HIGH | Wrong IQ entry invalidated | Duplicate execution |
| 30 | MEDIUM | Scoreboard read-before-write | Stale dependencies |
| 31 | MEDIUM | Counter race on partial enqueue | Wrong iq_count |
| 32 | MEDIUM | Fetch doesn't handshake | Invalid data |
| 33 | MEDIUM | Fixed PC increment | Misaligned fetches |
| 34 | MEDIUM | Registers uninitialized | Undefined behavior |
| 35 | MEDIUM | Second fetch hardcoded | No dual-decode |

## Total Issue Count

**Original Analysis:** 22 issues
**Additional Bugs:** 13 issues
**TOTAL: 35 issues**

### Breakdown by Severity
- **Critical:** 5 + 3 = **8 issues**
- **High:** 7 + 4 = **11 issues**
- **Medium:** 6 + 6 = **12 issues**
- **Low:** 4 + 0 = **4 issues**

## Recommended Fix Priority

**Phase 0 - Can't Even Simulate:**
1. Fix issue logic IQ indexing (#23)
2. Fix conditional enqueue (#25)
3. Initialize registers (#34)
4. Fix dual ALU instruction feed (#24)

**Phase 1 - Make It Boot:**
5. Fix memory fetch handshaking (#32)
6. Fix second instruction fetch (#35)
7. All original critical issues (#1-7)

**Phase 2 - Make It Functional:**
8. Fix IQ invalidation (#29)
9. Fix ALU completion (#27, #28)
10. Fix ROB hazards (#26)
11. Fix scoreboard (#2, #30)

**Phase 3 - Make It Correct:**
12. Fix counter races (#31)
13. Fix PC increment (#33)
14. Complete instruction decoder (#12)

## Estimated Fix Time

**Original estimate:** 20-32 hours
**Additional work:** 12-18 hours
**NEW TOTAL: 32-50 hours** of development

This is effectively a **complete rewrite** of the critical paths.
