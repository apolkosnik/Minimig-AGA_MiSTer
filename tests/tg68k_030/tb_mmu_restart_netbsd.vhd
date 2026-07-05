-- tb_mmu_restart_netbsd.vhd
--
-- NetBSD demand-paging contract test for MMU fault RESTART semantics
-- (MMU_RESTART_DESIGN.md). The bus-error handler does exactly what
-- NetBSD/amiga does: read fault address from the frame, fix the page
-- table entry, PFLUSH #0,#0,(va) (= NetBSD TBIS), then execute a plain
-- RTE with an UNMODIFIED frame. The faulted instruction must re-execute
-- correctly:
--   Test 1: MOVE.L (A0)+,D2 read fault  -> D2 loaded, A0 incremented ONCE
--   Test 2: MOVE.L D3,-(A2) write fault -> memory written, A2 decremented ONCE
--   Test 3: ADD.L (A5),D5 read fault    -> sum and CCR (X/Z/C) correct
--   Test 4: MOVEM.L D4-D7,(A3) write fault on first transfer -> all 4 stored
--   Test 5: MOVEM.L (A4)+,D4-D7 crossing into an invalid page (fault on the
--           3rd transfer) -> partial loads rolled back, all 4 reloaded,
--           A4 advanced ONCE
-- Page tables: 3-level short format (TC=$80D04780: 8K pages, TIA=4/TIB=7/TIC=8),
-- root entries 0-12,14,15 early-termination identity, entry 13 -> B table ->
-- C table with initially-invalid page descriptors the handler fills in.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_restart_netbsd is
end entity;

