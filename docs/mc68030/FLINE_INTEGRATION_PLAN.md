# F-Line Instruction Integration Plan

## Overview

Integrate PMOVE, PFLUSH, and PTEST instructions into TG68KdotC_Kernel to replace the current trap_1111 behavior for recognized MMU instructions.

## Current State

Currently in TG68KdotC_Kernel.vhd lines 3103-3133, ALL F-line instructions ($F000-$FFFF) cause `trap_1111 <= '1'`, generating an F-line emulator exception.

## Goal

Recognize and execute PMOVE/PFLUSH/PTEST instructions while still trapping unrecognized F-line instructions.

## Architecture Decision

**Chosen Approach**: Modify TG68KdotC_Kernel.vhd directly but minimally

**Rationale**:
- F-line instruction decoding must happen during the decode stage
- Can't intercept after trap is set (too late)
- Can't easily wrap/preprocess without major architecture changes
- TG68K already has infrastructure for multi-word F-line instructions (see cpSAVE handling)

## Implementation Strategy

### Phase 1: Add External Decoder Interface (Low Risk)

Add input ports to TG68KdotC_Kernel that external decoders can drive:

```vhdl
-- Add to entity TG68KdotC_Kernel port list:
        -- F-line MMU instruction decode (from external decoders)
        fline_is_mmu    : in std_logic := '0';                   -- This is recognized MMU instruction
        fline_is_pmove  : in std_logic := '0';                   -- PMOVE detected
        fline_is_pflush : in std_logic := '0';                   -- PFLUSH detected
        fline_is_ptest  : in std_logic := '0';                   -- PTEST detected
        -- Execution control
        fline_exec_req  : out std_logic;                         -- Request F-line execution
        fline_exec_done : in std_logic := '0';                   -- F-line execution complete
```

**Risk**: Very low - just adds ports with defaults, doesn't change behavior

### Phase 2: Modify F-Line Handler (Medium Risk)

Replace the WHEN "1111" case to check external decoder signals:

```vhdl
WHEN "1111" =>
    -- Check if external decoder recognized this as MMU instruction
    IF fline_is_mmu='1' THEN
        -- Recognized MMU instruction - route to external executor
        IF decodeOPC='1' THEN
            set(get_2ndOPC) <= '1';           -- Fetch extension word
            next_micro_state <= fline_exec1;   -- New microstate
        END IF;
        IF micro_state=fline_exec1 THEN
            -- Wait for external execution
            fline_exec_req <= '1';
            IF fline_exec_done='1' THEN
                next_micro_state <= idle;      -- Done
            END IF;
        END IF;
    ELSE
        -- Not recognized - trap as before
        IF cpu(1)='1' AND opcode(8 downto 6)="100" THEN --cpSAVE (existing code)
            -- ... existing cpSAVE handling ...
        ELSE
            trap_1111 <= '1';
            trapmake <= '1';
        END IF;
    END IF;
```

**Risk**: Medium - modifies critical decoder, but changes are localized

### Phase 3: Add Microstate (Low Risk)

Add new microstate to micro_states enumeration in TG68K_Pack.vhd:

```vhdl
type micro_states is (idle, nop, ld_nn, ...,
                      fline_exec1,  -- NEW: F-line MMU instruction execution
                      ...);
```

**Risk**: Low - just adds a new state

### Phase 4: External Integration in TG68K030.vhd (Low Risk)

Instantiate decoders in TG68K030.vhd and connect to TG68KdotC_Kernel:

