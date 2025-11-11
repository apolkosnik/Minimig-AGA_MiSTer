# TG68040 Test Suite

## Overview

This directory contains the test infrastructure for the TG68040 MC68040 processor implementation.

## Directory Structure

```
tests/
├── README.md              (this file)
├── Makefile               Test automation
├── common/                Common test utilities
│   └── test_pkg.vhd      Test helper package
├── unit/                  Unit tests (individual modules)
│   └── test_*.vhd        Unit test files
├── integration/           Integration tests (subsystems)
│   └── test_*.vhd        Integration test files
└── system/                System-level tests
    └── test_*.vhd        System test files
```

## Requirements

### Software
- **GHDL** 2.0 or later (open source VHDL simulator)
  - Download: https://github.com/ghdl/ghdl
  - Or use ModelSim/Questa if available
- **Make** (GNU Make)
- **GTKWave** (optional, for waveform viewing)

### Installation (Ubuntu/Debian)
```bash
sudo apt-get install ghdl gtkwave
```

### Installation (macOS with Homebrew)
```bash
brew install ghdl gtkwave
```

### Installation (Windows)
- Download GHDL binaries from GitHub releases
- Or use WSL2 with Linux instructions

## Running Tests

### Quick Start
```bash
# Run all tests
make all

# Run unit tests only
make unit

# Run integration tests only
make integration

# Clean build artifacts
make clean
```

### Individual Test Execution
```bash
# Compile and run specific test
ghdl -a --std=08 --ieee=synopsys ../src/TG68040_Pack.vhd
ghdl -a --std=08 --ieee=synopsys common/test_pkg.vhd
ghdl -a --std=08 --ieee=synopsys unit/test_TG68040_Pack.vhd
ghdl -e --std=08 --ieee=synopsys test_TG68040_Pack
ghdl -r --std=08 --ieee=synopsys test_TG68040_Pack
```

### With Waveform Output
```bash
# Generate VCD file
ghdl -r test_TG68040_Pack --vcd=test_TG68040_Pack.vcd

# View in GTKWave
gtkwave test_TG68040_Pack.vcd
```

## Test Categories

### Unit Tests
Test individual VHDL modules in isolation.

**Current Tests:**
- `test_TG68040_Pack.vhd` - Tests package functions and constants

**Planned Tests:**
- `test_TG68040_RegFile.vhd` - Register file operations
- `test_TG68040_Cache.vhd` - Cache tag and data structures
- `test_TG68040_MMU.vhd` - MMU translation logic
- `test_TG68040_FPU.vhd` - FPU arithmetic units
- `test_TG68040_Pipeline.vhd` - Pipeline stages

### Integration Tests
Test multiple modules working together.

**Planned Tests:**
- `test_cache_mmu.vhd` - Cache and MMU interaction
- `test_pipeline_hazards.vhd` - Pipeline with hazard detection
- `test_fpu_exceptions.vhd` - FPU with exception handling

### System Tests
Test the complete processor with assembly/C programs.

**Planned Tests:**
- Instruction execution tests
- Exception handling tests
- Real-world software tests

## Test Results

Test results are reported to stdout with the following format:

```
PASS: test_name
FAIL: test_name - error message
```

All tests must pass before moving to the next phase.

## Code Coverage

Code coverage is measured using GHDL's coverage features (when available).

**Target Coverage:**
- Statement coverage: >90%
- Branch coverage: >85%
- Toggle coverage: >80%

## Writing New Tests

### Unit Test Template

See `unit/test_TG68040_Pack.vhd` for a complete example.

Basic structure:
```vhdl
library ieee;
use ieee.std_logic_1164.all;
use work.TG68040_Pack.all;
use work.test_pkg.all;

entity test_MyModule is
end test_MyModule;

architecture sim of test_MyModule is
    signal test_done : boolean := false;
begin
    test_proc: process
    begin
        report "=== Starting tests ===";

        -- Test case 1
        assert_equal(actual, expected, "Test description");

        -- Test case 2
        assert_true(condition, "Test description");

        report "=== All tests passed ===";
        test_done <= true;
        wait;
    end process;
end sim;
```

### Using Test Utilities

The `test_pkg` provides helpful procedures:

```vhdl
-- Assert equality (multiple types)
assert_equal(actual_slv, expected_slv, "test name");
assert_equal(actual_int, expected_int, "test name");
assert_equal(actual_bit, expected_bit, "test name");

-- Assert boolean
assert_true(condition, "test name");

-- Manual reporting
report_test("test name", TEST_PASS);
report_test("test name", TEST_FAIL, "error message");
```

## Continuous Integration

(To be set up)

Tests will automatically run on:
- Every commit to feature branches
- Pull requests
- Nightly builds

## Troubleshooting

### GHDL Not Found
```
make: ghdl: command not found
```
**Solution:** Install GHDL (see Requirements above)

### Compilation Errors
```
ghdl: error: ...
```
**Solution:** Check VHDL syntax, ensure using --std=08 flag

### Test Failures
Check the error message for details. Common issues:
- Incorrect expected values
- Logic errors in implementation
- Missing signal updates

## Getting Help

- **GHDL Documentation:** http://ghdl.github.io/ghdl/
- **VHDL Reference:** IEEE Std 1076-2008
- **Project Issues:** https://github.com/apolkosnik/Minimig-AGA_MiSTer/issues

## License

LGPL v3 (matching TG68K)

## Status

**Current Phase:** Phase 1 - Core Extension & CPU ID
**Tests Implemented:** 1 (test_TG68040_Pack)
**Tests Passing:** 1/1 (100%)
**Coverage:** Not yet measured

---

Last Updated: 2025-11-11
