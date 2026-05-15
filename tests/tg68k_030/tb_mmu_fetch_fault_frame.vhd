-- tb_mmu_fetch_fault_frame.vhd
-- Verifies that an MC68030 internal PMMU instruction fetch fault
-- uses the long Format $B bus-fault frame at vector 2, not the short write
-- frame and not the old MC68851-only vector 61 path.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_fetch_fault_frame is
end entity;

architecture behavioral of tb_mmu_fetch_fault_frame is

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

    signal debug_TG68_PC       : std_logic_vector(31 downto 0);
    signal debug_state         : std_logic_vector(1 downto 0);
    signal debug_micro_state   : integer range 0 to 255;
    signal debug_clkena_lw     : std_logic;
    signal debug_trap_berr     : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_pmmu_fault    : std_logic;
    signal debug_cpu_halted    : std_logic;
    signal debug_stop_sig      : std_logic;
    signal debug_pmmu_busy     : std_logic;

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Vector table.
        m(0) := x"0000"; m(1) := x"2000";  -- SSP
        m(2) := x"0000"; m(3) := x"0100";  -- Reset PC
        m(4) := x"0000"; m(5) := x"0080";  -- Vector 2: bus error
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00A0";
        end loop;

        -- Bus error handler: save frame base, format/vector, and fault address, then STOP.
        -- Format $B layout still keeps:
        --   SP+$06 = format/vector, SP+$10 = fault address.
        m(64) := x"23CF"; m(65) := x"0000"; m(66) := x"1F10";  -- MOVE.L A7,$1F10.L
        m(67) := x"302F"; m(68) := x"0006";                    -- MOVE.W ($0006,SP),D0
        m(69) := x"222F"; m(70) := x"0010";                    -- MOVE.L ($0010,SP),D1
        m(71) := x"33C0"; m(72) := x"0000"; m(73) := x"1F14";  -- MOVE.W D0,$1F14.L
        m(74) := x"23C1"; m(75) := x"0000"; m(76) := x"1F18";  -- MOVE.L D1,$1F18.L
        m(77) := x"4E72"; m(78) := x"2700";                    -- STOP #$2700

        -- Unexpected handler (including stale vector 61).
        m(80) := x"2E3C"; m(81) := x"DEAD"; m(82) := x"BEEF";
        m(83) := x"23C7"; m(84) := x"0000"; m(85) := x"1F00";
        m(86) := x"4E72"; m(87) := x"2700";

        -- Main program.
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";  -- PMOVE ($1080).W,CRP
        m(131) := x"F000"; m(132) := x"2400";                      -- PFLUSHA
        m(133) := x"F038"; m(134) := x"4000"; m(135) := x"1088";  -- PMOVE ($1088).W,TC
        m(136) := x"4E71"; m(137) := x"4E71";                    -- Preserve following PC
        m(138) := x"4EF9"; m(139) := x"F000"; m(140) := x"1000";  -- JMP $F0001000

        -- CRP data at $1080; TC data at $1088.
        m(2112) := x"8000"; m(2113) := x"0002";
        m(2114) := x"0000"; m(2115) := x"6000";
        m(2116) := x"80D0"; m(2117) := x"4780";

        -- Root table at $6000: entries 0-14 valid identity maps, entry 15 invalid.
        m(12288) := x"0000"; m(12289) := x"0061";
        m(12290) := x"1000"; m(12291) := x"0061";
        m(12292) := x"2000"; m(12293) := x"0061";
        m(12294) := x"3000"; m(12295) := x"0061";
        m(12296) := x"4000"; m(12297) := x"0061";
        m(12298) := x"5000"; m(12299) := x"0061";
        m(12300) := x"6000"; m(12301) := x"0061";
        m(12302) := x"7000"; m(12303) := x"0061";
        m(12304) := x"8000"; m(12305) := x"0061";
        m(12306) := x"9000"; m(12307) := x"0061";
        m(12308) := x"A000"; m(12309) := x"0061";
        m(12310) := x"B000"; m(12311) := x"0061";
        m(12312) := x"C000"; m(12313) := x"0061";
        m(12314) := x"D000"; m(12315) := x"0061";
        m(12316) := x"E000"; m(12317) := x"0061";
        m(12318) := x"0000"; m(12319) := x"0000";  -- entry 15 invalid

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
            clk              => clk,
            nReset           => nReset,
            clkena_in        => clkena_in,
            data_in          => data_in,
            IPL              => "111",
            IPL_autovector   => '1',
            berr             => '0',
            CPU              => "10",
            addr_out         => addr_out,
            data_write       => data_write,
            nWr              => nWr,
            nUDS             => nUDS,
            nLDS             => nLDS,
            busstate         => busstate,
            longword         => open,
            nResetOut        => open,
            FC               => FC,
            clr_berr         => open,
            skipFetch        => open,
            regin_out        => open,
            CACR_out         => open,
            VBR_out          => open,
            cache_inv_req    => open,
            cache_op_scope   => open,
            cache_op_cache   => open,
            cache_op_addr    => open,
            cacr_ie          => open,
            cacr_de          => open,
            cacr_ifreeze     => open,
            cacr_dfreeze     => open,
            cacr_ibe         => open,
            cacr_dbe         => open,
            cacr_wa          => open,
            pmmu_reg_we      => open,
            pmmu_reg_re      => open,
            pmmu_reg_sel     => open,
            pmmu_reg_wdat    => open,
            pmmu_reg_part    => open,
            pmmu_addr_log    => pmmu_addr_log,
            pmmu_addr_phys   => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode     => open,
            debug_preSVmode  => open,
            debug_FlagsSR_S  => open,
            debug_changeMode => open,
            debug_setopcode  => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode     => open,
            debug_state      => debug_state,
            debug_setstate   => open,
            debug_last_opc_read => open,
            debug_data_read  => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC    => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout     => open,
            debug_decodeOPC  => open,
            debug_brief      => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw  => debug_clkena_lw,
            debug_regfile_d0 => open,
            debug_regfile_a0 => open,
            debug_fline_context_valid => open,
            debug_trap_1111  => open,
            debug_trapmake   => open,
            debug_pmmu_brief => open,
            debug_use_base   => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA     => open,
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
            debug_regfile_a7 => open,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => open,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy  => debug_pmmu_busy,
            debug_cpu_halted => debug_cpu_halted,
            debug_stop       => debug_stop_sig,
            debug_interrupt  => open,
            debug_setendOPC  => open,
            debug_IPL_nr     => open,
            debug_micro_state => debug_micro_state,
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
            debug_pmmu_fault => debug_pmmu_fault,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_pmmu_tc  => open,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open,
            debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open,
            debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open,
            debug_pmmu_atc_valid  => open,
            debug_pmmu_fault_status => open,
            debug_pmmu_saved_addr   => open,
            debug_pmmu_walk_desc_addr => open,
            debug_pmmu_walk_desc_data => open,
            debug_pmmu_ptr1_desc_addr => open,
            debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open,
            debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc       => open
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

    pc_trace: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '1');
    begin
        if rising_edge(clk) then
            if debug_TG68_PC /= prev_pc and debug_clkena_lw = '1' then
                if debug_TG68_PC = x"00000100" then
                    report "PC: $0100 main program start" severity note;
                elsif debug_TG68_PC = x"00000114" then
                    report "PC: $0114 JMP $F0001000 (instruction fetch fault trigger)" severity note;
                elsif debug_TG68_PC = x"00000080" then
                    report "PC: $0080 BUS ERROR HANDLER entered" severity note;
                elsif debug_TG68_PC = x"000000A0" then
                    report "PC: $00A0 UNEXPECTED HANDLER entered" severity warning;
                end if;
                prev_pc := debug_TG68_PC;
            end if;
        end if;
    end process;

    walker_trace: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' and pmmu_walker_ack = '1' and pmmu_walker_we = '0' then
                report "WALKER_READ: addr=0x" & slv_to_hex(pmmu_walker_addr) &
                       " data=0x" & slv_to_hex(pmmu_walker_data) severity note;
            end if;
        end if;
    end process;

    main_test: process
        variable saw_stop       : boolean := false;
        variable saw_halt       : boolean := false;
        variable saw_handler    : boolean := false;
        variable saw_unexpected : boolean := false;
        variable pass_count     : integer := 0;
        variable fail_count     : integer := 0;
        variable result32       : std_logic_vector(31 downto 0);
        variable result16       : std_logic_vector(15 downto 0);
    begin
        report "=== MMU INSTRUCTION FETCH FAULT FRAME TEST ===" severity note;
        report "Target: PMMU instruction fetch fault must use vector 2 with long Format $B frame" severity note;
        report "Setup: root entry 15 invalid, JMP $F0001000 after enabling MMU" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 10000 loop
            wait until rising_edge(clk);

            if debug_clkena_lw = '1' and debug_TG68_PC >= x"00000080" and debug_TG68_PC <= x"0000009A" then
                saw_handler := true;
            end if;

            if debug_clkena_lw = '1' and debug_TG68_PC = x"000000A0" then
                saw_unexpected := true;
            end if;

            if debug_cpu_halted = '1' then
                saw_halt := true;
                exit;
            end if;

            if debug_stop_sig = '1' then
                saw_stop := true;
                exit;
            end if;
        end loop;

        if not saw_stop and not saw_halt then
            report "FAIL: timeout waiting for fault handler or STOP" severity error;
            fail_count := fail_count + 1;
        end if;

        if saw_halt then
            report "FAIL: cpu_halted asserted during instruction-fetch fault handling" severity error;
            fail_count := fail_count + 1;
        else
            report "PASS: cpu_halted stayed low during instruction-fetch fault handling" severity note;
            pass_count := pass_count + 1;
        end if;

        if saw_handler and not saw_unexpected then
            report "PASS: vector 2 bus-error handler ran for the PMMU fetch fault" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: expected vector 2 handler, but saw unexpected trap path" severity error;
            fail_count := fail_count + 1;
        end if;

        result32 := mem(to_integer(unsigned'(x"0F80"))) & mem(to_integer(unsigned'(x"0F81")));
        if result32 /= x"DEADBEEF" then
            report "PASS: vector 61 / unexpected handler marker not observed" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: unexpected handler marker DEADBEEF observed at $1F00" severity error;
            fail_count := fail_count + 1;
        end if;

        result32 := mem(to_integer(unsigned'(x"0F88"))) & mem(to_integer(unsigned'(x"0F89")));
        if result32 = x"00001FA4" then
            report "PASS: long bus-fault frame base saved as $00001FA4" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: saved A7/frame base = $" & slv_to_hex(result32) &
                   " (expected $00001FA4 for long Format $B frame)" severity error;
            fail_count := fail_count + 1;
        end if;

        result16 := mem(to_integer(unsigned'(x"0F8A")));
        if result16 = x"B008" then
            report "PASS: format/vector word = $B008 (Format $B, vector 2)" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: format/vector word = $" & slv_to_hex(result16) &
                   " (expected $B008)" severity error;
            fail_count := fail_count + 1;
        end if;

        result32 := mem(to_integer(unsigned'(x"0F8C"))) & mem(to_integer(unsigned'(x"0F8D")));
        if result32 = x"F0001000" then
            report "PASS: fault address saved as $F0001000" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: fault address = $" & slv_to_hex(result32) &
                   " (expected $F0001000)" severity error;
            fail_count := fail_count + 1;
        end if;

        report "========================================" severity note;
        report "TOTAL: " & integer'image(pass_count + fail_count) & " tests, " &
               integer'image(pass_count) & " passed, " &
               integer'image(fail_count) & " failed" severity note;
        if fail_count = 0 then
            report "*** ALL MMU FETCH FAULT FRAME TESTS PASSED ***" severity note;
        else
            report "*** SOME MMU FETCH FAULT FRAME TESTS FAILED ***" severity error;
        end if;
        report "========================================" severity note;

        test_done <= true;
        wait;
    end process;

end behavioral;
