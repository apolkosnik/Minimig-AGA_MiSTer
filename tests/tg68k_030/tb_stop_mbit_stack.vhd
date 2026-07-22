-- tb_stop_mbit_stack.vhd
-- Regression: STOP #imm loads the complete immediate into SR (M68000 PRM,
-- STOP entry: "Immediate Data -> SR"). The S/M encoding of the new SR selects
-- USP/ISP/MSP as the active A7. STOP #$3000 executed with ISP active (M=0)
-- must therefore make MSP the active stack pointer (save old A7 to the ISP
-- shadow, load MSP into A7) exactly as MOVE-to-SR does. The kernel previously
-- performed the MSP/ISP swap only for exec(to_SR), never for the set_stop
-- (STOP) path, so STOP #$3000 wrongly left A7 on ISP and a7_is_msp=0.
--
-- Observation: after STOP #$3000 raises M, a level-7 interrupt resumes the CPU.
-- The interrupt clears M and switches to ISP, saving the (correctly MSP) active
-- A7 back to the MSP shadow. The handler reads the MSP shadow with MOVEC and
-- stores it. With the swap performed, the MSP shadow holds the MSP value
-- ($00000A00) that STOP loaded into A7; without it, the interrupt entry saved
-- the stale ISP-valued A7 ($00000900) into the MSP shadow instead.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_stop_mbit_stack is
end entity;

architecture behavior of tb_stop_mbit_stack is
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
        variable saw_handler  : boolean := false;
        variable done_seen    : boolean := false;
        variable msp_shadow   : std_logic_vector(31 downto 0);
    begin
        init_memory;

        -- Reset vectors: SSP=$0800, PC=$1000
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Level-7 autovector -> handler $1100
        mem(16#007C# / 2) := x"0000";
        mem(16#007E# / 2) := x"1100";

        -- Main program:
        --   MOVE.L #$00000A80,D1
        --   MOVEC  D1,MSP            ; MSP shadow = $00000A80 (page $0Axx)
        --   MOVE.L #$00000980,D0
        --   MOVEC  D0,ISP            ; ISP active, A7 = $00000980 (page $09xx), M=0
        --   MOVE.W #$2000,SR         ; S=1, M=0, I=0 (interrupts enabled)
        --   STOP   #$3000            ; S=1, M=1, I=0 -> A7 must become MSP
        -- resume:
        --   BRA.S resume
        -- MSP/ISP are placed mid-page ($0A80/$0980) so the interrupt throwaway
        -- frame push (a few words) cannot carry the saved value across a page
        -- boundary; the high byte ($0A vs $09) then cleanly identifies which
        -- stack STOP made active.
        mem(16#1000# / 2) := x"223C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0A80";
        mem(16#1006# / 2) := x"4E7B";
        mem(16#1008# / 2) := x"1803";
        mem(16#100A# / 2) := x"203C";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"0980";
        mem(16#1010# / 2) := x"4E7B";
        mem(16#1012# / 2) := x"0804";
        mem(16#1014# / 2) := x"46FC";
        mem(16#1016# / 2) := x"2000";
        mem(16#1018# / 2) := x"4E72";  -- STOP
        mem(16#101A# / 2) := x"3000";  --   #$3000
        mem(16#101C# / 2) := x"60FE";  -- BRA.S self

        -- Interrupt handler at $1100:
        --   MOVEC MSP,D0             ; read MSP shadow
        --   MOVE.L D0,$00001600
        --   MOVE.W #$600D,$00001608  ; done sentinel
        --   BRA.S self
        mem(16#1100# / 2) := x"4E7A";
        mem(16#1102# / 2) := x"0803";
        mem(16#1104# / 2) := x"23C0";
        mem(16#1106# / 2) := x"0000";
        mem(16#1108# / 2) := x"1600";
        mem(16#110A# / 2) := x"33FC";
        mem(16#110C# / 2) := x"600D";
        mem(16#110E# / 2) := x"0000";
        mem(16#1110# / 2) := x"1608";
        mem(16#1112# / 2) := x"60FE";  -- BRA.S self

        report "=== STOP #imm M-bit stack-swap test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Wait until the CPU has reached and is executing STOP at $1018.
        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1018" then
                exit;
            end if;
        end loop;

        -- Give STOP time to load SR and halt, then raise the level-7 interrupt.
        wait_cycles(8);
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
            report "FAIL: level-7 interrupt did not resume STOP / reach handler" severity failure;
        end if;

        -- Wait for the handler to publish the MSP shadow it read.
        for i in 0 to 8000 loop
            wait until rising_edge(clk);
            if mem(16#1608# / 2) = x"600D" then
                done_seen := true;
                exit;
            end if;
        end loop;

        if not done_seen then
            report "FAIL: handler did not complete MSP readout" severity failure;
        end if;

        msp_shadow := mem(16#1600# / 2) & mem(16#1602# / 2);
        report "MSP shadow after STOP #$3000 + interrupt = " &
               integer'image(to_integer(unsigned(msp_shadow))) &
               " (decimal; MSP page $0Axx = correct, ISP page $09xx = buggy)" severity note;

        if msp_shadow(15 downto 8) = x"0A" then
            report "PASS: STOP #$3000 made MSP the active A7 (M 0->1 swap performed; throwaway landed on MSP page $0Axx)" severity note;
        elsif msp_shadow(15 downto 8) = x"09" then
            report "FAIL: STOP #$3000 did NOT swap A7 to MSP - stale ISP-page ($09xx) value leaked into the MSP shadow" severity failure;
        else
            report "FAIL: unexpected MSP shadow " &
                   integer'image(to_integer(unsigned(msp_shadow))) &
                   " (expected MSP page $0Axx after STOP M 0->1 swap)" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
