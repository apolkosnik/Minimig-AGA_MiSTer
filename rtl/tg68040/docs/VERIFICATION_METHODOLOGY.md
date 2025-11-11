# TG68040 Verification Methodology

## Overview

This document defines the verification strategy for the TG68040 MC68040 processor implementation. The goal is to ensure correctness, completeness, and compatibility with the original MC68040 processor.

## Verification Levels

### Level 1: Unit Testing
**Scope:** Individual VHDL modules
**Tool:** GHDL, ModelSim, or Verilator
**Coverage:** Statement, branch, toggle, FSM

**Process:**
1. Write testbench for each module
2. Define test vectors covering:
   - Normal operation
   - Boundary conditions
   - Error conditions
   - Corner cases
3. Run simulation
4. Measure coverage
5. Iterate until >80% coverage

**Example Modules:**
- ALU operations
- Register file
- Cache tag logic
- MMU translation
- FPU arithmetic units

### Level 2: Integration Testing
**Scope:** Subsystems (multiple modules working together)
**Tool:** GHDL + waveform analysis
**Coverage:** Interface protocols, data flow

**Example Subsystems:**
- Pipeline stages (IF→ID→EA→OF→EX→WB)
- Cache + Memory interface
- MMU + Cache
- FPU + Exception handling
- Bus interface + Cache coherency

**Process:**
1. Create bus functional models (BFMs) for external interfaces
2. Define integration test scenarios
3. Verify handshake protocols
4. Check data integrity across boundaries
5. Measure timing characteristics

### Level 3: System Testing
**Scope:** Complete TG68040 core
**Tool:** Full simulation with memory models
**Coverage:** End-to-end instruction execution

**Test Programs:**
1. Assembly test programs (hand-written)
2. C test programs (compiler-generated)
3. Existing 68040 test suites
4. Amiga software

### Level 4: FPGA Testing
**Scope:** Real hardware on MiSTer platform
**Tool:** SignalTap, LED indicators, serial output
**Coverage:** Real-world performance and compatibility

## Test Categories

### 1. Instruction Tests

#### Format
```vhdl
-- Test: ADD.L D0, D1
-- Input: D0=0x12345678, D1=0x00000001
-- Expected: D1=0x12345679, CCR=0x00 (no flags set)
```

#### Coverage Matrix

| Category | Instructions | Priority | Status |
|----------|-------------|----------|--------|
| Data Movement | MOVE, MOVEA, MOVEQ, MOVEM, MOVE16 | High | Planned |
| Integer Arithmetic | ADD, SUB, MUL, DIV, NEG, CLR, CMP | High | Planned |
| Logical | AND, OR, EOR, NOT | High | Planned |
| Shift/Rotate | ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR | Medium | Planned |
| Bit Manipulation | BSET, BCLR, BTST, BCHG, BFEXTU, BFINS | Medium | Planned |
| BCD | ABCD, SBCD, NBCD, PACK, UNPK | Low | Planned |
| Program Control | Bcc, DBcc, Scc, JMP, JSR, RTS, RTR, RTE | High | Planned |
| System Control | STOP, RESET, RTE, MOVE SR, MOVEC | High | Planned |
| FP Data Movement | FMOVE, FMOVEM, FMOVECR | High | Planned |
| FP Arithmetic | FADD, FSUB, FMUL, FDIV, FSQRT, FABS | High | Planned |
| FP Comparison | FCMP, FTST | Medium | Planned |
| FP Conditional | FBcc, FDBcc, FScc, FTRAPcc | Medium | Planned |
| Cache Control | CINV, CPUSH | Medium | Planned |
| MMU Control | PTEST, PFLUSH, PMOVE | Medium | Planned |

#### Test Generation
1. **Manual tests** for basic operations
2. **Random tests** for stress testing
3. **Directed tests** for corner cases
4. **Compliance tests** from public test suites

### 2. Pipeline Tests

