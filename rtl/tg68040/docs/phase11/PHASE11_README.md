# Phase 11: Exception Handling

## Overview

**Phase:** 11 of 15
**Goal:** Implement MC68040 exception processing and interrupt handling
**Complexity:** High
**Estimated Effort:** 2-3 sessions

## MC68040 Exception Architecture

The MC68040 implements a sophisticated exception handling mechanism that includes:
- 256 exception vectors
- Multiple exception types
- Exception priorities
- 7 interrupt levels
- Exception stack frames
- RTE (Return from Exception) instruction

### Exception Types

**Group 0 Exceptions (Highest Priority):**
- Reset (vector 0)
- Bus Error (vector 2)
- Address Error (vector 3)

**Group 1 Exceptions:**
- Trace (vector 9)
- Illegal Instruction (vector 4)
- Privilege Violation (vector 8)
- FP Protocol Violation (vector 13)

**Group 2 Exceptions:**
- CHK, CHK2 (vector 6)
- FP exceptions (vectors 48-54)
- Divide by Zero (vector 5)
- TRAP #n (vectors 32-47)
- TRAPV (vector 7)

**Interrupts:**
- Auto-vectored interrupts (vectors 25-31, levels 1-7)
- User interrupts (vectors 64-255)

## Exception Vector Table

The exception vector table starts at address determined by VBR (Vector Base Register):

```
VBR + 0x000: Reset: Initial SSP
VBR + 0x004: Reset: Initial PC
VBR + 0x008: Bus Error
VBR + 0x00C: Address Error
VBR + 0x010: Illegal Instruction
VBR + 0x014: Divide by Zero
VBR + 0x018: CHK, CHK2 Instruction
VBR + 0x01C: cpTRAPcc, TRAPcc, TRAPV
VBR + 0x020: Privilege Violation
VBR + 0x024: Trace
VBR + 0x028: Line A Emulator (opcode 1010)
VBR + 0x02C: Line F Emulator (opcode 1111)
VBR + 0x034: Format Error
VBR + 0x038: Uninitialized Interrupt
VBR + 0x060: Spurious Interrupt
VBR + 0x064-0x07C: Level 1-7 Interrupts
VBR + 0x080-0x0BC: TRAP #0-15
VBR + 0x0C0-0x0D8: FP Branch/Set on Unordered
VBR + 0x0DC: FP Inexact Result
VBR + 0x0E0: FP Divide by Zero
VBR + 0x0E4: FP Underflow
VBR + 0x0E8: FP Operand Error
VBR + 0x0EC: FP Overflow
VBR + 0x0F0: FP Signaling NaN
VBR + 0x0F4: FP Unimplemented Data Type
VBR + 0x100-0x3FC: User Defined (64-255)
```

## Exception Stack Frames

The MC68040 uses different stack frame formats depending on the exception type:

### Format 0 (4-word frame) - Normal exceptions
```
SP+0x00: SR (Status Register)
SP+0x02: PC (Program Counter, 32-bit)
SP+0x06: Format/Vector Word
         Bits 15-12: Format (0000)
         Bits 11-2: Reserved
         Bits 1-0: Vector offset[9:8]
```

### Format 1 (4-word frame) - Throwaway frame
Used when an exception occurs during RTE processing.

### Format 2 (6-word frame) - Instruction exception
```
SP+0x00: SR
SP+0x02: PC
SP+0x06: Format/Vector Word (format = 0010)
SP+0x08: Instruction Address
```

### Format 7 (30-word frame) - Access error
Used for bus errors and address errors.
Contains extensive information about the faulting access.

## Exception Processing Flow

### 1. Exception Recognition
```
Instruction Execution
    ↓
Exception Detected
    ↓
Check Exception Priority
    ↓
Higher priority? → Process
Lower priority? → Continue current exception
```

### 2. Exception Entry
```
1. Make internal copy of SR
2. Set S-bit (enter supervisor mode)
3. Clear T0, T1 (disable tracing during exception)
4. For interrupts: Set interrupt mask
5. Get vector number (8-bit)
6. Calculate vector offset (vector × 4)
7. Calculate exception vector address (VBR + offset)
8. Create exception stack frame:
   - Push format/vector word
   - Push PC
   - Push SR
   - Push additional information (format-dependent)
9. Fetch new PC from exception vector
10. Resume execution at exception handler
```

