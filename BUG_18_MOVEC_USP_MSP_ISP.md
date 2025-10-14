# BUG #18: MOVEC USP/MSP/ISP Not Implemented

## Problem
MOVEC instructions for USP (0x800), MSP (0x803), and ISP (0x804) were stubbed out as NULL operations, preventing proper stack pointer management in supervisor mode.

## Root Cause
In the MOVEC write handler (`TG68KdotC_Kernel.vhd:4665-4669`), these registers had NULL operations:

```vhdl
when X"800" => NULL; -- USP -- 68010+
when X"803" => NULL; -- MSP -- 68020+
when X"804" => NULL; -- ISP -- 68020+
```

The MOVEC read handler didn't include these registers at all.

## Affected Functionality
Without this fix:
1. **USP (User Stack Pointer)**: Cannot switch between user/supervisor stack pointers via MOVEC
2. **MSP (Master Stack Pointer)**: 68020+ master mode stack cannot be configured
3. **ISP (Interrupt Stack Pointer)**: 68020+ interrupt stack cannot be configured
4. Operating systems that use MOVEC for stack management fail
5. Context switching and privilege mode changes don't properly save/restore stack pointers

## Stack Pointer Architecture (MC68030)
- **68000/68010**: Single A7 register, switches between USP and SSP based on S bit
- **68020/68030**: Three stack pointers:
  - **USP**: User mode stack (A7 in user mode)
  - **MSP**: Master supervisor stack
  - **ISP**: Interrupt supervisor stack
  - M bit in SR selects between MSP/ISP in supervisor mode

## Fix Applied

### 1. Add Register Declarations (line 336-337)
```vhdl
signal USP  : std_logic_vector(31 downto 0);
signal MSP  : std_logic_vector(31 downto 0);  -- BUG #18: Master Stack Pointer (68020+)
signal ISP  : std_logic_vector(31 downto 0);  -- BUG #18: Interrupt Stack Pointer (68020+)
```

### 2. Initialize on Reset (line 4649-4651)
```vhdl
USP <= (others => '0');   -- BUG #18: Initialize USP
MSP <= (others => '0');   -- BUG #18: Initialize MSP
ISP <= (others => '0');   -- BUG #18: Initialize ISP
```

### 3. MOVEC Write Operations (line 4667, 4670-4671)
```vhdl
when X"800" => USP <= reg_QA; -- BUG #18: USP -- 68010+
when X"803" => MSP <= reg_QA; -- BUG #18: MSP -- 68020+
when X"804" => ISP <= reg_QA; -- BUG #18: ISP -- 68020+
```

### 4. MOVEC Read Operations (line 4691, 4694-4695)
```vhdl
when X"800" => movec_data <= USP;  -- BUG #18: USP -- 68010+
when X"803" => movec_data <= MSP;  -- BUG #18: MSP -- 68020+
when X"804" => movec_data <= ISP;  -- BUG #18: ISP -- 68020+
```

### 5. Update Process Sensitivity List (line 4641)
```vhdl
process (clk, SFC, DFC, VBR, CACR, CAAR, USP, MSP, ISP, brief, pmmu_reg_rdat)
```

## Note on USP
The TG68K already had a USP signal declared and had `to_USP`/`from_USP` exec flags used by the MOVE USP,An / MOVE An,USP instructions. However, MOVEC USP was not implemented. This fix adds MOVEC support while preserving the existing MOVE USP functionality.

## Automatic Stack Pointer Switching (68020+)

### Additional Fix: M Bit Handling
Beyond MOVEC support, this fix also implements **automatic stack pointer switching** for 68020/68030 based on S and M bits in SR:

**Stack Selection Rules:**
- **User mode (S=0)**: A7 = USP
- **Supervisor mode (S=1, M=0)**: A7 = ISP (Interrupt Stack Pointer)
- **Supervisor mode (S=1, M=1)**: A7 = MSP (Master Stack Pointer)

**Implementation** (lines 855-920):
The register file process now automatically saves/restores A7 (regfile(15)) to/from the appropriate stack pointer register on mode transitions:

1. **Exception Entry** (interrupt='1' AND SVmode='0'):
   - Save regfile(15) to USP
   - Load regfile(15) from MSP (if M=1) or ISP (if M=0)

2. **RTE** (exec(directSR)='1'):
   - Check restored SR bits to determine target mode
   - Save regfile(15) to current stack register
   - Load regfile(15) from target stack register

3. **MOVE to SR** (exec(to_SR)='1'):
   - Compare SRin(5) and SRin(4) with current FlagsSR(5) and FlagsSR(4)
   - Save/load regfile(15) appropriately on transitions

This ensures transparent stack pointer management compatible with MC68030 behavior.

## Files Modified
- `rtl/tg68k/TG68KdotC_Kernel.vhd`:
  - Line 336-337: Added MSP/ISP signal declarations
  - Line 855-920: **Implemented automatic A7 switching on mode changes**
  - Line 4641: Updated process sensitivity list
  - Line 4649-4651: Added register initialization on reset
  - Line 4667, 4670-4671: Implemented MOVEC write operations
  - Line 4691, 4694-4695: Implemented MOVEC read operations

## Testing
After this fix, the following should work:
1. `MOVEC USP,D0` / `MOVEC D0,USP` - Read/write user stack pointer
2. `MOVEC MSP,D0` / `MOVEC D0,MSP` - Read/write master stack pointer (68020+)
3. `MOVEC ISP,D0` / `MOVEC D0,ISP` - Read/write interrupt stack pointer (68020+)
4. **Automatic A7 switching on exceptions** (user→supervisor)
5. **Automatic A7 switching on RTE** (supervisor→user or M bit change)
6. **Automatic A7 switching on MOVE to SR** (any S/M bit change)
7. Operating system dual-stack operation (separate interrupt and master stacks)

## Build
This fix is included in Build #5.
