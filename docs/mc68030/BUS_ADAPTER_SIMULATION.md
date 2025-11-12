# TG68K030_Bus_Adapter Simulation Guide

**Document**: Bus Adapter Testbench Documentation
**Date**: 2025-11-12
**Status**: Ready for simulation

---

## Overview

This document describes the testbench created for the TG68K030_Bus_Adapter module. The testbench validates the critical DTACK handshaking fix and verifies correct operation of the 32-bit to 16-bit bus width conversion.

**Files**:
- `rtl/TG68K030_Bus_Adapter_tb.v` - Verilog testbench (520 lines)
- `rtl/run_bus_adapter_sim.sh` - Automated simulation script

---

## Purpose

The testbench validates:

1. **DTACK Handshaking** - Ensures proper bus protocol compliance with LONG_WAIT state
2. **Long Word Transfers** - Verifies 32-bit reads/writes split into two 16-bit cycles
3. **Single Transfers** - Validates byte and word operations
4. **UDS/LDS Generation** - Checks proper upper/lower data strobe signals
5. **Wait States** - Tests operation with variable memory access delays
6. **Back-to-back Transfers** - Ensures no bus conflicts between consecutive operations

---

## Test Cases

### Test 1: Long Word Read (DTACK Handshaking)

**Purpose**: Verify that the LONG_WAIT state properly handles DTACK deassert between the two 16-bit cycles of a long word transfer.

**Operation**:
1. CPU requests 32-bit read from address 0x00001000
2. Adapter performs upper 16-bit read (address 0x1000)
3. **Waits for DTACK to deassert** (LONG_WAIT state)
4. Adapter performs lower 16-bit read (address 0x1002)
5. CPU receives combined 32-bit data

**Expected Result**: `0xDEADBEEF` (upper: 0xDEAD, lower: 0xBEEF)

**What This Tests**: The critical bug fix - ensures AS deasserts, DTACK goes high, then second transfer begins.

---

### Test 2: Long Word Write (Split Transfer)

**Purpose**: Verify that 32-bit writes are correctly split into two 16-bit writes.

**Operation**:
1. CPU writes 0x12345678 to address 0x00001000
2. Adapter writes 0x1234 to address 0x1000 (upper word)
3. **Waits for DTACK handshake**
4. Adapter writes 0x5678 to address 0x1002 (lower word)

**Expected Result**:
- Memory at 0x1000: 0x1234
- Memory at 0x1002: 0x5678

---

### Test 3: Word Read

**Purpose**: Validate single 16-bit read operations.

**Operation**: CPU reads 16-bit word from address 0x00002000

**Expected Result**: 0xABCD

---

### Test 4: Byte Read

**Purpose**: Validate single 8-bit read operations.

**Operation**: CPU reads byte from address 0x00003000

**Expected Result**: 0x43 (upper byte of 0x4321)

---

### Test 5: DTACK Timing (Wait States)

**Purpose**: Verify operation with slow memory (multiple wait states).

**Operation**:
1. Set memory DTACK delay to 5 cycles
2. CPU reads 32-bit long word
3. Each 16-bit transfer should wait 5 cycles for DTACK

**Expected Result**: Correct data returned despite long delays

**What This Tests**: Adapter properly waits for each DTACK before proceeding.

---

### Test 6: Back-to-back Transfers

**Purpose**: Ensure no bus conflicts between consecutive long word reads.

**Operation**:
1. CPU reads from 0x00005000 → 0x11112222
2. Immediately CPU reads from 0x00005004 → 0x33334444

**Expected Result**: Both reads return correct data with no corruption

**What This Tests**: Bus properly returns to IDLE state between transfers.

---

### Test 7: UDS/LDS Verification

**Purpose**: Validate upper/lower data strobe generation.

**Operation**:
1. Monitor UDS/LDS signals during long word write
2. Upper word: both UDS and LDS should assert (16-bit transfer)
3. Lower word: both UDS and LDS should assert

**Expected Result**:
- First cycle: UDS=0, LDS=0, address[1:0]=00
- Second cycle: UDS=0, LDS=0, address[1:0]=10

---

## Testbench Architecture

### System Bus Simulator

The testbench includes a realistic 16-bit bus simulator:

```verilog
// Key features:
- Configurable DTACK delay (simulates wait states)
- Simulated memory for upper/lower words
- Proper DTACK deassert when AS deasserts
- Read data based on address
- Write data with UDS/LDS masking
```

**DTACK State Machine**:
```
AS asserted → count delay → assert DTACK (low)
AS deasserted → deassert DTACK (high), reset counter
```

