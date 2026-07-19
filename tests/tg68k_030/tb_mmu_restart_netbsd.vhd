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
--   Test 32: CAS.L D0,D1,(A0) locked-RMW read fault -> Format $B/RM frame,
--            whole instruction restarts, compare succeeds, update written once
-- Page tables: 3-level short format (TC=$80D04780: 8K pages, TIA=4/TIB=7/TIC=8),
-- root entries 0-12,14,15 early-termination identity, entry 13 -> B table ->
-- C table with initially-invalid page descriptors the handler fills in.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_mmu_restart_netbsd is
    generic (
        IRQ_PERIOD : integer := 0;  -- >0: fire a level-2 autovector IRQ every IRQ_PERIOD clocks (VBL-style storm)
        IRQ_AT_FAULT : integer := -1; -- >=0: fire a level-2 IRQ exactly N clocks after each pmmu_fault rising edge
        ENABLE_T12 : integer := 0;  -- 1: enable the Enforcer software-completion scenario (UM 8.2.2 - kernel support pending)
        ENABLE_T15_MCLEAR : integer := 1;  -- 0: T15 without the root slot-0 M-clear (isolates boundary fetch fault from the M-rewalk)
        IRQ_AT_RTE : integer := -1;  -- >=0: pulse a level-2 IRQ exactly N clocks after each exec(directPC) event (sweeps the RTE-completion boundary; hardware: an IRQ dispatching there stacked frame PC=0)
        T26_FINAL_BEAT : integer := 0  -- 1: force-release the final rather than non-final directPC beat
    );
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
    signal ipl_n     : std_logic_vector(2 downto 0) := "111";  -- active-low IPL
    signal test_done : boolean := false;

    signal clkena_in   : std_logic := '1';
    signal beat_valid  : std_logic := '1';
    signal debug_exec_directpc : std_logic;
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
    signal debug_memmaskmux    : std_logic_vector(5 downto 0);
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
    -- T26: one-beat poison injection at the RTE redirect window
    signal debug_setopcode_sig : std_logic;
    signal t26_armed      : std_logic := '0';  -- arm marker write seen
    signal t26_suppress   : std_logic;         -- combinational: force beat_valid low THIS edge
    signal t26_fired      : std_logic := '0';  -- suppression actually landed
    -- T27: wrapper-valid poison via a real squashed prefetch fault
    signal debug_bus_beat_poisoned_sig : std_logic;
    signal t27_window      : std_logic := '0'; -- stub write seen; scenario in flight
    signal t27_poison_seen : std_logic := '0'; -- kernel poison observed inside the window
    -- T28: the same discarded page-tail fault followed immediately by a real
    -- demand fault on the RTE redirect target.
    signal t28_window      : std_logic := '0';
    signal t28_poison_seen : std_logic := '0';
    signal t28_fallthrough_fault_seen : std_logic := '0';
    -- T31: full-format JMP whose memory-indirect pointer read demand-faults.
    signal t31_window      : std_logic := '0';
    signal t31_fault_seen  : std_logic := '0';
    signal t31_bad_pc_seen : std_logic := '0';
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
        -- TRAP #0 (vector 32) -> service A $0500: invalidate C entry 1 + PFLUSHA
        m(64) := x"0000"; m(65) := x"0500";
        -- TRAP #1 (vector 33) -> service B $0540: record kernel-visible USP
        m(66) := x"0000"; m(67) := x"0540";
        -- TRAP #2 (vector 34) -> service C $0580: invalidate C entry 2 + PFLUSHA
        m(68) := x"0000"; m(69) := x"0580";
        -- TRAP #3 (vector 35) -> service D $05C0: set page-3 descriptor VALID+WP
        m(70) := x"0000"; m(71) := x"05C0";
        -- Vector 26 (level-2 autovector) -> IRQ handler $0640
        m(52) := x"0000"; m(53) := x"0640";
        -- TRAP #4 (vector 36) -> service G $0680: discard TRAP frame, clear
        -- Enforcer flag, RTE via synthetic user frame to $0700
        m(72) := x"0000"; m(73) := x"0680";
        -- TRAP #5 (vector 37) -> service H $06C0: build synthetic user frame
        -- targeting the INVALIDATED page 2, clear M on the root slot-0
        -- descriptor, PFLUSHA, RTE (T15: fetch fault at the RTE boundary
        -- while the supervisor-stack ATC entry has M=0 - the exception frame
        -- pushes must trigger the BUG #410 M-rewalk mid-stacking and survive)
        m(74) := x"0000"; m(75) := x"06C0";
        -- TRAP #6 (vector 38) -> service I $0780: discard TRAP frame, RTE via
        -- synthetic user frame to $D0002200 (T18: first instruction after the
        -- exec-return RTE is a PC-RELATIVE data read whose target page is
        -- unmapped - FC=2 (user program) data fault at the boundary, exe_pc
        -- still stale at the kernel RTE)
        m(76) := x"0000"; m(77) := x"0780";
        -- TRAP #7 (vector 39) -> service J $0648: T25 supervisor trigger
        -- (T9 lands in USER mode; the RTE-pop-fault scenario needs S=1)
        m(78) := x"0000"; m(79) := x"0648";
        -- TRAP #10 (vector 42) -> service M $1140: T28 combined discarded
        -- fall-through fault plus redirect-target demand fault.
        m(84) := x"0000"; m(85) := x"1140";

        ------------------------------------------------------------------
        -- Main program at $0100 (supervisor mode throughout)
        ------------------------------------------------------------------
        w := 128;
        -- PMOVE ($1080).W,CRP ; PFLUSHA ; PMOVE ($1088).W,TC
        m(w) := x"F038"; m(w+1) := x"4C00"; m(w+2) := x"1080"; w := w+3;
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;
        m(w) := x"F038"; m(w+1) := x"4000"; m(w+2) := x"1088"; w := w+3;
        m(w) := x"46FC"; m(w+1) := x"2000"; w := w+2;                     -- MOVE #$2000,SR (supervisor, IPL mask 0)
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
        -- Test 32: locked RMW must never use the Format-$A last-write replay
        -- path. Invalidate page 3, fault the read half of CAS.L, repair it in
        -- the normal handler, and require the complete compare+write sequence
        -- to restart. Snapshot D0, memory, and SSW before later faults replace
        -- the handler's last-fault record.
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"540C"; w := w+3;  -- CLR.L $540C (invalidate page 3)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"41F9"; m(w+1) := x"D000"; m(w+2) := x"6800"; w := w+3;  -- LEA $D0006800,A0
        m(w) := x"203C"; m(w+1) := x"1122"; m(w+2) := x"3344"; w := w+3;  -- MOVE.L #$11223344,D0 compare
        m(w) := x"223C"; m(w+1) := x"5566"; m(w+2) := x"7788"; w := w+3;  -- MOVE.L #$55667788,D1 update
        m(w) := x"0ED0"; m(w+1) := x"0040"; w := w+2;                     -- CAS.L D0,D1,(A0) FAULT 6 (read/RM)
        m(w) := x"23C0"; m(w+1) := x"0000"; m(w+2) := x"0FA8"; w := w+3;  -- MOVE.L D0,$0FA8
        m(w) := x"2410"; w := w+1;                                        -- MOVE.L (A0),D2
        m(w) := x"23C2"; m(w+1) := x"0000"; m(w+2) := x"0FAC"; w := w+3;  -- MOVE.L D2,$0FAC
        m(w) := x"31F8"; m(w+1) := x"1014"; m(w+2) := x"0FD0"; w := w+3;  -- MOVE.W $1014.W,$0FD0.W (SSW)
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
        -- Test 7: USP-shadow contract across a user-mode restart fault.
        -- The kernel-visible USP (MOVE USP,An in a TRAP handler) must equal
        -- the live user SP after fault 7's rollback+restart (NetBSD fork
        -- copies the trapframe SP; a stale USP shadow returns the child to
        -- userland with the wrong stack).
        m(w) := x"4E40"; w := w+1;                                        -- TRAP #0 (service A: invalidate page)
        m(w) := x"264F"; w := w+1;                                        -- MOVEA.L A7,A3 (pre-fault user SP snapshot)
        m(w) := x"2E16"; w := w+1;                                        -- MOVE.L (A6),D7  FAULT 7 (user mode)
        m(w) := x"4E41"; w := w+1;                                        -- TRAP #1 (service B: record USP -> $1058)
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"105C"; w := w+3;  -- MOVE.L A7,$105C (live user SP)
        m(w) := x"23CB"; m(w+1) := x"0000"; m(w+2) := x"1060"; w := w+3;  -- MOVE.L A3,$1060 (pre-fault snapshot)
        -- Test 8: __fork shape - BSR pushes the return address on the user
        -- stack, the subroutine takes a user-mode restart fault, RTS must
        -- pop the correct return address and SP must balance.
        m(w) := x"4E40"; w := w+1;                                        -- TRAP #0 (service A: invalidate page)
        m(w) := x"6166"; w := w+1;                                        -- BSR.S sub (+102: skips post-RTS code, T10, T12/13, T14, T9 jump-out)
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"1064"; w := w+3;  -- MOVE.L A7,$1064 (post-RTS user SP)
        m(w) := x"23FC"; m(w+1) := x"F02C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"1068"; w := w+5;                   -- MOVE.L #$F02C600D,$1068
        -- Test 9: instruction-stream extension-word page straddle. The MOVE.L
        -- immediate's opcode is the LAST word of mapped page 1 ($D0003FFE);
        -- its 32-bit immediate lives on initially-unmapped page 2 ($D0004000).
        -- The extension fetch faults mid-instruction; after the NetBSD handler
        -- maps the page and RTEs, the whole instruction must re-execute (D2
        -- gets the immediate, execution continues on page 2 and jumps back).
        -- Test 10: WRITE-PROTECTION fault (fork/COW shape). Page 3 descriptor
        -- is VALID but WP; the user write must fault, the handler clears WP
        -- (NetBSD COW resolution), and the write must LAND after recovery.
        m(w) := x"4E43"; w := w+1;                                        -- TRAP #3 (service D: set page-3 descriptor WP)
        m(w) := x"227C"; m(w+1) := x"D000"; m(w+2) := x"6100"; w := w+3;  -- MOVEA.L #$D0006100,A1
        m(w) := x"263C"; m(w+1) := x"C0C0"; m(w+2) := x"D0D0"; w := w+3;  -- MOVE.L #$C0C0D0D0,D3
        m(w) := x"2283"; w := w+1;                                        -- MOVE.L D3,(A1)  FAULT 10 (WP write)
        m(w) := x"23C9"; m(w+1) := x"0000"; m(w+2) := x"1074"; w := w+3;  -- MOVE.L A1,$1074 (post-recovery marker)
        -- Test 12: Enforcer/MuForce software completion (MC68030 UM 8.2.2).
        -- The handler (flag at $107C set) fills the frame DIB with $0DEFACED,
        -- CLEARS DF, and RTEs WITHOUT repairing the page: the CPU must take
        -- the DIB as the read data and continue - any re-run refaults and
        -- breaks the fault-count contract (the MuForce infinite-loop shape).
        if ENABLE_T12 = 1 then
            m(w) := x"23FC"; m(w+1) := x"0000"; m(w+2) := x"0001";
            m(w+3) := x"0000"; m(w+4) := x"107C"; w := w+5;               -- MOVE.L #1,$107C (Enforcer-mode flag)
            m(w) := x"4E42"; w := w+1;                                    -- TRAP #2 (service C: invalidate page 2)
            m(w) := x"207C"; m(w+1) := x"D000"; m(w+2) := x"4800"; w := w+3; -- MOVEA.L #$D0004800,A0
        else
            -- Test 13 (T12 disabled): dispatch-vs-deferred-changeMode collision.
            -- The read below is the FIRST instruction after service C's RTE to
            -- user mode; its fault must dispatch cleanly even when it lands on
            -- the deferred S->U swap boundary (the NetBSD fork-return halt).
            for k in 0 to 4 loop m(w+k) := x"4E71"; end loop; w := w+5;   -- NOPs (pad to match)
            m(w) := x"207C"; m(w+1) := x"D000"; m(w+2) := x"4800"; w := w+3; -- MOVEA.L #$D0004800,A0
            m(w) := x"4E42"; w := w+1;                                    -- TRAP #2 (service C: invalidate page 2, RTE)
        end if;
        m(w) := x"2C10"; w := w+1;                                        -- MOVE.L (A0),D6  FAULT (T12: Enforcer / T13: first-after-RTE)
        m(w) := x"23C6"; m(w+1) := x"0000"; m(w+2) := x"0FF8"; w := w+3;  -- MOVE.L D6,$0FF8.L
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"107C"; w := w+3;  -- CLR.L $107C
        -- Test 14: dispatch-vs-deferred-swap COLLISION (the NetBSD fork halt).
        -- Prime a hot fault-ATC entry (Enforcer-mode fault on page 2, no
        -- repair/no flush), then RTE (via service G's synthetic frame) to user
        -- code at $0700 whose FIRST instruction re-touches the page: the fault
        -- hits the cached ATC entry in ONE cycle, landing the dispatch on the
        -- deferred S->U changeMode boundary.
        m(w) := x"23FC"; m(w+1) := x"0000"; m(w+2) := x"0001";
        m(w+3) := x"0000"; m(w+4) := x"107C"; w := w+5;                   -- MOVE.L #1,$107C (Enforcer mode)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 + PFLUSHA)
        m(w) := x"227C"; m(w+1) := x"D000"; m(w+2) := x"4900"; w := w+3;  -- MOVEA.L #$D0004900,A1
        m(w) := x"2211"; w := w+1;                                        -- MOVE.L (A1),D1  PRIME FAULT (no repair -> hot ATC entry)
        m(w) := x"4E44"; w := w+1;                                        -- TRAP #4 (service G: clear flag, RTE to $0700)
        -- (dead code below: real T9 jump-out now runs from the $0700 block)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (unreachable)
        m(w) := x"4EF9"; m(w+1) := x"D000"; m(w+2) := x"3FF8"; w := w+3;  -- JMP $D0003FF8.L (unreachable)
        m(w) := x"6004"; w := w+1;                                        -- BRA.S done (skip sub; unreachable)
        m(w) := x"2A16"; w := w+1;                                        -- sub: MOVE.L (A6),D5  FAULT 8 (user mode)
        m(w) := x"4E75"; w := w+1;                                        -- RTS
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
        -- Enforcer mode ($107C flag): fill DIB, clear DF, count, RTE (NO repair)
        m(w) := x"4AB9"; m(w+1) := x"0000"; m(w+2) := x"107C"; w := w+3;  -- TST.L $107C
        m(w) := x"671A"; w := w+1;                                        -- BEQ.S normal (+26)
        m(w) := x"2F7C"; m(w+1) := x"0DEF"; m(w+2) := x"ACED";
        m(w+3) := x"003C"; w := w+4;                                      -- MOVE.L #$0DEFACED,$3C(SP) (frame DIB $2C)
        m(w) := x"026F"; m(w+1) := x"FEFF"; m(w+2) := x"001A"; w := w+3;  -- ANDI.W #$FEFF,$1A(SP) (clear SSW DF)
        m(w) := x"52B9"; m(w+1) := x"0000"; m(w+2) := x"1000"; w := w+3;  -- ADDQ.L #1,$1000 (fault count)
        m(w) := x"4CDF"; m(w+1) := x"0303"; w := w+2;                     -- MOVEM.L (SP)+,D0-D1/A0-A1
        m(w) := x"4E73"; w := w+1;                                        -- RTE (frame patched, page NOT repaired)
        -- normal path:
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

        -- TRAP #0 service A at $0500: invalidate C entry 1, flush ATC, RTE
        w := 640;
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5404"; w := w+3;  -- CLR.L $5404
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"4E73"; w := w+1;                                        -- RTE

        -- TRAP #1 service B at $0540: record kernel-visible USP, RTE
        w := 672;
        m(w) := x"4E68"; w := w+1;                                        -- MOVE USP,A0
        m(w) := x"23C8"; m(w+1) := x"0000"; m(w+2) := x"1058"; w := w+3;  -- MOVE.L A0,$1058
        m(w) := x"4E73"; w := w+1;                                        -- RTE

        -- TRAP #2 service C at $0580: invalidate C entry 2, flush ATC, RTE
        w := 704;
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5408"; w := w+3;  -- CLR.L $5408
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"4E73"; w := w+1;                                        -- RTE

        -- TRAP #3 service D at $05C0: page-3 descriptor = $00006005 (VALID+WP), PFLUSHA, RTE
        w := 736;
        m(w) := x"23FC"; m(w+1) := x"0000"; m(w+2) := x"6005";
        m(w+3) := x"0000"; m(w+4) := x"540C"; w := w+5;                   -- MOVE.L #$00006005,$540C
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"4E73"; w := w+1;                                        -- RTE

        -- TRAP #4 service G at $0680: discard the TRAP frame, leave Enforcer
        -- mode, build a synthetic format-0 user frame targeting $0700, RTE.
        w := 832;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard own TRAP frame)
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"107C"; w := w+3;  -- CLR.L $107C (normal handler mode)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (format 0 / vector 0)
        m(w) := x"4879"; m(w+1) := x"0000"; m(w+2) := x"0700"; w := w+3;  -- PEA ($0700).L (target PC)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (SR = user)
        m(w) := x"4E73"; w := w+1;                                        -- RTE -> user $0700

        -- TRAP #5 service H at $06C0 (T15): build the synthetic user frame
        -- FIRST (its pushes re-set M via the walker), then clear M on the
        -- root slot-0 early-termination descriptor (low word at phys $5002)
        -- as the LAST write, PFLUSHA, RTE. The RTE pops are READS, so the
        -- slot-0 ATC refill carries M=0 into the boundary-fault dispatch.
        w := 864;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard own TRAP frame)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (format 0 / vector 0)
        m(w) := x"4879"; m(w+1) := x"D000"; m(w+2) := x"4060"; w := w+3;  -- PEA ($D0004060).L (target PC, page 2 = INVALID)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (SR = user)
        if ENABLE_T15_MCLEAR = 1 then
            m(w) := x"0279"; m(w+1) := x"FFEF";
            m(w+2) := x"0000"; m(w+3) := x"5002"; w := w+4;               -- ANDI.W #$FFEF,($00005002).L (clear M, root slot 0)
        else
            for k in 0 to 3 loop m(w+k) := x"4E71"; end loop; w := w+4;   -- NOPs (isolate: boundary fetch fault only)
        end if;
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"4E73"; w := w+1;                                        -- RTE -> user $D0004060 (fetch faults at boundary)

        -- T15 user target at $D0004060 (phys $4060): canary + jump back
        m(16#2030#) := x"23FC"; m(16#2031#) := x"F15C"; m(16#2032#) := x"600D";
        m(16#2033#) := x"0000"; m(16#2034#) := x"0FEC";                   -- MOVE.L #$F15C600D,$0FEC.L
        m(16#2035#) := x"4EF9"; m(16#2036#) := x"0000"; m(16#2037#) := x"0720";  -- JMP $0720.L (continuation)

        -- T14 user target at $0700: FIRST instruction faults via the hot ATC
        w := 896;
        m(w) := x"2E11"; w := w+1;                                        -- MOVE.L (A1),D7  COLLISION FAULT (instant, first after RTE)
        m(w) := x"23C7"; m(w+1) := x"0000"; m(w+2) := x"0FF0"; w := w+3;  -- MOVE.L D7,$0FF0.L
        m(w) := x"23FC"; m(w+1) := x"F14C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FF4"; w := w+5;                   -- MOVE.L #$F14C600D,$0FF4
        -- Test 15: fetch fault at the RTE boundary with an M=0 supervisor
        -- stack mapping (the NetBSD fork-child kernel stack shape). TRAP #2
        -- invalidates page 2; service H clears M on the root slot-0
        -- descriptor + PFLUSHA and RTEs straight into page 2: the target
        -- fetch faults on the boundary, and the dispatch's frame pushes hit
        -- an M=0 ATC entry -> BUG #410 invalidate + walker re-walk DURING
        -- exception stacking. Must recover (handler repairs page 2), not
        -- double-fault halt.
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 for T15)
        m(w) := x"4E45"; w := w+1;                                        -- TRAP #5 (service H: RTE -> $D0004060 FETCH FAULT)
        -- (unreachable: service H discards this frame)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)

        -- Test 16 at $0720 (T15 continuation): fault ON the RTS pop itself
        -- (the NetBSD __fork PC=$1 halt shape). The RTS's return-slot read
        -- demand-faults mid-instruction; the restart rollback must undo the
        -- RTS's own A7 side effect even though A7 is swap-managed at dispatch
        -- (user A7 -> USP shadow). If the +4 leaks, the re-executed RTS pops
        -- the NEXT slot and resumes at a garbage PC (hardware: PC=$00000001,
        -- odd-fetch address error inside berr_exception_active -> halt).
        -- Page 2 is MAPPED here (T15's handler repaired it).
        w := 912;
        m(w) := x"2A4F"; w := w+1;                                        -- MOVEA.L A7,A5 (save real user SP)
        m(w) := x"2E7C"; m(w+1) := x"D000"; m(w+2) := x"4FF8"; w := w+3;  -- MOVEA.L #$D0004FF8,A7 (fake stack in page 2)
        m(w) := x"4879"; m(w+1) := x"0000"; m(w+2) := x"0740"; w := w+3;  -- PEA ($0740).L (push continuation)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 + PFLUSHA)
        m(w) := x"4E75"; w := w+1;                                        -- RTS  FAULT ON THE POP (return slot in dead page)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)

        -- T16 continuation at $0740: verify pop balance, canary, then T17
        w := 928;
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"0FE4"; w := w+3;  -- MOVE.L A7,$0FE4.L (expect $D0004FF8)
        m(w) := x"2E4D"; w := w+1;                                        -- MOVEA.L A5,A7 (restore real user SP)
        m(w) := x"23FC"; m(w+1) := x"F16C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FE8"; w := w+5;                   -- MOVE.L #$F16C600D,$0FE8.L (canary)
        -- Test 17: Enforcer software completion of a MULTI-WORD source form,
        -- MOVE.L (d16,A1),D1 (the MuForce hardware loop shape: $2A6E - only
        -- (An) sources were whitelisted, the softfix never committed and the
        -- re-executed read refaulted on the hot fault-ATC entry forever).
        -- The commit must take the DIB into D1 AND resume PAST the extension
        -- word (+4, not +2).
        m(w) := x"23FC"; m(w+1) := x"0000"; m(w+2) := x"0001";
        m(w+3) := x"0000"; m(w+4) := x"107C"; w := w+5;                   -- MOVE.L #1,$107C (Enforcer mode)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 + PFLUSHA)
        m(w) := x"227C"; m(w+1) := x"D000"; m(w+2) := x"4900"; w := w+3;  -- MOVEA.L #$D0004900,A1
        m(w) := x"2229"; m(w+1) := x"0010"; w := w+2;                     -- MOVE.L $10(A1),D1  FAULT (Enforcer, no repair)
        m(w) := x"23C1"; m(w+1) := x"0000"; m(w+2) := x"0FE0"; w := w+3;  -- MOVE.L D1,$0FE0.L (expect DIB $0DEFACED)
        -- Test 24: MEMORY-DESTINATION Enforcer completion (the AmigaOS
        -- launch-lockup shape: MOVE.L (A1),(A4) copying ExecBase - the
        -- register-commit whitelist can never handle a memory dest; the
        -- DIB-substitution one-shot must inject the completed data into the
        -- re-executed read so the instruction's own store proceeds).
        m(w) := x"287C"; m(w+1) := x"0000"; m(w+2) := x"0FD8"; w := w+3;  -- MOVEA.L #$0FD8,A4 (mem dest, page 0)
        m(w) := x"2891"; w := w+1;                                        -- MOVE.L (A1),(A4)  FAULT (Enforcer completes; dest = memory)
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"107C"; w := w+3;  -- CLR.L $107C (normal handler mode)
        -- Test 18: exec-return shape. Invalidate page 2, then RTE (service I
        -- synthetic frame) into user code at $D0002200 (page 1, mapped) whose
        -- FIRST instruction is MOVE.L (d16,PC),D3 targeting page 2: an FC=2
        -- (user program space) DATA read faulting on the RTE boundary while
        -- exe_pc is still stale at the service RTE. The frame must carry a
        -- usable restart PC and the read must complete after repair.
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 for T18)
        m(w) := x"4E46"; w := w+1;                                        -- TRAP #6 (service I: RTE -> $D0002200)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)

        -- Test 19 at $07A0 (T18 continuation): dependent-store base integrity
        -- across a racing restart (the NetBSD pool-corruption shape: a store
        -- stream landing at a STALE base). A1 is loaded from memory (its
        -- writeback races the next instruction's shadow snapshot), the NEXT
        -- instruction faults and restarts, then a store through A1 MUST land
        -- at the NEW base and MUST NOT touch the OLD buffer.
        w := 976;
        m(w) := x"41F8"; m(w+1) := x"0E80"; w := w+2;                     -- LEA ($0E80).W,A0 (ptr holder -> $0E40)
        m(w) := x"227C"; m(w+1) := x"0000"; m(w+2) := x"0E00"; w := w+3;  -- MOVEA.L #$0E00,A1 (OLD buffer)
        m(w) := x"22BC"; m(w+1) := x"0FAC"; m(w+2) := x"E001"; w := w+3;  -- MOVE.L #$0FACE001,(A1) (old marker)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (invalidate page 2 + PFLUSHA)
        m(w) := x"247C"; m(w+1) := x"D000"; m(w+2) := x"4800"; w := w+3;  -- MOVEA.L #$D0004800,A2 (dead page)
        m(w) := x"2250"; w := w+1;                                        -- MOVEA.L (A0),A1  A1 := NEW base $0E40 (racing writeback)
        m(w) := x"2212"; w := w+1;                                        -- MOVE.L (A2),D1  FAULT (restart; A1 must stay NEW)
        m(w) := x"22BC"; m(w+1) := x"C0FE"; m(w+2) := x"FACE"; w := w+3;  -- MOVE.L #$C0FEFACE,(A1) (dependent store -> $0E40)
        m(w) := x"4E42"; w := w+1;                                        -- TRAP #2 (re-invalidate page 2 for T9)
        m(w) := x"4EF9"; m(w+1) := x"D000"; m(w+2) := x"3FF8"; w := w+3;  -- JMP $D0003FF8.L (T9 jump-out)
        -- Test 25 (runs LAST, after T9): fault ON the RTE PC pop itself (the
        -- NetBSD fork-return PC=0 hardware shape: SR pop hits the ATC, PC
        -- pop misses -> walk -> invalid descriptor -> the suppressed beats
        -- assemble garbage data_read; the consumption edge sees beat_valid=1
        -- again via the ~cpu_req idle term once the request-match drops the
        -- live fault). Synthetic format-0 frame at the entry-1/entry-2
        -- BOUNDARY: SR word at $D0003FFE (entry 1, mapped), PC long at
        -- $D0004000 (entry 2, invalidated by TRAP #2) - rte1 succeeds, rte2
        -- faults. Dispatch pushes land in mapped entry 1 (over T9's already-
        -- executed code); the handler repairs entry 2; the restarted RTE
        -- must re-pop the SAME frame (A7 rollback to $D0003FFE) and resume
        -- at the frame PC, NOT at a garbage/zero PC.
        -- T25 continuation at $07D0: SP balance, restore, canary, done.
        w := 1000;
        m(w) := x"23CF"; m(w+1) := x"0000"; m(w+2) := x"0FCC"; w := w+3;  -- MOVE.L A7,$0FCC.L (expect $D0004006)
        m(w) := x"2E4D"; w := w+1;                                        -- MOVEA.L A5,A7 (restore real SP)
        m(w) := x"23FC"; m(w+1) := x"F25C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FC8"; w := w+5;                   -- MOVE.L #$F25C600D,$0FC8.L (T25 canary)
        m(w) := x"4E48"; w := w+1;                                        -- TRAP #8 (T26 trigger: stale-poison RTE redirect)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S * (unreachable)
        -- Test 26: stale bus-beat poison must not veto a CLEAN RTE redirect
        -- (the beacon-0015 NetBSD lockup shape: bus_beat_poisoned set by an
        -- unrelated suppressed beat inside the RTE window - a parallel
        -- prefetch force-release on wait-stated hardware - is only cleared
        -- at setopcode or exception entry, so the frame-PC commit at the
        -- exec(directPC) gate is refused with NO fault pending. The RTE
        -- then completes micro-code-wise, A7 fully advanced, and execution
        -- CONTINUES SEQUENTIALLY in the old stream past the RTE: the
        -- FBRD/HALT hardware capture showed kernel exe_pc=$3B4C executing
        -- after the $B-frame RTE at $276A, ending in a JMP to instruction-
        -- stream data $2F3C1400 and a double-fault halt on the user stack.)
        -- TRAP #8 service K builds a clean synthetic format-$0 frame to
        -- $0F00, arms the tb one-beat suppression (write $A5A5 -> $0F98),
        -- then RTEs. The tb force-releases one non-final data edge while the
        -- directPC load is held, then allows the clean longword retry to
        -- finish. The word directly after the RTE is the sail-on detector: it
        -- only executes if the redirect was silently skipped.
        -- TRAP #8 vector 40 (offset $A0) -> service K $0F40
        m(80) := x"0000"; m(81) := x"0F40";
        -- TRAP #9 vector 41 (offset $A4) -> service L $1100 (T27)
        m(82) := x"0000"; m(83) := x"1100";
        -- TRAP #11 vector 43 (offset $AC) -> service N $0850 (T29)
        m(86) := x"0000"; m(87) := x"0850";
        -- TRAP #12 vector 44 (offset $B0) -> service P $0888 (T30)
        m(88) := x"0000"; m(89) := x"0888";
        -- Service K at $0F40
        w := 1952;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard TRAP frame)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (format 0 / vector 0)
        m(w) := x"4879"; m(w+1) := x"0000"; m(w+2) := x"0F00"; w := w+3;  -- PEA ($0F00).L (target PC)
        m(w) := x"3F3C"; m(w+1) := x"2000"; w := w+2;                     -- MOVE.W #$2000,-(SP) (SR: supervisor)
        m(w) := x"31FC"; m(w+1) := x"A5A5"; m(w+2) := x"0F98"; w := w+3;  -- MOVE.W #$A5A5,($0F98).W (ARM tb suppression)
        m(w) := x"4E73"; w := w+1;                                        -- RTE (must redirect to $0F00)
        m(w) := x"23FC"; m(w+1) := x"0BAD"; m(w+2) := x"0BAD";
        m(w+3) := x"0000"; m(w+4) := x"0F90"; w := w+5;                   -- MOVE.L #$0BAD0BAD,$0F90.L (sail-on detector)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S *
        -- T26 target at $0F00: redirect canary, then chain to T27
        w := 1920;
        m(w) := x"23FC"; m(w+1) := x"F26C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0F94"; w := w+5;                   -- MOVE.L #$F26C600D,$0F94.L (T26 canary)
        m(w) := x"4E49"; w := w+1;                                        -- TRAP #9 (T27 trigger)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S * (unreachable)
        -- Test 27: WRAPPER-VALID poison-veto reproduction. Unlike T26's
        -- injected suppression, the stale poison here comes from the REAL
        -- fault path: the RTE sits at the LAST WORD of the mapped page-1
        -- window ($D0003FFE); its fall-through prefetch walks into the
        -- freshly invalidated page 2 ($D0004000) -> genuine PMMU fault ->
        -- the released beat sets bus_beat_poisoned AFTER the RTE's
        -- setopcode. The prefetched word is never consumed (the RTE
        -- redirects), so the fault is squashed without a dispatch (the
        -- fault-count contract stays at exactly 20) - and the stale poison
        -- reaches the clean frame-PC pop from identity memory at $0F80.
        -- Pre-fix: silent sail-on into $D0004000 (the 0014/0015 hardware
        -- lockup). Post-fix: tier-2 commit redirects to $10C0.
        -- TRAP #9 service L at $1100 (words 2112-2117 hold the CRP/TC
        -- bootstrap data - do not place code there):
        w := 2176;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard TRAP frame)
        m(w) := x"31FC"; m(w+1) := x"2000"; m(w+2) := x"0F80"; w := w+3;  -- MOVE.W #$2000,($0F80).W (frame SR)
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"10C0";
        m(w+3) := x"0F82"; w := w+4;                                      -- MOVE.L #$10C0,($0F82).W (frame PC -> T27 target)
        m(w) := x"31FC"; m(w+1) := x"0000"; m(w+2) := x"0F86"; w := w+3;  -- MOVE.W #$0000,($0F86).W (frame fmt/vec)
        m(w) := x"31FC"; m(w+1) := x"4E73"; m(w+2) := x"3FFE"; w := w+3;  -- MOVE.W #$4E73,($3FFE).W (RTE stub at page-1 tail; arms tb window)
        m(w) := x"42B8"; m(w+1) := x"5408"; w := w+2;                     -- CLR.L ($5408).W (invalidate page-2 descriptor)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"2E7C"; m(w+1) := x"0000"; m(w+2) := x"0F80"; w := w+3;  -- MOVEA.L #$0F80,A7 (frame in identity memory)
        m(w) := x"4EF9"; m(w+1) := x"D000"; m(w+2) := x"3FFE"; w := w+3;  -- JMP ($D0003FFE).L (the page-tail RTE)
        -- T27 target at $10C0: canary, preserve T25's last-fault records,
        -- then chain to the combined redirect-target-fault scenario T28.
        w := 2144;
        m(w) := x"23FC"; m(w+1) := x"F27C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0F9C"; w := w+5;                   -- MOVE.L #$F27C600D,$0F9C.L (T27 canary)
        m(w) := x"21F8"; m(w+1) := x"1010"; m(w+2) := x"1090"; w := w+3;  -- snapshot T25 fault addr
        m(w) := x"31F8"; m(w+1) := x"1014"; m(w+2) := x"1094"; w := w+3;  -- snapshot T25 SSW
        m(w) := x"21F8"; m(w+1) := x"1018"; m(w+2) := x"1096"; w := w+3;  -- snapshot T25 stacked PC
        m(w) := x"21F8"; m(w+1) := x"103C"; m(w+2) := x"109A"; w := w+3;  -- snapshot T25 handler A7
        m(w) := x"4E4A"; w := w+1;                                        -- TRAP #10 (T28 trigger)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S * (unreachable)

        -- Test 28: reproduce the complete NetBSD exec-return shape. Pop a
        -- 92-byte Format $B frame (matching the hardware lockup), with the RTE
        -- at the end of mapped page 1. Its speculative fall-through faults on
        -- page 2 while the frame redirects to USER page 3, which is also
        -- invalid. The page-2 fault must die with the discarded stream; the
        -- page-3 target fault must then dispatch exactly once with PC and fault
        -- address both equal to $D0006200, recover, and execute the canary.
        -- TRAP #10 service M at $1140.
        w := 2208;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard TRAP frame)
        m(w) := x"31FC"; m(w+1) := x"0000"; m(w+2) := x"1300"; w := w+3;  -- frame SR = user
        m(w) := x"21FC"; m(w+1) := x"D000"; m(w+2) := x"6200";
        m(w+3) := x"1302"; w := w+4;                                      -- frame PC = $D0006200 (invalid page 3)
        m(w) := x"31FC"; m(w+1) := x"B008"; m(w+2) := x"1306"; w := w+3;  -- Format $B / vector 2; extension is zero-filled
        m(w) := x"31FC"; m(w+1) := x"4E73"; m(w+2) := x"3FFE"; w := w+3;  -- page-tail RTE stub; arms T28 watch
        m(w) := x"42B8"; m(w+1) := x"5408"; w := w+2;                     -- invalidate page-2 fall-through
        m(w) := x"42B8"; m(w+1) := x"540C"; w := w+2;                     -- invalidate page-3 redirect target
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"2E7C"; m(w+1) := x"0000"; m(w+2) := x"1300"; w := w+3;  -- A7 -> synthetic frame
        m(w) := x"4EF9"; m(w+1) := x"D000"; m(w+2) := x"3FFE"; w := w+3;  -- JMP page-tail RTE

        -- T28 target at logical $D0006200 / physical $6200. The normal fault
        -- handler maps page 3 before RTE retries this fetch.
        w := 16#3100#;
        m(w) := x"23FC"; m(w+1) := x"F28C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FA0"; w := w+5;                   -- T28 target canary
        m(w) := x"21F8"; m(w+1) := x"1010"; m(w+2) := x"10A0"; w := w+3;  -- snapshot T28 fault addr
        m(w) := x"31F8"; m(w+1) := x"1014"; m(w+2) := x"10A4"; w := w+3;  -- snapshot T28 SSW
        m(w) := x"21F8"; m(w+1) := x"1018"; m(w+2) := x"10A6"; w := w+3;  -- snapshot T28 stacked PC
        m(w) := x"4E4B"; w := w+1;                                        -- TRAP #11 (T29 trigger)
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S * (unreachable)
        -- TRAP #7 service J at $0648: the T25 trigger, in supervisor mode.
        -- Write the synthetic frame via identity addresses, invalidate
        -- entry 2 inline (service C body), discard the TRAP frame into A5,
        -- point A7 at the boundary frame, RTE.
        w := 804;
        m(w) := x"31FC"; m(w+1) := x"2000"; m(w+2) := x"3FFE"; w := w+3;  -- MOVE.W #$2000,($3FFE).W (frame SR)
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"07D0";
        m(w+3) := x"4000"; w := w+4;                                      -- MOVE.L #$07D0,($4000).W (frame PC)
        m(w) := x"31FC"; m(w+1) := x"0080"; m(w+2) := x"4004"; w := w+3;  -- MOVE.W #$0080,($4004).W (frame fmt)
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5408"; w := w+3;  -- CLR.L $5408 (invalidate entry 2)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"4BEF"; m(w+1) := x"0008"; w := w+2;                     -- LEA 8(A7),A5 (real SSP sans TRAP frame)
        m(w) := x"2E7C"; m(w+1) := x"D000"; m(w+2) := x"3FFE"; w := w+3;  -- MOVEA.L #$D0003FFE,A7 (frame at the boundary)
        m(w) := x"4E73"; w := w+1;                                        -- RTE  FAULT ON THE POP (frame slots in dead entry 2)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)

        -- Test 29 (runs LAST): the SRE-split RTE-to-user FC contract - the
        -- NetBSD fork-return shape at last. TC.SRE=1 splits the roots:
        -- supervisor walks SRP ($5000, the existing tables), user walks CRP
        -- (throwaway root $5200 whose entry-1 page maps to phys $6000). A
        -- synthetic frame with SR=$0000 (USER) sits at VA $D0003F00: via the
        -- SUPERVISOR map it holds SR=$0000/PC=$0838/fmt=$0084 (phys $3F00);
        -- via the USER map the same VA reads phys $7F00 = ZEROS. MC68030:
        -- ALL RTE pops are supervisor (FC=101) cycles - if the popped SR's
        -- S=0 leaks into the remaining pops' FC, the PC pop walks CRP and
        -- pops PC=0 from the user image with every beat legitimately acked
        -- (the exact deterministic hardware signature, beacons 0012-001A).
        -- TRAP #11 service N at $0850: build frame, split the roots, RTE.
        w := 1064;
        m(w) := x"31FC"; m(w+1) := x"0000"; m(w+2) := x"3F00"; w := w+3;  -- MOVE.W #$0000,($3F00).W (frame SR = USER)
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"0838";
        m(w+3) := x"3F02"; w := w+4;                                      -- MOVE.L #$0838,($3F02).W (frame PC)
        m(w) := x"31FC"; m(w+1) := x"0084"; m(w+2) := x"3F06"; w := w+3;  -- MOVE.W #$0084,($3F06).W (frame fmt)
        m(w) := x"F038"; m(w+1) := x"4800"; m(w+2) := x"10B0"; w := w+3;  -- PMOVE ($10B0).W,SRP (supervisor root $5000)
        m(w) := x"F038"; m(w+1) := x"4C00"; m(w+2) := x"10B8"; w := w+3;  -- PMOVE ($10B8).W,CRP (user root $5200)
        m(w) := x"F038"; m(w+1) := x"4000"; m(w+2) := x"0FC4"; w := w+3;  -- PMOVE ($0FC4).W,TC (SRE=1)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"2E7C"; m(w+1) := x"D000"; m(w+2) := x"3F00"; w := w+3;  -- MOVEA.L #$D0003F00,A7
        m(w) := x"4E73"; w := w+1;                                        -- RTE (SR pop = user SR; PC pop = THE FC TEST)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)
        -- T29 continuation at $0838 (USER mode): canary + done, both via
        -- the user map's identity entry 0.
        w := 1052;
        m(w) := x"23FC"; m(w+1) := x"F29C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FC0"; w := w+5;                   -- MOVE.L #$F29C600D,$0FC0.L (T29 canary)
        m(w) := x"4E4C"; w := w+1;                                        -- TRAP #12 (T30 trigger)
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)
        -- Test 30: stale-ATC remap WRITE contract (the 001C hardware shape:
        -- a function epilogue popped its return address as ZERO from phys
        -- $0FC5BFA8 while the frame around it was intact - the push landed
        -- at a DIFFERENT physical page through a stale translation. Fork
        -- gives the child a fresh kernel-stack page; any ATC entry surviving
        -- the flush leaks pushes to the old page). Map $D0006xxx -> phys
        -- $6000, store, make the entry hot, REMAP -> phys $4000 + PFLUSHA,
        -- store again: the second store MUST land at phys $4180 and MUST
        -- NOT touch phys $6180.
        -- TRAP #12 service P at $0888 (supervisor; SRE=1 -> stores walk SRP).
        w := 1092;
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"6001";
        m(w+3) := x"540C"; w := w+4;                                      -- MOVE.L #$6001,($540C).W (entry 3 -> phys $6000)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"23FC"; m(w+1) := x"AAAA"; m(w+2) := x"5555";
        m(w+3) := x"D000"; m(w+4) := x"6180"; w := w+5;                   -- MOVE.L #$AAAA5555,($D0006180).L -> phys $6180
        m(w) := x"2039"; m(w+1) := x"D000"; m(w+2) := x"6180"; w := w+3;  -- MOVE.L ($D0006180).L,D0 (ATC hot)
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"4001";
        m(w+3) := x"540C"; w := w+4;                                      -- MOVE.L #$4001,($540C).W (REMAP entry 3 -> phys $4000)
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        m(w) := x"23FC"; m(w+1) := x"BBBB"; m(w+2) := x"6666";
        m(w+3) := x"D000"; m(w+4) := x"6180"; w := w+5;                   -- MOVE.L #$BBBB6666,($D0006180).L -> MUST land phys $4180
        -- Test 31: the hardware lockup captured by beacon $0025. The
        -- full-format PC-relative memory-indirect JMP reads its pointer from
        -- page 2. Invalidate that page so the pointer read demand-faults.
        -- The fault handler maps it and returns with an unmodified frame; the
        -- JMP must restart instead of committing the released beat's garbage
        -- through exec(ea_to_pc).
        m(w) := x"21FC"; m(w+1) := x"0000"; m(w+2) := x"1200";
        m(w+3) := x"4914"; w := w+4;                                      -- pointer at phys $4914 -> target $1200
        m(w) := x"42B9"; m(w+1) := x"0000"; m(w+2) := x"5408"; w := w+3;  -- invalidate page-2 descriptor
        m(w) := x"F000"; m(w+1) := x"2400"; w := w+2;                     -- PFLUSHA
        -- At $08CC: JMP ([PC + $D0004046]) -> pointer at $D0004914.
        m(w) := x"4EFB"; m(w+1) := x"0171";
        m(w+2) := x"D000"; m(w+3) := x"4046"; w := w+4;
        m(w) := x"4E72"; m(w+1) := x"2700"; w := w+2;                     -- STOP (unreachable)

        -- T31 JMP target at $1200.
        w := 16#0900#;
        m(w) := x"23FC"; m(w+1) := x"F31C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"0FA4"; w := w+5;                   -- T31 canary
        m(w) := x"23FC"; m(w+1) := x"C0DE"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"1004"; w := w+5;                   -- done marker
        m(w) := x"60FE"; w := w+1;                                        -- BRA.S *

        -- T29 root-pointer descriptors and split TC ($1090-$109D belongs to
        -- the T25-record snapshots; $10C0+ is T27 target code)
        m(16#0858#) := x"8000"; m(16#0859#) := x"0002";
        m(16#085A#) := x"0000"; m(16#085B#) := x"5000";                   -- $10B0: SRP -> root $5000
        m(16#085C#) := x"8000"; m(16#085D#) := x"0002";
        m(16#085E#) := x"0000"; m(16#085F#) := x"5200";                   -- $10B8: CRP -> user root $5200
        m(16#07E2#) := x"82D0"; m(16#07E3#) := x"4780";                   -- $0FC4: TC with SRE=1


        -- T19 pointer holder at $0E80 -> new buffer $0E40
        m(16#0740#) := x"0000"; m(16#0741#) := x"0E40";

        -- TRAP #6 service I at $0780: discard frame, synthetic user frame to $D0002200
        w := 960;
        m(w) := x"508F"; w := w+1;                                        -- ADDQ.L #8,A7 (discard own TRAP frame)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (format 0 / vector 0)
        m(w) := x"4879"; m(w+1) := x"D000"; m(w+2) := x"2200"; w := w+3;  -- PEA ($D0002200).L (target PC, page 1 mapped)
        m(w) := x"3F3C"; m(w+1) := x"0000"; w := w+2;                     -- MOVE.W #$0000,-(SP) (SR = user)
        m(w) := x"4E73"; w := w+1;                                        -- RTE -> user $D0002200

        -- T18 user code at $D0002200 (phys $2200): PC-relative read into page 2
        m(16#1100#) := x"263A"; m(16#1101#) := x"271E";                   -- MOVE.L ($271E,PC),D3 -> reads $D0004920 (page 2)
        m(16#1102#) := x"23C3"; m(16#1103#) := x"0000"; m(16#1104#) := x"0FDC";  -- MOVE.L D3,$0FDC.L
        m(16#1105#) := x"4EF9"; m(16#1106#) := x"0000"; m(16#1107#) := x"07A0";  -- JMP $07A0.L (continuation)
        -- T18 target data at phys $4920
        m(16#2490#) := x"F18D"; m(16#2491#) := x"600D";

        -- T9 landing pad at $0600: canary marker, snapshot the T9 fault
        -- records (T25 runs next and overwrites the last-wins slots), then
        -- chain to the T25 trigger. Done moves to the T25 continuation.
        w := 768;
        m(w) := x"23FC"; m(w+1) := x"F17C"; m(w+2) := x"600D";
        m(w+3) := x"0000"; m(w+4) := x"1070"; w := w+5;                   -- MOVE.L #$F17C600D,$1070
        m(w) := x"21F8"; m(w+1) := x"1010"; m(w+2) := x"0FB0"; w := w+3;  -- MOVE.L $1010.W,$0FB0.W (T9 fault addr)
        m(w) := x"21F8"; m(w+1) := x"1014"; m(w+2) := x"0FB4"; w := w+3;  -- MOVE.L $1014.W,$0FB4.W (T9 SSW)
        m(w) := x"21F8"; m(w+1) := x"1018"; m(w+2) := x"0FB8"; w := w+3;  -- MOVE.L $1018.W,$0FB8.W (T9 stacked PC)
        m(w) := x"21F8"; m(w+1) := x"103C"; m(w+2) := x"0FBC"; w := w+3;  -- MOVE.L $103C.W,$0FBC.W (T9 handler A7)
        m(w) := x"4E47"; w := w+1;                                        -- TRAP #7 (service J: T25 trigger, supervisor)

        -- Level-2 IRQ handler at $0640: count and return
        w := 800;
        m(w) := x"52B9"; m(w+1) := x"0000"; m(w+2) := x"1078"; w := w+3;  -- ADDQ.L #1,$1078
        m(w) := x"4E73"; w := w+1;                                        -- RTE

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
        -- T9 straddle code: page 1 tail + page 2 head (avoids T2's $400C slot)
        m(16#1FFC#) := x"4E71";                          -- $D0003FF8 NOP
        m(16#1FFD#) := x"4E71";                          -- $D0003FFA NOP
        m(16#1FFE#) := x"4E71";                          -- $D0003FFC NOP
        m(16#1FFF#) := x"243C";                          -- $D0003FFE MOVE.L #imm,D2 (opcode)
        m(16#2000#) := x"CAFE";                          -- $D0004000 imm hi (unmapped page 2)
        m(16#2001#) := x"D00D";                          -- $D0004002 imm lo
        m(16#2002#) := x"23C2"; m(16#2003#) := x"0000";
        m(16#2004#) := x"106C";                          -- $D0004004 MOVE.L D2,$106C.L
        m(16#2005#) := x"6006";                          -- $D000400A BRA.S +6 (skip T2's slot)
        m(16#2009#) := x"4EF9"; m(16#200A#) := x"0000";
        m(16#200B#) := x"0600";                          -- $D0004012 JMP $0600.L (landing pad)
        m(16#2FFC#) := x"AABB"; m(16#2FFD#) := x"0001";  -- phys $5FF8
        m(16#2FFE#) := x"AABB"; m(16#2FFF#) := x"0002";  -- phys $5FFC
        m(16#3000#) := x"AABB"; m(16#3001#) := x"0003";  -- phys $6000
        m(16#3002#) := x"AABB"; m(16#3003#) := x"0004";  -- phys $6004
        m(16#3400#) := x"1122"; m(16#3401#) := x"3344";  -- phys $6800 (T32 CAS compare operand)

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
        -- T29 throwaway USER tables at $5200 (inside the zeroed region):
        -- root: identity early-term except entry 13 -> B'' -> C''
        for n in 0 to 15 loop
            if n = 13 then
                m(16#2900# + n*2)     := x"0000";
                m(16#2900# + n*2 + 1) := x"5282";
            else
                m(16#2900# + n*2)     := std_logic_vector(to_unsigned(n, 4)) & x"000";
                m(16#2900# + n*2 + 1) := x"0061";
            end if;
        end loop;
        m(16#2940#) := x"0000"; m(16#2941#) := x"52C2";                   -- B'' entry 0 -> C'' $52C0
        m(16#2960#) := x"0000"; m(16#2961#) := x"0001";                   -- C'' e0: base $0000 (identity)
        m(16#2962#) := x"0000"; m(16#2963#) := x"6001";                   -- C'' e1: base $6000 (the SPLIT page)
        m(16#2964#) := x"0000"; m(16#2965#) := x"4001";                   -- C'' e2: base $4000
        m(16#2966#) := x"0000"; m(16#2967#) := x"6005";                   -- C'' e3
        -- The user image of the frame (phys $7F00-$7F07): explicit ZEROS -
        -- a leaked user-FC pop reads PC=$00000000 (the hardware signature).
        m(16#3F80#) := x"0000"; m(16#3F81#) := x"0000";
        m(16#3F82#) := x"0000"; m(16#3F83#) := x"0000";
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

    -- VBL-style IRQ storm: pulse a level-2 autovector interrupt every
    -- IRQ_PERIOD clocks (released after 2 clocks), exercising the fault/
    -- replay/restart windows against asynchronous interrupt arrival.
    irq_storm: process(clk)
        variable cnt  : integer := 0;
        variable fdel : integer := -1;
        variable fprev : std_logic := '0';
        variable ddel : integer := -1;
        variable dprev : std_logic := '0';
    begin
        if rising_edge(clk) then
            if IRQ_PERIOD > 0 then
                cnt := cnt + 1;
                if cnt >= IRQ_PERIOD then
                    cnt := 0;
                    ipl_n <= "101";  -- level 2 (active low)
                elsif cnt = 2 then
                    ipl_n <= "111";
                end if;
            end if;
            -- Targeted mode: pulse the IRQ exactly IRQ_AT_FAULT clocks after
            -- each fault first-fire, sweeping the first-fire->dispatch window
            -- (an IRQ dispatch inside the restart squash window must not have
            -- its exception-frame pushes write-gated).
            if IRQ_AT_RTE >= 0 then
                if debug_exec_directpc = '1' and dprev = '0' then
                    ddel := IRQ_AT_RTE;
                end if;
                dprev := debug_exec_directpc;
                if ddel > 0 then
                    ddel := ddel - 1;
                elsif ddel = 0 then
                    ipl_n <= "101";
                    ddel := -2;
                elsif ddel = -2 then
                    ipl_n <= "111";
                    ddel := -1;
                end if;
            end if;
            if IRQ_AT_FAULT >= 0 then
                if debug_pmmu_fault = '1' and fprev = '0' then
                    fdel := IRQ_AT_FAULT;
                end if;
                fprev := debug_pmmu_fault;
                if fdel > 0 then
                    fdel := fdel - 1;
                elsif fdel = 0 then
                    ipl_n <= "101";
                    fdel := -2;
                elsif fdel = -2 then
                    ipl_n <= "111";
                    fdel := -3;
                elsif fdel = -3 then
                    fdel := -1;
                end if;
            end if;
        end if;
    end process;

    -- A direct-PC source is always a 32-bit read (RTE/RTS/RTD or a vector
    -- fetch).  The first 16-bit bus beat may leave data_read containing a
    -- partial value, but that value must never become architecturally visible
    -- as TG68_PC.  Hardware interrupts can arrive between the two beats.
    directpc_longword_atomicity: process
        variable pc_before : std_logic_vector(31 downto 0);
    begin
        while not test_done loop
            wait until rising_edge(clk);
            if nReset = '1' and clkena_in = '1' and
               debug_exec_directpc = '1' and debug_clkena_lw = '0' then
                pc_before := debug_TG68_PC;
                wait for 1 ns;
                assert debug_TG68_PC = pc_before
                    report "FAIL: directPC committed a partial 16-bit bus beat: old=$" &
                           slv_to_hex(pc_before) & " new=$" & slv_to_hex(debug_TG68_PC)
                    severity error;
            end if;
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
            beat_valid       => beat_valid,
            data_in          => data_in,
            IPL              => ipl_n,
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
            debug_setopcode  => debug_setopcode_sig,
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
            debug_memmaskmux => debug_memmaskmux,
            debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open,
            debug_exec_directPC => debug_exec_directpc,
            debug_bus_beat_poisoned => debug_bus_beat_poisoned_sig,
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

    mem_read: process(pmmu_addr_phys, mem, t31_window, debug_pmmu_fault, busstate)
    begin
        -- POISON unmapped/faulted reads: hardware returns open-bus echo, not
        -- NOPs. A resume path that consumes stale prefetch from a faulted
        -- fetch executed harmless $4E71s here and the contract never saw it
        -- (hardware: $1B00 garbage executed after a text demand-fault RTE).
        -- $4AFC = ILLEGAL: any consumption trips vector 4 -> unexpected trap.
        if t31_window = '1' and debug_pmmu_fault = '1' and busstate = "10" then
            -- Match the board's open-bus/stale low half closely enough that an
            -- unsafe EA-to-PC commit becomes an odd address immediately.
            data_in <= x"FFFF";
        elsif is_x(pmmu_addr_phys) then
            data_in <= x"4AFC";
        elsif unsigned(pmmu_addr_phys) < x"00008000" then
            data_in <= mem(to_integer(unsigned(pmmu_addr_phys(14 downto 1))));
        else
            data_in <= x"4AFC";
        end if;
    end process;

    -- Invariant: every write into the supervisor stack region must carry
    -- FC=101 (supervisor data). Exception-frame pushes that leak a user FC
    -- (orphan-SR dispatch: FlagsSR(5) still 0 from the RTE's SR restore, so
    -- fc_internal re-tracks to user after the one-cycle interrupt override)
    -- walk the USER root on SRE=1 systems and double-fault NetBSD; the
    -- identity tables here hide that, so assert the FC directly.
    sup_stack_fc_check: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' and
               not is_x(pmmu_addr_phys) and
               unsigned(pmmu_addr_phys) >= x"00001E00" and
               unsigned(pmmu_addr_phys) < x"00002000" then
                assert FC = "101"
                    report "FAIL: supervisor-stack write phys=" & slv_to_hex(pmmu_addr_phys(15 downto 0)) &
                           " with non-supervisor FC=" & std_logic'image(FC(2)) & std_logic'image(FC(1)) & std_logic'image(FC(0))
                    severity error;
            end if;
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
                    if unsigned(pmmu_addr_phys(14 downto 1)) >= x"0F50" then
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

    -- Mirror cpu_wrapper's beat_valid: a clkena edge released BY the fault
    -- (rather than by a real memory ack) carries garbage - the kernel must
    -- consume nothing on it. This makes the hardware force-completed-beat
    -- class visible in simulation for the first time.
    -- T26 adds a one-shot NO-FAULT suppression: hardware also releases beats
    -- invalid without a fault of the consuming instruction (a parallel
    -- prefetch force-release under wait states) - the stale poison from such
    -- a beat must not veto a later clean directPC commit.
    beat_valid <= '0' when (debug_pmmu_fault = '1' or t26_suppress = '1') else '1';

    -- T26 sequencing: arm on the service-K marker write ($A5A5 -> $0F98),
    -- then force-release one selected beat while exec(directPC) is held, with
    -- no fault pending. The default covers a non-final beat; T26_FINAL_BEAT=1
    -- covers the hardware-shaped final-beat release that DPCW can otherwise
    -- misreport as valid on the following no-request cycle.
    t26_suppress <= '1' when (t26_armed = '1' and
                              debug_exec_directpc = '1' and
                              clkena_in = '1' and
                              ((T26_FINAL_BEAT = 0 and debug_memmaskmux(3) = '0') or
                               (T26_FINAL_BEAT = 1 and debug_memmaskmux(3) = '1')) and
                              debug_pmmu_fault = '0') else '0';

    t26_inject: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                t26_armed      <= '0';
                t26_fired      <= '0';
            elsif clkena_in = '1' then
                if t26_suppress = '1' then
                    t26_armed <= '0';
                    t26_fired <= '1';
                    report "T26: injected one no-fault directPC beat release (final=" &
                           integer'image(T26_FINAL_BEAT) & ")" severity note;
                elsif busstate = "11" and nWr = '0' and not is_x(pmmu_addr_phys) and
                      unsigned(pmmu_addr_phys(15 downto 0)) = x"0F98" and
                      data_write = x"A5A5" then
                    t26_armed <= '1';
                end if;
            end if;
        end if;
    end process;

    -- T27 evidence: the scenario opens its window when service L writes the
    -- RTE stub word ($4E73 -> phys $3FFE); the kernel's sticky poison flag
    -- must then be observed set (the REAL fall-through prefetch fault into
    -- the invalidated page) before the run completes. Without this check a
    -- timing shift could silently neuter the scenario.
    t27_watch: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                t27_window      <= '0';
                t27_poison_seen <= '0';
            elsif clkena_in = '1' then
                if t27_window = '1' and debug_bus_beat_poisoned_sig = '1' then
                    t27_poison_seen <= '1';
                elsif busstate = "11" and nWr = '0' and not is_x(pmmu_addr_phys) and
                      unsigned(pmmu_addr_phys(15 downto 0)) = x"3FFE" and
                      data_write = x"4E73" then
                    t27_window <= '1';
                end if;
            end if;
        end if;
    end process;

    -- The second runtime write of the page-tail RTE stub starts T28 (the
    -- first starts T27). Require both the real page-2 fall-through fault and
    -- its resulting poison before accepting recovery from the page-3 target.
    t28_watch: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                t28_window <= '0';
                t28_poison_seen <= '0';
                t28_fallthrough_fault_seen <= '0';
            elsif clkena_in = '1' then
                if t28_window = '1' then
                    if debug_bus_beat_poisoned_sig = '1' then
                        t28_poison_seen <= '1';
                    end if;
                    if debug_pmmu_fault = '1' and pmmu_addr_log = x"D0004000" then
                        t28_fallthrough_fault_seen <= '1';
                    end if;
                elsif t27_window = '1' and busstate = "11" and nWr = '0' and
                      not is_x(pmmu_addr_phys) and
                      unsigned(pmmu_addr_phys(15 downto 0)) = x"3FFE" and
                      data_write = x"4E73" then
                    t28_window <= '1';
                end if;
            end if;
        end if;
    end process;

    t31_watch: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                t31_window      <= '0';
                t31_fault_seen  <= '0';
                t31_bad_pc_seen <= '0';
            elsif clkena_in = '1' then
                if t31_window = '1' then
                    if debug_pmmu_fault = '1' and pmmu_addr_log = x"D0004914" then
                        t31_fault_seen <= '1';
                    end if;
                    if debug_TG68_PC(0) = '1' then
                        t31_bad_pc_seen <= '1';
                    end if;
                elsif busstate = "11" and nWr = '0' and
                      not is_x(pmmu_addr_phys) and pmmu_addr_phys = x"00004916" and
                      data_write = x"1200" then
                    t31_window <= '1';
                end if;
            end if;
        end if;
    end process;

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
        variable t6_d6       : std_logic_vector(31 downto 0);
        variable t7_usp, t7_livesp, t7_presp : std_logic_vector(31 downto 0);
        variable t8_sp, t8_mark : std_logic_vector(31 downto 0);
        variable t9_d2, t9_mark : std_logic_vector(31 downto 0);
        variable t10_mem, t10_mark : std_logic_vector(31 downto 0);
        variable t12_d6 : std_logic_vector(31 downto 0);
        variable t14_d7, t14_mark : std_logic_vector(31 downto 0);
        variable t15_mark : std_logic_vector(31 downto 0);
        variable t16_sp, t16_mark : std_logic_vector(31 downto 0);
        variable t17_d1 : std_logic_vector(31 downto 0);
        variable t18_d3 : std_logic_vector(31 downto 0);
        variable t24_mem : std_logic_vector(31 downto 0);
        variable t25_canary : std_logic_vector(31 downto 0);
        variable t25_sp : std_logic_vector(31 downto 0);
        variable t25_pc_opcode : std_logic_vector(15 downto 0);
        variable t25_fa : std_logic_vector(31 downto 0);
        variable t25_ssw : std_logic_vector(15 downto 0);
        variable t25_pc : std_logic_vector(31 downto 0);
        variable t25_h_a7 : std_logic_vector(31 downto 0);
        variable t26_bad : std_logic_vector(31 downto 0);
        variable t26_ok  : std_logic_vector(31 downto 0);
        variable t27_ok  : std_logic_vector(31 downto 0);
        variable t28_ok  : std_logic_vector(31 downto 0);
        variable t28_fa  : std_logic_vector(31 downto 0);
        variable t28_ssw : std_logic_vector(15 downto 0);
        variable t28_pc  : std_logic_vector(31 downto 0);
        variable t9s_fa : std_logic_vector(31 downto 0);
        variable t9s_ssw : std_logic_vector(15 downto 0);
        variable t9s_pc : std_logic_vector(31 downto 0);
        variable t9s_a7 : std_logic_vector(31 downto 0);
        variable t29_canary : std_logic_vector(31 downto 0);
        variable t30_new : std_logic_vector(31 downto 0);
        variable t30_old : std_logic_vector(31 downto 0);
        variable t31_canary : std_logic_vector(31 downto 0);
        variable t32_d0, t32_mem : std_logic_vector(31 downto 0);
        variable t32_ssw : std_logic_vector(15 downto 0);
        variable t19_new, t19_old : std_logic_vector(31 downto 0);
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
        t6_d6       := mem(16#081C#) & mem(16#081D#);
        t7_usp      := mem(16#082C#) & mem(16#082D#);
        t7_livesp   := mem(16#082E#) & mem(16#082F#);
        t7_presp    := mem(16#0830#) & mem(16#0831#);
        t8_sp       := mem(16#0832#) & mem(16#0833#);
        t8_mark     := mem(16#0834#) & mem(16#0835#);
        t9_d2       := mem(16#0836#) & mem(16#0837#);
        t9_mark     := mem(16#0838#) & mem(16#0839#);
        t10_mem     := mem(16#3080#) & mem(16#3081#);
        t10_mark    := mem(16#083A#) & mem(16#083B#);
        t12_d6      := mem(16#07FC#) & mem(16#07FD#);
        t14_d7      := mem(16#07F8#) & mem(16#07F9#);
        t14_mark    := mem(16#07FA#) & mem(16#07FB#);
        t15_mark    := mem(16#07F6#) & mem(16#07F7#);
        t16_sp      := mem(16#07F2#) & mem(16#07F3#);
        t16_mark    := mem(16#07F4#) & mem(16#07F5#);
        t17_d1      := mem(16#07F0#) & mem(16#07F1#);
        t18_d3      := mem(16#07EE#) & mem(16#07EF#);
        t24_mem     := mem(16#07EC#) & mem(16#07ED#);
        t25_canary  := mem(16#07E4#) & mem(16#07E5#);
        t25_sp      := mem(16#07E6#) & mem(16#07E7#);
        t25_fa      := mem(16#0848#) & mem(16#0849#);
        t25_ssw     := mem(16#084A#);
        t25_pc      := mem(16#084B#) & mem(16#084C#);
        t25_h_a7    := mem(16#084D#) & mem(16#084E#);
        t26_bad     := mem(16#07C8#) & mem(16#07C9#);
        t26_ok      := mem(16#07CA#) & mem(16#07CB#);
        t27_ok      := mem(16#07CE#) & mem(16#07CF#);
        t28_ok      := mem(16#07D0#) & mem(16#07D1#);
        t28_fa      := mem(16#0850#) & mem(16#0851#);
        t28_ssw     := mem(16#0852#);
        t28_pc      := mem(16#0853#) & mem(16#0854#);
        t9s_fa      := mem(16#07D8#) & mem(16#07D9#);
        t9s_ssw     := mem(16#07DA#);
        t9s_pc      := mem(16#07DC#) & mem(16#07DD#);
        t9s_a7      := mem(16#07DE#) & mem(16#07DF#);
        t29_canary  := mem(16#07E0#) & mem(16#07E1#);
        t30_new     := mem(16#20C0#) & mem(16#20C1#);
        t30_old     := mem(16#30C0#) & mem(16#30C1#);
        t31_canary  := mem(16#07D2#) & mem(16#07D3#);
        t32_d0      := mem(16#07D4#) & mem(16#07D5#);
        t32_mem     := mem(16#07D6#) & mem(16#07D7#);
        t32_ssw     := mem(16#07E8#);
        t19_new     := mem(16#0720#) & mem(16#0721#);
        t19_old     := mem(16#0700#) & mem(16#0701#);
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
        if fault_count /= x"00000017" then
            report "FAIL: fault count=$" & slv_to_hex(fault_count) & " expected exactly 23 ($17)" severity error;
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
        if t32_d0 /= x"11223344" or t32_mem /= x"55667788" then
            report "FAIL T32: CAS.L locked-RMW restart D0=$" & slv_to_hex(t32_d0) &
                   " memory=$" & slv_to_hex(t32_mem) &
                   " expected $11223344/$55667788" severity error;
            fails := fails + 1;
        end if;
        if t32_ssw(8) /= '1' or t32_ssw(7) /= '1' or t32_ssw(6) /= '1' or
           t32_ssw(2 downto 0) /= "101" then
            report "FAIL T32: CAS.L SSW=$" & slv_to_hex(t32_ssw) &
                   " expected DF=1 RM=1 RW=1 FC=101" severity error;
            fails := fails + 1;
        end if;
        -- T9 frame contents (snapshotted at the landing pad before T25
        -- overwrites the last-wins slots): straddle-page fetch fault.
        if (t9s_fa and x"FFFFE000") /= x"D0004000" then  -- $D0004000..$D0005FFF (straddle page)
            report "FAIL: T9 fault addr=$" & slv_to_hex(t9s_fa) & " expected straddle page $D0004xxx" severity error;
            fails := fails + 1;
        end if;
        if t9s_ssw(8) /= '0' or t9s_ssw(14) /= '1'
           or t9s_ssw(2 downto 0) /= "010" then  -- user program space, insn fault (DF=0, FB=1)
            report "FAIL: T9 SSW=$" & slv_to_hex(t9s_ssw) & " expected DF=0 FB=1 FC=010" severity error;
            fails := fails + 1;
        end if;
        -- T25 was the last dispatched fault before T27; its records were
        -- snapshotted at the T27 target before T28 intentionally overwrote
        -- the live last-fault slots.
        if t25_fa /= x"D0004000" then
            report "FAIL T25: fault addr=$" & slv_to_hex(t25_fa) & " expected $D0004000 (the frame PC slot)" severity error;
            fails := fails + 1;
        end if;
        if t25_ssw(8) /= '1' or t25_ssw(14) /= '0' or t25_ssw(6) /= '1'
           or t25_ssw(2 downto 0) /= "101" then  -- supervisor data read, DF=1
            report "FAIL T25: SSW=$" & slv_to_hex(t25_ssw) & " expected DF=1 RW=1 FB=0 FC=101" severity error;
            fails := fails + 1;
        end if;
        -- Stacked PC must point at the FAULTING instruction (restart contract):
        -- the word at the stacked PC must be the straddling MOVE.L #imm opcode.
        -- The $D000xxxx test window maps to identity-low physical addresses, so
        -- bits 14:1 index the same backing words for both address forms.
        if unsigned(t25_pc and x"0FFFFFFF") < x"00008000" then
            t25_pc_opcode := mem(to_integer(unsigned(t25_pc(14 downto 1))));
        else
            t25_pc_opcode := x"0000";
        end if;
        -- Test 6 (user-mode fault: changeMode swap during stacking)
        if t7_usp /= x"00001800" or t7_livesp /= x"00001800" or t7_presp /= x"00001800" then
            report "FAIL T7: USP contract after user restart: kernel USP=$" & slv_to_hex(t7_usp) &
                   " live SP=$" & slv_to_hex(t7_livesp) & " pre-fault SP=$" & slv_to_hex(t7_presp) &
                   " expected all $00001800" severity error;
            fails := fails + 1;
        end if;
        if t8_mark /= x"F02C600D" then
            report "FAIL T8: RTS after in-subroutine user restart did not return correctly, marker=$" &
                   slv_to_hex(t8_mark) & " post-RTS SP=$" & slv_to_hex(t8_sp) severity error;
            fails := fails + 1;
        end if;
        if t14_d7 /= x"4E714E71" or t14_mark /= x"F14C600D" then
            report "FAIL T14: dispatch-vs-deferred-swap collision: D7=$" & slv_to_hex(t14_d7) &
                   " marker=$" & slv_to_hex(t14_mark) &
                   " expected $4E714E71/$F14C600D (stacked on user A7 / derailed?)" severity error;
            fails := fails + 1;
        end if;
        if t15_mark /= x"F15C600D" then
            report "FAIL T15: boundary fetch fault + M=0 stack-page rewalk during stacking: marker=$" &
                   slv_to_hex(t15_mark) &
                   " expected $F15C600D (double-fault halt / dispatch derailed?)" severity error;
            fails := fails + 1;
        end if;
        if t19_new /= x"C0FEFACE" or t19_old /= x"0FACE001" then
            report "FAIL T19: dependent-store base integrity across restart: [new $0E40]=$" & slv_to_hex(t19_new) &
                   " [old $0E00]=$" & slv_to_hex(t19_old) &
                   " expected $C0FEFACE/$0FACE001 (store landed at STALE base / rollback clobbered A1?)" severity error;
            fails := fails + 1;
        end if;
        if t18_d3 /= x"F18D600D" then
            report "FAIL T18: exec-return PC-relative first-instruction read: D3 store=$" & slv_to_hex(t18_d3) &
                   " expected $F18D600D (stale exe_pc stacked as frame PC / FC=2 data fault mishandled?)" severity error;
            fails := fails + 1;
        end if;
        if t30_new /= x"BBBB6666" then
            report "FAIL T30: post-remap store MISSED the new page: [phys $4180]=$" & slv_to_hex(t30_new) &
                   " expected $BBBB6666 (store translated through a STALE ATC entry)" severity error;
            fails := fails + 1;
        end if;
        if t30_old /= x"AAAA5555" then
            report "FAIL T30: old page clobbered or first write lost: [phys $6180]=$" & slv_to_hex(t30_old) &
                   " expected $AAAA5555 (post-remap store leaked to the OLD phys page)" severity error;
            fails := fails + 1;
        end if;
        if t31_fault_seen /= '1' then
            report "FAIL T31: memory-indirect JMP pointer read did not fault at $D0004914" severity error;
            fails := fails + 1;
        end if;
        if t31_bad_pc_seen = '1' then
            report "FAIL T31: faulted memory-indirect JMP committed an odd garbage PC before dispatch" severity error;
            fails := fails + 1;
        end if;
        if t31_canary /= x"F31C600D" then
            report "FAIL T31: restarted memory-indirect JMP target canary=$" & slv_to_hex(t31_canary) &
                   " expected $F31C600D" severity error;
            fails := fails + 1;
        end if;
        if last_fa /= x"D0004914" then
            report "FAIL T31: fault addr=$" & slv_to_hex(last_fa) & " expected $D0004914" severity error;
            fails := fails + 1;
        end if;
        if last_ssw(8) /= '1' or last_ssw(14) /= '0' or last_ssw(6) /= '1' or
           last_ssw(2 downto 0) /= "110" then
            report "FAIL T31: SSW=$" & slv_to_hex(last_ssw) &
                   " expected DF=1 RW=1 FB=0 FC=110 (supervisor program indirect read)" severity error;
            fails := fails + 1;
        end if;
        if last_pc /= x"000008CC" then
            report "FAIL T31: stacked PC=$" & slv_to_hex(last_pc) &
                   " expected restart PC $000008CC" severity error;
            fails := fails + 1;
        end if;
        if t29_canary /= x"F29C600D" then
            report "FAIL T29: SRE-split RTE-to-user FC contract: canary=$" & slv_to_hex(t29_canary) &
                   " expected $F29C600D (the PC pop walked the USER root - popped SR S bit" &
                   " leaked into the remaining pop cycles' FC)" severity error;
            fails := fails + 1;
        end if;
        if t25_canary /= x"F25C600D" then
            report "FAIL T25: fault on the RTE PC pop: canary=$" & slv_to_hex(t25_canary) &
                   " expected $F25C600D (restarted RTE resumed at garbage/zero PC?)" severity error;
            fails := fails + 1;
        end if;
        if t25_sp /= x"D0004006" then
            report "FAIL T25: RTE restart SP balance: A7=$" & slv_to_hex(t25_sp) &
                   " expected $D0004006 (A7 rollback missed - re-pop from wrong slot)" severity error;
            fails := fails + 1;
        end if;
        if t24_mem /= x"0DEFACED" then
            report "FAIL T24: memory-dest Enforcer completion (DIB substitution): [$0FD8]=$" & slv_to_hex(t24_mem) &
                   " expected DIB $0DEFACED (substitution missed / commit-less loop?)" severity error;
            fails := fails + 1;
        end if;
        if t17_d1 /= x"0DEFACED" then
            report "FAIL T17: Enforcer completion of MOVE.L (d16,A1),D1: D1 store=$" & slv_to_hex(t17_d1) &
                   " expected DIB $0DEFACED (commit rejected multi-word form / resumed into extension word?)" severity error;
            fails := fails + 1;
        end if;
        if t16_mark /= x"F16C600D" or t16_sp /= x"D0004FF8" then
            report "FAIL T16: fault on the RTS pop itself: marker=$" & slv_to_hex(t16_mark) &
                   " post-RTS SP=$" & slv_to_hex(t16_sp) &
                   " expected $F16C600D/$D0004FF8 (A7 side effect leaked through restart -> wrong slot popped, PC=garbage)" severity error;
            fails := fails + 1;
        end if;
        if ENABLE_T12 = 1 and t12_d6 /= x"0DEFACED" then
            report "FAIL T12: Enforcer software completion (UM 8.2.2): D6=$" & slv_to_hex(t12_d6) &
                   " expected DIB value $0DEFACED (re-ran the read / ignored DF clear?)" severity error;
            fails := fails + 1;
        end if;
        if t10_mem /= x"C0C0D0D0" or t10_mark /= x"D0006100" then
            report "FAIL T10: WP (COW) write fault: [$6100]=$" & slv_to_hex(t10_mem) &
                   " marker=$" & slv_to_hex(t10_mark) & " expected $C0C0D0D0/$D0006100 (write LOST?)" severity error;
            fails := fails + 1;
        end if;
        if t9_d2 /= x"CAFED00D" or t9_mark /= x"F17C600D" then
            report "FAIL T9: extension-straddle insn fault: D2 store=$" & slv_to_hex(t9_d2) &
                   " marker=$" & slv_to_hex(t9_mark) & " expected $CAFED00D/$F17C600D" severity error;
            fails := fails + 1;
        end if;
        if t8_sp /= x"00001800" then
            report "FAIL T8: user SP after BSR/RTS=$" & slv_to_hex(t8_sp) & " expected $00001800" severity error;
            fails := fails + 1;
        end if;
        if t6_d6 /= x"FEEDF00D" then
            report "FAIL T6: user-mode MOVE.L (A6),D6 after restart D6=$" & slv_to_hex(t6_d6) & " expected $FEEDF00D" severity error;
            fails := fails + 1;
        end if;
        -- Supervisor stack balance: every fault stacks a full format $B frame
        -- ($5C bytes) from SSP=$2000 and RTE pops exactly the same amount, so
        -- the handler (after its 16-byte MOVEM push) must see the SAME A7 for
        -- every fault: $2000 - $5C - $10 = $1F94. Any push/pop mismatch leaks
        -- SSP by 4 per fault and shows up here on the 5th fault.
        -- (T25's service J overwrites phys $3FFE at runtime, so the post-run
        -- opcode lookup is stale for T9 - assert the exact stacked PC value.)
        if t9s_pc /= x"D0003FFE" then
            report "FAIL: T9 stacked PC=$" & slv_to_hex(t9s_pc) &
                   " expected $D0003FFE (the straddling MOVE.L opcode)" severity error;
            fails := fails + 1;
        end if;
        if t25_pc_opcode /= x"4E73" then
            report "FAIL T25: stacked PC=$" & slv_to_hex(t25_pc) & " does not point at the faulting RTE opcode (found $" &
                   slv_to_hex(t25_pc_opcode) & ") - restart contract broken for a mid-RTE fault" severity error;
            fails := fails + 1;
        end if;
        if t9s_a7 /= x"00001F94" then
            report "FAIL: T9 handler A7=$" & slv_to_hex(t9s_a7) & " expected $00001F94 (SSP leak across faults)" severity error;
            fails := fails + 1;
        end if;
        if t25_h_a7 /= x"D0003F92" then
            report "FAIL T25: handler A7=$" & slv_to_hex(t25_h_a7) & " expected $D0003F92 (frame at $D0003FA2" &
                   " - A7 rollback to $D0003FFE leaked?)" severity error;
            fails := fails + 1;
        end if;
        -- T26: invalid-beat RTE redirect. A force-released directPC beat sets
        -- bus_beat_poisoned with no fault pending. A non-final release must not
        -- veto the later clean commit; a final release must retry before the
        -- PC/A7/microstate commit. Sail-on means the kernel kept executing the
        -- old stream past the RTE (the beacon 0014/0015/0019 lockup mechanism).
        if t26_fired /= '1' then
            report "FAIL T26: poison injection never landed (selected directPC pop beat not found)" severity error;
            fails := fails + 1;
        end if;
        if t26_bad = x"0BAD0BAD" then
            report "FAIL T26: RTE redirect silently skipped - execution SAILED ON past the RTE" &
                   " (stale bus_beat_poisoned vetoed a clean directPC commit with no fault pending)" severity error;
            fails := fails + 1;
        end if;
        if t26_ok /= x"F26C600D" then
            report "FAIL T26: redirect target canary=$" & slv_to_hex(t26_ok) &
                   " expected $F26C600D (RTE did not resume at the frame PC)" severity error;
            fails := fails + 1;
        end if;
        -- T27: wrapper-valid poison-veto - the page-tail RTE whose
        -- fall-through prefetch really faults (then squashes) must still
        -- redirect. Poison evidence is required so a timing shift cannot
        -- silently neuter the scenario.
        if t27_poison_seen /= '1' then
            report "FAIL T27: parasitic prefetch fault never set the poison flag" &
                   " (scenario timing shifted - fault landed before the RTE decode?)" severity error;
            fails := fails + 1;
        end if;
        if t27_ok /= x"F27C600D" then
            report "FAIL T27: redirect target canary=$" & slv_to_hex(t27_ok) &
                   " expected $F27C600D (page-tail RTE with squashed prefetch fault" &
                   " did not resume at the frame PC)" severity error;
            fails := fails + 1;
        end if;
        -- T28: the discarded page-2 fault must not consume or mask the real
        -- first fetch at the page-3 redirect target.
        if t28_fallthrough_fault_seen /= '1' or t28_poison_seen /= '1' then
            report "FAIL T28: page-tail fall-through fault/poison was not observed" &
                   " (fault=" & std_logic'image(t28_fallthrough_fault_seen) &
                   " poison=" & std_logic'image(t28_poison_seen) & ")" severity error;
            fails := fails + 1;
        end if;
        if t28_ok /= x"F28C600D" then
            report "FAIL T28: redirect-target canary=$" & slv_to_hex(t28_ok) &
                   " expected $F28C600D (target demand fault was lost or mis-dispatched)" severity error;
            fails := fails + 1;
        end if;
        if t28_fa /= x"D0006200" then
            report "FAIL T28: target fault addr=$" & slv_to_hex(t28_fa) &
                   " expected $D0006200" severity error;
            fails := fails + 1;
        end if;
        if t28_ssw(8) /= '0' or t28_ssw(14) /= '1' or
           t28_ssw(2 downto 0) /= "010" then
            report "FAIL T28: target SSW=$" & slv_to_hex(t28_ssw) &
                   " expected DF=0 FB=1 FC=010" severity error;
            fails := fails + 1;
        end if;
        if t28_pc /= x"D0006200" then
            report "FAIL T28: target stacked PC=$" & slv_to_hex(t28_pc) &
                   " expected $D0006200" severity error;
            fails := fails + 1;
        end if;

        if fails = 0 then
            report "PASS: MMU restart and RTE redirect contract completed under plain-RTE (NetBSD) handling" severity note;
        else
            report "FAIL: " & integer'image(fails) & " restart-contract checks failed" severity error;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
