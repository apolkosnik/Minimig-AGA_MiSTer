library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_div_rtr_frame_probe is
end entity;

architecture behavior of tb_div_rtr_frame_probe is
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
    signal dbg_pc     : std_logic_vector(31 downto 0);
    signal dbg_a7     : std_logic_vector(31 downto 0);
    signal test_done  : boolean := false;

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

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

    function hex32(value : std_logic_vector(31 downto 0)) return string is
        variable s : string(1 to 8);
    begin
        s(1) := hex_char(value(31 downto 28));
        s(2) := hex_char(value(27 downto 24));
        s(3) := hex_char(value(23 downto 20));
        s(4) := hex_char(value(19 downto 16));
        s(5) := hex_char(value(15 downto 12));
        s(6) := hex_char(value(11 downto 8));
        s(7) := hex_char(value(7 downto 4));
        s(8) := hex_char(value(3 downto 0));
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
            debug_pmove_dn_regnum => open,
            debug_opcode => open,
            debug_state => open,
            debug_setstate => open,
            debug_last_opc_read => open,
            debug_data_read => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC => dbg_pc,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => open,
            debug_regfile_d0 => open,
            debug_regfile_a0 => open,
            debug_fline_context_valid => open,
            debug_trap_1111 => open,
            debug_trapmake => open,
            debug_pmmu_brief => open,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
            debug_last_data_read => open,
            debug_last_opc_pc => open,
            debug_getbrief => open,
            debug_get_2ndopc => open,
            debug_fline_brief_pending => open,
            debug_fline_opcode_pc => open,
            debug_exe_PC => open,
            debug_memaddr_delta_rega => open,
            debug_memaddr_delta_regb => open,
            debug_addsub_q => open,
            debug_memmaskmux => open,
            debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open,
            debug_exec_directPC => open,
            debug_exec_mem_addsub => open,
            debug_set_addrlong => open,
            debug_mdelta_src => open,
            debug_pc_brw => open,
            debug_pc_word => open,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => open,
            debug_regfile_d7 => open,
            debug_regfile_a1 => open,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => dbg_a7,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => open,
            debug_trap_mmu_berr => open,
            debug_trap_vector => open,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy => open,
            debug_cpu_halted => open,
            debug_stop => open,
            debug_interrupt => open,
            debug_setendOPC => open,
            debug_IPL_nr => open,
            debug_micro_state => open,
            debug_next_micro_state => open,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => open,
            debug_pmmu_fault => open,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_data_write_tmp => open,
            debug_FlagsSR => open
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

        procedure wait_for_stop(timeout_cycles : integer := 8000) is
            variable idle_count : integer := 0;
        begin
            for i in 0 to timeout_cycles loop
                wait until rising_edge(clk);
                if busstate = "01" then
                    idle_count := idle_count + 1;
                    exit when idle_count >= 10;
                else
                    idle_count := 0;
                end if;
            end loop;
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

        procedure write_bsr_s(addr : integer; target : integer) is
            variable disp8 : integer;
        begin
            disp8 := target - (addr + 2);
            assert disp8 >= -128 and disp8 <= 127
                report "BSR.S target out of range in divide probe" severity failure;
            mem(addr / 2) := x"61" & std_logic_vector(to_signed(disp8, 8));
        end procedure;

        procedure setup_frame_store_handler(handler_addr : integer; stop_sr : std_logic_vector(15 downto 0)) is
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
            mem(handler_addr / 2 + 9) := x"2F0F"; -- MOVE.L A7,-(A7)
            mem(handler_addr / 2 + 10) := x"23DF"; -- MOVE.L (A7)+,$00003206
            mem(handler_addr / 2 + 11) := x"0000";
            mem(handler_addr / 2 + 12) := x"3206";
            mem(handler_addr / 2 + 13) := x"4E72"; -- STOP
            mem(handler_addr / 2 + 14) := stop_sr;
        end procedure;

        procedure setup_cputest020_capture_handler(
            table_addr    : integer;
            handler_addr  : integer;
            stop_sr       : std_logic_vector(15 downto 0);
            expsr_addr    : integer;
            framesr_addr  : integer;
            framepc_addr  : integer;
            framea7_addr  : integer
        ) is
        begin
            write_bsr_s(table_addr, handler_addr);
            mem(handler_addr / 2)     := x"4FEF"; -- LEA 4(A7),A7
            mem(handler_addr / 2 + 1) := x"0004";
            mem(handler_addr / 2 + 2) := x"40C0"; -- MOVE SR,D0
            mem(handler_addr / 2 + 3) := x"33C0"; -- MOVE.W D0,$abs.l
            mem(handler_addr / 2 + 4) := std_logic_vector(to_unsigned(expsr_addr / 65536, 16));
            mem(handler_addr / 2 + 5) := std_logic_vector(to_unsigned(expsr_addr mod 65536, 16));
            mem(handler_addr / 2 + 6) := x"3017"; -- MOVE.W (A7),D0
            mem(handler_addr / 2 + 7) := x"33C0"; -- MOVE.W D0,$abs.l
            mem(handler_addr / 2 + 8) := std_logic_vector(to_unsigned(framesr_addr / 65536, 16));
            mem(handler_addr / 2 + 9) := std_logic_vector(to_unsigned(framesr_addr mod 65536, 16));
            mem(handler_addr / 2 + 10) := x"202F"; -- MOVE.L 2(A7),D0
            mem(handler_addr / 2 + 11) := x"0002";
            mem(handler_addr / 2 + 12) := x"23C0"; -- MOVE.L D0,$abs.l
            mem(handler_addr / 2 + 13) := std_logic_vector(to_unsigned(framepc_addr / 65536, 16));
            mem(handler_addr / 2 + 14) := std_logic_vector(to_unsigned(framepc_addr mod 65536, 16));
            mem(handler_addr / 2 + 15) := x"2F0F"; -- MOVE.L A7,-(A7)
            mem(handler_addr / 2 + 16) := x"23DF"; -- MOVE.L (A7)+,$abs.l
            mem(handler_addr / 2 + 17) := std_logic_vector(to_unsigned(framea7_addr / 65536, 16));
            mem(handler_addr / 2 + 18) := std_logic_vector(to_unsigned(framea7_addr mod 65536, 16));
            mem(handler_addr / 2 + 19) := x"4E72"; -- STOP
            mem(handler_addr / 2 + 20) := stop_sr;
        end procedure;

        procedure setup_user_entry(frame_sp : integer; entry_pc : integer; user_sp : integer := 16#5000#) is
        begin
            mem(16#1000# / 2) := x"223C"; -- MOVE.L #user_sp,D1
            mem(16#1002# / 2) := std_logic_vector(to_unsigned(user_sp / 65536, 16));
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(user_sp mod 65536, 16));
            mem(16#1006# / 2) := x"4E7B"; -- MOVEC D1,USP
            mem(16#1008# / 2) := x"1800";
            mem(16#100A# / 2) := x"4E73"; -- RTE
            mem(frame_sp / 2) := x"0000";
            mem(frame_sp / 2 + 1) := std_logic_vector(to_unsigned(entry_pc / 65536, 16));
            mem(frame_sp / 2 + 2) := std_logic_vector(to_unsigned(entry_pc mod 65536, 16));
            mem(frame_sp / 2 + 3) := x"0000";
        end procedure;

        procedure setup_movem_user_entry(
            frame_sp : integer;
            entry_pc : integer;
            regblock : integer;
            user_sp  : integer := 16#5000#
        ) is
        begin
            mem(16#1000# / 2) := x"223C"; -- MOVE.L #user_sp,D1
            mem(16#1002# / 2) := std_logic_vector(to_unsigned(user_sp / 65536, 16));
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(user_sp mod 65536, 16));
            mem(16#1006# / 2) := x"4E7B"; -- MOVEC D1,USP
            mem(16#1008# / 2) := x"1800";
            mem(16#100A# / 2) := x"207C"; -- MOVEA.L #regblock,A0
            mem(16#100C# / 2) := std_logic_vector(to_unsigned(regblock / 65536, 16));
            mem(16#100E# / 2) := std_logic_vector(to_unsigned(regblock mod 65536, 16));
            mem(16#1010# / 2) := x"2E7C"; -- MOVEA.L #frame_sp,A7
            mem(16#1012# / 2) := std_logic_vector(to_unsigned(frame_sp / 65536, 16));
            mem(16#1014# / 2) := std_logic_vector(to_unsigned(frame_sp mod 65536, 16));
            mem(16#1016# / 2) := x"4CD0"; -- MOVEM.L (A0),D0-D7/A0-A6
            mem(16#1018# / 2) := x"7FFF";
            mem(16#101A# / 2) := x"4E73"; -- RTE
            mem(frame_sp / 2) := x"0000";
            mem(frame_sp / 2 + 1) := std_logic_vector(to_unsigned(entry_pc / 65536, 16));
            mem(frame_sp / 2 + 2) := std_logic_vector(to_unsigned(entry_pc mod 65536, 16));
            mem(frame_sp / 2 + 3) := x"0000";
        end procedure;

        procedure setup_execute020_like_entry(
            frame_top : integer;
            entry_pc  : integer;
            regblock  : integer;
            user_sp   : integer := 16#5000#;
            msp_value : integer := 16#6000#;
            sr_value  : std_logic_vector(15 downto 0) := x"0000"
        ) is
        begin
            mem(16#1000# / 2) := x"223C"; -- MOVE.L #user_sp,D1
            mem(16#1002# / 2) := std_logic_vector(to_unsigned(user_sp / 65536, 16));
            mem(16#1004# / 2) := std_logic_vector(to_unsigned(user_sp mod 65536, 16));
            mem(16#1006# / 2) := x"4E7B"; -- MOVEC D1,USP
            mem(16#1008# / 2) := x"1800";
            mem(16#100A# / 2) := x"243C"; -- MOVE.L #msp_value,D2
            mem(16#100C# / 2) := std_logic_vector(to_unsigned(msp_value / 65536, 16));
            mem(16#100E# / 2) := std_logic_vector(to_unsigned(msp_value mod 65536, 16));
            mem(16#1010# / 2) := x"4E7A"; -- MOVEC D2,MSP
            mem(16#1012# / 2) := x"2803";
            mem(16#1014# / 2) := x"207C"; -- MOVEA.L #regblock,A0
            mem(16#1016# / 2) := std_logic_vector(to_unsigned(regblock / 65536, 16));
            mem(16#1018# / 2) := std_logic_vector(to_unsigned(regblock mod 65536, 16));
            mem(16#101A# / 2) := x"2E7C"; -- MOVEA.L #frame_top,A7
            mem(16#101C# / 2) := std_logic_vector(to_unsigned(frame_top / 65536, 16));
            mem(16#101E# / 2) := std_logic_vector(to_unsigned(frame_top mod 65536, 16));
            mem(16#1020# / 2) := x"3F3C"; -- MOVE.W #0,-(A7) format word
            mem(16#1022# / 2) := x"0000";
            mem(16#1024# / 2) := x"2F3C"; -- MOVE.L #entry_pc,-(A7)
            mem(16#1026# / 2) := std_logic_vector(to_unsigned(entry_pc / 65536, 16));
            mem(16#1028# / 2) := std_logic_vector(to_unsigned(entry_pc mod 65536, 16));
            mem(16#102A# / 2) := x"3F3C"; -- MOVE.W #sr_value,-(A7)
            mem(16#102C# / 2) := sr_value;
            mem(16#102E# / 2) := x"4CD0"; -- MOVEM.L (A0),D0-D7/A0-A6
            mem(16#1030# / 2) := x"7FFF";
            mem(16#1032# / 2) := x"4E73"; -- RTE
        end procedure;

        procedure write_regblock_default_div(regblock : integer) is
        begin
            mem(regblock / 2 + 16#00# / 2) := x"0000"; mem(regblock / 2 + 16#02# / 2) := x"0022"; -- D0
            mem(regblock / 2 + 16#04# / 2) := x"0000"; mem(regblock / 2 + 16#06# / 2) := x"0000"; -- D1
            mem(regblock / 2 + 16#08# / 2) := x"FFFF"; mem(regblock / 2 + 16#0A# / 2) := x"FFFF"; -- D2
            mem(regblock / 2 + 16#0C# / 2) := x"FFFF"; mem(regblock / 2 + 16#0E# / 2) := x"FF00"; -- D3
            mem(regblock / 2 + 16#10# / 2) := x"FFFF"; mem(regblock / 2 + 16#12# / 2) := x"0000"; -- D4
            mem(regblock / 2 + 16#14# / 2) := x"8000"; mem(regblock / 2 + 16#16# / 2) := x"8080"; -- D5
            mem(regblock / 2 + 16#18# / 2) := x"0001"; mem(regblock / 2 + 16#1A# / 2) := x"0101"; -- D6
            mem(regblock / 2 + 16#1C# / 2) := x"AAAA"; mem(regblock / 2 + 16#1E# / 2) := x"AAAA"; -- D7
            mem(regblock / 2 + 16#20# / 2) := x"0000"; mem(regblock / 2 + 16#22# / 2) := x"0000"; -- A0
            mem(regblock / 2 + 16#24# / 2) := x"0000"; mem(regblock / 2 + 16#26# / 2) := x"0078"; -- A1
            mem(regblock / 2 + 16#28# / 2) := x"0000"; mem(regblock / 2 + 16#2A# / 2) := x"7FF0"; -- A2
            mem(regblock / 2 + 16#2C# / 2) := x"0000"; mem(regblock / 2 + 16#2E# / 2) := x"7FFF"; -- A3
            mem(regblock / 2 + 16#30# / 2) := x"FFFF"; mem(regblock / 2 + 16#32# / 2) := x"FFFE"; -- A4
            mem(regblock / 2 + 16#34# / 2) := x"FFFF"; mem(regblock / 2 + 16#36# / 2) := x"FF00"; -- A5
            mem(regblock / 2 + 16#38# / 2) := x"4204"; mem(regblock / 2 + 16#3A# / 2) := x"FF00"; -- A6
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

        procedure check_word(name : string; addr : integer; expected : std_logic_vector(15 downto 0)) is
            variable actual : std_logic_vector(15 downto 0);
        begin
            actual := mem(addr / 2);
            if actual = expected then
                report "PASS: " & name & " = $" & hex16(actual) severity note;
            else
                report "FAIL: " & name & " expected $" & hex16(expected) &
                       " got $" & hex16(actual) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_long(name : string; addr : integer; expected : integer) is
            variable hi, lo : std_logic_vector(15 downto 0);
        begin
            hi := mem(addr / 2);
            lo := mem(addr / 2 + 1);
            if hi & lo = std_logic_vector(to_unsigned(expected, 32)) then
                report "PASS: " & name & " = $" & hex32(hi & lo) severity note;
            else
                report "FAIL: " & name & " expected $" &
                       hex32(std_logic_vector(to_unsigned(expected, 32))) &
                       " got $" & hex32(hi & lo) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

    begin
        report "=== direct DIV/RTR frame probe ===" severity note;

        -- DIVL.L record1/group0/sub0: signed long overflow, then ILLEGAL captures SR.
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#2000#); -- ILLEGAL
        setup_frame_store_handler(16#2000#, x"2700");
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"203C"; mem(16#1202# / 2) := x"0000"; mem(16#1204# / 2) := x"0022"; -- D0
        mem(16#1206# / 2) := x"223C"; mem(16#1208# / 2) := x"0000"; mem(16#120A# / 2) := x"0000"; -- D1
        mem(16#120C# / 2) := x"243C"; mem(16#120E# / 2) := x"FFFF"; mem(16#1210# / 2) := x"FFFF"; -- D2
        mem(16#1212# / 2) := x"263C"; mem(16#1214# / 2) := x"FFFF"; mem(16#1216# / 2) := x"FF00"; -- D3
        mem(16#1218# / 2) := x"283C"; mem(16#121A# / 2) := x"FFFF"; mem(16#121C# / 2) := x"0000"; -- D4
        mem(16#121E# / 2) := x"2A3C"; mem(16#1220# / 2) := x"8000"; mem(16#1222# / 2) := x"8080"; -- D5
        mem(16#1224# / 2) := x"2C3C"; mem(16#1226# / 2) := x"0001"; mem(16#1228# / 2) := x"0101"; -- D6
        mem(16#122A# / 2) := x"2E3C"; mem(16#122C# / 2) := x"AAAA"; mem(16#122E# / 2) := x"AAAA"; -- D7
        mem(16#1230# / 2) := x"4C40";
        mem(16#1232# / 2) := x"9E54";
        mem(16#1234# / 2) := x"2048";
        mem(16#1236# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVL.L stacked SR", 16#3200#, x"0006");

        -- DIVL.L again through a 68020-style BSR.S vector-table entry.
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#1800#); -- ILLEGAL vector points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"203C"; mem(16#1202# / 2) := x"0000"; mem(16#1204# / 2) := x"0022"; -- D0
        mem(16#1206# / 2) := x"223C"; mem(16#1208# / 2) := x"0000"; mem(16#120A# / 2) := x"0000"; -- D1
        mem(16#120C# / 2) := x"243C"; mem(16#120E# / 2) := x"FFFF"; mem(16#1210# / 2) := x"FFFF"; -- D2
        mem(16#1212# / 2) := x"263C"; mem(16#1214# / 2) := x"FFFF"; mem(16#1216# / 2) := x"FF00"; -- D3
        mem(16#1218# / 2) := x"283C"; mem(16#121A# / 2) := x"FFFF"; mem(16#121C# / 2) := x"0000"; -- D4
        mem(16#121E# / 2) := x"2A3C"; mem(16#1220# / 2) := x"8000"; mem(16#1222# / 2) := x"8080"; -- D5
        mem(16#1224# / 2) := x"2C3C"; mem(16#1226# / 2) := x"0001"; mem(16#1228# / 2) := x"0101"; -- D6
        mem(16#122A# / 2) := x"2E3C"; mem(16#122C# / 2) := x"AAAA"; mem(16#122E# / 2) := x"AAAA"; -- D7
        mem(16#1230# / 2) := x"4C40";
        mem(16#1232# / 2) := x"9E54";
        mem(16#1234# / 2) := x"2048";
        mem(16#1236# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVL.L table EXPSR", 16#3210#, x"2006");
        check_word("DIVL.L table stacked SR", 16#3212#, x"0006");
        check_long("DIVL.L table stacked PC", 16#3214#, 16#00001236#);

        -- DIVU.W record1/group0/sub0
        init_memory(16#3FF8#);
        setup_vector(16#14#, 16#2000#); -- vector 5
        setup_frame_store_handler(16#2000#, x"2700");
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"203C"; mem(16#1202# / 2) := x"0000"; mem(16#1204# / 2) := x"0022"; -- D0
        mem(16#1206# / 2) := x"223C"; mem(16#1208# / 2) := x"0000"; mem(16#120A# / 2) := x"0000"; -- D1
        mem(16#120C# / 2) := x"80C1";
        mem(16#120E# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVU.W stacked SR", 16#3200#, x"0006");

        -- DIVU.W again through a 68020-style BSR.S vector-table entry.
        init_memory(16#3FF8#);
        setup_vector(16#14#, 16#1800#); -- vector 5 points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        setup_user_entry(16#3FF8#, 16#1200#);
        mem(16#1200# / 2) := x"203C"; mem(16#1202# / 2) := x"0000"; mem(16#1204# / 2) := x"0022"; -- D0
        mem(16#1206# / 2) := x"223C"; mem(16#1208# / 2) := x"0000"; mem(16#120A# / 2) := x"0000"; -- D1
        mem(16#120C# / 2) := x"80C1";
        mem(16#120E# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVU.W table EXPSR", 16#3210#, x"2006");
        check_word("DIVU.W table stacked SR", 16#3212#, x"0006");
        check_long("DIVU.W table stacked PC", 16#3214#, 16#0000120C#);

        -- DIVL.L with MOVEM.L restore as the last pre-RTE step.
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#1800#); -- ILLEGAL vector points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        write_regblock_default_div(16#3400#);
        setup_movem_user_entry(16#3FF8#, 16#1200#, 16#3400#);
        mem(16#1200# / 2) := x"4C40";
        mem(16#1202# / 2) := x"9E54";
        mem(16#1204# / 2) := x"2048";
        mem(16#1206# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVL.L movem EXPSR", 16#3210#, x"2006");
        check_word("DIVL.L movem stacked SR", 16#3212#, x"0006");
        check_long("DIVL.L movem stacked PC", 16#3214#, 16#00001206#);

        -- DIVU.W with MOVEM.L restore as the last pre-RTE step.
        init_memory(16#3FF8#);
        setup_vector(16#14#, 16#1800#); -- vector 5 points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        write_regblock_default_div(16#3400#);
        setup_movem_user_entry(16#3FF8#, 16#1200#, 16#3400#);
        mem(16#1200# / 2) := x"80C1";
        mem(16#1202# / 2) := x"2048";
        mem(16#1204# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVU.W movem EXPSR", 16#3210#, x"2006");
        check_word("DIVU.W movem stacked SR", 16#3212#, x"0006");

        -- DIVL.L with execute_test020-style frame construction before RTE.
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#1800#); -- ILLEGAL vector points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        write_regblock_default_div(16#3400#);
        setup_execute020_like_entry(16#4000#, 16#1200#, 16#3400#);
        mem(16#1200# / 2) := x"4C40";
        mem(16#1202# / 2) := x"9E54";
        mem(16#1204# / 2) := x"2048";
        mem(16#1206# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVL.L exec020 EXPSR", 16#3210#, x"2006");
        check_word("DIVL.L exec020 stacked SR", 16#3212#, x"0006");
        check_long("DIVL.L exec020 stacked PC", 16#3214#, 16#00001206#);

        -- DIVU.W with execute_test020-style frame construction before RTE.
        init_memory(16#3FF8#);
        setup_vector(16#14#, 16#1800#); -- vector 5 points to BSR.S entry
        setup_cputest020_capture_handler(16#1800#, 16#1830#, x"2700", 16#3210#, 16#3212#, 16#3214#, 16#3218#);
        write_regblock_default_div(16#3400#);
        setup_execute020_like_entry(16#4000#, 16#1200#, 16#3400#);
        mem(16#1200# / 2) := x"80C1";
        mem(16#1202# / 2) := x"2048";
        mem(16#1204# / 2) := x"4AFC";
        do_reset;
        wait_for_stop;
        check_word("DIVU.W exec020 EXPSR", 16#3210#, x"2006");
        check_word("DIVU.W exec020 stacked SR", 16#3212#, x"0006");

        -- DIVS.W default photographed case: 85EF 3FB4, then ILLEGAL captures SR.
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#2000#); -- ILLEGAL
        setup_frame_store_handler(16#2000#, x"2700");
        setup_user_entry(16#3FF8#, 16#1300#);
        mem(16#1300# / 2) := x"203C"; mem(16#1302# / 2) := x"0000"; mem(16#1304# / 2) := x"166C"; -- D0
        mem(16#1306# / 2) := x"243C"; mem(16#1308# / 2) := x"DFFF"; mem(16#130A# / 2) := x"DFFF"; -- D2
        mem(16#130C# / 2) := x"263C"; mem(16#130E# / 2) := x"700D"; mem(16#1310# / 2) := x"FFFF"; -- D3
        mem(16#1312# / 2) := x"283C"; mem(16#1314# / 2) := x"D550"; mem(16#1316# / 2) := x"0095"; -- D4
        mem(16#1318# / 2) := x"2A3C"; mem(16#131A# / 2) := x"800A"; mem(16#131C# / 2) := x"8A8A"; -- D5
        mem(16#131E# / 2) := x"2C3C"; mem(16#1320# / 2) := x"0200"; mem(16#1322# / 2) := x"0202"; -- D6
        mem(16#1324# / 2) := x"2E3C"; mem(16#1326# / 2) := x"5C06"; mem(16#1328# / 2) := x"FFB5"; -- D7
        mem(16#132A# / 2) := x"227C"; mem(16#132C# / 2) := x"0000"; mem(16#132E# / 2) := x"0080"; -- A1
        mem(16#1330# / 2) := x"247C"; mem(16#1332# / 2) := x"0000"; mem(16#1334# / 2) := x"801D"; -- A2
        mem(16#1336# / 2) := x"267C"; mem(16#1338# / 2) := x"0000"; mem(16#133A# / 2) := x"FFFF"; -- A3
        mem(16#133C# / 2) := x"287C"; mem(16#133E# / 2) := x"7FFF"; mem(16#1340# / 2) := x"FF7A"; -- A4
        mem(16#1342# / 2) := x"2A7C"; mem(16#1344# / 2) := x"C03F"; mem(16#1346# / 2) := x"FFFF"; -- A5
        mem(16#1348# / 2) := x"85EF";
        mem(16#134A# / 2) := x"3FB4";
        mem(16#134C# / 2) := x"4AFC";
        mem(16#3FB4# / 2) := x"5838";
        mem(16#3FB6# / 2) := x"0000";
        do_reset;
        wait_for_stop;
        check_word("DIVS.W post-ILLEGAL stacked SR", 16#3200#, x"0000");

        -- RTR record0/group0/sub0
        init_memory(16#3FF8#);
        setup_vector(16#10#, 16#2000#);
        setup_frame_store_handler(16#2000#, x"2700");
        setup_user_entry(16#3FF8#, 16#1200#, 16#5000#);
        mem(16#1200# / 2) := x"4E77";
        mem(16#5000# / 2) := x"C5A0";
        mem(16#5002# / 2) := x"0000";
        mem(16#5004# / 2) := x"703E";
        mem(16#703E# / 2) := x"4AFC";
        mem(16#7040# / 2) := x"2048";
        do_reset;
        wait_for_stop;
        check_long("RTR post-return A7", 16#3206#, 16#00005002#);
        if dbg_pc = x"00007040" and dbg_a7 = x"00005002" then
            report "PASS: RTR reached target with PC=$" & hex32(dbg_pc) &
                   " A7=$" & hex32(dbg_a7) severity note;
        else
            report "FAIL: RTR target state PC=$" & hex32(dbg_pc) &
                   " A7=$" & hex32(dbg_a7) severity error;
            fail_count := fail_count + 1;
        end if;

        report "RESULT: " & integer'image(fail_count) & " FAILED" severity note;
        test_done <= true;
        wait;
    end process;
end architecture;
