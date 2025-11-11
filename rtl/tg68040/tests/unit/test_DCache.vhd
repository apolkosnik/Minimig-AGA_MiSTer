------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_DCache                                               --
--                                                                          --
-- Tests the data cache stub implementation                                --
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

entity test_DCache is
end test_DCache;

architecture sim of test_DCache is

    -- Component declaration
    component TG68040_DCache is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            cache_enable   : in std_logic;
            cache_freeze   : in std_logic;
            cache_invalidate : in std_logic;
            cache_flush    : in std_logic;
            mem_req        : in std_logic;
            mem_write      : in std_logic;
            mem_size       : in std_logic_vector(1 downto 0);
            mem_addr       : in std_logic_vector(31 downto 0);
            mem_data_in    : in std_logic_vector(31 downto 0);
            mem_data_out   : out std_logic_vector(31 downto 0);
            mem_ready      : out std_logic;
            bus_req        : out std_logic;
            bus_write      : out std_logic;
            bus_addr       : out std_logic_vector(31 downto 0);
            bus_data_in    : out std_logic_vector(127 downto 0);
            bus_data_out   : in std_logic_vector(127 downto 0);
            bus_ready      : in std_logic;
            hit_count      : out std_logic_vector(31 downto 0);
            miss_count     : out std_logic_vector(31 downto 0);
            read_count     : out std_logic_vector(31 downto 0);
            write_count    : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal cache_enable   : std_logic := '1';
    signal cache_freeze   : std_logic := '0';
    signal cache_invalidate : std_logic := '0';
    signal cache_flush    : std_logic := '0';
    signal mem_req        : std_logic := '0';
    signal mem_write      : std_logic := '0';
    signal mem_size       : std_logic_vector(1 downto 0) := "10";  -- Longword
    signal mem_addr       : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_data_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_data_out   : std_logic_vector(31 downto 0);
    signal mem_ready      : std_logic;
    signal bus_req        : std_logic;
    signal bus_write      : std_logic;
    signal bus_addr       : std_logic_vector(31 downto 0);
    signal bus_data_in    : std_logic_vector(127 downto 0);
    signal bus_data_out   : std_logic_vector(127 downto 0) := (others => '0');
    signal bus_ready      : std_logic := '0';
    signal hit_count      : std_logic_vector(31 downto 0);
    signal miss_count     : std_logic_vector(31 downto 0);
    signal read_count     : std_logic_vector(31 downto 0);
    signal write_count    : std_logic_vector(31 downto 0);

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_DCache
        port map(
            clk            => clk,
            reset          => reset,
            cache_enable   => cache_enable,
            cache_freeze   => cache_freeze,
            cache_invalidate => cache_invalidate,
            cache_flush    => cache_flush,
            mem_req        => mem_req,
            mem_write      => mem_write,
            mem_size       => mem_size,
            mem_addr       => mem_addr,
            mem_data_in    => mem_data_in,
            mem_data_out   => mem_data_out,
            mem_ready      => mem_ready,
            bus_req        => bus_req,
            bus_write      => bus_write,
            bus_addr       => bus_addr,
            bus_data_in    => bus_data_in,
            bus_data_out   => bus_data_out,
            bus_ready      => bus_ready,
            hit_count      => hit_count,
            miss_count     => miss_count,
            read_count     => read_count,
            write_count    => write_count
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting D-Cache tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(mem_ready, '0', "Not ready after reset");
        assert_equal(hit_count, x"00000000", "Zero hits after reset");
        assert_equal(miss_count, x"00000000", "Zero misses after reset");
        assert_equal(read_count, x"00000000", "Zero reads after reset");
        assert_equal(write_count, x"00000000", "Zero writes after reset");
        assert_equal(bus_req, '0', "No bus request after reset");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 2: Write longword (always hit in stub)
        ----------------------------------------------------------------------
        report "--- Test 2: Write Longword (Always Hit) ---";

        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "10";  -- Longword
        mem_addr <= x"00001000";
        mem_data_in <= x"DEADBEEF";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD;

        assert_equal(mem_ready, '1', "Write ready after 1 cycle");
        assert_equal(hit_count, x"00000001", "One hit");
        assert_equal(miss_count, x"00000000", "Zero misses");
        assert_equal(write_count, x"00000001", "One write");
        assert_equal(read_count, x"00000000", "Zero reads");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 3: Read longword (verify write)
        ----------------------------------------------------------------------
        report "--- Test 3: Read Longword (Verify Write) ---";

        mem_req <= '1';
        mem_write <= '0';
        mem_size <= "10";  -- Longword
        mem_addr <= x"00001000";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD;

        assert_equal(mem_ready, '1', "Read ready after 1 cycle");
        assert_equal(mem_data_out, x"DEADBEEF", "Read back written data");
        assert_equal(hit_count, x"00000002", "Two hits");
        assert_equal(read_count, x"00000001", "One read");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 4: Write word (16-bit)
        ----------------------------------------------------------------------
        report "--- Test 4: Write Word (16-bit) ---";

        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "01";  -- Word
        mem_addr <= x"00002000";
        mem_data_in <= x"00001234";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD * 2;

        -- Read back
        mem_req <= '1';
        mem_write <= '0';
        mem_size <= "01";  -- Word
        mem_addr <= x"00002000";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD;

        assert_equal(mem_data_out, x"00001234", "Word written correctly");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 5: Write byte
        ----------------------------------------------------------------------
        report "--- Test 5: Write Byte ---";

        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00003000";
        mem_data_in <= x"000000AB";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD * 2;

        -- Read back
        mem_req <= '1';
        mem_write <= '0';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00003000";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD;

        assert_equal(mem_data_out, x"000000AB", "Byte written correctly");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 6: Read-after-write (different addresses)
        ----------------------------------------------------------------------
        report "--- Test 6: Read-After-Write (Different Addresses) ---";

        for i in 0 to 9 loop
            -- Write
            mem_req <= '1';
            mem_write <= '1';
            mem_size <= "10";
            mem_addr <= std_logic_vector(to_unsigned(i * 4, 32));
            mem_data_in <= std_logic_vector(to_unsigned(i + 100, 32));
            wait until rising_edge(clk);
            mem_req <= '0';
            wait for CLK_PERIOD;

            -- Read back
            mem_req <= '1';
            mem_write <= '0';
            mem_size <= "10";
            mem_addr <= std_logic_vector(to_unsigned(i * 4, 32));
            wait until rising_edge(clk);
            mem_req <= '0';
            wait for CLK_PERIOD;

            assert_equal(mem_data_out, std_logic_vector(to_unsigned(i + 100, 32)),
                        "Read-after-write " & integer'image(i));
        end loop;

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 7: Cache disabled
        ----------------------------------------------------------------------
        report "--- Test 7: Cache Disabled ---";

        cache_enable <= '0';
        mem_req <= '1';
        mem_write <= '0';
        mem_addr <= x"00004000";
        wait until rising_edge(clk);
        mem_req <= '0';

        wait for CLK_PERIOD * 2;

        assert_equal(mem_ready, '0', "No ready when cache disabled");

        -- Re-enable cache
        cache_enable <= '1';
        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 8: Cache invalidate
        ----------------------------------------------------------------------
        report "--- Test 8: Cache Invalidate ---";

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
        assert_equal(read_count, x"00000000", "Reads reset after invalidate");
        assert_equal(write_count, x"00000000", "Writes reset after invalidate");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 9: Cache flush (no-op in stub)
        ----------------------------------------------------------------------
        report "--- Test 9: Cache Flush (No-op in Stub) ---";

        cache_flush <= '1';
        wait until rising_edge(clk);
        cache_flush <= '0';

        wait for CLK_PERIOD * 2;

        -- Flush is a no-op in stub (real cache writes back dirty lines)
        -- Just verify interface works

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 10: Hit rate (should be 100% in stub)
        ----------------------------------------------------------------------
        report "--- Test 10: Hit Rate Verification ---";

        -- Do several reads
        for i in 0 to 19 loop
            mem_req <= '1';
            mem_write <= '0';
            mem_addr <= std_logic_vector(to_unsigned(i * 4, 32));
            wait until rising_edge(clk);
            mem_req <= '0';
            wait for CLK_PERIOD;
        end loop;

        assert_equal(miss_count, x"00000000", "Still zero misses");
        report "Hit rate: 100% (stub always hits)";
        report "Total reads: " & integer'image(to_integer(unsigned(read_count)));
        report "Total writes: " & integer'image(to_integer(unsigned(write_count)));
        report "Total hits: " & integer'image(to_integer(unsigned(hit_count)));
        report "Total misses: " & integer'image(to_integer(unsigned(miss_count)));

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 11: Bus interface (unused in stub)
        ----------------------------------------------------------------------
        report "--- Test 11: Bus Interface (Unused in Stub) ---";

        -- Bus request should always be '0' in stub (always hit)
        assert_equal(bus_req, '0', "No bus requests in stub");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- Test 12: Byte alignment
        ----------------------------------------------------------------------
        report "--- Test 12: Byte Alignment ---";

        -- Write to byte offset 0
        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00005000";
        mem_data_in <= x"000000AA";
        wait until rising_edge(clk);
        mem_req <= '0';
        wait for CLK_PERIOD;

        -- Write to byte offset 1
        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00005001";
        mem_data_in <= x"000000BB";
        wait until rising_edge(clk);
        mem_req <= '0';
        wait for CLK_PERIOD;

        -- Write to byte offset 2
        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00005002";
        mem_data_in <= x"000000CC";
        wait until rising_edge(clk);
        mem_req <= '0';
        wait for CLK_PERIOD;

        -- Write to byte offset 3
        mem_req <= '1';
        mem_write <= '1';
        mem_size <= "00";  -- Byte
        mem_addr <= x"00005003";
        mem_data_in <= x"000000DD";
        wait until rising_edge(clk);
        mem_req <= '0';
        wait for CLK_PERIOD;

        -- Read back as longword
        mem_req <= '1';
        mem_write <= '0';
        mem_size <= "10";  -- Longword
        mem_addr <= x"00005000";
        wait until rising_edge(clk);
        mem_req <= '0';
        wait for CLK_PERIOD;

        assert_equal(mem_data_out, x"DDCCBBAA", "Byte alignment correct");

        wait for CLK_PERIOD * 2;

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All D-Cache tests completed successfully ===";
        report "Final statistics:";
        report "  Hits: " & integer'image(to_integer(unsigned(hit_count)));
        report "  Misses: " & integer'image(to_integer(unsigned(miss_count)));
        report "  Reads: " & integer'image(to_integer(unsigned(read_count)));
        report "  Writes: " & integer'image(to_integer(unsigned(write_count)));
        report "  Hit Rate: 100% (stub)";

        test_done <= true;
        wait;

    end process;

end sim;
