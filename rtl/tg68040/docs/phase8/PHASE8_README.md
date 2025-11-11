# Phase 8: Branch Handling

## Overview

**Phase:** 8 of 15
**Goal:** Implement branch prediction and handling for pipeline efficiency
**Status:** In Progress
**Start Date:** 2025-11-11
**Target Completion:** 2025-11-18 (7 days)

## Objectives

1. ⏳ Design branch prediction mechanism
2. ⏳ Implement branch target buffer (BTB)
3. ⏳ Add branch misprediction detection
4. ⏳ Implement pipeline flush on mispredict
5. ⏳ Add return address stack (RAS)
6. ⏳ Create branch unit tests
7. ⏳ Measure branch prediction accuracy

## MC68040 Branch Architecture

### Branch Types in MC68040

The MC68040 supports several branch instruction types:

1. **Conditional Branches** (Bcc):
   - BRA (unconditional)
   - BEQ, BNE (zero flag)
   - BGT, BLE, BGE, BLT (signed comparisons)
   - BHI, BLS, BCC, BCS (unsigned comparisons)
   - Branch displacement: 8-bit, 16-bit, or 32-bit

2. **Jump Instructions** (JMP, JSR):
   - JMP - Jump to address
   - JSR - Jump to subroutine (push return address)

3. **Subroutine Return** (RTS, RTR, RTD):
   - RTS - Return from subroutine
   - RTR - Return and restore condition codes
   - RTD - Return and deallocate

4. **Decrement and Branch** (DBcc):
   - DBcc Dn, label - Decrement and branch if condition false

### Branch Penalties Without Prediction

In a 6-stage pipeline without branch prediction:

```
IF → ID → EA → OF → EX → WB

Branch instruction:
Cycle 1: IF - Fetch branch
Cycle 2: ID - Decode branch
Cycle 3: EA - Calculate target
Cycle 4: OF - Evaluate condition
Cycle 5: EX - Determine taken/not-taken
Cycle 6: WB - Complete

Pipeline flush required if taken: 4-5 cycles wasted!
```

**Problem:** Branch direction known in EX stage (cycle 5)
- 4 instructions already in pipeline (IF, ID, EA, OF)
- If branch taken: must flush these 4 instructions
- **Penalty:** 4-5 cycles per taken branch

**Impact:** With 15-20% branch instructions, CPI increases by 0.6-1.0

## Phase 8 Approach: Static Branch Prediction

Phase 8 implements **static branch prediction** with a simple strategy:

### Branch Prediction Strategy

**Backward Branches** (negative displacement):
- **Predict TAKEN** (90-95% accuracy)
- Rationale: Usually loop branches
- Example: Loop back to start

**Forward Branches** (positive displacement):
- **Predict NOT TAKEN** (60-70% accuracy)
- Rationale: Usually conditional code
- Example: if-then-else exit

**Unconditional Branches** (BRA, JMP):
- **Always TAKEN** (100% accuracy)
- No prediction needed

**Subroutine Returns** (RTS):
- **Use Return Address Stack** (95-98% accuracy)
- Pop predicted return address
- Verify in EX stage

### Branch Target Buffer (BTB)

The BTB caches branch targets for faster resolution:

```
BTB Entry:
┌─────────────────────────────────────────────┐
│ Valid │ PC (Tag) │ Target │ Type │ Taken   │
│  (1)  │   (30)   │  (32)  │ (2)  │  (1)    │
└─────────────────────────────────────────────┘

BTB Size: 64 entries (direct-mapped for simplicity)
Index: PC[7:2] (6 bits)
Tag: PC[31:8] (24 bits)
```

**BTB Operation:**
1. **IF stage**: Look up PC in BTB
2. **Hit**: Use predicted target, continue fetching
3. **Miss**: Assume not-taken, continue sequential
4. **EX stage**: Verify prediction
5. **Mispredict**: Flush pipeline, update BTB

### Return Address Stack (RAS)

The RAS predicts return addresses for subroutine returns:

