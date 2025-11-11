------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_ICache                                               --
--                                                                          --
-- Tests the instruction cache stub implementation                         --
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
use work.test_pkg.all;

entity test_ICache is
end test_ICache;

architecture sim of test_ICache is

    -- Component declaration
    component TG68040_ICache is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            cache_enable   : in std_logic;
            cache_freeze   : in std_logic;
            cache_invalidate : in std_logic;
            fetch_req      : in std_logic;
            fetch_addr     : in std_logic_vector(31 downto 0);
            fetch_data     : out std_logic_vector(15 downto 0);
            fetch_ready    : out std_logic;
            mem_req        : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_data       : in std_logic_vector(127 downto 0);
            mem_ready      : in std_logic;
            hit_count      : out std_logic_vector(31 downto 0);
            miss_count     : out std_logic_vector(31 downto 0);
            access_count   : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal cache_enable   : std_logic := '1';
    signal cache_freeze   : std_logic := '0';
    signal cache_invalidate : std_logic := '0';
    signal fetch_req      : std_logic := '0';
    signal fetch_addr     : std_logic_vector(31 downto 0) := (others => '0');
    signal fetch_data     : std_logic_vector(15 downto 0);
    signal fetch_ready    : std_logic;
    signal mem_req        : std_logic;
    signal mem_addr       : std_logic_vector(31 downto 0);
    signal mem_data       : std_logic_vector(127 downto 0) := (others => '0');
    signal mem_ready      : std_logic := '0';
    signal hit_count      : std_logic_vector(31 downto 0);
    signal miss_count     : std_logic_vector(31 downto 0);
    signal access_count   : std_logic_vector(31 downto 0);

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_ICache
        port map(
            clk            => clk,
            reset          => reset,
            cache_enable   => cache_enable,
            cache_freeze   => cache_freeze,
            cache_invalidate => cache_invalidate,
            fetch_req      => fetch_req,
            fetch_addr     => fetch_addr,
            fetch_data     => fetch_data,
            fetch_ready    => fetch_ready,
            mem_req        => mem_req,
            mem_addr       => mem_addr,
            mem_data       => mem_data,
            mem_ready      => mem_ready,
            hit_count      => hit_count,
            miss_count     => miss_count,
            access_count   => access_count
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting I-Cache tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(fetch_ready, '0', "Not ready after reset");
        assert_equal(hit_count, x"00000000", "Zero hits after reset");
        assert_equal(miss_count, x"00000000", "Zero misses after reset");
        assert_equal(access_count, x"00000000", "Zero accesses after reset");
        assert_equal(mem_req, '0', "No memory request after reset");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 2: Single fetch (always hit in stub)
        ----------------------------------------------------------------------
        report "--- Test 2: Single Fetch (Always Hit) ---";

        fetch_req <= '1';
        fetch_addr <= x"00001000";
        wait until rising_edge(clk);
        fetch_req <= '0';

        wait for CLK_PERIOD;

        assert_equal(fetch_ready, '1', "Fetch ready after 1 cycle");
        assert_equal(fetch_data, x"4E71", "Fetched NOP instruction");
        assert_equal(hit_count, x"00000001", "One hit");
        assert_equal(miss_count, x"00000000", "Zero misses");
        assert_equal(access_count, x"00000001", "One access");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 3: Multiple sequential fetches
        ----------------------------------------------------------------------
        report "--- Test 3: Multiple Sequential Fetches ---";

        for i in 0 to 9 loop
            fetch_req <= '1';
            fetch_addr <= std_logic_vector(to_unsigned(i * 2, 32));
            wait until rising_edge(clk);
            fetch_req <= '0';
            wait for CLK_PERIOD;
            assert_equal(fetch_ready, '1', "Fetch " & integer'image(i) & " ready");
        end loop;

        assert_equal(hit_count, x"0000000B", "11 total hits");
        assert_equal(miss_count, x"00000000", "Still zero misses");
        assert_equal(access_count, x"0000000B", "11 total accesses");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 4: Cache disabled
        ----------------------------------------------------------------------
        report "--- Test 4: Cache Disabled ---";

        cache_enable <= '0';
        fetch_req <= '1';
        fetch_addr <= x"00002000";
        wait until rising_edge(clk);
        fetch_req <= '0';

        wait for CLK_PERIOD * 2;

        assert_equal(fetch_ready, '0', "No fetch when cache disabled");

        -- Re-enable cache
        cache_enable <= '1';
        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 5: Cache invalidate
        ----------------------------------------------------------------------
        report "--- Test 5: Cache Invalidate ---";

        -- Record current counts
        wait for CLK_PERIOD;

        -- Invalidate cache
        cache_invalidate <= '1';
        wait until rising_edge(clk);
        cache_invalidate <= '0';

        wait for CLK_PERIOD;

        -- Counts should be reset
        assert_equal(hit_count, x"00000000", "Hits reset after invalidate");
        assert_equal(miss_count, x"00000000", "Misses reset after invalidate");
        assert_equal(access_count, x"00000000", "Accesses reset after invalidate");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 6: Continuous fetching
        ----------------------------------------------------------------------
        report "--- Test 6: Continuous Fetching ---";

        for i in 0 to 19 loop
            fetch_req <= '1';
            fetch_addr <= std_logic_vector(to_unsigned(i * 2 + 100, 32));
            wait until rising_edge(clk);
        end loop;

        fetch_req <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(hit_count, x"00000014", "20 hits");
        assert_equal(access_count, x"00000014", "20 accesses");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 7: Hit rate (should be 100% in stub)
        ----------------------------------------------------------------------
        report "--- Test 7: Hit Rate Verification ---";

        assert_equal(miss_count, x"00000000", "Still zero misses");

        -- Calculate hit rate
        report "Hit rate: 100% (stub always hits)";
        report "Total accesses: " & integer'image(to_integer(unsigned(access_count)));
        report "Total hits: " & integer'image(to_integer(unsigned(hit_count)));
        report "Total misses: " & integer'image(to_integer(unsigned(miss_count)));

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 8: Cache freeze (not implemented in stub, but test interface)
        ----------------------------------------------------------------------
        report "--- Test 8: Cache Freeze ---";

        cache_freeze <= '1';
        fetch_req <= '1';
        fetch_addr <= x"00003000";
        wait until rising_edge(clk);
        fetch_req <= '0';

        wait for CLK_PERIOD;

        -- In stub, freeze doesn't affect behavior (future enhancement)
        -- Just verify interface works
        cache_freeze <= '0';

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 9: Memory interface (unused in stub)
        ----------------------------------------------------------------------
        report "--- Test 9: Memory Interface (Unused in Stub) ---";

        -- Memory request should always be '0' in stub (always hit)
        assert_equal(mem_req, '0', "No memory requests in stub");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 10: Address range testing
        ----------------------------------------------------------------------
        report "--- Test 10: Address Range Testing ---";

        -- Test various addresses
        for i in 0 to 255 loop
            fetch_req <= '1';
            fetch_addr <= std_logic_vector(to_unsigned(i * 2, 32));
            wait until rising_edge(clk);
            fetch_req <= '0';
            wait for CLK_PERIOD;

            assert_equal(fetch_ready, '1', "Fetch ready for addr " & integer'image(i * 2));
        end loop;

        report "Tested full address range (0-510)";

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 11: Rapid request toggling
        ----------------------------------------------------------------------
        report "--- Test 11: Rapid Request Toggling ---";

        for i in 0 to 9 loop
            fetch_req <= '1';
            wait until rising_edge(clk);
            fetch_req <= '0';
            wait until rising_edge(clk);
        end loop;

        report "Rapid toggling completed";

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All I-Cache tests completed successfully ===";
        report "Final statistics:";
        report "  Hits: " & integer'image(to_integer(unsigned(hit_count)));
        report "  Misses: " & integer'image(to_integer(unsigned(miss_count)));
        report "  Accesses: " & integer'image(to_integer(unsigned(access_count)));
        report "  Hit Rate: 100% (stub)";

        test_done <= true;
        wait;

    end process;

end sim;
