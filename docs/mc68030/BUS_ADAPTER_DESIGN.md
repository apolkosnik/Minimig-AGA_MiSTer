# Bus Width Adapter Design Document

**Module**: TG68K030_Bus_Adapter
**Purpose**: Convert between 32-bit TG68K030 bus and 16-bit Minimig system bus
**Date**: 2025-11-11
**Status**: Design Phase

---

## Problem Statement

The TG68K030 wrapper uses a 32-bit data bus (following MC68030 architecture), but the MiSTer Minimig system uses a 16-bit data bus (following MC68000/68020 convention). A bus width adapter is required to bridge these interfaces.

### Interface Differences

| Aspect | TG68K030 (CPU Side) | Minimig (System Side) |
|--------|---------------------|----------------------|
| Address | 32-bit | 32-bit (same) |
| Data Width | 32-bit | 16-bit |
| Data Strobes | UDS, LDS (for 32-bit) | UDS, LDS (for 16-bit) |
| Transfer Sizes | BYTE, WORD, LONG | BYTE, WORD, LONG |
| Acknowledge | DTACK | DTACK |
| Long Transfer | 1 cycle | 2 cycles (split) |

---

## Design Requirements

### Functional Requirements

1. **Byte Transfers** (size=00):
   - Single 16-bit bus cycle
   - Route byte to correct position in 16-bit word
   - Generate appropriate UDS/LDS

2. **Word Transfers** (size=01):
   - Single 16-bit bus cycle
   - Direct pass-through
   - Generate UDS+LDS

3. **Long Word Transfers** (size=10):
   - **Two sequential 16-bit bus cycles**
   - First cycle: Upper 16 bits (address[31:16])
   - Second cycle: Lower 16 bits (address[15:0])
   - Buffer data between cycles
   - Generate ready after both cycles complete

### Timing Requirements

1. **Single-cycle operations** (byte, word): Add 0-1 clock latency
2. **Long word operations**: Exactly 2 bus cycles
3. **Back-to-back operations**: No bubbles between transfers
4. **Ready signal**: Asserted when transfer complete

### Data Routing Requirements

#### Write Operations

**Byte Write**:
```
CPU: data_out[31:24] or [23:16] or [15:8] or [7:0]
SYS: data_out[15:8] or [7:0] depending on address[1:0]
```

**Word Write**:
```
CPU: data_out[31:16] or [15:0]
SYS: data_out[15:0] directly (even address)
     or misaligned handling needed
```

**Long Write**:
```
Cycle 1: CPU data_out[31:16] → SYS data_out[15:0]
Cycle 2: CPU data_out[15:0] → SYS data_out[15:0]
```

#### Read Operations

**Byte Read**:
```
SYS: data_in[15:8] or [7:0]
CPU: data_in[31:24], [23:16], [15:8], or [7:0] depending on address
```

**Word Read**:
```
SYS: data_in[15:0]
CPU: data_in[31:16] or [15:0] depending on address[1]
```

**Long Read**:
```
Cycle 1: SYS data_in[15:0] → buffer[31:16]
Cycle 2: SYS data_in[15:0] → buffer[15:0]
Result: CPU data_in[31:0] = buffer
```

---

## State Machine Design

### States

```
IDLE         - Waiting for CPU request
LONG_UPPER   - Transferring upper 16 bits of long word
LONG_WAIT    - Wait for dtack deassert between long word cycles
LONG_LOWER   - Transferring lower 16 bits of long word
WAIT_READY   - Waiting for system bus ready
```

**Note**: The LONG_WAIT state was added to ensure proper 68000 bus protocol compliance. The bus requires dtack to deassert between consecutive transfers to avoid bus contention.

### State Transitions

```
IDLE:
  - cpu_as==0 && size==LONG → LONG_UPPER
  - cpu_as==0 && size!=LONG → WAIT_READY
  - cpu_as==1 → IDLE

LONG_UPPER:
  - sys_dtack==0 → LONG_WAIT (deassert sys_as, buffer read data)
  - sys_dtack==1 → LONG_UPPER

LONG_WAIT:
  - sys_dtack==1 → LONG_LOWER (assert sys_as, increment address)
  - sys_dtack==0 → LONG_WAIT

LONG_LOWER:
  - sys_dtack==0 → IDLE (assert cpu_dtack, deassert sys_as)
  - sys_dtack==1 → LONG_LOWER

WAIT_READY:
  - sys_dtack==0 → IDLE (assert cpu_dtack, deassert sys_as)
  - sys_dtack==1 → WAIT_READY
```

---

## Module Interface

