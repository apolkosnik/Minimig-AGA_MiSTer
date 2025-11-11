# MC68030 Function Code Registers Specification

## Document Purpose

This document specifies the Source Function Code (SFC) and Destination Function Code (DFC) registers used by the MC68030 for the MOVES instruction.

## Overview

The MC68030 includes two 3-bit function code registers:

| Register | Size | Access | Purpose |
|----------|------|--------|---------|
| **SFC** | 3-bit | Supervisor | Source Function Code for MOVES instruction |
| **DFC** | 3-bit | Supervisor | Destination Function Code for MOVES instruction |

These registers specify the function code (address space) for MOVES instruction operands.

## Background: Function Codes

The 68000 family uses **Function Codes** (FC0, FC1, FC2) to indicate the type of bus cycle:

| FC2 | FC1 | FC0 | Address Space |
|-----|-----|-----|---------------|
| 0 | 0 | 0 | (Undefined, reserved) |
| 0 | 0 | 1 | User Data Space |
| 0 | 1 | 0 | User Program Space |
| 0 | 1 | 1 | (Undefined, reserved) |
| 1 | 0 | 0 | (Undefined, reserved) |
| 1 | 0 | 1 | Supervisor Data Space |
| 1 | 1 | 0 | Supervisor Program Space |
| 1 | 1 | 1 | CPU Space (interrupts, breakpoints) |

**Normal Operation:**
- CPU automatically sets FC based on current mode and access type
- FC2 = S bit (supervisor/user mode)
- FC0 = 1 for data, 0 for program
- FC1 = 0 for data, 1 for program

**MOVES Instruction:**
- Allows supervisor mode to access user or other address spaces
- SFC specifies source address space
- DFC specifies destination address space
- Useful for operating systems to access user memory safely

---

## SFC - Source Function Code Register (3-bit)

Specifies the function code for the source operand of MOVES instruction.

### Bit Layout
```
 31  30  29  28  27  26  25  24  23  22  21  20  19  18  17  16
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0 │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘

 15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│ 0   0   0   0   0   0   0   0   0   0   0   0   0  FC2 FC1 FC0│
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

### Bit Definitions

| Bit(s) | Name | Description |
|--------|------|-------------|
| 31-3 | - | Reserved (read as 0, written as don't care) |
| 2 | **FC2** | Function code bit 2 |
| 1 | **FC1** | Function code bit 1 |
| 0 | **FC0** | Function code bit 0 |

### Reset Value
`0x00000000` (000 = undefined/reserved space, but safe)

### Usage
```assembly
; Set SFC to user data space (001)
MOVE.L  #1,D0
MOVEC   D0,SFC

; Now MOVES will read from user data space
MOVES.L (A0),D1    ; Read from user data space at address A0
```

---

## DFC - Destination Function Code Register (3-bit)

Specifies the function code for the destination operand of MOVES instruction.

### Bit Layout
Same as SFC (3-bit value in bits 2-0, upper bits reserved).

### Bit Definitions
Same as SFC.

### Reset Value
`0x00000000`

### Usage
```assembly
; Set DFC to user data space (001)
MOVE.L  #1,D0
MOVEC   D0,DFC

