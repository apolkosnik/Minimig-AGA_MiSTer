-- tb_rte_format_a_replay.vhd
-- Regression: MC68030 RTE from a Format $A LASTWRITE data-fault frame must
-- replay the saved write once using the stacked fault address, size, and FC.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rte_format_a_replay is
end entity;

architecture behavior of tb_rte_format_a_replay is
    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);
    signal FC         : std_logic_vector(2 downto 0);

    constant CLK_PERIOD  : time := 10 ns;
    constant STACK_BASE  : integer := 16#1FE0#;
    constant FAULT_ADDR  : integer := 16#1301#;
    constant TARGET_WORD : integer := 16#1300# / 2;

    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal replay_write_seen : std_logic := '0';
    signal replay_fc_seen    : std_logic_vector(2 downto 0) := (others => '0');
    signal test_done         : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            FC => FC,
            longword => open,
            nResetOut => open,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 8191 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 8191 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;

                if addr_out(15 downto 0) = std_logic_vector(to_unsigned(FAULT_ADDR, 16)) then
                    replay_write_seen <= '1';
                    replay_fc_seen <= FC;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable reached_return : boolean;
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset vectors: SSP=$2000, PC=$1000.
        mem(0) := x"0000";
        mem(1) := x"2000";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- MOVEA.L #STACK_BASE,A7; RTE.
        mem(16#1000# / 2) := x"2E7C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := std_logic_vector(to_unsigned(STACK_BASE, 16));
        mem(16#1006# / 2) := x"4E73";

        -- Return target.
        mem(16#1200# / 2) := x"4E72";
        mem(16#1202# / 2) := x"2700";

        -- Target byte starts as $55 and must become $A5 on the low byte.
        mem(TARGET_WORD) := x"5555";

        -- Format $A frame:
        -- $00 SR, $02/$04 PC, $06 format/vector
        -- $08 state1/SSW, $10 fault address, $18 data output buffer.
        mem(STACK_BASE / 2 + 0)  := x"2700";
        mem(STACK_BASE / 2 + 1)  := x"0000";
        mem(STACK_BASE / 2 + 2)  := x"1200";
        mem(STACK_BASE / 2 + 3)  := x"A008";
        mem(STACK_BASE / 2 + 4)  := x"0100"; -- state1 LASTWRITE
        mem(STACK_BASE / 2 + 5)  := x"0311"; -- DF, write, byte, FC=user-data
        mem(STACK_BASE / 2 + 6)  := x"0000";
        mem(STACK_BASE / 2 + 7)  := x"0000";
        mem(STACK_BASE / 2 + 8)  := x"0000";
        mem(STACK_BASE / 2 + 9)  := std_logic_vector(to_unsigned(FAULT_ADDR, 16));
        mem(STACK_BASE / 2 + 10) := x"0000";
        mem(STACK_BASE / 2 + 11) := x"0000";
        mem(STACK_BASE / 2 + 12) := x"1122";
        mem(STACK_BASE / 2 + 13) := x"33A5";
        mem(STACK_BASE / 2 + 14) := x"0000";
        mem(STACK_BASE / 2 + 15) := x"0000";

        wait for 100 ns;
        nReset <= '1';

        reached_return := false;
        for i in 0 to 5000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1200" then
                reached_return := true;
                for j in 0 to 20 loop
                    wait until rising_edge(clk);
                end loop;
                exit;
            end if;
        end loop;

        assert reached_return
            report "FAIL: RTE did not return to stacked PC after Format $A replay"
            severity failure;
        assert replay_write_seen = '1'
            report "FAIL: Format $A LASTWRITE RTE did not replay the saved write"
            severity failure;
        assert replay_fc_seen = "001"
            report "FAIL: Format $A replay did not use stacked user-data FC"
            severity failure;
        assert mem(TARGET_WORD) = x"55A5"
            report "FAIL: Format $A replay target word was not updated to $55A5"
            severity failure;

        report "PASS: Format $A LASTWRITE RTE replay wrote byte with stacked FC" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