**Hazard Detection:**
```assembly
; RAW (Read After Write) hazard
ADD.L D0, D1    ; D1 written
MOVE.L D1, D2   ; D1 read immediately - needs forwarding

; WAW (Write After Write) hazard
MOVE.L D0, D1   ; D1 written
ADD.L D2, D1    ; D1 written again - needs ordering

; Control hazard
BRA target      ; Branch taken
NOP             ; Should not execute (speculative)
target:
```

**Test Coverage:**
- All hazard types detected
- Forwarding paths work correctly
- Pipeline stalls when necessary
- Branch prediction accuracy
- Pipeline flush on exceptions

### 3. Cache Tests

**Cache Hit/Miss Patterns:**
```c
// Sequential access (should hit)
for (i = 0; i < 1024; i++)
    data[i] = i;

// Stride access (may miss)
for (i = 0; i < 1024; i += 64)
    data[i] = i;

// Random access (likely miss)
for (i = 0; i < 1024; i++)
    data[random()] = i;
```

**Test Coverage:**
- Cache line fill
- Cache hit detection
- Cache replacement
- Write-through behavior
- Cache invalidation (CINV)
- Cache push (CPUSH)
- Cache coherency (if applicable)

**Metrics:**
- Hit rate (target: >90% for sequential code)
- Miss penalty (target: <10 cycles)
- Fill latency

### 4. MMU Tests

**Translation Tests:**
```c
// Direct mapping
virt_addr = 0x00100000;
phys_addr = translate(virt_addr);
assert(phys_addr == 0x00100000);  // Transparent translation

// Page table translation
virt_addr = 0x80000000;
phys_addr = translate(virt_addr);
assert(phys_addr == page_table_lookup(virt_addr));

// Protection violation
write_to_readonly_page(addr);
assert(exception_raised == ACCESS_FAULT);
```

**Test Coverage:**
- Transparent translation (ITT/DTT)
- Page table walks (4KB pages)
- TLB hits and misses
- Protection checks (supervisor/user, read/write)
- Invalid page access
- Modified/referenced bits

### 5. FPU Tests

**Arithmetic Accuracy:**
```c
// IEEE 754 compliance tests
assert(fadd(1.0, 2.0) == 3.0);
assert(fsub(5.0, 3.0) == 2.0);
assert(fmul(2.0, 3.0) == 6.0);
assert(fdiv(6.0, 2.0) == 3.0);
assert(fsqrt(4.0) == 2.0);

// Edge cases
assert(fadd(+inf, +inf) == +inf);
assert(fdiv(1.0, 0.0) == +inf);
assert(fsqrt(-1.0) == NaN);
```

**Test Coverage:**
- All FPU instructions
- All data types (single, double, extended)
- All rounding modes
- Exception conditions (overflow, underflow, inexact, invalid, divide-by-zero)
- Denormalized numbers
- NaN and infinity handling
- FPSR flag updates

**Test Suites:**
- IEEE 754 compliance tests
- Paranoia test suite
- UCBTEST
- Custom edge case tests

### 6. Exception Tests

**Exception Types:**
```assembly
; Address error
MOVE.W (0x00001001), D0   ; Odd address - should trap

; Privilege violation
MOVE.W SR, D0             ; User mode - should trap

; Illegal instruction
DC.W 0xFFFF               ; Undefined opcode

; Division by zero
DIVU.W #0, D0

; CHK exception
CHK.W #100, D0            ; D0 > 100 or D0 < 0

; FP exceptions
FDIV.X FP0, FP1           ; FP0 = 1.0, FP1 = 0.0 → divide-by-zero
```

**Test Coverage:**
- All exception types
- Exception priority
- Exception vectors
- Stack frame format
- Return from exception (RTE)
- Nested exceptions

### 7. Performance Tests

**Benchmarks:**
1. **Dhrystone** - Integer performance
2. **Whetstone** - FP performance
3. **CoreMark** - Embedded benchmark
4. **Amiga-specific** - Blitter operations, etc.

