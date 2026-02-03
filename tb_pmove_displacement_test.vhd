-- tb_pmove_displacement_test.vhd
-- Focused test for PMOVE (d16,An) displacement mode
-- Tests BUG #191 fix

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_displacement_test is
end entity;

architecture behavioral of tb_pmove_displacement_test is
    signal clk          : std_logic := '0';
    signal nReset       : std_logic := '0';
    signal clkena_in    : std_logic := '1';
    signal data_in      : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write   : std_logic_vector(15 downto 0);
    signal addr_out     : std_logic_vector(31 downto 0);
    signal busstate     : std_logic_vector(1 downto 0);
    signal nWr          : std_logic;
    signal nUDS, nLDS   : std_logic;
    signal FC           : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    signal test_done    : boolean := false;

    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        -- Reset vectors
        0 => x"0000", 1 => x"2000",  -- SSP = $2000
        2 => x"0000", 3 => x"0500",  -- PC = $500

        -- Test program
        16#280# => x"41F9", 16#281# => x"0000", 16#282# => x"1000",  -- LEA $1000,A0
        16#283# => x"7E12",  -- MOVEQ #$12,D7
        
        -- Simple (An) mode first to verify baseline
        16#284# => x"F010",  -- PMOVE (A0),TC
        16#285# => x"4210",  -- Extension: TC, (An) mode
        
        -- Now test (d16,An) mode - BUG #191 test case
        16#286# => x"F010",  -- PMOVE (8,A0),TC
        16#287# => x"4228",  -- Extension: TC, (d16,An) mode
        16#288# => x"0008",  -- Displacement: +8
        
        -- Another (An) mode to verify we can continue
        16#289# => x"F010",  -- PMOVE (A0),TC
        16#28A# => x"4210",  -- Extension: TC, (An) mode
        
        -- STOP
        16#28B# => x"4E72", 16#28C# => x"2700",

        -- Data area
        16#800# => x"1234", 16#801# => x"5678",  -- TC value at $1000
        16#804# => x"ABCD", 16#805# => x"EF00",  -- TC value at $1008 (A0+8)

        others => x"4E71"
    );

    signal pc_at_508 : boolean := false;
    signal pc_at_50C : boolean := false;
    signal pc_at_512 : boolean := false;
    signal pc_at_516 : boolean := false;

begin
    clk_process: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    dut: entity work.TG68KdotC_Kernel
        generic map(SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2,
                    MUL_Mode => 2, DIV_Mode => 2, BitField => 2,
                    MUL_Hardware => 1, BarrelShifter => 2)
        port map(clk => clk, nReset => nReset, clkena_in => clkena_in,
                 data_in => data_in, IPL => "111", IPL_autovector => '1',
                 CPU => "11", addr_out => addr_out, data_write => data_write,
                 nWr => nWr, nUDS => nUDS, nLDS => nLDS, busstate => busstate, FC => FC,
                 pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open,
                 pmmu_reg_wdat => open, pmmu_reg_part => open,
                 pmmu_addr_log => open, pmmu_addr_phys => open,
                 pmmu_cache_inhibit => open, cache_op_addr => open,
                 pmmu_walker_req => open, pmmu_walker_we => open,
                 pmmu_walker_addr => open, pmmu_walker_wdat => open,
                 pmmu_walker_ack => '0', pmmu_walker_data => (others => '0'),
                 pmmu_walker_berr => '0', debug_SVmode => open,
                 debug_preSVmode => open, debug_FlagsSR_S => open,
                 debug_changeMode => open, debug_setopcode => open);

    data_in <= mem(to_integer(unsigned(addr_out(14 downto 1))));

    pc_tracker: process(clk)
    begin
        if rising_edge(clk) and busstate = "00" and FC(1) = '1' then
            case to_integer(unsigned(addr_out)) is
                when 16#500# => report "FETCH: LEA $1000,A0" severity note;
                when 16#506# => report "FETCH: MOVEQ" severity note;
                when 16#508# =>
                    pc_at_508 <= true;
                    report "FETCH at PC=$508: PMOVE (A0),TC - baseline test" severity note;
                when 16#50C# =>
                    pc_at_50C <= true;
                    if pc_at_508 then
                        report "PASS: PC=$508->$50C (+4). FETCH: PMOVE (8,A0),TC - BUG #191 TEST" severity note;
                    else
                        report "ERROR: Reached $50C without hitting $508!" severity error;
                    end if;
                when 16#512# =>
                    pc_at_512 <= true;
                    if pc_at_50C then
                        report "PASS: PC=$50C->$512 (+6). BUG #191 FIXED! FETCH: PMOVE (A0),TC" severity note;
                    else
                        report "ERROR: Reached $512 without hitting $50C!" severity error;
                    end if;
                when 16#516# =>
                    pc_at_516 <= true;
                    if pc_at_512 then
                        report "PASS: PC=$512->$516 (+4). FETCH: STOP" severity note;
                    end if;
                when 16#518# =>
                    report "PASS: All tests completed successfully!" severity note;
                when others => null;
            end case;
        end if;
    end process;

    test_monitor: process
    begin
        report "=============================================" severity note;
        report "PMOVE (d16,An) Displacement Mode Test" severity note;
        report "Testing BUG #191 fix" severity note;
        report "=============================================" severity note;

        nReset <= '0'; wait for CLK_PERIOD * 5; nReset <= '1';
        wait for CLK_PERIOD * 10000;

        report "" severity note;
        report "=============================================" severity note;
        if pc_at_508 and pc_at_50C and pc_at_512 and pc_at_516 then
            report "*** ALL TESTS PASSED ***" severity note;
            report "BUG #191 FIX VERIFIED" severity note;
        elsif pc_at_508 and pc_at_50C and not pc_at_512 then
            report "*** TEST FAILED - HUNG AT (d16,An) MODE ***" severity error;
            report "BUG #191 FIX NOT WORKING" severity error;
        else
            report "*** TEST INCOMPLETE ***" severity warning;
        end if;
        report "=============================================" severity note;

        test_done <= true;
        wait;
    end process;

end behavioral;
