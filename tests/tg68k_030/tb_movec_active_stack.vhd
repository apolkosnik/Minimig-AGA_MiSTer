-- tb_movec_active_stack.vhd
-- Regression: MOVEC Dn,ISP must update A7 when ISP is the active supervisor stack.
-- Without this alias update, RTE pops SR/PC from stale A7 and returns incorrectly.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_movec_active_stack is
end entity;

architecture behavior of tb_movec_active_stack is
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

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
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
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",  -- 68030
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
        variable reached_return : boolean := false;
        variable reached_return_msp : boolean := false;
    begin
        -- Initialize memory to NOP
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset vectors: SSP=$0800, PC=$1000
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Program:
        --   MOVE.L #$00000900,D0
        --   MOVEC  D0,ISP
        --   RTE                  ; must pop frame from $0900 (active ISP/A7)
        mem(16#1000#/2) := x"203C";
        mem(16#1002#/2) := x"0000";
        mem(16#1004#/2) := x"0900";
        mem(16#1006#/2) := x"4E7B";
        mem(16#1008#/2) := x"0804";  -- MOVEC D0,ISP
        mem(16#100A#/2) := x"4E73";  -- RTE
        mem(16#100C#/2) := x"4E72";  -- STOP #$2700 (failure path if RTE didn't return)
        mem(16#100E#/2) := x"2700";

        -- Exception frame at $0900
        mem(16#0900#/2) := x"2700";  -- SR
        mem(16#0902#/2) := x"0000";  -- PC high
        mem(16#0904#/2) := x"1200";  -- PC low (success marker)
        mem(16#0906#/2) := x"0000";  -- Format $0

        -- Success marker
        mem(16#1200#/2) := x"4E72";  -- STOP #$2700
        mem(16#1202#/2) := x"2700";

        report "=== MOVEC active ISP -> A7 alias test ===" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1200" then
                reached_return := true;
                exit;
            end if;
        end loop;

        if reached_return then
            report "PASS: MOVEC Dn,ISP updated active A7; RTE popped frame from ISP" severity note;
        else
            report "FAIL: MOVEC Dn,ISP did not update active A7; RTE did not return via ISP frame" severity failure;
        end if;

        -- ============================================================
        -- Case 2: Active MSP alias update
        -- ============================================================
        for i in 0 to 8191 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset vectors: SSP=$0800, PC=$1000
        mem(0) := x"0000";
        mem(1) := x"0800";
        mem(2) := x"0000";
        mem(3) := x"1000";

        -- Program:
        --   MOVE.L #$00000A00,D1
        --   MOVEC  D1,MSP        ; preload MSP shadow
        --   MOVE.W #$3000,SR      ; supervisor M=1 => A7=MSP=$0A00
        --   MOVE.L #$00000B00,D0
        --   MOVEC  D0,MSP        ; active MSP write must update A7 to $0B00
        --   RTE                  ; must pop frame at $0B00
        mem(16#1000#/2) := x"223C";
        mem(16#1002#/2) := x"0000";
        mem(16#1004#/2) := x"0A00";
        mem(16#1006#/2) := x"4E7B";
        mem(16#1008#/2) := x"1803";  -- MOVEC D1,MSP
        mem(16#100A#/2) := x"46FC";
        mem(16#100C#/2) := x"3000";  -- MOVE #$3000,SR (S=1,M=1)
        mem(16#100E#/2) := x"203C";
        mem(16#1010#/2) := x"0000";
        mem(16#1012#/2) := x"0B00";
        mem(16#1014#/2) := x"4E7B";
        mem(16#1016#/2) := x"0803";  -- MOVEC D0,MSP (active)
        mem(16#1018#/2) := x"4E73";  -- RTE
        mem(16#101A#/2) := x"4E72";  -- STOP #$2700 (failure path)
        mem(16#101C#/2) := x"2700";

        -- Frame at stale MSP ($0A00) -> fail marker if A7 did NOT update
        mem(16#0A00#/2) := x"3000";
        mem(16#0A02#/2) := x"0000";
        mem(16#0A04#/2) := x"1400";
        mem(16#0A06#/2) := x"0000";

        -- Frame at new MSP ($0B00) -> success marker if A7 DID update
        mem(16#0B00#/2) := x"3000";
        mem(16#0B02#/2) := x"0000";
        mem(16#0B04#/2) := x"1300";
        mem(16#0B06#/2) := x"0000";

        mem(16#1300#/2) := x"4E72";  -- success STOP
        mem(16#1302#/2) := x"2700";
        mem(16#1400#/2) := x"4E72";  -- stale-stack STOP
        mem(16#1402#/2) := x"2700";

        report "=== MOVEC active MSP -> A7 alias test ===" severity note;
        reached_return_msp := false;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 18000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1300" then
                reached_return_msp := true;
                exit;
            elsif addr_out(15 downto 0) = x"1400" then
                exit;
            end if;
        end loop;

        if reached_return_msp then
            report "PASS: MOVEC Dn,MSP updated active A7; RTE popped frame from MSP" severity note;
        else
            report "FAIL: MOVEC Dn,MSP did not update active A7; RTE used stale MSP frame" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