**Metrics:**
- DMIPS (Dhrystone MIPS)
- MWIPS (Whetstone MIPS)
- CoreMark score
- Comparison vs TG68K 68020 mode
- Comparison vs real 68040 (target: >50% of real)

## Test Infrastructure

### Directory Structure
```
rtl/tg68040/tests/
├── unit/
│   ├── test_alu.vhd
│   ├── test_regfile.vhd
│   ├── test_cache.vhd
│   ├── test_mmu.vhd
│   └── test_fpu.vhd
├── integration/
│   ├── test_pipeline.vhd
│   ├── test_cache_mmu.vhd
│   └── test_fpu_exceptions.vhd
├── system/
│   ├── test_instructions.vhd
│   ├── test_programs/
│   │   ├── *.asm (assembly tests)
│   │   └── *.c (C tests)
│   └── test_amiga/
│       └── (Amiga software tests)
├── fpga/
│   ├── test_hardware.vhd
│   └── test_mister.tcl
└── common/
    ├── test_pkg.vhd (common test utilities)
    ├── memory_model.vhd
    └── bus_monitor.vhd
```

### Testbench Template

```vhdl
-- Template: Unit Test Testbench
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.test_pkg.all;

entity test_<module_name> is
end test_<module_name>;

architecture sim of test_<module_name> is
    -- Component declaration
    component <module_name> is
        -- ports...
    end component;

    -- Test signals
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    -- other signals...

    -- Test control
    signal test_done : boolean := false;

    -- Constants
    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz

begin
    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: <module_name>
        port map (
            clk => clk,
            reset => reset
            -- other ports...
        );

    -- Stimulus process
    stimulus: process
    begin
        -- Reset
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD;

        -- Test case 1
        report "Test 1: <description>";
        -- stimulus...
        -- check results...
        assert <condition> report "Test 1 failed" severity error;

        -- Test case 2
        report "Test 2: <description>";
        -- stimulus...
        -- check results...
        assert <condition> report "Test 2 failed" severity error;

        -- More test cases...

        -- End
        report "All tests passed";
        test_done <= true;
        wait;
    end process;

end sim;
```

### Automation Scripts

**Makefile for tests:**
```makefile
# Test automation

GHDL := ghdl
GHDL_FLAGS := --std=08 --ieee=synopsys

# Source files
SRCS := ../src/TG68040_*.vhd
TEST_SRCS := $(wildcard unit/*.vhd) $(wildcard integration/*.vhd)

# Targets
.PHONY: all clean unit integration system

all: unit integration

unit:
	@echo "Running unit tests..."
	@for test in unit/test_*.vhd; do \
		$(GHDL) -a $(GHDL_FLAGS) $$test; \
		$(GHDL) -e $(GHDL_FLAGS) $$(basename $$test .vhd); \
		$(GHDL) -r $(GHDL_FLAGS) $$(basename $$test .vhd); \
	done

integration:
	@echo "Running integration tests..."
	@for test in integration/test_*.vhd; do \
		$(GHDL) -a $(GHDL_FLAGS) $$test; \
		$(GHDL) -e $(GHDL_FLAGS) $$(basename $$test .vhd); \
		$(GHDL) -r $(GHDL_FLAGS) $$(basename $$test .vhd); \
	done

clean:
	$(GHDL) --clean
	rm -f *.o *.cf work-obj08.cf
```

## Coverage Metrics

### Code Coverage Targets

| Coverage Type | Target | Measurement |
|---------------|--------|-------------|
| Statement | >90% | Lines of code executed |
| Branch | >85% | Conditional branches taken |
| Toggle | >80% | Signal bit transitions |
| FSM | 100% | State machine states visited |
| Expression | >80% | Boolean sub-expressions |

### Functional Coverage

**Coverage Groups:**
1. **Instructions** - All opcodes exercised
2. **Addressing Modes** - All modes for each instruction
3. **Data Types** - Byte, word, long for each instruction
4. **Edge Cases** - Boundary values, overflow, underflow
5. **Exception Paths** - All exception conditions

