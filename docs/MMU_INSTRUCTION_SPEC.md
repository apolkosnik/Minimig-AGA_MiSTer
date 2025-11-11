# MC68030 MMU Instruction Specification

## Overview

This document specifies the MC68030 PMMU instructions that must be implemented in the TG68K core.
All specifications are based on the MC68030 User's Manual (Motorola/NXP document MC68030UM).

## MMU Registers

### Register Map
| Register | Selector (brief[14:10]) | Size | Access | Description |
|----------|------------------------|------|--------|-------------|
| TC       | 00000 (0x00)           | 32   | R/W    | Translation Control Register |
| CRP      | 00010 (0x02)           | 64   | R/W    | CPU Root Pointer |
| SRP      | 00011 (0x03)           | 64   | R/W    | Supervisor Root Pointer |
| TT0      | 00010 (0x02)           | 32   | R/W    | Transparent Translation Register 0 |
| TT1      | 00011 (0x03)           | 32   | R/W    | Transparent Translation Register 1 |
| MMUSR    | 11000 (0x18)           | 16   | R      | MMU Status Register (read-only) |

NOTE: The selector encoding varies between registers. The actual encoding used is:
- brief[15:13] determines the instruction class
- brief[14:10] combined with brief[15:13] determines the specific register

### Register Encoding in Extension Word

**TT0/TT1 (brief[15:13] = "000")**:
- TT0: brief[14:10] = "00010" (0x02)
- TT1: brief[14:10] = "00011" (0x03)

**TC/CRP/SRP (brief[15:13] = "010")** when NOT PLOAD:
- TC:  brief[14:10] = "10000" (0x10)
- SRP: brief[14:10] = "10010" (0x12)
- CRP: brief[14:10] = "10011" (0x13)

**MMUSR (brief[15:13] = "110")**:
- MMUSR: brief[14:10] = "11000" (0x18)

## Instruction Formats

All MMU instructions use the F-line (opcode[15:12] = "1111") encoding.
Specifically, opcode[11:8] = "0000" for all PMMU instructions.

### Opcode Format
```
Bits 15-12: 1111 (F-line)
Bits 11-8:  0000 (PMMU instruction class)
Bits 7-6:   Size/function code
Bits 5-0:   Effective Address
```

### Extension Word Format (brief)
```
Bits 15-13: Instruction type
            000 = PMOVE (TT0/TT1)
            001 = PFLUSH or PMOVEFD
            010 = PLOAD or PMOVE (TC/SRP/CRP)
            100 = PTEST
            110 = PMOVE (MMUSR)

Bits 14-10: Register selector (for PMOVE)
Bit 9:      Direction (0=to MMU, 1=from MMU) or R/W for PTEST
Bit 8:      Size (.L=0, .D=1) or other function bits
Bits 7-0:   Varies by instruction
```

## Instruction Specifications

### 1. PMOVE - Move to/from MMU Register

**Purpose**: Transfer data between MMU registers and memory/data registers

**Formats**:
1. `PMOVE <MMU_reg>,Dn` - Read MMU register to data register
2. `PMOVE Dn,<MMU_reg>` - Write data register to MMU register
3. `PMOVE <MMU_reg>,<ea>` - Read MMU register to memory
4. `PMOVE <ea>,<MMU_reg>` - Write memory to MMU register
5. `PMOVEFD <ea>,<MMU_reg>` - Write memory to MMU register (flush disable)

**Encoding**:
- Opcode: F000
- Extension word format varies by register (see Register Encoding above)
- Direction: brief[9] (0=write to MMU, 1=read from MMU)
- Size: brief[8] (0=.L/32-bit, 1=.D/64-bit, only valid for CRP/SRP)

**Legal Effective Addresses**:
- Valid: Dn, (An), -(An), (d16,An), (d8,An,Xn), xxx.W, xxx.L, ([...])
- Invalid: An, (An)+, PC-relative, Immediate