```
RAS Structure:
┌────────────┐
│ TOS → Addr │  ← Most recent JSR
├────────────┤
│     Addr   │
├────────────┤
│     Addr   │
├────────────┤
│     ...    │
└────────────┘
Depth: 8 entries

Operations:
- JSR: Push return address (PC + instruction length)
- RTS: Pop return address, predict target
- Overflow: Discard oldest entry
- Underflow: Predict sequential (will mispredict)
```

## Phase 8A: Branch Prediction Design (Days 1-2)

**Deliverables:**
- Branch prediction strategy specification
- BTB structure design
- RAS structure design
- Branch type decoder

### Branch Type Detection

```vhdl
-- Branch type enumeration
type branch_type_t is (
    BRANCH_NONE,       -- Not a branch
    BRANCH_COND,       -- Conditional branch (Bcc)
    BRANCH_UNCOND,     -- Unconditional branch (BRA)
    BRANCH_JSR,        -- Jump to subroutine
    BRANCH_RTS,        -- Return from subroutine
    BRANCH_JMP,        -- Jump
    BRANCH_DBCC        -- Decrement and branch
);

-- Decode branch type from opcode
function decode_branch_type(opcode : std_logic_vector(15 downto 0))
    return branch_type_t is
begin
    case opcode(15 downto 12) is
        when x"6" =>
            if opcode(7 downto 0) = x"00" then
                return BRANCH_UNCOND;  -- BRA
            else
                return BRANCH_COND;    -- Bcc
            end if;
        when x"4" =>
            if opcode(11 downto 6) = "111011" then
                if opcode(5 downto 0) = "010001" then
                    return BRANCH_JSR;  -- JSR
                elsif opcode(5 downto 0) = "010101" then
                    return BRANCH_RTS;  -- RTS
                end if;
            end if;
        when x"5" =>
            if opcode(11 downto 8) = x"1" then
                return BRANCH_DBCC;     -- DBcc
            end if;
        when others =>
            return BRANCH_NONE;
    end case;
    return BRANCH_NONE;
end function;
```

### Static Prediction Logic

```vhdl
-- Predict branch direction based on displacement
function predict_taken(
    branch_type : branch_type_t;
    displacement : std_logic_vector(31 downto 0)
) return std_logic is
begin
    case branch_type is
        when BRANCH_UNCOND | BRANCH_JSR | BRANCH_JMP =>
            return '1';  -- Always taken

        when BRANCH_RTS =>
            return '1';  -- Predict taken (RAS provides target)

        when BRANCH_COND | BRANCH_DBCC =>
            -- Static prediction based on displacement sign
            if displacement(31) = '1' then
                return '1';  -- Backward branch: predict taken
            else
                return '0';  -- Forward branch: predict not-taken
            end if;

        when others =>
            return '0';  -- Not a branch
    end case;
end function;
```

## Phase 8B: Branch Target Buffer (Days 3-4)

**Deliverables:**
- BTB implementation (64 entries)
- BTB lookup in IF stage
- BTB update in EX stage
- BTB statistics

### BTB Structure

