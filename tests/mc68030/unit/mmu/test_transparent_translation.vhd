------------------------------------------------------------------------------
-- Test: MC68030 Transparent Translation (TT0/TT1)
--
-- Tests the TT0 and TT1 transparent translation registers including:
--   - Enable/disable functionality
--   - Address matching with masks
--   - Function code matching with masks
--   - Supervisor/user mode checking
--   - Read/write checking
--   - Priority (TT0 before TT1)
--   - Cache inhibit flag output
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity test_transparent_translation is
end entity test_transparent_translation;

architecture testbench of test_transparent_translation is

    -- Component under test
    component TG68K030_TransparentTranslation is
        port(
            tt0_reg     : in  std_logic_vector(31 downto 0);
            tt1_reg     : in  std_logic_vector(31 downto 0);
            virt_addr   : in  std_logic_vector(31 downto 0);
            fc          : in  std_logic_vector(2 downto 0);
            supervisor  : in  std_logic;
            rw          : in  std_logic;
            tt_match    : out std_logic;
            tt_ci       : out std_logic;
            tt_which    : out std_logic_vector(1 downto 0)
        );
    end component;

    -- Signals
    signal tt0_reg    : std_logic_vector(31 downto 0) := (others => '0');
    signal tt1_reg    : std_logic_vector(31 downto 0) := (others => '0');
    signal virt_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal fc         : std_logic_vector(2 downto 0) := (others => '0');
    signal supervisor : std_logic := '0';
    signal rw         : std_logic := '0';
    signal tt_match   : std_logic;
    signal tt_ci      : std_logic;
    signal tt_which   : std_logic_vector(1 downto 0);

    -- Test counter
    signal test_num : integer := 0;

    -- TT register field positions
    constant TT_ENABLE     : integer := 31;
    constant TT_SUPER_USER : integer := 30;
    constant TT_CACHE_INH  : integer := 29;
    constant TT_RW         : integer := 28;

    -- Helper function to build TT register
    function build_tt(
        enable      : std_logic;
        super_user  : std_logic;
        cache_inh   : std_logic;
        rw_bit      : std_logic;
        log_addr    : std_logic_vector(7 downto 0);
        log_mask    : std_logic_vector(7 downto 0);
        fc_base     : std_logic_vector(3 downto 0);
        fc_mask     : std_logic_vector(3 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
    begin
        result := (others => '0');
        result(31) := enable;
        result(30) := super_user;
        result(29) := cache_inh;
        result(28) := rw_bit;
        result(23 downto 16) := log_addr;
        result(15 downto 8)  := log_mask;
        result(7 downto 4)   := fc_base;
        result(3 downto 0)   := fc_mask;
        return result;
    end function;

begin

    -- Instantiate DUT
    dut: TG68K030_TransparentTranslation
        port map(
            tt0_reg    => tt0_reg,
            tt1_reg    => tt1_reg,
            virt_addr  => virt_addr,
            fc         => fc,
            supervisor => supervisor,
            rw         => rw,
            tt_match   => tt_match,
            tt_ci      => tt_ci,
            tt_which   => tt_which
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

        procedure wait_delta is
        begin
            wait for 1 ns;
        end procedure;

    begin
        wait for 10 ns;

        ---------------------------------------------------------------
        -- Test 1: TT0 disabled - no match
        ---------------------------------------------------------------
        report_test("TT0 disabled - no match");
        tt0_reg <= build_tt(
            enable     => '0',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"FF",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"FF000000";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '0' report "Expected no match when disabled" severity error;

        ---------------------------------------------------------------
        -- Test 2: TT0 enabled - address match
        ---------------------------------------------------------------
        report_test("TT0 enabled - address and FC match");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"FF",
            log_mask   => X"FF",  -- All bits must match
            fc_base    => "0101",
            fc_mask    => "0111"  -- Match bits 0,1,2 of FC
        );
        virt_addr  <= X"FF000000";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '1' report "Expected match" severity error;
        assert tt_which = "01" report "Expected TT0 match" severity error;

        ---------------------------------------------------------------
        -- Test 3: Address mismatch
        ---------------------------------------------------------------
        report_test("Address mismatch - no match");
        virt_addr <= X"FE000000";  -- Different address
        wait_delta;
        assert tt_match = '0' report "Expected no match with different address" severity error;

        ---------------------------------------------------------------
        -- Test 4: Partial address mask
        ---------------------------------------------------------------
        report_test("Partial address mask - upper 4 bits only");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"F0",
            log_mask   => X"F0",  -- Only upper 4 bits matter
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"F5000000";  -- Upper 4 bits = F, lower 4 = 5
        fc         <= "101";
        supervisor <= '1';
        wait_delta;
        assert tt_match = '1' report "Expected match with partial mask" severity error;

        ---------------------------------------------------------------
        -- Test 5: FC mismatch
        ---------------------------------------------------------------
        report_test("Function code mismatch - no match");
        fc <= "001";  -- Different FC
        wait_delta;
        assert tt_match = '0' report "Expected no match with different FC" severity error;

        ---------------------------------------------------------------
        -- Test 6: Partial FC mask
        ---------------------------------------------------------------
        report_test("Partial FC mask - only bit 2 matters");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"F0",
            log_mask   => X"F0",
            fc_base    => "0100",
            fc_mask    => "0100"  -- Only bit 2 matters
        );
        virt_addr  <= X"F5000000";
        fc         <= "111";  -- Bit 2 = 1, matches fc_base bit 2 = 1
        supervisor <= '1';
        wait_delta;
        assert tt_match = '1' report "Expected match with partial FC mask" severity error;

        ---------------------------------------------------------------
        -- Test 7: Supervisor mode mismatch
        ---------------------------------------------------------------
        report_test("Supervisor mode mismatch - no match");
        supervisor <= '0';  -- User mode, but TT requires supervisor
        wait_delta;
        assert tt_match = '0' report "Expected no match in user mode" severity error;

        ---------------------------------------------------------------
        -- Test 8: User mode configuration
        ---------------------------------------------------------------
        report_test("User mode match");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '0',  -- User mode
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"80",
            log_mask   => X"FF",
            fc_base    => "0001",
            fc_mask    => "0111"
        );
        virt_addr  <= X"80000000";
        fc         <= "001";
        supervisor <= '0';  -- User mode
        rw         <= '0';
        wait_delta;
        assert tt_match = '1' report "Expected match in user mode" severity error;

        ---------------------------------------------------------------
        -- Test 9: Read-only TT, read access - match
        ---------------------------------------------------------------
        report_test("Read-only TT with read access - match");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '0',  -- Read-only
            log_addr   => X"C0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"C0000000";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';  -- Read
        wait_delta;
        assert tt_match = '1' report "Expected match for read on read-only TT" severity error;

        ---------------------------------------------------------------
        -- Test 10: Read-only TT, write access - no match
        ---------------------------------------------------------------
        report_test("Read-only TT with write access - no match");
        rw <= '1';  -- Write
        wait_delta;
        assert tt_match = '0' report "Expected no match for write on read-only TT" severity error;

        ---------------------------------------------------------------
        -- Test 11: Read-write TT, write access - match
        ---------------------------------------------------------------
        report_test("Read-write TT with write access - match");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',  -- Read-write
            log_addr   => X"C0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        rw <= '1';  -- Write
        wait_delta;
        assert tt_match = '1' report "Expected match for write on read-write TT" severity error;

        ---------------------------------------------------------------
        -- Test 12: Cache inhibit flag
        ---------------------------------------------------------------
        report_test("Cache inhibit flag output");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '1',  -- Cache inhibit
            rw_bit     => '1',
            log_addr   => X"D0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"D0000000";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '1' report "Expected match" severity error;
        assert tt_ci = '1' report "Expected cache inhibit flag set" severity error;

        ---------------------------------------------------------------
        -- Test 13: TT1 match when TT0 doesn't
        ---------------------------------------------------------------
        report_test("TT1 match when TT0 doesn't");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"FF",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        tt1_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"E0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"E0000000";  -- Matches TT1, not TT0
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '1' report "Expected TT1 match" severity error;
        assert tt_which = "10" report "Expected TT1 indicator" severity error;

        ---------------------------------------------------------------
        -- Test 14: Priority - TT0 before TT1
        ---------------------------------------------------------------
        report_test("Priority - TT0 before TT1");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '0',  -- TT0: no cache inhibit
            rw_bit     => '1',
            log_addr   => X"A0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        tt1_reg <= build_tt(
            enable     => '1',
            super_user => '1',
            cache_inh  => '1',  -- TT1: cache inhibit
            rw_bit     => '1',
            log_addr   => X"A0",
            log_mask   => X"FF",
            fc_base    => "0101",
            fc_mask    => "0111"
        );
        virt_addr  <= X"A0000000";  -- Matches both
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '1' report "Expected match" severity error;
        assert tt_which = "01" report "Expected TT0 (priority)" severity error;
        assert tt_ci = '0' report "Expected TT0 cache inhibit flag (no CI)" severity error;

        ---------------------------------------------------------------
        -- Test 15: Both disabled - no match
        ---------------------------------------------------------------
        report_test("Both TT0 and TT1 disabled - no match");
        tt0_reg <= build_tt(
            enable     => '0',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"00",
            log_mask   => X"00",
            fc_base    => "0000",
            fc_mask    => "0000"
        );
        tt1_reg <= build_tt(
            enable     => '0',
            super_user => '1',
            cache_inh  => '0',
            rw_bit     => '1',
            log_addr   => X"00",
            log_mask   => X"00",
            fc_base    => "0000",
            fc_mask    => "0000"
        );
        virt_addr  <= X"00000000";
        fc         <= "000";
        supervisor <= '1';
        rw         <= '0';
        wait_delta;
        assert tt_match = '0' report "Expected no match when both disabled" severity error;
        assert tt_which = "00" report "Expected no match indicator" severity error;

        ---------------------------------------------------------------
        -- Test 16: Typical I/O mapping (0xFFxxxxxx, supervisor, cache inhibit)
        ---------------------------------------------------------------
        report_test("Typical I/O mapping scenario");
        tt0_reg <= build_tt(
            enable     => '1',
            super_user => '1',       -- Supervisor only
            cache_inh  => '1',       -- No caching for I/O
            rw_bit     => '1',       -- Read-write
            log_addr   => X"FF",     -- Address 0xFFxxxxxx
            log_mask   => X"FF",     -- All 8 bits must match
            fc_base    => "0101",    -- Supervisor data
            fc_mask    => "0111"     -- All 3 FC bits must match
        );
        tt1_reg    <= (others => '0');  -- TT1 disabled
        virt_addr  <= X"FF800000";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '1';
        wait_delta;
        assert tt_match = '1' report "Expected I/O match" severity error;
        assert tt_ci = '1' report "Expected cache inhibit for I/O" severity error;

        ---------------------------------------------------------------
        -- Test 17: Typical ROM mapping (0xF0xxxxxx, any mode, no cache inhibit)
        ---------------------------------------------------------------
        report_test("Typical ROM mapping scenario");
        tt1_reg <= build_tt(
            enable     => '1',
            super_user => '1',       -- Supervisor (could be either)
            cache_inh  => '0',       -- Allow caching for ROM
            rw_bit     => '0',       -- Read-only
            log_addr   => X"F0",     -- Address 0xF0xxxxxx
            log_mask   => X"FF",
            fc_base    => "0110",    -- Supervisor program
            fc_mask    => "0111"
        );
        virt_addr  <= X"F0000000";
        fc         <= "110";
        supervisor <= '1';
        rw         <= '0';  -- Read
        wait_delta;
        assert tt_match = '1' report "Expected ROM match" severity error;
        assert tt_ci = '0' report "Expected caching allowed for ROM" severity error;

        ---------------------------------------------------------------
        -- All tests complete
        ---------------------------------------------------------------
        wait for 10 ns;
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);
        write(l, string'("All Transparent Translation tests passed!"));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);

        wait;
    end process;

end architecture testbench;
