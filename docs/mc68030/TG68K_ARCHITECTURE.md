# TG68K Architecture Analysis

## Document Purpose

This document analyzes the existing TG68K (TG68KdotC_Kernel) implementation to understand its architecture and design patterns. This analysis serves as the foundation for the MC68030 implementation.

## Overview

TG68K is a soft-core implementation of the Motorola 68000-family processors, written in VHDL. It supports 68000, 68010, and partial 68020 functionality through configurable generics.

**Author**: Tobias Gubener (tobiflex@opencores.org)
**License**: GNU Lesser General Public License v3
**Last Major Update**: 2020

## File Structure

### Primary Files

| File | Lines | Purpose |
|------|-------|---------|
| `TG68KdotC_Kernel.vhd` | 4,139 | Main CPU kernel and control logic |
| `TG68K_ALU.vhd` | 1,330 | Arithmetic Logic Unit |
| `TG68K_Pack.vhd` | 180 | Type definitions and constants |
| `TG68K.vhd` | 295 | Top-level wrapper for bus interface |

### Compilation Order
1. TG68K_ALU.vhd
2. TG68K_Pack.vhd
3. TG68KdotC_Kernel.vhd
4. TG68K.vhd

## Package Definitions (TG68K_Pack.vhd)

### Micro-States Enumeration

The processor uses a micro-coded control approach with 70+ micro-states:

```vhdl
type micro_states is (
    idle, nop,                           -- Basic states
    ld_nn, st_nn,                        -- Load/store no address calc
    ld_dAn1, ld_AnXn1, ld_AnXn2,        -- Load with address modes
    st_dAn1, st_AnXn1, st_AnXn2,        -- Store with address modes
    ld_AnXnbd1, ld_AnXnbd2, ld_AnXnbd3, -- Extended addr modes (68020)
    ld_229_1...ld_229_4,                 -- 68020 complex addressing
    st_229_1...st_229_4,                 -- 68020 store states
    bra1, bsr1, bsr2,                    -- Branch operations
    dbcc1,                               -- DBcc loop
    movem1, movem2, movem3,              -- MOVEM states
    andi, pack1, pack2, pack3,           -- Special instructions
    op_AxAy, cmpm,                       -- Register operations
    link1, link2, unlink1, unlink2,      -- LINK/UNLINK
    int1...int4,                         -- Interrupt processing
    rte1...rte5,                         -- Return from exception
    rtd1, rtd2,                          -- Return and deallocate
    trap00, trap0...trap6,               -- Trap processing
    cas1, cas2, cas21...cas28,           -- CAS instruction (68020)
    chk20...chk24,                       -- CHK2 instruction (68020)
    movec1,                              -- MOVEC instruction
    movep1...movep5,                     -- MOVEP states
    rota1,                               -- Rotate operations
    bf1,                                 -- Bitfield operations (68020)
    mul1, mul2, mul_end1, mul_end2,      -- Multiplication
    div1, div2, div3, div4,              -- Division
    div_end1, div_end2
);
```

### Operation Constants

The package defines 89 operation control bits (opcodes/flags):

**Major Instruction Groups**:
- `opcMOVE`, `opcMOVEQ`, `opcMOVESR` - Data movement
- `opcADD`, `opcADDQ` - Addition
- `opcOR`, `opcAND`, `opcEOR` - Logical operations
- `opcCMP` - Comparison
- `opcROT` - Rotates and shifts
- `opcEXT` - Sign extension
- `opcABCD`, `opcSBCD` - BCD arithmetic
- `opcBITS` - Bit test/manipulate
- `opcSWAP`, `opcScc` - Special operations
- `opcMULU`, `opcDIVU` - Multiply/divide
- `opcCHK`, `opcCHK2` - CHK instructions
- `opcBF`, `opcBFwb` - Bitfields (68020)
- `opcPACK`, `opcUNPACK` - PACK/UNPACK (68020)
- `opcEXTB` - Extend byte to long (68020)

