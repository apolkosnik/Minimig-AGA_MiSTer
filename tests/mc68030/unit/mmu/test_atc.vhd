------------------------------------------------------------------------------
-- Test: MC68030 Address Translation Cache (ATC)
--
-- Tests the 22-entry fully associative ATC including:
--   - Lookup operations (hit/miss)
--   - Loading entries
--   - FIFO replacement
--   - Flush operations (all, by FC, by address)
--   - Permission flags
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity test_atc is
end entity test_atc;

architecture testbench of test_atc is

    -- Component under test
    component TG68K030_ATC is
        port(
            clk            : in  std_logic;
            reset          : in  std_logic;
            lookup_addr    : in  std_logic_vector(31 downto 0);
            lookup_fc      : in  std_logic_vector(2 downto 0);
            lookup_en      : in  std_logic;
            hit            : out std_logic;
            phys_addr      : out std_logic_vector(31 downto 0);
            write_protect  : out std_logic;
            super_only     : out std_logic;
            cache_inhibit  : out std_logic;
            modified       : out std_logic;
            used           : out std_logic;
            load_entry     : in  std_logic;
            load_virt_addr : in  std_logic_vector(31 downto 0);
            load_phys_addr : in  std_logic_vector(31 downto 0);
            load_fc        : in  std_logic_vector(2 downto 0);
            load_wp        : in  std_logic;
            load_super     : in  std_logic;
            load_ci        : in  std_logic;
            load_modified  : in  std_logic;
            load_used      : in  std_logic;
            flush_all      : in  std_logic;
            flush_by_fc    : in  std_logic;
            flush_fc       : in  std_logic_vector(2 downto 0);
            flush_by_addr  : in  std_logic;
            flush_addr     : in  std_logic_vector(31 downto 0)
        );
    end component;

    -- Clock and reset
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Lookup interface
    signal lookup_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal lookup_fc      : std_logic_vector(2 downto 0) := (others => '0');
    signal lookup_en      : std_logic := '0';
    signal hit            : std_logic;
    signal phys_addr      : std_logic_vector(31 downto 0);
    signal write_protect  : std_logic;
    signal super_only     : std_logic;
    signal cache_inhibit  : std_logic;
    signal modified       : std_logic;
    signal used           : std_logic;

    -- Load interface
    signal load_entry     : std_logic := '0';
    signal load_virt_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal load_phys_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal load_fc        : std_logic_vector(2 downto 0) := (others => '0');
    signal load_wp        : std_logic := '0';
    signal load_super     : std_logic := '0';
    signal load_ci        : std_logic := '0';
    signal load_modified  : std_logic := '0';
    signal load_used      : std_logic := '0';

    -- Flush interface
    signal flush_all      : std_logic := '0';
    signal flush_by_fc    : std_logic := '0';
    signal flush_fc       : std_logic_vector(2 downto 0) := (others => '0');
    signal flush_by_addr  : std_logic := '0';
    signal flush_addr     : std_logic_vector(31 downto 0) := (others => '0');

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;

    -- Test counter
    signal test_num : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- Instantiate DUT
    dut: TG68K030_ATC
        port map(
            clk            => clk,
            reset          => reset,
            lookup_addr    => lookup_addr,
            lookup_fc      => lookup_fc,
            lookup_en      => lookup_en,
            hit            => hit,
            phys_addr      => phys_addr,
            write_protect  => write_protect,
            super_only     => super_only,
            cache_inhibit  => cache_inhibit,
            modified       => modified,
            used           => used,
            load_entry     => load_entry,
            load_virt_addr => load_virt_addr,
            load_phys_addr => load_phys_addr,
            load_fc        => load_fc,
            load_wp        => load_wp,
            load_super     => load_super,
            load_ci        => load_ci,
            load_modified  => load_modified,
            load_used      => load_used,
            flush_all      => flush_all,
            flush_by_fc    => flush_by_fc,
            flush_fc       => flush_fc,
            flush_by_addr  => flush_by_addr,
            flush_addr     => flush_addr
        );

    -- Test process
    test_proc: process
        variable l : line;

        procedure report_test(test_name : string) is
        begin
            test_num <= test_num + 1;
            write(l, string'("Test "));
            write(l, test_num + 1);
            write(l, string'(": "));
            write(l, test_name);
            writeline(output, l);
        end procedure;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

    begin
        -- Reset
        reset <= '1';
        wait_cycles(5);
        reset <= '0';
        wait_cycles(2);

        ---------------------------------------------------------------
        -- Test 1: ATC empty - lookup should miss
        ---------------------------------------------------------------
        report_test("ATC empty - lookup miss");
        lookup_addr <= X"12345000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected ATC miss on empty cache" severity error;

        ---------------------------------------------------------------
        -- Test 2: Load one entry
        ---------------------------------------------------------------
        report_test("Load entry into ATC");
        load_virt_addr <= X"12345000";
        load_phys_addr <= X"ABCD5000";
        load_fc        <= "101";
        load_wp        <= '0';
        load_super     <= '1';
        load_ci        <= '0';
        load_modified  <= '0';
        load_used      <= '1';
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 3: Lookup loaded entry - should hit
        ---------------------------------------------------------------
        report_test("Lookup loaded entry - should hit");
        lookup_addr <= X"12345000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '1' report "Expected ATC hit" severity error;
        assert phys_addr = X"ABCD5000" report "Wrong physical address" severity error;
        assert super_only = '1' report "Wrong supervisor flag" severity error;

        ---------------------------------------------------------------
        -- Test 4: Lookup with different FC - should miss
        ---------------------------------------------------------------
        report_test("Lookup with different FC - should miss");
        lookup_addr <= X"12345000";
        lookup_fc   <= "001";  -- Different FC
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected ATC miss with different FC" severity error;

        ---------------------------------------------------------------
        -- Test 5: Lookup with different address - should miss
        ---------------------------------------------------------------
        report_test("Lookup with different address - should miss");
        lookup_addr <= X"99999000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected ATC miss with different address" severity error;

        ---------------------------------------------------------------
        -- Test 6: Load 22 entries (fill ATC)
        ---------------------------------------------------------------
        report_test("Fill ATC with 22 entries");
        for i in 0 to 21 loop
            load_virt_addr <= std_logic_vector(to_unsigned(16#10000000# + i * 16#1000#, 32));
            load_phys_addr <= std_logic_vector(to_unsigned(16#20000000# + i * 16#1000#, 32));
            load_fc        <= "101";
            load_wp        <= '0';
            load_super     <= '0';
            load_ci        <= '0';
            load_modified  <= '0';
            load_used      <= '1';
            load_entry     <= '1';
            wait_cycles(1);
            load_entry     <= '0';
            wait_cycles(1);
        end loop;

        ---------------------------------------------------------------
        -- Test 7: Verify first entry still present
        ---------------------------------------------------------------
        report_test("Verify first entry still present");
        lookup_addr <= X"10000000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '1' report "Expected first entry to be present" severity error;
        assert phys_addr = X"20000000" report "Wrong physical address for first entry" severity error;

        ---------------------------------------------------------------
        -- Test 8: Load 23rd entry (should evict first entry - FIFO)
        ---------------------------------------------------------------
        report_test("Load 23rd entry - FIFO replacement");
        load_virt_addr <= X"10016000";
        load_phys_addr <= X"20016000";
        load_fc        <= "101";
        load_wp        <= '0';
        load_super     <= '0';
        load_ci        <= '0';
        load_modified  <= '0';
        load_used      <= '1';
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 9: Verify first entry was evicted
        ---------------------------------------------------------------
        report_test("Verify FIFO evicted first entry");
        lookup_addr <= X"10000000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected first entry to be evicted" severity error;

        ---------------------------------------------------------------
        -- Test 10: Verify 23rd entry is present
        ---------------------------------------------------------------
        report_test("Verify 23rd entry is present");
        lookup_addr <= X"10016000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '1' report "Expected 23rd entry to be present" severity error;

        ---------------------------------------------------------------
        -- Test 11: Flush all entries
        ---------------------------------------------------------------
        report_test("Flush all ATC entries");
        flush_all <= '1';
        wait_cycles(1);
        flush_all <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 12: Verify all entries flushed
        ---------------------------------------------------------------
        report_test("Verify all entries flushed");
        lookup_addr <= X"10016000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected all entries to be flushed" severity error;

        ---------------------------------------------------------------
        -- Test 13: Load entries with different FCs
        ---------------------------------------------------------------
        report_test("Load entries with different FCs");
        -- User data
        load_virt_addr <= X"30000000";
        load_phys_addr <= X"40000000";
        load_fc        <= "001";  -- User data
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        -- Supervisor data
        load_virt_addr <= X"31000000";
        load_phys_addr <= X"41000000";
        load_fc        <= "101";  -- Supervisor data
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        -- Supervisor program
        load_virt_addr <= X"32000000";
        load_phys_addr <= X"42000000";
        load_fc        <= "110";  -- Supervisor program
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 14: Flush by FC (supervisor data)
        ---------------------------------------------------------------
        report_test("Flush by FC (supervisor data)");
        flush_by_fc <= '1';
        flush_fc    <= "101";
        wait_cycles(1);
        flush_by_fc <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 15: Verify supervisor data flushed
        ---------------------------------------------------------------
        report_test("Verify supervisor data entry flushed");
        lookup_addr <= X"31000000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected supervisor data entry to be flushed" severity error;

        ---------------------------------------------------------------
        -- Test 16: Verify user data NOT flushed
        ---------------------------------------------------------------
        report_test("Verify user data entry NOT flushed");
        lookup_addr <= X"30000000";
        lookup_fc   <= "001";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '1' report "Expected user data entry to remain" severity error;

        ---------------------------------------------------------------
        -- Test 17: Flush by address
        ---------------------------------------------------------------
        report_test("Flush by address");
        flush_by_addr <= '1';
        flush_addr    <= X"30000000";
        wait_cycles(1);
        flush_by_addr <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 18: Verify entry flushed by address
        ---------------------------------------------------------------
        report_test("Verify entry flushed by address");
        lookup_addr <= X"30000000";
        lookup_fc   <= "001";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '0' report "Expected entry to be flushed by address" severity error;

        ---------------------------------------------------------------
        -- Test 19: Load entry with all flags set
        ---------------------------------------------------------------
        report_test("Load entry with all flags set");
        load_virt_addr <= X"50000000";
        load_phys_addr <= X"60000000";
        load_fc        <= "101";
        load_wp        <= '1';  -- Write protected
        load_super     <= '1';  -- Supervisor only
        load_ci        <= '1';  -- Cache inhibit
        load_modified  <= '1';  -- Modified
        load_used      <= '1';  -- Used
        load_entry     <= '1';
        wait_cycles(1);
        load_entry     <= '0';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- Test 20: Verify all flags returned correctly
        ---------------------------------------------------------------
        report_test("Verify all flags returned correctly");
        lookup_addr <= X"50000000";
        lookup_fc   <= "101";
        lookup_en   <= '1';
        wait_cycles(1);
        lookup_en   <= '0';
        wait_cycles(1);
        assert hit = '1' report "Expected hit" severity error;
        assert write_protect = '1' report "Expected WP flag set" severity error;
        assert super_only = '1' report "Expected S flag set" severity error;
        assert cache_inhibit = '1' report "Expected CI flag set" severity error;
        assert modified = '1' report "Expected M flag set" severity error;
        assert used = '1' report "Expected U flag set" severity error;

        ---------------------------------------------------------------
        -- All tests complete
        ---------------------------------------------------------------
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);
        write(l, string'("All ATC tests passed!"));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);

        test_done <= true;
        wait;
    end process;

end architecture testbench;