```vhdl
entity TG68040_BTB is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Lookup (IF stage)
        lookup_pc      : in std_logic_vector(31 downto 0);
        lookup_hit     : out std_logic;
        lookup_target  : out std_logic_vector(31 downto 0);
        lookup_taken   : out std_logic;

        -- Update (EX stage)
        update_en      : in std_logic;
        update_pc      : in std_logic_vector(31 downto 0);
        update_target  : in std_logic_vector(31 downto 0);
        update_taken   : in std_logic;
        update_type    : in branch_type_t;

        -- Statistics
        lookups        : out std_logic_vector(31 downto 0);
        hits           : out std_logic_vector(31 downto 0);
        misses         : out std_logic_vector(31 downto 0)
    );
end TG68040_BTB;

architecture rtl of TG68040_BTB is

    -- BTB entry
    type btb_entry_t is record
        valid  : std_logic;
        tag    : std_logic_vector(23 downto 0);  -- PC[31:8]
        target : std_logic_vector(31 downto 0);
        taken  : std_logic;
        btype  : branch_type_t;
    end record;

    constant BTB_ENTRY_INIT : btb_entry_t := (
        valid  => '0',
        tag    => (others => '0'),
        target => (others => '0'),
        taken  => '0',
        btype  => BRANCH_NONE
    );

    -- BTB array (64 entries)
    type btb_array_t is array (0 to 63) of btb_entry_t;
    signal btb_array : btb_array_t := (others => BTB_ENTRY_INIT);

begin

    -- BTB lookup (combinational)
    btb_lookup: process(lookup_pc, btb_array)
        variable index : integer range 0 to 63;
        variable tag : std_logic_vector(23 downto 0);
    begin
        index := to_integer(unsigned(lookup_pc(7 downto 2)));
        tag := lookup_pc(31 downto 8);

        if btb_array(index).valid = '1' and btb_array(index).tag = tag then
            lookup_hit <= '1';
            lookup_target <= btb_array(index).target;
            lookup_taken <= btb_array(index).taken;
        else
            lookup_hit <= '0';
            lookup_target <= (others => '0');
            lookup_taken <= '0';
        end if;
    end process;

    -- BTB update (registered)
    btb_update: process(clk)
        variable index : integer range 0 to 63;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                btb_array <= (others => BTB_ENTRY_INIT);
            elsif update_en = '1' then
                index := to_integer(unsigned(update_pc(7 downto 2)));

                btb_array(index).valid <= '1';
                btb_array(index).tag <= update_pc(31 downto 8);
                btb_array(index).target <= update_target;
                btb_array(index).taken <= update_taken;
                btb_array(index).btype <= update_type;
            end if;
        end if;
    end process;

end rtl;
```

## Phase 8C: Return Address Stack (Days 5)

**Deliverables:**
- RAS implementation (8 entries)
- Push on JSR
- Pop on RTS
- RAS statistics

### RAS Structure

```vhdl
entity TG68040_RAS is
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Push (JSR in EX stage)
        push_en        : in std_logic;
        push_addr      : in std_logic_vector(31 downto 0);

        -- Pop (RTS in IF stage)
        pop_en         : in std_logic;
        pop_addr       : out std_logic_vector(31 downto 0);
        pop_valid      : out std_logic;

        -- Statistics
        pushes         : out std_logic_vector(31 downto 0);
        pops           : out std_logic_vector(31 downto 0);
        overflows      : out std_logic_vector(31 downto 0);
        underflows     : out std_logic_vector(31 downto 0)
    );
end TG68040_RAS;

architecture rtl of TG68040_RAS is

    -- RAS array (8 entries)
    type ras_array_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal ras_array : ras_array_t := (others => (others => '0'));

    -- Top of stack pointer
    signal tos : integer range 0 to 7 := 0;
    signal valid_count : integer range 0 to 8 := 0;

    -- Statistics
    signal stat_pushes : unsigned(31 downto 0) := (others => '0');
    signal stat_pops : unsigned(31 downto 0) := (others => '0');
    signal stat_overflows : unsigned(31 downto 0) := (others => '0');
    signal stat_underflows : unsigned(31 downto 0) := (others => '0');

begin

    -- Output statistics
    pushes <= std_logic_vector(stat_pushes);
    pops <= std_logic_vector(stat_pops);
    overflows <= std_logic_vector(stat_overflows);
    underflows <= std_logic_vector(stat_underflows);

    -- RAS operations
    ras_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                tos <= 0;
                valid_count <= 0;
                stat_pushes <= (others => '0');
                stat_pops <= (others => '0');
                stat_overflows <= (others => '0');
                stat_underflows <= (others => '0');
                pop_valid <= '0';

            else
                -- Default
                pop_valid <= '0';

                if push_en = '1' and pop_en = '1' then
                    -- Push and pop simultaneously (tail call optimization)
                    ras_array(tos) <= push_addr;
                    pop_addr <= ras_array(tos);
                    pop_valid <= valid_count > 0;
                    stat_pushes <= stat_pushes + 1;
                    stat_pops <= stat_pops + 1;

                elsif push_en = '1' then
                    -- Push return address
                    if valid_count < 8 then
                        -- Normal push
                        tos <= (tos + 1) mod 8;
                        valid_count <= valid_count + 1;
                        ras_array(tos) <= push_addr;
                    else
                        -- Overflow: overwrite oldest
                        ras_array(tos) <= push_addr;
                        tos <= (tos + 1) mod 8;
                        stat_overflows <= stat_overflows + 1;
                    end if;
                    stat_pushes <= stat_pushes + 1;

                elsif pop_en = '1' then
                    -- Pop return address
                    if valid_count > 0 then
                        -- Normal pop
                        tos <= (tos - 1) mod 8;
                        valid_count <= valid_count - 1;
                        pop_addr <= ras_array((tos - 1) mod 8);
                        pop_valid <= '1';
                    else
                        -- Underflow: predict invalid
                        pop_addr <= (others => '0');
                        pop_valid <= '0';
                        stat_underflows <= stat_underflows + 1;
                    end if;
                    stat_pops <= stat_pops + 1;
                end if;
            end if;
        end if;
    end process;

end rtl;
```