### 3. Exception Return (RTE)
```
1. Pop stack frame from SSP
2. Check format field
3. Restore SR (includes mode, interrupt mask)
4. Restore PC
5. Resume execution
```

## Exception Priorities

When multiple exceptions occur simultaneously, they are processed in priority order:

**Priority 1 (Highest):** Reset
**Priority 2:** Bus Error, Address Error
**Priority 3:** Trace
**Priority 4:** Interrupt
**Priority 5:** Illegal, Privilege Violation
**Priority 6:** FP exceptions
**Priority 7:** TRAP, TRAPV, CHK
**Priority 8 (Lowest):** Divide by Zero

## Status Register (SR) Structure

```
SR (16 bits):
Bits 15-13: Trace mode (T1, T0)
Bit 13: Supervisor mode (S)
Bits 10-8: Interrupt mask (I2, I1, I0)
Bits 4-0: Condition codes (X, N, Z, V, C)
```

**Trace Modes:**
- T1=0, T0=0: No tracing
- T1=0, T0=1: Trace on change of flow
- T1=1, T0=0: Trace on any instruction
- T1=1, T0=1: Undefined

**Interrupt Mask:**
- Levels 0-7 (0=all interrupts enabled, 7=only level 7/NMI)

## Interrupt Handling

### Interrupt Levels
- **Level 0:** No interrupt
- **Level 1-6:** Maskable interrupts
- **Level 7:** Non-maskable interrupt (NMI)

### Interrupt Acknowledge Cycle
```
1. External interrupt request (IPL[2:0])
2. Check current interrupt mask in SR
3. If IPL > mask: acknowledge interrupt
4. Perform interrupt acknowledge bus cycle
5. External device provides vector number
6. Process as interrupt exception
```

### Auto-vectored Interrupts
If external device doesn't provide vector:
- Use auto-vector (25 + level)
- Vectors 25-31 for levels 1-7

## Implementation Strategy

### Phase 11A: Exception Infrastructure

**Goal:** Create exception types and basic infrastructure

**Components:**
1. **TG68040_Exception_Pack.vhd** - Exception package
   - Exception type enumeration
   - Exception vector addresses
   - Stack frame types
   - Exception priorities
   - Utility functions

2. **Exception signals in pipeline**
   - Exception detection flags
   - Exception vector numbers
   - Exception priorities

**Deliverables:**
- Exception package (~300 lines)
- Updated pipeline with exception signals (~50 lines)

### Phase 11B: Exception Detection

**Goal:** Detect exceptions in each pipeline stage

**Detection Points:**
1. **IF Stage:** Bus error on instruction fetch
2. **ID Stage:** Illegal instruction, privilege violation
3. **EA Stage:** Address error (misaligned access)
4. **OF Stage:** FP exceptions
5. **EX Stage:** Arithmetic exceptions (divide by zero)
6. **All Stages:** Trace exceptions

**Deliverables:**
- Exception detection logic in pipeline (~200 lines)
- Exception priority arbitration (~100 lines)

### Phase 11C: Exception Processing

**Goal:** Implement exception entry and stack frame creation

**Components:**
1. **TG68040_Exception_Unit.vhd** - Exception processing unit
   - Stack frame creation
   - VBR-based vector lookup
   - PC/SR save/restore
   - Mode switching (user → supervisor)

2. **Pipeline integration**
   - Exception entry FSM
   - Pipeline flush on exception
   - PC redirect to handler

**Deliverables:**
- Exception unit (~400 lines)
- Pipeline exception integration (~150 lines)

### Phase 11D: RTE Instruction

**Goal:** Implement Return from Exception

**Components:**
1. **RTE instruction decode**
2. **Stack frame restoration**
3. **SR/PC restoration**
4. **Mode switching (supervisor → user)**

**Deliverables:**
- RTE implementation in pipeline (~100 lines)
- Format error detection (~50 lines)

## Exception Package Types