**Control Flags** (selection of important ones):
- `Regwrena` - Register write enable
- `update_FC` - Update function codes
- `write_reg`, `write_lowlong` - Register write control
- `mem_byte`, `longaktion`, `addrlong` - Data size control
- `use_SP` - Use stack pointer
- `to_CCR`, `to_SR` - Condition code/status register update
- `use_XZFlag` - Use X and Z flags
- `changeMode` - Change privilege mode
- `trap_chk` - Trap/CHK exception
- And many more...

## TG68KdotC_Kernel Architecture

### Generics (Configuration Parameters)

```vhdl
generic(
    SR_Read : integer := 2;           -- 0=user, 1=privileged, 2=switchable
    VBR_Stackframe : integer := 2;    -- 0=no, 1=yes/extended, 2=switchable
    extAddr_Mode : integer := 2;      -- 0=no, 1=yes, 2=switchable
    MUL_Mode : integer := 2;          -- 0=16bit, 1=32bit, 2=switchable, 3=none
    DIV_Mode : integer := 2;          -- 0=16bit, 1=32bit, 2=switchable, 3=none
    BitField : integer := 2;          -- 0=no, 1=yes, 2=switchable
    BarrelShifter : integer := 1;     -- 0=no, 1=yes, 2=switchable
    MUL_Hardware : integer := 1       -- 0=no, 1=yes
);
```

**Switchable Features**: When generic = 2, the feature is controlled by CPU input signal:
- `CPU(0)` controls: SR_Read, VBR_Stackframe (68010 features)
- `CPU(1)` controls: extAddr_Mode, MUL_Mode, DIV_Mode, BitField (68020 features)

### Port Interface

**Input Ports**:
```vhdl
clk          : in std_logic;                    -- System clock
nReset       : in std_logic;                    -- Active-low reset
clkena_in    : in std_logic := '1';             -- Clock enable (for wait states)
data_in      : in std_logic_vector(15 downto 0); -- Data from memory
IPL          : in std_logic_vector(2 downto 0); -- Interrupt priority level
IPL_autovector : in std_logic := '0';           -- Auto-vectored interrupt
berr         : in std_logic := '0';             -- Bus error
CPU          : in std_logic_vector(1 downto 0); -- CPU type (00=68000, 01=68010, 11=68020)
```

**Output Ports**:
```vhdl
addr_out     : out std_logic_vector(31 downto 0); -- Address bus
data_write   : out std_logic_vector(15 downto 0); -- Data to memory
nWr          : out std_logic;                     -- Write strobe (active low)
nUDS         : out std_logic;                     -- Upper data strobe
nLDS         : out std_logic;                     -- Lower data strobe
busstate     : out std_logic_vector(1 downto 0);  -- 00=fetch, 10=read, 11=write, 01=internal
longword     : out std_logic;                     -- 32-bit transfer
nResetOut    : out std_logic;                     -- Reset output
FC           : out std_logic_vector(2 downto 0);  -- Function codes
clr_berr     : out std_logic;                     -- Clear bus error
skipFetch    : out std_logic;                     -- Debug: skip fetch cycle
regin_out    : out std_logic_vector(31 downto 0); -- Debug: register data
CACR_out     : out std_logic_vector(3 downto 0);  -- Cache control register
VBR_out      : out std_logic_vector(31 downto 0); -- Vector base register
```

### Internal Architecture

#### 1. Register File

**Structure**:
```vhdl
type regfile_t is array(0 to 15) of std_logic_vector(31 downto 0);
signal regfile : regfile_t;
```

**Register Mapping**:
- Registers 0-7: D0-D7 (Data registers)
- Registers 8-15: A0-A7 (Address registers)
  - Register 15 is stack pointer (USP or SSP depending on mode)

**Access Mechanism**:
- Two read ports (reg_QA, reg_QB) for simultaneous operand access
- Single write port with byte/word/long write control
- Indexed by `RDindex_A`, `RDindex_B` (0-15)