```verilog
module TG68K030_Bus_Adapter
(
    input             clk,
    input             reset,

    // 32-bit CPU side (TG68K030)
    input      [31:0] cpu_addr,        // CPU address
    input      [31:0] cpu_data_write,  // CPU write data
    output reg [31:0] cpu_data_read,   // CPU read data
    input             cpu_as,           // CPU address strobe
    input             cpu_write,        // CPU write (0=read, 1=write)
    input       [1:0] cpu_size,         // CPU transfer size (00=byte, 01=word, 10=long)
    output reg        cpu_dtack,        // CPU data acknowledge

    // 16-bit System side (Minimig)
    output reg [31:0] sys_addr,        // System address (32-bit, but only 24-bit used)
    output reg [15:0] sys_data_write,  // System write data
    input      [15:0] sys_data_read,   // System read data
    output reg        sys_as,           // System address strobe
    output reg        sys_uds,          // System upper data strobe
    output reg        sys_lds,          // System lower data strobe
    output reg        sys_rw,           // System read/write (0=write, 1=read)
    input             sys_dtack         // System data acknowledge
);
```

---

## Data Routing Logic

### Write Data Routing

```verilog
always @(*) begin
    case (state)
        IDLE, WAIT_READY: begin
            case (cpu_size)
                2'b00: begin // Byte
                    case (cpu_addr[1:0])
                        2'b00: sys_data_write = {cpu_data_write[31:24], 8'h00};
                        2'b01: sys_data_write = {8'h00, cpu_data_write[23:16]};
                        2'b10: sys_data_write = {cpu_data_write[15:8], 8'h00};
                        2'b11: sys_data_write = {8'h00, cpu_data_write[7:0]};
                    endcase
                end
                2'b01: begin // Word
                    sys_data_write = cpu_addr[1] ? cpu_data_write[15:0] : cpu_data_write[31:16];
                end
                2'b10: begin // Long - not in IDLE
                    sys_data_write = 16'h0000;
                end
                default: sys_data_write = 16'h0000;
            endcase
        end

        LONG_UPPER: begin
            sys_data_write = cpu_data_write[31:16]; // Upper word
        end

        LONG_LOWER: begin
            sys_data_write = cpu_data_write[15:0];  // Lower word
        end
    endcase
end
```

### Read Data Routing

```verilog
always @(*) begin
    if (state == LONG_LOWER && sys_dtack) begin
        // Complete long word read
        cpu_data_read = {data_buffer[31:16], sys_data_read};
    end
    else begin
        case (cpu_size)
            2'b00: begin // Byte
                case (cpu_addr[1:0])
                    2'b00: cpu_data_read = {sys_data_read[15:8], 24'h000000};
                    2'b01: cpu_data_read = {8'h00, sys_data_read[7:0], 16'h0000};
                    2'b10: cpu_data_read = {16'h0000, sys_data_read[15:8], 8'h00};
                    2'b11: cpu_data_read = {24'h000000, sys_data_read[7:0]};
                endcase
            end
            2'b01: begin // Word
                cpu_data_read = cpu_addr[1] ? {16'h0000, sys_data_read} : {sys_data_read, 16'h0000};
            end
            2'b10: begin // Long
                cpu_data_read = {data_buffer[31:16], sys_data_read};
            end
            default: cpu_data_read = 32'h00000000;
        endcase
    end
end
```

### UDS/LDS Generation

```verilog
always @(*) begin
    sys_uds = 1'b1;  // Default: inactive (active low)
    sys_lds = 1'b1;

    if (sys_as) begin
        case (state)
            IDLE, WAIT_READY: begin
                case (cpu_size)
                    2'b00: begin // Byte
                        case (cpu_addr[1:0])
                            2'b00: sys_uds = 1'b0;       // Upper byte
                            2'b01: sys_lds = 1'b0;       // Lower byte
                            2'b10: sys_uds = 1'b0;       // Upper byte
                            2'b11: sys_lds = 1'b0;       // Lower byte
                        endcase
                    end
                    2'b01: begin // Word
                        sys_uds = 1'b0;
                        sys_lds = 1'b0;
                    end
                endcase
            end

            LONG_UPPER, LONG_LOWER: begin
                // Both strobes for long word transfers
                sys_uds = 1'b0;
                sys_lds = 1'b0;
            end
        endcase
    end
end
```

---

## State Machine Implementation