architecture behavioral of tb_mmu_restart_netbsd is

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

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
        variable w : integer;
    begin
        -- Reset vectors: SSP=$2000, PC=$0100
        m(0) := x"0000"; m(1) := x"2000";
        m(2) := x"0000"; m(3) := x"0100";
        -- Vector 2: bus error -> $0400
        m(4) := x"0000"; m(5) := x"0400";
        -- All other vectors -> unexpected trap handler $04C0
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"04C0";
        end loop;

        ------------------------------------------------------------------
        -- Main program at $0100 (supervisor mode throughout)
        ------------------------------------------------------------------
        w := 128;
        -- PMOVE ($1080).W,CRP ; PFLUSHA ; PMOVE ($1088).W,TC
        m(w) := x"F038"; m(w+1) := x"4C00"; m(w+2) := x"1080"; w := w+3;
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;
        m(w) := x"F038"; m(w+1) := x"4000"; m(w+2) := x"1088"; w := w+3;
        -- Test 1: read fault, postincrement rollback ($0110)
        m(w) := x"41F9"; m(w+1) := x"D000"; m(w+2) := x"2100"; w := w+3;  -- LEA $D0002100,A0
        m(w) := x"7400"; w := w+1;                                        -- MOVEQ #0,D2
        m(w) := x"2418"; w := w+1;                                        -- MOVE.L (A0)+,D2  FAULT 1 @$0118
        m(w) := x"23C2"; m(w+1) := x"0000"; m(w+2) := x"1020"; w := w+3;  -- MOVE.L D2,$1020
        m(w) := x"23C8"; m(w+1) := x"0000"; m(w+2) := x"1024"; w := w+3;  -- MOVE.L A0,$1024
        -- Test 2: write fault, predecrement rollback
        m(w) := x"45F9"; m(w+1) := x"D000"; m(w+2) := x"4010"; w := w+3;  -- LEA $D0004010,A2
        m(w) := x"263C"; m(w+1) := x"1234"; m(w+2) := x"5678"; w := w+3;  -- MOVE.L #$12345678,D3
        m(w) := x"2503"; w := w+1;                                        -- MOVE.L D3,-(A2)  FAULT 2
        m(w) := x"23CA"; m(w+1) := x"0000"; m(w+2) := x"1028"; w := w+3;  -- MOVE.L A2,$1028
        -- Test 3: ADD.L read fault, CCR/X integrity
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5404"; w := w+3;  -- CLR.L $5404 (invalidate C entry 1)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"44FC"; m(w+1) := x"0000"; w := w+2;                     -- MOVE #$0000,CCR
        m(w) := x"7A01"; w := w+1;                                        -- MOVEQ #1,D5
        m(w) := x"4BF9"; m(w+1) := x"D000"; m(w+2) := x"2108"; w := w+3;  -- LEA $D0002108,A5
        m(w) := x"DA95"; w := w+1;                                        -- ADD.L (A5),D5   FAULT 3
        m(w) := x"23C5"; m(w+1) := x"0000"; m(w+2) := x"102C"; w := w+3;  -- MOVE.L D5,$102C
        m(w) := x"40F9"; m(w+1) := x"0000"; m(w+2) := x"1030"; w := w+3;  -- MOVE.W SR,$1030
        -- Test 4: MOVEM store fault on first transfer
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5408"; w := w+3;  -- CLR.L $5408 (invalidate C entry 2)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"47F9"; m(w+1) := x"D000"; m(w+2) := x"4100"; w := w+3;  -- LEA $D0004100,A3
        m(w) := x"283C"; m(w+1) := x"0D0D"; m(w+2) := x"0D01"; w := w+3;  -- MOVE.L #$0D0D0D01,D4
        m(w) := x"2A3C"; m(w+1) := x"0D0D"; m(w+2) := x"0D02"; w := w+3;  -- MOVE.L #$0D0D0D02,D5
        m(w) := x"2C3C"; m(w+1) := x"0D0D"; m(w+2) := x"0D03"; w := w+3;  -- MOVE.L #$0D0D0D03,D6
        m(w) := x"2E3C"; m(w+1) := x"0D0D"; m(w+2) := x"0D04"; w := w+3;  -- MOVE.L #$0D0D0D04,D7
        m(w) := x"48D3"; m(w+1) := x"00F0"; w := w+2;                     -- MOVEM.L D4-D7,(A3)  FAULT 4
        -- Test 5: MOVEM load crossing into invalid page (fault mid-transfer)
        m(w) := x"49F9"; m(w+1) := x"D000"; m(w+2) := x"5FF8"; w := w+3;  -- LEA $D0005FF8,A4
        m(w) := x"4CDC"; m(w+1) := x"00F0"; w := w+2;                     -- MOVEM.L (A4)+,D4-D7  FAULT 5
        m(w) := x"23CC"; m(w+1) := x"0000"; m(w+2) := x"1034"; w := w+3;  -- MOVE.L A4,$1034
        m(w) := x"48F9"; m(w+1) := x"00F0"; m(w+2) := x"0000"; m(w+3) := x"1040"; w := w+4;  -- MOVEM.L D4-D7,$1040
        -- Test 6: USER-MODE fault (exception stacking crosses the A7<-SSP
        -- changeMode swap; the swap-wait cycle must not eat a berr_fill push)
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5404"; w := w+3;  -- CLR.L $5404 (invalidate C entry 1)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"227C"; m(w+1) := x"0000"; m(w+2) := x"1800"; w := w+3;  -- MOVEA.L #$1800,A1
        m(w) := x"4E61"; w := w+1;                                        -- MOVE A1,USP
        m(w) := x"4DF9"; m(w+1) := x"D000"; m(w+2) := x"2120"; w := w+3;  -- LEA $D0002120,A6
        m(w) := x"7C00"; w := w+1;                                        -- MOVEQ #0,D6
        m(w) := x"46FC"; m(w+1) := x"0000"; w := w+2;                     -- MOVE #$0000,SR (enter user mode)
        m(w) := x"2C16"; w := w+1;                                        -- MOVE.L (A6),D6  FAULT 6 (user mode)
        m(w) := x"23C6"; m(w+1) := x"0000"; m(w+2) := x"1038"; w := w+3;  -- MOVE.L D6,$1038
        -- Done marker
        m(w) := x"23FC"; m(w+1) := x"C0DE"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"1004"; w := w+5;                   -- MOVE.L #$C0DE600D,$1004
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S *

        ------------------------------------------------------------------
        -- Bus error handler at $0400: NetBSD-style. Fix the PTE from the
        -- fault address, PFLUSH the page, RTE with UNMODIFIED frame.
        ------------------------------------------------------------------
        w := 512;
        m(w) := x"48E7"; m(w+1) := x"C0C0"; w := w+2;                     -- MOVEM.L D0-D1/A0-A1,-(SP)
        m(w) := x"226F"; m(w+1) := x"0020"; w := w+2;                     -- MOVEA.L $20(SP),A1  (fault addr, frame $10+16)
        m(w) := x"23C9"; m(w+1) := x"0000"; m(w+2) := x"1010"; w := w+3;  -- MOVE.L A1,$1010
        m(w) := x"33EF"; m(w+1) := x"001A";
        m(w+2) := x"0000"; m(w+3) := x"1014"; w := w+4;                   -- MOVE.W $1A(SP),$1014 (SSW, frame $0A+16)
        m(w) := x"23EF"; m(w+1) := x"0012";
        m(w+2) := x"0000"; m(w+3) := x"1018"; w := w+4;                   -- MOVE.L $12(SP),$1018 (stacked PC, frame $02+16)
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"103C"; w := w+3;  -- MOVE.L A7,$103C (stack-balance check)
        m(w) := x"52B9"; m(w+1) := x"0000"; m(w+2) := x"1000"; w := w+3;  -- ADDQ.L #1,$1000 (fault count)
        m(w) := x"2009"; w := w+1;                                        -- MOVE.L A1,D0
        m(w) := x"0280"; m(w+1) := x"0000"; m(w+2) := x"6000"; w := w+3;  -- ANDI.L #$6000,D0 (page phys base)
        m(w) := x"2200"; w := w+1;                                        -- MOVE.L D0,D1
        m(w) := x"0080"; m(w+1) := x"0000"; m(w+2) := x"0001"; w := w+3;  -- ORI.L #1,D0 (page descriptor DT=01)
        m(w) := x"E089"; w := w+1;                                        -- LSR.L #8,D1
        m(w) := x"E689"; w := w+1;                                        -- LSR.L #3,D1  ((addr&$6000)>>11)
        m(w) := x"0681"; m(w+1) := x"0000"; m(w+2) := x"5400"; w := w+3;  -- ADDI.L #$5400,D1 (C-table slot)
        m(w) := x"2041"; w := w+1;                                        -- MOVEA.L D1,A0
        m(w) := x"2080"; w := w+1;                                        -- MOVE.L D0,(A0)  fix PTE
        m(w) := x"F011"; m(w+1) := x"3810"; w := w+2;                     -- PFLUSH #0,#0,(A1)  = NetBSD TBIS(va)
        m(w) := x"4CDF"; m(w+1) := x"0303"; w := w+2;                     -- MOVEM.L (SP)+,D0-D1/A0-A1
        m(w) := x"4E73"; w := w+1;                                        -- RTE (frame unmodified)

        -- Unexpected trap handler at $04C0
        w := 608;
        m(w) := x"23FC"; m(w+1) := x"DEAD"; m(w+2) := x"DEAD";
        m(w+3) := x"0000"; m(w+4) := x"1008"; w := w+5;                   -- MOVE.L #$DEADDEAD,$1008
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP #$2700

        ------------------------------------------------------------------
        -- Results area $1000-$107F zeroed
        ------------------------------------------------------------------
        for i in 2048 to 2111 loop
            m(i) := x"0000";
        end loop;

        -- CRP at $1080 = $80000002:$00005000 ; TC at $1088 = $80D04780
        m(2112) := x"8000"; m(2113) := x"0002";
        m(2114) := x"0000"; m(2115) := x"5000";
        m(2116) := x"80D0"; m(2117) := x"4780";

        ------------------------------------------------------------------
        -- Test data
        ------------------------------------------------------------------
        m(16#1080#) := x"CAFE"; m(16#1081#) := x"BABE";  -- phys $2100
        m(16#1084#) := x"FFFF"; m(16#1085#) := x"FFFF";  -- phys $2108
        m(16#1090#) := x"FEED"; m(16#1091#) := x"F00D";  -- phys $2120 (user-mode test)
        m(16#2FFC#) := x"AABB"; m(16#2FFD#) := x"0001";  -- phys $5FF8
        m(16#2FFE#) := x"AABB"; m(16#2FFF#) := x"0002";  -- phys $5FFC
        m(16#3000#) := x"AABB"; m(16#3001#) := x"0003";  -- phys $6000
        m(16#3002#) := x"AABB"; m(16#3003#) := x"0004";  -- phys $6004

        ------------------------------------------------------------------
        -- Page tables (zero $5000-$57FF first: word idx 10240..11263)
        ------------------------------------------------------------------
        for i in 10240 to 11263 loop
            m(i) := x"0000";
        end loop;
        -- Root table at $5000: early-termination identity descriptors,
        -- entry 13 -> short table descriptor to B table at $5100
        for n in 0 to 15 loop
            if n = 13 then
                m(10240 + n*2)     := x"0000";
                m(10240 + n*2 + 1) := x"5102";
            else
                m(10240 + n*2)     := std_logic_vector(to_unsigned(n, 4)) & x"000";
                m(10240 + n*2 + 1) := x"0061";
            end if;
        end loop;
        -- B table at $5100: entry 0 -> C table at $5400, rest invalid
        m(10368) := x"0000"; m(10369) := x"5402";
        -- C table at $5400: all entries invalid (handler fills 1,2,3)

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
                    if nUDS = '0' and nLDS = '0' then
                        mem(phys_word) <= data_write;
                    elsif nUDS = '0' then
                        mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                    elsif nLDS = '0' then
                        mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                    if unsigned(pmmu_addr_phys(14 downto 1)) >= x"2000" then
                        report "TBMEM: cpu write phys=" & slv_to_hex(pmmu_addr_phys(15 downto 0)) &
                               " data=" & slv_to_hex(data_write) &
                               " uds=" & std_logic'image(nUDS) & " lds=" & std_logic'image(nLDS) severity note;
                    end if;
                elsif not is_x(pmmu_addr_phys) then
                    report "TBMEM: cpu write OUT OF RANGE phys=" & slv_to_hex(pmmu_addr_phys) &
                           " data=" & slv_to_hex(data_write) severity note;
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

    read_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "10" and clkena_in = '1' and not is_x(pmmu_addr_log) then
                if pmmu_addr_log(31 downto 28) = x"D" then
                    report "TBMEM: cpu read log=" & slv_to_hex(pmmu_addr_log) &
                           " phys=" & slv_to_hex(pmmu_addr_phys) &
                           " data=" & slv_to_hex(data_in) severity note;
                end if;
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
        variable fault_count : std_logic_vector(31 downto 0);
        variable done_mark   : std_logic_vector(31 downto 0);
        variable unexp_mark  : std_logic_vector(31 downto 0);
        variable last_fa     : std_logic_vector(31 downto 0);
        variable last_ssw    : std_logic_vector(15 downto 0);
        variable last_pc     : std_logic_vector(31 downto 0);
        variable pc_opcode   : std_logic_vector(15 downto 0);
        variable t1_d2       : std_logic_vector(31 downto 0);
        variable t1_a0       : std_logic_vector(31 downto 0);
        variable t2_a2       : std_logic_vector(31 downto 0);
        variable t2_mem      : std_logic_vector(31 downto 0);
        variable t3_d5       : std_logic_vector(31 downto 0);
        variable t3_sr       : std_logic_vector(15 downto 0);
        variable t4_m0, t4_m1, t4_m2, t4_m3 : std_logic_vector(31 downto 0);
        variable t5_a4       : std_logic_vector(31 downto 0);
        variable h_a7        : std_logic_vector(31 downto 0);
        variable t6_d6       : std_logic_vector(31 downto 0);
        variable t5_d4, t5_d5, t5_d6, t5_d7 : std_logic_vector(31 downto 0);
        variable fails       : integer := 0;
    begin
        report "=== MMU RESTART / NETBSD DEMAND-PAGING CONTRACT TEST ===" severity note;

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 400000 loop
            wait until rising_edge(clk);
            done_mark := mem(16#0802#) & mem(16#0803#);
            unexp_mark := mem(16#0804#) & mem(16#0805#);
            if done_mark = x"C0DE600D" or unexp_mark = x"DEADDEAD"
               or debug_cpu_halted = '1' or debug_stop_sig = '1' then
                exit;
            end if;
        end loop;

        fault_count := mem(16#0800#) & mem(16#0801#);
        done_mark   := mem(16#0802#) & mem(16#0803#);
        unexp_mark  := mem(16#0804#) & mem(16#0805#);
        last_fa     := mem(16#0808#) & mem(16#0809#);
        last_ssw    := mem(16#080A#);
        last_pc     := mem(16#080C#) & mem(16#080D#);
        t1_d2       := mem(16#0810#) & mem(16#0811#);
        t1_a0       := mem(16#0812#) & mem(16#0813#);
        t2_a2       := mem(16#0814#) & mem(16#0815#);
        t2_mem      := mem(16#2006#) & mem(16#2007#);
        t3_d5       := mem(16#0816#) & mem(16#0817#);
        t3_sr       := mem(16#0818#);
        t4_m0       := mem(16#2080#) & mem(16#2081#);
        t4_m1       := mem(16#2082#) & mem(16#2083#);
        t4_m2       := mem(16#2084#) & mem(16#2085#);
        t4_m3       := mem(16#2086#) & mem(16#2087#);
        t5_a4       := mem(16#081A#) & mem(16#081B#);
        h_a7        := mem(16#081E#) & mem(16#081F#);
        t6_d6       := mem(16#081C#) & mem(16#081D#);
        t5_d4       := mem(16#0820#) & mem(16#0821#);
        t5_d5       := mem(16#0822#) & mem(16#0823#);
        t5_d6       := mem(16#0824#) & mem(16#0825#);
        t5_d7       := mem(16#0826#) & mem(16#0827#);

        report "DIAG: faults=" & slv_to_hex(fault_count) &
               " done=$" & slv_to_hex(done_mark) &
               " unexpected=$" & slv_to_hex(unexp_mark) severity note;
        report "DIAG: last fault addr=$" & slv_to_hex(last_fa) &
               " SSW=$" & slv_to_hex(last_ssw) &
               " stacked PC=$" & slv_to_hex(last_pc) severity note;

        if debug_cpu_halted = '1' then
            report "FAIL: cpu_halted asserted (double fault) during restart sequence" severity error;
            fails := fails + 1;
        end if;
        if unexp_mark = x"DEADDEAD" then
            report "FAIL: unexpected exception vector taken" severity error;
            fails := fails + 1;
        end if;
        if done_mark /= x"C0DE600D" then
            report "FAIL: program did not complete, done=$" & slv_to_hex(done_mark) severity error;
            fails := fails + 1;
        end if;
        if fault_count /= x"00000006" then
            report "FAIL: fault count=$" & slv_to_hex(fault_count) & " expected exactly 6" severity error;
            fails := fails + 1;
        end if;
        -- Test 1
        if t1_d2 /= x"CAFEBABE" then
            report "FAIL T1: MOVE.L (A0)+,D2 after restart D2=$" & slv_to_hex(t1_d2) & " expected $CAFEBABE" severity error;
            fails := fails + 1;
        end if;
        if t1_a0 /= x"D0002104" then
            report "FAIL T1: A0=$" & slv_to_hex(t1_a0) & " expected $D0002104 (postincrement exactly once)" severity error;
            fails := fails + 1;
        end if;
        -- Test 2
        if t2_mem /= x"12345678" then
            report "FAIL T2: write not completed after restart, [$400C]=$" & slv_to_hex(t2_mem) severity error;
            fails := fails + 1;
        end if;
        if t2_a2 /= x"D000400C" then
            report "FAIL T2: A2=$" & slv_to_hex(t2_a2) & " expected $D000400C (predecrement exactly once)" severity error;
            fails := fails + 1;
        end if;
        -- Test 3
        if t3_d5 /= x"00000000" then
            report "FAIL T3: ADD.L (A5),D5 after restart D5=$" & slv_to_hex(t3_d5) & " expected 0" severity error;
            fails := fails + 1;
        end if;
        -- ADD.L sets X=C=1,Z=1; the following MOVE.L D5,$102C then clears
        -- C and V and re-evaluates N/Z (Z=1), X unchanged -> CCR=$14 at capture.
        if t3_sr(4 downto 0) /= "10100" then
            report "FAIL T3: CCR after restart=$" & slv_to_hex(t3_sr) & " expected X=1 Z=1 C=0 V=0 ($xx14)" severity error;
            fails := fails + 1;
        end if;
        -- Test 4
        if t4_m0 /= x"0D0D0D01" or t4_m1 /= x"0D0D0D02" or
           t4_m2 /= x"0D0D0D03" or t4_m3 /= x"0D0D0D04" then
            report "FAIL T4: MOVEM store after restart [$4100..]=$" & slv_to_hex(t4_m0) & ",$" &
                   slv_to_hex(t4_m1) & ",$" & slv_to_hex(t4_m2) & ",$" & slv_to_hex(t4_m3) severity error;
            fails := fails + 1;
        end if;
        -- Test 5
        if t5_d4 /= x"AABB0001" or t5_d5 /= x"AABB0002" or
           t5_d6 /= x"AABB0003" or t5_d7 /= x"AABB0004" then
            report "FAIL T5: MOVEM load after mid-transfer restart D4-D7=$" & slv_to_hex(t5_d4) & ",$" &
                   slv_to_hex(t5_d5) & ",$" & slv_to_hex(t5_d6) & ",$" & slv_to_hex(t5_d7) severity error;
            fails := fails + 1;
        end if;
        if t5_a4 /= x"D0006008" then
            report "FAIL T5: A4=$" & slv_to_hex(t5_a4) & " expected $D0006008 (advanced exactly once)" severity error;
            fails := fails + 1;
        end if;
        -- Last fault (test 5) frame contents: read fault of the crossing page
        if last_fa /= x"D0002120" then
            report "FAIL: last fault addr=$" & slv_to_hex(last_fa) & " expected $D0002120" severity error;
            fails := fails + 1;
        end if;
        if last_ssw(8) /= '1' or last_ssw(6) /= '1' or last_ssw(7) /= '0'
           or last_ssw(2 downto 0) /= "001" then  -- user data space
            report "FAIL: last SSW=$" & slv_to_hex(last_ssw) & " expected DF=1 RW=1 RM=0 FC=001" severity error;
            fails := fails + 1;
        end if;
        -- Stacked PC must point at the FAULTING instruction (restart contract):
        -- the word at the stacked PC must be the user MOVE.L (A6),D6 opcode $2C16.
        if unsigned(last_pc) < x"00008000" then
            pc_opcode := mem(to_integer(unsigned(last_pc(14 downto 1))));
        else
            pc_opcode := x"0000";
        end if;
        -- Test 6 (user-mode fault: changeMode swap during stacking)
        if t6_d6 /= x"FEEDF00D" then
            report "FAIL T6: user-mode MOVE.L (A6),D6 after restart D6=$" & slv_to_hex(t6_d6) & " expected $FEEDF00D" severity error;
            fails := fails + 1;
        end if;
        -- Supervisor stack balance: every fault stacks a full format $B frame
        -- ($5C bytes) from SSP=$2000 and RTE pops exactly the same amount, so
        -- the handler (after its 16-byte MOVEM push) must see the SAME A7 for
        -- every fault: $2000 - $5C - $10 = $1F94. Any push/pop mismatch leaks
        -- SSP by 4 per fault and shows up here on the 5th fault.
        if h_a7 /= x"00001F94" then
            report "FAIL: handler A7=$" & slv_to_hex(h_a7) & " expected $00001F94 (SSP leak across faults)" severity error;
            fails := fails + 1;
        end if;
        if pc_opcode /= x"2C16" then
            report "FAIL: stacked PC=$" & slv_to_hex(last_pc) & " does not point at the faulting user MOVE opcode (found $" &
                   slv_to_hex(pc_opcode) & ")" severity error;
            fails := fails + 1;
        end if;

        if fails = 0 then
            report "PASS: all 5 faulted instructions restarted correctly under plain-RTE (NetBSD) handling" severity note;
        else
            report "FAIL: " & integer'image(fails) & " restart-contract checks failed" severity error;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