; Now MOVES will write to user data space
MOVES.L D1,(A0)    ; Write to user data space at address A0
```

---

## MOVES Instruction

The MOVES instruction is the primary user of SFC and DFC registers.

### Syntax
```assembly
MOVES.size <ea>,Rn    ; Move from address space to register
MOVES.size Rn,<ea>    ; Move from register to address space
```

### Operation

**MOVES from memory:**
```
1. CPU uses SFC as function code (instead of normal FC)
2. Address from <ea> is accessed
3. Data loaded to register Rn
```

**MOVES to memory:**
```
1. CPU uses DFC as function code (instead of normal FC)
2. Data from register Rn is written
3. Address from <ea> is accessed
```

### Function Code Usage

| Instruction | Function Code Used |
|-------------|-------------------|
| `MOVES <ea>,Rn` | SFC (source from memory) |
| `MOVES Rn,<ea>` | DFC (destination to memory) |

### Privilege
MOVES is **supervisor only**. Executing in user mode causes privilege violation.

### Use Cases

**1. Operating System User Memory Access**
```assembly
; OS wants to read user memory safely
MOVE.L  #$001,D0     ; User data space
MOVEC   D0,SFC
LEA     user_addr,A0
MOVES.L (A0),D1      ; Read user memory
```

**2. Debugger Breakpoint Access**
```assembly
; Debugger writing to code being debugged
MOVE.L  #$002,D0     ; User program space
MOVEC   D0,DFC
LEA     code_addr,A0
MOVE.L  #$4E714E71,D1  ; NOP instruction
MOVES.L D1,(A0)      ; Write to user code
```

**3. Memory Protection Verification**
```assembly
; Test if memory is accessible in user mode
MOVE.L  #$001,D0
MOVEC   D0,SFC
MOVE.L  test_addr,A0
MOVES.W (A0),D1      ; Try to read
; If no bus error, memory is accessible to user
```

---

## Register Access

Both SFC and DFC are accessed via the **MOVEC** instruction:

```assembly
; Read SFC
MOVEC   SFC,D0       ; D0 = 0x000000FC (only bits 2-0 significant)

; Write SFC
MOVE.L  #$001,D0     ; User data space
MOVEC   D0,SFC

; Read DFC
MOVEC   DFC,D0

; Write DFC
MOVE.L  #$005,D0     ; Supervisor data space
MOVEC   D0,DFC
```

**Control Register Codes:**
- SFC: 0x000
- DFC: 0x001

**Privilege**: Supervisor only (privilege violation if executed in user mode).

---

## Implementation Status in TG68K

### Already Implemented ✅

TG68K already has SFC and DFC registers:

**Location**: `TG68KdotC_Kernel.vhd`

**Declaration** (line 357-358):
```vhdl
signal DFC : std_logic_vector(2 downto 0);
signal SFC : std_logic_vector(2 downto 0);
```

**MOVEC Write** (line 4016-4017):
```vhdl
when X"000" => SFC <= reg_QA(2 downto 0); -- SFC -- 68010+
when X"001" => DFC <= reg_QA(2 downto 0); -- DFC -- 68010+
```

**MOVEC Read** (line 4031-4032):
```vhdl
when X"000" => movec_data <= "00000000000000000000000000000" & SFC;
when X"001" => movec_data <= "00000000000000000000000000000" & DFC;
```

### Not Yet Implemented ⏳

**MOVES Instruction:**
- Currently marked as TODO (line 1766)
- Decodes but generates illegal instruction trap
- Needs implementation to actually use SFC/DFC

**Implementation needed** (Phase 3 or later):
```vhdl
-- In MOVES execution:
IF opcode(bit) = direction_to_memory THEN
    FC_override <= DFC;  -- Use DFC for write
ELSE
    FC_override <= SFC;  -- Use SFC for read
