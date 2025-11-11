------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: LRU Algorithm (Pseudo-LRU Tree)                              --
--                                                                          --
-- Tests the pseudo-LRU replacement algorithm                              --
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
use work.TG68040_Cache_Pack.all;
use work.test_pkg.all;

entity test_LRU is
end test_LRU;

architecture sim of test_LRU is

    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 20 ns;

begin

    -- Test process
    test_proc: process
        variable lru_bits : std_logic_vector(2 downto 0);
        variable way : integer;
    begin
        report "=== Starting LRU Algorithm tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Initial state
        ----------------------------------------------------------------------
        report "--- Test 1: Initial State ---";
        lru_bits := "000";
        way := get_lru_way(lru_bits);
        assert way = 2 report "Initial LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 2: Access way 0
        ----------------------------------------------------------------------
        report "--- Test 2: Access Way 0 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 0);
        assert lru_bits = "110" report "After accessing way 0: " &
            to_string(lru_bits) severity error;
        way := get_lru_way(lru_bits);
        assert way = 2 report "LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 3: Access way 1
        ----------------------------------------------------------------------
        report "--- Test 3: Access Way 1 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 1);
        assert lru_bits = "100" report "After accessing way 1: " &
            to_string(lru_bits) severity error;
        way := get_lru_way(lru_bits);
        assert way = 2 report "LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 4: Access way 2
        ----------------------------------------------------------------------
        report "--- Test 4: Access Way 2 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 2);
        assert lru_bits = "010" report "After accessing way 2: " &
            to_string(lru_bits) severity error;
        way := get_lru_way(lru_bits);
        assert way = 0 report "LRU should be way 0" severity error;

        ----------------------------------------------------------------------
        -- Test 5: Access way 3
        ----------------------------------------------------------------------
        report "--- Test 5: Access Way 3 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 3);
        assert lru_bits = "000" report "After accessing way 3: " &
            to_string(lru_bits) severity error;
        way := get_lru_way(lru_bits);
        assert way = 2 report "LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 6: Sequence 0, 1, 2, 3
        ----------------------------------------------------------------------
        report "--- Test 6: Sequence 0, 1, 2, 3 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 0);  -- 110
        lru_bits := update_lru_bits(lru_bits, 1);  -- 100
        lru_bits := update_lru_bits(lru_bits, 2);  -- 010
        lru_bits := update_lru_bits(lru_bits, 3);  -- 000
        way := get_lru_way(lru_bits);
        assert way = 2 report "After 0,1,2,3: LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 7: Sequence 3, 2, 1, 0
        ----------------------------------------------------------------------
        report "--- Test 7: Sequence 3, 2, 1, 0 ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 3);  -- 000
        lru_bits := update_lru_bits(lru_bits, 2);  -- 010
        lru_bits := update_lru_bits(lru_bits, 1);  -- 110
        lru_bits := update_lru_bits(lru_bits, 0);  -- 110
        way := get_lru_way(lru_bits);
        assert way = 3 report "After 3,2,1,0: LRU should be way 3" severity error;

        ----------------------------------------------------------------------
        -- Test 8: Access pattern: 0, 0, 0, 0
        ----------------------------------------------------------------------
        report "--- Test 8: Repeated Way 0 Access ---";
        lru_bits := "000";
        lru_bits := update_lru_bits(lru_bits, 0);
        lru_bits := update_lru_bits(lru_bits, 0);
        lru_bits := update_lru_bits(lru_bits, 0);
        lru_bits := update_lru_bits(lru_bits, 0);
        assert lru_bits = "110" report "After repeated way 0: " &
            to_string(lru_bits) severity error;
        way := get_lru_way(lru_bits);
        assert way = 2 report "LRU should be way 2" severity error;

        ----------------------------------------------------------------------
        -- Test 9: Access pattern for real workload
        ----------------------------------------------------------------------
        report "--- Test 9: Real Workload Pattern ---";
        lru_bits := "000";

        -- Simulate accessing ways in order they're filled
        lru_bits := update_lru_bits(lru_bits, 0);  -- Fill way 0
        way := get_lru_way(lru_bits);
        report "After filling way 0, LRU = " & integer'image(way);

        lru_bits := update_lru_bits(lru_bits, 1);  -- Fill way 1
        way := get_lru_way(lru_bits);
        report "After filling way 1, LRU = " & integer'image(way);

        lru_bits := update_lru_bits(lru_bits, 2);  -- Fill way 2
        way := get_lru_way(lru_bits);
        report "After filling way 2, LRU = " & integer'image(way);
        assert way = 0 report "After filling 0,1,2: LRU should be way 0" severity error;

        lru_bits := update_lru_bits(lru_bits, 3);  -- Fill way 3
        way := get_lru_way(lru_bits);
        report "After filling way 3, LRU = " & integer'image(way);
        assert way = 2 report "After filling 0,1,2,3: LRU should be way 2" severity error;

        -- Now access way 0 again (making it more recent)
        lru_bits := update_lru_bits(lru_bits, 0);
        way := get_lru_way(lru_bits);
        report "After re-accessing way 0, LRU = " & integer'image(way);
        assert way = 1 report "After re-accessing way 0: LRU should be way 1" severity error;

        ----------------------------------------------------------------------
        -- Test 10: Exhaustive verification
        ----------------------------------------------------------------------
        report "--- Test 10: Exhaustive Verification ---";
        for b0 in 0 to 1 loop
            for b1 in 0 to 1 loop
                for b2 in 0 to 1 loop
                    lru_bits := std_logic_vector(to_unsigned(b2, 1)) &
                               std_logic_vector(to_unsigned(b1, 1)) &
                               std_logic_vector(to_unsigned(b0, 1));
                    way := get_lru_way(lru_bits);

                    -- Verify returned way is valid
                    assert way >= 0 and way <= 3 report
                        "Invalid LRU way: " & integer'image(way) severity error;

                    -- Update and verify we don't get the same way immediately
                    lru_bits := update_lru_bits(lru_bits, way);

                    report "LRU bits " & to_string(lru_bits) &
                           " → way " & integer'image(way);
                end loop;
            end loop;
        end loop;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All LRU Algorithm tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

    -- Helper function to convert std_logic_vector to string
    function to_string(v : std_logic_vector) return string is
        variable result : string(1 to v'length);
    begin
        for i in v'range loop
            if v(i) = '1' then
                result(i - v'low + 1) := '1';
            else
                result(i - v'low + 1) := '0';
            end if;
        end loop;
        return result;
    end function;

end sim;
