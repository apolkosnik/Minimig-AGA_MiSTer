-- tb_mmu_user_data_fault_recovery.vhd
-- Regression: user-mode PMMU data access fault must build vector-2 long frame,
-- save user SR in the frame, RTE back to the next user instruction, and keep
-- the machine running.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_user_data_fault_recovery is
end entity;

architecture behavioral of tb_mmu_user_data_fault_recovery is

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

    signal debug_TG68_PC       : std_logic_vector(31 downto 0);
    signal debug_state         : std_logic_vector(1 downto 0);
    signal debug_micro_state   : integer range 0 to 255;
    signal debug_clkena_lw     : std_logic;
    signal debug_trap_berr     : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_make_berr     : std_logic;
    signal debug_pmmu_fault    : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);
    signal debug_cpu_halted    : std_logic;
    signal debug_stop_sig      : std_logic;
    signal debug_pmmu_busy     : std_logic;
    signal debug_SVmode        : std_logic;

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- TC = $80D04780: 8KB pages, root early-termination table
    -- CRP_H = $80000002, CRP_L = $00006000
    -- Entry 13 is invalid so a user-mode MOVE.L $DFFFFFFC,D0 triggers vector 2.
    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Reset vectors: SSP=$2000, PC=$0100
        m(0) := x"0000"; m(1) := x"2000";
        m(2) := x"0000"; m(3) := x"0100";

        -- Vector 2: Bus error -> $0080
        m(4) := x"0000"; m(5) := x"0080";

        -- Other vectors -> unexpected trap handler $00C8
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00C8";
        end loop;

        -- Bus error handler at $0080.
        -- Save frame details, mark DF, then RTE.
        -- BTST #0,($0A,SP) -> DF bit from SSW
        m(64) := x"082F"; m(65) := x"0000"; m(66) := x"000A";
        -- BEQ.B $00C0 if DF=0
        m(67) := x"671C";
        -- MOVE.L #$AA550001,$1F20.L
        m(68) := x"23FC"; m(69) := x"AA55"; m(70) := x"0001";
        m(71) := x"0000"; m(72) := x"1F20";
        -- MOVE.L A7,$1F24.L
        m(73) := x"23CF"; m(74) := x"0000"; m(75) := x"1F24";
        -- MOVE.W (A7),$1F28.L      ; stacked SR
        m(76) := x"33D7"; m(77) := x"0000"; m(78) := x"1F28";
        -- MOVE.L 2(A7),$1F2C.L     ; stacked PC
        m(79) := x"23EF"; m(80) := x"0002"; m(81) := x"0000"; m(82) := x"1F2C";
        -- MOVE.W 6(A7),$1F30.L     ; format/vector word
        m(83) := x"33EF"; m(84) := x"0006"; m(85) := x"0000"; m(86) := x"1F30";
        -- MOVE.W $0A(A7),$1F32.L   ; SSW
        m(87) := x"33EF"; m(88) := x"000A"; m(89) := x"0000"; m(90) := x"1F32";
        -- MOVE.L $10(A7),$1F34.L   ; fault address
        m(91) := x"23EF"; m(92) := x"0010"; m(93) := x"0000"; m(94) := x"1F34";
        -- ADDQ.L #6,$02(SP) - advance stacked PC past the 6-byte faulting
        -- MOVE.L abs.L,Dn instruction. The page tables still mark entry 13
        -- invalid, so without this RTE would return to the same instruction
        -- and re-fault forever. Real bus-error handlers must either fix the
        -- underlying issue or skip the access.
        m(95) := x"5CAF"; m(96) := x"0002";
        -- RTE
        m(97) := x"4E73";

        -- Unexpected trap handler at $00C8
        m(100) := x"2E3C"; m(101) := x"FF00"; m(102) := x"0000";
        m(103) := x"23C7"; m(104) := x"0000"; m(105) := x"1F00";
        m(106) := x"4E72"; m(107) := x"2700";

        -- Main program at $0100
        -- PMOVE ($1080).W,CRP
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";
        -- PFLUSHA
        m(131) := x"F000"; m(132) := x"2400";
        -- PMOVE ($1088).W,TC
        m(133) := x"F038"; m(134) := x"4000"; m(135) := x"1088";
        -- NOP padding keeps user-mode transition at the same PC.
        m(136) := x"4E71"; m(137) := x"4E71";
        -- MOVE #$0000,SR   ; enter user mode
        m(138) := x"46FC"; m(139) := x"0000";
        -- MOVE.L $DFFFFFFC,D0 ; user-data MMU access fault
        m(140) := x"2039"; m(141) := x"DFFF"; m(142) := x"FFFC";
        -- MOVE.L #$55AA0001,$1F00.L ; must execute after RTE
        m(143) := x"23FC"; m(144) := x"55AA"; m(145) := x"0001";
        m(146) := x"0000"; m(147) := x"1F00";
        -- BRA.S *-2
        m(148) := x"60FE";

        -- CRP at $1080; TC at $1088.
        m(2112) := x"8000"; m(2113) := x"0002";
        m(2114) := x"0000"; m(2115) := x"6000";
        m(2116) := x"80D0"; m(2117) := x"4780";

        -- Root table at $6000, 16 entries. Entry 13 invalid.
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
        m(12314) := x"0000"; m(12315) := x"0000"; -- entry 13 invalid
        m(12316) := x"E000"; m(12317) := x"0061";
        m(12318) := x"F000"; m(12319) := x"0061";

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
            debug_SVmode     => debug_SVmode,
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
            debug_trap_vector => debug_trap_vector,
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
            debug_make_berr => debug_make_berr,
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

    main_test: process
        variable marker      : std_logic_vector(31 downto 0);
        variable df_marker   : std_logic_vector(31 downto 0);
        variable frame_base  : std_logic_vector(31 downto 0);
        variable stacked_sr  : std_logic_vector(15 downto 0);
        variable stacked_pc  : std_logic_vector(31 downto 0);
        variable fmtvec      : std_logic_vector(15 downto 0);
        variable ssw         : std_logic_vector(15 downto 0);
        variable fault_addr  : std_logic_vector(31 downto 0);
    begin
        report "=== USER-MODE MMU DATA FAULT RECOVERY TEST ===" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 50000 loop
            wait until rising_edge(clk);
            marker := mem(16#0F80#) & mem(16#0F81#);
            if marker = x"55AA0001" or debug_cpu_halted = '1' then
                exit;
            end if;
        end loop;

        marker := mem(16#0F80#) & mem(16#0F81#);
        df_marker := mem(16#0F90#) & mem(16#0F91#);
        frame_base := mem(16#0F92#) & mem(16#0F93#);
        stacked_sr := mem(16#0F94#);
        stacked_pc := mem(16#0F96#) & mem(16#0F97#);
        fmtvec := mem(16#0F98#);
        ssw := mem(16#0F99#);
        fault_addr := mem(16#0F9A#) & mem(16#0F9B#);

        report "DIAG: marker=$" & slv_to_hex(marker) &
               " df=$" & slv_to_hex(df_marker) &
               " A7=$" & slv_to_hex(frame_base) severity note;
        report "DIAG: PC=$" & slv_to_hex(stacked_pc) &
               " SR=$" & slv_to_hex(stacked_sr) &
               " fmtvec=$" & slv_to_hex(fmtvec) severity note;
        report "DIAG: SSW=$" & slv_to_hex(ssw) &
               " fault_addr=$" & slv_to_hex(fault_addr) severity note;
        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted asserted on user-mode MMU data fault" severity error;
        elsif df_marker /= x"AA550001" then
            report "FAIL: handler did not confirm DF=1, got $" & slv_to_hex(df_marker) severity error;
        elsif marker /= x"55AA0001" then
            report "FAIL: user code after RTE did not execute, marker=$" & slv_to_hex(marker) severity error;
        elsif stacked_sr(13) /= '0' then
            report "FAIL: stacked SR S-bit was not user mode, SR=$" & slv_to_hex(stacked_sr) severity error;
        elsif stacked_pc /= x"00000118" then
            -- Per WinUAE exception_pc() in newcpu_common.cpp:1399, vector 2
            -- stacks regs.instruction_pc (the faulting instruction's PC),
            -- not the post-instruction PC. The handler skips past it via
            -- ADDQ.L #6,2(SP) above.
            report "FAIL: stacked PC=$" & slv_to_hex(stacked_pc) & " expected $00000118" severity error;
        elsif frame_base /= x"00001FA4" then
            report "FAIL: handler saved A7=$" & slv_to_hex(frame_base) & " expected $00001FA4" severity error;
        elsif fmtvec(15 downto 12) /= x"B" then
            report "FAIL: format/vector word=$" & slv_to_hex(fmtvec) & " expected Format $B" severity error;
        elsif ssw(8) /= '1' or ssw(6) /= '1' or ssw(5 downto 4) /= "00" then
            report "FAIL: SSW=$" & slv_to_hex(ssw) & " expected DF=1 RW=1 SIZE=long" severity error;
        elsif fault_addr /= x"DFFFFFFC" then
            report "FAIL: fault address=$" & slv_to_hex(fault_addr) & " expected $DFFFFFFC" severity error;
        else
            report "PASS: user-mode MMU data fault recovered via vector 2 long frame and RTE" severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