```verilog
// State machine registers
reg [2:0] state;
reg [15:0] data_buffer;  // Buffer for long word upper 16 bits

localparam IDLE       = 3'b000;
localparam LONG_UPPER = 3'b001;
localparam LONG_WAIT  = 3'b010;
localparam LONG_LOWER = 3'b011;
localparam WAIT_READY = 3'b100;

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        cpu_dtack <= 1'b1;  // Inactive (active low)
        sys_as <= 1'b1;
        sys_rw <= 1'b1;
        data_buffer <= 16'h0000;
    end
    else begin
        case (state)
            IDLE: begin
                cpu_dtack <= 1'b1;

                if (cpu_as == 1'b0) begin  // CPU requests transfer
                    sys_as <= 1'b0;
                    sys_rw <= ~cpu_write;
                    sys_addr <= cpu_addr;

                    if (cpu_size == 2'b10) begin
                        // Long word - requires 2 cycles
                        state <= LONG_UPPER;
                    end
                    else begin
                        // Byte or word - single cycle
                        state <= WAIT_READY;
                    end
                end
            end

            LONG_UPPER: begin
                if (sys_dtack == 1'b0) begin
                    // Upper word complete
                    if (~cpu_write) begin
                        // Read: save upper 16 bits
                        data_buffer <= sys_data_read;
                    end

                    // Deassert AS and wait for dtack to go high
                    sys_as <= 1'b1;
                    state <= LONG_WAIT;
                end
            end

            LONG_WAIT: begin
                // Wait for dtack to deassert before starting second transfer
                if (sys_dtack == 1'b1) begin
                    // dtack deasserted, start second transfer
                    sys_addr <= sys_addr + 32'd2;  // Increment address by 2
                    sys_as <= 1'b0;                // Assert AS for second cycle
                    state <= LONG_LOWER;
                end
            end

            LONG_LOWER: begin
                if (sys_dtack == 1'b0) begin
                    // Lower word complete
                    // For reads, data_buffer[31:16] + sys_data_read[15:0] = full 32-bit
                    cpu_dtack <= 1'b0;  // Signal CPU completion
                    sys_as <= 1'b1;     // De-assert system AS
                    state <= IDLE;
                end
            end

            WAIT_READY: begin
                if (sys_dtack == 1'b0) begin
                    // Transfer complete
                    cpu_dtack <= 1'b0;
                    sys_as <= 1'b1;
                    state <= IDLE;
                end
            end
        endcase
    end
end
```

---

## Address Handling

### Long Word Address Alignment

For long word transfers, the MC68030 expects long words to be aligned on even addresses (address[0]=0). However, the adapter must handle:

1. **First cycle**: Use address as-is
2. **Second cycle**: Increment address by 2

```verilog
// In LONG_UPPER → LONG_LOWER transition:
sys_addr <= cpu_addr + 2;  // Next word
```

### Byte Address Mapping

Byte addresses map differently to 16-bit bus:

```
CPU addr[1:0]  →  System position
    00         →  D15-D8 (upper byte, UDS)
    01         →  D7-D0 (lower byte, LDS)
    10         →  D15-D8 (upper byte, UDS)
    11         →  D7-D0 (lower byte, LDS)
```

---

## Timing Diagrams

### Byte Transfer (1 cycle)

```
Clock:    ___/‾‾‾\___/‾‾‾\___
cpu_as:   ‾‾‾\___________/‾‾‾
sys_as:   ‾‾‾\___________/‾‾‾
sys_dtack:‾‾‾‾‾‾‾\_____/‾‾‾‾‾
cpu_dtack:‾‾‾‾‾‾‾\_____/‾‾‾‾‾
State:    IDLE→WAIT_READY→IDLE
```

### Word Transfer (1 cycle)

```
Clock:    ___/‾‾‾\___/‾‾‾\___
cpu_as:   ‾‾‾\___________/‾‾‾
sys_as:   ‾‾‾\___________/‾‾‾
sys_dtack:‾‾‾‾‾‾‾\_____/‾‾‾‾‾
cpu_dtack:‾‾‾‾‾‾‾\_____/‾‾‾‾‾
State:    IDLE→WAIT_READY→IDLE
```

### Long Word Transfer (3 states, 2 bus cycles)

```
Clock:    ___/‾‾‾\___/‾‾‾\___/‾‾‾\___/‾‾‾\___
cpu_as:   ‾‾‾\___________________________/‾‾‾
sys_as:   ‾‾‾\___/‾‾‾‾‾‾‾\___________/‾‾‾‾‾‾‾
sys_dtack:‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾
cpu_dtack:‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾
State:    IDLE→LONG_UPPER→LONG_WAIT→LONG_LOWER→IDLE
Address:  XXXX→XXXX→XXXX→XXXX+2→XXXX
```

**Note**: The sys_as signal deasserts during LONG_WAIT to ensure proper bus protocol. This allows the bus to idle before the second transfer begins, preventing bus contention.

---

## Resource Estimates

### Logic Resources