**Operation**:
1. Check privilege (supervisor only)
2. Decode register and direction from extension word
3. For 32-bit registers (TC, TT0, TT1): Single 32-bit transfer
4. For 64-bit registers (CRP, SRP): Two 32-bit transfers (high word first)
5. For MMUSR: 16-bit transfer (read-only)
6. PMOVEFD variant sets flush-disable flag

**Exceptions**:
- Privilege Violation (if not supervisor)
- Illegal Instruction (if illegal EA or invalid register selector)

### 2. PTEST - Test Address Translation

**Purpose**: Test MMU address translation without generating faults

**Formats**:
1. `PTESTR FC,<ea>,#level` - Test read access
2. `PTESTW FC,<ea>,#level` - Test write access
3. `PTESTR FC,<ea>,#level,An` - Test read access with return address
4. `PTESTW FC,<ea>,#level,An` - Test write access with return address

**Encoding**:
- Opcode: F000
- Extension word: brief[15:13] = "100"
- Level: brief[12:10] (0-7)
- R/W: brief[9] (0=write test, 1=read test)
- A: brief[8] (0=no return, 1=return address in An)
- An: brief[7:5] (if A=1)
- FC: brief[4:0] (function code encoding)

**FC Encoding** (brief[4:0]):
- 1xxxx = Immediate FC in bits [2:0]
- 01xxx = Use SFC (Source Function Code)
- 00xxx = Use DFC (Destination Function Code)

**Legal Effective Addresses**:
- Same as PMOVE (Control/Alterable modes)

**Operation**:
1. Perform page table walk for specified address and FC
2. Update MMUSR with result (T bit, N bit, etc.)
3. If A=1, store last table address in specified An
4. Do NOT generate MMU faults (test only)

**Result in MMUSR**:
- B (Bus Error): Set if table walk caused bus error
- T (Transparent): Set if address matched TT0/TT1
- N (Number of levels): Number of levels actually walked
- Other status bits as appropriate

### 3. PFLUSH - Flush Address Translation Cache

**Purpose**: Invalidate entries in the ATC (Address Translation Cache)

**Formats**:
1. `PFLUSHA` - Flush all entries
2. `PFLUSHAN` - Flush all non-global entries
3. `PFLUSH FC,<ea>` - Flush specific page
4. `PFLUSHN FC,<ea>` - Flush specific page (non-global)

**Encoding**:
- Opcode: F000
- Extension word: brief[15:13] = "001"
- PFLUSHA: brief[12:8] = "00000"
- PFLUSHAN: brief[12:8] = "01000"
- PFLUSH: brief[12] = "0", brief[11] = "0"
- PFLUSHN: brief[12] = "0", brief[11] = "1"
- FC: brief[10:8] or brief[4:0] (similar to PTEST)

**Legal Effective Addresses**:
- For PFLUSHA/PFLUSHAN: No EA required
- For PFLUSH/PFLUSHN: Same as PMOVE

**Operation**:
1. PFLUSHA: Invalidate all ATC entries
2. PFLUSHAN: Invalidate all ATC entries where G (global) bit = 0
3. PFLUSH FC,<ea>: Invalidate ATC entry matching address and FC
4. PFLUSHN FC,<ea>: Invalidate matching entry if G bit = 0

**Exceptions**:
- Privilege Violation (if not supervisor)
- Illegal Instruction (if illegal EA)

### 4. PLOAD - Preload ATC Entry

**Purpose**: Load a translation into the ATC without accessing data

**Formats**:
1. `PLOADR FC,<ea>` - Preload for read access
2. `PLOADW FC,<ea>` - Preload for write access

**Encoding**:
- Opcode: F000
- Extension word: brief[15:13] = "010"
- R/W: brief[9] (0=write, 1=read)
- FC: brief[12:10] or brief[4:0]

**Legal Effective Addresses**:
- Same as PMOVE

**Operation**:
1. Perform page table walk for specified address and FC
2. Load result into ATC (if successful)
3. Similar to PTEST but loads ATC instead of just testing

**Exceptions**:
- Privilege Violation (if not supervisor)
- MMU Configuration Exception (if invalid descriptors)
- Bus Error (if table walk fails)

