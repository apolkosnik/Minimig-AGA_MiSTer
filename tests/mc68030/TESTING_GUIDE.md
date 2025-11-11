# MC68030 Testing Guide

## Overview

This guide explains how to run tests for the MC68030 implementation. Tests are organized into unit tests, integration tests, and system tests.

## Prerequisites

### Required Tools

1. **GHDL** - VHDL simulator (recommended)
   ```bash
   # Ubuntu/Debian
   sudo apt-get install ghdl ghdl-llvm

   # Fedora
   sudo dnf install ghdl

   # macOS
   brew install ghdl
   ```

2. **GTKWave** - Waveform viewer (optional, for debugging)
   ```bash
   # Ubuntu/Debian
   sudo apt-get install gtkwave

   # Fedora
   sudo dnf install gtkwave

   # macOS
   brew install gtkwave
   ```

### Alternative Simulators

- **ModelSim** - Commercial simulator (requires license)
- **Vivado Simulator** - Free with Vivado installation
- **NVC** - Another open-source VHDL simulator

## Directory Structure

```
tests/mc68030/
├── unit/                    # Unit tests
│   ├── registers/          # Register tests
│   ├── cache/              # Cache tests
│   ├── mmu/                # MMU tests
│   └── instructions/       # Instruction tests
├── integration/            # Integration tests
├── system/                 # System-level tests
├── vectors/                # Test vectors
├── scripts/                # Test automation scripts
│   ├── compile_test.sh    # Compile a testbench
│   ├── run_test.sh        # Run a compiled test
│   └── run_all_tests.sh   # Run all tests
├── results/                # Test results (generated)
├── work/                   # GHDL work directory (generated)
└── mc68030_tb_template.vhd # Testbench template
```

## Quick Start

### 1. Compile a Test

```bash
cd tests/mc68030
./scripts/compile_test.sh unit/registers/test_mmu_registers.vhd
```

### 2. Run the Test

```bash
./scripts/run_test.sh test_mmu_registers_tb
```

### 3. Run with Waveform Generation

```bash
./scripts/run_test.sh test_mmu_registers_tb --wave
```

### 4. View Waveform

```bash
gtkwave results/test_mmu_registers_tb.vcd
```

## Creating a New Test

### Step 1: Copy Template

```bash
cp mc68030_tb_template.vhd unit/registers/test_my_feature.vhd
```

### Step 2: Modify Template

Edit the file and replace:
- Entity name: `mc68030_tb_template` → `test_my_feature_tb`
- Add your DUT (Device Under Test) component declaration
- Add test-specific signals
- Write test stimulus

Example:

```vhdl
entity test_my_feature_tb is
end entity;

architecture behavior of test_my_feature_tb is
    -- Clock and reset
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';

    -- DUT signals
    signal data_in : std_logic_vector(31 downto 0);
    signal data_out : std_logic_vector(31 downto 0);

    -- Component under test
    component my_module is
        port(
            clk : in std_logic;
            reset : in std_logic;
            data_in : in std_logic_vector(31 downto 0);
            data_out : out std_logic_vector(31 downto 0)
        );
    end component;

begin
    -- Clock generation
    clk <= not clk after 10 ns;

    -- DUT instantiation
    dut: my_module
        port map(
            clk => clk,
            reset => reset,
            data_in => data_in,
            data_out => data_out
        );

    -- Test stimulus
    stim_proc: process
    begin
        -- Reset
        reset <= '1';
        wait for 100 ns;
        reset <= '0';

        -- Test 1
        data_in <= x"12345678";
        wait for 20 ns;
        assert data_out = x"12345678"
            report "Test 1 failed" severity error;

        -- More tests...

        report "All tests passed" severity note;
        wait;
    end process;
end architecture;
```

### Step 3: Compile and Run

```bash
./scripts/compile_test.sh unit/registers/test_my_feature.vhd
./scripts/run_test.sh test_my_feature_tb --wave
```

## Test Categories

### Unit Tests

Test individual modules in isolation.

**Example: Testing MMU Registers**

```bash
# Compile
./scripts/compile_test.sh unit/registers/test_mmu_registers.vhd

# Run
./scripts/run_test.sh test_mmu_registers_tb

# Run with waveform
./scripts/run_test.sh test_mmu_registers_tb --wave
```

**Unit test template structure:**
1. Reset DUT
2. Write to register
3. Read from register
4. Verify value
5. Test privilege violations
6. Test edge cases

### Integration Tests

Test interaction between multiple modules.

**Example: CPU + MMU Integration**

```bash
./scripts/compile_test.sh integration/test_cpu_mmu.vhd
./scripts/run_test.sh test_cpu_mmu_tb --wave
```

**Integration test template structure:**
1. Initialize both modules
2. Perform operation on module A
3. Verify effect on module B
4. Test bidirectional interaction
5. Test error conditions

### System Tests

Test complete processor operation.

**Example: Instruction Execution**

```bash
./scripts/compile_test.sh system/test_instruction_execution.vhd
./scripts/run_test.sh test_instruction_execution_tb
```

**System test template structure:**
1. Load test program
2. Execute instructions
3. Verify processor state
4. Check memory contents
5. Verify timing

## Writing Effective Tests

### Best Practices

1. **One test per feature**
   - Keep tests focused
   - Test one thing at a time

2. **Clear test names**
   ```vhdl
   -- Good
   report "Test 1: TC register read/write" severity note;

   -- Bad
   report "Test 1" severity note;
   ```

3. **Use helper procedures**
   ```vhdl
   procedure check_value(
       test_name : string;
       actual : std_logic_vector;
       expected : std_logic_vector
   ) is
   begin
       if actual /= expected then
           report "FAIL: " & test_name severity error;
           test_passed <= false;
       end if;
   end procedure;
   ```