```vhdl
-- Signals
signal fline_is_mmu, fline_is_pmove, fline_is_pflush, fline_is_ptest : std_logic;
signal fline_exec_req, fline_exec_done : std_logic;

-- Instantiate decoders
pmove_decoder: entity work.TG68K030_PMOVE_Decoder
    port map(
        clk => clk,
        reset => reset,
        opcode => tg68k_opcode,           -- From CPU
        extension => tg68k_extension,      -- Second word
        opcode_valid => tg68k_opcode_valid,
        supervisor => cpu_supervisor,
        is_pmove => fline_is_pmove,
        ...
    );

-- Similar for PFLUSH and PTEST decoders

-- Combine decoder outputs
fline_is_mmu <= fline_is_pmove or fline_is_pflush or fline_is_ptest;

-- Connect to CPU core
cpu_core: TG68KdotC_Kernel
    port map(
        ...
        fline_is_mmu => fline_is_mmu,
        fline_is_pmove => fline_is_pmove,
        fline_is_pflush => fline_is_pflush,
        fline_is_ptest => fline_is_ptest,
        fline_exec_req => fline_exec_req,
        fline_exec_done => fline_exec_done,
        ...
    );

-- Execution coordinator
fline_exec: process(clk)
begin
    if rising_edge(clk) then
        if fline_exec_req = '1' then
            if fline_is_pmove = '1' then
                -- Execute PMOVE
                pmove_execute_start <= '1';
                -- Wait for pmove_execute_done
            elsif fline_is_pflush = '1' then
                -- Execute PFLUSH
                pflush_execute_start <= '1';
            elsif fline_is_ptest = '1' then
                -- Execute PTEST
                ptest_execute_start <= '1';
            end if;
        end if;

        fline_exec_done <= pmove_execute_done or pflush_execute_done or ptest_execute_done;
    end if;
end process;
```

**Risk**: Low - adds new components, doesn't modify existing logic

## Alternative Approach (Not Chosen)

**Preprocessing Wrapper**: Create a preprocessor that sits between instruction fetch and CPU core
- **Pros**: No modification to TG68K core
- **Cons**:
  - Complex to implement (needs to understand fetch protocol)
  - Adds latency
  - Doesn't fit TG68K's architecture (tight coupling between fetch and decode)
  - Would still need to prevent trap_1111, which requires modifying TG68K anyway

## Implementation Order

1. ✅ Phase 1: Add external decoder interface ports (safest first)
2. ✅ Phase 3: Add new microstate
3. ✅ Phase 2: Modify F-line handler logic
4. ✅ Phase 4: External integration in TG68K030.vhd

Start with the safest changes and test incrementally.

## Testing Strategy

### Unit Testing
1. Test with F-line non-MMU instruction → should still trap
2. Test with PMOVE → should route to external executor
3. Test with PFLUSH → should route to external executor
4. Test with PTEST → should route to external executor

### Integration Testing
1. Verify no regression on existing 68000/68010/68020 instructions
2. Verify cpSAVE handling still works
3. Verify privilege checking works

### Validation
1. Compare against MC68030 hardware behavior
2. Run Amiga software that uses MMU (AmigaOS 3.x with mmu.library)

## Risk Mitigation

1. **Keep changes minimal**: Only modify what's necessary
2. **Default values**: New ports have safe defaults (fline_is_mmu='0')
3. **Backward compatible**: If external decoder not connected, behaves as before (traps)
4. **Incremental**: Can implement one instruction at a time (PMOVE first)
5. **Testable**: Each phase can be tested independently

## Rollback Plan

If integration causes issues:
1. Phase 1-3 changes can be removed easily (just port additions)
2. Phase 2 change can be reverted to original trap_1111 behavior
3. All changes are localized to WHEN "1111" case

## Success Criteria

- [ ] F-line MMU instructions recognized and don't trap
- [ ] Non-MMU F-line instructions still trap correctly
- [ ] PMOVE can access MMU registers
- [ ] PFLUSH can invalidate ATC entries
- [ ] PTEST can query MMU translations
- [ ] No regression on existing instructions
- [ ] Privilege violations detected correctly

## Notes

- TG68K already fetches second word for multi-word instructions (see `set(get_2ndOPC)`)
- Extension word stored in `sndOPC` signal
- Microstate machine handles multi-cycle instructions
- Exception handling (privilege, illegal) already exists

## Estimated Effort

- Phase 1: 30 minutes
- Phase 2: 1 hour
- Phase 3: 10 minutes
- Phase 4: 2 hours
- Testing: 2 hours
- **Total**: ~5-6 hours

## References

- TG68KdotC_Kernel.vhd: Lines 3103-3133 (current F-line handler)
- TG68K_Pack.vhd: micro_states enumeration
- MC68030 docs: PMOVE.md, PFLUSH.md, PTEST.md
