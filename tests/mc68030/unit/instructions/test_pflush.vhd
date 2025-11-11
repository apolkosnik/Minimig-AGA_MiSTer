------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 PFLUSH Instruction Unit Test                                    --
--                                                                          --
-- Tests PFLUSH instruction for invalidating ATC entries                   --
--                                                                          --
-- Coverage:                                                                --
--   - PFLUSHA (flush all) detection and execution                         --
--   - PFLUSH FC (flush by function code) detection and execution          --
--   - PFLUSH FC,EA (flush specific address) detection and execution       --
--   - All function code values (0-7)                                      --
--   - Privilege checking (supervisor only)                                --
--   - Illegal instruction detection                                       --
--   - ATC invalidation interface                                          --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_pflush_tb is
end entity test_pflush_tb;

architecture behavior of test_pflush_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_PFLUSH is
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
            atc_inv_req     : out std_logic;
            atc_inv_mode    : out std_logic_vector(1 downto 0);
            atc_inv_fc      : out std_logic_vector(2 downto 0);
            atc_inv_addr    : out std_logic_vector(31 downto 0);
            atc_inv_ack     : in  std_logic;
            is_pflush       : out std_logic;
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
    signal atc_inv_req    : std_logic;
    signal atc_inv_mode   : std_logic_vector(1 downto 0);
    signal atc_inv_fc     : std_logic_vector(2 downto 0);
    signal atc_inv_addr   : std_logic_vector(31 downto 0);
    signal atc_inv_ack    : std_logic := '0';
    signal is_pflush      : std_logic;
    signal illegal_instr  : std_logic;
    signal priv_violation : std_logic;

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- PFLUSH instruction format
    constant FLINE_PREFIX : std_logic_vector(9 downto 0) := "1111000000";
    constant MMU_CP_ID    : std_logic_vector(2 downto 0) := "010";

    -- PFLUSH modes
    constant MODE_PFLUSHA  : std_logic_vector(1 downto 0) := "00";
    constant MODE_FC_EA    : std_logic_vector(1 downto 0) := "01";
    constant MODE_FC       : std_logic_vector(1 downto 0) := "10";

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
    dut: TG68K030_PFLUSH
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
            atc_inv_req     => atc_inv_req,
            atc_inv_mode    => atc_inv_mode,
            atc_inv_fc      => atc_inv_fc,
            atc_inv_addr    => atc_inv_addr,
            atc_inv_ack     => atc_inv_ack,
            is_pflush       => is_pflush,
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

        procedure build_pflusha is
        begin
            -- PFLUSHA: opcode=0xF000, extension=0x2400
            opcode       <= X"F000";
            extension    <= X"2400";
            opcode_valid <= '1';
        end procedure;

        procedure build_pflush_fc(fc : std_logic_vector(2 downto 0)) is
        begin
            -- PFLUSH FC: opcode=0xF000, extension=0x20xx (fc in bits 4-2)
            opcode       <= X"F000";
            extension    <= MMU_CP_ID & "10000000000" & fc & "00";
            opcode_valid <= '1';
        end procedure;

        procedure build_pflush_fc_ea(
            ea_mode_in  : std_logic_vector(2 downto 0);
            ea_reg_in   : std_logic_vector(2 downto 0);
            fc          : std_logic_vector(2 downto 0)
        ) is
        begin
            -- PFLUSH FC,EA: opcode=0xF0xx (with EA), extension=0x30xx (fc in bits 4-2)
            opcode       <= FLINE_PREFIX & ea_mode_in & ea_reg_in;
            extension    <= MMU_CP_ID & "01000000000" & fc & "00";
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
        report_test("No PFLUSH detected", is_pflush = '0');

        --------------------------------------------------------------
        -- Test 1: PFLUSHA Decode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: PFLUSHA decode" severity note;
        report "==================================" severity note;

        build_pflusha;
        wait_cycles(2);

        report_test("PFLUSHA detected", is_pflush = '1');
        report_test("Mode is PFLUSHA", atc_inv_mode = MODE_PFLUSHA);
        report_test("Not illegal", illegal_instr = '0');
        report_test("No privilege violation", priv_violation = '0');

        opcode_valid <= '0';
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 2: PFLUSH FC Decode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: PFLUSH FC decode" severity note;
        report "==================================" severity note;

        -- PFLUSH FC with user data (001)
        build_pflush_fc(FC_USER_DATA);
        wait_cycles(2);

        report_test("PFLUSH FC detected", is_pflush = '1');
        report_test("Mode is FC", atc_inv_mode = MODE_FC);
        report_test("FC is user data", atc_inv_fc = FC_USER_DATA);

        opcode_valid <= '0';
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 3: PFLUSH FC,EA Decode
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: PFLUSH FC,EA decode" severity note;
        report "==================================" severity note;

        -- PFLUSH #1,(A0)
        build_pflush_fc_ea("010", "000", FC_USER_DATA);
        wait_cycles(2);

        report_test("PFLUSH FC,EA detected", is_pflush = '1');
        report_test("Mode is FC,EA", atc_inv_mode = MODE_FC_EA);
        report_test("FC is user data", atc_inv_fc = FC_USER_DATA);
        report_test("EA mode extracted", ea_mode = "010");
        report_test("EA reg extracted", ea_reg = "000");

        opcode_valid <= '0';
        wait_cycles(2);

        --------------------------------------------------------------
        -- Test 4: All Function Codes
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: All function codes" severity note;
        report "==================================" severity note;

        for fc_val in 0 to 7 loop
            build_pflush_fc(std_logic_vector(to_unsigned(fc_val, 3)));
            wait_cycles(1);
            report_test("FC=" & integer'image(fc_val),
                       is_pflush = '1' and atc_inv_fc = std_logic_vector(to_unsigned(fc_val, 3)));
            opcode_valid <= '0';
            wait_cycles(1);
        end loop;

        --------------------------------------------------------------
        -- Test 5: Privilege Violations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: Privilege violations" severity note;
        report "==================================" severity note;

        -- Supervisor mode - should work
        supervisor <= '1';
        build_pflusha;
        wait_cycles(1);
        report_test("Supervisor allowed", priv_violation = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- User mode - should fail
        supervisor <= '0';
        build_pflusha;
        wait_cycles(1);
        report_test("User mode blocked", priv_violation = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Return to supervisor
        supervisor <= '1';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 6: Illegal Instructions
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: Illegal instructions" severity note;
        report "==================================" severity note;

        -- Valid PFLUSHA
        build_pflusha;
        wait_cycles(1);
        report_test("Valid PFLUSHA", illegal_instr = '0');
        opcode_valid <= '0';
        wait_cycles(1);

        -- Invalid mode (11)
        opcode       <= X"F000";
        extension    <= X"2600";  -- Mode=11 (invalid)
        opcode_valid <= '1';
        wait_cycles(1);
        report_test("Invalid mode illegal", illegal_instr = '1');
        opcode_valid <= '0';
        wait_cycles(1);

        --------------------------------------------------------------
        -- Test 7: PFLUSHA Execution
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: PFLUSHA execution" severity note;
        report "==================================" severity note;

        build_pflusha;
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Should request ATC invalidation
        wait until atc_inv_req = '1' or test_complete;
        wait_cycles(1);
        report_test("ATC invalidation requested", atc_inv_req = '1');
        report_test("Mode is PFLUSHA", atc_inv_mode = MODE_PFLUSHA);

        -- Acknowledge
        atc_inv_ack <= '1';
        wait_cycles(1);
        atc_inv_ack <= '0';

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("PFLUSHA execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 8: PFLUSH FC Execution
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: PFLUSH FC execution" severity note;
        report "==================================" severity note;

        build_pflush_fc(FC_USER_DATA);
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Should request ATC invalidation with FC
        wait until atc_inv_req = '1' or test_complete;
        wait_cycles(1);
        report_test("ATC invalidation requested", atc_inv_req = '1');
        report_test("Mode is FC", atc_inv_mode = MODE_FC);
        report_test("FC is user data", atc_inv_fc = FC_USER_DATA);

        -- Acknowledge
        atc_inv_ack <= '1';
        wait_cycles(1);
        atc_inv_ack <= '0';

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("PFLUSH FC execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 9: PFLUSH FC,EA Execution
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: PFLUSH FC,EA execution" severity note;
        report "==================================" severity note;

        build_pflush_fc_ea("010", "000", FC_SUPER_DATA);
        ea_addr <= X"12345000";  -- Specific address
        wait_cycles(1);

        -- Start execution
        execute_start <= '1';
        wait_cycles(1);
        execute_start <= '0';

        -- Should request ATC invalidation with FC and address
        wait until atc_inv_req = '1' or test_complete;
        wait_cycles(1);
        report_test("ATC invalidation requested", atc_inv_req = '1');
        report_test("Mode is FC,EA", atc_inv_mode = MODE_FC_EA);
        report_test("FC is super data", atc_inv_fc = FC_SUPER_DATA);
        report_test("Address captured", atc_inv_addr = X"12345000");

        -- Acknowledge
        atc_inv_ack <= '1';
        wait_cycles(1);
        atc_inv_ack <= '0';

        -- Wait for done
        wait until execute_done = '1' or test_complete;
        wait_cycles(1);
        report_test("PFLUSH FC,EA execution complete", execute_done = '1');

        opcode_valid <= '0';
        wait_cycles(5);

        --------------------------------------------------------------
        -- Test 10: Multiple FC Values
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 10: Execute multiple FCs" severity note;
        report "==================================" severity note;

        for fc_val in 1 to 6 loop
            build_pflush_fc(std_logic_vector(to_unsigned(fc_val, 3)));
            wait_cycles(1);

            execute_start <= '1';
            wait_cycles(1);
            execute_start <= '0';

            wait until atc_inv_req = '1' or test_complete;
            wait_cycles(1);
            report_test("FC=" & integer'image(fc_val) & " captured",
                       atc_inv_fc = std_logic_vector(to_unsigned(fc_val, 3)));

            atc_inv_ack <= '1';
            wait_cycles(1);
            atc_inv_ack <= '0';

            wait until execute_done = '1' or test_complete;
            opcode_valid <= '0';
            wait_cycles(2);
        end loop;

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

        report "PFLUSH Test Summary:" severity note;
        report "  - PFLUSHA (flush all) detection and execution" severity note;
        report "  - PFLUSH FC (by function code) detection and execution" severity note;
        report "  - PFLUSH FC,EA (specific address) detection and execution" severity note;
        report "  - All function code values (0-7)" severity note;
        report "  - Privilege checking (supervisor only)" severity note;
        report "  - Illegal instruction detection" severity note;
        report "  - ATC invalidation interface signaling" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
