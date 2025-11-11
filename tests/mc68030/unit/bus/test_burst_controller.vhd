------------------------------------------------------------------------------
-- Test: MC68030 Burst Controller
--
-- Tests 4-beat burst transfers for cache line fills:
--   - Correct address generation (aligned to 16 bytes)
--   - 4-longword data capture
--   - BURST signal assertion/deassertion
--   - Bus error handling
--   - DSACK wait states
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity test_burst_controller is
end entity test_burst_controller;

architecture testbench of test_burst_controller is

    -- Component under test
    component TG68K030_BurstController is
        port(
            clk, reset      : in  std_logic;
            burst_req       : in  std_logic;
            burst_addr      : in  std_logic_vector(31 downto 0);
            burst_done      : out std_logic;
            burst_error     : out std_logic;
            bus_addr        : out std_logic_vector(31 downto 0);
            bus_burst       : out std_logic;
            bus_as          : out std_logic;
            bus_ds          : out std_logic;
            bus_data_in     : in  std_logic_vector(31 downto 0);
            bus_dsack       : in  std_logic_vector(1 downto 0);
            bus_berr        : in  std_logic;
            line_data_0     : out std_logic_vector(31 downto 0);
            line_data_1     : out std_logic_vector(31 downto 0);
            line_data_2     : out std_logic_vector(31 downto 0);
            line_data_3     : out std_logic_vector(31 downto 0);
            line_valid      : out std_logic
        );
    end component;

    -- Clock and reset
    signal clk   : std_logic := '0';
    signal reset : std_logic := '1';

    -- Control signals
    signal burst_req   : std_logic := '0';
    signal burst_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal burst_done  : std_logic;
    signal burst_error : std_logic;

    -- Bus signals
    signal bus_addr    : std_logic_vector(31 downto 0);
    signal bus_burst   : std_logic;
    signal bus_as      : std_logic;
    signal bus_ds      : std_logic;
    signal bus_data_in : std_logic_vector(31 downto 0) := (others => '0');
    signal bus_dsack   : std_logic_vector(1 downto 0) := "11";
    signal bus_berr    : std_logic := '0';

    -- Data output
    signal line_data_0 : std_logic_vector(31 downto 0);
    signal line_data_1 : std_logic_vector(31 downto 0);
    signal line_data_2 : std_logic_vector(31 downto 0);
    signal line_data_3 : std_logic_vector(31 downto 0);
    signal line_valid  : std_logic;

    -- Test control
    signal test_done : boolean := false;
    constant CLK_PERIOD : time := 10 ns;
    signal test_num : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- Instantiate DUT
    dut: TG68K030_BurstController
        port map(
            clk         => clk,
            reset       => reset,
            burst_req   => burst_req,
            burst_addr  => burst_addr,
            burst_done  => burst_done,
            burst_error => burst_error,
            bus_addr    => bus_addr,
            bus_burst   => bus_burst,
            bus_as      => bus_as,
            bus_ds      => bus_ds,
            bus_data_in => bus_data_in,
            bus_dsack   => bus_dsack,
            bus_berr    => bus_berr,
            line_data_0 => line_data_0,
            line_data_1 => line_data_1,
            line_data_2 => line_data_2,
            line_data_3 => line_data_3,
            line_valid  => line_valid
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
        -- Test 1: Simple burst transfer with immediate DSACK
        ---------------------------------------------------------------
        report_test("Simple burst transfer - 4 beats");
        burst_addr <= X"10000008";  -- Unaligned address
        burst_req  <= '1';
        wait_cycles(1);
        burst_req  <= '0';

        -- Wait for BURST assertion
        wait until bus_burst = '1';
        wait_cycles(1);

        -- Beat 1: Address should be aligned to 0x10000000
        assert bus_addr = X"10000000" report "Beat 1: Wrong address" severity error;
        assert bus_as = '1' report "Beat 1: AS not asserted" severity error;
        assert bus_ds = '1' report "Beat 1: DS not asserted" severity error;

        -- Simulate memory response
        bus_data_in <= X"AAAAAAAA";
        bus_dsack   <= "00";  -- 32-bit port, ready
        wait_cycles(1);
        bus_dsack   <= "11";  -- Deassert DSACK
        wait_cycles(1);

        -- Beat 2
        assert bus_addr = X"10000004" report "Beat 2: Wrong address" severity error;
        bus_data_in <= X"BBBBBBBB";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 3
        assert bus_addr = X"10000008" report "Beat 3: Wrong address" severity error;
        bus_data_in <= X"CCCCCCCC";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 4 (last beat, BURST should deassert)
        assert bus_addr = X"1000000C" report "Beat 4: Wrong address" severity error;
        assert bus_burst = '0' report "Beat 4: BURST should be deasserted" severity error;
        bus_data_in <= X"DDDDDDDD";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";

        -- Wait for completion
        wait until burst_done = '1';
        wait_cycles(1);

        -- Verify captured data
        assert line_data_0 = X"AAAAAAAA" report "Data 0 incorrect" severity error;
        assert line_data_1 = X"BBBBBBBB" report "Data 1 incorrect" severity error;
        assert line_data_2 = X"CCCCCCCC" report "Data 2 incorrect" severity error;
        assert line_data_3 = X"DDDDDDDD" report "Data 3 incorrect" severity error;
        assert line_valid = '1' report "Line valid not asserted" severity error;

        ---------------------------------------------------------------
        -- Test 2: Burst with wait states
        ---------------------------------------------------------------
        report_test("Burst with wait states");
        wait_cycles(2);

        burst_addr <= X"20000000";  -- Already aligned
        burst_req  <= '1';
        wait_cycles(1);
        burst_req  <= '0';

        wait until bus_burst = '1';
        wait_cycles(1);

        -- Beat 1 with 2 wait states
        assert bus_addr = X"20000000" report "Beat 1: Wrong address" severity error;
        wait_cycles(2);  -- Wait states (DSACK = 11)
        bus_data_in <= X"11111111";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 2 with 1 wait state
        wait_cycles(1);  -- Wait state
        bus_data_in <= X"22222222";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 3 immediate
        bus_data_in <= X"33333333";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 4 immediate
        bus_data_in <= X"44444444";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";

        wait until burst_done = '1';
        wait_cycles(1);

        assert line_data_0 = X"11111111" report "Data 0 incorrect" severity error;
        assert line_data_1 = X"22222222" report "Data 1 incorrect" severity error;
        assert line_data_2 = X"33333333" report "Data 2 incorrect" severity error;
        assert line_data_3 = X"44444444" report "Data 3 incorrect" severity error;

        ---------------------------------------------------------------
        -- Test 3: Burst with bus error on beat 2
        ---------------------------------------------------------------
        report_test("Burst with bus error on beat 2");
        wait_cycles(2);

        burst_addr <= X"30000000";
        burst_req  <= '1';
        wait_cycles(1);
        burst_req  <= '0';

        wait until bus_burst = '1';
        wait_cycles(1);

        -- Beat 1 success
        bus_data_in <= X"AAAAAAAA";
        bus_dsack   <= "00";
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Beat 2 - bus error
        bus_berr <= '1';
        wait_cycles(1);
        bus_berr <= '0';

        -- Wait for completion with error
        wait until burst_done = '1';
        wait_cycles(1);

        assert burst_error = '1' report "Expected burst_error to be asserted" severity error;
        assert bus_burst = '0' report "BURST should be deasserted on error" severity error;
        assert bus_as = '0' report "AS should be deasserted on error" severity error;

        ---------------------------------------------------------------
        -- Test 4: Address alignment verification
        ---------------------------------------------------------------
        report_test("Address alignment to 16-byte boundary");
        wait_cycles(2);

        -- Test various unaligned addresses
        burst_addr <= X"4000000F";  -- Should align to 0x40000000
        burst_req  <= '1';
        wait_cycles(1);
        burst_req  <= '0';

        wait until bus_burst = '1';
        wait_cycles(1);

        assert bus_addr = X"40000000" report "Should align to 16-byte boundary" severity error;

        -- Complete the burst (simplified)
        for i in 1 to 4 loop
            bus_data_in <= X"00000000";
            bus_dsack   <= "00";
            wait_cycles(1);
            bus_dsack   <= "11";
            wait_cycles(1);
        end loop;

        wait until burst_done = '1';
        wait_cycles(2);

        ---------------------------------------------------------------
        -- Test 5: DSACK port sizing (16-bit port)
        ---------------------------------------------------------------
        report_test("16-bit port DSACK");
        wait_cycles(2);

        burst_addr <= X"50000000";
        burst_req  <= '1';
        wait_cycles(1);
        burst_req  <= '0';

        wait until bus_burst = '1';
        wait_cycles(1);

        -- Beat 1 with 16-bit port indication
        bus_data_in <= X"AAAA0000";
        bus_dsack   <= "01";  -- 16-bit port
        wait_cycles(1);
        bus_dsack   <= "11";
        wait_cycles(1);

        -- Continue with remaining beats
        for i in 1 to 3 loop
            bus_data_in <= X"BBBB0000";
            bus_dsack   <= "01";
            wait_cycles(1);
            bus_dsack   <= "11";
            wait_cycles(1);
        end loop;

        wait until burst_done = '1';
        wait_cycles(1);

        ---------------------------------------------------------------
        -- All tests complete
        ---------------------------------------------------------------
        wait_cycles(5);
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);
        write(l, string'("All Burst Controller tests passed!"));
        writeline(output, l);
        write(l, string'("==========================================="));
        writeline(output, l);

        test_done <= true;
        wait;
    end process;

end architecture testbench;
