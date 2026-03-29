-- tb_chk_long_odd_addr.vhd
-- Verify that CHK.L with a memory source at an odd data address still raises
-- vector 6 on MC68020/030 instead of being misclassified as vector 3.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_chk_long_odd_addr is
end entity;

architecture behavior of tb_chk_long_odd_addr is
    signal clk         : std_logic := '0';
    signal nReset      : std_logic := '0';
    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0);
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal busstate    : std_logic_vector(1 downto 0);
    signal FC          : std_logic_vector(2 downto 0);
    signal dbg_oddout  : std_logic;
    signal dbg_addrerr : std_logic;
    signal dbg_make_berr : std_logic;
    signal dbg_opcode  : std_logic_vector(15 downto 0);
    signal dbg_pc      : std_logic_vector(31 downto 0);
    signal dbg_decodeopc : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    type mem_array_t is array (0 to 65535) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done : boolean := false;
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
            clk                   => clk,
            nReset                => nReset,
            clkena_in             => clkena_in,
            data_in               => data_in,
            IPL                   => "111",
            IPL_autovector        => '1',
            berr                  => '0',
            CPU                   => "10",
            addr_out              => addr_out,
            data_write            => data_write,
            nWr                   => nWr,
            nUDS                  => nUDS,
            nLDS                  => nLDS,
            busstate              => busstate,
            FC                    => FC,
            longword              => open,
            nResetOut             => open,
            clr_berr              => open,
            skipFetch             => open,
            regin_out             => open,
            CACR_out              => open,
            VBR_out               => open,
            cache_inv_req         => open,
            cache_op_scope        => open,
            cache_op_cache        => open,
            cache_op_addr         => open,
            pmmu_reg_we           => open,
            pmmu_reg_re           => open,
            pmmu_reg_sel          => open,
            pmmu_reg_wdat         => open,
            pmmu_reg_part         => open,
            pmmu_addr_log         => open,
            pmmu_addr_phys        => open,
            pmmu_cache_inhibit    => open,
            pmmu_walker_req       => open,
            pmmu_walker_we        => open,
            pmmu_walker_addr      => open,
            pmmu_walker_wdat      => open,
            pmmu_walker_ack       => '0',
            pmmu_walker_data      => (others => '0'),
            pmmu_walker_berr      => '0',
            debug_oddout          => dbg_oddout,
            debug_trap_addr_error => dbg_addrerr,
            debug_make_berr       => dbg_make_berr,
            debug_opcode          => dbg_opcode,
            debug_tg68_pc         => dbg_pc,
            debug_decodeopc       => dbg_decodeopc,
            debug_SVmode          => open,
            debug_preSVmode       => open,
            debug_FlagsSR_S       => open,
            debug_changeMode      => open,
            debug_setopcode       => open,
            debug_exec_directSR   => open,
            debug_exec_to_SR      => open,
            debug_pmove_dn_mode   => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(16 downto 1))))
        when to_integer(unsigned(addr_out(16 downto 1))) <= 65535 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(16 downto 1))) <= 65535 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(16 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(16 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable saw_vec3 : boolean;
        variable saw_vec6 : boolean;
        variable saw_stop : boolean;
        variable saw_addr : boolean;
        variable fault_addr : integer;

        procedure init_memory is
            variable idx : integer;
        begin
            for i in 0 to 65535 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := x"0000";
            mem(1) := x"4000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Vector 3: address error
            mem(16#0C# / 2) := x"0000";
            mem(16#0C# / 2 + 1) := x"3000";
            -- Vector 6: CHK
            mem(16#18# / 2) := x"0000";
            mem(16#18# / 2 + 1) := x"3200";

            mem(16#3000# / 2) := x"4E72";
            mem(16#3002# / 2) := x"2700";
            mem(16#3200# / 2) := x"4E72";
            mem(16#3202# / 2) := x"2700";

            idx := 16#1000# / 2;
            mem(idx)     := x"227C"; -- MOVEA.L #$00002001,A1
            mem(idx + 1) := x"0000";
            mem(idx + 2) := x"2001";
            mem(idx + 3) := x"203C"; -- MOVE.L #$000001C0,D0
            mem(idx + 4) := x"0000";
            mem(idx + 5) := x"01C0";
            mem(idx + 6) := x"4119"; -- CHK.L (A1)+,D0
            mem(idx + 7) := x"4E72"; -- STOP #$2700 (must not be reached)
            mem(idx + 8) := x"2700";

            -- Bytes at $2001..$2004 = 00 00 00 79, so D0=$01C0 must trip CHK.
            mem(16#2000# / 2) := x"AA00";
            mem(16#2002# / 2) := x"0000";
            mem(16#2004# / 2) := x"7900";
        end procedure;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        report "=== CHK.L odd source address test ===" severity note;
        init_memory;

        saw_vec3 := false;
        saw_vec6 := false;
        saw_stop := false;
        saw_addr := false;
        fault_addr := -1;

        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';

        for i in 1 to 3000 loop
            wait until rising_edge(clk);

            if busstate = "10" and to_integer(unsigned(addr_out)) = 16#0C# then
                saw_vec3 := true;
            end if;
            if busstate = "10" and to_integer(unsigned(addr_out)) = 16#18# then
                saw_vec6 := true;
            end if;
            if dbg_decodeopc = '1' and dbg_opcode = x"4E72" and
               to_integer(unsigned(dbg_pc)) = 16#1010# then
                saw_stop := true;
                exit;
            end if;
            if busstate = "00" and to_integer(unsigned(addr_out)) = 16#3000# then
                exit;
            end if;
            if busstate = "00" and to_integer(unsigned(addr_out)) = 16#3200# then
                exit;
            end if;
            if busstate = "10" and to_integer(unsigned(addr_out)) = 16#2001# then
                saw_addr := true;
                fault_addr := 16#2001#;
            end if;
        end loop;

        if saw_vec6 and not saw_vec3 and not saw_stop then
            report "PASS: CHK.L odd source address raised vector 6 (CHK)" severity note;
        elsif saw_vec3 then
            report "FAIL: CHK.L odd source address raised vector 3 (address error) instead of vector 6" severity error;
        elsif saw_stop then
            report "FAIL: CHK.L odd source address fell through to STOP instead of trapping" severity error;
        elsif saw_addr then
            report "FAIL: CHK.L attempted data read at odd address $" &
                   integer'image(fault_addr) & " without taking vector 6" severity error;
        else
            report "FAIL: timeout waiting for CHK.L odd source address result" severity error;
        end if;

        report "=== Test complete ===" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