#### 2. Program Counter (PC)

**Signals**:
```vhdl
signal TG68_PC      : std_logic_vector(31 downto 0); -- Current PC
signal tmp_TG68_PC  : std_logic_vector(31 downto 0); -- Temporary PC
signal TG68_PC_add  : std_logic_vector(31 downto 0); -- PC adder
signal exe_pc       : std_logic_vector(31 downto 0); -- Execution PC
signal last_opc_pc  : std_logic_vector(31 downto 0); -- Last opcode PC
```

**PC Management**:
- PC auto-increments during instruction fetch
- Supports branches, jumps, and exceptions
- Saved for exception processing

#### 3. Address Generation Unit

**Components**:
```vhdl
signal memaddr        : std_logic_vector(31 downto 0); -- Memory address
signal memaddr_reg    : std_logic_vector(31 downto 0); -- Saved address
signal memaddr_delta  : std_logic_vector(31 downto 0); -- Address offset
signal ea_data        : std_logic_vector(31 downto 0); -- Effective address data
```

**Addressing Modes**:
The kernel supports all 68000/68010/68020 addressing modes:
- Register direct (Dn, An)
- Register indirect (An), (An)+, -(An)
- Register indirect with displacement (d16,An), (d8,An,Xn)
- Absolute short/long
- PC relative (d16,PC), (d8,PC,Xn)
- Immediate
- **68020 Extended modes**:
  - Base displacement (bd,An,Xn)
  - Memory indirect ([bd,An,Xn],od)
  - PC relative with index and scale

#### 4. ALU Integration

The kernel instantiates TG68K_ALU for arithmetic operations:

```vhdl
component TG68K_ALU
    generic(
        MUL_Mode : integer;
        MUL_Hardware : integer;
        DIV_Mode : integer;
        BarrelShifter : integer
    );
    port(
        -- Control inputs
        clk, Reset, CPU, clkena_lw,
        execOPC, decodeOPC, exe_condition,
        -- Data inputs
        OP1out, OP2out, reg_QA, reg_QB,
        opcode, exe_opcode, sndOPC,
        -- Control bits
        exec : bit_vector(lastOpcBit downto 0),
        -- Flags
        FlagsSR : in, Flags : out,
        -- Results
        ALUout, addsub_q, c_out
    );
end component;
```

#### 5. Control State Machine

**State Vector**:
```vhdl
signal state : std_logic_vector(1 downto 0);
-- 00 = Fetch instruction
-- 01 = No memory access (internal operation)
-- 10 = Read data
-- 11 = Write data
```

**Micro-State Machine**:
```vhdl
signal micro_state : micro_states;
```

The processor operates through micro-states, with each instruction decomposed into a sequence of micro-operations.

**Typical Instruction Flow**:
1. `idle` - Fetch opcode
2. Decode opcode, determine addressing mode
3. Execute address calculation micro-states (ld_xxx, st_xxx)
4. Execute ALU operation
5. Write back result
6. Return to `idle`

#### 6. Instruction Decode

**Opcode Registers**:
```vhdl
signal opcode     : std_logic_vector(15 downto 0); -- Current opcode
signal exe_opcode : std_logic_vector(15 downto 0); -- Executing opcode
signal sndOPC     : std_logic_vector(15 downto 0); -- Second opcode word
```

**Decode Process**:
- Fetches 16-bit opcode from memory
- Decodes instruction type and addressing modes
- Generates control signals via `exec` bit vector
- Handles multi-word instructions (e.g., immediate data, displacements)

#### 7. Data Path

**Operand Signals**:
```vhdl
signal OP1out : std_logic_vector(31 downto 0); -- Operand 1
signal OP2out : std_logic_vector(31 downto 0); -- Operand 2
```

