-- WhichAmiga MMU Test Reproduction Testbench
-- Reproduces the exact MMU configuration from WhichAmiga.ASM that causes system lockup:
-- - TC = $80D04780: E=1, PS=13(8KB), IS=0, TIA=4, TIB=7, TIC=8, TID=0
-- - CRP = $80000002 / $00006000 (short-format root pointer, DT=10)
-- - 16 early-terminating page descriptors (DT=01) at root level
-- - Each descriptor maps a 256MB "super page" (effective shift = 28)
-- - Tests: instruction fetch after MMU enable, data access, $D0xxxxxx remap

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_whichamiga_mmu is
end entity;

architecture behavioral of tb_whichamiga_mmu is

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

    -- Clock
    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal test_done : boolean := false;

    -- CPU interface
    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal busstate    : std_logic_vector(1 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal FC          : std_logic_vector(2 downto 0);

    -- Walker interface
    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    -- PMMU outputs
    signal pmmu_addr_phys    : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;

    -- Debug
    signal debug_TG68_PC    : std_logic_vector(31 downto 0);
    signal debug_opcode     : std_logic_vector(15 downto 0);
    signal debug_state      : std_logic_vector(1 downto 0);
    signal debug_regfile_d0 : std_logic_vector(31 downto 0);
    signal debug_regfile_a0 : std_logic_vector(31 downto 0);
    signal debug_micro_state : integer range 0 to 255;
    signal debug_last_opc_read : std_logic_vector(15 downto 0);
    signal debug_regfile_a1 : std_logic_vector(31 downto 0);
    signal debug_setopcode  : std_logic;
    signal debug_clkena_lw  : std_logic;
    signal debug_trap_berr  : std_logic;
    signal debug_make_berr  : std_logic;
    signal debug_pmmu_fault : std_logic;
    signal pmmu_addr_log    : std_logic_vector(31 downto 0);
    signal debug_data_read  : std_logic_vector(31 downto 0);
    signal debug_memmask    : std_logic_vector(5 downto 0);
    signal debug_setnextpass : std_logic;
    signal debug_decodeOPC  : std_logic;
    signal debug_last_data_read : std_logic_vector(31 downto 0);
    signal debug_regfile_we    : std_logic;
    signal debug_regfile_waddr : std_logic_vector(3 downto 0);
    signal debug_regfile_wdata : std_logic_vector(31 downto 0);
    signal debug_regfile_a7    : std_logic_vector(31 downto 0);
    signal debug_trap_mmu_berr : std_logic;
    signal debug_trap_vector   : std_logic_vector(31 downto 0);

    -- PMMU busy
    signal pmmu_busy : std_logic;

    -- Memory wait state
    signal mem_wait : std_logic := '0';

    -- Walker stall control
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    -- Memory model: 16384 x 16-bit words = 32KB ($0000-$7FFF)
    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- WhichAmiga MMU Configuration:
    -- TC = $80D04780: E=1, PS=13(8KB), IS=0, TIA=4, TIB=7, TIC=8, TID=0
    -- CRP_H = $80000002 (L/U=1, Limit=0, DT=10 short format)
    -- CRP_L = $00006000 (root table at physical $6000)
    -- Root table at $6000: 16 short-format early-terminating page descriptors (DT=01)
    --   Each maps 256MB (effective page shift = PS + TID + TIC + TIB = 13+0+8+7 = 28)
    --   Entry format: $xx000061 where xx = physical base >> 24
    --   Bits: [31:8]=phys addr, [7]=0, [6]=CI=1, [5]=1, [4]=M=0, [3]=U=0, [2]=WP=0, [1:0]=DT=01

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");  -- Default: NOP
    begin
        ---------------------------------------------------------------
        -- VECTOR TABLE ($0000-$00FF)
        ---------------------------------------------------------------
        -- Vector 0: Initial SSP = $00002000
        m(0) := x"0000"; m(1) := x"2000";
        -- Vector 1: Reset PC = $00000100
        m(2) := x"0000"; m(3) := x"0100";
        -- Vector 2: Bus Error -> $0080
        m(4) := x"0000"; m(5) := x"0080";
        -- All other vectors -> unexpected trap handler at $00A0
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00A0";
        end loop;
        ---------------------------------------------------------------
        -- BUS ERROR HANDLER at $0080 (checks SSW.DF for PMMU data fault)
        -- Frame layout from SP: $00=SR, $02=PC_hi, $04=PC_lo, $06=Format/Vec,
        --   $08=$0000(stub), $0A=berr_ssw (SSW), $0C=InstrPipe, $10=FaultAddr...
        -- berr_ssw[8] = DF bit = bit 0 of byte at SP+$0A
        ---------------------------------------------------------------
        -- $0080: BTST #0, ($0A,SP)  ; Test SSW.DF (bit 0 of byte at SP+$0A = berr_ssw[8])
        --   $082F = BTST #n,(d16,A7) opcode; $0000 = bit#0; $000A = disp $0A
        m(64) := x"082F"; m(65) := x"0000"; m(66) := x"000A";
        -- $0086: BEQ.B $009A         ; Z=1 if DF=0 (bit was 0) -> branch to plain RTE
        m(67) := x"6712";
        -- $0088: MOVE.L #$AA550001,$1F20.L  ; DF=1 confirmed: write success marker
        m(68) := x"23FC"; m(69) := x"AA55"; m(70) := x"0001";
        m(71) := x"0000"; m(72) := x"1F20";
        -- $0092: MOVE.L A7,$1F24.L   ; Save stack-frame base for format-size checks
        m(73) := x"23CF"; m(74) := x"0000"; m(75) := x"1F24";
        -- $0098: RTE                 ; Return (DF=1 success path, resumes at saved PC)
        m(76) := x"4E73";
        -- $009A: RTE                 ; Return (DF=0 path, not a data fault)
        m(77) := x"4E73";

        ---------------------------------------------------------------
        -- UNEXPECTED TRAP HANDLER at $00A0
        ---------------------------------------------------------------
        -- $00A0: MOVE.L #$FF000000,D7
        m(80) := x"2E3C"; m(81) := x"FF00"; m(82) := x"0000";
        -- $00A6: MOVE.L D7,$1F00.L
        m(83) := x"23C7"; m(84) := x"0000"; m(85) := x"1F00";
        -- $00AC: STOP #$2700
        m(86) := x"4E72"; m(87) := x"2700";

        ---------------------------------------------------------------
        -- MAIN PROGRAM at $0100
        ---------------------------------------------------------------
        -- Phase 1: Set CRP and enable MMU with WhichAmiga configuration
        -- PMOVE ($1080).W,CRP   ; F038=EA abs.W, 4C00=CRP write
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";
        -- NOP padding
        m(131) := x"4E71"; m(132) := x"4E71";
        -- PFLUSHA               ; Clear ATC before enabling
        m(133) := x"F000"; m(134) := x"2400";
        -- PMOVE ($1088).W,TC    ; Enable MMU!
        m(135) := x"F038"; m(136) := x"4000"; m(137) := x"1088";
        m(138) := x"4E71"; m(139) := x"4E71";

        -- Phase 2: Test basic operation after MMU enable
        -- If we get past the PMOVE TC without lockup, MMU translation is working.
        -- Test 1: MOVE.L #$11111111,$1100.L  (write to low memory - identity mapped)
        m(140) := x"23FC"; m(141) := x"1111"; m(142) := x"1111";
        m(143) := x"0000"; m(144) := x"1100";
        -- Test 2: MOVE.L $1100,D1  (read back - verify identity)
        m(145) := x"2239"; m(146) := x"0000"; m(147) := x"1100";
        -- MOVE.L D1,$1F10.L  (save result)
        m(148) := x"23C1"; m(149) := x"0000"; m(150) := x"1F10";

        -- Phase 3: Test $D0xxxxxx remap
        -- First, modify root table entry 13 to remap $D0xxxxxx -> $00xxxxxx
        -- The entry is at $6000 + 13*4 = $6034. We need to change byte 0 from $D0 to $00.
        -- Since we can't do clr.b easily via CPU code in our simple model,
        -- we'll write the full longword: MOVE.L #$00000061,$6034.L
        m(151) := x"23FC"; m(152) := x"0000"; m(153) := x"0061";
        m(154) := x"0000"; m(155) := x"6034";
        -- PFLUSHA  ; Flush ATC so new descriptor is used
        m(156) := x"F000"; m(157) := x"2400";
        -- NOP
        m(158) := x"4E71";

        -- Test 3: Write to mapped address via $D0xxxxxx alias
        -- The .chipaddr equivalent: use $1200 as our test location
        -- MOVE.L #$4D4D5574,$1200.L  ('MMUt')
        m(159) := x"23FC"; m(160) := x"4D4D"; m(161) := x"5574";
        m(162) := x"0000"; m(163) := x"1200";
        -- NOP (pipeline sync)
        m(164) := x"4E71";

        -- Test 4: Read via $D0xxxxxx alias - should see same data at phys $1200
        -- MOVE.L $D0001200,D2
        m(165) := x"2439"; m(166) := x"D000"; m(167) := x"1200";
        -- MOVE.L D2,$1F14.L  (save result)
        m(168) := x"23C2"; m(169) := x"0000"; m(170) := x"1F14";

        -- Test 5: Write via $D0xxxxxx alias, read via direct address
        -- MOVE.L #$DEADBEEF,$D0001200
        m(171) := x"23FC"; m(172) := x"DEAD"; m(173) := x"BEEF";
        m(174) := x"D000"; m(175) := x"1200";
        -- NOP
        m(176) := x"4E71";
        -- MOVE.L $1200,D3  (read direct - should see $DEADBEEF)
        m(177) := x"2639"; m(178) := x"0000"; m(179) := x"1200";
        -- MOVE.L D3,$1F18.L
        m(180) := x"23C3"; m(181) := x"0000"; m(182) := x"1F18";

        -- Phase 3.5: Bus Fault Detection Test ($016E)
        -- Make entry 13 INVALID: write $D0000060 to $6034 (DT=00 = not allocated)
        -- MOVE.L #$D0000060, $6034.L
        m(183) := x"23FC"; m(184) := x"D000"; m(185) := x"0060";
        m(186) := x"0000"; m(187) := x"6034";
        -- PFLUSHA  ; Flush ATC so invalidated entry is not cached
        m(188) := x"F000"; m(189) := x"2400";
        -- NOP
        m(190) := x"4E71";
        -- MOVE.L ($DFFFFFFC),D0  ; Trigger PMMU bus fault (entry 13 = invalid DT=00)
        --   $2039=MOVE.L (xxx).L,D0; extension words: $DFFFFFFC
        --   Walker reads $6034=$D0000060 (DT=00=invalid) -> PMMU fault -> trap_berr
        --   berr_ssw[8]=1 (DF=1, data access fault); handler at $0080 checks DF
        --   Handler writes $AA550001 to $1F20, RTE returns to saved TG68_PC=$0184
        m(191) := x"2039"; m(192) := x"D000"; m(193) := x"FFFC";

        -- Phase 4: Disable MMU and write final marker ($0184)
        -- PMOVE ($108C).W,TC  ; Disable MMU (TC=0, E=0)
        m(194) := x"F038"; m(195) := x"4000"; m(196) := x"108C";
        -- MOVE.L #$AA550000,$1F00.L
        m(197) := x"23FC"; m(198) := x"AA55"; m(199) := x"0000";
        m(200) := x"0000"; m(201) := x"1F00";
        -- STOP #$2700
        m(202) := x"4E72"; m(203) := x"2700";

        ---------------------------------------------------------------
        -- DATA SECTION at $1080
        ---------------------------------------------------------------
        -- CRP data at $1080 (for PMOVE abs.W load):
        -- CRP_H = $80000002 (L/U=1, Limit=0, DT=10)
        m(2112) := x"8000"; m(2113) := x"0002";
        -- CRP_L = $00006000 (root table at $6000)
        m(2114) := x"0000"; m(2115) := x"6000";
        -- TC enable/disable data
        m(2116) := x"80D0"; m(2117) := x"4780";
        m(2118) := x"0000"; m(2119) := x"0000";

        ---------------------------------------------------------------
        -- ROOT PAGE TABLE at $6000 (16 entries, 4 bytes each)
        -- Each entry: short-format early-terminating page descriptor (DT=01)
        -- Entry i maps logical $i0000000-$iFFFFFFF -> physical $i0000000-$iFFFFFFF
        -- Format: $xx000061 where xx = i << 4
        -- Bits: CI=1, reserved5=1, M=0, U=0, WP=0, DT=01
        ---------------------------------------------------------------
        -- $6000: Entry 0 ($00000000-$0FFFFFFF -> $00000000) = $00000061
        m(12288) := x"0000"; m(12289) := x"0061";
        -- $6004: Entry 1 ($10000000-$1FFFFFFF -> $10000000) = $10000061
        m(12290) := x"1000"; m(12291) := x"0061";
        -- $6008: Entry 2 ($20000000-$2FFFFFFF -> $20000000) = $20000061
        m(12292) := x"2000"; m(12293) := x"0061";
        -- $600C: Entry 3 = $30000061
        m(12294) := x"3000"; m(12295) := x"0061";
        -- $6010: Entry 4 = $40000061
        m(12296) := x"4000"; m(12297) := x"0061";
        -- $6014: Entry 5 = $50000061
        m(12298) := x"5000"; m(12299) := x"0061";
        -- $6018: Entry 6 = $60000061
        m(12300) := x"6000"; m(12301) := x"0061";
        -- $601C: Entry 7 = $70000061
        m(12302) := x"7000"; m(12303) := x"0061";
        -- $6020: Entry 8 = $80000061
        m(12304) := x"8000"; m(12305) := x"0061";
        -- $6024: Entry 9 = $90000061
        m(12306) := x"9000"; m(12307) := x"0061";
        -- $6028: Entry 10 = $A0000061
        m(12308) := x"A000"; m(12309) := x"0061";
        -- $602C: Entry 11 = $B0000061
        m(12310) := x"B000"; m(12311) := x"0061";
        -- $6030: Entry 12 = $C0000061
        m(12312) := x"C000"; m(12313) := x"0061";
        -- $6034: Entry 13 = $D0000061 (will be remapped to $00000061 by test)
        m(12314) := x"D000"; m(12315) := x"0061";
        -- $6038: Entry 14 = $E0000061
        m(12316) := x"E000"; m(12317) := x"0061";
        -- $603C: Entry 15 = $F0000061
        m(12318) := x"F000"; m(12319) := x"0061";

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin

    ---------------------------------------------------------------
    -- CLOCK GENERATION
    ---------------------------------------------------------------
    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    ---------------------------------------------------------------
    -- UUT: TG68KdotC_Kernel (68030 mode)
    ---------------------------------------------------------------
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
            debug_setopcode  => debug_setopcode,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_state      => debug_state,
            debug_setstate   => open,
            debug_last_opc_read => debug_last_opc_read,
            debug_data_read  => debug_data_read,
            debug_direct_data => open,
            debug_setnextpass => debug_setnextpass,
            debug_TG68_PC    => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout     => open,
            debug_decodeOPC  => debug_decodeOPC,
            debug_brief      => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw  => debug_clkena_lw,
            debug_regfile_d0 => debug_regfile_d0,
            debug_regfile_a0 => debug_regfile_a0,
            debug_opcode     => debug_opcode,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_fline_context_valid => open,
            debug_trap_1111  => open,
            debug_trapmake   => open,
            debug_pmmu_brief => open,
            debug_use_base   => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA     => open,
            debug_last_data_read => debug_last_data_read,
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
            debug_regfile_a1 => debug_regfile_a1,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => debug_regfile_a7,
            debug_regfile_we => debug_regfile_we,
            debug_regfile_waddr => debug_regfile_waddr,
            debug_regfile_wdata => debug_regfile_wdata,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => open,
            debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => debug_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy  => pmmu_busy,
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
            debug_pmmu_fault => debug_pmmu_fault
        );

    ---------------------------------------------------------------
    -- MEMORY READ: Drive data_in from physical address
    ---------------------------------------------------------------
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

    ---------------------------------------------------------------
    -- UNIFIED MEMORY WRITE + WALKER RESPONSE
    ---------------------------------------------------------------
    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            -- CPU writes
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and
                   unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            -- Walker response
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

    ---------------------------------------------------------------
    -- MEMORY WAIT STATE
    ---------------------------------------------------------------
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

    ---------------------------------------------------------------
    -- CPU STALL CONTROL
    ---------------------------------------------------------------
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
                           or (pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

    ---------------------------------------------------------------
    -- PC TRACE (report key milestones)
    ---------------------------------------------------------------
    pc_trace: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '1');
        variable cycle_count : integer := 0;
    begin
        if rising_edge(clk) then
            cycle_count := cycle_count + 1;
            if debug_TG68_PC /= prev_pc and debug_clkena_lw = '1' then
                -- Report at key addresses
                if debug_TG68_PC = x"00000100" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $0100 (main program start)" severity note;
                elsif debug_TG68_PC = x"00000118" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $0118 (post-MMU-enable test 1)" severity note;
                elsif debug_TG68_PC = x"0000012E" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $012E (remap test start)" severity note;
                elsif debug_TG68_PC = x"00000148" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $0148 (D0 alias read)" severity note;
                elsif debug_TG68_PC = x"00000156" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $0156 (D0 alias write)" severity note;
                elsif debug_TG68_PC = x"0000016E" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $016E (Phase 3.5: make entry 13 INVALID)" severity note;
                elsif debug_TG68_PC = x"0000017E" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $017E (bus fault trigger: MOVE.L ($DFFFFFFC),D0)" severity note;
                elsif debug_TG68_PC = x"00000184" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: Reached $0184 (Phase 4)" &
                           " log=0x" & slv_to_hex(pmmu_addr_log) &
                           " phys=0x" & slv_to_hex(pmmu_addr_phys) &
                           " fault=" & std_logic'image(debug_pmmu_fault) &
                           " busy=" & std_logic'image(pmmu_busy) &
                           " berr=" & std_logic'image(debug_trap_berr) &
                           " mask=" & slv_to_hex(debug_memmask)
                    severity note;
                elsif debug_TG68_PC = x"00000080" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: BUS ERROR HANDLER at $0080!" &
                           " A7=0x" & slv_to_hex(debug_regfile_a7) &
                           " fault=" & std_logic'image(debug_pmmu_fault) &
                           " berr=" & std_logic'image(debug_trap_berr) &
                           " mmuberr=" & std_logic'image(debug_trap_mmu_berr)
                    severity note;
                elsif debug_TG68_PC = x"000000A0" then
                    report "PC_TRACE[" & integer'image(cycle_count) & "]: UNEXPECTED TRAP at $00A0!" severity note;
                end if;
                prev_pc := debug_TG68_PC;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- WALKER ACTIVITY TRACE
    ---------------------------------------------------------------
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

    ---------------------------------------------------------------
    -- BERR FAULT TRACE (report logical address when trap_berr fires)
    ---------------------------------------------------------------
    berr_trace: process(clk)
        variable prev_trap_berr : std_logic := '0';
        variable berr_count : integer := 0;
        variable cycle_count : integer := 0;
    begin
        if rising_edge(clk) then
            cycle_count := cycle_count + 1;
            if debug_trap_berr = '1' and prev_trap_berr = '0' then
                berr_count := berr_count + 1;
                report "TRAP_BERR[" & integer'image(berr_count) & "] cyc=" & integer'image(cycle_count) &
                       " PC=0x" & slv_to_hex(debug_TG68_PC) &
                       " log=0x" & slv_to_hex(pmmu_addr_log) &
                       " phys=0x" & slv_to_hex(pmmu_addr_phys) &
                       " fault=" & std_logic'image(debug_pmmu_fault) &
                       " busy=" & std_logic'image(pmmu_busy) &
                       " memmask=" & slv_to_hex(debug_memmask)
                severity note;
            end if;
            prev_trap_berr := debug_trap_berr;
        end if;
    end process;

    ---------------------------------------------------------------
    -- MAIN TEST PROCESS
    ---------------------------------------------------------------
    main_test: process
        variable timeout : integer;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        variable result : std_logic_vector(31 downto 0);
    begin
        report "=== WhichAmiga MMU Test Starting ===" severity note;
        report "TC=$80D04780: PS=13(8KB), IS=0, TIA=4, TIB=7, TIC=8, TID=0" severity note;
        report "CRP=$80000002/$00006000: 16 early-terminating 256MB page descriptors" severity note;

        -- Reset
        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';
        wait for CLK_PERIOD;

        ---------------------------------------------------------------
        -- Wait for success marker at $1F00 or timeout
        ---------------------------------------------------------------
        timeout := 0;
        while timeout < 30000 loop
            wait for CLK_PERIOD;
            timeout := timeout + 1;

            -- Check for success marker
            if mem(to_integer(unsigned'(x"0F80"))) = x"AA55" and
               mem(to_integer(unsigned'(x"0F81"))) = x"0000" then
                report "SUCCESS: Test program completed (marker $AA550000 at $1F00)" severity note;
                exit;
            end if;

            -- Check for bus error marker
            if mem(to_integer(unsigned'(x"0F80"))) = x"BE00" and
               mem(to_integer(unsigned'(x"0F81"))) = x"0000" then
                report "BUS ERROR occurred (marker $BE000000 at $1F00)" severity note;
                exit;
            end if;

            -- Check for unexpected trap marker
            if mem(to_integer(unsigned'(x"0F80"))) = x"FF00" and
               mem(to_integer(unsigned'(x"0F81"))) = x"0000" then
                report "UNEXPECTED TRAP occurred (marker $FF000000 at $1F00)" severity note;
                exit;
            end if;

            -- Periodic progress reports
            if timeout mod 5000 = 0 then
                report "Progress: cycle=" & integer'image(timeout) &
                       " PC=0x" & slv_to_hex(debug_TG68_PC) &
                       " state=" & slv_to_hex(debug_state) &
                       " busy=" & std_logic'image(pmmu_busy) &
                       " walk=" & std_logic'image(pmmu_walker_req) &
                       " fault=" & std_logic'image(debug_pmmu_fault) &
                       " berr=" & std_logic'image(debug_trap_berr) &
                       " mmu_berr=" & std_logic'image(debug_trap_mmu_berr) &
                       " log=0x" & slv_to_hex(pmmu_addr_log) &
                       " phys=0x" & slv_to_hex(pmmu_addr_phys)
                severity note;
            end if;
        end loop;

        if timeout >= 30000 then
            report "TIMEOUT: Test did not complete in 30000 cycles!" severity error;
            report "LOCKUP STATE:" &
                   " PC=0x" & slv_to_hex(debug_TG68_PC) &
                   " state=" & slv_to_hex(debug_state) &
                   " busy=" & std_logic'image(pmmu_busy) &
                   " walk=" & std_logic'image(pmmu_walker_req) &
                   " fault=" & std_logic'image(debug_pmmu_fault) &
                   " berr=" & std_logic'image(debug_trap_berr) &
                   " clkena=" & std_logic'image(clkena_in) &
                   " log=0x" & slv_to_hex(pmmu_addr_log) &
                   " phys=0x" & slv_to_hex(pmmu_addr_phys)
            severity error;
            fail_count := fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- Check results
        ---------------------------------------------------------------
        -- Read result at $1F10 (Test 1: identity mapping read-back)
        result := mem(to_integer(unsigned'(x"0F88"))) & mem(to_integer(unsigned'(x"0F89")));
        if result = x"11111111" then
            report "PASS: Test 1 - Identity mapping read-back = $11111111" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 1 - Identity mapping read-back = $" & slv_to_hex(result) & " (expected $11111111)" severity error;
            fail_count := fail_count + 1;
        end if;

        -- Read result at $1F14 (Test 4: $D0xxxxxx alias read)
        result := mem(to_integer(unsigned'(x"0F8A"))) & mem(to_integer(unsigned'(x"0F8B")));
        if result = x"4D4D5574" then
            report "PASS: Test 4 - D0 alias read = $4D4D5574 ('MMUt')" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 4 - D0 alias read = $" & slv_to_hex(result) & " (expected $4D4D5574)" severity error;
            fail_count := fail_count + 1;
        end if;

        -- Read result at $1F18 (Test 5: $D0xxxxxx alias write-through)
        result := mem(to_integer(unsigned'(x"0F8C"))) & mem(to_integer(unsigned'(x"0F8D")));
        if result = x"DEADBEEF" then
            report "PASS: Test 5 - D0 alias write-through = $DEADBEEF" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 5 - D0 alias write-through = $" & slv_to_hex(result) & " (expected $DEADBEEF)" severity error;
            fail_count := fail_count + 1;
        end if;

        -- Test 6: Bus fault SSW.DF=1 confirmed ($1F20 = $AA550001)
        -- Handler at $0080 checks bit 0 of byte at SP+$0A = berr_ssw[8] = DF
        result := mem(to_integer(unsigned'(x"0F90"))) & mem(to_integer(unsigned'(x"0F91")));
        if result = x"AA550001" then
            report "PASS: Test 6 - Bus fault SSW.DF=1 confirmed ($AA550001 at $1F20)" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 6 - Bus fault test: $1F20=$" & slv_to_hex(result) &
                   " (expected $AA550001; DF=1 check)" severity error;
            fail_count := fail_count + 1;
        end if;

        -- Test 7: PMMU data read fault must use a long Format $B frame.
        -- Handler saves the active frame base at $1F24. For this fixed test case
        -- the long frame starts at $1FA4, so the format/vector word is at $1FAA.
        result := mem(to_integer(unsigned'(x"0F92"))) & mem(to_integer(unsigned'(x"0F93")));
        if result = x"00001FA4" then
            report "PASS: Test 7 - PMMU read fault stacked long frame at $1FA4" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 7 - handler saved A7=$" & slv_to_hex(result) &
                   " (expected $00001FA4 for long Format $B frame)" severity error;
            fail_count := fail_count + 1;
        end if;

        result := x"0000" & mem(to_integer(unsigned'(x"0FD5")));
        if result(15 downto 12) = x"B" then
            report "PASS: Test 8 - PMMU read fault format/vector word uses Format $B" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: Test 8 - format/vector word at $1FAA = $" & slv_to_hex(result(15 downto 0)) &
                   " (expected format nibble $B)" severity error;
            fail_count := fail_count + 1;
        end if;

        report "=== WhichAmiga MMU Test Complete: " &
               integer'image(pass_count) & " passed, " &
               integer'image(fail_count) & " failed ===" severity note;

        test_done <= true;
        wait;
    end process;

end architecture;
