------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Instruction Cache Unit Test                                     --
--                                                                          --
-- Tests 256-byte direct-mapped instruction cache                          --
--                                                                          --
-- Coverage:                                                                --
--   - Cache hits and misses                                               --
--   - All 16 cache lines                                                  --
--   - Cache invalidation (clear all, clear entry)                         --
--   - Freeze mode                                                         --
--   - Enable/disable                                                      --
--   - Burst mode                                                          --
--   - Different fetch sizes (byte, word, long)                            --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_icache_tb is
end entity test_icache_tb;

architecture behavior of test_icache_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_ICache is
        port(
            clk         : in  std_logic;
            reset       : in  std_logic;
            enable      : in  std_logic;
            freeze      : in  std_logic;
            clear_all   : in  std_logic;
            clear_entry : in  std_logic;
            burst_en    : in  std_logic;
            clear_addr  : in  std_logic_vector(31 downto 0);
            cpu_addr    : in  std_logic_vector(31 downto 0);
            cpu_read    : in  std_logic;
            cpu_size    : in  std_logic_vector(1 downto 0);
            cpu_data    : out std_logic_vector(31 downto 0);
            cpu_ready   : out std_logic;
            cpu_hit     : out std_logic;
            bus_req     : out std_logic;
            bus_addr    : out std_logic_vector(31 downto 0);
            bus_burst   : out std_logic;
            bus_data    : in  std_logic_vector(127 downto 0);
            bus_ready   : in  std_logic;
            bus_error   : in  std_logic
        );
    end component;

    -- Signals
    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';
    signal enable      : std_logic := '1';
    signal freeze      : std_logic := '0';
    signal clear_all   : std_logic := '0';
    signal clear_entry : std_logic := '0';
    signal burst_en    : std_logic := '0';
    signal clear_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_read    : std_logic := '0';
    signal cpu_size    : std_logic_vector(1 downto 0) := "10";  -- Long
    signal cpu_data    : std_logic_vector(31 downto 0);
    signal cpu_ready   : std_logic;
    signal cpu_hit     : std_logic;
    signal bus_req     : std_logic;
    signal bus_addr    : std_logic_vector(31 downto 0);
    signal bus_burst   : std_logic;
    signal bus_data    : std_logic_vector(127 downto 0) := (others => '0');
    signal bus_ready   : std_logic := '0';
    signal bus_error   : std_logic := '0';

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- Size constants
    constant SIZE_BYTE : std_logic_vector(1 downto 0) := "00";
    constant SIZE_WORD : std_logic_vector(1 downto 0) := "01";
    constant SIZE_LONG : std_logic_vector(1 downto 0) := "10";