**Data Type**:
```vhdl
signal datatype     : std_logic_vector(1 downto 0); -- 00=byte, 01=word, 10=long
signal exe_datatype : std_logic_vector(1 downto 0); -- Executing data type
```

**Data Flow**:
1. Read operands from register file or memory
2. Route through OP1out, OP2out
3. ALU processes operands
4. Result written to register or memory

#### 8. Exception Handling

**Interrupt Processing**:
```vhdl
signal IPL_nr : std_logic_vector(2 downto 0); -- Interrupt level
```

**Exception States**:
- `int1` through `int4` - Interrupt processing
- `trap00`, `trap0` through `trap6` - Trap processing
- `rte1` through `rte5` - Return from exception

**Stack Frame**:
- Supports both short (68000) and long (68010+) stack frames
- Controlled by `VBR_Stackframe` generic and `use_VBR_Stackframe` signal

#### 9. Special Registers

```vhdl
signal VBR  : std_logic_vector(31 downto 0); -- Vector Base Register (68010+)
signal CACR : std_logic_vector(3 downto 0);  -- Cache Control Register (68020)
signal SR   : std_logic_vector(15 downto 0); -- Status Register
signal USP  : std_logic_vector(31 downto 0); -- User Stack Pointer
```

## TG68K_ALU Architecture

### Purpose
The ALU module handles all arithmetic and logical operations.

### Key Features

**1. Arithmetic Operations**:
- Add, Subtract (with and without extend/carry)
- BCD addition/subtraction (ABCD, SBCD)
- Negation (NEG, NEGX)
- Comparison (CMP, CMPA)

**2. Logical Operations**:
- AND, OR, EOR (Exclusive OR)
- NOT
- Bit test, set, clear, change (BTST, BSET, BCLR, BCHG)

**3. Shift and Rotate**:
- ASL, ASR (Arithmetic shift)
- LSL, LSR (Logical shift)
- ROL, ROR (Rotate)
- ROXL, ROXR (Rotate with extend)
- **Optional Barrel Shifter** for single-cycle shifts

**4. Multiplication** (configurable):
- **16-bit mode**: MULU.W, MULS.W (16×16→32)
- **32-bit mode**: MULU.L, MULS.L (32×32→32 or 32×32→64)
- **Hardware multiplier option** for speed

**5. Division** (configurable):
- **16-bit mode**: DIVU.W, DIVS.W (32÷16→16q+16r)
- **32-bit mode**: DIVU.L, DIVS.L (64÷32→32q+32r or 32÷32→32q+32r)

**6. Bitfield Operations** (68020, optional):
- BFEXT, BFEXTU - Extract bitfield
- BFINS - Insert bitfield
- BFSET, BFCLR, BFCHG - Set/clear/change bitfield
- BFFO - Find first one in bitfield
- BFTST - Test bitfield

**7. Flag Generation**:
Generates condition code flags:
- **N**: Negative
- **Z**: Zero
- **V**: Overflow
- **C**: Carry
- **X**: Extend (for multi-precision arithmetic)

### ALU Interface

```vhdl
-- Control
clk, Reset, CPU, clkena_lw,
execOPC, decodeOPC, exe_condition,

-- Operation control
exec : bit_vector(lastOpcBit downto 0), -- Control bits from decoder
rot_bits : std_logic_vector(1 downto 0), -- Rotation type

-- Operands
OP1out, OP2out    : in std_logic_vector(31 downto 0),
reg_QA, reg_QB    : in std_logic_vector(31 downto 0),

-- Instruction info
opcode, exe_opcode, sndOPC : in std_logic_vector(15 downto 0),
exe_datatype : in std_logic_vector(1 downto 0),

-- Flags
FlagsSR : in std_logic_vector(7 downto 0),  -- Input flags
Flags   : out std_logic_vector(7 downto 0), -- Output flags

-- Results
ALUout    : out std_logic_vector(31 downto 0), -- Main result
addsub_q  : out std_logic_vector(31 downto 0), -- Add/sub result
c_out     : out std_logic_vector(2 downto 0)   -- Carry outputs
```

