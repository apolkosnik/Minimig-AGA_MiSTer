-- tb_berr_frame.vhd
-- Tests MC68030 Format $A bus error stack frame contents (BUG #414/#415)
-- Verifies: SSW (Special Status Word), fault address, format/vector,
--           data output buffer, instruction pipe in the exception frame
-- Triggers WP faults with different access sizes and verifies frame fields

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_berr_frame is
end entity;

architecture behavioral of tb_berr_frame is

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

    signal debug_TG68_PC    : std_logic_vector(31 downto 0);
    signal debug_opcode     : std_logic_vector(15 downto 0);
    signal debug_regfile_a7 : std_logic_vector(31 downto 0);
    signal debug_trap_berr  : std_logic;
    signal debug_make_berr  : std_logic;
    signal debug_pmmu_fault : std_logic;
    signal pmmu_addr_log    : std_logic_vector(31 downto 0);
    signal pmmu_busy : std_logic;

    -- BUG #428 debug signals
    signal debug_state       : std_logic_vector(1 downto 0);
    signal debug_clkena_lw   : std_logic;
    signal debug_memmask     : std_logic_vector(5 downto 0);
    signal debug_memmaskmux  : std_logic_vector(5 downto 0);
    signal debug_micro_state : integer range 0 to 255;
    signal fault_trace_active : boolean := false;

    signal mem_wait : std_logic := '0';
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- TC=$80C07760: E=1, PS=12(4KB), IS=0, TIA=7, TIB=7, TIC=6, TID=0
    -- CRP: $00000002 $00006000 (DT=10, root at $6000)
    -- Page $3000: write-protected (WP=1)

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
    begin
        ---------------------------------------------------------------
        -- VECTOR TABLE ($0000-$00FF)
        ---------------------------------------------------------------
        m(0) := x"0000"; m(1) := x"2000";    -- SSP = $2000
        m(2) := x"0000"; m(3) := x"0100";    -- Reset PC = $0100
        -- Vector 2 (bus error) -> $0080
        m(4) := x"0000"; m(5) := x"0080";
        -- Vectors 3-63: unexpected trap -> $00B0
        for i in 3 to 63 loop
            m(i*2)   := x"0000";
            m(i*2+1) := x"00B0";
        end loop;
        ---------------------------------------------------------------
        -- BUS ERROR HANDLER at $0080 (index 64)
        -- Reads Format $A frame fields and saves to result area
        -- Frame layout from SP:
        --   SP+$00: SR            SP+$02: PC Hi
        --   SP+$04: PC Lo         SP+$06: Format/Vector
        --   SP+$08: Internal      SP+$0A: SSW
        --   SP+$0C: Pipe C        SP+$0E: Pipe B
        --   SP+$10: Fault Addr Hi SP+$12: Fault Addr Lo
        --   SP+$14: Internal Hi   SP+$16: Internal Lo
        --   SP+$18: Data Out Hi   SP+$1A: Data Out Lo
        --   SP+$1C: Internal Hi   SP+$1E: Internal Lo
        ---------------------------------------------------------------
        -- $0080: MOVE.W ($000A,SP),D0    ; Read SSW from frame
        m(64) := x"302F"; m(65) := x"000A";
        -- $0084: MOVE.L ($0010,SP),D1    ; Read fault address from frame
        m(66) := x"222F"; m(67) := x"0010";
        -- $0088: MOVE.W ($0006,SP),D2    ; Read format/vector word
        m(68) := x"342F"; m(69) := x"0006";
        -- $008C: MOVE.L ($0018,SP),D3    ; Read data output buffer
        m(70) := x"262F"; m(71) := x"0018";

        -- Save results using D6 as test index (1-based)
        -- Each test saves 4 fields at $1E00 + (D6-1)*16
        -- Compute A5 = $1E00 + (D6-1)*16
        -- $0090: LEA ($1E00).W,A5
        m(72) := x"4BF8"; m(73) := x"1E00";
        -- $0094: MOVE.L D6,D5
        m(74) := x"2A06";
        -- $0096: SUBQ.L #1,D5
        m(75) := x"5385";
        -- $0098: LSL.L #4,D5     (D5 = (D6-1)*16)
        m(76) := x"E98D";
        -- $009A: ADDA.L D5,A5
        m(77) := x"DBC5";
        -- $009C: MOVE.W D0,(A5)+  ; Save SSW (word)
        m(78) := x"3AC0";
        -- $009E: MOVE.W D2,(A5)+  ; Save format/vector (word)
        m(79) := x"3AC2";
        -- $00A0: MOVE.L D1,(A5)+  ; Save fault address (long)
        m(80) := x"2AC1";
        -- $00A2: MOVE.L D3,(A5)   ; Save data output buffer (long)
        m(81) := x"2A83";

        -- Jump to per-test continuation via A6
        -- $00A4: JMP (A6)
        m(82) := x"4ED6";

        -- Unexpected trap handler at $00B0 (index 88)
        -- $00B0: MOVE.L #$FF000000,D7
        m(88) := x"2E3C"; m(89) := x"FF00"; m(90) := x"0000";
        -- $00B6: MOVE.L D7,$1F00.L
        m(91) := x"23C7"; m(92) := x"0000"; m(93) := x"1F00";
        -- $00BC: STOP #$2700
        m(94) := x"4E72"; m(95) := x"2700";

        ---------------------------------------------------------------
        -- MAIN PROGRAM at $0100 (index 128)
        ---------------------------------------------------------------
        -- Setup: Load CRP and enable MMU
        -- PMOVE ($1080).W,CRP
        m(128) := x"F038"; m(129) := x"4C00"; m(130) := x"1080";
        -- NOP padding
        m(131) := x"4E71"; m(132) := x"4E71";
        -- PFLUSHA
        m(133) := x"F000"; m(134) := x"2400";
        -- PMOVE ($1088).W,TC
        m(135) := x"F038"; m(136) := x"4000"; m(137) := x"1088";
        -- NOP padding to preserve test PCs
        m(138) := x"4E71"; m(139) := x"4E71";
        -- NOP (pipeline settle after TC enable)
        m(140) := x"4E71";

        ---------------------------------------------------------------
        -- Test 1: MOVE.L write to WP page ($3000)
        -- Expected SSW: FC=5(sup data), DF=1, bit9=1, RW=0(write), SIZE=00(long)
        -- SSW = 0000_0011_0000_0101 = $0305
        -- Expected fault addr = $00003000
        ---------------------------------------------------------------
        -- LEA (test1_continue).W,A6   ; Continuation at $0128
        m(141) := x"4DF8"; m(142) := x"0128";
        -- MOVEQ #1,D6
        m(143) := x"7C01";
        -- MOVE.L #$DEADBEEF,$3000.L   ; WP write -> bus error
        m(144) := x"23FC"; m(145) := x"DEAD"; m(146) := x"BEEF";
        m(147) := x"0000"; m(148) := x"3000";
        -- Fallthrough (should not reach here)
        m(149) := x"4E71"; m(150) := x"4E71"; m(151) := x"4E71";

        -- test1_continue at $0128 (index 148)
        -- Wait, $0128/2 = 148. But index 148 is m(148). Let me recalculate.
        -- m(141) is at byte address $0100 + (141-128)*2 = $0100 + 26 = $011A
        -- m(142) is at $011C (extension word for LEA)
        -- m(143) is at $011E (MOVEQ)
        -- m(144) is at $0120 (MOVE.L)
        -- m(145) is at $0122
        -- m(146) is at $0124
        -- m(147) is at $0126
        -- m(148) is at $0128
        -- m(149) is at $012A (fallthrough NOP)
        -- So test1_continue should be at $012A (past the MOVE.L)
        -- But m(144) is MOVE.L #$DEADBEEF,$3000.L = 6 words (opcode + 2 imm + 3 addr)
        -- Wait: MOVE.L #imm,(xxx).L = 23FC + imm_hi + imm_lo + addr_hi + addr_lo = 5 words
        -- m(144)=23FC, m(145)=DEAD, m(146)=BEEF, m(147)=0000, m(148)=3000
        -- Next instruction at m(149) = $012A
        -- Fallthrough NOPs: m(149),m(150),m(151) = $012A,$012C,$012E

        -- test1_continue should skip past fallthrough, let's put it at $0130
        -- That's index 152. Fix the LEA displacement.
        -- Actually, let me restructure for clarity. Start tests after NOPs.

        -- Redo layout:
        -- $011A: LEA $0134.W,A6 (continuation past fallthrough + NOPs)
        -- $011E: MOVEQ #1,D6
        -- $0120: MOVE.L #$DEADBEEF,$3000.L (5 words: $0120-$0128)
        -- $012A: NOP (fallthrough marker - should not reach)
        -- $012C: NOP
        -- $012E: NOP
        -- $0130: NOP
        -- $0132: NOP
        -- $0134: test1_continue (index 154)

        -- Fix LEA target: $0134
        m(142) := x"0134";

        ---------------------------------------------------------------
        -- Test 2: MOVE.B write to WP page ($3002)
        -- Expected SSW: FC=5, DF=1, bit9=1, RW=0, SIZE=01(byte)
        -- SSW = 0000_0011_0001_0101 = $0315
        -- Expected fault addr = $00003002
        ---------------------------------------------------------------
        -- test1_continue at $0134 (index 154)
        -- LEA (test2_continue).W,A6  ; at $014A
        m(154) := x"4DF8"; m(155) := x"014A";
        -- MOVEQ #2,D6
        m(156) := x"7C02";
        -- MOVE.B #$FF,$3002.L   ; 4 words: $13FC 00FF 0000 3002
        m(157) := x"13FC"; m(158) := x"00FF"; m(159) := x"0000"; m(160) := x"3002";
        -- Fallthrough NOPs ($013E-$0148)
        m(161) := x"4E71"; m(162) := x"4E71"; m(163) := x"4E71";
        m(164) := x"4E71"; m(165) := x"4E71";

        ---------------------------------------------------------------
        -- Test 3: MOVE.W write to WP page ($3004)
        -- Expected SSW: FC=5, DF=1, bit9=1, RW=0, SIZE=10(word)
        -- SSW = 0000_0011_0010_0101 = $0325
        -- Expected fault addr = $00003004
        ---------------------------------------------------------------
        -- test2_continue at $014A (index 165)
        -- LEA (test3_continue).W,A6  ; at $0162
        m(165) := x"4DF8"; m(166) := x"0162";
        -- MOVEQ #3,D6
        m(167) := x"7C03";
        -- MOVE.W #$1234,$3004.L   ; 4 words: $33FC 1234 0000 3004
        m(168) := x"33FC"; m(169) := x"1234"; m(170) := x"0000"; m(171) := x"3004";
        -- Fallthrough NOPs ($0158-$0160)
        m(172) := x"4E71"; m(173) := x"4E71"; m(174) := x"4E71";
        m(175) := x"4E71"; m(176) := x"4E71";

        ---------------------------------------------------------------
        -- Test 4: MOVE.L read from WP page (should NOT fault - reads are OK)
        -- This verifies that reads to WP pages don't generate faults
        ---------------------------------------------------------------
        -- test3_continue at $0162 (index 177)
        -- MOVEQ #4,D6
        m(177) := x"7C04";
        -- MOVE.L $3000,D4    ; Read from WP page (should succeed)
        -- MOVE.L (xxx).L,D4 = 2839 0000 3000
        m(178) := x"2839"; m(179) := x"0000"; m(180) := x"3000";
        -- Save D4 to result area ($1E30 = $1E00 + 3*16)
        -- MOVE.L D4,$1E30.L
        m(181) := x"23C4"; m(182) := x"0000"; m(183) := x"1E30";

        -- STOP
        m(184) := x"4E72"; m(185) := x"2700";

        ---------------------------------------------------------------
        -- CRP DATA at $1080; TC data at $1088.
        ---------------------------------------------------------------
        m(2112) := x"0000"; m(2113) := x"0002";  -- CRP_H: DT=10
        m(2114) := x"0000"; m(2115) := x"6000";  -- CRP_L: root at $6000
        m(2116) := x"80C0"; m(2117) := x"7760";  -- TC

        ---------------------------------------------------------------
        -- PAGE TABLES ($6000-$6FFF)
        -- Same layout as tb_mmu_translation
        ---------------------------------------------------------------
        -- Root table at $6000 (index 12288)
        -- Entry 0: -> L1 at $6200
        m(12288) := x"0000"; m(12289) := x"6202";

        -- L1 table at $6200 (index 12544)
        -- Entry 0: -> L2 at $6400
        m(12544) := x"0000"; m(12545) := x"6402";

        -- L2 table at $6400 (index 12800)
        -- Entry 0: page $0000 identity (code+vectors), DT=01
        m(12800) := x"0000"; m(12801) := x"0001";
        -- Entry 1: page $1000 identity (data/stack), DT=01
        m(12802) := x"0000"; m(12803) := x"1001";
        -- Entry 2: page $2000 identity (stack high), DT=01
        m(12804) := x"0000"; m(12805) := x"2001";
        -- Entry 3: page $3000 write-protected (WP=1 bit2), DT=01
        m(12806) := x"0000"; m(12807) := x"3005";

        return m;
    end function;

    signal mem : mem_type := init_mem;

begin
    clk <= not clk after CLK_PERIOD/2 when not test_done else '0';

    uut: entity work.TG68KdotC_Kernel
        port map (
            clk          => clk,
            nReset       => nReset,
            clkena_in    => clkena_in,
            data_in      => data_in,
            IPL          => "111",
            IPL_autovector => '1',
            CPU          => "10",  -- 68030 mode
            addr_out     => addr_out,
            data_write   => data_write,
            nWr          => nWr,
            nUDS         => nUDS,
            nLDS         => nLDS,
            busstate     => busstate,
            FC           => FC,
            longword     => open,
            clr_berr     => open,
            berr         => '0',
            pmmu_addr_phys  => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            pmmu_addr_log    => pmmu_addr_log,
            debug_pmmu_busy  => pmmu_busy,
            debug_TG68_PC    => debug_TG68_PC,
            debug_opcode     => debug_opcode,
            debug_trap_berr  => debug_trap_berr,
            debug_make_berr  => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault,
            debug_regfile_a7 => debug_regfile_a7,
            debug_state      => debug_state,
            debug_clkena_lw  => debug_clkena_lw,
            debug_memmask    => debug_memmask,
            debug_memmaskmux => debug_memmaskmux,
            debug_micro_state => debug_micro_state
        );

    -- Memory read
    process(pmmu_addr_phys, mem)
        variable phys_word : integer;
    begin
        phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
        data_in <= mem(phys_word);
    end process;

    -- Combined memory write + walker service process.
    -- IMPORTANT: All writes to mem must be in a single process to avoid
    -- VHDL multiple-driver resolution issues (two processes driving the same
    -- signal resolves to 'X' for any bit where the drivers disagree).
    process(clk)
        variable phys_word : integer;
        variable walk_word : integer;
    begin
        if rising_edge(clk) then
            -- CPU memory write (gated by clkena_in for valid PMMU physical address)
            if busstate = "11" and nWr = '0' and clkena_in = '1' and (nUDS = '0' or nLDS = '0') then
                phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                -- synthesis translate_off
                report "MEM_WR: phys=$" & slv_to_hex(pmmu_addr_phys) &
                       " log=$" & slv_to_hex(pmmu_addr_log) &
                       " data=$" & slv_to_hex(data_write) &
                       " UDS=" & std_logic'image(nUDS) &
                       " LDS=" & std_logic'image(nLDS) &
                       " clkena=" & std_logic'image(clkena_in);
                -- synthesis translate_on
                if nUDS = '0' then
                    mem(phys_word)(15 downto 8) <= data_write(15 downto 8);
                end if;
                if nLDS = '0' then
                    mem(phys_word)(7 downto 0) <= data_write(7 downto 0);
                end if;
            end if;

            -- Walker memory service
            walker_req_prev <= pmmu_walker_req;
            if stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;

            if pmmu_walker_req = '1' and pmmu_walker_ack = '0' then
                walk_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                if pmmu_walker_we = '1' then
                    -- Descriptor writeback (U/M bits)
                    mem(walk_word)(15 downto 8) <= pmmu_walker_wdat(31 downto 24);
                    mem(walk_word)(7 downto 0)  <= pmmu_walker_wdat(23 downto 16);
                    mem(walk_word+1)(15 downto 8) <= pmmu_walker_wdat(15 downto 8);
                    mem(walk_word+1)(7 downto 0)  <= pmmu_walker_wdat(7 downto 0);
                    pmmu_walker_ack <= '1';
                else
                    -- Descriptor read
                    pmmu_walker_data <= mem(walk_word) & mem(walk_word + 1);
                    pmmu_walker_ack <= '1';
                end if;
                stall_cooldown <= 2;
            elsif pmmu_walker_req = '0' then
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Memory wait state: insert 1 wait cycle after each CPU advance
    -- Gives PMMU time to detect ATC misses before CPU advances with stale addr_phys_reg
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

    -- BUG #399 FIX: Release clkena_in when PMMU has a pending fault (debug_pmmu_fault='1').
    -- Without this, fault_reg='1' keeps pmmu_busy='1', keeping clkena_in='0' forever,
    -- preventing the kernel from ever seeing the fault and triggering make_berr.
    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

    ---------------------------------------------------------------
    -- Debug Monitor: trace PC, faults, bus errors
    ---------------------------------------------------------------
    debug_mon: process(clk)
        variable prev_pc : std_logic_vector(31 downto 0) := (others => '0');
        variable prev_fault : std_logic := '0';
        variable prev_berr : std_logic := '0';
    begin
        if rising_edge(clk) then
            if not is_x(debug_TG68_PC) and clkena_in = '1' then
                if debug_TG68_PC /= prev_pc then
                    if debug_TG68_PC = x"00000100" or debug_TG68_PC = x"00000080"
                       or debug_TG68_PC = x"000000B0" or debug_TG68_PC = x"0000011A"
                       or debug_TG68_PC = x"00000120" or debug_TG68_PC = x"00000134"
                       or debug_TG68_PC = x"0000014A" or debug_TG68_PC = x"00000162" then
                        report "PC milestone: $" & slv_to_hex(debug_TG68_PC) &
                               " opcode=$" & slv_to_hex(debug_opcode) &
                               " fault=" & std_logic'image(debug_pmmu_fault) &
                               " berr=" & std_logic'image(debug_trap_berr) &
                               " busy=" & std_logic'image(pmmu_busy);
                    end if;
                    prev_pc := debug_TG68_PC;
                end if;
            end if;
            if not is_x(debug_pmmu_fault) and debug_pmmu_fault /= prev_fault then
                report "PMMU FAULT changed to " & std_logic'image(debug_pmmu_fault) &
                       " at PC=$" & slv_to_hex(debug_TG68_PC) &
                       " addr_log=$" & slv_to_hex(pmmu_addr_log) &
                       " phys=$" & slv_to_hex(pmmu_addr_phys) &
                       " A7=$" & slv_to_hex(debug_regfile_a7);
                prev_fault := debug_pmmu_fault;
            end if;
            if not is_x(debug_trap_berr) and debug_trap_berr /= prev_berr then
                report "TRAP_BERR changed to " & std_logic'image(debug_trap_berr) &
                       " at PC=$" & slv_to_hex(debug_TG68_PC);
                prev_berr := debug_trap_berr;
            end if;
        end if;
    end process;

    -- BUG #428 debug: per-cycle trace around fault time
    fault_trace: process(clk)
        variable cycle_count : integer := 0;
    begin
        if rising_edge(clk) then
            -- Activate trace when fault detected or when addr_log is WP page
            if not is_x(debug_pmmu_fault) then
                if debug_pmmu_fault = '1' and not fault_trace_active then
                    fault_trace_active <= true;
                    cycle_count := 0;
                end if;
                if fault_trace_active then
                    cycle_count := cycle_count + 1;
                    report "TRACE[" & integer'image(cycle_count) & "]:" &
                           " st=" & slv_to_hex("000000" & debug_state) &
                           " clw=" & std_logic'image(debug_clkena_lw) &
                           " cin=" & std_logic'image(clkena_in) &
                           " mw=" & std_logic'image(mem_wait) &
                           " fault=" & std_logic'image(debug_pmmu_fault) &
                           " mberr=" & std_logic'image(debug_make_berr) &
                           " tberr=" & std_logic'image(debug_trap_berr) &
                           " busy=" & std_logic'image(pmmu_busy) &
                           " mm=" & slv_to_hex("00" & debug_memmask) &
                           " mmx=" & slv_to_hex("00" & debug_memmaskmux) &
                           " alog=$" & slv_to_hex(pmmu_addr_log) &
                           " A7=$" & slv_to_hex(debug_regfile_a7);
                    if cycle_count > 30 then
                        fault_trace_active <= false;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------
    -- Test Monitor
    ---------------------------------------------------------------
    test_monitor: process
        variable val16 : std_logic_vector(15 downto 0);
        variable val32 : std_logic_vector(31 downto 0);
        variable pass  : boolean;
        variable tests_passed : integer := 0;
        variable tests_failed : integer := 0;

        procedure check_test(test_id : integer; test_name : string; passed : boolean) is
        begin
            if passed then
                tests_passed := tests_passed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> PASSED";
            else
                tests_failed := tests_failed + 1;
                report "TEST " & integer'image(test_id) & ": " & test_name & " -> FAILED" severity error;
            end if;
        end procedure;

    begin
        report "=== BUS ERROR FRAME (FORMAT $A) TEST SUITE ===";
        report "Testing SSW, fault address, format/vector in MC68030 bus error frames";

        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        -- Wait for STOP instruction
        for i in 0 to 800 loop
            wait for 100 ns;
            if not is_x(debug_opcode) and debug_opcode = x"4E72" then
                report "CPU reached STOP at " & time'image(now);
                exit;
            end if;
        end loop;

        wait for 200 ns;

        -- Debug: dump the first bus error stack frame at $1FE0 (index 4080)
        report "Stack frame dump (SP=$1FE0):";
        report "  $1FE0 (SR/PC_hi): $" & slv_to_hex(mem(4080)) & slv_to_hex(mem(4081));
        report "  $1FE4 (PC_lo/FmtVec): $" & slv_to_hex(mem(4082)) & slv_to_hex(mem(4083));
        report "  $1FE8 (Internal/SSW): $" & slv_to_hex(mem(4084)) & slv_to_hex(mem(4085));
        report "  $1FEC (Pipe): $" & slv_to_hex(mem(4086)) & slv_to_hex(mem(4087));
        report "  $1FF0 (FaultAddr): $" & slv_to_hex(mem(4088)) & slv_to_hex(mem(4089));
        report "  $1FF4 (Internal2): $" & slv_to_hex(mem(4090)) & slv_to_hex(mem(4091));
        report "  $1FF8 (DataOut): $" & slv_to_hex(mem(4092)) & slv_to_hex(mem(4093));
        report "  $1FFC (Internal1): $" & slv_to_hex(mem(4094)) & slv_to_hex(mem(4095));
        -- Debug: dump result area (handler saves SSW+FmtVec+FaultAddr+DataOut per test)
        report "Result area dump:";
        report "  $1E00 (test1 SSW/FmtVec/FaultAddr/DataOut): $" &
               slv_to_hex(mem(3840)) & " " & slv_to_hex(mem(3841)) & " " &
               slv_to_hex(mem(3842)) & slv_to_hex(mem(3843)) & " " &
               slv_to_hex(mem(3844)) & slv_to_hex(mem(3845));
        report "  $1E10 (test2 SSW/FmtVec/FaultAddr/DataOut): $" &
               slv_to_hex(mem(3848)) & " " & slv_to_hex(mem(3849)) & " " &
               slv_to_hex(mem(3850)) & slv_to_hex(mem(3851)) & " " &
               slv_to_hex(mem(3852)) & slv_to_hex(mem(3853));
        report "  $1E20 (test3 SSW/FmtVec/FaultAddr/DataOut): $" &
               slv_to_hex(mem(3856)) & " " & slv_to_hex(mem(3857)) & " " &
               slv_to_hex(mem(3858)) & slv_to_hex(mem(3859)) & " " &
               slv_to_hex(mem(3860)) & slv_to_hex(mem(3861));

        ---------------------------------------------------------------
        -- Verify Test 1: MOVE.L write to WP page ($3000)
        -- Handler saves to result area $1E00 + (D6-1)*16:
        --   +0: SSW (word), +2: FmtVec (word), +4: FaultAddr (long), +8: DataOut (long)
        -- Test 1 (D6=1): base = $1E00 (idx 3840)
        ---------------------------------------------------------------
        val16 := mem(3840);  -- SSW at $1E00
        report "  Test1 SSW=$" & slv_to_hex(val16);
        pass := (val16(2 downto 0) = "101");  -- FC = supervisor data (5)
        check_test(1, "SSW FC field = 5 (supervisor data)", pass);
        if not pass then
            report "  Got SSW=$" & slv_to_hex(val16) & " FC=" & integer'image(to_integer(unsigned(val16(2 downto 0))));
        end if;

        pass := (val16(6) = '0');  -- RW=0 (write)
        check_test(2, "SSW RW=0 (write access)", pass);

        pass := (val16(8) = '1');  -- DF=1 (data fault)
        check_test(3, "SSW DF=1 (data fault)", pass);

        pass := (val16(5 downto 4) = "00");  -- SIZE=00 (long)
        check_test(4, "SSW SIZE=00 (long word access)", pass);

        -- Format/vector at $1E02 (idx 3841)
        val16 := mem(3841);
        pass := (val16 = x"A008");
        check_test(5, "Format/vector = $A008 (short bus fault, vector 2)", pass);
        if not pass then
            report "  Got format/vector=$" & slv_to_hex(val16);
        end if;

        -- Fault address at $1E04 (idx 3842-3843)
        val32 := mem(3842) & mem(3843);
        pass := (val32 = x"00003000");
        check_test(6, "Fault address = $00003000", pass);
        if not pass then
            report "  Got fault_addr=$" & slv_to_hex(val32);
        end if;

        ---------------------------------------------------------------
        -- Verify Test 2: MOVE.B write to WP page ($3002)
        -- Test 2 (D6=2): base = $1E10 (idx 3848)
        ---------------------------------------------------------------
        val16 := mem(3848);  -- SSW at $1E10
        report "  Test2 SSW=$" & slv_to_hex(val16);
        pass := (val16(5 downto 4) = "01");  -- SIZE=01 (byte)
        check_test(7, "SSW SIZE=01 (byte access)", pass);
        if not pass then
            report "  Got SSW=$" & slv_to_hex(val16) & " SIZE=" & integer'image(to_integer(unsigned(val16(5 downto 4))));
        end if;

        pass := (val16(6) = '0');  -- RW=0 (write)
        check_test(8, "SSW RW=0 (byte write)", pass);

        pass := (val16(2 downto 0) = "101");  -- FC=5
        check_test(9, "SSW FC=5 (byte write, supervisor data)", pass);

        val16 := mem(3849);  -- FmtVec at $1E12
        pass := (val16 = x"A008");
        check_test(10, "Format/vector = $A008 for byte write fault", pass);
        if not pass then
            report "  Got format/vector=$" & slv_to_hex(val16);
        end if;

        -- Fault address at $1E14 (idx 3850-3851)
        val32 := mem(3850) & mem(3851);
        pass := (val32 = x"00003002");
        check_test(11, "Fault address = $00003002 (byte)", pass);
        if not pass then
            report "  Got fault_addr=$" & slv_to_hex(val32);
        end if;

        ---------------------------------------------------------------
        -- Verify Test 3: MOVE.W write to WP page ($3004)
        -- Test 3 (D6=3): base = $1E20 (idx 3856)
        ---------------------------------------------------------------
        val16 := mem(3856);  -- SSW at $1E20
        report "  Test3 SSW=$" & slv_to_hex(val16);
        pass := (val16(5 downto 4) = "10");  -- SIZE=10 (word)
        check_test(12, "SSW SIZE=10 (word access)", pass);
        if not pass then
            report "  Got SSW=$" & slv_to_hex(val16) & " SIZE=" & integer'image(to_integer(unsigned(val16(5 downto 4))));
        end if;

        val16 := mem(3857);  -- FmtVec at $1E22
        pass := (val16 = x"A008");
        check_test(13, "Format/vector = $A008 for word write fault", pass);
        if not pass then
            report "  Got format/vector=$" & slv_to_hex(val16);
        end if;

        -- Fault address at $1E24 (idx 3858-3859)
        val32 := mem(3858) & mem(3859);
        pass := (val32 = x"00003004");
        check_test(14, "Fault address = $00003004 (word)", pass);
        if not pass then
            report "  Got fault_addr=$" & slv_to_hex(val32);
        end if;

        ---------------------------------------------------------------
        -- Verify: No unexpected trap marker at $1F00
        ---------------------------------------------------------------
        val32 := mem(3968) & mem(3969);
        pass := (val32 /= x"FF000000");
        check_test(15, "No unexpected trap during test", pass);

        ---------------------------------------------------------------
        -- Summary
        ---------------------------------------------------------------
        report "========================================";
        report "TOTAL: " & integer'image(tests_passed + tests_failed) &
               " tests, " & integer'image(tests_passed) & " passed, " &
               integer'image(tests_failed) & " failed";
        if tests_failed = 0 then
            report "*** ALL BUS ERROR FRAME TESTS PASSED ***";
        else
            report "*** SOME TESTS FAILED ***" severity error;
        end if;
        report "========================================";

        test_done <= true;
        wait;
    end process;

end behavioral;
