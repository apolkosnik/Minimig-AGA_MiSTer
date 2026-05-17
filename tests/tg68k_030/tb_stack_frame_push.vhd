-- tb_stack_frame_push.vhd
-- Validates exception stack frame GENERATION (what the CPU pushes)
-- for all MC68030 exception types against spec Table 8-6.
--
-- Tests verify:
--   1. Format code in format/vector word (bits 15:12)
--   2. Vector offset in format/vector word (bits 11:0)
--   3. Stacked PC value (should point to correct location per exception type)
--   4. Frame size (SP displacement)
--   5. Instruction address field for Format $2 frames
--
-- MC68030 Stack Frame Layout (from SP upward):
--   SP+0: Status Register (16 bits)
--   SP+2: Program Counter High (16 bits)
--   SP+4: Program Counter Low (16 bits)
--   SP+6: Format/Vector Word (16 bits) = format(15:12) & vector_offset(11:0)
--   SP+8: [Format $2 only] Instruction Address (32 bits)
--
-- Per WinUAE's 68030 exception frame selection:
--   Format $0 (8 bytes): Interrupt, Format Error, TRAP #n, Illegal,
--                         A-line, F-line, Privilege Violation, MMU Configuration
--   Format $2 (12 bytes): CHK, TRAPcc, TRAPV, Trace, Zero Divide,
--                          cpTRAPcc

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_stack_frame_push is
end entity;