## TG68K Top-Level Wrapper

**File**: `TG68K.vhd`

### Purpose
Wraps TG68KdotC_Kernel to provide standard 68K bus interface signals.

### Key Functions

**1. Bus State Machine**:
- Converts kernel's simple interface to full 68K bus protocol
- Generates AS (Address Strobe)
- Handles DTACK (Data Acknowledge) wait states

**2. Peripheral Support**:
- E-clock generation for 6800-style peripherals
- VPA/VMA (Valid Peripheral Address) synchronous bus
- Implements ~1MHz E-clock from system clock

**3. Bus Arbitration**:
- (Basic - for simple systems)

## 68020 Features in TG68K

The current TG68K has partial 68020 support:

### Implemented 68020 Features ✅

1. **Extended Addressing Modes**:
   - Memory indirect
   - Base displacement with index and scale
   - Full outer displacement

2. **32-bit Multiply/Divide**:
   - MULU.L, MULS.L (32×32→32, 32×32→64)
   - DIVU.L, DIVS.L (32÷32, 64÷32)

3. **Bitfield Instructions**:
   - BFEXT, BFEXTU, BFINS
   - BFSET, BFCLR, BFCHG
   - BFFO, BFTST

4. **New Instructions**:
   - CAS, CAS2 (Compare and Swap)
   - CHK2, CMP2
   - TRAPcc (Trap on Condition)
   - PACK, UNPK (Pack/Unpack BCD)
   - EXTB.L (Extend Byte)
   - LINK.L (Long Link)
   - RTD (Return and Deallocate)

5. **Enhanced Instructions**:
   - MOVEM with 68020 addressing modes
   - MOVEC (partial)

### NOT Implemented ❌

1. **No MMU**:
   - No address translation
   - No PMOVE, PTEST, PFLUSH instructions
   - No MMU registers (TC, TT0/TT1, CRP, SRP, MMUSR)

2. **No On-Chip Cache**:
   - CACR exists but doesn't control real cache
   - No instruction cache
   - No data cache
   - No CINV instruction

3. **No Burst Mode**:
   - Standard bus cycles only

4. **Incomplete Instructions**:
   - MOVEC (partially implemented)
   - MOVES (not implemented)
   - BKPT (not fully implemented)
   - CALLM, RTM (not implemented - 68020 only)

5. **No Coprocessor Interface**:
   - No cpGEN instructions
   - No F-line emulator for FPU

## Micro-Architecture Observations

### Strengths

1. **Modular Design**: Clean separation between kernel, ALU, and bus wrapper
2. **Configurable**: Generics allow feature selection
3. **Micro-Coded**: Easy to add new instructions
4. **Well-Tested**: Many bug fixes over years indicate maturity
5. **Compact**: Efficient FPGA resource usage

### Areas for Enhancement (for MC68030)

1. **Add MMU Module**: Separate module for address translation
2. **Add Cache Modules**: I-Cache and D-Cache
3. **Extend Control Bits**: Add MMU/Cache control signals
4. **Add New Micro-States**: For MMU operations (table walk, ATC lookup)
5. **Extend Register File**: Add MMU control registers
6. **Bus Interface**: Add burst mode support

## Design Patterns to Follow

### 1. Generic-Based Feature Control
```vhdl
generic(
    MMU_Enable : integer := 2;    -- 0=no, 1=yes, 2=switchable
    Cache_Enable : integer := 2;   -- 0=no, 1=yes, 2=switchable
);
```

### 2. Micro-State Based Control
Add new micro-states for MC68030 operations:
```vhdl
type micro_states is (
    -- ... existing states ...
    pmove1, pmove2,           -- PMOVE instruction
    pflush1,                  -- PFLUSH instruction
    ptest1, ptest2, ptest3,   -- PTEST instruction
    atc_lookup1,              -- ATC lookup
    table_walk1, table_walk2  -- MMU table walk
);
```