END IF;
```

---

## MC68030 Requirements

### Phase 2 (Current) ✅
1. ✅ SFC/DFC registers exist (already in TG68K)
2. ✅ MOVEC read/write works (already in TG68K)
3. ✅ 3-bit width (matches spec)
4. ✅ Supervisor-only access (MOVEC is privileged)
5. ✅ Reset to 0

### Phase 3 (MMU Instructions)
6. ⏳ Implement MOVES instruction
7. ⏳ Use SFC for MOVES source
8. ⏳ Use DFC for MOVES destination
9. ⏳ Generate correct FC on bus during MOVES

### Phase 7 (Integration)
10. ⏳ Ensure FC output uses SFC/DFC during MOVES
11. ⏳ Test with MMU (if FC lookup enabled in TC)

---

## Testing Requirements

### Unit Tests
- Read/write SFC via MOVEC
- Read/write DFC via MOVEC
- Verify reset values (0)
- Test privilege violations (user mode)
- Test upper bits read as zero
- Test all FC values (0-7)

### Integration Tests (Phase 3+)
- MOVES instruction uses SFC/DFC
- FC output changes during MOVES
- Privilege checking works
- Bus cycles have correct FC

---

## Function Code Values Reference

### Common Values

| Value | Binary | Symbolic | Description |
|-------|--------|----------|-------------|
| 0 | 000 | - | Undefined (reserved) |
| 1 | 001 | UD | User Data |
| 2 | 010 | UP | User Program |
| 3 | 011 | - | Undefined (reserved) |
| 4 | 100 | - | Undefined (reserved) |
| 5 | 101 | SD | Supervisor Data |
| 6 | 110 | SP | Supervisor Program |
| 7 | 111 | CPU | CPU Space |

### Typical Usage

**For User Space Access:**
```assembly
MOVE.L  #1,D0    ; User data
MOVEC   D0,SFC
MOVEC   D0,DFC
```

**For Supervisor Space Access:**
```assembly
MOVE.L  #5,D0    ; Supervisor data
MOVEC   D0,SFC
MOVEC   D0,DFC
```

**For Mixed:**
```assembly
MOVE.L  #1,D0    ; Read from user
MOVEC   D0,SFC
MOVE.L  #5,D0    ; Write to supervisor
MOVEC   D0,DFC
```

---

## Comparison with MC68020

SFC and DFC were introduced in the **MC68010** (not MC68020). They are identical across 68010, 68020, and 68030:

| Feature | MC68010 | MC68020 | MC68030 |
|---------|---------|---------|---------|
| SFC register | ✅ 3-bit | ✅ 3-bit | ✅ 3-bit |
| DFC register | ✅ 3-bit | ✅ 3-bit | ✅ 3-bit |
| MOVEC access | ✅ Yes | ✅ Yes | ✅ Yes |
| MOVES instruction | ✅ Yes | ✅ Yes | ✅ Yes |
| Control codes | 0x000, 0x001 | 0x000, 0x001 | 0x000, 0x001 |

**Conclusion**: No changes needed for MC68030 - already correct!

---

## Integration with TG68K030

### Current TG68K Implementation
SFC and DFC are already part of TG68KdotC_Kernel and will be inherited by TG68K030.

### No New Module Needed
Unlike MMU and cache registers, SFC/DFC don't need a separate module. They're simple 3-bit registers accessed via MOVEC.

### TG68K030 Integration
```vhdl
-- TG68K030_Kernel will inherit from TG68KdotC_Kernel
-- SFC and DFC are already present
-- Just need to ensure MOVES instruction implementation (Phase 3)
```

### Outputs (if needed)
```vhdl
-- Could expose for debugging or MMU FC lookup
sfc_out : out std_logic_vector(2 downto 0);
dfc_out : out std_logic_vector(2 downto 0);
```

---

## AmigaOS Usage

AmigaOS typically does **not** use MOVES instruction extensively:
- Most user/supervisor transitions use standard instructions
- Memory protection not heavily used in AmigaOS
- SFC/DFC usually remain at default (0)

However, some uses:
- **Enforcer** (debugging tool) may use MOVES
- **MMU libraries** (mmu.library) may configure SFC/DFC
- **Memory protection** schemes may use these registers

---

## Summary

### What We Have ✅
- SFC and DFC registers implemented in TG68K
- MOVEC read/write functional
- Proper 3-bit width
- Correct control register codes (0x000, 0x001)
- Supervisor-only access
- Reset values correct

### What We Need ⏳
- MOVES instruction implementation (Phase 3)
- Use SFC/DFC to override FC during MOVES
- Unit tests to verify functionality
- Documentation (this file)

### Step 2.3 Status
**Implementation**: ✅ Already complete (inherited from TG68K)
**Documentation**: ✅ Complete (this file)
**Testing**: ⏳ Need to create unit tests

---

## References

- MC68030 User's Manual, Section 9: MOVES instruction
- MC68030 User's Manual, Section 3: Function Codes
- MC68010 User's Manual (where SFC/DFC were introduced)
- TG68KdotC_Kernel.vhd (lines 357-358, 4016-4017, 4031-4032)

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created FC register specification |
| 1.1 | 2025-11-11 | Update | Noted TG68K already has implementation |