## Phase 8D: Branch Misprediction Detection (Days 6)

**Deliverables:**
- Misprediction detection in EX stage
- Pipeline flush logic
- Branch resolution
- Performance counters

### Misprediction Detection

```vhdl
-- In EX stage
process(clk)
    variable predicted_taken : std_logic;
    variable predicted_target : std_logic_vector(31 downto 0);
    variable actual_taken : std_logic;
    variable actual_target : std_logic_vector(31 downto 0);
    variable mispredict : std_logic;
begin
    if rising_edge(clk) then
        if of_ex.branch_type /= BRANCH_NONE then
            -- Get prediction
            predicted_taken := of_ex.predicted_taken;
            predicted_target := of_ex.predicted_target;

            -- Evaluate actual branch
            actual_taken := evaluate_branch_condition(
                of_ex.branch_type,
                of_ex.condition_code,
                condition_flags
            );

            if actual_taken = '1' then
                actual_target := of_ex.branch_target;
            else
                actual_target := of_ex.pc + of_ex.instr_length;  -- Sequential
            end if;

            -- Compare prediction with actual
            if predicted_taken /= actual_taken or
               (actual_taken = '1' and predicted_target /= actual_target) then
                -- Misprediction!
                mispredict := '1';

                -- Flush pipeline (IF, ID, EA, OF stages)
                flush_if <= '1';
                flush_id <= '1';
                flush_ea <= '1';
                flush_of <= '1';

                -- Redirect fetch to correct target
                pc <= unsigned(actual_target);

                -- Update BTB with correct information
                btb_update_en <= '1';
                btb_update_pc <= of_ex.pc;
                btb_update_target <= actual_target;
                btb_update_taken <= actual_taken;

                -- Statistics
                branch_mispredicts <= branch_mispredicts + 1;
            else
                -- Correct prediction
                mispredict := '0';
                branch_correct_predicts <= branch_correct_predicts + 1;
            end if;

            -- Always update BTB for branches
            btb_update_en <= '1';
        end if;
    end if;
end process;
```

## Phase 8E: Testing (Day 7)

**Unit Tests:**
1. Branch type detection test
2. Static prediction test (backward/forward)
3. BTB lookup test (hit/miss)
4. BTB update test
5. RAS push test
6. RAS pop test
7. RAS overflow/underflow test
8. Misprediction detection test
9. Pipeline flush test
10. Branch sequence test

**Test Scenarios:**

**Test 1: Static Prediction**
```vhdl
-- Backward branch (loop)
branch_type := BRANCH_COND;
displacement := x"FFFFFFFC";  -- -4 (backward)
prediction := predict_taken(branch_type, displacement);
assert prediction = '1' report "Backward branch should predict taken";

-- Forward branch (if-then)
displacement := x"00000010";  -- +16 (forward)
prediction := predict_taken(branch_type, displacement);
assert prediction = '0' report "Forward branch should predict not-taken";
```

