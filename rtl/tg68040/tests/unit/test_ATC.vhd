------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 ATC Unit Tests (Phase 9)                                        --
--                                                                          --
-- Tests for Address Translation Cache functionality                       --
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
use work.TG68040_MMU_Pack.all;

entity test_ATC is
end test_ATC;

architecture test of test_ATC is

    -- Component under test
    component TG68040_ATC is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            lookup_addr    : in std_logic_vector(31 downto 0);
            lookup_en      : in std_logic;
            lookup_hit     : out std_logic;
            lookup_entry   : out atc_entry_t;
            update_en      : in std_logic;
            update_logical : in std_logic_vector(31 downto 0);
            update_entry   : in atc_entry_t;
            invalidate_all : in std_logic;
            invalidate_entry : in std_logic;
            invalidate_addr  : in std_logic_vector(31 downto 0);
            lookups        : out std_logic_vector(31 downto 0);
            hits           : out std_logic_vector(31 downto 0);
            misses         : out std_logic_vector(31 downto 0);
            replacements   : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Signals
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal lookup_addr : std_logic_vector(31 downto 0);
    signal lookup_en : std_logic;
    signal lookup_hit : std_logic;
    signal lookup_entry : atc_entry_t;
    signal update_en : std_logic;
    signal update_logical : std_logic_vector(31 downto 0);
    signal update_entry : atc_entry_t;
    signal invalidate_all : std_logic;
    signal invalidate_entry : std_logic;
    signal invalidate_addr : std_logic_vector(31 downto 0);
    signal lookups : std_logic_vector(31 downto 0);
    signal hits : std_logic_vector(31 downto 0);
    signal misses : std_logic_vector(31 downto 0);
    signal replacements : std_logic_vector(31 downto 0);

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
    dut: TG68040_ATC
        port map(
            clk            => clk,
            reset          => reset,
            lookup_addr    => lookup_addr,
            lookup_en      => lookup_en,
            lookup_hit     => lookup_hit,
            lookup_entry   => lookup_entry,
            update_en      => update_en,
            update_logical => update_logical,
            update_entry   => update_entry,
            invalidate_all => invalidate_all,
            invalidate_entry => invalidate_entry,
            invalidate_addr  => invalidate_addr,
            lookups        => lookups,
            hits           => hits,
            misses         => misses,
            replacements   => replacements
        );

    -- Test stimulus
    test_proc: process
        variable test_entry : atc_entry_t;
    begin
        -- Test 1: Reset
        report "Test 1: Reset ATC";
        reset <= '1';
        lookup_en <= '0';
        update_en <= '0';
        invalidate_all <= '0';
        invalidate_entry <= '0';
        wait for CLK_PERIOD * 2;
        reset <= '0';
        wait for CLK_PERIOD;

        -- Test 2: Lookup miss (empty ATC)
        report "Test 2: Lookup miss on empty ATC";
        lookup_addr <= x"00001000";
        lookup_en <= '1';
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Expected miss on empty ATC" severity error;
        assert unsigned(misses) = 1 report "Miss count should be 1" severity error;
        lookup_en <= '0';
        wait for CLK_PERIOD;

        -- Test 3: Add entry to ATC
        report "Test 3: Add entry to ATC";
        update_logical <= x"00001000";
        test_entry := ATC_ENTRY_INIT;
        test_entry.valid := '1';
        test_entry.logical_tag := x"00001";  -- [31:12]
        test_entry.physical_frame := x"00005";  -- Translate to 0x5000
        test_entry.cache_mode := "01";  -- Copyback
        update_entry <= test_entry;
        update_en <= '1';
        wait for CLK_PERIOD;
        update_en <= '0';
        wait for CLK_PERIOD;

        -- Test 4: Lookup hit
        report "Test 4: Lookup hit after update";
        lookup_addr <= x"00001ABC";  -- Same page, different offset
        lookup_en <= '1';
        wait for CLK_PERIOD;
        assert lookup_hit = '1' report "Expected hit after update" severity error;
        assert lookup_entry.physical_frame = x"00005"
            report "Wrong physical frame" severity error;
        assert unsigned(hits) = 1 report "Hit count should be 1" severity error;
        lookup_en <= '0';
        wait for CLK_PERIOD;

        -- Test 5: Lookup miss (different page)
        report "Test 5: Lookup miss with different page";
        lookup_addr <= x"00002000";  -- Different page
        lookup_en <= '1';
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Expected miss with different page" severity error;
        assert unsigned(misses) = 2 report "Miss count should be 2" severity error;
        lookup_en <= '0';
        wait for CLK_PERIOD;

        -- Test 6: Add multiple entries
        report "Test 6: Add multiple entries";
        for i in 0 to 9 loop
            update_logical <= std_logic_vector(to_unsigned(16#10000# + i * 16#1000#, 32));
            test_entry.logical_tag := std_logic_vector(to_unsigned(16#10# + i, 20));
            test_entry.physical_frame := std_logic_vector(to_unsigned(16#20# + i, 20));
            update_entry <= test_entry;
            update_en <= '1';
            wait for CLK_PERIOD;
            update_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- Test 7: Verify all entries
        report "Test 7: Verify all stored entries";
        for i in 0 to 9 loop
            lookup_addr <= std_logic_vector(to_unsigned(16#10000# + i * 16#1000#, 32));
            lookup_en <= '1';
            wait for CLK_PERIOD;
            assert lookup_hit = '1'
                report "Expected hit for entry " & integer'image(i) severity error;
            assert lookup_entry.physical_frame =
                std_logic_vector(to_unsigned(16#20# + i, 20))
                report "Wrong physical frame for entry " & integer'image(i) severity error;
            lookup_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- Test 8: Invalidate specific entry
        report "Test 8: Invalidate specific entry";
        invalidate_addr <= x"00010000";  -- First entry
        invalidate_entry <= '1';
        wait for CLK_PERIOD;
        invalidate_entry <= '0';
        wait for CLK_PERIOD;

        lookup_addr <= x"00010000";
        lookup_en <= '1';
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "Entry should be invalidated" severity error;
        lookup_en <= '0';
        wait for CLK_PERIOD;

        -- Test 9: LRU replacement
        report "Test 9: LRU replacement (fill 64 entries)";
        -- Fill all 64 entries
        for i in 0 to 63 loop
            update_logical <= std_logic_vector(to_unsigned(16#100000# + i * 16#1000#, 32));
            test_entry.logical_tag := std_logic_vector(to_unsigned(16#100# + i, 20));
            test_entry.physical_frame := std_logic_vector(to_unsigned(16#200# + i, 20));
            update_entry <= test_entry;
            update_en <= '1';
            wait for CLK_PERIOD;
            update_en <= '0';
            wait for CLK_PERIOD;
        end loop;

        -- Add one more (should trigger replacement)
        update_logical <= x"00FF0000";
        test_entry.logical_tag := x"000FF";
        test_entry.physical_frame := x"002FF";
        update_entry <= test_entry;
        update_en <= '1';
        wait for CLK_PERIOD;
        update_en <= '0';
        wait for CLK_PERIOD;

        assert unsigned(replacements) > 0
            report "Should have at least one replacement" severity error;

        -- Test 10: Invalidate all
        report "Test 10: Invalidate all entries";
        invalidate_all <= '1';
        wait for CLK_PERIOD;
        invalidate_all <= '0';
        wait for CLK_PERIOD;

        -- Verify all entries are invalid
        lookup_addr <= x"00100000";
        lookup_en <= '1';
        wait for CLK_PERIOD;
        assert lookup_hit = '0' report "ATC should be empty after invalidate_all" severity error;
        lookup_en <= '0';
        wait for CLK_PERIOD;

        -- All tests complete
        report "All ATC tests passed!";
        test_done <= true;
        wait;
    end process;

end test;