This simulates real 68000-style peripheral behavior.

### CPU Bus Cycle Tasks

The testbench provides convenient tasks:

- `cpu_read_byte(addr, data)` - Performs complete byte read cycle
- `cpu_read_word(addr, data)` - Performs complete word read cycle
- `cpu_read_long(addr, data)` - Performs complete long word read cycle
- `cpu_write_long(addr, data)` - Performs complete long word write cycle

Each task:
1. Asserts address and control signals
2. Waits for DTACK assertion
3. Captures/sends data
4. Deasserts AS
5. Waits for DTACK deassertion
6. Returns to idle

---

## Running the Simulation

### Prerequisites

**Icarus Verilog** (open source, free):
```bash
# Ubuntu/Debian
sudo apt-get install iverilog gtkwave

# macOS
brew install icarus-verilog gtkwave

# Windows
# Download from: http://bleyer.org/icarus/
```

### Quick Start

```bash
cd rtl
./run_bus_adapter_sim.sh
```

The script will:
1. Check for iverilog
2. Compile the testbench
3. Run the simulation
4. Generate waveform file

### Expected Output

```
====================================================================
TG68K030_Bus_Adapter Testbench
Testing DTACK handshaking and bus width conversion
====================================================================

--- Test 1: Long Word Read (DTACK handshaking) ---
[PASS] Test 1: Long word read returned data

--- Test 2: Long Word Write (split transfer) ---
[PASS] Test 2: Long word write upper
[PASS] Test 3: Long word write lower

--- Test 3: Word Read ---
[PASS] Test 4: Word read

--- Test 4: Byte Read ---
[PASS] Test 5: Byte read (upper byte)

--- Test 5: DTACK Timing (wait states) ---
[PASS] Test 6: Long word read with wait states

--- Test 6: Back-to-back Transfers ---
[PASS] Test 7: First transfer
[PASS] Test 8: Second transfer

--- Test 7: UDS/LDS Signal Generation ---
  Upper word: UDS=0 LDS=0 (both asserted) ✓
  Lower word: UDS=0 LDS=0 (both asserted) ✓
[PASS] Test 9: UDS/LDS generation

====================================================================
ALL TESTS PASSED! (9 tests)
Bus adapter is functioning correctly.
====================================================================
```

---

## Viewing Waveforms

After simulation, view the waveforms with GTKWave:

```bash
gtkwave TG68K030_Bus_Adapter_tb.vcd
```

### Key Signals to Monitor

**CPU Side**:
- `cpu_addr` - CPU address
- `cpu_as` - CPU address strobe (active low)
- `cpu_dtack` - CPU data acknowledge (active low)
- `cpu_data_write` / `cpu_data_read` - 32-bit data
- `cpu_size` - Transfer size (00=byte, 01=word, 10=long)

**System Side**:
- `sys_addr` - System bus address
- `sys_as` - System address strobe (active low)
- `sys_dtack` - System data acknowledge (active low)
- `sys_data_write` / `sys_data_read` - 16-bit data
- `sys_uds` / `sys_lds` - Upper/lower data strobes

**Internal State**:
- `dut.state` - FSM state (000=IDLE, 001=LONG_UPPER, 010=LONG_WAIT, 011=LONG_LOWER, 100=WAIT_READY)
- `dut.data_buffer` - Buffered upper 16 bits during long word transfer

### Critical Waveform Pattern (Long Word Read)

```
Time:         0ns   20ns  40ns  60ns  80ns  100ns 120ns
                |     |     |     |     |     |     |
cpu_as:    ‾‾‾‾\___________________________________/‾‾‾
sys_as:    ‾‾‾‾\___/‾‾‾‾‾‾‾‾‾\___________/‾‾‾‾‾‾‾‾‾‾‾
sys_dtack: ‾‾‾‾‾‾‾‾\_/‾‾‾‾‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾‾‾‾‾
cpu_dtack: ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾
state:     IDLE→LONG_UPPER→LONG_WAIT→LONG_LOWER→IDLE
sys_addr:  XXXX→1000→1000→1000→1002→1002→XXXX
```

**Key observation**: Note how `sys_as` deasserts during LONG_WAIT state, and `sys_dtack` goes high before the second transfer begins. This is the critical DTACK handshaking that was fixed.

---

## Alternative Simulators

### Verilator

If you prefer Verilator (faster, but requires C++ wrapper):

```bash
# Install
sudo apt-get install verilator

# Compile (requires C++ testbench - not provided)
verilator --cc TG68K030_Bus_Adapter.v --exe TG68K030_Bus_Adapter_tb.cpp
```