## Implementation State Machine

### States Required

1. **F000_DECODE** - Initial decode of opcode F000
   - Check supervisor mode
   - Fetch extension word
   - Dispatch to instruction-specific handler

2. **PMOVE_DECODE** - Decode PMOVE specifics
   - Determine register and direction
   - Validate EA mode
   - Dispatch to Dn or memory handler

3. **PMOVE_DN_32** - Handle Dn mode, 32-bit
   - Single register transfer
   - Complete in one cycle

4. **PMOVE_DN_64_H** - Handle Dn mode, 64-bit high word
   - First of two transfers for CRP/SRP

5. **PMOVE_DN_64_L** - Handle Dn mode, 64-bit low word
   - Second transfer for CRP/SRP

6. **PMOVE_MEM_RD** - Read from memory for PMOVE <ea>,<MMU>
   - Initiate EA read
   - Wait for data

7. **PMOVE_MEM_WR** - Write to memory for PMOVE <MMU>,<ea>
   - Read MMU register
   - Initiate EA write

8. **PMOVE_64_MEM_2** - Second memory access for 64-bit PMOVE
   - Handle second longword for CRP/SRP

9. **PTEST_EXEC** - Execute PTEST
   - Signal PMMU module
   - Wait for completion

10. **PFLUSH_EXEC** - Execute PFLUSH
    - Signal PMMU module
    - Complete immediately

11. **PLOAD_EXEC** - Execute PLOAD
    - Signal PMMU module
    - Wait for completion

### Data Flow

**PMOVE to MMU**:
```
Dn/Memory → Kernel → PMMU module register file
```

**PMOVE from MMU**:
```
PMMU module register file → Kernel → Dn/Memory
```

**PTEST/PLOAD**:
```
EA → PMMU module (translation logic) → MMUSR update
```

**PFLUSH**:
```
FC/EA → PMMU module (ATC invalidation)
```

## PMMU Module Interface

The kernel must drive these signals to communicate with the PMMU module:

### Register Access
- `pmmu_reg_we` : Write enable
- `pmmu_reg_re` : Read enable
- `pmmu_reg_sel[4:0]` : Register selector (from brief[14:10])
- `pmmu_reg_wdat[31:0]` : Write data
- `pmmu_reg_rdat[31:0]` : Read data (from PMMU)
- `pmmu_reg_part` : Part selector (0=low, 1=high for 64-bit regs)
- `pmmu_reg_fd` : Flush disable flag (for PMOVEFD)

### Instruction Control
- `pmmu_ptest_req` : PTEST instruction request
- `pmmu_pflush_req` : PFLUSH instruction request
- `pmmu_pload_req` : PLOAD instruction request
- `pmmu_fc[2:0]` : Function code for instruction
- `pmmu_addr[31:0]` : Address for instruction
- `pmmu_brief[15:0]` : Extension word (for mode bits)

## Testing Strategy

### Unit Tests Required

1. **PMOVE tests**:
   - All register types (TC, TT0, TT1, CRP, SRP, MMUSR)
   - Both directions (to/from MMU)
   - Both Dn and memory EA modes
   - 32-bit and 64-bit transfers

2. **PTEST tests**:
   - Read and write variants
   - With and without An return
   - Different FC modes
   - Level parameter validation

3. **PFLUSH tests**:
   - All variants (A, AN, FC-specific)
   - Verification of ATC invalidation

4. **PLOAD tests**:
   - Read and write variants
   - Verify ATC loading

### Integration Tests

1. Privilege checking (all instructions require supervisor)
2. Illegal EA detection
3. Invalid register selector detection
4. Proper state machine progression
5. Correct timing (cycle counts)

## Success Criteria

1. All instructions decode correctly
2. All legal EA modes work
3. All illegal EAs generate exceptions
4. Privilege violations detected
5. 32-bit and 64-bit transfers work
6. PMMU module interface driven correctly
7. No state machine lockups
8. Clean, readable, maintainable code
9. Comprehensive documentation
10. All tests pass
