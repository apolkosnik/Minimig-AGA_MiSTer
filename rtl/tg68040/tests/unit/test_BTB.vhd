------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 BTB Unit Tests (Phase 8)                                        --
--                                                                          --
-- Tests for Branch Target Buffer functionality                            --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Branch_Pack.all;

entity test_BTB is
end test_BTB;

architecture test of test_BTB is

    -- Component under test
    component TG68040_BTB is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            lookup_pc      : in std_logic_vector(31 downto 0);
            lookup_hit     : out std_logic;
            lookup_target  : out std_logic_vector(31 downto 0);
            lookup_taken   : out std_logic;
            lookup_type    : out branch_type_t;
            update_en      : in std_logic;
            update_pc      : in std_logic_vector(31 downto 0);
            update_target  : in std_logic_vector(31 downto 0);
            update_taken   : in std_logic;
            update_type    : in branch_type_t;
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Signals
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal lookup_pc : std_logic_vector(31 downto 0);
    signal lookup_hit : std_logic;
    signal lookup_target : std_logic_vector(31 downto 0);
    signal lookup_taken : std_logic;
    signal lookup_type : branch_type_t;
    signal update_en : std_logic;
    signal update_pc : std_logic_vector(31 downto 0);
    signal update_target : std_logic_vector(31 downto 0);
    signal update_taken : std_logic;
    signal update_type : branch_type_t;
    signal lookups : std_logic_vector(31 downto 0);
    signal hits : std_logic_vector(31 downto 0);
    signal misses : std_logic_vector(31 downto 0);

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;

begin

    -- Clock generation
    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT instantiation
    dut: TG68040_BTB
        port map(
            clk           => clk,
            reset         => reset,
            lookup_pc     => lookup_pc,
            lookup_hit    => lookup_hit,
            lookup_target => lookup_target,
            lookup_taken  => lookup_taken,
            lookup_type   => lookup_type,
            update_en     => update_en,
            update_pc     => update_pc,
            update_target => update_target,
            update_taken  => update_taken,
            update_type   => update_type,
            lookups       => lookups,
            hits          => hits,
            misses        => misses
        );

    -- Test stimulus
    test_proc: process
    begin
        -- Test 1: Reset
        report "Test 1: Reset";
        reset <= '1';
        update_en <= '0';
        lookup_pc <= (others => '0');
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;

        -- Test 2: Lookup miss (empty BTB)
        report "Test 2: Lookup miss on empty BTB";
        lookup_pc <= x"00001000";
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Expected miss on empty BTB" severity error;

        -- Test 3: Update entry
        report "Test 3: Update BTB entry";
        update_en <= '1';
        update_pc <= x"00001000";
        update_target <= x"00002000";
        update_taken <= '1';
        update_type <= BRANCH_UNCOND;
        wait for CLK_PERIOD;
        update_en <= '0';
        wait for CLK_PERIOD;

        -- Test 4: Lookup hit
        report "Test 4: Lookup hit after update";
        lookup_pc <= x"00001000";
        wait for CLK_PERIOD;
        assert lookup_hit = '1' report "Expected hit after update" severity error;
        assert lookup_target = x"00002000" report "Wrong target" severity error;
        assert lookup_taken = '1' report "Wrong taken prediction" severity error;
        assert lookup_type = BRANCH_UNCOND report "Wrong branch type" severity error;

        -- Test 5: Lookup miss (different PC)
        report "Test 5: Lookup miss with different PC";
        lookup_pc <= x"00001004";  -- Different PC
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Expected miss with different PC" severity error;

        -- Test 6: Tag aliasing (same index, different tag)
        report "Test 6: Update entry with same index, different tag";
        update_en <= '1';
        update_pc <= x"00011000";  -- Same index (bits 7:2), different tag
        update_target <= x"00003000";
        update_taken <= '0';
        update_type <= BRANCH_COND;
        wait for CLK_PERIOD;
        update_en <= '0';
        wait for CLK_PERIOD;

        -- Test 7: Lookup new entry (old entry replaced)
        report "Test 7: Lookup after replacement";
        lookup_pc <= x"00011000";
        wait for CLK_PERIOD;
        assert lookup_hit = '1' report "Expected hit on new entry" severity error;
        assert lookup_target = x"00003000" report "Wrong target after replacement" severity error;

        -- Test 8: Old entry should miss now
        report "Test 8: Old entry should miss after replacement";
        lookup_pc <= x"00001000";
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Old entry should have been replaced" severity error;

        -- Test 9: Multiple entries in different sets
        report "Test 9: Add multiple entries in different sets";
        for i in 0 to 3 loop
            update_en <= '1';
            update_pc <= std_logic_vector(to_unsigned(16#1000# + i * 4, 32));
            update_target <= std_logic_vector(to_unsigned(16#2000# + i * 4, 32));
            update_taken <= '1';
            update_type <= BRANCH_UNCOND;
            wait for CLK_PERIOD;
        end loop;
        update_en <= '0';
        wait for CLK_PERIOD;

        -- Test 10: Verify all entries
        report "Test 10: Verify all stored entries";
        for i in 0 to 3 loop
            lookup_pc <= std_logic_vector(to_unsigned(16#1000# + i * 4, 32));
            wait for CLK_PERIOD;
            assert lookup_hit = '1'
                report "Expected hit for entry " & integer'image(i) severity error;
            assert lookup_target = std_logic_vector(to_unsigned(16#2000# + i * 4, 32))
                report "Wrong target for entry " & integer'image(i) severity error;
        end loop;

        -- Test 11: Update existing entry
        report "Test 11: Update existing entry";
        update_en <= '1';
        update_pc <= x"00001000";
        update_target <= x"00009000";  -- New target
        update_taken <= '0';  -- New prediction
        update_type <= BRANCH_COND;
        wait for CLK_PERIOD;
        update_en <= '0';
        wait for CLK_PERIOD;

        lookup_pc <= x"00001000";
        wait for CLK_PERIOD;
        assert lookup_hit = '1' report "Expected hit after update" severity error;
        assert lookup_target = x"00009000" report "Target should be updated" severity error;
        assert lookup_taken = '0' report "Taken prediction should be updated" severity error;

        -- Test 12: Reset clears all entries
        report "Test 12: Reset clears all entries";
        reset <= '1';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;

        lookup_pc <= x"00001000";
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "BTB should be empty after reset" severity error;

        -- All tests complete
        report "All BTB tests passed!";
        test_done <= true;
        wait;
    end process;

end test;