| Component | Estimate |
|-----------|----------|
| State machine | 50 LUTs |
| Data routing muxes | 150 LUTs |
| Address increment | 20 LUTs |
| Control logic | 80 LUTs |
| **Total** | **~300 LUTs** |

### Registers

| Component | Bits |
|-----------|------|
| State | 2 |
| Data buffer | 16 |
| Address buffer | 32 |
| Control signals | 10 |
| **Total** | **~60 registers** |

### Critical Paths

1. **Data routing**: Combinational mux for 32→16 bit selection
2. **Address increment**: 32-bit adder for long word second cycle
3. **State machine**: Sequential logic, not critical

**Expected Fmax**: >100 MHz (well within Cyclone V capability)

---

## Testing Strategy

### Test Cases

1. **Byte Transfers**:
   - Write byte to address 0x1000 (upper byte)
   - Write byte to address 0x1001 (lower byte)
   - Read byte from address 0x1002
   - Read byte from address 0x1003

2. **Word Transfers**:
   - Write word to aligned address 0x2000
   - Write word to odd address 0x2001 (should work if system supports)
   - Read word from 0x2002

3. **Long Word Transfers**:
   - Write long word 0x12345678 to address 0x3000
   - Verify two bus cycles occur
   - Verify first cycle writes 0x1234
   - Verify second cycle writes 0x5678
   - Read long word from 0x3004

4. **Back-to-Back Transfers**:
   - Multiple byte transfers in sequence
   - Word followed by long word
   - Long word followed by byte

### Simulation

Use ModelSim/QuestaSim to verify:
- Correct data routing
- Proper timing
- UDS/LDS generation
- State transitions

### Hardware Testing

On MiSTer:
- Run memory test programs
- Verify data integrity
- Check performance impact

---

## Known Limitations

1. **Latency**: Adds 0-1 clock for byte/word, 2 clocks for long word
2. **Alignment**: Assumes CPU generates valid alignments
3. **Bursts**: Not supported (requires memory controller changes)
4. **Exceptions**: Bus errors not fully handled

---

## Future Enhancements

1. **Burst Mode**: Support burst transfers for cache fills
2. **Pipelining**: Overlap transfers to reduce latency
3. **Error Handling**: Proper bus error propagation
4. **Performance Counters**: Track adapter efficiency

---

## Implementation Checklist

- [x] Create module skeleton
- [x] Implement state machine (5-state FSM with LONG_WAIT)
- [x] Implement data routing (write)
- [x] Implement data routing (read)
- [x] Implement UDS/LDS generation
- [x] Implement address handling
- [x] Add reset logic
- [x] Fix DTACK handshaking bug (added LONG_WAIT state)
- [x] Add to build system (files.qip)
- [x] Write testbench (rtl/TG68K030_Bus_Adapter_tb.v - 520 lines)
- [x] Create simulation script (rtl/run_bus_adapter_sim.sh)
- [x] Document simulation procedure (BUS_ADAPTER_SIMULATION.md)
- [ ] Run simulation (requires iverilog - user can run locally)
- [ ] Review timing
- [ ] Synthesize and check resources
- [ ] Integrate with cpu_wrapper.v (conditional compilation)
- [ ] Hardware testing

---

## Bug Fixes and Revisions

### Revision 1 (2025-11-12): DTACK Handshaking Fix
**Problem**: Original design transitioned directly from LONG_UPPER to LONG_LOWER without waiting for dtack to deassert, violating 68000 bus protocol.

**Fix**: Added LONG_WAIT state to properly handle bus handshaking:
- State machine expanded from 4 states to 5 states
- LONG_UPPER now deasserts sys_as and transitions to LONG_WAIT
- LONG_WAIT waits for sys_dtack to go high before starting second transfer
- Ensures proper bus idle time between consecutive transfers

**Impact**: Prevents bus contention and timing violations in hardware.

---

## References

- MC68030 User's Manual, Section 6: Bus Operation
- Minimig-AGA cpu_wrapper.v implementation
- TG68K030.vhd interface specification
- **[BUS_ADAPTER_SIMULATION.md](BUS_ADAPTER_SIMULATION.md)** - Testbench documentation and simulation guide

---

## Related Files

- **rtl/TG68K030_Bus_Adapter.v** - Implementation (260 lines)
- **rtl/TG68K030_Bus_Adapter_tb.v** - Testbench (520 lines)
- **rtl/run_bus_adapter_sim.sh** - Simulation automation script
- **docs/mc68030/BUS_ADAPTER_SIMULATION.md** - Simulation guide

---

**Status**: Implementation and testbench complete
**Files**: Implementation (260 lines) + Testbench (520 lines)
**Next Step**: Local simulation validation (requires iverilog) or hardware testing
