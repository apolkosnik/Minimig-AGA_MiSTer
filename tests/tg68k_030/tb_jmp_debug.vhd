-- Minimal debug testbench to trace JMP (d16,SP) execution with trace
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jmp_debug is
end entity;

architecture behavior of tb_jmp_debug is
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
    signal d_state    : std_logic_vector(1 downto 0);
    signal d_PC       : std_logic_vector(31 downto 0);
    signal d_exe_pc   : std_logic_vector(31 downto 0);
    signal d_dwr_tmp  : std_logic_vector(31 downto 0);
    signal d_micro    : integer range 0 to 255;
    signal d_setopcode: std_logic;

    constant CLK_PERIOD : time := 10 ns;

    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(SR_Read=>2, VBR_Stackframe=>1, extAddr_Mode=>1, MUL_Hardware=>1, BarrelShifter=>2)
        port map(
            clk=>clk, nReset=>nReset, clkena_in=>clkena_in,
            data_in=>data_in, IPL=>"111", IPL_autovector=>'1', berr=>'0', CPU=>"10",
            addr_out=>addr_out, data_write=>data_write, nWr=>nWr, nUDS=>nUDS, nLDS=>nLDS,
            busstate=>busstate, FC=>FC,
            longword=>open, nResetOut=>open, clr_berr=>open, skipFetch=>open,
            regin_out=>open, CACR_out=>open, VBR_out=>open,
            cache_inv_req=>open, cache_op_scope=>open, cache_op_cache=>open, cache_op_addr=>open,
            pmmu_reg_we=>open, pmmu_reg_re=>open, pmmu_reg_sel=>open,
            pmmu_reg_wdat=>open, pmmu_reg_part=>open,
            pmmu_addr_log=>open, pmmu_addr_phys=>open, pmmu_cache_inhibit=>open,
            pmmu_walker_req=>open, pmmu_walker_we=>open, pmmu_walker_addr=>open,
            pmmu_walker_wdat=>open, pmmu_walker_ack=>'0',
            pmmu_walker_data=>(others=>'0'), pmmu_walker_berr=>'0',
            debug_SVmode=>open, debug_preSVmode=>open, debug_FlagsSR_S=>open,
            debug_changeMode=>open, debug_setopcode=>d_setopcode,
            debug_exec_directSR=>open, debug_exec_to_SR=>open,
            debug_pmove_dn_mode=>open, debug_pmove_dn_regnum=>open,
            debug_state=>d_state, debug_TG68_PC=>d_PC, debug_exe_PC=>d_exe_pc,
            debug_data_write_tmp=>d_dwr_tmp, debug_micro_state=>d_micro
        );

    data_in <= mem(to_integer(unsigned(addr_out(14 downto 1))))
               when to_integer(unsigned(addr_out(14 downto 1))) <= 16383 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(14 downto 1))) <= 16383 then
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(14 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(14 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Monitor bus activity for analysis (only after reset)
    monitor: process(clk)
    begin
        if rising_edge(clk) and nReset = '1' then
            if busstate /= "01" and not is_x(d_PC) and not is_x(addr_out) then
                report "BUS: st=" & integer'image(to_integer(unsigned(d_state))) &
                       " ms=" & integer'image(d_micro) &
                       " PC=$" & to_hstring(d_PC) &
                       " addr=$" & to_hstring(addr_out) &
                       " dwr=$" & to_hstring(d_dwr_tmp) &
                       " exe=$" & to_hstring(d_exe_pc) &
                       " bs=" & integer'image(to_integer(unsigned(busstate))) &
                       " wr=" & std_logic'image(nWr) &
                       " sop=" & std_logic'image(d_setopcode)
                       severity note;
            end if;
        end if;
    end process;

    test: process
    begin
        -- Initialize memory
        for i in 0 to 16383 loop
            mem(i) := x"4E71";
        end loop;

        -- Reset vectors
        mem(0) := x"0000"; mem(1) := x"0800";  -- SSP
        mem(2) := x"0000"; mem(3) := x"1000";  -- PC

        -- Trace vector at $24 -> handler at $2000
        mem(16#24# / 2) := x"0000";
        mem(16#26# / 2) := x"2000";
        -- Illegal vector at $10 -> handler at $2100
        mem(16#10# / 2) := x"0000";
        mem(16#12# / 2) := x"2100";

        -- Handler at $2000: STOP #$2700
        mem(16#2000# / 2) := x"4E72";
        mem(16#2002# / 2) := x"2700";
        -- Handler at $2100: STOP #$2700
        mem(16#2100# / 2) := x"4E72";
        mem(16#2102# / 2) := x"2700";

        -- Boot code at $1000:
        -- MOVEA.L #$0400,A7 (set SP=$0400)
        mem(16#1000# / 2) := x"2E7C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0400";
        -- MOVE #$A000,SR (supervisor, T1=1)
        mem(16#1006# / 2) := x"46FC";
        mem(16#1008# / 2) := x"A000";
        -- JMP ($0200,SP) = JMP ($0200+$0400) = JMP $0600
        mem(16#100A# / 2) := x"4EEF";
        mem(16#100C# / 2) := x"0200";

        -- Target at $0600: MOVEA.L A0,A0 + ILLEGAL
        mem(16#0600# / 2) := x"2048";
        mem(16#0602# / 2) := x"4AFC";

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Wait for STOP or timeout
        for i in 0 to 5000 loop
            wait until rising_edge(clk);
            if busstate = "01" then
                -- Check if idle for a while
                wait for 200 ns;
                exit;
            end if;
        end loop;

        -- Read trace frame at SP
        -- SP should be $0400 - 12 = $03F4 for format 2
        report "=== TRACE FRAME ===" severity note;
        report "SP-12: SR    = " & integer'image(to_integer(unsigned(mem(16#03F4# / 2)))) severity note;
        report "SP-10: PC_hi = " & integer'image(to_integer(unsigned(mem(16#03F6# / 2)))) severity note;
        report "SP-8:  PC_lo = " & integer'image(to_integer(unsigned(mem(16#03F8# / 2)))) severity note;
        report "SP-6:  FV    = " & integer'image(to_integer(unsigned(mem(16#03FA# / 2)))) severity note;
        report "SP-4:  IA_hi = " & integer'image(to_integer(unsigned(mem(16#03FC# / 2)))) severity note;
        report "SP-2:  IA_lo = " & integer'image(to_integer(unsigned(mem(16#03FE# / 2)))) severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
