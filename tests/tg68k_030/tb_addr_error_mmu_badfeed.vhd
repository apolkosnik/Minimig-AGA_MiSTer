-- tb_addr_error_mmu_badfeed.vhd
-- Regression: odd user-data access must NOT raise address error on 68020/030.
-- With MMU enabled, the odd access should still take the vector-2 MMU/bus-fault
-- path when the translated target resolves to the BADFEED0 sentinel chain.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_addr_error_mmu_badfeed is
end entity;

architecture behavioral of tb_addr_error_mmu_badfeed is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        variable v : std_logic_vector(value'length - 1 downto 0);
    begin
        v := value;
        for i in 0 to (v'length/4 - 1) loop
            nibble := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    function is_x(value : std_logic_vector) return boolean is
    begin
        for i in value'range loop
            if value(i) /= '0' and value(i) /= '1' then
                return true;
            end if;
        end loop;
        return false;
    end function;

    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal test_done : boolean := false;

    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal busstate    : std_logic_vector(1 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal FC          : std_logic_vector(2 downto 0);

    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    signal pmmu_addr_phys     : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_addr_log      : std_logic_vector(31 downto 0);

    signal debug_TG68_PC         : std_logic_vector(31 downto 0);
    signal debug_trap_berr       : std_logic;
    signal debug_trap_mmu_berr   : std_logic;
    signal debug_trap_addr_error : std_logic;
    signal debug_trap_vector     : std_logic_vector(31 downto 0);
    signal debug_pmmu_fault      : std_logic;
    signal debug_pmmu_busy       : std_logic;
    signal debug_cpu_halted      : std_logic;
    signal debug_pmmu_fault_status : std_logic_vector(15 downto 0);
    signal debug_pmmu_saved_addr   : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_addr : std_logic_vector(31 downto 0);
    signal debug_pmmu_walk_desc_data : std_logic_vector(31 downto 0);

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Reset vectors
        m(0) := x"0000"; m(1) := x"2000";
        m(2) := x"0000"; m(3) := x"0100";

        -- Vector 2 -> $0080, vector 3 -> $00C0
        m(4) := x"0000"; m(5) := x"0080";
        m(6) := x"0000"; m(7) := x"00C0";

        -- All other vectors -> unexpected trap at $00A0
        for i in 4 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00A0";
        end loop;

        -- Vector 2 handler: success marker
        m(64) := x"23FC"; m(65) := x"0000"; m(66) := x"0002";
        m(67) := x"0000"; m(68) := x"1F00";
        m(69) := x"4E72"; m(70) := x"2700";

        -- Unexpected trap handler: fail marker
        m(80) := x"23FC"; m(81) := x"00FF"; m(82) := x"0000";
        m(83) := x"0000"; m(84) := x"1F00";
        m(85) := x"4E72"; m(86) := x"2700";

        -- Vector 3 handler: fail marker
        m(96) := x"23FC"; m(97) := x"0000"; m(98) := x"0003";
        m(99) := x"0000"; m(100) := x"1F00";
        m(101) := x"4E72"; m(102) := x"2700";

        -- Program
        m(128) := x"2E7C"; m(129) := x"0000"; m(130) := x"1080"; -- MOVEA.L #$00001080,A7
        m(131) := x"F017"; m(132) := x"4C00";                     -- PMOVE.Q (A7),CRP
        m(133) := x"2E7C"; m(134) := x"0000"; m(135) := x"1088"; -- MOVEA.L #$00001088,A7
        m(136) := x"F017"; m(137) := x"4800";                     -- PMOVE.Q (A7),SRP
        m(138) := x"F000"; m(139) := x"2400";                     -- PFLUSHA
        m(140) := x"F038"; m(141) := x"4000"; m(142) := x"1090"; -- PMOVE.L ($1090).W,TC
        m(143) := x"4E71"; m(144) := x"4E71";
        m(145) := x"46FC"; m(146) := x"0000";                     -- MOVE #0,SR
        m(147) := x"207C"; m(148) := x"0001"; m(149) := x"1C09"; -- MOVEA.L #$00011C09,A0
        m(150) := x"2010";                                         -- MOVE.L (A0),D0
        m(151) := x"23FC"; m(152) := x"DEAD"; m(153) := x"BEEF"; -- retired => fail
        m(154) := x"0000"; m(155) := x"1F04";
        m(156) := x"60FE";                                         -- BRA.S *

        -- CRP
        m(2112) := x"8000"; m(2113) := x"0002";
        m(2114) := x"0000"; m(2115) := x"6000";

        -- SRP
        m(2116) := x"8000"; m(2117) := x"0002";
        m(2118) := x"0000"; m(2119) := x"6000";
        -- TC
        m(2120) := x"82A0"; m(2121) := x"8680";

        -- Root slot index 0 -> table at $6800
        m(12288) := x"0000"; m(12289) := x"6802";

        -- Next level slot index 0 -> final table at $6E00
        m(13312) := x"0000"; m(13313) := x"6E02";

        -- Final table identity maps the code page and supervisor stack page so the
        -- program can actually reach the odd access under MMU:
        --   slot 0  -> phys $00000000 (vectors/code at $0000-$03FF)
        --   slot 7  -> phys $00001C00 (stack page containing $1FFC)
        m(14080) := x"0000"; m(14081) := x"0061";
        m(14094) := x"0000"; m(14095) := x"1C61";

        -- Final-level slot for logical $00011C09: ($11C09 >> 10) = $47, so slot at $6E00+$11C
        m(14222) := x"0000"; m(14223) := x"7002";

        -- Indirect target contains the sentinel, not a page descriptor
        m(14336) := x"BADF"; m(14337) := x"EED0";

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin

    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    uut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 2,
            extAddr_Mode   => 2,
            MUL_Mode       => 2,
            DIV_Mode       => 2,
            BitField       => 2,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk, nReset => nReset, clkena_in => clkena_in, data_in => data_in,
            IPL => "111", IPL_autovector => '1', berr => '0', CPU => "10",
            addr_out => addr_out, data_write => data_write, nWr => nWr, nUDS => nUDS, nLDS => nLDS,
            busstate => busstate, longword => open, nResetOut => open, FC => FC, clr_berr => open,
            skipFetch => open, regin_out => open, CACR_out => open, VBR_out => open,
            cache_inv_req => open, cache_op_scope => open, cache_op_cache => open, cache_op_addr => open,
            cacr_ie => open, cacr_de => open, cacr_ifreeze => open, cacr_dfreeze => open,
            cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
            pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open, pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => pmmu_addr_log, pmmu_addr_phys => pmmu_addr_phys, pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req => pmmu_walker_req, pmmu_walker_we => pmmu_walker_we, pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat, pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data, pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode => open, debug_preSVmode => open, debug_FlagsSR_S => open, debug_changeMode => open,
            debug_setopcode => open, debug_exec_directSR => open, debug_exec_to_SR => open,
            debug_pmove_dn_mode => open, debug_pmove_dn_regnum => open, debug_opcode => open,
            debug_state => open, debug_setstate => open, debug_last_opc_read => open, debug_data_read => open,
            debug_direct_data => open, debug_setnextpass => open, debug_TG68_PC => debug_TG68_PC,
            debug_memaddr_reg => open, debug_memaddr_delta => open, debug_oddout => open, debug_decodeOPC => open,
            debug_brief => open, debug_moves_bus_pending => open, debug_moves_writeback_pending => open,
            debug_clkena_lw => open, debug_regfile_d0 => open, debug_regfile_a0 => open,
            debug_fline_context_valid => open, debug_trap_1111 => open, debug_trapmake => open,
            debug_pmmu_brief => open, debug_use_base => open, debug_rf_source_addr => open,
            debug_pmove_ea_latched => open, debug_reg_QA => open, debug_last_data_read => open,
            debug_last_opc_pc => open, debug_getbrief => open, debug_get_2ndopc => open,
            debug_fline_brief_pending => open, debug_fline_opcode_pc => open, debug_exe_PC => open,
            debug_memaddr_delta_rega => open, debug_memaddr_delta_regb => open, debug_addsub_q => open,
            debug_memmaskmux => open, debug_fline_opcode_latch => open, debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open, debug_exec_directPC => open, debug_exec_mem_addsub => open,
            debug_set_addrlong => open, debug_mdelta_src => open, debug_pc_brw => open, debug_pc_word => open,
            debug_regfile_d1 => open, debug_regfile_d2 => open, debug_regfile_d3 => open, debug_regfile_d4 => open,
            debug_regfile_d5 => open, debug_regfile_d6 => open, debug_regfile_d7 => open, debug_regfile_a1 => open,
            debug_regfile_a2 => open, debug_regfile_a3 => open, debug_regfile_a4 => open, debug_regfile_a5 => open,
            debug_regfile_a6 => open, debug_regfile_a7 => open, debug_regfile_we => open, debug_regfile_waddr => open,
            debug_regfile_wdata => open, debug_trap_illegal => open, debug_trap_priv => open,
            debug_trap_addr_error => debug_trap_addr_error, debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr, debug_trap_vector => debug_trap_vector,
            debug_pc_add => open, debug_pc_dataa => open, debug_pc_datab => open, debug_pmmu_busy => debug_pmmu_busy,
            debug_cpu_halted => debug_cpu_halted, debug_stop => open, debug_interrupt => open,
            debug_setendOPC => open, debug_IPL_nr => open, debug_micro_state => open, debug_next_micro_state => open,
            debug_memmask => open, debug_sndOPC => open, debug_pmmu_reg_we => open, debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open, debug_pmmu_reg_wdat => open, debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open, debug_make_berr => open, debug_pmmu_fault => debug_pmmu_fault,
            debug_trap_format_error => open, debug_format_error_rte_word => open, debug_format_error_pc => open,
            debug_format_error_addr => open, debug_format_error_sr => open, debug_pmmu_tc => open,
            debug_pmmu_tt0 => open, debug_pmmu_tt1 => open, debug_pmmu_crp_hi => open, debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open, debug_pmmu_srp_lo => open, debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open, debug_pmmu_atc_valid => open, debug_pmmu_fault_status => debug_pmmu_fault_status,
            debug_pmmu_saved_addr => debug_pmmu_saved_addr, debug_pmmu_walk_desc_addr => debug_pmmu_walk_desc_addr, debug_pmmu_walk_desc_data => debug_pmmu_walk_desc_data,
            debug_pmmu_ptr1_desc_addr => open, debug_pmmu_ptr1_desc_data => open, debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open, debug_pmmu_ptr3_desc_addr => open, debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc => open
        );

    mem_read: process(pmmu_addr_phys, mem)
    begin
        if is_x(pmmu_addr_phys) then
            data_in <= x"4E71";
        elsif unsigned(pmmu_addr_phys) < x"00008000" then
            data_in <= mem(to_integer(unsigned(pmmu_addr_phys(14 downto 1))));
        else
            data_in <= x"4E71";
        end if;
    end process;

    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            if pmmu_walker_req = '1' then
                if not is_x(pmmu_walker_addr) and unsigned(pmmu_walker_addr) < x"00008000" then
                    walker_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                    if pmmu_walker_we = '1' then
                        mem(walker_word)     <= pmmu_walker_wdat(31 downto 16);
                        mem(walker_word + 1) <= pmmu_walker_wdat(15 downto 0);
                    else
                        pmmu_walker_data <= mem(walker_word) & mem(walker_word + 1);
                    end if;
                else
                    pmmu_walker_data <= x"00000000";
                end if;
                pmmu_walker_ack <= '1';
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    mem_wait_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';
            else
                mem_wait <= '0';
            end if;
        end if;
    end process;

    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            walker_req_prev <= pmmu_walker_req;
            if walker_req_prev = '1' and pmmu_walker_req = '0' then
                stall_cooldown <= 2;
            elsif stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;
        end if;
    end process;

    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (debug_pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0
                           or mem_wait = '1') else '1';

    main_test: process
        variable marker  : std_logic_vector(31 downto 0);
        variable fail2   : std_logic_vector(31 downto 0);
    begin
        report "=== ODD MMU BADFEED ADDRESS TEST ===" severity note;
        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 12000 loop
            wait until rising_edge(clk);
            marker := mem(16#0F80#) & mem(16#0F81#);
            fail2 := mem(16#0F82#) & mem(16#0F83#);
            if marker = x"00000003" or fail2 = x"DEADBEEF" or debug_cpu_halted = '1' then
                exit;
            end if;
        end loop;

        marker := mem(16#0F80#) & mem(16#0F81#);
        fail2 := mem(16#0F82#) & mem(16#0F83#);

        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted asserted"
                   & " PC=$" & slv_to_hex(debug_TG68_PC)
                   & " trapvec=$" & slv_to_hex(debug_trap_vector)
                   & " trap_berr=" & std_logic'image(debug_trap_berr)
                   & " trap_mmu_berr=" & std_logic'image(debug_trap_mmu_berr)
                   & " trap_addr=" & std_logic'image(debug_trap_addr_error)
                   & " pmmu_fault=" & std_logic'image(debug_pmmu_fault)
                   & " mmusr=$" & slv_to_hex(debug_pmmu_fault_status)
                   & " fault_addr=$" & slv_to_hex(debug_pmmu_saved_addr)
                   & " desc_addr=$" & slv_to_hex(debug_pmmu_walk_desc_addr)
                   & " desc_data=$" & slv_to_hex(debug_pmmu_walk_desc_data)
            severity failure;
        elsif marker = x"00000002" then
            report "PASS: odd BADFEED-backed MMU access took vector 2 MMU/bus fault path" severity note;
        elsif marker = x"00000003" then
            report "FAIL: odd BADFEED-backed MMU access raised vector 3 address error on 68020/030" severity failure;
        elsif fail2 = x"DEADBEEF" then
            report "FAIL: odd BADFEED-backed MMU access retired instead of faulting" severity failure;
        else
            report "FAIL: no decisive exception marker, PC=$" & slv_to_hex(debug_TG68_PC) &
                   " trapvec=$" & slv_to_hex(debug_trap_vector) &
                   " trap_addr=" & std_logic'image(debug_trap_addr_error) &
                   " trap_berr=" & std_logic'image(debug_trap_berr) &
                   " trap_mmu_berr=" & std_logic'image(debug_trap_mmu_berr) &
                   " pmmu_fault=" & std_logic'image(debug_pmmu_fault) &
                   " mmusr=$" & slv_to_hex(debug_pmmu_fault_status) &
                   " fault_addr=$" & slv_to_hex(debug_pmmu_saved_addr) &
                   " desc_addr=$" & slv_to_hex(debug_pmmu_walk_desc_addr) &
                   " desc_data=$" & slv_to_hex(debug_pmmu_walk_desc_data) severity failure;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
