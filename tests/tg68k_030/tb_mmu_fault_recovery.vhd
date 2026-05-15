-- tb_mmu_fault_recovery.vhd
-- Tests PMMU fault recovery: MMU enabled with partial page table, first access
-- faults (invalid descriptor), exception processing completes correctly, no
-- spurious double bus fault (cpu_halted should NOT fire).
--
-- Scenario: 15 valid identity-mapped root entries + 1 invalid (DT=00) entry 15
-- Program accesses $F0001000 (entry 15 = INVALID) -> fault -> bus error dispatched
-- -> berr frame pushed to SSP ($2000, entry 0 = valid) -> handler at $0080 (entry 0 = valid)
-- Expected: cpu_halted='0', handler reaches STOP, no spurious double fault

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_fault_recovery is
end entity;

architecture behavioral of tb_mmu_fault_recovery is

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

    signal pmmu_addr_phys    : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_addr_log     : std_logic_vector(31 downto 0);

    signal debug_TG68_PC      : std_logic_vector(31 downto 0);
    signal debug_state        : std_logic_vector(1 downto 0);
    signal debug_micro_state  : integer range 0 to 255;
    signal debug_clkena_lw    : std_logic;
    signal debug_trap_berr    : std_logic;
    signal debug_trap_mmu_berr: std_logic;
    signal debug_make_berr    : std_logic;
    signal debug_pmmu_fault   : std_logic;
    signal debug_trap_vector  : std_logic_vector(31 downto 0);
    signal debug_cpu_halted   : std_logic;
    signal debug_stop_sig     : std_logic;
    signal debug_pmmu_busy    : std_logic;
    signal debug_memmask      : std_logic_vector(5 downto 0);

    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';
    signal mem_wait : std_logic := '0';

    -- Memory: 32KB ($0000-$7FFF)
    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- Page table configuration:
    -- TC = $80D04780: E=1, PS=13(8KB), IS=0, TIA=4, TIB=7, TIC=8, TID=0
    -- CRP_H = $80000002, CRP_L = $00006000 (root table at $6000)
    -- Root table: 16 entries (TIA=4, 2^4=16), each covers 256MB (shift=28)
    -- Entries 0-14: valid identity mapping ($xx000061, DT=01 early-term)
    -- Entry 15: INVALID ($00000000, DT=00) -> fault when $F0xxxxxx accessed
    -- SSP=$2000 (entry 0, identity mapped -> berr frame writes OK)
    -- Handler at $0080 (entry 0 -> fetch OK)
    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        -- Vector table ($0000-$00FF)
        -- Vector 0: SSP = $00002000
        m(0) := x"0000"; m(1) := x"2000";
        -- Vector 1: Reset PC = $00000100
        m(2) := x"0000"; m(3) := x"0100";
        -- Vector 2: Bus Error -> $0080
        m(4) := x"0000"; m(5) := x"0080";
        -- All other vectors -> unexpected handler $00A0
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00A0";
        end loop;
        -- BUS ERROR HANDLER at $0080
        -- $0080: MOVE.L #$CAFE0001,D7
        m(64) := x"2E3C"; m(65) := x"CAFE"; m(66) := x"0001";
        -- $0086: MOVE.L D7,$1F00.L
        m(67) := x"23C7"; m(68) := x"0000"; m(69) := x"1F00";
        -- $008C: STOP #$2700
        m(70) := x"4E72"; m(71) := x"2700";

        -- UNEXPECTED HANDLER at $00A0
        m(80) := x"2E3C"; m(81) := x"DEAD"; m(82) := x"BEEF";
        m(83) := x"23C7"; m(84) := x"0000"; m(85) := x"1F00";
        m(86) := x"4E72"; m(87) := x"2700";

        -- MAIN PROGRAM at $0100
        -- PMOVE ($1080).W,CRP   ; 6 bytes
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";
        -- PFLUSHA               ; 4 bytes
        m(131) := x"F000"; m(132) := x"2400";
        -- PMOVE ($1088).W,TC    ; 6 bytes (enable MMU from memory)
        m(133) := x"F038"; m(134) := x"4000"; m(135) := x"1088";
        -- NOP padding keeps the faulting access at the same PC.
        m(136) := x"4E71"; m(137) := x"4E71";
        -- MOVE.L $F0001000.L,D1 ; 6 bytes (access invalid entry 15)
        m(138) := x"2239"; m(139) := x"F000"; m(140) := x"1000";
        -- If RTE returns here:
        -- MOVE.L #$AA550001,$1F04.L ; 10 bytes
        m(141) := x"23FC"; m(142) := x"AA55"; m(143) := x"0001";
        m(144) := x"0000"; m(145) := x"1F04";
        -- STOP #$2700
        m(146) := x"4E72"; m(147) := x"2700";

        -- CRP data at $1080; TC data at $1088.
        m(2112) := x"8000"; m(2113) := x"0002";  -- CRP_H = $80000002
        m(2114) := x"0000"; m(2115) := x"6000";  -- CRP_L = $00006000
        m(2116) := x"80D0"; m(2117) := x"4780";

        -- Root page table at $6000 (word index 12288 = $3000)
        -- 16 entries, each 4 bytes (short format), covering 256MB each
        -- Entries 0-14: identity mapping ($xx000061, DT=01 early-term, CI=1)
        m(12288) := x"0000"; m(12289) := x"0061";  -- entry 0:  $00000000 region
        m(12290) := x"1000"; m(12291) := x"0061";  -- entry 1:  $10000000 region
        m(12292) := x"2000"; m(12293) := x"0061";  -- entry 2
        m(12294) := x"3000"; m(12295) := x"0061";  -- entry 3
        m(12296) := x"4000"; m(12297) := x"0061";  -- entry 4
        m(12298) := x"5000"; m(12299) := x"0061";  -- entry 5
        m(12300) := x"6000"; m(12301) := x"0061";  -- entry 6
        m(12302) := x"7000"; m(12303) := x"0061";  -- entry 7
        m(12304) := x"8000"; m(12305) := x"0061";  -- entry 8
        m(12306) := x"9000"; m(12307) := x"0061";  -- entry 9
        m(12308) := x"A000"; m(12309) := x"0061";  -- entry 10
        m(12310) := x"B000"; m(12311) := x"0061";  -- entry 11
        m(12312) := x"C000"; m(12313) := x"0061";  -- entry 12
        m(12314) := x"D000"; m(12315) := x"0061";  -- entry 13
        m(12316) := x"E000"; m(12317) := x"0061";  -- entry 14
        -- Entry 15: INVALID (DT=00) - $F0xxxxxx is unmapped
        m(12318) := x"0000"; m(12319) := x"0000";  -- entry 15: INVALID

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
            debug_memmask => debug_memmask,
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

    -- Memory read: combinational from physical address
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

    -- Unified memory write + walker response
    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            -- CPU writes to main memory
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and
                   unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            -- Walker response (same cycle as request)
            if pmmu_walker_req = '1' then
                if not is_x(pmmu_walker_addr) and
                   unsigned(pmmu_walker_addr) < x"00008000" then
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

    -- Memory wait state
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

    -- CPU stall control
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

    -- PC trace
    pc_trace: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '1');
    begin
        if rising_edge(clk) then
            if debug_TG68_PC /= prev_pc and debug_clkena_lw = '1' then
                if debug_TG68_PC = x"00000100" then
                    report "PC: $0100 main program start" severity note;
                elsif debug_TG68_PC = x"00000114" then
                    report "PC: $0114 MOVE.L $F0001000,D1 (fault trigger)" severity note;
                elsif debug_TG68_PC = x"00000080" then
                    report "PC: $0080 BUS ERROR HANDLER entered" severity note;
                elsif debug_TG68_PC = x"0000008C" then
                    report "PC: $008C STOP reached in handler" severity note;
                elsif debug_TG68_PC = x"000000A0" then
                    report "PC: $00A0 UNEXPECTED HANDLER! Wrong exception vector" severity warning;
                end if;
                prev_pc := debug_TG68_PC;
            end if;
        end if;
    end process;

    -- Walker activity trace
    walker_trace: process(clk)
    begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' and pmmu_walker_ack = '1' then
                if pmmu_walker_we = '1' then
                    report "WALKER_WRITE: addr=0x" & slv_to_hex(pmmu_walker_addr) &
                           " data=0x" & slv_to_hex(pmmu_walker_wdat) severity note;
                else
                    report "WALKER_READ: addr=0x" & slv_to_hex(pmmu_walker_addr) &
                           " data=0x" & slv_to_hex(pmmu_walker_data) severity note;
                end if;
            end if;
        end if;
    end process;

    -- Main test process
    main_test: process
        variable saw_handler : boolean := false;
        variable saw_halt    : boolean := false;
        variable saw_stop    : boolean := false;
        variable cycle_count : integer := 0;
    begin
        report "=== MMU FAULT RECOVERY TEST ===" severity note;
        report "Partial page table: entry 15 ($F0xxxxxx) is INVALID (DT=00)" severity note;
        report "Expected: PMMU fault -> bus error vector 2 -> handler at $0080 -> STOP" severity note;
        report "Expected: cpu_halted=0 (no spurious double fault)" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 10000 loop
            wait until rising_edge(clk);
            cycle_count := i;

            -- Detect handler entry via PC
            if debug_clkena_lw = '1' and
               debug_TG68_PC >= x"00000080" and
               debug_TG68_PC <= x"0000008E" then
                saw_handler := true;
            end if;

            -- Detect STOP
            if debug_stop_sig = '1' then
                saw_stop := true;
            end if;

            -- Detect cpu_halted (should NOT happen)
            if debug_cpu_halted = '1' then
                saw_halt := true;
                report "HALT DETECTED at cycle " & integer'image(i) &
                       ": trap_berr=" & std_logic'image(debug_trap_berr) &
                       " trap_mmu_berr=" & std_logic'image(debug_trap_mmu_berr) &
                       " pmmu_fault=" & std_logic'image(debug_pmmu_fault) severity warning;
                exit;
            end if;

            -- Stop if we've seen handler and then STOP
            if saw_handler and saw_stop then
                exit;
            end if;

            -- Timeout safety: if handler seen but STOP not reached in another 2000 cycles
            if saw_handler and i > cycle_count + 2000 then
                exit;
            end if;
        end loop;

        report "========================================" severity note;
        if saw_halt then
            report "SCENARIO FAILED: cpu_halted fired (spurious double fault!)" severity error;
            report "  Make berr logic may have a false-positive trigger" severity error;
        elsif saw_handler and saw_stop then
            report "SCENARIO PASSED: Handler reached and STOP executed, no double fault" severity note;
        elsif saw_handler then
            report "SCENARIO PARTIAL: Handler entered but STOP not detected" severity warning;
        else
            report "SCENARIO FAILED: Handler never reached (10000 cycle timeout)" severity error;
        end if;
        report "========================================" severity note;

        test_done <= true;
        wait;
    end process;

end behavioral;