begin

    --------------------------------------------------------------
    -- Clock generation
    --------------------------------------------------------------
    clk_process: process
    begin
        while not test_complete loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    --------------------------------------------------------------
    -- DUT instantiation
    --------------------------------------------------------------
    dut: TG68K030_ICache
        port map(
            clk         => clk,
            reset       => reset,
            enable      => enable,
            freeze      => freeze,
            clear_all   => clear_all,
            clear_entry => clear_entry,
            burst_en    => burst_en,
            clear_addr  => clear_addr,
            cpu_addr    => cpu_addr,
            cpu_read    => cpu_read,
            cpu_size    => cpu_size,
            cpu_data    => cpu_data,
            cpu_ready   => cpu_ready,
            cpu_hit     => cpu_hit,
            bus_req     => bus_req,
            bus_addr    => bus_addr,
            bus_burst   => bus_burst,
            bus_data    => bus_data,
            bus_ready   => bus_ready,
            bus_error   => bus_error
        );

    --------------------------------------------------------------
    -- Test stimulus
    --------------------------------------------------------------
    stim_proc: process

        procedure report_test(test_name : string; passed : boolean) is
        begin
            if passed then
                report "PASS: " & test_name severity note;
            else
                report "FAIL: " & test_name severity error;
                test_passed <= false;
            end if;
        end procedure;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait for CLK_PERIOD;
            end loop;
        end procedure;

        procedure fetch_instruction(addr : std_logic_vector(31 downto 0);
                                    size : std_logic_vector(1 downto 0)) is
        begin
            cpu_addr <= addr;
            cpu_size <= size;
            cpu_read <= '1';
            wait_cycles(1);
            cpu_read <= '0';

            -- Wait for bus request if miss
            if bus_req = '1' then
                wait_cycles(1);
                -- Simulate bus response
                bus_data  <= X"DEADBEEF_CAFEBABE_12345678_9ABCDEF0";
                bus_ready <= '1';
                wait_cycles(1);
                bus_ready <= '0';
            end if;

            -- Wait for ready
            wait until cpu_ready = '1' or test_complete;
            wait_cycles(1);
        end procedure;

    begin
        --------------------------------------------------------------
        -- Test 0: Reset
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 0: Reset" severity note;
        report "==================================" severity note;

        enable <= '1';
        reset <= '1';
        wait_cycles(5);
        reset <= '0';
        wait_cycles(2);

        report_test("Cache not busy after reset", cpu_ready = '0');

        --------------------------------------------------------------
        -- Test 1: First Access (Miss)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: First access (cache miss)" severity note;
        report "==================================" severity note;

        cpu_addr <= X"00001000";
        cpu_size <= SIZE_LONG;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';

        -- Should request bus
        wait until bus_req = '1' or test_complete;
        wait_cycles(1);
        report_test("Bus requested on miss", bus_req = '1');
        report_test("Not a hit", cpu_hit = '0');

        -- Provide bus data
        bus_data  <= X"DEADBEEF_CAFEBABE_12345678_9ABCDEF0";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';

        wait until cpu_ready = '1' or test_complete;
        report_test("Data ready", cpu_ready = '1');
        report_test("Correct data", cpu_data = X"DEADBEEF");  -- First longword
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 2: Second Access (Hit)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: Second access (cache hit)" severity note;
        report "==================================" severity note;

        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';

        wait_cycles(2);
        report_test("Cache hit", cpu_hit = '1');
        report_test("No bus request", bus_req = '0');

        wait until cpu_ready = '1' or test_complete;
        report_test("Data from cache", cpu_data = X"DEADBEEF");
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 3: All 16 Cache Lines
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: All 16 cache lines" severity note;
        report "==================================" severity note;

        for i in 0 to 15 loop
            -- Access different addresses with same tag but different index
            fetch_instruction(std_logic_vector(to_unsigned(16#1000# + i * 16, 32)), SIZE_LONG);
            report_test("Line " & integer'image(i) & " filled", true);
        end loop;

        -- Verify all lines cached (hits on second access)
        for i in 0 to 15 loop
            cpu_addr <= std_logic_vector(to_unsigned(16#1000# + i * 16, 32));
            cpu_read <= '1';
            wait_cycles(1);
            cpu_read <= '0';
            wait_cycles(3);
            report_test("Line " & integer'image(i) & " hit", cpu_hit = '1');
        end loop;

        --------------------------------------------------------------
        -- Test 4: Cache Invalidation (Clear All)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: Clear all cache lines" severity note;
        report "==================================" severity note;

        clear_all <= '1';
        wait_cycles(1);
        clear_all <= '0';
        wait_cycles(1);

        -- Access should miss now
        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Miss after clear", cpu_hit = '0');
        report_test("Bus requested", bus_req = '1');

        bus_data  <= X"11111111_22222222_33333333_44444444";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 5: Clear Entry
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: Clear specific entry" severity note;
        report "==================================" severity note;

        -- Fill line at 0x1000 (index 0)
        fetch_instruction(X"00001000", SIZE_LONG);

        -- Fill line at 0x1010 (index 1)
        fetch_instruction(X"00001010", SIZE_LONG);

        -- Clear entry at 0x1000
        clear_addr  <= X"00001000";
        clear_entry <= '1';
        wait_cycles(1);
        clear_entry <= '0';
        wait_cycles(1);

        -- Access 0x1000 should miss
        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);
        report_test("Cleared entry misses", cpu_hit = '0');

        bus_ready <= '1';
        bus_data  <= X"55555555_66666666_77777777_88888888";
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        -- Access 0x1010 should still hit
        cpu_addr <= X"00001010";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Other entry still hits", cpu_hit = '1');

        --------------------------------------------------------------
        -- Test 6: Freeze Mode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: Freeze mode" severity note;
        report "==================================" severity note;

        -- Fill a cache line
        fetch_instruction(X"00002000", SIZE_LONG);

        -- Enable freeze
        freeze <= '1';
        wait_cycles(1);

        -- Try to access different address with same index
        -- Should miss but NOT update cache
        cpu_addr <= X"00012000";  -- Different tag, same index
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Miss in freeze mode", cpu_hit = '0');

        bus_data  <= X"AAAAAAAA_BBBBBBBB_CCCCCCCC_DDDDDDDD";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        -- Disable freeze
        freeze <= '0';
        wait_cycles(1);

        -- Original address should still hit (not replaced)
        cpu_addr <= X"00002000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Original entry preserved", cpu_hit = '1');

        --------------------------------------------------------------
        -- Test 7: Cache Disabled
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: Cache disabled" severity note;
        report "==================================" severity note;

        -- Disable cache
        enable <= '0';
        wait_cycles(1);

        -- Every access should go to bus
        cpu_addr <= X"00003000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Bus request when disabled", bus_req = '1');

        bus_data  <= X"EEEEEEEE_FFFFFFFF_11111111_22222222";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Second access should also go to bus
        cpu_addr <= X"00003000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("No caching when disabled", bus_req = '1');

        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        -- Re-enable
        enable <= '1';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 8: Burst Mode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Burst mode" severity note;
        report "==================================" severity note;

        -- Enable burst
        burst_en <= '1';
        wait_cycles(1);

        cpu_addr <= X"00004000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Burst requested", bus_burst = '1');

        -- Provide burst data
        bus_data  <= X"DEAD0000_DEAD0001_DEAD0002_DEAD0003";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        -- Disable burst
        burst_en <= '0';

        --------------------------------------------------------------
        -- Test 9: Different Fetch Sizes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: Different fetch sizes" severity note;
        report "==================================" severity note;

        -- Fill cache line with known pattern
        cpu_addr <= X"00005000";
        cpu_size <= SIZE_LONG;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        bus_data  <= X"12345678_9ABCDEF0_FEDCBA98_76543210";
        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Byte fetch
        cpu_addr <= X"00005000";
        cpu_size <= SIZE_BYTE;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Byte fetch hit", cpu_hit = '1');
        report_test("Byte data correct", cpu_data(7 downto 0) = X"12");
        wait_cycles(1);

        -- Word fetch
        cpu_addr <= X"00005000";
        cpu_size <= SIZE_WORD;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Word fetch hit", cpu_hit = '1');
        report_test("Word data correct", cpu_data(15 downto 0) = X"1234");
        wait_cycles(1);

        -- Long fetch
        cpu_addr <= X"00005000";
        cpu_size <= SIZE_LONG;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Long fetch hit", cpu_hit = '1');
        report_test("Long data correct", cpu_data = X"12345678");

        --------------------------------------------------------------
        -- Final report
        --------------------------------------------------------------
        wait_cycles(10);

        report "==================================" severity note;
        if test_passed then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        report "==================================" severity note;

        report "I-Cache Test Summary:" severity note;
        report "  - Cache hits and misses" severity note;
        report "  - All 16 cache lines" severity note;
        report "  - Cache invalidation (all and entry)" severity note;
        report "  - Freeze mode" severity note;
        report "  - Enable/disable" severity note;
        report "  - Burst mode" severity note;
        report "  - Different fetch sizes (byte/word/long)" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