```vhdl
-- Exception type enumeration
type exception_type_t is (
    EXC_NONE,
    EXC_RESET,
    EXC_BUS_ERROR,
    EXC_ADDRESS_ERROR,
    EXC_ILLEGAL_INSTRUCTION,
    EXC_DIVIDE_BY_ZERO,
    EXC_CHK,
    EXC_TRAPV,
    EXC_PRIVILEGE_VIOLATION,
    EXC_TRACE,
    EXC_LINE_A,
    EXC_LINE_F,
    EXC_FORMAT_ERROR,
    EXC_UNINITIALIZED_INT,
    EXC_SPURIOUS_INT,
    EXC_INTERRUPT_L1,
    EXC_INTERRUPT_L2,
    EXC_INTERRUPT_L3,
    EXC_INTERRUPT_L4,
    EXC_INTERRUPT_L5,
    EXC_INTERRUPT_L6,
    EXC_INTERRUPT_L7,
    EXC_TRAP_0_15,
    EXC_FP_BRANCH_UNORDERED,
    EXC_FP_INEXACT,
    EXC_FP_DIVIDE_BY_ZERO,
    EXC_FP_UNDERFLOW,
    EXC_FP_OPERAND_ERROR,
    EXC_FP_OVERFLOW,
    EXC_FP_SIGNALING_NAN,
    EXC_FP_UNIMPLEMENTED
);

-- Exception information
type exception_info_t is record
    valid       : std_logic;                       -- Exception is valid
    exc_type    : exception_type_t;                -- Exception type
    vector      : std_logic_vector(7 downto 0);    -- Vector number
    priority    : std_logic_vector(3 downto 0);    -- Priority level
    fault_addr  : std_logic_vector(31 downto 0);   -- Faulting address
    fault_pc    : std_logic_vector(31 downto 0);   -- PC at fault
    fault_sr    : std_logic_vector(15 downto 0);   -- SR at fault
end record;

-- Stack frame format
type stack_frame_format_t is (
    FRAME_FORMAT_0,  -- 4-word normal
    FRAME_FORMAT_1,  -- 4-word throwaway
    FRAME_FORMAT_2,  -- 6-word instruction
    FRAME_FORMAT_7   -- 30-word access error
);

-- Status Register
type status_register_t is record
    trace_mode      : std_logic_vector(1 downto 0);  -- T1, T0
    supervisor_mode : std_logic;                      -- S
    interrupt_mask  : std_logic_vector(2 downto 0);  -- I2, I1, I0
    condition_x     : std_logic;                      -- X (extend)
    condition_n     : std_logic;                      -- N (negative)
    condition_z     : std_logic;                      -- Z (zero)
    condition_v     : std_logic;                      -- V (overflow)
    condition_c     : std_logic;                      -- C (carry)
end record;
```

## Exception Processing Algorithm

### Exception Entry
```vhdl
procedure exception_entry(
    exc_type   : in exception_type_t;
    vector     : in std_logic_vector(7 downto 0);
    fault_addr : in std_logic_vector(31 downto 0);
    fault_pc   : in std_logic_vector(31 downto 0)
) is
begin
    -- Save current SR
    saved_sr := current_sr;

    -- Update SR for exception mode
    current_sr.supervisor_mode := '1';  -- Enter supervisor mode
    current_sr.trace_mode := "00";      -- Disable trace

    -- For interrupts, update interrupt mask
    if is_interrupt(exc_type) then
        current_sr.interrupt_mask := get_interrupt_level(exc_type);
    end if;

    -- Calculate vector address
    vector_offset := unsigned(vector) * 4;
    vector_addr := vbr + vector_offset;

    -- Create stack frame (format depends on exception)
    frame_format := get_frame_format(exc_type);

    case frame_format is
        when FRAME_FORMAT_0 =>
            push_word(format_vector_word);
            push_long(fault_pc);
            push_word(saved_sr);

        when FRAME_FORMAT_2 =>
            push_word(format_vector_word);
            push_long(fault_addr);
            push_long(fault_pc);
            push_word(saved_sr);

        when FRAME_FORMAT_7 =>
            -- Push 30-word access error frame
            push_access_error_frame();
    end case;

    -- Fetch new PC from vector
    new_pc := fetch_long(vector_addr);

    -- Flush pipeline
    flush_all_stages();

    -- Resume at exception handler
    pc := new_pc;
end procedure;
```