architecture behavior of tb_stack_frame_push is
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
    signal test_passed : integer := 0;
    signal test_failed : integer := 0;

    -- Stack write capture: record all writes during exception stacking
    type stack_write_t is record
        addr : std_logic_vector(31 downto 0);
        data : std_logic_vector(15 downto 0);
        uds  : std_logic;
        lds  : std_logic;
    end record;
    type stack_writes_array is array(0 to 63) of stack_write_t;
    signal stack_writes : stack_writes_array;
    signal stack_write_count : integer := 0;
    signal capture_stacks : boolean := false;

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
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => IPL_sig,
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",  -- 68030
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
            debug_pmove_dn_regnum => open
        );

    -- Memory read
    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 32767 else x"4E71";

    -- Memory write with stack capture
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

                -- Capture stack writes when enabled
                if capture_stacks and stack_write_count < 64 then
                    stack_writes(stack_write_count).addr <= addr_out;
                    stack_writes(stack_write_count).data <= data_write;
                    stack_writes(stack_write_count).uds <= nUDS;
                    stack_writes(stack_write_count).lds <= nLDS;
                    stack_write_count <= stack_write_count + 1;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable v_pass : boolean;
        variable v_sr : std_logic_vector(15 downto 0);
        variable v_pc_hi : std_logic_vector(15 downto 0);
        variable v_pc_lo : std_logic_vector(15 downto 0);
        variable v_format_word : std_logic_vector(15 downto 0);
        variable v_instr_addr_hi : std_logic_vector(15 downto 0);
        variable v_instr_addr_lo : std_logic_vector(15 downto 0);
        variable v_stacked_pc : std_logic_vector(31 downto 0);
        variable v_stacked_sr : std_logic_vector(15 downto 0);
        variable v_format : std_logic_vector(3 downto 0);
        variable v_vector : std_logic_vector(11 downto 0);
        variable v_sp_final : unsigned(31 downto 0);
        variable v_sp_initial : unsigned(31 downto 0);
        variable v_frame_size : integer;

        -- Wait for CPU to reach a STOP instruction or timeout
        -- STOP puts the CPU in busstate="01" (no bus access) indefinitely.
        -- Detect by waiting for sustained bus inactivity (10+ consecutive cycles).
        -- Brief busstate="01" gaps occur between instructions so we need multiple cycles.
        procedure wait_for_stop(timeout_cycles : integer := 5000) is
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

        -- Wait for handler entry (vector table read)
        procedure wait_for_handler(
            expected_vector_offset : std_logic_vector(11 downto 0);
            timeout_cycles : integer := 3000
        ) is
            variable handler_addr : std_logic_vector(31 downto 0);
            variable vec_addr : unsigned(31 downto 0);
        begin
            vec_addr := resize(unsigned(expected_vector_offset), 32);
            for i in 0 to timeout_cycles loop
                wait until rising_edge(clk);
                -- Look for fetch from vector table (read cycle, address matches vector)
                if busstate = "10" and
                   unsigned(addr_out) >= vec_addr and
                   unsigned(addr_out) <= vec_addr + 2 then
                    -- Found vector read
                    return;
                end if;
            end loop;
            report "TIMEOUT waiting for vector " &
                   integer'image(to_integer(unsigned(expected_vector_offset)))
                   severity warning;
        end procedure;

        -- Read stacked frame from memory after exception
        -- sp_addr: final SP value (start of frame)
        procedure read_frame(
            sp_addr : unsigned(31 downto 0);
            format_expected : std_logic_vector(3 downto 0)
        ) is
            variable idx : integer;
        begin
            idx := to_integer(sp_addr(15 downto 1));
            v_stacked_sr := mem(idx);
            v_pc_hi := mem(idx + 1);
            v_pc_lo := mem(idx + 2);
            v_format_word := mem(idx + 3);
            v_stacked_pc := v_pc_hi & v_pc_lo;
            v_format := v_format_word(15 downto 12);
            v_vector := v_format_word(11 downto 0);

            if format_expected = "0010" then
                -- Format $2: also read instruction address
                v_instr_addr_hi := mem(idx + 4);
                v_instr_addr_lo := mem(idx + 5);
            end if;
        end procedure;

        -- Check frame format code
        procedure check_format(
            test_name : string;
            expected_format : std_logic_vector(3 downto 0)
        ) is
        begin
            if v_format = expected_format then
                report "  PASS: " & test_name & " format=$" &
                       integer'image(to_integer(unsigned(expected_format))) severity note;
                test_passed <= test_passed + 1;
            else
                report "  FAIL: " & test_name & " format: expected=$" &
                       integer'image(to_integer(unsigned(expected_format))) &
                       " got=$" & integer'image(to_integer(unsigned(v_format))) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Check vector offset
        procedure check_vector(
            test_name : string;
            expected_vector : std_logic_vector(11 downto 0)
        ) is
        begin
            if v_vector = expected_vector then
                report "  PASS: " & test_name & " vector=$" &
                       integer'image(to_integer(unsigned(expected_vector))) severity note;
                test_passed <= test_passed + 1;
            else
                report "  FAIL: " & test_name & " vector: expected=$" &
                       integer'image(to_integer(unsigned(expected_vector))) &
                       " got=$" & integer'image(to_integer(unsigned(v_vector))) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Check stacked PC
        procedure check_pc(
            test_name : string;
            expected_pc : std_logic_vector(31 downto 0)
        ) is
        begin
            if v_stacked_pc = expected_pc then
                report "  PASS: " & test_name & " PC=$" &
                       integer'image(to_integer(unsigned(expected_pc))) severity note;
                test_passed <= test_passed + 1;
            else
                report "  FAIL: " & test_name & " PC: expected=$" &
                       integer'image(to_integer(unsigned(expected_pc))) &
                       " got=$" & integer'image(to_integer(unsigned(v_stacked_pc))) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Check stacked SR supervisor bit
        procedure check_sr_supervisor(
            test_name : string;
            expected_s : std_logic
        ) is
        begin
            if v_stacked_sr(13) = expected_s then
                report "  PASS: " & test_name & " SR.S=" & std_logic'image(expected_s) severity note;
                test_passed <= test_passed + 1;
            else
                report "  FAIL: " & test_name & " SR.S: expected=" &
                       std_logic'image(expected_s) & " got=" &
                       std_logic'image(v_stacked_sr(13)) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Check frame size via SP displacement
        procedure check_frame_size(
            test_name : string;
            sp_before : unsigned(31 downto 0);
            sp_after  : unsigned(31 downto 0);
            expected_size : integer
        ) is
            variable actual_size : integer;
        begin
            actual_size := to_integer(sp_before) - to_integer(sp_after);
            if actual_size = expected_size then
                report "  PASS: " & test_name & " frame_size=" &
                       integer'image(expected_size) severity note;
                test_passed <= test_passed + 1;
            else
                report "  FAIL: " & test_name & " frame_size: expected=" &
                       integer'image(expected_size) & " got=" &
                       integer'image(actual_size) severity error;
                test_failed <= test_failed + 1;
            end if;
        end procedure;

        -- Common initialization
        procedure init_memory is
        begin
            for i in 0 to 32767 loop
                mem(i) := x"4E71";  -- NOP fill
            end loop;
            -- Reset vectors: SSP=$4000, PC=$1000
            mem(0) := x"0000";  -- SSP high
            mem(1) := x"4000";  -- SSP low
            mem(2) := x"0000";  -- PC high
            mem(3) := x"1000";  -- PC low
        end procedure;

        -- Set up an exception handler at the given vector to simply STOP
        -- handler_addr: where the handler code lives
        procedure setup_handler(
            vector_offset : integer;  -- byte offset in vector table (e.g. $80 for TRAP #0)
            handler_addr : integer    -- where handler code lives
        ) is
        begin
            -- Vector table entry (2 words = 32-bit pointer)
            mem(vector_offset / 2) := std_logic_vector(to_unsigned(handler_addr / 65536, 16));
            mem(vector_offset / 2 + 1) := std_logic_vector(to_unsigned(handler_addr mod 65536, 16));
            -- Handler: Read SP into A6 for frame analysis, then STOP
            -- MOVEA.L A7,A6  (2C4F)
            mem(handler_addr / 2) := x"2C4F";
            -- STOP #$2700
            mem(handler_addr / 2 + 1) := x"4E72";
            mem(handler_addr / 2 + 2) := x"2700";
        end procedure;

        -- Reset and run until initial PC
        procedure do_reset is
        begin
            nReset <= '0';
            IPL_sig <= "111";  -- No interrupt
            wait for 100 ns;
            nReset <= '1';
            -- Wait for CPU to start fetching from $1000
            for i in 0 to 2000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1000" then
                    exit;
                end if;
            end loop;
        end procedure;

    begin
        report "========================================" severity note;
        report "Stack Frame Push Validation Test" severity note;
        report "MC68030 Table 8-6 Compliance" severity note;
        report "========================================" severity note;

        -- ================================================================
        -- TEST 1: TRAP #0 - Format $0, Vector 32 ($80)
        -- Stacked PC = address of next instruction after TRAP
        -- ================================================================
        report "" severity note;
        report "TEST 1: TRAP #0 (Format $0, Vector $80)" severity note;

        init_memory;
        -- Handler for TRAP #0 (vector 32, offset $80) at $2000
        setup_handler(16#80#, 16#2000#);

        -- Test code at $1000:
        -- $1000: NOP           (4E71)  -- let CPU settle
        -- $1002: NOP           (4E71)
        -- $1004: TRAP #0       (4E40)  -- 1 word instruction
        -- $1006: NOP           (4E71)  -- next instruction (stacked PC should point here)
        mem(16#1000# / 2) := x"4E71";  -- NOP
        mem(16#1002# / 2) := x"4E71";  -- NOP
        mem(16#1004# / 2) := x"4E40";  -- TRAP #0
        mem(16#1006# / 2) := x"4E71";  -- NOP (next instruction)

        -- Pre-fill stack area with known pattern to detect writes
        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- Stack was at $4000, Format $0 frame = 8 bytes, so SP should be $3FF8
        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("TRAP#0", "0000");
        check_vector("TRAP#0", x"080");  -- Vector offset $80
        check_pc("TRAP#0 PC=next_instr", x"00001006");
        check_sr_supervisor("TRAP#0 was in SV mode", '1');

        -- ================================================================
        -- TEST 2: TRAP #15 - Format $0, Vector 47 ($BC)
        -- ================================================================
        report "" severity note;
        report "TEST 2: TRAP #15 (Format $0, Vector $BC)" severity note;

        init_memory;
        setup_handler(16#BC#, 16#2000#);

        mem(16#1000# / 2) := x"4E71";  -- NOP
        mem(16#1002# / 2) := x"4E71";  -- NOP
        mem(16#1004# / 2) := x"4E4F";  -- TRAP #15
        mem(16#1006# / 2) := x"4E71";  -- NOP (next instruction)

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("TRAP#15", "0000");
        check_vector("TRAP#15", x"0BC");  -- Vector offset $BC
        check_pc("TRAP#15 PC=next_instr", x"00001006");

        -- ================================================================
        -- TEST 3: Illegal instruction - Format $0, Vector 4 ($10)
        -- Stacked PC = address of the illegal instruction
        -- ================================================================
        report "" severity note;
        report "TEST 3: Illegal Instruction (Format $0, Vector $10)" severity note;

        init_memory;
        setup_handler(16#10#, 16#2000#);

        -- $1000: NOP
        -- $1002: NOP
        -- $1004: $4AFC (guaranteed illegal on 68030)
        -- $1006: NOP
        mem(16#1000# / 2) := x"4E71";
        mem(16#1002# / 2) := x"4E71";
        mem(16#1004# / 2) := x"4AFC";  -- ILLEGAL instruction
        mem(16#1006# / 2) := x"4E71";

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("Illegal", "0000");
        check_vector("Illegal", x"010");  -- Vector offset $10
        -- PC should point to the illegal instruction itself
        check_pc("Illegal PC=faulting_instr", x"00001004");

        -- ================================================================
        -- TEST 4: A-line (unimplemented) - Format $0, Vector 10 ($28)
        -- Stacked PC = address of the A-line instruction
        -- ================================================================
        report "" severity note;
        report "TEST 4: A-line (Format $0, Vector $28)" severity note;

        init_memory;
        setup_handler(16#28#, 16#2000#);

        mem(16#1000# / 2) := x"4E71";
        mem(16#1002# / 2) := x"4E71";
        mem(16#1004# / 2) := x"A000";  -- A-line opcode
        mem(16#1006# / 2) := x"4E71";

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("A-line", "0000");
        check_vector("A-line", x"028");
        check_pc("A-line PC=faulting_instr", x"00001004");

        -- ================================================================
        -- TEST 5: Privilege Violation - Format $0, Vector 8 ($20)
        -- Execute a supervisor instruction from user mode
        -- Stacked PC = address of the privilege-violating instruction
        -- ================================================================
        report "" severity note;
        report "TEST 5: Privilege Violation (Format $0, Vector $20)" severity note;

        init_memory;
        setup_handler(16#20#, 16#2000#);

        -- Need to get to user mode first, then execute a privileged instruction.
        -- Use MOVE to SR to clear S bit (go to user mode), then STOP (privileged)
        -- But MOVE to SR itself is privileged... we need to use RTE to get to user mode.

        -- Approach: Set up an RTE frame that drops to user mode, then execute RESET (privileged)
        -- Build Format $0 frame at $3FF8 pointing to $1100 in user mode
        -- $1000: MOVEA.L #$3FF8,A7   (set SP to frame)
        -- $1006: RTE                   (return to user mode at $1100)
        -- $1100: RESET                 (privileged - will cause priv violation)
        mem(16#1000# / 2) := x"2E7C";  -- MOVEA.L #imm,A7
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3FF8";
        mem(16#1006# / 2) := x"4E73";  -- RTE

        -- RTE frame at $3FF8: SR=$0000 (user mode), PC=$00001100, Format $0
        mem(16#3FF8# / 2) := x"0000";      -- SR: user mode
        mem(16#3FFA# / 2) := x"0000";      -- PC high
        mem(16#3FFC# / 2) := x"1100";      -- PC low
        mem(16#3FFE# / 2) := x"0000";      -- Format $0, vector 0

        -- User mode code at $1100
        mem(16#1100# / 2) := x"4E70";  -- RESET (privileged instruction)
        mem(16#1102# / 2) := x"4E71";

        -- Need to set USP too - handler will be at $2000
        -- Pre-fill stack area
        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;
        -- Restore the RTE frame we just filled over
        mem(16#3FF8# / 2) := x"0000";
        mem(16#3FFA# / 2) := x"0000";
        mem(16#3FFC# / 2) := x"1100";
        mem(16#3FFE# / 2) := x"0000";

        do_reset;
        wait_for_stop;

        -- Priv violation pushes Format $0 on supervisor stack
        -- Initial SSP was $4000 (but was modified to $3FF8 by MOVEA, then RTE consumed 8 bytes -> $4000 again)
        -- Exception pushes 8 bytes: SP = $4000 - 8 = $3FF8
        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("PrivViolation", "0000");
        check_vector("PrivViolation", x"020");
        -- PC should point to the RESET instruction that caused the violation
        check_pc("PrivViolation PC=faulting_instr", x"00001100");
        -- SR should show user mode (S=0) since that's what was active when violation occurred
        check_sr_supervisor("PrivViolation was in user mode", '0');

        -- ================================================================
        -- TEST 6: TRAPV (overflow set) - Format $2, Vector 7 ($1C)
        -- Need to set V flag first, then TRAPV
        -- Stacked PC = next instruction; Instruction Address = TRAPV address
        -- ================================================================
        report "" severity note;
        report "TEST 6: TRAPV with V=1 (Format $2, Vector $1C)" severity note;

        init_memory;
        setup_handler(16#1C#, 16#2000#);

        -- Set the V flag by doing an arithmetic overflow, then TRAPV
        -- MOVE.B #$7F,D0   (103C 007F)  -- load max positive byte
        -- ADD.B #$01,D0    (0600 0001)  -- overflow: $7F + $01 = $80, V=1
        -- TRAPV            (4E76)        -- should trap since V=1
        -- NOP              (4E71)        -- next instruction
        mem(16#1000# / 2) := x"103C";  -- MOVE.B #imm,D0
        mem(16#1002# / 2) := x"007F";  -- $7F
        mem(16#1004# / 2) := x"0600";  -- ADD.B #imm,D0
        mem(16#1006# / 2) := x"0001";  -- $01
        mem(16#1008# / 2) := x"4E76";  -- TRAPV
        mem(16#100A# / 2) := x"4E71";  -- NOP (next instruction)

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- Format $2 frame = 12 bytes. SP = $4000 - 12 = $3FF4
        v_sp_final := x"00003FF4";
        read_frame(v_sp_final, "0010");
        check_format("TRAPV", "0010");
        check_vector("TRAPV", x"01C");
        -- Per Table 8-6: PC = next instruction for TRAPV
        check_pc("TRAPV PC=next_instr", x"0000100A");
        -- Instruction address = the TRAPV instruction itself
        -- Read instruction address from SP+8 (Format $2 extra field)
        report "  INFO: Instruction Address = $" &
               integer'image(to_integer(unsigned(v_instr_addr_hi)) * 65536 + to_integer(unsigned(v_instr_addr_lo))) severity note;

        -- ================================================================
        -- TEST 7: CHK.W - Format $2, Vector 6 ($18)
        -- CHK Dn,<ea>: if Dn < 0 or Dn > ea, take exception
        -- ================================================================
        report "" severity note;
        report "TEST 7: CHK.W (Format $2, Vector $18)" severity note;

        init_memory;
        setup_handler(16#18#, 16#2000#);

        -- MOVE.W #-1,D0    (303C FFFF)  -- D0 = -1 (will fail CHK)
        -- MOVE.W #10,D1    (323C 000A)  -- D1 = 10 (upper bound)
        -- CHK.W D1,D0      (4081)       -- Check D0 against D1: D0 < 0, trap!
        -- NOP                            -- next instruction
        mem(16#1000# / 2) := x"303C";
        mem(16#1002# / 2) := x"FFFF";  -- D0 = -1
        mem(16#1004# / 2) := x"323C";
        mem(16#1006# / 2) := x"000A";  -- D1 = 10
        mem(16#1008# / 2) := x"4181";  -- CHK.W D1,D0
        mem(16#100A# / 2) := x"4E71";  -- NOP

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- Format $2 = 12 bytes
        v_sp_final := x"00003FF4";
        read_frame(v_sp_final, "0010");
        check_format("CHK.W", "0010");
        check_vector("CHK.W", x"018");
        -- PC = next instruction
        check_pc("CHK.W PC=next_instr", x"0000100A");

        -- ================================================================
        -- TEST 8: Zero Divide - Format $2, Vector 5 ($14)
        -- DIVU #0,Dn triggers divide by zero
        -- ================================================================
        report "" severity note;
        report "TEST 8: Zero Divide (Format $2, Vector $14)" severity note;

        init_memory;
        setup_handler(16#14#, 16#2000#);

        -- MOVE.L #100,D0   (203C 00000064)  -- D0 = 100
        -- DIVU #0,D0       (80FC 0000)      -- Divide by zero!
        -- NOP
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"0064";  -- D0 = 100
        mem(16#1006# / 2) := x"80FC";  -- DIVU #imm,D0
        mem(16#1008# / 2) := x"0000";  -- immediate = 0
        mem(16#100A# / 2) := x"4E71";  -- NOP

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF4";
        read_frame(v_sp_final, "0010");
        check_format("DivZero", "0010");
        check_vector("DivZero", x"014");
        -- PC = next instruction (after DIVU #0,D0 which is 4 bytes: $1006+4=$100A)
        check_pc("DivZero PC=next_instr", x"0000100A");

        -- ================================================================
        -- TEST 9: Trace (T1 mode) - Format $2, Vector 9 ($24)
        -- Execute one instruction with T1 set, verify trace frame
        -- ================================================================
        report "" severity note;
        report "TEST 9: Trace T1 (Format $2, Vector $24)" severity note;

        init_memory;
        setup_handler(16#24#, 16#2000#);

        -- Use MOVE to SR to enable T1 trace, then the NEXT instruction gets traced
        -- MOVE.W #$A700,SR  (46FC A700)  -- S=1, T1=1, T0=0, IPL mask=7
        -- NOP                (4E71)       -- This instruction will be traced
        -- NOP                (4E71)       -- next instruction (stacked PC should point here)
        mem(16#1000# / 2) := x"46FC";  -- MOVE #imm,SR
        mem(16#1002# / 2) := x"A700";  -- SR value: T1=1, S=1, IPL=7
        mem(16#1004# / 2) := x"4E71";  -- NOP (will be traced)
        mem(16#1006# / 2) := x"4E71";  -- NOP (stacked PC target)

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        -- Trace frame: Format $2, 12 bytes
        v_sp_final := x"00003FF4";
        read_frame(v_sp_final, "0010");
        check_format("Trace", "0010");
        check_vector("Trace", x"024");
        -- PC = next instruction (instruction AFTER the traced one)
        check_pc("Trace PC=next_instr", x"00001006");

        -- ================================================================
        -- TEST 10: F-line (PMMU opcode in user mode) - Format $0, Vector 11 ($2C)
        -- ================================================================
        report "" severity note;
        report "TEST 10: F-line (Format $0, Vector $2C)" severity note;

        init_memory;
        setup_handler(16#2C#, 16#2000#);

        -- F-line opcodes ($Fxxx) with bits [11:9] != 0 are F-line traps on 68030
        -- Use $F800 which doesn't match any coprocessor
        mem(16#1000# / 2) := x"4E71";
        mem(16#1002# / 2) := x"4E71";
        mem(16#1004# / 2) := x"F800";  -- F-line opcode (not valid PMMU/FPU)
        mem(16#1006# / 2) := x"4E71";

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("F-line", "0000");
        check_vector("F-line", x"02C");
        -- PC should point to the F-line instruction
        check_pc("F-line PC=faulting_instr", x"00001004");

        -- ================================================================
        -- TEST 11: MMU Configuration Exception - Format $0, Vector 56 ($E0)
        -- WinUAE's common 68020+ frame selection leaves vector 56 in Format $0.
        -- ================================================================
        report "" severity note;
        report "TEST 11: MMU Configuration (Format $0, Vector $E0)" severity note;

        init_memory;
        setup_handler(16#E0#, 16#2000#);

        -- PMOVE.L (A0),TC with TC.E=1 and PS=0 (reserved) raises vector 56.
        mem(16#1000# / 2) := x"41F9";  -- LEA $3000,A0
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"3000";
        mem(16#1006# / 2) := x"F010";  -- PMOVE.L (A0),TC
        mem(16#1008# / 2) := x"4000";
        mem(16#100A# / 2) := x"4E71";
        mem(16#3000# / 2) := x"8000";  -- Invalid TC: E=1, PS=0
        mem(16#3002# / 2) := x"0000";

        for i in 16#3F00#/2 to 16#4000#/2 - 1 loop
            mem(i) := x"DEAD";
        end loop;

        do_reset;
        wait_for_stop;

        v_sp_final := x"00003FF8";
        read_frame(v_sp_final, "0000");
        check_format("MMU Configuration", "0000");
        check_vector("MMU Configuration", x"0E0");

        -- ================================================================
        -- SUMMARY
        -- ================================================================
        wait for 0 ns;
        report "" severity note;
        report "========================================" severity note;
        report "RESULTS: " & integer'image(test_passed) & " passed, " &
               integer'image(test_failed) & " failed" severity note;
        report "========================================" severity note;

        if test_failed > 0 then
            report "SOME TESTS FAILED" severity error;
        else
            report "ALL TESTS PASSED" severity note;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
