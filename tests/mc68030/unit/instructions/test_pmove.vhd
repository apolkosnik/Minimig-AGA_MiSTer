------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PMOVE Instruction Unit Test                                     --
--                                                                          --
-- Tests PMOVE instruction for accessing MMU control registers             --
--                                                                          --
-- Coverage:                                                                --
--   - PMOVE decode (F-line opcode detection)                              --
--   - All MMU register codes (TC, TT0, TT1, CRP, SRP, MMUSR)             --
--   - Read and write directions                                           --
--   - PMOVEFD (flush disable) variant                                     --
--   - Data size handling (word/long/quad)                                 --
--   - Privilege checking (supervisor only)                                --
--   - Illegal instruction detection                                       --
--   - ATC flush behavior                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_pmove_tb is
end entity test_pmove_tb;

architecture behavior of test_pmove_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_PMOVE is
        port(
            clk             : in  std_logic;
            reset           : in  std_logic;
            opcode          : in  std_logic_vector(15 downto 0);
            extension       : in  std_logic_vector(15 downto 0);
            opcode_valid    : in  std_logic;
            supervisor      : in  std_logic;
            execute_start   : in  std_logic;
            execute_done    : out std_logic;
            execute_busy    : out std_logic;
            ea_addr         : in  std_logic_vector(31 downto 0);
            ea_mode         : out std_logic_vector(2 downto 0);
            ea_reg          : out std_logic_vector(2 downto 0);
            mem_data_in     : in  std_logic_vector(63 downto 0);
            mem_data_out    : out std_logic_vector(63 downto 0);
            mem_read        : out std_logic;
            mem_write       : out std_logic;
            mem_size        : out std_logic_vector(1 downto 0);
            mem_ready       : in  std_logic;
            mmu_data_in     : in  std_logic_vector(63 downto 0);
            mmu_data_out    : out std_logic_vector(63 downto 0);
            mmu_reg_addr    : out std_logic_vector(3 downto 0);
            mmu_read        : out std_logic;
            mmu_write       : out std_logic;
            mmu_size        : out std_logic_vector(1 downto 0);
            atc_flush       : out std_logic;
            atc_flush_all   : out std_logic;
            is_pmove        : out std_logic;
            illegal_instr   : out std_logic;
            priv_violation  : out std_logic
        );
    end component;

    -- Signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal opcode         : std_logic_vector(15 downto 0) := (others => '0');
    signal extension      : std_logic_vector(15 downto 0) := (others => '0');
    signal opcode_valid   : std_logic := '0';
    signal supervisor     : std_logic := '1';
    signal execute_start  : std_logic := '0';
    signal execute_done   : std_logic;
    signal execute_busy   : std_logic;
    signal ea_addr        : std_logic_vector(31 downto 0) := (others => '0');
    signal ea_mode        : std_logic_vector(2 downto 0);
    signal ea_reg         : std_logic_vector(2 downto 0);
    signal mem_data_in    : std_logic_vector(63 downto 0) := (others => '0');
    signal mem_data_out   : std_logic_vector(63 downto 0);
    signal mem_read       : std_logic;
    signal mem_write      : std_logic;
    signal mem_size       : std_logic_vector(1 downto 0);
    signal mem_ready      : std_logic := '0';
    signal mmu_data_in    : std_logic_vector(63 downto 0) := (others => '0');
    signal mmu_data_out   : std_logic_vector(63 downto 0);
    signal mmu_reg_addr   : std_logic_vector(3 downto 0);
    signal mmu_read       : std_logic;
    signal mmu_write      : std_logic;
    signal mmu_size       : std_logic_vector(1 downto 0);
    signal atc_flush      : std_logic;
    signal atc_flush_all  : std_logic;
    signal is_pmove       : std_logic;
    signal illegal_instr  : std_logic;
    signal priv_violation : std_logic;

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- PMOVE instruction format
    constant PMOVE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";
    constant MMU_CP_ID    : std_logic_vector(2 downto 0) := "010";

    -- MMU register codes
    constant REG_TC    : std_logic_vector(7 downto 0) := X"00";
    constant REG_SRP   : std_logic_vector(7 downto 0) := X"02";
    constant REG_CRP   : std_logic_vector(7 downto 0) := X"03";
    constant REG_TT0   : std_logic_vector(7 downto 0) := X"10";
    constant REG_TT1   : std_logic_vector(7 downto 0) := X"11";
    constant REG_MMUSR : std_logic_vector(7 downto 0) := X"18";

    -- Direction bits
    constant DIR_WRITE_MMU : std_logic := '0';  -- Write to MMU register
    constant DIR_READ_MMU  : std_logic := '1';  -- Read from MMU register

    -- Size codes
    constant SIZE_WORD : std_logic_vector(1 downto 0) := "01";
    constant SIZE_LONG : std_logic_vector(1 downto 0) := "10";
    constant SIZE_QUAD : std_logic_vector(1 downto 0) := "11";