### RTE (Return from Exception)
```vhdl
procedure rte is
begin
    -- Pop stack frame
    saved_sr := pop_word();
    new_pc := pop_long();
    format_vector := pop_word();

    -- Extract format
    format := format_vector(15 downto 12);

    -- Validate format
    if format /= "0000" and format /= "0001" and
       format /= "0010" and format /= "0111" then
        -- Format error exception
        exception_entry(EXC_FORMAT_ERROR, 14, pc, pc);
        return;
    end if;

    -- Pop additional frame data based on format
    case format is
        when "0010" =>  -- Format 2
            fault_addr := pop_long();

        when "0111" =>  -- Format 7
            pop_access_error_frame();
    end case;

    -- Restore SR (includes mode, trace, interrupt mask)
    current_sr := saved_sr;

    -- Restore PC
    pc := new_pc;

    -- Resume execution
end procedure;
```

## Testing Strategy

### Unit Tests

**Exception Detection Tests:**
1. Illegal instruction detection
2. Privilege violation detection
3. Address error detection (odd addresses)
4. Divide by zero detection
5. Trace exception generation

**Exception Processing Tests:**
1. Stack frame creation (format 0)
2. Stack frame creation (format 2)
3. Vector address calculation
4. SR mode switching (user → supervisor)
5. PC redirection to handler

**RTE Tests:**
1. Stack frame restoration (format 0)
2. Stack frame restoration (format 2)
3. SR restoration
4. PC restoration
5. Mode switching (supervisor → user)
6. Format error detection

**Interrupt Tests:**
1. Interrupt level masking
2. Auto-vectored interrupts
3. User-vectored interrupts
4. Interrupt priority
5. Nested interrupts

### Integration Tests

**Exception Flow:**
```assembly
; Test illegal instruction exception
    ILLEGAL_INSTR     ; Should trap to vector 4

; Exception handler
exc_handler:
    MOVE.L D0,-(SP)   ; Save register
    ; Handle exception
    MOVE.L (SP)+,D0   ; Restore register
    RTE               ; Return from exception
```

## Performance Impact

**Exception Entry:** ~20 cycles
- Stack frame creation: ~10 cycles
- Vector fetch: ~5 cycles
- Pipeline flush: ~5 cycles

**RTE:** ~15 cycles
- Stack frame restoration: ~8 cycles
- SR/PC restore: ~5 cycles
- Pipeline refill: ~2 cycles

**Interrupt Latency:** ~25 cycles
- Recognition: ~2 cycles
- Exception entry: ~20 cycles
- Handler entry: ~3 cycles

## Implementation Plan

### Session 1: Exception Infrastructure (Phase 11A)
1. Create TG68040_Exception_Pack.vhd
2. Define exception types
3. Define stack frame formats
4. Add exception signals to pipeline
5. Create PHASE11_README.md

### Session 2: Exception Detection & Processing (Phase 11B-C)
1. Add exception detection in pipeline stages
2. Implement exception priority arbitration
3. Create TG68040_Exception_Unit.vhd
4. Implement stack frame creation
5. Implement exception entry flow
6. Pipeline flush on exception

### Session 3: RTE & Testing (Phase 11D)
1. Implement RTE instruction
2. Implement stack frame restoration
3. Create exception unit tests
4. Create RTE tests
5. Create interrupt tests
6. Integration testing

## Acceptance Criteria

**Phase 11A:**
- ✅ Exception package compiles
- ✅ All exception types defined
- ✅ Stack frame types defined
- ✅ Exception signals added to pipeline

**Phase 11B:**
- ✅ Illegal instruction detected
- ✅ Privilege violation detected
- ✅ Address error detected
- ✅ Exception priority arbitration works

**Phase 11C:**
- ✅ Stack frames created correctly
- ✅ Vector lookup works
- ✅ SR/PC saved correctly
- ✅ Mode switching works
- ✅ Pipeline flushed on exception

**Phase 11D:**
- ✅ RTE instruction implemented
- ✅ Stack frames restored correctly
- ✅ SR/PC restored correctly
- ✅ Format error detected
- ✅ All tests pass

## Future Enhancements (Beyond Phase 11)

**Advanced Exception Features:**
- Double fault detection
- Bus error retry
- DMA transfer exceptions
- Coprocessor exceptions
- Access fault recovery

**Debug Support:**
- Hardware breakpoints
- Watchpoints
- Single-step debugging
- Exception tracing

## References

- MC68040 User's Manual, Chapter 6: Exception Processing
- MC68040 User's Manual, Chapter 5: Instruction Execution Timing
- MC68000 Family Programmer's Reference Manual

---

**Document Version:** 1.0 (Initial Planning)
**Date:** 2025-11-11
**Author:** Claude AI (Anthropic)