### ModelSim/Questa

For commercial simulators:

```tcl
# Create project
vlib work
vmap work work

# Compile
vlog -sv TG68K030_Bus_Adapter.v
vlog -sv TG68K030_Bus_Adapter_tb.v

# Simulate
vsim -voptargs=+acc TG68K030_Bus_Adapter_tb
run -all
```

---

## Debugging Failures

### Test Failure: "Long word read returned data"

**Possible Causes**:
1. State machine not transitioning correctly
2. Data buffer not capturing upper 16 bits
3. Read data routing incorrect

**Debug Steps**:
1. Check `dut.state` transitions: IDLE → LONG_UPPER → LONG_WAIT → LONG_LOWER → IDLE
2. Verify `dut.data_buffer` captures first word correctly
3. Check `cpu_data_read` assembly from buffer + second read

---

### Test Failure: "UDS/LDS generation"

**Possible Causes**:
1. UDS/LDS not generated for both bytes in word transfer
2. Address not incrementing correctly

**Debug Steps**:
1. Monitor `sys_uds` and `sys_lds` during each cycle
2. Check `sys_addr[1:0]`: should be `00` for upper word, `10` for lower word
3. Verify both strobes assert simultaneously for word transfers

---

### Simulation Hangs

**Possible Causes**:
1. DTACK never asserts (system bus simulator issue)
2. State machine stuck in wait state

**Debug Steps**:
1. Check for `wait(cpu_dtack == 1'b0)` hanging
2. Verify system bus simulator is responding to `sys_as`
3. Add timeout watchdog (already included: 100µs)

---

## Manual Simulation (Without iverilog)

If you don't have iverilog, you can:

1. **Use Online Simulators**:
   - EDA Playground: https://www.edaplayground.com
   - Upload TG68K030_Bus_Adapter.v and TG68K030_Bus_Adapter_tb.v
   - Select "Icarus Verilog" as simulator
   - Click "Run"

2. **Use Quartus Simulation**:
   - Open Quartus Prime
   - Create simulation project
   - Add both files to project
   - Use Quartus built-in simulator
   - Run functional simulation

---

## Testbench Limitations

1. **No Timing Violations**: This is a functional testbench, not a timing simulation. It doesn't model setup/hold times or propagation delays.

2. **Simplified Memory Model**: Real memory may have more complex behavior (burst modes, refresh cycles, etc.)

3. **No Error Injection**: Doesn't test bus error conditions or timeout scenarios.

4. **Fixed Test Pattern**: Could benefit from randomized testing.

---

## Future Enhancements

Potential improvements to the testbench:

1. **Randomized Testing**:
   ```verilog
   // Random address generation
   addr = $random % 32'h1000000;
   data = $random;
   ```

2. **Constrained Random**:
   - Random but aligned addresses for long words
   - Random DTACK delays
   - Random transfer sequences

3. **Coverage Metrics**:
   - State coverage (ensure all states visited)
   - Transition coverage (all state transitions)
   - UDS/LDS combination coverage

4. **Bus Error Testing**:
   - Timeout scenarios
   - Misaligned accesses
   - Invalid size encodings

5. **Performance Profiling**:
   - Measure average latency for each transfer type
   - Count total cycles
   - Analyze wait state overhead

---

## Integration Testing

After validating the bus adapter in isolation, the next step is integration testing with the full TG68K030 wrapper. However, per the integration strategy (TG68K030_WRAPPER_INTEGRATION_STRATEGY.md), this should be deferred until after hardware validation of the current Phase 13 implementation.

---

## Success Criteria

The testbench is considered successful if:

- ✅ All 9 test cases pass
- ✅ No simulation errors or warnings
- ✅ Waveforms show proper DTACK handshaking
- ✅ State machine transitions as expected
- ✅ LONG_WAIT state is entered and exited correctly
- ✅ No bus contention (AS asserts only when previous cycle complete)

---

## Related Documentation

- **[BUS_ADAPTER_DESIGN.md](BUS_ADAPTER_DESIGN.md)** - Complete design specification
- **[BUGFIXES_2025-11-12.md](BUGFIXES_2025-11-12.md)** - Bug fix details
- **[PHASE14_PLANNING.md](PHASE14_PLANNING.md)** - Phase 14 implementation plan

---

**Status**: Testbench complete and ready for simulation
**Files**: rtl/TG68K030_Bus_Adapter_tb.v (520 lines)
**Next Step**: Run simulation to validate bug fixes