begin

    --------------------------------------------------------------
    -- Clock generation
    --------------------------------------------------------------
    clk_process: process
    begin
        while not test_complete loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    --------------------------------------------------------------
    -- DUT instantiation
    --------------------------------------------------------------
    dut: TG68K030_PMOVE
        port map(
            clk             => clk,
            reset           => reset,
            opcode          => opcode,
            extension       => extension,
            opcode_valid    => opcode_valid,
            supervisor      => supervisor,
            execute_start   => execute_start,
            execute_done    => execute_done,
            execute_busy    => execute_busy,
            ea_addr         => ea_addr,
            ea_mode         => ea_mode,
            ea_reg          => ea_reg,
            mem_data_in     => mem_data_in,
            mem_data_out    => mem_data_out,
            mem_read        => mem_read,
            mem_write       => mem_write,
            mem_size        => mem_size,
            mem_ready       => mem_ready,
            mmu_data_in     => mmu_data_in,
            mmu_data_out    => mmu_data_out,
            mmu_reg_addr    => mmu_reg_addr,
            mmu_read        => mmu_read,
            mmu_write       => mmu_write,
            mmu_size        => mmu_size,
            atc_flush       => atc_flush,
            atc_flush_all   => atc_flush_all,
            is_pmove        => is_pmove,
            illegal_instr   => illegal_instr,
            priv_violation  => priv_violation
        );

    --------------------------------------------------------------
    -- Test stimulus
    --------------------------------------------------------------
    stim_proc: process

        procedure report_test(test_name : string; passed : boolean) is
        begin
            if passed then
                report "PASS: " & test_name severity note;
            else
                report "FAIL: " & test_name severity error;
                test_passed <= false;
            end if;
        end procedure;

        procedure build_pmove(
            ea_mode_in  : std_logic_vector(2 downto 0);
            ea_reg_in   : std_logic_vector(2 downto 0);
            reg_code    : std_logic_vector(7 downto 0);
            direction   : std_logic;
            fd_flag     : std_logic
        ) is
        begin
            -- Build opcode word: 1111000000 + EA mode + EA reg
            opcode <= PMOVE_PREFIX & ea_mode_in & ea_reg_in;

            -- Build extension word: 010 + FD + 0000 + direction + reg_code
            extension <= MMU_CP_ID & fd_flag & "0000" & direction & reg_code;

            opcode_valid <= '1';
        end procedure;

        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait for CLK_PERIOD;
            end loop;
        end procedure;

    begin
        --------------------------------------------------------------
        -- Test 0: Reset
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 0: Reset" severity note;
        report "==================================" severity note;

        supervisor <= '1';
        reset <= '1';
        wait_cycles(5);
        reset <= '0';
        wait_cycles(2);

        report_test("Not busy after reset", execute_busy = '0');
        report_test("No PMOVE detected", is_pmove = '0');

        --------------------------------------------------------------
        -- Test 1: PMOVE TC Decode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: PMOVE TC decode" severity note;
        report "==================================" severity note;

        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(2);

        report_test("PMOVE detected", is_pmove = '1');
        report_test("Not illegal", illegal_instr = '0');
        report_test("No privilege violation", priv_violation = '0');
        report_test("TC register selected", mmu_reg_addr = X"0");

        opcode_valid <= '0';
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 2: All MMU Register Codes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: All MMU register codes" severity note;
        report "==================================" severity note;

        -- TC (0x00)
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("TC decode", is_pmove = '1' and mmu_reg_addr = X"0");
        opcode_valid <= '0';
        wait_cycles(1);

        -- SRP (0x02)
        build_pmove("010", "000", REG_SRP, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("SRP decode", is_pmove = '1' and mmu_reg_addr = X"5");
        opcode_valid <= '0';
        wait_cycles(1);

        -- CRP (0x03)
        build_pmove("010", "000", REG_CRP, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("CRP decode", is_pmove = '1' and mmu_reg_addr = X"4");
        opcode_valid <= '0';
        wait_cycles(1);

        -- TT0 (0x10)
        build_pmove("010", "000", REG_TT0, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("TT0 decode", is_pmove = '1' and mmu_reg_addr = X"2");
        opcode_valid <= '0';
        wait_cycles(1);

        -- TT1 (0x11)
        build_pmove("010", "000", REG_TT1, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("TT1 decode", is_pmove = '1' and mmu_reg_addr = X"3");
        opcode_valid <= '0';
        wait_cycles(1);

        -- MMUSR (0x18)
        build_pmove("010", "000", REG_MMUSR, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("MMUSR decode", is_pmove = '1' and mmu_reg_addr = X"6");
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 3: Data Sizes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: Data sizes" severity note;
        report "==================================" severity note;

        -- MMUSR is word (16-bit)
        build_pmove("010", "000", REG_MMUSR, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("MMUSR word size", mem_size = SIZE_WORD);
        opcode_valid <= '0';
        wait_cycles(1);

        -- TC is long (32-bit)
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("TC long size", mem_size = SIZE_LONG);
        opcode_valid <= '0';
        wait_cycles(1);

        -- CRP is quad (64-bit)
        build_pmove("010", "000", REG_CRP, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("CRP quad size", mem_size = SIZE_QUAD);
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 4: Read vs Write Direction
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: Direction (read/write)" severity note;
        report "==================================" severity note;

        -- Write to MMU (direction=0)
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("Write to MMU", is_pmove = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Read from MMU (direction=1)
        build_pmove("010", "000", REG_TC, DIR_READ_MMU, '0');
        wait_cycles(1);
        report_test("Read from MMU", is_pmove = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 5: PMOVEFD (Flush Disable)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: PMOVEFD (flush disable)" severity note;
        report "==================================" severity note;

        -- PMOVE with FD=0 (normal, flush enabled)
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("PMOVE FD=0", is_pmove = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- PMOVEFD with FD=1 (flush disabled)
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '1');
        wait_cycles(1);
        report_test("PMOVEFD FD=1", is_pmove = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 6: Privilege Violations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: Privilege violations" severity note;
        report "==================================" severity note;

        -- Supervisor mode - should work
        supervisor <= '1';
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("Supervisor allowed", priv_violation = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- User mode - should fail
        supervisor <= '0';
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("User mode blocked", priv_violation = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Return to supervisor
        supervisor <= '1';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 7: Illegal Instructions
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: Illegal instructions" severity note;
        report "==================================" severity note;

        -- Valid PMOVE
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("Valid PMOVE", illegal_instr = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Invalid register code
        build_pmove("010", "000", X"FF", DIR_WRITE_MMU, '0');
        wait_cycles(1);
        report_test("Invalid reg code illegal", illegal_instr = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Not F-line (should not be PMOVE)
        opcode <= X"4E71";  -- NOP
        extension <= X"0000";
        opcode_valid <= '1';
        wait_cycles(1);
        report_test("Non-PMOVE ignored", is_pmove = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 8: Execution - Write to MMU
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Execute write to MMU" severity note;
        report "==================================" severity note;

        -- Setup PMOVE TC,(A0) - write to TC
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        ea_addr <= X"00001000";
        mem_data_in <= X"0000000080000000";  -- TC value
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Wait for memory read
        wait until mem_read = '1' or test_complete;
        wait_cycles(1);
        mem_ready <= '1';
        wait_cycles(1);
        mem_ready <= '0';

        -- Should write to MMU
        wait_cycles(2);
        report_test("MMU write occurred", mmu_write = '1');
        report_test("TC address selected", mmu_reg_addr = X"0");

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("Execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 9: Execution - Read from MMU
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: Execute read from MMU" severity note;
        report "==================================" severity note;

        -- Setup PMOVE (A0),TC - read from TC
        build_pmove("010", "000", REG_TC, DIR_READ_MMU, '0');
        ea_addr <= X"00002000";
        mmu_data_in <= X"0000000082000000";  -- TC value to read
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Should read from MMU
        wait_cycles(2);
        report_test("MMU read occurred", mmu_read = '1');

        -- Then write to memory
        wait until mem_write = '1' or test_complete;
        wait_cycles(1);
        mem_ready <= '1';
        wait_cycles(1);
        mem_ready <= '0';

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("Read execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 10: ATC Flush Behavior
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 10: ATC flush behavior" severity note;
        report "==================================" severity note;

        -- PMOVE to TC with FD=0 should flush ATC
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '0');
        ea_addr <= X"00003000";
        mem_data_in <= X"0000000084000000";
        wait_cycles(1);

        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Complete execution
        wait until mem_read = '1' or test_complete;
        mem_ready <= '1';
        wait_cycles(1);
        mem_ready <= '0';

        -- Should flush ATC
        wait until atc_flush = '1' or execute_done = '1' or test_complete;
        if atc_flush = '1' then
            report_test("ATC flushed", true);
        else
            report_test("ATC flushed", false);
        end if;

        wait until execute_done = '1' or test_complete;
        opcode_valid <= '0';
        wait_cycles(5);

        -- PMOVEFD to TC with FD=1 should NOT flush ATC
        build_pmove("010", "000", REG_TC, DIR_WRITE_MMU, '1');
        ea_addr <= X"00003000";
        mem_data_in <= X"0000000084000000";
        wait_cycles(1);

        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Complete execution
        wait until mem_read = '1' or test_complete;
        mem_ready <= '1';
        wait_cycles(1);
        mem_ready <= '0';

        wait until execute_done = '1' or test_complete;
        report_test("ATC not flushed with FD", atc_flush = '0');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Final report
        --------------------------------------------------------------
        wait_cycles(10);

        report "==================================" severity note;
        if test_passed then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        report "==================================" severity note;

        report "PMOVE Test Summary:" severity note;
        report "  - F-line opcode detection" severity note;
        report "  - All 6 MMU register codes" severity note;
        report "  - Read/write directions" severity note;
        report "  - Data sizes (word/long/quad)" severity note;
        report "  - PMOVEFD flush disable" severity note;
        report "  - Privilege checking" severity note;
        report "  - Illegal instruction detection" severity note;
        report "  - Execution with memory interface" severity note;
        report "  - ATC flush behavior" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
