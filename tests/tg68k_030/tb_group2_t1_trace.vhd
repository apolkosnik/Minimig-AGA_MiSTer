-- tb_group2_t1_trace.vhd
-- Settled MC68030 Group 2 trace tests for legal T1 trace mode cases.
-- Keeps only the T1 behavior that matches the Motorola manuals and the
-- cleaned core's current architectural behavior.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_group2_t1_trace is
end entity;

architecture behavior of tb_group2_t1_trace is
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
    signal IPL_sig    : std_logic_vector(2 downto 0) := "111";

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
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
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => IPL_sig,
            IPL_autovector => '1',
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            FC             => FC,
            longword       => open,
            nResetOut      => open,
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
            debug_SVmode        => open,
            debug_preSVmode     => open,
            debug_FlagsSR_S     => open,
            debug_changeMode    => open,
            debug_setopcode     => open,
            debug_exec_directSR => open,
            debug_exec_to_SR    => open,
            debug_pmove_dn_mode   => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 32767 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 32767 then
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
        variable v_pass_count : integer := 0;
        variable v_fail_count : integer := 0;

        variable v_stacked_pc    : std_logic_vector(31 downto 0);
        variable v_stacked_ia    : std_logic_vector(31 downto 0);
        variable v_format_word   : std_logic_vector(15 downto 0);
        variable v_format        : std_logic_vector(3 downto 0);
        variable v_vector        : std_logic_vector(11 downto 0);

        procedure wait_for_stop(timeout_cycles : integer := 6000) is
            variable idle_count : integer;
        begin
            idle_count := 0;
            for i in 0 to timeout_cycles loop
                wait until rising_edge(clk);
                if busstate = "01" then
                    idle_count := idle_count + 1;
                    if idle_count >= 10 then
                        return;
                    end if;
                else
                    idle_count := 0;
                end if;
            end loop;
            report "TIMEOUT waiting for STOP" severity error;
            v_fail_count := v_fail_count + 1;
        end procedure;

        procedure read_frame(sp_addr : unsigned(31 downto 0)) is
            variable idx : integer;
            variable v_pc_hi         : std_logic_vector(15 downto 0);
            variable v_pc_lo         : std_logic_vector(15 downto 0);
            variable v_instr_addr_hi : std_logic_vector(15 downto 0);
            variable v_instr_addr_lo : std_logic_vector(15 downto 0);
        begin
            idx             := to_integer(sp_addr(15 downto 1));
            v_pc_hi         := mem(idx + 1);
            v_pc_lo         := mem(idx + 2);
            v_format_word   := mem(idx + 3);
            v_instr_addr_hi := mem(idx + 4);
            v_instr_addr_lo := mem(idx + 5);
            v_stacked_pc    := v_pc_hi & v_pc_lo;
            v_stacked_ia    := v_instr_addr_hi & v_instr_addr_lo;
            v_format        := v_format_word(15 downto 12);
            v_vector        := v_format_word(11 downto 0);
        end procedure;

        procedure read_frame0(sp_addr : unsigned(31 downto 0)) is
            variable idx : integer;
            variable v_pc_hi : std_logic_vector(15 downto 0);
            variable v_pc_lo : std_logic_vector(15 downto 0);
        begin
            idx           := to_integer(sp_addr(15 downto 1));
            v_pc_hi       := mem(idx + 1);
            v_pc_lo       := mem(idx + 2);
            v_format_word := mem(idx + 3);
            v_stacked_pc  := v_pc_hi & v_pc_lo;
            v_stacked_ia  := (others => '0');
            v_format      := v_format_word(15 downto 12);
            v_vector      := v_format_word(11 downto 0);
        end procedure;

        procedure check_format(test_name : string; expected : std_logic_vector(3 downto 0)) is
        begin
            if v_format = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " format mismatch" severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_vector(test_name : string; expected : std_logic_vector(11 downto 0)) is
        begin
            if v_vector = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " vector mismatch" severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_pc(test_name : string; expected : std_logic_vector(31 downto 0)) is
        begin
            if v_stacked_pc = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " PC mismatch" severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_ia(test_name : string; expected : std_logic_vector(31 downto 0)) is
        begin
            if v_stacked_ia = expected then
                report "  PASS: " & test_name severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " instruction address mismatch" severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure init_memory is
        begin
            for i in 0 to 32767 loop
                mem(i) := x"4E71";
            end loop;
            mem(0) := x"0000";
            mem(1) := x"4000";
            mem(2) := x"0000";
            mem(3) := x"1000";
        end procedure;

        procedure setup_vector(vec_offset : integer; handler_addr : integer) is
        begin
            mem(vec_offset / 2)     := std_logic_vector(to_unsigned(handler_addr / 65536, 16));
            mem(vec_offset / 2 + 1) := std_logic_vector(to_unsigned(handler_addr mod 65536, 16));
        end procedure;

        procedure setup_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"2C4F";
            mem(handler_addr / 2 + 1) := x"4E72";
            mem(handler_addr / 2 + 2) := x"2700";
        end procedure;

        procedure do_reset is
        begin
            nReset  <= '0';
            IPL_sig <= "111";
            wait for 100 ns;
            nReset  <= '1';
            for i in 0 to 2000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1000" then
                    exit;
                end if;
            end loop;
        end procedure;

        procedure clear_stack is
        begin
            for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
                mem(i) := x"DEAD";
            end loop;
        end procedure;

    begin
        report "========================================" severity note;
        report "Group 2 T1 Trace Regression" severity note;
        report "MC68030 UM 8.1.12 settled T1 cases" severity note;
        report "========================================" severity note;

        report "" severity note;
        report "TEST 1: TRAP #5 with T1=1 (stacked trace)" severity note;
        init_memory;
        setup_vector(16#94#, 16#2200#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2200#);
        setup_handler(16#2100#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A700";
        mem(16#1004# / 2) := x"4E45";
        mem(16#1006# / 2) := x"4E71";
        clear_stack;
        do_reset;
        wait_for_stop;
        read_frame(x"00003FEC");
        check_format("T1: TRAP#5 trace frame format=$2", "0010");
        check_vector("T1: TRAP#5 trace vector=$024", x"024");
        check_pc("T1: TRAP#5 trace PC=$2200", x"00002200");
        check_ia("T1: TRAP#5 trace IA=$2200", x"00002200");
        read_frame0(x"00003FF8");
        check_format("T1: TRAP#5 frame format=$0", "0000");
        check_vector("T1: TRAP#5 vector=$094", x"094");
        check_pc("T1: TRAP#5 PC=$1006", x"00001006");

        report "" severity note;
        report "TEST 2: TRAPV with T1=1, V=1 (stacked trace)" severity note;
        init_memory;
        setup_vector(16#1C#, 16#2300#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2300#);
        setup_handler(16#2100#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A702";
        mem(16#1004# / 2) := x"4E76";
        mem(16#1006# / 2) := x"4E71";
        clear_stack;
        do_reset;
        wait_for_stop;
        read_frame(x"00003FE8");
        check_format("T2: TRAPV trace frame format=$2", "0010");
        check_vector("T2: TRAPV trace vector=$024", x"024");
        check_pc("T2: TRAPV trace PC=$2300", x"00002300");
        check_ia("T2: TRAPV trace IA=$2300", x"00002300");
        read_frame(x"00003FF4");
        check_format("T2: TRAPV frame format=$2", "0010");
        check_vector("T2: TRAPV vector=$01C", x"01C");
        check_pc("T2: TRAPV PC=$1006", x"00001006");
        check_ia("T2: TRAPV IA=$1004", x"00001004");

        report "" severity note;
        report "TEST 3: DIVS.W #0,D0 with T1=1 (stacked trace)" severity note;
        init_memory;
        setup_vector(16#14#, 16#2400#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2400#);
        setup_handler(16#2100#);
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";
        mem(16#1006# / 2) := x"46FC";
        mem(16#1008# / 2) := x"A700";
        mem(16#100A# / 2) := x"81FC";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"4E71";
        clear_stack;
        do_reset;
        wait_for_stop;
        read_frame(x"00003FE8");
        check_format("T3: DIV0 trace frame format=$2", "0010");
        check_vector("T3: DIV0 trace vector=$024", x"024");
        check_pc("T3: DIV0 trace PC=$2400", x"00002400");
        check_ia("T3: DIV0 trace IA=$2400", x"00002400");
        read_frame(x"00003FF4");
        check_format("T3: DIV0 frame format=$2", "0010");
        check_vector("T3: DIV0 vector=$014", x"014");
        check_pc("T3: DIV0 PC=$100E", x"0000100E");
        check_ia("T3: DIV0 IA=$100A", x"0000100A");

        report "" severity note;
        report "TEST 4: TRAPV with T1=1, V=0 (single trace only)" severity note;
        init_memory;
        setup_vector(16#1C#, 16#2300#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2300#);
        setup_handler(16#2100#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A700";
        mem(16#1004# / 2) := x"4E76";
        mem(16#1006# / 2) := x"4E71";
        clear_stack;
        do_reset;
        wait_for_stop;
        read_frame(x"00003FF4");
        check_format("T4: TRAPV no-trap trace frame format=$2", "0010");
        check_vector("T4: TRAPV no-trap trace vector=$024", x"024");
        check_pc("T4: TRAPV no-trap trace PC=$1006", x"00001006");
        check_ia("T4: TRAPV no-trap trace IA=$1004", x"00001004");

        report "" severity note;
        report "TEST 5: TRAPLT.W with T1=1 (stacked trace)" severity note;
        init_memory;
        setup_vector(16#1C#, 16#2300#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2300#);
        setup_handler(16#2100#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"A708";
        mem(16#1004# / 2) := x"5DFA";
        mem(16#1006# / 2) := x"0000";
        mem(16#1008# / 2) := x"4E71";
        clear_stack;
        do_reset;
        wait_for_stop;
        read_frame(x"00003FE8");
        check_format("T5: TRAPcc trace frame format=$2", "0010");
        check_vector("T5: TRAPcc trace vector=$024", x"024");
        check_pc("T5: TRAPcc trace PC=$2300", x"00002300");
        check_ia("T5: TRAPcc trace IA=$2300", x"00002300");
        read_frame(x"00003FF4");
        check_format("T5: TRAPcc frame format=$2", "0010");
        check_vector("T5: TRAPcc vector=$01C", x"01C");
        check_pc("T5: TRAPcc PC=$1008", x"00001008");
        check_ia("T5: TRAPcc IA=$1004", x"00001004");

        report "" severity note;
        report "========================================" severity note;
        report "RESULTS: " & integer'image(v_pass_count) & " passed, " &
               integer'image(v_fail_count) & " failed" severity note;
        report "========================================" severity note;
        if v_fail_count > 0 then
            report "SOME TESTS FAILED" severity error;
        else
            report "ALL TESTS PASSED" severity note;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
