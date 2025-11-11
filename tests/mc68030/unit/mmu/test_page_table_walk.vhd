------------------------------------------------------------------------------
-- Test: MC68030 Page Table Walk
--
-- Tests multi-level page table traversal including:
--   - Single-level page tables
--   - Multi-level tables (A, B, C, D)
--   - Early termination descriptors
--   - Permission checking (WP, S)
--   - Invalid descriptors
--   - Bus errors
--   - MMU disabled mode
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity test_page_table_walk is
end entity test_page_table_walk;

architecture testbench of test_page_table_walk is

    -- Component under test
    component TG68K030_PageTableWalk is
        port(
            clk, reset      : in  std_logic;
            start           : in  std_logic;
            abort_walk      : in  std_logic;
            virt_addr       : in  std_logic_vector(31 downto 0);
            fc              : in  std_logic_vector(2 downto 0);
            supervisor      : in  std_logic;
            rw              : in  std_logic;
            tc_reg          : in  std_logic_vector(31 downto 0);
            crp_reg         : in  std_logic_vector(63 downto 0);
            srp_reg         : in  std_logic_vector(63 downto 0);
            bus_req         : out std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_ready       : in  std_logic;
            bus_error       : in  std_logic;
            phys_addr       : out std_logic_vector(31 downto 0);
            write_protect   : out std_logic;
            super_only      : out std_logic;
            cache_inh       : out std_logic;
            modified        : out std_logic;
            used            : out std_logic;
            done            : out std_logic;
            error           : out std_logic;
            error_code      : out std_logic_vector(3 downto 0)
        );
    end component;

    -- Clock and reset
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Control signals
    signal start      : std_logic := '0';
    signal abort_walk : std_logic := '0';

    -- Input signals
    signal virt_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal fc         : std_logic_vector(2 downto 0) := (others => '0');
    signal supervisor : std_logic := '0';
    signal rw         : std_logic := '0';
    signal tc_reg     : std_logic_vector(31 downto 0) := (others => '0');
    signal crp_reg    : std_logic_vector(63 downto 0) := (others => '0');
    signal srp_reg    : std_logic_vector(63 downto 0) := (others => '0');

    -- Bus interface
    signal bus_req     : std_logic;
    signal bus_addr    : std_logic_vector(31 downto 0);
    signal bus_data_in : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_ready   : std_logic := '0';
    signal bus_error   : std_logic := '0';

    -- Output signals
    signal phys_addr     : std_logic_vector(31 downto 0);
    signal write_protect : std_logic;
    signal super_only    : std_logic;
    signal cache_inh     : std_logic;
    signal modified      : std_logic;
    signal used          : std_logic;
    signal done          : std_logic;
    signal error         : std_logic;
    signal error_code    : std_logic_vector(3 downto 0);

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;
    signal test_num : integer := 0;

    -- Helper function to build TC register
    function build_tc(
        enable : std_logic;
        sre    : std_logic;
        fcl    : std_logic;
        ps     : std_logic_vector(3 downto 0);
        is_val : std_logic_vector(3 downto 0);
        tia    : std_logic_vector(3 downto 0);
        tib    : std_logic_vector(3 downto 0);
        tic    : std_logic_vector(3 downto 0);
        tid    : std_logic_vector(3 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
    begin
        result := (others => '0');
        result(31) := enable;
        result(25) := sre;
        result(24) := fcl;
        result(23 downto 20) := ps;
        result(19 downto 16) := is_val;
        result(15 downto 12) := tia;
        result(11 downto 8)  := tib;
        result(7 downto 4)   := tic;
        result(3 downto 0)   := tid;
        return result;
    end function;

    -- Helper function to build descriptor
    function build_descriptor(
        dt   : std_logic_vector(1 downto 0);
        wp   : std_logic;
        u    : std_logic;
        m    : std_logic;
        ci   : std_logic;
        s    : std_logic;
        addr : std_logic_vector(27 downto 0)
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
    begin
        result(31 downto 4) := addr;
        result(8) := s;
        result(6) := ci;
        result(4) := m;
        result(3) := u;
        result(2) := wp;
        result(1 downto 0) := dt;
        return result;
    end function;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- Instantiate DUT
    dut: TG68K030_PageTableWalk
        port map(
            clk           => clk,
            reset         => reset,
            start         => start,
            abort_walk    => abort_walk,
            virt_addr     => virt_addr,
            fc            => fc,
            supervisor    => supervisor,
            rw            => rw,
            tc_reg        => tc_reg,
            crp_reg       => crp_reg,
            srp_reg       => srp_reg,
            bus_req       => bus_req,
            bus_addr      => bus_addr,
            bus_data_in   => bus_data_in,
            bus_ready     => bus_ready,
            bus_error     => bus_error,
            phys_addr     => phys_addr,
            write_protect => write_protect,
            super_only    => super_only,
            cache_inh     => cache_inh,
            modified      => modified,
            used          => used,
            done          => done,
            error         => error,
            error_code    => error_code
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

        procedure wait_for_done is
        begin
            while done = '0' and error = '0' loop
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
        -- Test 1: MMU disabled - direct mapping
        ---------------------------------------------------------------
        report_test("MMU disabled - direct mapping");
        tc_reg     <= build_tc('0', '0', '0', X"8", X"0", X"0", X"0", X"0", X"0");
        virt_addr  <= X"12345678";
        fc         <= "101";
        supervisor <= '1';
        rw         <= '0';
        start      <= '1';
        wait_cycles(1);
        start      <= '0';
        wait_for_done;
        assert done = '1' report "Expected done" severity error;
        assert phys_addr = X"12345678" report "Expected direct mapping" severity error;

        ---------------------------------------------------------------
        -- Test 2: Single-level table (D only), 4K pages
        ---------------------------------------------------------------
        report_test("Single-level table, 4K pages");
        wait_cycles(2);

        -- Setup: TC with IS=8, TID=12, PS=12 (4K pages)
        tc_reg    <= build_tc('1', '0', '0', X"C", X"8", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"10000000";  -- Root at 0x10000000
        virt_addr <= X"00123456";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        -- Start walk
        start <= '1';
        wait_cycles(1);
        start <= '0';

        -- Wait for bus request (D table)
        wait until bus_req = '1';
        wait_cycles(1);

        -- Return D descriptor (page descriptor)
        bus_data_in <= build_descriptor("01", '0', '1', '0', '0', '0', X"2000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert done = '1' report "Expected done" severity error;
        assert error = '0' report "Expected no error" severity error;
        -- Physical = 0x20000000 | 0x456 = 0x20000456
        assert phys_addr(31 downto 12) = X"20000" report "Wrong page base" severity error;

        ---------------------------------------------------------------
        -- Test 3: Two-level table (A + D)
        ---------------------------------------------------------------
        report_test("Two-level table (A + D)");
        wait_cycles(2);

        -- TC with TIA=8, TID=12, PS=12
        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"8", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"30000000";
        virt_addr <= X"12345678";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        -- Wait for A table bus request
        wait until bus_req = '1';
        wait_cycles(1);

        -- Return A descriptor (table descriptor pointing to D table)
        bus_data_in <= build_descriptor("10", '0', '1', '0', '0', '0', X"4000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        -- Wait for D table bus request
        wait until bus_req = '1';
        wait_cycles(1);

        -- Return D descriptor (page descriptor)
        bus_data_in <= build_descriptor("01", '0', '1', '0', '0', '0', X"5000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert done = '1' report "Expected done" severity error;
        assert error = '0' report "Expected no error" severity error;

        ---------------------------------------------------------------
        -- Test 4: Four-level table (A + B + C + D)
        ---------------------------------------------------------------
        report_test("Four-level table (A + B + C + D)");
        wait_cycles(2);

        -- TC with TIA=4, TIB=4, TIC=4, TID=4, PS=12
        tc_reg    <= build_tc('1', '0', '0', X"C", X"4", X"4", X"4", X"4", X"4");
        crp_reg   <= X"00000000" & X"60000000");
        virt_addr <= X"00111222";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        -- A table fetch
        wait until bus_req = '1';
        wait_cycles(1);
        bus_data_in <= build_descriptor("10", '0', '0', '0', '0', '0', X"6100000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        -- B table fetch
        wait until bus_req = '1';
        wait_cycles(1);
        bus_data_in <= build_descriptor("10", '0', '0', '0', '0', '0', X"6200000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        -- C table fetch
        wait until bus_req = '1';
        wait_cycles(1);
        bus_data_in <= build_descriptor("10", '0', '0', '0', '0', '0', X"6300000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        -- D table fetch (page)
        wait until bus_req = '1';
        wait_cycles(1);
        bus_data_in <= build_descriptor("01", '0', '1', '0', '0', '0', X"7000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert done = '1' report "Expected done" severity error;
        assert error = '0' report "Expected no error" severity error;

        ---------------------------------------------------------------
        -- Test 5: Invalid descriptor (DT=00)
        ---------------------------------------------------------------
        report_test("Invalid descriptor - expect error");
        wait_cycles(2);

        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"80000000";
        virt_addr <= X"00001000";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        wait until bus_req = '1';
        wait_cycles(1);

        -- Return invalid descriptor (DT=00)
        bus_data_in <= build_descriptor("00", '0', '0', '0', '0', '0', X"0000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert error = '1' report "Expected error for invalid descriptor" severity error;
        assert error_code = "0001" report "Expected invalid descriptor error code" severity error;

        ---------------------------------------------------------------
        -- Test 6: Bus error during fetch
        ---------------------------------------------------------------
        report_test("Bus error during fetch");
        wait_cycles(2);

        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"90000000";
        virt_addr <= X"00002000";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        wait until bus_req = '1';
        wait_cycles(1);

        -- Return bus error
        bus_error <= '1';
        wait_cycles(1);
        bus_error <= '0';

        wait_for_done;
        assert error = '1' report "Expected error for bus error" severity error;
        assert error_code = "0010" report "Expected bus error code" severity error;

        ---------------------------------------------------------------
        -- Test 7: Write protection check
        ---------------------------------------------------------------
        report_test("Write protection violation");
        wait_cycles(2);

        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"A0000000";
        virt_addr <= X"00003000";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '1';  -- Write access

        start <= '1';
        wait_cycles(1);
        start <= '0';

        wait until bus_req = '1';
        wait_cycles(1);

        -- Return write-protected descriptor
        bus_data_in <= build_descriptor("01", '1', '1', '0', '0', '0', X"B000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert error = '1' report "Expected error for write protection" severity error;
        assert error_code = "0011" report "Expected write protect error code" severity error;

        ---------------------------------------------------------------
        -- Test 8: Supervisor violation
        ---------------------------------------------------------------
        report_test("Supervisor violation");
        wait_cycles(2);

        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"C0000000";
        virt_addr <= X"00004000";
        fc        <= "001";  -- User data
        supervisor <= '0';   -- User mode
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        wait until bus_req = '1';
        wait_cycles(1);

        -- Return supervisor-only descriptor
        bus_data_in <= build_descriptor("01", '0', '1', '0', '0', '1', X"D000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert error = '1' report "Expected error for supervisor violation" severity error;
        assert error_code = "0100" report "Expected supervisor violation error code" severity error;

        ---------------------------------------------------------------
        -- Test 9: Successful translation with all flags
        ---------------------------------------------------------------
        report_test("Successful translation with all flags set");
        wait_cycles(2);

        tc_reg    <= build_tc('1', '0', '0', X"C", X"0", X"0", X"0", X"0", X"C");
        crp_reg   <= X"00000000" & X"E0000000";
        virt_addr <= X"00005ABC";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        wait until bus_req = '1';
        wait_cycles(1);

        -- Return descriptor with all flags set
        bus_data_in <= build_descriptor("01", '1', '1', '1', '1', '1', X"F000000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert done = '1' report "Expected done" severity error;
        assert error = '0' report "Expected no error for read from WP page" severity error;
        assert write_protect = '1' report "Expected WP flag" severity error;
        assert super_only = '1' report "Expected S flag" severity error;
        assert cache_inh = '1' report "Expected CI flag" severity error;
        assert modified = '1' report "Expected M flag" severity error;
        assert used = '1' report "Expected U flag" severity error;

        ---------------------------------------------------------------
        -- Test 10: Early termination descriptor
        ---------------------------------------------------------------
        report_test("Early termination descriptor");
        wait_cycles(2);

        -- TC with TIA=8, TIB=8, but we'll return a page descriptor early
        tc_reg    <= build_tc('1', '0', '0', X"8", X"8", X"8", X"8", X"0", X"0");
        crp_reg   <= X"00000000" & X"50000000";
        virt_addr <= X"01234567";
        fc        <= "101";
        supervisor <= '1';
        rw        <= '0';

        start <= '1';
        wait_cycles(1);
        start <= '0';

        -- A table request
        wait until bus_req = '1';
        wait_cycles(1);

        -- Return early termination page descriptor (DT=01)
        bus_data_in <= build_descriptor("01", '0', '1', '0', '0', '0', X"5500000");
        bus_ready   <= '1';
        wait_cycles(1);
        bus_ready   <= '0';

        wait_for_done;
        assert done = '1' report "Expected done with early termination" severity error;
        assert error = '0' report "Expected no error" severity error;

        ---------------------------------------------------------------
        -- All tests complete
        ---------------------------------------------------------------
        wait_cycles(5);
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);
        write(l, string'("All Page Table Walk tests passed!"));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);

        test_done <= true;
        wait;
    end process;

end architecture testbench;
