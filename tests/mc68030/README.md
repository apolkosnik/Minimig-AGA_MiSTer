# MC68030 Test Suite

This directory contains testbenches, verification scripts, and test cases for the TG68K030 MC68030 processor implementation.

## Overview

The test suite provides comprehensive verification of the MC68030 implementation through:
- Unit tests for individual modules
- Integration tests for subsystems
- System-level tests for full processor operation
- Regression tests to prevent functionality breakage

## Directory Structure

```
tests/mc68030/
├── unit/              # Unit tests for individual modules
│   ├── registers/     # Register tests
│   ├── cache/         # Cache tests
│   ├── mmu/           # MMU tests
│   └── instructions/  # Instruction tests
├── integration/       # Integration tests
├── system/            # System-level tests
├── vectors/           # Test vectors and expected results
├── scripts/           # Test automation scripts
└── results/           # Test results and reports
```

## Test Categories

### Unit Tests
Test individual modules in isolation:
- Register read/write operations
- Cache hit/miss logic
- ATC lookup and replacement
- Instruction decode and execute
- MMU table walk

### Integration Tests
Test interaction between modules:
- CPU + Cache integration
- CPU + MMU integration
- Cache + Memory bus
- MMU + Cache coherency

### System Tests
Test complete processor operation:
- Boot sequence
- Exception handling
- Instruction execution suite
- Real-world code execution

### Regression Tests
Ensure no functionality breaks:
- Existing 68020 compatibility
- Standard instruction set
- System integration

## Test Framework

### Testbench Template
Each module test follows this structure:

```vhdl
-- Test entity
entity test_<module>_tb is
end entity;

architecture behavior of test_<module>_tb is
    -- Component under test
    component <module> is
        -- ports
    end component;

    -- Test signals
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    -- ...

begin
    -- Clock generation
    clk <= not clk after 10 ns;

    -- DUT instantiation
    dut: <module>
        port map (...);

    -- Test process
    test_proc: process
    begin
        -- Test sequence
        wait;
    end process;
end architecture;
```

### Test Execution
Run tests using the provided scripts:

```bash
# Run all tests
./scripts/run_all_tests.sh

# Run specific test category
./scripts/run_unit_tests.sh
./scripts/run_integration_tests.sh

# Run single test
./scripts/run_test.sh test_mmu_registers
```

## Test Coverage Requirements

Each module must achieve:
- **Line Coverage**: >90%
- **Branch Coverage**: >85%
- **FSM Coverage**: 100% of states and transitions

## Test Vector Format

Test vectors are stored in text files with the following format:

```
# Register Read/Write Test
# Format: operation, address, data_in, expected_data_out, expected_flags
WRITE, 0x0000, 0x12345678, 0x00000000, 0x00
READ,  0x0000, 0x00000000, 0x12345678, 0x00
```

## Verification Methodology

### 1. Specification-Based Testing
Tests derived from MC68030 User's Manual specifications.

### 2. Comparison Testing
Compare results against known-good 68020 implementation for common functionality.

### 3. Random Testing
Generate random instruction sequences and verify correct execution.

### 4. Corner Case Testing
Test edge cases, boundary conditions, and error scenarios.

## Test Status

### Phase 1: Setup ✅
- [x] Test directory structure
- [x] Test framework documentation
- [ ] Basic testbench template
- [ ] Test execution scripts

### Phase 2: Register Tests (Pending)
- [ ] MMU register tests
- [ ] Cache register tests
- [ ] Function code register tests

### Phase 3: Instruction Tests (Pending)
- [ ] PMOVE instruction tests
- [ ] PFLUSH instruction tests
- [ ] PTEST instruction tests

### Phase 4: Cache Tests (Pending)
- [ ] I-Cache tests
- [ ] D-Cache tests
- [ ] Cache control tests

### Phase 5: MMU Tests (Pending)
- [ ] Transparent translation tests
- [ ] ATC tests
- [ ] Table walk tests

### Phase 6: Integration Tests (Pending)
- [ ] CPU+Cache integration
- [ ] CPU+MMU integration
- [ ] Full system tests

## Tools Required

- **Simulator**: ModelSim, GHDL, or Xilinx Vivado Simulator
- **Waveform Viewer**: GTKWave or ModelSim waveform viewer
- **Coverage Tools**: ModelSim coverage or similar
- **Build System**: Make or shell scripts

## Running Tests

### Prerequisites
```bash
# Ensure VHDL compiler is installed
which ghdl  # or vcom for ModelSim

# Set up environment variables
export SIM_HOME=/path/to/simulator
export MC68030_ROOT=/home/user/Minimig-AGA_MiSTer
```

### Quick Start
```bash
cd tests/mc68030
./scripts/compile_all.sh    # Compile all sources
./scripts/run_all_tests.sh  # Run all tests
./scripts/generate_report.sh # Generate test report
```

## Test Results

Test results are stored in `results/` directory:
- `test_<module>_results.txt` - Individual test results
- `coverage_report.html` - Code coverage report
- `regression_summary.txt` - Regression test summary

## Continuous Integration

Tests should be run automatically:
- Before each commit
- On pull request creation
- On merge to main branch

## Debugging Tests

When a test fails:

1. Review the test log in `results/`
2. Open waveform file in viewer
3. Check signal values at failure point
4. Verify test vector correctness
5. Debug RTL code if needed

## Adding New Tests

To add a new test:

1. Create test file in appropriate category directory
2. Follow testbench template structure
3. Add test to compilation script
4. Add test to run script
5. Document test purpose and expected results
6. Verify test passes with correct implementation

## Known Issues

None yet - project just started!

## Contributing

When adding tests:
- Follow naming convention: `test_<module>_<feature>.vhd`
- Document test purpose in header comments
- Include pass/fail criteria
- Update this README with test status

## References

- MC68030 User's Manual - Test case specifications
- TG68K tests - Reference for existing 68K test patterns
- IEEE VHDL standards - Testbench best practices

