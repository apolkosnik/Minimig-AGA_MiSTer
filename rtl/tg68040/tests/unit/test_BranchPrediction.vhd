------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: Branch Prediction                                             --
--                                                                          --
-- Tests branch type detection and static prediction                       --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Branch_Pack.all;
use work.test_pkg.all;

entity test_BranchPrediction is
end test_BranchPrediction;

architecture sim of test_BranchPrediction is

    signal test_done : boolean := false;

begin

    -- Test process
    test_proc: process
        variable opcode : std_logic_vector(15 downto 0);
        variable extension : std_logic_vector(31 downto 0);
        variable btype : branch_type_t;
        variable condition : branch_condition_t;
        variable displacement : std_logic_vector(31 downto 0);
        variable prediction : std_logic;
        variable ccr : std_logic_vector(7 downto 0);
        variable result : std_logic;
    begin
        report "=== Starting Branch Prediction tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Detect BRA (unconditional branch)
        ----------------------------------------------------------------------
        report "--- Test 1: Detect BRA ---";
        opcode := x"6000";  -- BRA with byte displacement
        btype := decode_branch_type(opcode);
        assert btype = BRANCH_UNCOND report "Should detect BRA" severity error;

        ----------------------------------------------------------------------
        -- Test 2: Detect Bcc (conditional branch)
        ----------------------------------------------------------------------
        report "--- Test 2: Detect Bcc ---";
        opcode := x"6700";  -- BEQ (branch if equal)
        btype := decode_branch_type(opcode);
        assert btype = BRANCH_COND report "Should detect Bcc" severity error;

        condition := decode_branch_condition(opcode);
        assert condition = COND_EQ report "Should be EQ condition" severity error;

        ----------------------------------------------------------------------
        -- Test 3: Detect JSR
        ----------------------------------------------------------------------
        report "--- Test 3: Detect JSR ---";
        opcode := x"4EB1";  -- JSR (An)
        btype := decode_branch_type(opcode);
        assert btype = BRANCH_JSR report "Should detect JSR" severity error;

        ----------------------------------------------------------------------
        -- Test 4: Detect RTS
        ----------------------------------------------------------------------
        report "--- Test 4: Detect RTS ---";
        opcode := x"4E75";  -- RTS
        btype := decode_branch_type(opcode);
        assert btype = BRANCH_RTS report "Should detect RTS" severity error;

        ----------------------------------------------------------------------
        -- Test 5: Static prediction - backward branch (loop)
        ----------------------------------------------------------------------
        report "--- Test 5: Predict Backward Branch TAKEN ---";
        btype := BRANCH_COND;
        displacement := x"FFFFFFFC";  -- -4 (backward)
        prediction := predict_branch_taken(btype, displacement);
        assert prediction = '1' report "Backward branch should predict taken" severity error;

        ----------------------------------------------------------------------
        -- Test 6: Static prediction - forward branch (if-then)
        ----------------------------------------------------------------------
        report "--- Test 6: Predict Forward Branch NOT TAKEN ---";
        btype := BRANCH_COND;
        displacement := x"00000010";  -- +16 (forward)
        prediction := predict_branch_taken(btype, displacement);
        assert prediction = '0' report "Forward branch should predict not-taken" severity error;

        ----------------------------------------------------------------------
        -- Test 7: Unconditional always taken
        ----------------------------------------------------------------------
        report "--- Test 7: Unconditional Always TAKEN ---";
        btype := BRANCH_UNCOND;
        displacement := x"00000000";  -- Don't care
        prediction := predict_branch_taken(btype, displacement);
        assert prediction = '1' report "Unconditional should predict taken" severity error;

        ----------------------------------------------------------------------
        -- Test 8: Evaluate BEQ condition (Z=1)
        ----------------------------------------------------------------------
        report "--- Test 8: Evaluate BEQ (Z=1) ---";
        condition := COND_EQ;
        ccr := "00000100";  -- Z=1
        result := evaluate_branch_condition(condition, ccr);
        assert result = '1' report "BEQ should be true when Z=1" severity error;

        ----------------------------------------------------------------------
        -- Test 9: Evaluate BEQ condition (Z=0)
        ----------------------------------------------------------------------
        report "--- Test 9: Evaluate BEQ (Z=0) ---";
        condition := COND_EQ;
        ccr := "00000000";  -- Z=0
        result := evaluate_branch_condition(condition, ccr);
        assert result = '0' report "BEQ should be false when Z=0" severity error;

        ----------------------------------------------------------------------
        -- Test 10: Evaluate BGT condition (N=0, V=0, Z=0)
        ----------------------------------------------------------------------
        report "--- Test 10: Evaluate BGT ---";
        condition := COND_GT;
        ccr := "00000000";  -- N=0, V=0, Z=0
        result := evaluate_branch_condition(condition, ccr);
        assert result = '1' report "BGT should be true" severity error;

        ----------------------------------------------------------------------
        -- Test 11: Branch displacement (byte)
        ----------------------------------------------------------------------
        report "--- Test 11: Get Byte Displacement ---";
        opcode := x"60FE";  -- BRA.B -2
        extension := x"00000000";
        displacement := get_branch_displacement(opcode, extension);
        assert displacement = x"FFFFFFFE" report "Should be -2" severity error;

        ----------------------------------------------------------------------
        -- Test 12: Branch displacement (word)
        ----------------------------------------------------------------------
        report "--- Test 12: Get Word Displacement ---";
        opcode := x"6000";  -- BRA.W
        extension := x"0000FFFE";  -- -2
        displacement := get_branch_displacement(opcode, extension);
        assert displacement = x"FFFFFFFE" report "Should be -2" severity error;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All Branch Prediction tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