4. **Test edge cases**
   - Minimum values
   - Maximum values
   - Boundary conditions
   - Error conditions

5. **Document test purpose**
   ```vhdl
   --------------------------------------------------------------
   -- Test 3: Verify TC enable bit controls MMU
   --
   -- This test checks that setting TC.E=1 enables the MMU
   -- and setting TC.E=0 disables it.
   --------------------------------------------------------------
   ```

### Assertion Techniques

**Simple assertion:**
```vhdl
assert data_out = x"12345678"
    report "Expected 0x12345678"
    severity error;
```

**Assertion with details:**
```vhdl
assert data_out = expected_value
    report "Expected: " & integer'image(to_integer(unsigned(expected_value))) &
           ", Got: " & integer'image(to_integer(unsigned(data_out)))
    severity error;
```

**Time-based assertion:**
```vhdl
wait for 20 ns;
assert ready = '1'
    report "Ready signal not asserted within 20ns"
    severity error;
```

## Test Automation

### Running All Tests

Create a script to run all tests:

```bash
#!/bin/bash
# run_all_tests.sh

TESTS=(
    "test_mmu_registers_tb"
    "test_cache_registers_tb"
    "test_pmove_tb"
    # Add more tests
)

PASSED=0
FAILED=0

for test in "${TESTS[@]}"; do
    echo "Running $test..."
    if ./scripts/run_test.sh "$test"; then
        ((PASSED++))
    else
        ((FAILED++))
    fi
done

echo "=========================="
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "=========================="

exit $FAILED
```

### Regression Testing

Run all tests before commits:

```bash
# In .git/hooks/pre-commit
#!/bin/bash
cd tests/mc68030
./scripts/run_all_tests.sh
exit $?
```

## Debugging Failed Tests

### Step 1: Read the Log

```bash
cat results/test_name_log.txt
```

Look for:
- Assertion failures
- Error messages
- Unexpected warnings

### Step 2: Generate Waveform

```bash
./scripts/run_test.sh test_name_tb --wave
```

### Step 3: Analyze Waveform

```bash
gtkwave results/test_name_tb.vcd
```

**What to look for:**
1. Signal transitions at correct times
2. Data values match expected
3. State machine transitions
4. Clock and reset behavior

### Step 4: Add Debug Signals

Add temporary signals to testbench:

```vhdl
-- Debug outputs
signal debug_state : std_logic_vector(3 downto 0);
signal debug_counter : integer;

-- In stimulus process
debug_counter <= debug_counter + 1;
report "Step " & integer'image(debug_counter) &
       ": state=" & integer'image(to_integer(unsigned(debug_state)));
```

### Step 5: Increase Verbosity

```vhdl
-- Enable detailed reporting
constant DEBUG_ENABLE : boolean := true;

if DEBUG_ENABLE then
    report "Data written: 0x" & to_hstring(data_in) severity note;
    report "Data read: 0x" & to_hstring(data_out) severity note;
end if;
```

## Performance Testing

### Measuring Cycles

```vhdl
signal cycle_count : integer := 0;

-- In test process
cycle_count <= 0;
-- Start operation
wait until operation_complete = '1';
-- Check cycles
assert cycle_count <= MAX_CYCLES
    report "Operation took too many cycles"
    severity error;

-- In clock process
if not reset then
    cycle_count <= cycle_count + 1;
end if;
```

### Timing Analysis

```vhdl
-- Measure time
variable start_time : time;
variable end_time : time;

start_time := now;
-- Operation
wait until complete = '1';
end_time := now;

report "Operation time: " & time'image(end_time - start_time);
```

## Test Coverage

### Coverage Goals

- **Line Coverage**: > 90%
- **Branch Coverage**: > 85%
- **FSM Coverage**: 100% of states

### Measuring Coverage (with GHDL)

GHDL doesn't have built-in coverage, but you can:

1. **Manual tracking**: Track tested features in a checklist
2. **Code review**: Verify all paths tested
3. **Use commercial tools**: ModelSim, VCS have coverage tools

### Coverage Checklist Template

```markdown
## Module: MMU_Registers

### Features Tested
- [x] TC register read
- [x] TC register write
- [x] TT0 register read/write
- [x] TT1 register read/write
- [x] CRP register read/write
- [x] SRP register read/write
- [ ] MMUSR register read (pending)

### States Tested
- [x] IDLE state
- [x] READ state
- [x] WRITE state
- [ ] ERROR state (pending)

### Edge Cases
- [x] Reset values
- [x] Maximum values
- [x] Zero values
- [ ] Privilege violations (pending)
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: MC68030 Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install GHDL
        run: sudo apt-get install ghdl
      - name: Run Tests
        run: |
          cd tests/mc68030
          ./scripts/run_all_tests.sh
```

## Troubleshooting

### Common Issues

**1. "Entity not found"**
```
Error: entity "my_module" not found
```
**Solution**: Compile dependencies first, check entity name spelling

**2. "Multiple drivers"**
```
Error: signal has multiple drivers
```
**Solution**: Check for signal assigned in multiple processes

**3. "Time resolution error"**
```
Error: time resolution mismatch
```
**Solution**: Use consistent time units (ns, us, ms)

**4. "Simulation hangs"**
```
(simulation never completes)
```
**Solution**:
- Add `--stop-time=1ms` option
- Check for infinite loops
- Verify test_complete signal is set

## References

- GHDL Documentation: https://ghdl.github.io/ghdl/
- GTKWave Documentation: http://gtkwave.sourceforge.net/
- VHDL Testbench Best Practices

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-11 | Initial | Created testing guide |

