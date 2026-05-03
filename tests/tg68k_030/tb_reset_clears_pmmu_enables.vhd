-- tb_reset_clears_pmmu_enables.vhd
-- Verifies that the RESET instruction preserves PMMU enable bits in this
-- board integration.
--
-- The core-local PMMU reset pulse is intentionally not driven by the RESET
-- instruction here because the board-level reset/autoconfig path relies on
-- the ROM RESET; JMP (A0) sequence not disturbing active PMMU state.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_reset_clears_pmmu_enables is
end entity;

architecture behavior of tb_reset_clears_pmmu_enables is
    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length / 4) - 1 loop
            nibble := value(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    signal clk          : std_logic := '0';
    signal nReset       : std_logic := '0';
    signal clkena_in    : std_logic := '1';
    signal data_in      : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write   : std_logic_vector(15 downto 0);
    signal addr_out     : std_logic_vector(31 downto 0);
    signal busstate     : std_logic_vector(1 downto 0);
    signal nWr          : std_logic;
    signal nUDS         : std_logic;
    signal nLDS         : std_logic;

    constant CLK_PERIOD : time := 10 ns;
    signal test_done    : boolean := false;

    constant TT0_INIT      : std_logic_vector(31 downto 0) := x"00FF8707";
    constant TT1_INIT      : std_logic_vector(31 downto 0) := x"00FF8707";
    constant TC_INIT       : std_logic_vector(31 downto 0) := x"81F09800";
    constant TT0_EXPECTED  : std_logic_vector(31 downto 0) := TT0_INIT;
    constant TT1_EXPECTED  : std_logic_vector(31 downto 0) := TT1_INIT;
    constant TC_EXPECTED   : std_logic_vector(31 downto 0) := TC_INIT;
    constant RESULT_ADDR   : integer := 16#3010#;

    type mem_array_t is array (0 to 32767) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        0 => x"0000", 1 => x"2000", -- SSP=$00002000
        2 => x"0000", 3 => x"0400", -- PC =$00000400

        -- $0400: MOVEA.L #$3000,A7
        16#200# => x"2E7C",
        16#201# => x"0000",
        16#202# => x"3000",

        -- $0406: PMOVE.L (A7),TT0
        16#203# => x"F017",
        16#204# => x"0800",

        -- $040A: MOVEA.L #$3004,A7
        16#205# => x"2E7C",
        16#206# => x"0000",
        16#207# => x"3004",

        -- $0410: PMOVE.L (A7),TT1
        16#208# => x"F017",
        16#209# => x"0C00",

        -- $0414: MOVEA.L #$3008,A7
        16#20A# => x"2E7C",
        16#20B# => x"0000",
        16#20C# => x"3008",

        -- $041A: PMOVE.L (A7),TC
        16#20D# => x"F017",
        16#20E# => x"4000",

        -- $041E: RESET
        16#20F# => x"4E70",

        -- $0420: MOVEA.L #$3010,A0
        16#210# => x"207C",
        16#211# => x"0000",
        16#212# => x"3010",

        -- $0426: PMOVE.L TT0,(A0)
        16#213# => x"F010",
        16#214# => x"0A00",

        -- $042A: PMOVE.L TT1,(4,A0)
        16#215# => x"F028",
        16#216# => x"0E00",
        16#217# => x"0004",

        -- $0430: PMOVE.L TC,(8,A0)
        16#218# => x"F028",
        16#219# => x"4200",
        16#21A# => x"0008",

        -- $0436: STOP #$2700
        16#21B# => x"4E72",
        16#21C# => x"2700",

        -- Data block at $3000
        16#1800# => x"00FF",
        16#1801# => x"8707",
        16#1802# => x"00FF",
        16#1803# => x"8707",
        16#1804# => x"81F0",
        16#1805# => x"9800",

        others => x"4E71"
    );

    impure function read_long(addr : integer) return std_logic_vector is
    begin
        return mem(addr / 2) & mem(addr / 2 + 1);
    end function;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 2,
            extAddr_Mode   => 2,
            MUL_Mode       => 2,
            DIV_Mode       => 2,
            BitField       => 2,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => "111",
            IPL_autovector => '1',
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            longword       => open,
            nResetOut      => open,
            FC             => open,
            clr_berr       => open,
            skipFetch      => open,
            regin_out      => open,
            CACR_out       => open,
            VBR_out        => open,
            cache_inv_req  => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr  => open,
            pmmu_reg_we    => open,
            pmmu_reg_re    => open,
            pmmu_reg_sel   => open,
            pmmu_reg_wdat  => open,
            pmmu_reg_part  => open,
            pmmu_addr_log  => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req  => open,
            pmmu_walker_we   => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack  => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode   => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))));

    mem_write: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                idx := to_integer(unsigned(addr_out(15 downto 1)));
                if idx <= mem'high then
                    if nUDS = '0' then
                        mem(idx)(15 downto 8) <= data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(idx)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable tt0_actual : std_logic_vector(31 downto 0);
        variable tt1_actual : std_logic_vector(31 downto 0);
        variable tc_actual  : std_logic_vector(31 downto 0);
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        nReset <= '0';
        wait for 80 ns;
        nReset <= '1';

        wait for 20 us;

        tt0_actual := read_long(RESULT_ADDR);
        tt1_actual := read_long(RESULT_ADDR + 4);
        tc_actual := read_long(RESULT_ADDR + 8);

        if tt0_actual = TT0_EXPECTED then
            report "PASS: RESET preserved TT0" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RESET TT0 readback expected=$" & slv_to_hex(TT0_EXPECTED) &
                   " got=$" & slv_to_hex(tt0_actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if tt1_actual = TT1_EXPECTED then
            report "PASS: RESET preserved TT1" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RESET TT1 readback expected=$" & slv_to_hex(TT1_EXPECTED) &
                   " got=$" & slv_to_hex(tt1_actual) severity error;
            fail_count := fail_count + 1;
        end if;

        if tc_actual = TC_EXPECTED then
            report "PASS: RESET preserved TC" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RESET TC readback expected=$" & slv_to_hex(TC_EXPECTED) &
                   " got=$" & slv_to_hex(tc_actual) severity error;
            fail_count := fail_count + 1;
        end if;

        test_done <= true;

        if fail_count = 0 then
            report "RESULT: " & integer'image(pass_count) & " passed, 0 failed" severity note;
        else
            assert false report "RESULT: " & integer'image(pass_count) & " passed, " &
                                 integer'image(fail_count) & " failed" severity failure;
        end if;
        wait;
    end process;
end architecture;