**Test 2: BTB Operation**
```vhdl
-- Miss initially
lookup_pc <= x"00001000";
assert lookup_hit = '0' report "Should miss initially";

-- Update BTB
update_en <= '1';
update_pc <= x"00001000";
update_target <= x"00002000";
update_taken <= '1';
wait for CLK_PERIOD;

-- Hit on second lookup
lookup_pc <= x"00001000";
assert lookup_hit = '1' report "Should hit after update";
assert lookup_target = x"00002000" report "Wrong target";
```

**Test 3: RAS Operation**
```vhdl
-- Push return address (JSR)
push_en <= '1';
push_addr <= x"00001004";
wait for CLK_PERIOD;

-- Pop return address (RTS)
pop_en <= '1';
wait for CLK_PERIOD;
assert pop_valid = '1' report "Pop should be valid";
assert pop_addr = x"00001004" report "Wrong return address";
```

## Performance Expectations

### Branch Statistics (Typical Workload)

| Metric | Without Prediction | With Static Prediction |
|--------|-------------------|----------------------|
| Branch Frequency | 15-20% | 15-20% |
| Branch Penalty (taken) | 4-5 cycles | 0-5 cycles (avg 1-2) |
| Branch Penalty (not-taken) | 0 cycles | 0-4 cycles (avg 0.3) |
| Prediction Accuracy | N/A | 75-85% |
| CPI Impact | +0.6-1.0 | +0.2-0.4 |

### Phase 8 Expected Performance

| Branch Type | Frequency | Prediction Accuracy | Penalty (Mispredict) |
|-------------|-----------|-------------------|---------------------|
| Backward (loop) | 50% | 90-95% | 4-5 cycles |
| Forward (if) | 30% | 60-70% | 4-5 cycles |
| Unconditional | 15% | 100% | 0 cycles |
| RTS | 5% | 95-98% | 4-5 cycles |

**Overall:** 75-85% prediction accuracy, 0.2-0.4 CPI increase

### Comparison

| Phase | Branch Handling | Expected CPI |
|-------|----------------|--------------|
| 7 (No prediction) | Flush on all taken branches | 2.3-3.0 |
| 8 (Static prediction) | Predict based on direction | 2.0-2.4 |
| Future (Dynamic) | 2-bit counters, history | 1.5-1.8 |

## Known Limitations (Phase 8)

1. **Static Prediction Only** - No learning from history (Phase 11+)
2. **Simple BTB** - Direct-mapped, 64 entries (could be set-associative)
3. **No Branch History** - No global/local history (Phase 11+)
4. **Small RAS** - 8 entries (could overflow on deep calls)
5. **No Indirect Branch Prediction** - JMP (An) always mispredicts first time
6. **Simple Flush** - Flushes entire pipeline (could be more selective)

## Integration with Previous Phases

### Phase 3-4 Integration (Pipeline + Hazards)
- Branch instructions flow through pipeline normally
- Misprediction triggers pipeline flush
- Forwarding still works for branch condition evaluation

### Phase 5-7 Integration (Caches)
- I-cache continues fetching predicted path
- Misprediction may waste I-cache accesses
- I-cache miss + mispredict = double penalty

## Success Criteria

- [ ] Branch type detection working
- [ ] Static prediction implemented
- [ ] BTB lookup in IF stage
- [ ] BTB update in EX stage
- [ ] RAS push/pop working
- [ ] Misprediction detection accurate
- [ ] Pipeline flush on mispredict
- [ ] All unit tests passing
- [ ] Prediction accuracy measured (75-85%)
- [ ] CPI improvement documented

## Next Steps (Phase 9)

After Phase 8:
1. Implement MMU (Memory Management Unit)
2. Add address translation (TLB)
3. Handle page faults
4. Implement protection checking
5. Add supervisor/user modes

## References

1. MC68040 User's Manual, Section 8: Instruction Pipeline
2. Computer Architecture: A Quantitative Approach - Chapter 3: Instruction-Level Parallelism
3. "Branch Prediction for Modern Architectures" - IEEE
4. "Static Branch Prediction" - Computer Architecture papers

---

**Document Version:** 1.0
**Date:** 2025-11-11
**Status:** In Progress
