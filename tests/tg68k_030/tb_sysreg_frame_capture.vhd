library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sysreg_frame_capture is
end entity;

architecture behavior of tb_sysreg_frame_capture is
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

    function hex_char(nib : std_logic_vector(3 downto 0)) return character is
    begin
        case nib is
            when "0000" => return '0';
            when "0001" => return '1';
            when "0010" => return '2';
            when "0011" => return '3';
            when "0100" => return '4';
            when "0101" => return '5';
            when "0110" => return '6';
            when "0111" => return '7';
            when "1000" => return '8';
            when "1001" => return '9';
            when "1010" => return 'A';
            when "1011" => return 'B';
            when "1100" => return 'C';
            when "1101" => return 'D';
            when "1110" => return 'E';
            when others => return 'F';
        end case;
    end function;

    function hex16(value : std_logic_vector(15 downto 0)) return string is
        variable s : string(1 to 4);
    begin
        s(1) := hex_char(value(15 downto 12));
        s(2) := hex_char(value(11 downto 8));
        s(3) := hex_char(value(7 downto 4));
        s(4) := hex_char(value(3 downto 0));
        return s;
    end function;
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
        variable fail_count : integer := 0;
        variable rtr_idle_count : integer := 0;
        variable rtr_saw_1200 : boolean := false;
        variable rtr_saw_1208 : boolean := false;
        variable rtr_saw_1300 : boolean := false;
        variable rtr_saw_2000 : boolean := false;

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

        procedure init_memory(initial_sp : integer; initial_pc : integer := 16#1000#) is
        begin
            for i in 0 to 32767 loop
                mem(i) := x"4E71";
            end loop;

            mem(0) := std_logic_vector(to_unsigned(initial_sp / 65536, 16));
            mem(1) := std_logic_vector(to_unsigned(initial_sp mod 65536, 16));
            mem(2) := std_logic_vector(to_unsigned(initial_pc / 65536, 16));
            mem(3) := std_logic_vector(to_unsigned(initial_pc mod 65536, 16));
        end procedure;

        procedure setup_vector(vec_offset : integer; handler_addr : integer) is
        begin
            mem(vec_offset / 2)     := std_logic_vector(to_unsigned(handler_addr / 65536, 16));
            mem(vec_offset / 2 + 1) := std_logic_vector(to_unsigned(handler_addr mod 65536, 16));
        end procedure;

        procedure setup_stop_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"3017"; -- MOVE.W (A7),D0
            mem(handler_addr / 2 + 1) := x"33C0"; -- MOVE.W D0,$00003200
            mem(handler_addr / 2 + 2) := x"0000";
            mem(handler_addr / 2 + 3) := x"3200";
            mem(handler_addr / 2 + 4) := x"202F"; -- MOVE.L 2(A7),D0
            mem(handler_addr / 2 + 5) := x"0002";
            mem(handler_addr / 2 + 6) := x"23C0"; -- MOVE.L D0,$00003202
            mem(handler_addr / 2 + 7) := x"0000";
            mem(handler_addr / 2 + 8) := x"3202";
            mem(handler_addr / 2 + 9) := x"4E72"; -- STOP #$2700
            mem(handler_addr / 2 + 10) := x"2700";
        end procedure;

        procedure setup_user_entry(frame_sp : integer; entry_pc : integer; user_sp : integer := 16#5000#) is
        begin
            mem(16#1000# / 2) := x"223C"; -- MOVE.L #user_sp,D1
            mem(16#1002# / 2) := std_logic_vector(to_unsigned(user_sp / 65536, 16));
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(user_sp mod 65536, 16));
            mem(16#1006# / 2) := x"4E7B"; -- MOVEC D1,USP
            mem(16#1008# / 2) := x"1800";
            mem(16#100A# / 2) := x"4E73"; -- RTE
            mem(frame_sp / 2) := x"0000"; -- user SR
            mem(frame_sp / 2 + 1) := std_logic_vector(to_unsigned(entry_pc / 65536, 16));
            mem(frame_sp / 2 + 2) := std_logic_vector(to_unsigned(entry_pc mod 65536, 16));
            mem(frame_sp / 2 + 3) := x"0000"; -- format 0
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

        impure function read_word(addr : integer) return std_logic_vector is
        begin
            return mem(addr / 2);
        end function;

        procedure check_word(test_name : string; actual : std_logic_vector(15 downto 0); expected : std_logic_vector(15 downto 0)) is
        begin
            if actual = expected then
                report "PASS: " & test_name & " = $" & hex16(actual) severity note;
            else
                report "FAIL: " & test_name & " expected $" & hex16(expected) &
                       " got $" & hex16(actual) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_long(test_name : string; addr : integer; expected : integer) is
            variable actual_hi : std_logic_vector(15 downto 0);
            variable actual_lo : std_logic_vector(15 downto 0);
            variable expect_hi : std_logic_vector(15 downto 0);
            variable expect_lo : std_logic_vector(15 downto 0);
        begin
            actual_hi := read_word(addr);
            actual_lo := read_word(addr + 2);
            expect_hi := std_logic_vector(to_unsigned(expected / 65536, 16));
            expect_lo := std_logic_vector(to_unsigned(expected mod 65536, 16));
            check_word(test_name & " high", actual_hi, expect_hi);
            check_word(test_name & " low", actual_lo, expect_lo);
        end procedure;
    begin
        report "=== system-register frame-capture probe ===" severity note;

        -- ORI.B #$50,CCR ; MOVEA.L A0,A0 ; ILLEGAL
        init_memory(16#3FF8#);
        setup_vector(16#0C#, 16#2000#);
        setup_vector(16#10#, 16#2000#);
        setup_vector(16#20#, 16#2000#);
        setup_stop_handler(16#2000#);
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"003C";
        mem(16#1202# / 2) := x"0050";
        mem(16#1204# / 2) := x"2048";
        mem(16#1206# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("ORSR.B stacked SR", read_word(16#3FF8#), x"0010");

        -- ORI.W #$005B,SR ; MOVEA.L A0,A0 ; ILLEGAL
        init_memory(16#4000#);
        setup_vector(16#0C#, 16#2000#);
        setup_vector(16#10#, 16#2000#);
        setup_vector(16#20#, 16#2000#);
        setup_stop_handler(16#2000#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"2000";
        mem(16#1004# / 2) := x"007C";
        mem(16#1006# / 2) := x"005B";
        mem(16#1008# / 2) := x"2048";
        mem(16#100A# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("ORSR.W stacked SR", read_word(16#3FF8#), x"201B");

        -- MOVEQ #-1,D2 ; MOVE.W D2,CCR ; MOVEA.L A0,A0 ; ILLEGAL
        init_memory(16#3FF8#);
        setup_vector(16#0C#, 16#2000#);
        setup_vector(16#10#, 16#2000#);
        setup_vector(16#20#, 16#2000#);
        setup_stop_handler(16#2000#);
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"74FF";
        mem(16#1202# / 2) := x"44C2";
        mem(16#1204# / 2) := x"2048";
        mem(16#1206# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("MOVE.W D2,CCR stacked SR", read_word(16#3FF8#), x"001F");

        -- MOVE.L #$0000AAAA,D3 ; MOVE.W D3,SR ; MOVEA.L A0,A0 ; trace
        init_memory(16#4000#);
        setup_vector(16#0C#, 16#2100#);
        setup_vector(16#10#, 16#2100#);
        setup_vector(16#20#, 16#2100#);
        setup_vector(16#24#, 16#2100#);
        setup_stop_handler(16#2100#);
        mem(16#1000# / 2) := x"46FC";
        mem(16#1002# / 2) := x"2000";
        mem(16#1004# / 2) := x"263C";
        mem(16#1006# / 2) := x"0000";
        mem(16#1008# / 2) := x"AAAA";
        mem(16#100A# / 2) := x"46C3";
        mem(16#100C# / 2) := x"2048";
        mem(16#100E# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("MOVE.W D3,SR trace stacked SR", read_word(16#3FF4#), x"A20A");

        -- RTR restores stacked low-byte image, then ILLEGAL stacks it back out
        init_memory(16#3FF8#);
        setup_vector(16#0C#, 16#2000#);
        setup_vector(16#10#, 16#2000#);
        setup_vector(16#20#, 16#2000#);
        setup_stop_handler(16#2000#);
        setup_user_entry(16#3FF8#, 16#1200#, 16#5000#);
        mem(16#1200# / 2) := x"200F"; -- MOVE.L A7,D0
        mem(16#1202# / 2) := x"23C0"; -- MOVE.L D0,$00003100
        mem(16#1204# / 2) := x"0000";
        mem(16#1206# / 2) := x"3100";
        mem(16#1208# / 2) := x"4E77";
        mem(16#5000# / 2) := x"0029";
        mem(16#5002# / 2) := x"0000";
        mem(16#5004# / 2) := x"1300";
        mem(16#1300# / 2) := x"2048";
        mem(16#1302# / 2) := x"4AFC";
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';
        rtr_idle_count := 0;
        rtr_saw_1200 := false;
        rtr_saw_1208 := false;
        rtr_saw_1300 := false;
        rtr_saw_2000 := false;
        for i in 0 to 6000 loop
            wait until rising_edge(clk);
            if addr_out(15 downto 0) = x"1200" then
                rtr_saw_1200 := true;
            elsif addr_out(15 downto 0) = x"1208" then
                rtr_saw_1208 := true;
            elsif addr_out(15 downto 0) = x"1300" then
                rtr_saw_1300 := true;
            elsif addr_out(15 downto 0) = x"2000" then
                rtr_saw_2000 := true;
            end if;

            if busstate = "01" then
                rtr_idle_count := rtr_idle_count + 1;
                exit when rtr_idle_count >= 10;
            else
                rtr_idle_count := 0;
            end if;
        end loop;
        check_long("RTR user A7 before RTR", 16#3100#, 16#00005000#);
        check_long("RTR stacked PC", 16#3202#, 16#00001302#);
        check_word("RTR stacked SR", read_word(16#3200#), x"0029");
        report "RTR path saw $1200=" & boolean'image(rtr_saw_1200) &
               " $1208=" & boolean'image(rtr_saw_1208) &
               " $1300=" & boolean'image(rtr_saw_1300) &
               " $2000=" & boolean'image(rtr_saw_2000) severity note;

        if fail_count = 0 then
            report "OVERALL: ALL SYSTEM-REGISTER FRAME TESTS PASSED" severity note;
        else
            report "OVERALL: SOME SYSTEM-REGISTER FRAME TESTS FAILED" severity error;
        end if;

        test_done <= true;
        wait;
    end process;
end architecture;