**Coverage Plan:**
```systemverilog
// Example coverage group (if using SystemVerilog)
covergroup instr_cov;
    opcode_cp: coverpoint opcode {
        bins move = {MOVE};
        bins add = {ADD, ADDI, ADDQ};
        bins sub = {SUB, SUBI, SUBQ};
        // ... all opcodes
    }

    datatype_cp: coverpoint datatype {
        bins byte = {0};
        bins word = {1};
        bins long = {2};
    }

    cross opcode_cp, datatype_cp;
endgroup
```

## Regression Testing

### Continuous Integration

**Process:**
1. Developer commits code to branch
2. CI system (GitHub Actions or similar) triggers
3. Run all unit tests
4. Run integration tests
5. Generate coverage report
6. Report results (pass/fail + coverage %)

**Acceptance Criteria:**
- All tests pass
- No coverage regression (must maintain or improve)
- No timing violations in synthesis

### Test Selection

**For each commit:**
- Run affected unit tests (fast)
- Run smoke tests (medium)

**Nightly:**
- Run all unit tests
- Run all integration tests
- Run system tests

**Weekly:**
- Run extended tests
- Run FPGA hardware tests
- Run performance benchmarks

## Bug Tracking

### Bug Report Template
```markdown
**Bug ID:** TG68040-XXX
**Title:** Brief description
**Severity:** Critical / Major / Minor / Cosmetic
**Found In:** Phase X, Module Y
**Test Case:** test_module.vhd, line 123

**Description:**
Detailed description of the bug...

**Expected Behavior:**
What should happen...

**Actual Behavior:**
What actually happens...

**Reproduction Steps:**
1. Step 1
2. Step 2
3. ...

**Waveform/Log:**
Attach waveform or simulation log

**Fix:**
Description of fix (after resolution)

**Verification:**
How fix was verified

**Status:** Open / In Progress / Fixed / Verified / Closed
```

### Bug Database
- Track in GitHub Issues or similar
- Tag with phase, module, severity
- Link to commits that fix
- Link to regression tests added

## Documentation Requirements

### For Each Phase

1. **Test Plan**
   - What will be tested
   - How it will be tested
   - Success criteria

2. **Test Results**
   - Test execution log
   - Pass/fail summary
   - Coverage report
   - Performance metrics

3. **Known Issues**
   - List of known bugs
   - Workarounds
   - Priority for fixes

4. **Sign-off**
   - Test plan reviewed
   - All critical tests pass
   - Coverage targets met
   - Ready for next phase

## Tools and Environment

### Simulation Tools
- **GHDL** (open source) - primary tool
- **ModelSim** (if available) - secondary
- **Verilator** (for mixed simulation)

### Waveform Viewers
- **GTKWave** (open source)
- **ModelSim** (built-in)

### Coverage Tools
- **GHDL** with GCOV
- **Questa** coverage (if available)

### Synthesis Tools
- **Quartus Prime** (for Cyclone V FPGA)
- **Vivado** (for alternative FPGAs)

### Version Control
- **Git** with feature branches
- **GitHub** for collaboration

### Documentation
- **Markdown** for text documents
- **Wavedrom** for timing diagrams
- **Graphviz** for block diagrams

## Success Criteria Summary

### Per-Phase Criteria
- [ ] All unit tests pass (100%)
- [ ] Code coverage > 80%
- [ ] Integration tests pass (100%)
- [ ] Documentation complete
- [ ] Code reviewed and approved

### Final Acceptance Criteria
- [ ] All 68040 instructions working
- [ ] Amiga Kickstart 3.1 boots
- [ ] 68040.library functions work
- [ ] Performance > 2x TG68K 68020 mode
- [ ] No known critical bugs
- [ ] All documentation complete

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2025-11-11 | Claude AI | Initial verification methodology |

