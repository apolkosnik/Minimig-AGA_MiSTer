-- tb_chk_stacked_trace.vhd
-- Tests CHK instruction + stacked trace frame behavior (BUG #439 fix).
--
-- When CHK fires with T1=1 (trace mode active), the MC68030 pushes two
-- consecutive Format $2 stack frames:
--   1. CHK frame  (vector $18): PC = next instr after CHK,
--                               instr_addr = CHK instruction address
--   2. Trace frame (vector $24): PC = CHK handler entry address,
--                                instr_addr = CHK handler entry address
--
-- BUG #439 had two sub-bugs, both fixed in TG68KdotC_Kernel.vhd:
--   BUG A: exe_pc at trace_stk_grp2 used stale TG68_PC (pre-handler address).
--          Fix: use data_read (the actual handler address from vector table read).
--   BUG B: set(trap_chk)='1' persists from stale opcode throughout the stacked
--          trace frame and overrides trap_trace='1' -> $24 in trap_vector chain.
--          Fix: move trap_trace -> $24 AFTER exec/set(trap_chk) -> $18 so trace
--          wins when trap_trace='1' (stacked trace frame).
--
-- Tests:
--   1. CHK.W D1,D0 with T1=1 (D0.W = -1, below zero -> CHK trap + stacked trace)
--   2. CHK.L D1,D0 with T1=1 (D0.L = -1, below zero -> CHK trap + stacked trace)
--   3. CHK.L (A1)+,D0 with T1=1 (odd source address, CHK trap + stacked trace)
--
-- Stack layout after both tests (SSP=$4000):
--   CHK frame at $3FF4 (pushed first):
--     $3FF4: SR ($A700 = T1=1, S=1, IPL=7)
--     $3FF6/$3FF8: PC = next instruction after CHK
--     $3FFA: Format/Vector = $2018 (format=2, vector=$018)
--     $3FFC/$3FFE: Instruction Address = CHK instruction address
--   Trace frame at $3FE8 (pushed second, lower address):
--     $3FE8: SR ($A700)
--     $3FEA/$3FEC: PC = CHK handler entry address (BUG A: was stale pre-handler PC)
--     $3FEE: Format/Vector = $2024 (BUG B: was $2018 due to stale opcode)
--     $3FF0/$3FF2: Instruction Address = CHK handler entry address (BUG A fix)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_chk_stacked_trace is
end entity;

architecture behavior of tb_chk_stacked_trace is
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal data_in   : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out  : std_logic_vector(31 downto 0);
    signal nWr       : std_logic;
    signal nUDS      : std_logic;
    signal nLDS      : std_logic;
    signal busstate  : std_logic_vector(1 downto 0);
    signal FC        : std_logic_vector(2 downto 0);
    signal IPL_sig   : std_logic_vector(2 downto 0) := "111";

    constant CLK_PERIOD : time := 10 ns;
    -- 32K words = 64KB address space
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done : boolean := false;

begin
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => IPL_sig,
            IPL_autovector => '1',
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            FC             => FC,
            longword       => open,
            nResetOut      => open,
            clr_berr       => open,
            skipFetch      => open,
            regin_out      => open,
            CACR_out       => open,
            VBR_out        => open,
            cache_inv_req  => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr  => open,
            pmmu_reg_we    => open,
            pmmu_reg_re    => open,
            pmmu_reg_sel   => open,
            pmmu_reg_wdat  => open,
            pmmu_reg_part  => open,
            pmmu_addr_log  => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req  => open,
            pmmu_walker_we   => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack  => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode        => open,
            debug_preSVmode     => open,
            debug_FlagsSR_S     => open,
            debug_changeMode    => open,
            debug_setopcode     => open,
            debug_exec_directSR => open,
            debug_exec_to_SR    => open,
            debug_pmove_dn_mode   => open,
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
        -- Use integer variables for pass/fail counting so multiple increments
        -- within a single process activation accumulate correctly (signals only
        -- commit after the next wait statement, causing undercounting).
        variable v_pass_count : integer := 0;
        variable v_fail_count : integer := 0;

        variable v_stacked_sr    : std_logic_vector(15 downto 0);
        variable v_pc_hi         : std_logic_vector(15 downto 0);
        variable v_pc_lo         : std_logic_vector(15 downto 0);
        variable v_format_word   : std_logic_vector(15 downto 0);
        variable v_instr_addr_hi : std_logic_vector(15 downto 0);
        variable v_instr_addr_lo : std_logic_vector(15 downto 0);
        variable v_stacked_pc    : std_logic_vector(31 downto 0);
        variable v_stacked_ia    : std_logic_vector(31 downto 0);
        variable v_format        : std_logic_vector(3 downto 0);
        variable v_vector        : std_logic_vector(11 downto 0);

        -- Wait for CPU to reach STOP (sustained bus inactivity)
        procedure wait_for_stop(timeout_cycles : integer := 6000) is
            variable idle_count : integer;
        begin
            idle_count := 0;
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
            report "TIMEOUT waiting for STOP" severity error;
        end procedure;

        -- Read a Format $2 frame from memory at sp_addr
        procedure read_frame(sp_addr : unsigned(31 downto 0)) is
            variable idx : integer;
        begin
            idx             := to_integer(sp_addr(15 downto 1));
            v_stacked_sr    := mem(idx);
            v_pc_hi         := mem(idx + 1);
            v_pc_lo         := mem(idx + 2);
            v_format_word   := mem(idx + 3);
            v_instr_addr_hi := mem(idx + 4);
            v_instr_addr_lo := mem(idx + 5);
            v_stacked_pc    := v_pc_hi & v_pc_lo;
            v_stacked_ia    := v_instr_addr_hi & v_instr_addr_lo;
            v_format        := v_format_word(15 downto 12);
            v_vector        := v_format_word(11 downto 0);
        end procedure;

        procedure check_format(test_name : string; expected : std_logic_vector(3 downto 0)) is
        begin
            if v_format = expected then
                report "  PASS: " & test_name & " format=$" &
                       integer'image(to_integer(unsigned(expected))) severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " format: expected=$" &
                       integer'image(to_integer(unsigned(expected))) &
                       " got=$" & integer'image(to_integer(unsigned(v_format))) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_vector(test_name : string; expected : std_logic_vector(11 downto 0)) is
        begin
            if v_vector = expected then
                report "  PASS: " & test_name & " vector=$" &
                       integer'image(to_integer(unsigned(expected))) severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " vector: expected=$" &
                       integer'image(to_integer(unsigned(expected))) &
                       " got=$" & integer'image(to_integer(unsigned(v_vector))) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_pc(test_name : string; expected : std_logic_vector(31 downto 0)) is
        begin
            if v_stacked_pc = expected then
                report "  PASS: " & test_name & " PC=$" &
                       integer'image(to_integer(unsigned(expected))) severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " PC: expected=$" &
                       integer'image(to_integer(unsigned(expected))) &
                       " got=$" & integer'image(to_integer(unsigned(v_stacked_pc))) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_sr(test_name : string; expected : std_logic_vector(15 downto 0)) is
        begin
            if v_stacked_sr = expected then
                report "  PASS: " & test_name & " SR=$" &
                       integer'image(to_integer(unsigned(expected))) severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " SR: expected=$" &
                       integer'image(to_integer(unsigned(expected))) &
                       " got=$" & integer'image(to_integer(unsigned(v_stacked_sr))) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        procedure check_ia(test_name : string; expected : std_logic_vector(31 downto 0)) is
        begin
            if v_stacked_ia = expected then
                report "  PASS: " & test_name & " instr_addr=$" &
                       integer'image(to_integer(unsigned(expected))) severity note;
                v_pass_count := v_pass_count + 1;
            else
                report "  FAIL: " & test_name & " instr_addr: expected=$" &
                       integer'image(to_integer(unsigned(expected))) &
                       " got=$" & integer'image(to_integer(unsigned(v_stacked_ia))) severity error;
                v_fail_count := v_fail_count + 1;
            end if;
        end procedure;

        -- Fill memory with NOP, set reset vectors SSP=$4000 PC=$1000
        procedure init_memory is
        begin
            for i in 0 to 32767 loop
                mem(i) := x"4E71";
            end loop;
            mem(0) := x"0000";  -- SSP high
            mem(1) := x"4000";  -- SSP low
            mem(2) := x"0000";  -- PC high
            mem(3) := x"1000";  -- PC low
        end procedure;

        -- Write 32-bit vector table entry
        procedure setup_vector(vec_offset : integer; handler_addr : integer) is
        begin
            mem(vec_offset / 2)     := std_logic_vector(to_unsigned(handler_addr / 65536, 16));
            mem(vec_offset / 2 + 1) := std_logic_vector(to_unsigned(handler_addr mod 65536, 16));
        end procedure;

        -- Write handler code: MOVEA.L A7,A6 ; STOP #$2700
        procedure setup_handler(handler_addr : integer) is
        begin
            mem(handler_addr / 2)     := x"2C4F";  -- MOVEA.L A7,A6
            mem(handler_addr / 2 + 1) := x"4E72";  -- STOP
            mem(handler_addr / 2 + 2) := x"2700";  -- #$2700
        end procedure;

        procedure do_reset is
        begin
            nReset  <= '0';
            IPL_sig <= "111";
            wait for 100 ns;
            nReset  <= '1';
            for i in 0 to 2000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1000" then
                    exit;
                end if;
            end loop;
        end procedure;

    begin
        report "========================================" severity note;
        report "CHK + Stacked Trace Frame Test (BUG #439)" severity note;
        report "MC68030 Group 2 exception + T1 trace stacking" severity note;
        report "========================================" severity note;

        -- ================================================================
        -- TEST 1: CHK.W D1,D0 with T1=1
        --
        -- Code at $1000:
        --   $1000: MOVE.W #$FFFF,D0  (303C FFFF) D0.W=-1, below zero
        --   $1004: MOVE.W #10,D1     (323C 000A) D1.W=10, upper bound
        --   $1008: MOVE #$A700,SR    (46FC A700) T1=1 S=1 IPL=7 (NOT traced, old T1=0)
        --   $100C: CHK.W D1,D0       (4181)      D0<0, trap fires (T1=1 -> stacked trace)
        --   $100E: NOP               (4E71)       CHK frame stacked PC points here
        --
        -- CHK handler at $2000 (address read from vector $18, never executed)
        -- Trace handler at $2100 (address read from vector $24, CPU enters here)
        --
        -- Expected after STOP in trace handler:
        --   Trace frame at $3FE8: format=$2, vector=$024, PC=$2000, IA=$2000
        --   CHK frame  at $3FF4: format=$2, vector=$018, PC=$100E, IA=$100C
        -- ================================================================
        report "" severity note;
        report "TEST 1: CHK.W D1,D0 with T1=1 (stacked trace)" severity note;
        report "  BUG #439 check: trace frame must have vector=$024 and IA=CHK handler addr" severity note;

        init_memory;
        setup_vector(16#18#, 16#2000#);  -- CHK exception vector -> $2000
        setup_vector(16#24#, 16#2100#);  -- Trace exception vector -> $2100
        setup_handler(16#2000#);         -- CHK handler (never executed in this test)
        setup_handler(16#2100#);         -- Trace handler (CPU enters here)

        mem(16#1000# / 2) := x"303C";   -- MOVE.W #imm,D0
        mem(16#1002# / 2) := x"FFFF";   -- D0.W = -1 (will fail CHK)
        mem(16#1004# / 2) := x"323C";   -- MOVE.W #imm,D1
        mem(16#1006# / 2) := x"000A";   -- D1.W = 10 (upper bound)
        mem(16#1008# / 2) := x"46FC";   -- MOVE #imm,SR
        mem(16#100A# / 2) := x"A700";   -- SR = $A700: T1=1 S=1 IPL=7
        mem(16#100C# / 2) := x"4181";   -- CHK.W D1,D0 (D0.W=-1 < 0 -> trap)
        mem(16#100E# / 2) := x"4E71";   -- NOP (CHK frame stacked PC)

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- After STOP in trace handler:
        --   SP = $3FE8 (trace frame base, 12 bytes below CHK frame $3FF4)
        report "  -- Trace frame (SP=$3FE8, pushed second):" severity note;
        read_frame(x"00003FE8");
        check_format("CHK.W trace frame", "0010");
        check_vector("CHK.W trace frame vector (BUG B: $024 not $018)", x"024");
        check_pc("CHK.W trace PC=CHK_handler=$2000", x"00002000");
        check_ia("CHK.W trace IA=CHK_handler=$2000 (BUG A fix)", x"00002000");

        report "  -- CHK frame (SP=$3FF4, pushed first):" severity note;
        read_frame(x"00003FF4");
        check_format("CHK.W frame", "0010");
        check_vector("CHK.W frame vector=$018", x"018");
        check_pc("CHK.W frame PC=next_instr=$100E", x"0000100E");
        check_ia("CHK.W frame IA=CHK_addr=$100C", x"0000100C");

        -- ================================================================
        -- TEST 2: CHK.L D1,D0 with T1=1
        --
        -- Code at $1000:
        --   $1000: MOVE.L #-1,D0    (203C FFFF FFFF) D0.L=$FFFFFFFF=-1
        --   $1006: MOVE.W #10,D1    (323C 000A)      D1.W=10 (bound)
        --   $100A: MOVE #$A700,SR   (46FC A700)      T1=1 S=1 (NOT traced)
        --   $100E: CHK.L D1,D0      (4101)            D0.L<0, trap fires (T1=1)
        --   $1010: NOP              (4E71)             CHK frame stacked PC
        --
        -- Expected after STOP in trace handler:
        --   Trace frame at $3FE8: format=$2, vector=$024, PC=$2000, IA=$2000
        --   CHK frame  at $3FF4: format=$2, vector=$018, PC=$1010, IA=$100E
        -- ================================================================
        report "" severity note;
        report "TEST 2: CHK.L D1,D0 with T1=1 (stacked trace)" severity note;
        report "  Verifies stacked trace works for long-word CHK variant (68020+)" severity note;

        init_memory;
        setup_vector(16#18#, 16#2000#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2000#);
        setup_handler(16#2100#);

        mem(16#1000# / 2) := x"203C";   -- MOVE.L #imm,D0
        mem(16#1002# / 2) := x"FFFF";   -- high word of -1
        mem(16#1004# / 2) := x"FFFF";   -- low word of -1  (D0.L=$FFFFFFFF)
        mem(16#1006# / 2) := x"323C";   -- MOVE.W #imm,D1
        mem(16#1008# / 2) := x"000A";   -- D1.W = 10 (upper bound)
        mem(16#100A# / 2) := x"46FC";   -- MOVE #imm,SR
        mem(16#100C# / 2) := x"A700";   -- SR = $A700: T1=1 S=1 IPL=7
        mem(16#100E# / 2) := x"4101";   -- CHK.L D1,D0 (D0.L<0 -> trap)
        mem(16#1010# / 2) := x"4E71";   -- NOP (CHK frame stacked PC)

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        report "  -- Trace frame (SP=$3FE8, pushed second):" severity note;
        read_frame(x"00003FE8");
        check_format("CHK.L trace frame", "0010");
        check_vector("CHK.L trace frame vector (BUG B: $024 not $018)", x"024");
        check_pc("CHK.L trace PC=CHK_handler=$2000", x"00002000");
        check_ia("CHK.L trace IA=CHK_handler=$2000 (BUG A fix)", x"00002000");

        report "  -- CHK.L frame (SP=$3FF4, pushed first):" severity note;
        read_frame(x"00003FF4");
        check_format("CHK.L frame", "0010");
        check_vector("CHK.L frame vector=$018", x"018");
        check_pc("CHK.L frame PC=next_instr=$1010", x"00001010");
        check_ia("CHK.L frame IA=CHK.L_addr=$100E", x"0000100E");

        -- ================================================================
        -- TEST 2B: CHK.L (A1)+,D0 with T1=1
        --
        -- Reproduces the memory-source CHK.L case with an odd source address.
        -- The source access must still retire as a CHK exception with stacked
        -- trace, not as an address error.
        --
        -- Code at $1000:
        --   $1000: MOVEA.L #$3001,A1  (227C 0000 3001)
        --   $1006: MOVE.L  #$01C0,D0  (203C 0000 01C0)
        --   $100C: MOVE    #$A700,SR  (46FC A700)
        --   $1010: CHK.L   (A1)+,D0   (4119)
        --   $1012: NOP                (4E71)
        --
        -- Unaligned source bytes at $3001..$3004 are 00 00 00 79.
        -- Expected after STOP in trace handler:
        --   Trace frame at $3FE8: format=$2, vector=$024, PC=$2000, IA=$2000
        --   CHK frame  at $3FF4: format=$2, vector=$018, PC=$1012, IA=$1010
        -- ================================================================
        report "" severity note;
        report "TEST 2B: CHK.L (A1)+,D0 with T1=1 (stacked trace)" severity note;
        report "  Verifies odd source addresses still stack CHK + trace frames" severity note;

        init_memory;
        setup_vector(16#18#, 16#2000#);
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2000#);
        setup_handler(16#2100#);

        mem(16#1000# / 2) := x"227C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3001";
        mem(16#1006# / 2) := x"203C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"01C0";
        mem(16#100C# / 2) := x"46FC";
        mem(16#100E# / 2) := x"A700";
        mem(16#1010# / 2) := x"4119";
        mem(16#1012# / 2) := x"4E71";

        mem(16#3000# / 2) := x"AA00";
        mem(16#3002# / 2) := x"0000";
        mem(16#3004# / 2) := x"7900";

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        report "  -- Trace frame (SP=$3FE8, pushed second):" severity note;
        read_frame(x"00003FE8");
        check_format("CHK.L (A1)+ trace frame", "0010");
        check_vector("CHK.L (A1)+ trace frame vector=$024", x"024");
        check_pc("CHK.L (A1)+ trace PC=CHK_handler=$2000", x"00002000");
        check_ia("CHK.L (A1)+ trace IA=CHK_handler=$2000", x"00002000");

        report "  -- CHK.L frame (SP=$3FF4, pushed first):" severity note;
        read_frame(x"00003FF4");
        check_format("CHK.L (A1)+ frame", "0010");
        check_vector("CHK.L (A1)+ frame vector=$018", x"018");
        check_pc("CHK.L (A1)+ frame PC=next_instr=$1012", x"00001012");
        check_ia("CHK.L (A1)+ frame IA=CHK_addr=$1010", x"00001010");

        -- ================================================================
        -- TEST 3: CHK2.B (A0),D0 with T1=1
        --
        -- CHK2 uses a different execution path (chk20-chk24 micro-states)
        -- than regular CHK. This tests that stacked trace works for CHK2.
        --
        -- Code at $1000:
        --   $1000: MOVE.L #$3000,A0  (207C 0000 3000) A0 = bounds address
        --   $1006: MOVE.L #$FF,D0    (203C 0000 00FF) D0 = 255 (out of range)
        --   $100C: MOVE #$A700,SR    (46FC A700) T1=1 S=1 IPL=7 (NOT traced)
        --   $1010: CHK2.B (A0),D0    (00D0 0800) D0=$FF > $20, trap fires
        --   $1014: NOP               (4E71) CHK frame stacked PC points here
        --
        -- Bounds at $3000: lower=$10, upper=$20 (bytes)
        -- CHK handler at $2000, Trace handler at $2100
        --
        -- Expected:
        --   CHK frame at $3FF4: format=$2, vector=$018, PC=$1014, IA=$1010
        --   Trace frame at $3FE8: format=$2, vector=$024, PC=$2000, IA=$2000
        -- ================================================================
        report "" severity note;
        report "TEST 3: CHK2.B (A0),D0 with T1=1 (stacked trace)" severity note;
        report "  Tests CHK2 micro-state path (chk20-chk24) with trace pending" severity note;

        init_memory;
        setup_vector(16#18#, 16#2000#);  -- CHK exception vector -> $2000
        setup_vector(16#24#, 16#2100#);  -- Trace exception vector -> $2100
        setup_handler(16#2000#);
        setup_handler(16#2100#);

        -- Bounds at $3000: lower=$10, upper=$20
        mem(16#3000# / 2) := x"1020";   -- lower=$10, upper=$20

        mem(16#1000# / 2) := x"207C";   -- MOVE.L #imm,A0
        mem(16#1002# / 2) := x"0000";   -- high word
        mem(16#1004# / 2) := x"3000";   -- A0 = $3000 (bounds)
        mem(16#1006# / 2) := x"203C";   -- MOVE.L #imm,D0
        mem(16#1008# / 2) := x"0000";   -- high word
        mem(16#100A# / 2) := x"00FF";   -- D0 = $FF (out of range: $FF > $20)
        mem(16#100C# / 2) := x"46FC";   -- MOVE #imm,SR
        mem(16#100E# / 2) := x"A700";   -- SR = $A700: T1=1 S=1 IPL=7
        mem(16#1010# / 2) := x"00D0";   -- CHK2.B (A0),D0 opcode
        mem(16#1012# / 2) := x"0800";   -- extension: D0, CHK2 (bit 11=1)
        mem(16#1014# / 2) := x"4E71";   -- NOP (CHK frame stacked PC)

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        report "  -- Trace frame (SP=$3FE8, pushed second):" severity note;
        read_frame(x"00003FE8");
        check_format("CHK2.B trace frame", "0010");
        check_vector("CHK2.B trace vector=$024", x"024");
        check_pc("CHK2.B trace PC=CHK_handler=$2000", x"00002000");
        check_ia("CHK2.B trace IA=CHK_handler=$2000", x"00002000");

        report "  -- CHK frame (SP=$3FF4, pushed first):" severity note;
        read_frame(x"00003FF4");
        check_format("CHK2.B CHK frame", "0010");
        check_vector("CHK2.B CHK frame vector=$018", x"018");
        check_pc("CHK2.B CHK frame PC=next_instr=$1014", x"00001014");
        check_ia("CHK2.B CHK frame IA=CHK2_addr=$1010", x"00001010");

        -- ================================================================
        -- TEST 4: CHK2.B (A0),D0 with T1=1, value IN BOUNDS (no CHK trap)
        --
        -- When CHK2 doesn't trap but T1 is active, a NORMAL trace exception
        -- should fire after the CHK2 instruction completes.
        --
        -- Code at $1000:
        --   $1000: MOVE.L #$3000,A0  (207C 0000 3000) A0 = bounds address
        --   $1006: MOVE.L #$15,D0    (203C 0000 0015) D0 = $15 (in range $10-$20)
        --   $100C: MOVE #$A700,SR    (46FC A700) T1=1 S=1 IPL=7 (NOT traced)
        --   $1010: CHK2.B (A0),D0    (00D0 0800) D0=$15, in range -> no trap
        --   $1014: NOP               (4E71) trace frame PC points here
        --
        -- Bounds at $3000: lower=$10, upper=$20
        -- Trace handler at $2100
        --
        -- Expected: Single trace frame at $3FF4 (no CHK frame)
        --   Format $2, vector $024, PC=$1014 (next instr after CHK2)
        -- ================================================================
        report "" severity note;
        report "TEST 4: CHK2.B (A0),D0 with T1=1, IN BOUNDS (normal trace)" severity note;
        report "  Tests that normal T1 trace fires after CHK2 that does NOT trap" severity note;

        init_memory;
        setup_vector(16#18#, 16#2000#);  -- CHK exception vector (not used)
        setup_vector(16#24#, 16#2100#);  -- Trace exception vector
        setup_handler(16#2100#);         -- Trace handler

        -- Bounds at $3000: lower=$10, upper=$20
        mem(16#3000# / 2) := x"1020";   -- lower=$10, upper=$20

        mem(16#1000# / 2) := x"207C";   -- MOVE.L #imm,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3000";   -- A0 = $3000 (bounds)
        mem(16#1006# / 2) := x"203C";   -- MOVE.L #imm,D0
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"0015";   -- D0 = $15 (in range $10-$20)
        mem(16#100C# / 2) := x"46FC";   -- MOVE #imm,SR
        mem(16#100E# / 2) := x"A700";   -- SR = $A700: T1=1 S=1 IPL=7
        mem(16#1010# / 2) := x"00D0";   -- CHK2.B (A0),D0 opcode
        mem(16#1012# / 2) := x"0800";   -- extension: D0, CHK2 (bit 11=1)
        mem(16#1014# / 2) := x"4E71";   -- NOP (trace frame PC points here)

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- Normal trace: single Format $2 frame at $3FF4 (SSP=$4000, 12 bytes)
        report "  -- Trace frame (SP=$3FF4):" severity note;
        read_frame(x"00003FF4");
        check_sr("CHK2.B normal trace SR=$A700", x"A700");
        check_format("CHK2.B normal trace frame", "0010");
        check_vector("CHK2.B normal trace vector=$024", x"024");
        check_pc("CHK2.B normal trace PC=next_instr=$1014", x"00001014");

        -- ================================================================
        -- TEST 5: CHK2.B (A0),D0 with T1=1 in user mode (normal trace)
        --
        -- This matches the cputest-style "SR=$8000 then CHK2 trace" shape:
        -- the normal trace frame must preserve the user-mode T1 SR image.
        -- ================================================================
        report "" severity note;
        report "TEST 5: CHK2.B (A0),D0 with SR=$8000 (normal trace)" severity note;
        report "  Tests user-mode T1 saved SR image on the CHK2 no-trap path" severity note;

        init_memory;
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2100#);

        mem(16#3000# / 2) := x"1020";

        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3000";
        mem(16#1006# / 2) := x"203C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"0015";
        mem(16#100C# / 2) := x"46FC";
        mem(16#100E# / 2) := x"8000";
        mem(16#1010# / 2) := x"00D0";
        mem(16#1012# / 2) := x"0800";
        mem(16#1014# / 2) := x"4E71";

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        report "  -- Trace frame (SP=$3FF4):" severity note;
        read_frame(x"00003FF4");
        check_sr("CHK2.B user normal trace SR=$8000", x"8000");
        check_format("CHK2.B user normal trace frame", "0010");
        check_vector("CHK2.B user normal trace vector=$024", x"024");
        check_pc("CHK2.B user normal trace PC=next_instr=$1014", x"00001014");

        -- ================================================================
        -- TEST 6: CHK2.W (A0),D0 with T1=1 in user mode (normal trace)
        --
        -- Mirrors the hardware cputest/basic CHK2.W shape: saved SR must
        -- preserve the user-mode T1 image on the no-trap CHK2 path.
        -- ================================================================
        report "" severity note;
        report "TEST 6: CHK2.W (A0),D0 with SR=$8000 (normal trace)" severity note;
        report "  Tests user-mode T1 saved SR image on the CHK2.W no-trap path" severity note;

        init_memory;
        setup_vector(16#24#, 16#2100#);
        setup_handler(16#2100#);

        mem(16#3000# / 2) := x"0010";
        mem(16#3002# / 2) := x"0020";

        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3000";
        mem(16#1006# / 2) := x"203C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"0015";
        mem(16#100C# / 2) := x"46FC";
        mem(16#100E# / 2) := x"8000";
        mem(16#1010# / 2) := x"02D0";
        mem(16#1012# / 2) := x"0800";
        mem(16#1014# / 2) := x"4E71";

        for i in 16#3F00# / 2 to 16#4000# / 2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        report "  -- Trace frame (SP=$3FF4):" severity note;
        read_frame(x"00003FF4");
        check_sr("CHK2.W user normal trace SR=$8000", x"8000");
        check_format("CHK2.W user normal trace frame", "0010");
        check_vector("CHK2.W user normal trace vector=$024", x"024");
        check_pc("CHK2.W user normal trace PC=next_instr=$1014", x"00001014");

        -- ================================================================
        -- SUMMARY
        -- ================================================================
        report "" severity note;
        report "========================================" severity note;
        report "RESULTS: " & integer'image(v_pass_count) & " passed, " &
               integer'image(v_fail_count) & " failed" severity note;
        report "========================================" severity note;

        if v_fail_count > 0 then
            report "SOME TESTS FAILED" severity error;
        else
            report "ALL TESTS PASSED" severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