### 3. Control Bit Extension
Add new operation control bits:
```vhdl
constant opcPMOVE    : integer := 89;
constant opcPFLUSH   : integer := 90;
constant opcPTEST    : integer := 91;
constant opcCINV     : integer := 92;
constant mmu_enable  : integer := 93;
constant cache_op    : integer := 94;
```

### 4. Register Addition
Add MMU registers alongside existing special registers:
```vhdl
signal TC     : std_logic_vector(31 downto 0); -- Translation Control
signal TT0    : std_logic_vector(31 downto 0); -- Transparent Translation 0
signal TT1    : std_logic_vector(31 downto 0); -- Transparent Translation 1
signal CRP    : std_logic_vector(63 downto 0); -- CPU Root Pointer
signal SRP    : std_logic_vector(63 downto 0); -- Supervisor Root Pointer
signal MMUSR  : std_logic_vector(15 downto 0); -- MMU Status Register
```

## Code Quality Notes

### Documentation
- Well-commented change history
- Attribution to contributors
- License clearly stated

### Coding Style
- Consistent naming conventions
- Use of packages for type definitions
- Separate files for major components

### Testing History
Multiple bug fixes over years show:
- Active maintenance
- Real-world usage
- Continuous improvement

## Integration Points for MC68030

When building MC68030, these are key integration points:

### 1. Address Generation
**Current**: `memaddr` signal
**MC68030**: Insert MMU between address generation and bus
```
Address Calc → MMU (translate) → Physical Address → Bus
```

### 2. Instruction Fetch
**Current**: Direct PC fetch
**MC68030**: Add I-Cache check
```
PC → I-Cache → (hit) Data
               (miss) Memory → I-Cache → Data
```

### 3. Data Access
**Current**: Direct memory access
**MC68030**: Add D-Cache check (for reads)
```
Address → D-Cache → (hit) Data
                   (miss) Memory → D-Cache → Data
```

### 4. Micro-State Machine
**Current**: ~70 states
**MC68030**: Add ~10-15 states for MMU/Cache operations

### 5. Instruction Decode
**Current**: Opcode → Control bits
**MC68030**: Add decode for PMOVE, PFLUSH, PTEST, CINV

## Resource Estimates

**Current TG68K** (approximate):
- Logic Elements: 3,000 - 5,000 (depending on features)
- Memory bits: ~2,000 (register file)
- Multipliers: 0-2 (if hardware multiplier used)

**Estimated MC68030 Addition**:
- MMU: +1,000 - 2,000 LEs (ATC, table walk)
- I-Cache: +500 - 1,000 LEs + 2,048 memory bits (256 bytes)
- D-Cache: +500 - 1,000 LEs + 2,048 memory bits (256 bytes)
- Control Logic: +500 LEs
- **Total**: +2,500 - 4,500 LEs, +4,096 memory bits

**Estimated Total MC68030**:
- Logic Elements: 5,500 - 9,500
- Memory bits: ~6,000
- Should fit comfortably in modern FPGAs

## Conclusion

TG68K provides an excellent foundation for MC68030 implementation:

✅ **Strengths**:
- Solid 68000/68010/partial 68020 implementation
- Modular architecture
- Configurable features
- Clean code structure
- Well-maintained

✅ **Path Forward**:
- Add MMU module (new VHDL file)
- Add Cache modules (new VHDL files)
- Extend kernel with MMU/Cache control
- Add new micro-states
- Maintain backward compatibility

✅ **Compatibility**:
- Existing 68000/68010 code continues to work
- Existing 68020 features continue to work
- MC68030 features add transparently

## References

- TG68KdotC_Kernel.vhd source code
- TG68K_ALU.vhd source code
- TG68K_Pack.vhd source code
- TG68K.vhd source code
- Change history in source files

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created architecture analysis |

