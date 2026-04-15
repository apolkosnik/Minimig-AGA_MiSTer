-- Precise cputest basic/jmp reproducer - traces all bus cycles
-- Registers from screenshot: D0=$B2, A1=$8B, A7=$420003FE, SR=$2008
-- Instruction: JMP ($65B2,SP) at $42050000 -> target $420069B0
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jmp_bus_trace is
end entity;

architecture behavior of tb_jmp_bus_trace is
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
    signal d_micro    : integer range 0 to 255;
    signal d_setopcode: std_logic;

    constant CLK_PERIOD : time := 10 ns;
    constant LOW_BASE   : integer := 16#00000000#;
    constant LOW_BYTES  : integer := 16#00010000#;
    constant HIGH_BASE  : integer := 16#42000000#;
    constant HIGH_BYTES : integer := 16#00100000#;

    type low_mem_t is array(0 to LOW_BYTES/2 - 1) of std_logic_vector(15 downto 0);
    type high_mem_t is array(0 to HIGH_BYTES/2 - 1) of std_logic_vector(15 downto 0);
    shared variable low_mem  : low_mem_t;
    shared variable high_mem : high_mem_t;
    signal test_done : boolean := false;
    signal cycle_count : integer := 0;
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
            debug_state=>d_state, debug_TG68_PC=>d_PC,
            debug_micro_state=>d_micro
        );

    -- Memory read mux
    data_in <= low_mem(to_integer(unsigned(addr_out(15 downto 1))))
               when addr_out(31 downto 16) = x"0000" else
               high_mem(to_integer(unsigned(addr_out(19 downto 1))))
               when addr_out(31 downto 20) = x"420" else
               x"4E71";

    -- Memory write with bus trace
    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' then
                cycle_count <= cycle_count + 1;
            end if;
            if busstate = "11" and nWr = '0' and nReset = '1' then
                report "WRITE @" & to_hstring(addr_out) &
                       " data=" & to_hstring(data_write) &
                       " UDS=" & std_logic'image(nUDS) &
                       " LDS=" & std_logic'image(nLDS) &
                       " cycle=" & integer'image(cycle_count)
                       severity note;
                if addr_out(31 downto 16) = x"0000" then
                    if nUDS = '0' then
                        low_mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        low_mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                elsif addr_out(31 downto 20) = x"420" then
                    if nUDS = '0' then
                        high_mem(to_integer(unsigned(addr_out(19 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        high_mem(to_integer(unsigned(addr_out(19 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
            -- Also trace reads from interesting addresses
            if busstate = "00" and nReset = '1' and not is_x(addr_out) then
                report "READ  @" & to_hstring(addr_out) &
                       " st=" & to_hstring("000000" & d_state) &
                       " ms=" & integer'image(d_micro) &
                       " PC=" & to_hstring(d_PC) &
                       " cycle=" & integer'image(cycle_count)
                       severity note;
            end if;
        end if;
    end process;

    test: process
        variable idx : integer;
    begin
        -- Initialize all memory to NOP
        for i in low_mem'range loop low_mem(i) := x"4E71"; end loop;
        for i in high_mem'range loop high_mem(i) := x"4E71"; end loop;

        -- Reset vectors: SSP=$42000800, PC=$42001000
        low_mem(0) := x"4200"; low_mem(1) := x"0800";
        low_mem(2) := x"4200"; low_mem(3) := x"1000";

        -- Illegal instruction vector ($10) -> handler at $42002000
        low_mem(16#10# / 2) := x"4200";
        low_mem(16#12# / 2) := x"2000";
        -- Trace vector ($24) -> handler at $42002100
        low_mem(16#24# / 2) := x"4200";
        low_mem(16#26# / 2) := x"2100";

        -- Illegal handler: STOP #$2700
        idx := (16#42002000# - HIGH_BASE) / 2;
        high_mem(idx) := x"4E72"; high_mem(idx+1) := x"2700";

        -- Trace handler: STOP #$2700
        idx := (16#42002100# - HIGH_BASE) / 2;
        high_mem(idx) := x"4E72"; high_mem(idx+1) := x"2700";

        -- Boot code at $42001000:
        -- Set up A7=$420003FE, then MOVE to SR, then JMP
        idx := (16#42001000# - HIGH_BASE) / 2;
        -- MOVEA.L #$420003FE,A7
        high_mem(idx)   := x"2E7C";
        high_mem(idx+1) := x"4200";
        high_mem(idx+2) := x"03FE";
        -- MOVE #$2008,SR  (S=1, N=1, no trace)
        high_mem(idx+3) := x"46FC";
        high_mem(idx+4) := x"2008";
        -- JMP to $42050000 (where the actual test instruction lives)
        high_mem(idx+5) := x"4EF9";
        high_mem(idx+6) := x"4205";
        high_mem(idx+7) := x"0000";

        -- Test instruction at $42050000: JMP ($65B2,SP)
        idx := (16#42050000# - HIGH_BASE) / 2;
        high_mem(idx)   := x"4EEF";
        high_mem(idx+1) := x"65B2";
        -- Words after JMP (prefetch targets):
        high_mem(idx+2) := x"2048"; -- MOVEA.L A0,A0
        high_mem(idx+3) := x"4AFC"; -- ILLEGAL

        -- Target at $420069B0 (=$420003FE + $65B2): MOVEA.L A0,A0 + ILLEGAL
        idx := (16#420069B0# - HIGH_BASE) / 2;
        high_mem(idx)   := x"2048"; -- MOVEA.L A0,A0
        high_mem(idx+1) := x"4AFC"; -- ILLEGAL

        report "=== JMP ($65B2,SP) bus trace test ===" severity note;
        report "A7=$420003FE, target=$420069B0" severity note;

        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Wait for STOP
        for i in 0 to 20000 loop
            wait until rising_edge(clk);
            if busstate = "01" then
                wait for 500 ns;
                exit;
            end if;
        end loop;

        -- Check where the exception frame went
        report "=== Memory state after test ===" severity note;
        -- SP=$420003FE, exception pushes 8 bytes (format $0): frame at $420003F6
        idx := (16#420003F6# - HIGH_BASE) / 2;
        report "Frame SR    @$420003F6 = " & to_hstring(high_mem(idx)) severity note;
        report "Frame PC_hi @$420003F8 = " & to_hstring(high_mem(idx+1)) severity note;
        report "Frame PC_lo @$420003FA = " & to_hstring(high_mem(idx+2)) severity note;
        report "Frame FV    @$420003FC = " & to_hstring(high_mem(idx+3)) severity note;

        test_done <= true;
        wait;
    end process;
end architecture;
