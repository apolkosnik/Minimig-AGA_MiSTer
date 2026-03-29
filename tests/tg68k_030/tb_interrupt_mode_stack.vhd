-- tb_interrupt_mode_stack.vhd
-- Regression: after a real hardware interrupt, an RTE back to supervisor M=1
-- must make MSP active again so a following RTE pops from MSP, not the older
-- interrupt-context ISP frame.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_interrupt_mode_stack is
end entity;

architecture behavior of tb_interrupt_mode_stack is
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
    signal ipl_sig    : std_logic_vector(2 downto 0) := "111";

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;

    procedure init_memory is
    begin
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;
    end procedure;

    procedure wait_cycles(count : natural) is
    begin
        for i in 1 to count loop
            wait until rising_edge(clk);
        end loop;
    end procedure;
begin
    clk <= not clk after CLK_PERIOD/2 when not test_done;

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
            IPL => ipl_sig,
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
            end if;
        end if;
    end process;

    test: process
        variable saw_handler       : boolean := false;
        variable saw_nested_return : boolean := false;
        variable success_seen      : boolean := false;
        variable fail_seen         : boolean := false;
    begin
        init_memory;

        -- Reset vectors: SSP=$0800, PC=$1000
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Level-7 autovector -> $1100
        mem(16#007C# / 2) := x"0000";
        mem(16#007E# / 2) := x"1100";

        -- Main program:
        --   MOVE.L #$00000A00,D1
        --   MOVEC  D1,MSP
        --   MOVE.L #$00000900,D0
        --   MOVEC  D0,ISP
        --   MOVE.W #$2000,SR      ; enable interrupts, stay supervisor M=0
        -- loop:
        --   BRA.S  loop
        mem(16#1000# / 2) := x"223C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0A00";
        mem(16#1006# / 2) := x"4E7B";
        mem(16#1008# / 2) := x"1803";
        mem(16#100A# / 2) := x"203C";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"0900";
        mem(16#1010# / 2) := x"4E7B";
        mem(16#1012# / 2) := x"0804";
        mem(16#1014# / 2) := x"46FC";
        mem(16#1016# / 2) := x"2000";
        mem(16#1018# / 2) := x"60FE";

        -- Interrupt handler at $1100:
        --   Patch the original interrupt frame at $08F8 to return to $1300
        --   Push a nested format-$0 frame that returns to $1200 with SR=$3000
        --   RTE
        mem(16#1100# / 2) := x"31FC";
        mem(16#1102# / 2) := x"0000";
        mem(16#1104# / 2) := x"08FA";
        mem(16#1106# / 2) := x"31FC";
        mem(16#1108# / 2) := x"1300";
        mem(16#110A# / 2) := x"08FC";
        mem(16#110C# / 2) := x"3F3C";
        mem(16#110E# / 2) := x"0000";
        mem(16#1110# / 2) := x"3F3C";
        mem(16#1112# / 2) := x"1200";
        mem(16#1114# / 2) := x"3F3C";
        mem(16#1116# / 2) := x"0000";
        mem(16#1118# / 2) := x"3F3C";
        mem(16#111A# / 2) := x"3000";
        mem(16#111C# / 2) := x"4E73";

        -- Code reached after nested RTE to supervisor M=1:
        --   RTE
        -- Per the MC68030 manuals, WinUAE, and wf68k30L, S=1/M=1 makes MSP
        -- the active stack pointer again. The second RTE must therefore return
        -- via the MSP frame at $1400, not the older interrupt-context ISP frame
        -- patched to $1300.
        mem(16#1200# / 2) := x"4E73";

        mem(16#1300# / 2) := x"4E72";
        mem(16#1302# / 2) := x"2700";
        mem(16#1400# / 2) := x"4E72";
        mem(16#1402# / 2) := x"2700";

        -- Expected frame on MSP after RTE restores supervisor M=1.
        mem(16#0A00# / 2) := x"3000";
        mem(16#0A02# / 2) := x"0000";
        mem(16#0A04# / 2) := x"1400";
        mem(16#0A06# / 2) := x"0000";

        report "=== interrupt-context RTE to supervisor M=1 uses MSP test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Wait for the main loop with interrupts enabled, then trigger a level-7 autovector.
        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1018" then
                exit;
            end if;
        end loop;

        wait_cycles(4);
        ipl_sig <= "000";

        for i in 0 to 4000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1100" then
                saw_handler := true;
                exit;
            end if;
        end loop;
        ipl_sig <= "111";

        if not saw_handler then
            report "FAIL: level-7 autovector interrupt handler was not reached" severity failure;
        end if;

        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1200" then
                saw_nested_return := true;
            elsif addr_out(15 downto 0) = x"1400" then
                success_seen := true;
                exit;
            elsif addr_out(15 downto 0) = x"1300" then
                fail_seen := true;
                exit;
            end if;
        end loop;

        if not saw_nested_return then
            report "FAIL: nested RTE did not return to supervisor M=1 code at $1200" severity failure;
        elsif fail_seen then
            report "FAIL: post-RTE stack selection stayed on the older ISP interrupt frame" severity failure;
        elsif not success_seen then
            report "FAIL: post-interrupt RTE did not return through the MSP frame" severity failure;
        else
            report "PASS: RTE to supervisor M=1 switched active stack back to MSP" severity note;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
