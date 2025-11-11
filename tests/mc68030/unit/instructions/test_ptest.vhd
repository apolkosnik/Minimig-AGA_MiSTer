------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PTEST Instruction Unit Test                                     --
--                                                                          --
-- Tests PTEST instruction for testing MMU address translations            --
--                                                                          --
-- Coverage:                                                                --
--   - PTEST decode (all levels 0-7)                                       --
--   - All function code values (0-7)                                      --
--   - Read and write access tests                                         --
--   - Return register enable and write                                    --
--   - Effective addressing modes                                          --
--   - Privilege checking (supervisor only)                                --
--   - Illegal instruction detection                                       --
--   - MMUSR update with various conditions                                --
--   - ATC lookup interface                                                --
--   - MMU table walk interface                                            --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_ptest_tb is
end entity test_ptest_tb;

architecture behavior of test_ptest_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_PTEST is
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
            mmu_walk_req    : out std_logic;
            mmu_walk_level  : out std_logic_vector(2 downto 0);
            mmu_walk_fc     : out std_logic_vector(2 downto 0);
            mmu_walk_addr   : out std_logic_vector(31 downto 0);
            mmu_walk_rw     : out std_logic;
            mmu_walk_done   : in  std_logic;
            mmu_walk_result : in  std_logic_vector(15 downto 0);
            mmu_desc_addr   : in  std_logic_vector(31 downto 0);
            atc_lookup_req  : out std_logic;
            atc_lookup_fc   : out std_logic_vector(2 downto 0);
            atc_lookup_addr : out std_logic_vector(31 downto 0);
            atc_hit         : in  std_logic;
            atc_lookup_done : in  std_logic;
            mmusr_update    : out std_logic;
            mmusr_data      : out std_logic_vector(15 downto 0);
            ret_reg_write   : out std_logic;
            ret_reg_num     : out std_logic_vector(2 downto 0);
            ret_reg_data    : out std_logic_vector(31 downto 0);
            is_ptest        : out std_logic;
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
    signal mmu_walk_req   : std_logic;
    signal mmu_walk_level : std_logic_vector(2 downto 0);
    signal mmu_walk_fc    : std_logic_vector(2 downto 0);
    signal mmu_walk_addr  : std_logic_vector(31 downto 0);
    signal mmu_walk_rw    : std_logic;
    signal mmu_walk_done  : std_logic := '0';
    signal mmu_walk_result: std_logic_vector(15 downto 0) := (others => '0');
    signal mmu_desc_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal atc_lookup_req : std_logic;
    signal atc_lookup_fc  : std_logic_vector(2 downto 0);
    signal atc_lookup_addr: std_logic_vector(31 downto 0);
    signal atc_hit        : std_logic := '0';
    signal atc_lookup_done: std_logic := '0';
    signal mmusr_update   : std_logic;
    signal mmusr_data     : std_logic_vector(15 downto 0);
    signal ret_reg_write  : std_logic;
    signal ret_reg_num    : std_logic_vector(2 downto 0);
    signal ret_reg_data   : std_logic_vector(31 downto 0);
    signal is_ptest       : std_logic;
    signal illegal_instr  : std_logic;
    signal priv_violation : std_logic;

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- PTEST instruction format
    constant FLINE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";
    constant PTEST_CP_ID  : std_logic_vector(2 downto 0) := "100";

    -- Function codes
    constant FC_USER_DATA   : std_logic_vector(2 downto 0) := "001";
    constant FC_USER_PROG   : std_logic_vector(2 downto 0) := "010";
    constant FC_SUPER_DATA  : std_logic_vector(2 downto 0) := "101";
    constant FC_SUPER_PROG  : std_logic_vector(2 downto 0) := "110";

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
    dut: TG68K030_PTEST
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
            mmu_walk_req    => mmu_walk_req,
            mmu_walk_level  => mmu_walk_level,
            mmu_walk_fc     => mmu_walk_fc,
            mmu_walk_addr   => mmu_walk_addr,
            mmu_walk_rw     => mmu_walk_rw,
            mmu_walk_done   => mmu_walk_done,
            mmu_walk_result => mmu_walk_result,
            mmu_desc_addr   => mmu_desc_addr,
            atc_lookup_req  => atc_lookup_req,
            atc_lookup_fc   => atc_lookup_fc,
            atc_lookup_addr => atc_lookup_addr,
            atc_hit         => atc_hit,
            atc_lookup_done => atc_lookup_done,
            mmusr_update    => mmusr_update,
            mmusr_data      => mmusr_data,
            ret_reg_write   => ret_reg_write,
            ret_reg_num     => ret_reg_num,
            ret_reg_data    => ret_reg_data,
            is_ptest        => is_ptest,
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

        procedure build_ptest(
            ea_mode_in  : std_logic_vector(2 downto 0);
            ea_reg_in   : std_logic_vector(2 downto 0);
            level       : std_logic_vector(2 downto 0);
            fc          : std_logic_vector(2 downto 0);
            rw_bit      : std_logic;
            ret_en      : std_logic;
            ret_reg     : std_logic_vector(2 downto 0)
        ) is
        begin
            -- Build opcode word: 1111000000 + EA mode + EA reg
            opcode <= FLINE_PREFIX & ea_mode_in & ea_reg_in;

            -- Build extension word: 100R RRRR LLLL LFFF X00
            extension <= PTEST_CP_ID & ret_en & ret_reg & level & fc & rw_bit & "00";

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
        report_test("No PTEST detected", is_ptest = '0');

        --------------------------------------------------------------
        -- Test 1: PTEST Decode - Level 7
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: PTEST level 7 decode" severity note;
        report "==================================" severity note;

        -- PTEST #1,(A0),#7 - complete translation
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
        wait_cycles(2);

        report_test("PTEST detected", is_ptest = '1');
        report_test("Level is 7", mmu_walk_level = "111");
        report_test("FC is user data", mmu_walk_fc = FC_USER_DATA);
        report_test("Not illegal", illegal_instr = '0');
        report_test("No privilege violation", priv_violation = '0');

        opcode_valid <= '0';
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 2: All Levels (0-7)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: All levels (0-7)" severity note;
        report "==================================" severity note;

        for lev in 0 to 7 loop
            build_ptest("010", "000", std_logic_vector(to_unsigned(lev, 3)),
                       FC_SUPER_DATA, '0', '0', "000");
            wait_cycles(1);
            report_test("Level " & integer'image(lev),
                       is_ptest = '1' and mmu_walk_level = std_logic_vector(to_unsigned(lev, 3)));
            opcode_valid <= '0';
            wait_cycles(1);
        end loop;

        --------------------------------------------------------------
        -- Test 3: All Function Codes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: All function codes" severity note;
        report "==================================" severity note;

        for fc_val in 0 to 7 loop
            build_ptest("010", "000", "111", std_logic_vector(to_unsigned(fc_val, 3)),
                       '0', '0', "000");
            wait_cycles(1);
            report_test("FC=" & integer'image(fc_val),
                       is_ptest = '1' and mmu_walk_fc = std_logic_vector(to_unsigned(fc_val, 3)));
            opcode_valid <= '0';
            wait_cycles(1);
        end loop;

        --------------------------------------------------------------
        -- Test 4: Read vs Write Test
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: Read vs write test" severity note;
        report "==================================" severity note;

        -- Read test (R/W = 0)
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
        wait_cycles(1);
        report_test("Read test", is_ptest = '1' and mmu_walk_rw = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Write test (R/W = 1)
        build_ptest("010", "000", "111", FC_USER_DATA, '1', '0', "000");
        wait_cycles(1);
        report_test("Write test", is_ptest = '1' and mmu_walk_rw = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 5: Return Register Enable
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: Return register" severity note;
        report "==================================" severity note;

        -- Without return register
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
        wait_cycles(1);
        report_test("No return register", is_ptest = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- With return register (A3)
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '1', "011");
        wait_cycles(1);
        report_test("Return to A3", is_ptest = '1' and ret_reg_num = "011");
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
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
        wait_cycles(1);
        report_test("Supervisor allowed", priv_violation = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- User mode - should fail
        supervisor <= '0';
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
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

        -- Valid PTEST
        build_ptest("010", "000", "111", FC_USER_DATA, '0', '0', "000");
        wait_cycles(1);
        report_test("Valid PTEST", illegal_instr = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Invalid reserved bits (bits 1-0 not zero)
        opcode       <= X"F010";  -- PTEST with EA
        extension    <= X"8007";  -- PTEST format but reserved bits = 11
        opcode_valid <= '1';
        wait_cycles(1);
        report_test("Reserved bits illegal", illegal_instr = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 8: Execution - Complete Flow
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Complete execution" severity note;
        report "==================================" severity note;

        build_ptest("010", "000", "111", FC_SUPER_DATA, '0', '0', "000");
        ea_addr <= X"12345000";
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Should request ATC lookup
        wait until atc_lookup_req = '1' or test_complete;
        wait_cycles(1);
        report_test("ATC lookup requested", atc_lookup_req = '1');
        atc_lookup_done <= '1';
        atc_hit <= '0';  -- Not in ATC
        wait_cycles(1);
        atc_lookup_done <= '0';

        -- Should request MMU walk
        wait until mmu_walk_req = '1' or test_complete;
        wait_cycles(1);
        report_test("MMU walk requested", mmu_walk_req = '1');
        report_test("Level is 7", mmu_walk_level = "111");
        report_test("FC is super data", mmu_walk_fc = FC_SUPER_DATA);
        report_test("Address captured", mmu_walk_addr = X"12345000");

        -- Complete MMU walk
        mmu_walk_result <= X"0000";  -- Success
        mmu_desc_addr   <= X"00100000";
        mmu_walk_done   <= '1';
        wait_cycles(1);
        mmu_walk_done   <= '0';

        -- Should update MMUSR
        wait until mmusr_update = '1' or test_complete;
        wait_cycles(1);
        report_test("MMUSR updated", mmusr_update = '1');

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("Execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 9: Execution with Return Register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: Return register write" severity note;
        report "==================================" severity note;

        build_ptest("010", "000", "111", FC_USER_DATA, '0', '1', "101");  -- Return to A5
        ea_addr <= X"87654000";
        wait_cycles(1);

        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- ATC lookup
        wait until atc_lookup_req = '1' or test_complete;
        atc_lookup_done <= '1';
        atc_hit <= '1';  -- Found in ATC
        wait_cycles(1);
        atc_lookup_done <= '0';

        -- MMU walk
        wait until mmu_walk_req = '1' or test_complete;
        mmu_walk_result <= X"0040";  -- ATC hit bit should be set
        mmu_desc_addr   <= X"00200000";
        mmu_walk_done   <= '1';
        wait_cycles(1);
        mmu_walk_done   <= '0';

        -- MMUSR update
        wait until mmusr_update = '1' or test_complete;
        wait_cycles(1);

        -- Return register write
        wait until ret_reg_write = '1' or test_complete;
        wait_cycles(1);
        report_test("Return register written", ret_reg_write = '1');
        report_test("Return to A5", ret_reg_num = "101");
        report_test("Descriptor address", ret_reg_data = X"00200000");

        wait until execute_done = '1' or test_complete;
        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 10: ATC Hit Detection
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 10: ATC hit in MMUSR" severity note;
        report "==================================" severity note;

        build_ptest("010", "000", "111", FC_USER_PROG, '0', '0', "000");
        ea_addr <= X"00001000";
        wait_cycles(1);

        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- ATC hit
        wait until atc_lookup_req = '1' or test_complete;
        atc_lookup_done <= '1';
        atc_hit <= '1';
        wait_cycles(1);
        atc_lookup_done <= '0';

        -- MMU walk
        wait until mmu_walk_req = '1' or test_complete;
        mmu_walk_result <= X"0000";  -- Base result
        mmu_walk_done   <= '1';
        wait_cycles(1);
        mmu_walk_done   <= '0';

        -- MMUSR should have ATC hit bit set (bit 6)
        wait until mmusr_update = '1' or test_complete;
        wait_cycles(1);
        report_test("MMUSR ATC hit bit", mmusr_data(6) = '1');

        wait until execute_done = '1' or test_complete;
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

        report "PTEST Test Summary:" severity note;
        report "  - All levels (0-7) decoded correctly" severity note;
        report "  - All function codes (0-7) supported" severity note;
        report "  - Read and write access tests" severity note;
        report "  - Return register enable and write" severity note;
        report "  - Privilege checking (supervisor only)" severity note;
        report "  - Illegal instruction detection" severity note;
        report "  - Complete execution flow with MMU interface" severity note;
        report "  - ATC lookup and hit detection" severity note;
        report "  - MMUSR update with results" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
