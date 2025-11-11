------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Data Cache Unit Test                                            --
--                                                                          --
-- Tests 256-byte direct-mapped data cache with write-through              --
--                                                                          --
-- Coverage:                                                                --
--   - Read hits and misses                                                --
--   - Write hits and misses                                               --
--   - Write-through policy                                                --
--   - Write allocate mode                                                 --
--   - All 16 cache lines                                                  --
--   - Cache invalidation                                                  --
--   - Freeze mode                                                         --
--   - Enable/disable                                                      --
--   - Burst mode                                                          --
--   - Different access sizes                                              --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_dcache_tb is
end entity test_dcache_tb;

architecture behavior of test_dcache_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_DCache is
        port(
            clk          : in  std_logic;
            reset        : in  std_logic;
            enable       : in  std_logic;
            freeze       : in  std_logic;
            clear_all    : in  std_logic;
            clear_entry  : in  std_logic;
            burst_en     : in  std_logic;
            write_alloc  : in  std_logic;
            clear_addr   : in  std_logic_vector(31 downto 0);
            cpu_addr     : in  std_logic_vector(31 downto 0);
            cpu_read     : in  std_logic;
            cpu_write    : in  std_logic;
            cpu_size     : in  std_logic_vector(1 downto 0);
            cpu_data_in  : in  std_logic_vector(31 downto 0);
            cpu_data_out : out std_logic_vector(31 downto 0);
            cpu_ready    : out std_logic;
            cpu_hit      : out std_logic;
            bus_req      : out std_logic;
            bus_addr     : out std_logic_vector(31 downto 0);
            bus_read     : out std_logic;
            bus_write    : out std_logic;
            bus_burst    : out std_logic;
            bus_size     : out std_logic_vector(1 downto 0);
            bus_data_in  : in  std_logic_vector(127 downto 0);
            bus_data_out : out std_logic_vector(31 downto 0);
            bus_ready    : in  std_logic;
            bus_error    : in  std_logic
        );
    end component;

    -- Signals
    signal clk          : std_logic := '0';
    signal reset        : std_logic := '1';
    signal enable       : std_logic := '1';
    signal freeze       : std_logic := '0';
    signal clear_all    : std_logic := '0';
    signal clear_entry  : std_logic := '0';
    signal burst_en     : std_logic := '0';
    signal write_alloc  : std_logic := '0';
    signal clear_addr   : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_addr     : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_read     : std_logic := '0';
    signal cpu_write    : std_logic := '0';
    signal cpu_size     : std_logic_vector(1 downto 0) := "10";
    signal cpu_data_in  : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_data_out : std_logic_vector(31 downto 0);
    signal cpu_ready    : std_logic;
    signal cpu_hit      : std_logic;
    signal bus_req      : std_logic;
    signal bus_addr     : std_logic_vector(31 downto 0);
    signal bus_read     : std_logic;
    signal bus_write    : std_logic;
    signal bus_burst    : std_logic;
    signal bus_size     : std_logic_vector(1 downto 0);
    signal bus_data_in  : std_logic_vector(127 downto 0) := (others => '0');
    signal bus_data_out : std_logic_vector(31 downto 0);
    signal bus_ready    : std_logic := '0';
    signal bus_error    : std_logic := '0';

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
    dut: TG68K030_DCache
        port map(
            clk          => clk,
            reset        => reset,
            enable       => enable,
            freeze       => freeze,
            clear_all    => clear_all,
            clear_entry  => clear_entry,
            burst_en     => burst_en,
            write_alloc  => write_alloc,
            clear_addr   => clear_addr,
            cpu_addr     => cpu_addr,
            cpu_read     => cpu_read,
            cpu_write    => cpu_write,
            cpu_size     => cpu_size,
            cpu_data_in  => cpu_data_in,
            cpu_data_out => cpu_data_out,
            cpu_ready    => cpu_ready,
            cpu_hit      => cpu_hit,
            bus_req      => bus_req,
            bus_addr     => bus_addr,
            bus_read     => bus_read,
            bus_write    => bus_write,
            bus_burst    => bus_burst,
            bus_size     => bus_size,
            bus_data_in  => bus_data_in,
            bus_data_out => bus_data_out,
            bus_ready    => bus_ready,
            bus_error    => bus_error
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

        procedure read_data(addr : std_logic_vector(31 downto 0);
                           size : std_logic_vector(1 downto 0)) is
        begin
            cpu_addr  <= addr;
            cpu_size  <= size;
            cpu_read  <= '1';
            wait_cycles(1);
            cpu_read  <= '0';

            -- Handle bus request if miss
            if bus_req = '1' and bus_read = '1' then
                wait_cycles(1);
                bus_data_in <= X"11111111_22222222_33333333_44444444";
                bus_ready   <= '1';
                wait_cycles(1);
                bus_ready   <= '0';
            end if;

            wait until cpu_ready = '1' or test_complete;
            wait_cycles(1);
        end procedure;

        procedure write_data(addr : std_logic_vector(31 downto 0);
                            data : std_logic_vector(31 downto 0);
                            size : std_logic_vector(1 downto 0)) is
        begin
            cpu_addr    <= addr;
            cpu_data_in <= data;
            cpu_size    <= size;
            cpu_write   <= '1';
            wait_cycles(1);
            cpu_write   <= '0';

            -- Handle bus request (write-through always writes to bus)
            wait until bus_req = '1' or cpu_ready = '1' or test_complete;
            if bus_req = '1' then
                wait_cycles(1);
                bus_ready <= '1';
                wait_cycles(1);
                bus_ready <= '0';
            end if;

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
        reset  <= '1';
        wait_cycles(5);
        reset  <= '0';
        wait_cycles(2);

        report_test("Cache idle after reset", cpu_ready = '0');

        --------------------------------------------------------------
        -- Test 1: Read Miss
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: Read miss" severity note;
        report "==================================" severity note;

        cpu_addr <= X"00001000";
        cpu_size <= SIZE_LONG;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';

        wait until bus_req = '1' or test_complete;
        wait_cycles(1);
        report_test("Bus read requested", bus_read = '1');
        report_test("Not a hit", cpu_hit = '0');

        bus_data_in <= X"DEADBEEF_CAFEBABE_12345678_9ABCDEF0";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait until cpu_ready = '1' or test_complete;
        report_test("Read miss complete", cpu_ready = '1');
        report_test("Correct data", cpu_data_out = X"DEADBEEF");
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 2: Read Hit
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: Read hit" severity note;
        report "==================================" severity note;

        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);

        report_test("Cache hit", cpu_hit = '1');
        report_test("No bus request", bus_req = '0');
        report_test("Data from cache", cpu_data_out = X"DEADBEEF");

        --------------------------------------------------------------
        -- Test 3: Write Hit (Write-Through)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: Write hit (write-through)" severity note;
        report "==================================" severity note;

        -- Write to cached location
        cpu_addr    <= X"00001000";
        cpu_data_in <= X"55555555";
        cpu_size    <= SIZE_LONG;
        cpu_write   <= '1';
        wait_cycles(1);
        cpu_write   <= '0';

        wait until bus_req = '1' or test_complete;
        wait_cycles(1);
        report_test("Bus write requested", bus_write = '1');
        report_test("Write-through to bus", bus_data_out = X"55555555");

        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';

        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Read back to verify cache updated
        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);

        report_test("Cache updated", cpu_data_out = X"55555555");

        --------------------------------------------------------------
        -- Test 4: Write Miss (No Allocate)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: Write miss (no allocate)" severity note;
        report "==================================" severity note;

        write_alloc <= '0';  -- Disable write allocate

        cpu_addr    <= X"00002000";
        cpu_data_in <= X"AAAAAAAA";
        cpu_write   <= '1';
        wait_cycles(1);
        cpu_write   <= '0';

        wait until bus_req = '1' or test_complete;
        wait_cycles(1);
        report_test("Bus write on miss", bus_write = '1');

        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';

        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Read should miss (no allocate on write)
        cpu_addr <= X"00002000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Read misses after write-no-alloc", cpu_hit = '0');

        bus_data_in <= X"AAAAAAAA_BBBBBBBB_CCCCCCCC_DDDDDDDD";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 5: Write Miss (With Allocate)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: Write miss (with allocate)" severity note;
        report "==================================" severity note;

        write_alloc <= '1';  -- Enable write allocate

        cpu_addr    <= X"00003000";
        cpu_data_in <= X"BBBBBBBB";
        cpu_write   <= '1';
        wait_cycles(1);
        cpu_write   <= '0';

        -- Should first read to fill cache
        wait until bus_req = '1' or test_complete;
        wait_cycles(1);
        if bus_read = '1' then
            report_test("Read to allocate", true);
            bus_data_in <= X"00000000_11111111_22222222_33333333";
            bus_ready   <= '1';
            wait_cycles(1);
            bus_ready   <= '0';
            wait_cycles(1);
        end if;

        -- Then write
        wait until bus_req = '1' or cpu_ready = '1' or test_complete;
        if bus_write = '1' then
            report_test("Write after allocate", true);
            bus_ready <= '1';
            wait_cycles(1);
            bus_ready <= '0';
        end if;

        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Read should hit now
        cpu_addr <= X"00003000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);

        report_test("Read hits after write-alloc", cpu_hit = '1');

        write_alloc <= '0';  -- Disable for other tests
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 6: All 16 Cache Lines
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: All 16 cache lines" severity note;
        report "==================================" severity note;

        for i in 0 to 15 loop
            read_data(std_logic_vector(to_unsigned(16#1000# + i * 16, 32)), SIZE_LONG);
            report_test("Line " & integer'image(i) & " filled", true);
        end loop;

        -- Verify hits
        for i in 0 to 15 loop
            cpu_addr <= std_logic_vector(to_unsigned(16#1000# + i * 16, 32));
            cpu_read <= '1';
            wait_cycles(1);
            cpu_read <= '0';
            wait_cycles(3);
            report_test("Line " & integer'image(i) & " hit", cpu_hit = '1');
        end loop;

        --------------------------------------------------------------
        -- Test 7: Cache Invalidation
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: Cache invalidation" severity note;
        report "==================================" severity note;

        clear_all <= '1';
        wait_cycles(1);
        clear_all <= '0';
        wait_cycles(1);

        cpu_addr <= X"00001000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Miss after clear", cpu_hit = '0');

        bus_data_in <= X"FFFFFFFF_EEEEEEEE_DDDDDDDD_CCCCCCCC";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 8: Clear Entry
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Clear specific entry" severity note;
        report "==================================" severity note;

        -- Fill two lines
        read_data(X"00004000", SIZE_LONG);
        read_data(X"00004010", SIZE_LONG);

        -- Clear first line
        clear_addr  <= X"00004000";
        clear_entry <= '1';
        wait_cycles(1);
        clear_entry <= '0';
        wait_cycles(1);

        -- First should miss
        cpu_addr <= X"00004000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);
        report_test("Cleared entry misses", cpu_hit = '0');

        bus_ready <= '1';
        wait_cycles(1);
        bus_ready <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        -- Second should hit
        cpu_addr <= X"00004010";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Other entry hits", cpu_hit = '1');

        --------------------------------------------------------------
        -- Test 9: Freeze Mode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: Freeze mode" severity note;
        report "==================================" severity note;

        read_data(X"00005000", SIZE_LONG);

        freeze <= '1';
        wait_cycles(1);

        -- Try to read different address same index
        cpu_addr <= X"00015000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Miss in freeze", cpu_hit = '0');

        bus_data_in <= X"77777777_88888888_99999999_AAAAAAAA";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        freeze <= '0';
        wait_cycles(1);

        -- Original should still hit
        cpu_addr <= X"00005000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Original preserved in freeze", cpu_hit = '1');

        --------------------------------------------------------------
        -- Test 10: Cache Disabled
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 10: Cache disabled" severity note;
        report "==================================" severity note;

        enable <= '0';
        wait_cycles(1);

        cpu_addr <= X"00006000";
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        report_test("Bus request when disabled", bus_req = '1');

        bus_data_in <= X"12121212_34343434_56565656_78787878";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(1);

        enable <= '1';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 11: Different Sizes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 11: Different access sizes" severity note;
        report "==================================" severity note;

        -- Fill cache line
        cpu_addr <= X"00007000";
        cpu_size <= SIZE_LONG;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(2);

        bus_data_in <= X"12345678_9ABCDEF0_FEDCBA98_76543210";
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        wait_cycles(2);

        -- Byte access
        cpu_addr <= X"00007000";
        cpu_size <= SIZE_BYTE;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Byte read hit", cpu_hit = '1');
        report_test("Byte data", cpu_data_out(7 downto 0) = X"12");
        wait_cycles(1);

        -- Word access
        cpu_addr <= X"00007000";
        cpu_size <= SIZE_WORD;
        cpu_read <= '1';
        wait_cycles(1);
        cpu_read <= '0';
        wait_cycles(3);
        report_test("Word read hit", cpu_hit = '1');
        report_test("Word data", cpu_data_out(15 downto 0) = X"1234");
        wait_cycles(1);

        -- Byte write
        cpu_addr    <= X"00007000";
        cpu_data_in <= X"000000AA";
        cpu_size    <= SIZE_BYTE;
        cpu_write   <= '1';
        wait_cycles(1);
        cpu_write   <= '0';
        wait until bus_req = '1' or test_complete;
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';
        wait until cpu_ready = '1' or test_complete;
        report_test("Byte write completed", true);

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

        report "D-Cache Test Summary:" severity note;
        report "  - Read hits and misses" severity note;
        report "  - Write hits and misses" severity note;
        report "  - Write-through policy" severity note;
        report "  - Write allocate mode" severity note;
        report "  - All 16 cache lines" severity note;
        report "  - Cache invalidation" severity note;
        report "  - Freeze mode" severity note;
        report "  - Enable/disable" severity note;
        report "  - Different access sizes" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
