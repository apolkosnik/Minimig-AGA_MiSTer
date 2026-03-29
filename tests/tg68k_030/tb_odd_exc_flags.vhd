-- tb_odd_exc_flags.vhd
-- Direct MC68030 exception-frame flag coverage for the CHK and DIV cases
-- behind WinUAE cputest ODD_EXC.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_odd_exc_flags is
end entity;

architecture behavior of tb_odd_exc_flags is
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
        variable pass_count  : integer := 0;
        variable fail_count  : integer := 0;
        variable stacked_sr  : std_logic_vector(15 downto 0);
        variable stacked_pc  : std_logic_vector(31 downto 0);
        variable stacked_ia  : std_logic_vector(31 downto 0);
        variable format_word : std_logic_vector(15 downto 0);
        variable vector_word : std_logic_vector(11 downto 0);

        procedure wait_for_stop(timeout_cycles : integer := 6000) is
            variable idle_count : integer := 0;
        begin
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

            report "FAIL: timeout waiting for STOP" severity error;
            fail_count := fail_count + 1;
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

        procedure clear_stack is
        begin
            for i in 16#3FC0# / 2 to 16#4000# / 2 - 1 loop
                mem(i) := x"DEAD";
            end loop;
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
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
            for i in 0 to 2000 loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure read_frame(sp_addr : integer) is
            variable idx   : integer;
            variable pc_hi : std_logic_vector(15 downto 0);
            variable pc_lo : std_logic_vector(15 downto 0);
            variable ia_hi : std_logic_vector(15 downto 0);
            variable ia_lo : std_logic_vector(15 downto 0);
        begin
            idx := sp_addr / 2;
            stacked_sr  := mem(idx);
            pc_hi       := mem(idx + 1);
            pc_lo       := mem(idx + 2);
            format_word := mem(idx + 3);
            ia_hi       := mem(idx + 4);
            ia_lo       := mem(idx + 5);
            stacked_pc  := pc_hi & pc_lo;
            stacked_ia  := ia_hi & ia_lo;
            vector_word := format_word(11 downto 0);
        end procedure;

        procedure check_frame(
            test_name : string;
            expected_sr : std_logic_vector(15 downto 0);
            expected_vector : std_logic_vector(11 downto 0);
            expected_pc : std_logic_vector(31 downto 0);
            expected_ia : std_logic_vector(31 downto 0)
        ) is
        begin
            read_frame(16#3FF4#);

            if stacked_sr = expected_sr then
                report "PASS: " & test_name & " saved SR" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " saved SR mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if format_word(15 downto 12) = "0010" and vector_word = expected_vector then
                report "PASS: " & test_name & " format/vector" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " format/vector mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if stacked_pc = expected_pc then
                report "PASS: " & test_name & " stacked PC" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " stacked PC mismatch" severity error;
                fail_count := fail_count + 1;
            end if;

            if stacked_ia = expected_ia then
                report "PASS: " & test_name & " instruction address" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & test_name & " instruction address mismatch" severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;
    begin
        report "=== MC68030 ODD_EXC CHK/DIV Flag Coverage ===" severity note;

        report "=== Test 1: CHK.W negative destination ===" severity note;
        init_memory;
        clear_stack;
        setup_vector(16#18#, 16#2200#);
        setup_handler(16#2200#);
        mem(16#1000# / 2) := x"323C";
        mem(16#1002# / 2) := x"7FFF";
        mem(16#1004# / 2) := x"70FF";
        mem(16#1006# / 2) := x"4181";
        mem(16#1008# / 2) := x"4E71";
        do_reset;
        wait_for_stop;
        check_frame("CHK.W negative", x"270B", x"018", x"00001008", x"00001006");

        report "=== Test 2: CHK.L negative destination ===" severity note;
        init_memory;
        clear_stack;
        setup_vector(16#18#, 16#2200#);
        setup_handler(16#2200#);
        mem(16#1000# / 2) := x"223C";
        mem(16#1002# / 2) := x"7FFF";
        mem(16#1004# / 2) := x"FFFF";
        mem(16#1006# / 2) := x"70FF";
        mem(16#1008# / 2) := x"4101";
        mem(16#100A# / 2) := x"4E71";
        do_reset;
        wait_for_stop;
        check_frame("CHK.L negative", x"270B", x"018", x"0000100A", x"00001008");

        report "=== Test 3: DIVU.W divide-by-zero high-word zero ===" severity note;
        init_memory;
        clear_stack;
        setup_vector(16#14#, 16#2400#);
        setup_handler(16#2400#);
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"8000";
        mem(16#1006# / 2) := x"80FC";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"4E71";
        do_reset;
        wait_for_stop;
        check_frame("DIVU.W divide-by-zero", x"2706", x"014", x"0000100A", x"00001006");

        report "=== Test 4: DIVUL.L divide-by-zero low-word nonzero ===" severity note;
        init_memory;
        clear_stack;
        setup_vector(16#14#, 16#2400#);
        setup_handler(16#2400#);
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"8000";
        mem(16#1006# / 2) := x"7400";
        mem(16#1008# / 2) := x"4C42";
        mem(16#100A# / 2) := x"0000";
        mem(16#100C# / 2) := x"4E71";
        do_reset;
        wait_for_stop;
        check_frame("DIVUL.L divide-by-zero", x"2702", x"014", x"0000100C", x"00001008");

        report "ODD_EXC CHK/DIV flag tests: " & integer'image(pass_count) & " PASSED, " &
               integer'image(fail_count) & " FAILED" severity note;

        if fail_count = 0 then
            report "ALL ODD_EXC CHK/DIV FLAG TESTS PASSED!" severity note;
        else
            report "ODD_EXC CHK/DIV FLAG TESTS FAILED" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
