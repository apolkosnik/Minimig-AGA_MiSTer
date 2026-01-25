library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_lea_similar_issues is
end tb_lea_similar_issues;

architecture behavior of tb_lea_similar_issues is

    component TG68KdotC_Kernel
        generic(
            SR_Read : integer := 2;
            VBR_Stackframe : integer := 2;
            extAddr_Mode : integer := 2;
            MUL_Mode : integer := 2;
            DIV_Mode : integer := 2;
            BitField : integer := 2;
            BarrelShifter : integer := 1;
            MUL_Hardware : integer := 1
        );
        port(
            CPU : in std_logic_vector(1 downto 0) := "10";
            clk : in std_logic;
            nReset : in std_logic := '1';
            clkena_in : in std_logic := '1';
            data_in : in std_logic_vector(15 downto 0);
            IPL : in std_logic_vector(2 downto 0) := "111";
            IPL_autovector : in std_logic := '0';
            addr_out : out std_logic_vector(31 downto 0);
            berr : in std_logic := '0';
            FC : out std_logic_vector(2 downto 0);
            data_write : out std_logic_vector(15 downto 0);
            busstate : out std_logic_vector(1 downto 0);
            nWr : out std_logic;
            nUDS, nLDS : out std_logic;
            nResetOut : out std_logic;
            skipFetch : out std_logic;
            cache_cinv_req : out std_logic;
            cache_cpush_req : out std_logic;
            cache_op_scope : out std_logic_vector(1 downto 0);
            cache_op_cache : out std_logic_vector(1 downto 0);
            cacr_ie : out std_logic;
            cacr_de : out std_logic;
            cacr_ifreeze : out std_logic;
            cacr_dfreeze : out std_logic;
            cacr_ibe : out std_logic;
            cacr_dbe : out std_logic;
            cacr_wa : out std_logic;
            pmmu_addr_log : out std_logic_vector(31 downto 0);
            pmmu_addr_phys : out std_logic_vector(31 downto 0);
            pmmu_cache_inhibit : out std_logic;
            cache_op_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_req : out std_logic;
            pmmu_walker_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_ack : in std_logic;
            pmmu_walker_data : in std_logic_vector(31 downto 0);
            debug_SVmode : out std_logic;
            debug_preSVmode : out std_logic;
            debug_FlagsSR_S : out std_logic;
            debug_changeMode : out std_logic;
            debug_setopcode : out std_logic;
            debug_exec_directSR : out std_logic;
            debug_exec_to_SR : out std_logic
        );
    end component;

    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal addr_out : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal busstate : std_logic_vector(1 downto 0);
    signal nWr : std_logic;
    signal nUDS, nLDS : std_logic;
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    constant clk_period : time := 20 ns;

    type rom_array is array (0 to 511) of std_logic_vector(15 downto 0);
    signal rom : rom_array := (others => x"0000");

    type ram_array is array (0 to 255) of std_logic_vector(15 downto 0);
    signal ram : ram_array := (others => x"0000");

    -- Test checkpoint tracking
    signal test_passed : std_logic_vector(7 downto 0) := (others => '0');

begin

    uut: TG68KdotC_Kernel
        generic map(
            SR_Read => 2,
            VBR_Stackframe => 2,
            extAddr_Mode => 2,
            MUL_Mode => 2,
            DIV_Mode => 2,
            BitField => 2,
            BarrelShifter => 1,
            MUL_Hardware => 1
        )
        port map(
            CPU => "11",
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => IPL,
            IPL_autovector => '0',
            addr_out => addr_out,
            berr => '0',
            FC => open,
            data_write => data_write,
            busstate => busstate,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            nResetOut => open,
            skipFetch => open,
            cache_cinv_req => open,
            cache_cpush_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cacr_ie => open,
            cacr_de => open,
            cacr_ifreeze => open,
            cacr_dfreeze => open,
            cacr_ibe => open,
            cacr_dbe => open,
            cacr_wa => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            cache_op_addr => open,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open
        );

    clk_process: process
    begin
        clk <= '0';
        wait for clk_period/2;
        clk <= '1';
        wait for clk_period/2;
    end process;

    test_process: process
    begin
        report "========================================";
        report "Testing Instructions with Absolute Long";
        report "Checking for PC increment issues";
        report "========================================";

        -- Initialize 68000 reset vectors
        rom(0) <= x"0000";  -- Initial SSP high
        rom(1) <= x"3000";  -- Initial SSP low
        rom(2) <= x"0000";  -- Initial PC high
        rom(3) <= x"0010";  -- Initial PC low (0x10 = word offset 8)

        -- Initialize RAM
        ram(0) <= x"1234";  -- Test data at 0x2000
        ram(1) <= x"5678";

        -- Program starts at 0x10 (word offset 8)

        -- TEST 1: LEA (abs).L,An - Known bug
        report "TEST 1: LEA (abs).L,A0 - Known to have PC increment bug";
        rom(8) <= x"41F9";   -- LEA $2000,A0
        rom(9) <= x"0000";
        rom(10) <= x"2000";
        rom(11) <= x"7001";  -- MOVEQ #1,D0 (checkpoint - will this execute?)

        -- TEST 2: PEA (abs).L - Similar to LEA, might have same issue
        report "TEST 2: PEA (abs).L - Similar to LEA";
        rom(12) <= x"4879";  -- PEA $2000
        rom(13) <= x"0000";
        rom(14) <= x"2000";
        rom(15) <= x"7002";  -- MOVEQ #2,D0 (checkpoint)

        -- TEST 3: MOVE.L (abs).L,Dn - Regular memory read
        report "TEST 3: MOVE.L (abs).L,D1 - Regular memory access";
        rom(16) <= x"2239";  -- MOVE.L $2000,D1
        rom(17) <= x"0000";
        rom(18) <= x"2000";
        rom(19) <= x"7003";  -- MOVEQ #3,D0 (checkpoint)

        -- TEST 4: CLR.L (abs).L - Memory write operation
        report "TEST 4: CLR.L (abs).L - Memory write";
        rom(20) <= x"42B9";  -- CLR.L $2000
        rom(21) <= x"0000";
        rom(22) <= x"2000";
        rom(23) <= x"7004";  -- MOVEQ #4,D0 (checkpoint)

        -- TEST 5: ADD.L (abs).L,Dn - Arithmetic with memory
        report "TEST 5: ADD.L (abs).L,D2 - Arithmetic operation";
        rom(24) <= x"D4B9";  -- ADD.L $2000,D2
        rom(25) <= x"0000";
        rom(26) <= x"2000";
        rom(27) <= x"7005";  -- MOVEQ #5,D0 (checkpoint)

        -- TEST 6: CMP.L (abs).L,Dn - Comparison operation
        report "TEST 6: CMP.L (abs).L,D3 - Compare operation";
        rom(28) <= x"B6B9";  -- CMP.L $2000,D3
        rom(29) <= x"0000";
        rom(30) <= x"2000";
        rom(31) <= x"7006";  -- MOVEQ #6,D0 (checkpoint)

        -- TEST 7: MOVEA.L (abs).L,An - Move to address register
        report "TEST 7: MOVEA.L (abs).L,A1 - Move to address register";
        rom(32) <= x"2279";  -- MOVEA.L $2000,A1
        rom(33) <= x"0000";
        rom(34) <= x"2000";
        rom(35) <= x"7007";  -- MOVEQ #7,D0 (checkpoint)

        -- TEST 8: JSR (abs).L - Subroutine call
        report "TEST 8: JSR (abs).L - Subroutine call (will crash, but tests PC)";
        rom(36) <= x"4EB9";  -- JSR $2000
        rom(37) <= x"0000";
        rom(38) <= x"2000";
        rom(39) <= x"7008";  -- MOVEQ #8,D0 (checkpoint - may not reach)

        -- End marker
        rom(40) <= x"4E72";  -- STOP #$2700
        rom(41) <= x"2700";

        -- Release reset
        wait for 100 ns;
        nReset <= '1';
        wait for 100 ns;

        -- Run simulation
        for i in 1 to 500 loop
            wait for clk_period;

            -- Instruction fetch monitoring
            if busstate = "00" then
                if unsigned(addr_out(9 downto 1)) < rom'length then
                    data_in <= rom(to_integer(unsigned(addr_out(9 downto 1))));

                    -- Track checkpoints
                    case to_integer(unsigned(addr_out(9 downto 1))) is
                        -- TEST 1: LEA
                        when 8 =>
                            report "FETCH @ 0x10: LEA $2000,A0 (opcode)";
                        when 9 =>
                            report "FETCH @ 0x12: LEA address high";
                        when 10 =>
                            report "FETCH @ 0x14: LEA address low";
                        when 11 =>
                            report "FETCH @ 0x16: MOVEQ #1,D0";
                            test_passed(0) <= '1';
                            report "TEST 1 PASS: Next instruction after LEA executed";

                        -- TEST 2: PEA
                        when 12 =>
                            report "FETCH @ 0x18: PEA $2000 (opcode)";
                        when 13 =>
                            report "FETCH @ 0x1A: PEA address high";
                        when 14 =>
                            report "FETCH @ 0x1C: PEA address low";
                        when 15 =>
                            report "FETCH @ 0x1E: MOVEQ #2,D0";
                            test_passed(1) <= '1';
                            report "TEST 2 PASS: Next instruction after PEA executed";

                        -- TEST 3: MOVE.L
                        when 16 =>
                            report "FETCH @ 0x20: MOVE.L $2000,D1 (opcode)";
                        when 17 =>
                            report "FETCH @ 0x22: MOVE.L address high";
                        when 18 =>
                            report "FETCH @ 0x24: MOVE.L address low";
                        when 19 =>
                            report "FETCH @ 0x26: MOVEQ #3,D0";
                            test_passed(2) <= '1';
                            report "TEST 3 PASS: Next instruction after MOVE.L executed";

                        -- TEST 4: CLR.L
                        when 20 =>
                            report "FETCH @ 0x28: CLR.L $2000 (opcode)";
                        when 21 =>
                            report "FETCH @ 0x2A: CLR.L address high";
                        when 22 =>
                            report "FETCH @ 0x2C: CLR.L address low";
                        when 23 =>
                            report "FETCH @ 0x2E: MOVEQ #4,D0";
                            test_passed(3) <= '1';
                            report "TEST 4 PASS: Next instruction after CLR.L executed";

                        -- TEST 5: ADD.L
                        when 24 =>
                            report "FETCH @ 0x30: ADD.L $2000,D2 (opcode)";
                        when 25 =>
                            report "FETCH @ 0x32: ADD.L address high";
                        when 26 =>
                            report "FETCH @ 0x34: ADD.L address low";
                        when 27 =>
                            report "FETCH @ 0x36: MOVEQ #5,D0";
                            test_passed(4) <= '1';
                            report "TEST 5 PASS: Next instruction after ADD.L executed";

                        -- TEST 6: CMP.L
                        when 28 =>
                            report "FETCH @ 0x38: CMP.L $2000,D3 (opcode)";
                        when 29 =>
                            report "FETCH @ 0x3A: CMP.L address high";
                        when 30 =>
                            report "FETCH @ 0x3C: CMP.L address low";
                        when 31 =>
                            report "FETCH @ 0x3E: MOVEQ #6,D0";
                            test_passed(5) <= '1';
                            report "TEST 6 PASS: Next instruction after CMP.L executed";

                        -- TEST 7: MOVEA.L
                        when 32 =>
                            report "FETCH @ 0x40: MOVEA.L $2000,A1 (opcode)";
                        when 33 =>
                            report "FETCH @ 0x42: MOVEA.L address high";
                        when 34 =>
                            report "FETCH @ 0x44: MOVEA.L address low";
                        when 35 =>
                            report "FETCH @ 0x46: MOVEQ #7,D0";
                            test_passed(6) <= '1';
                            report "TEST 7 PASS: Next instruction after MOVEA.L executed";

                        -- TEST 8: JSR
                        when 36 =>
                            report "FETCH @ 0x48: JSR $2000 (opcode)";
                        when 37 =>
                            report "FETCH @ 0x4A: JSR address high";
                        when 38 =>
                            report "FETCH @ 0x4C: JSR address low";
                        when 39 =>
                            report "FETCH @ 0x4E: MOVEQ #8,D0";
                            test_passed(7) <= '1';
                            report "TEST 8 PASS: Next instruction after JSR executed (before jump)";

                        when 40 =>
                            report "FETCH @ 0x50: STOP instruction reached";

                        when others =>
                            null;
                    end case;
                end if;
            -- Data read
            elsif busstate = "10" then
                if addr_out(15 downto 8) = x"20" then
                    data_in <= ram(to_integer(unsigned(addr_out(7 downto 1))));
                end if;
            -- Data write
            elsif busstate = "11" and nWr = '0' then
                if addr_out(15 downto 8) = x"20" then
                    ram(to_integer(unsigned(addr_out(7 downto 1)))) <= data_write;
                end if;
            end if;
        end loop;

        -- Report results
        report " ";
        report "========================================";
        report "TEST RESULTS SUMMARY";
        report "========================================";

        if test_passed(0) = '1' then
            report "TEST 1 (LEA):    PASS - No PC skip detected";
        else
            report "TEST 1 (LEA):    FAIL - PC increment bug confirmed";
        end if;

        if test_passed(1) = '1' then
            report "TEST 2 (PEA):    PASS - No PC skip detected";
        else
            report "TEST 2 (PEA):    FAIL - PC increment bug detected";
        end if;

        if test_passed(2) = '1' then
            report "TEST 3 (MOVE.L): PASS - No PC skip detected";
        else
            report "TEST 3 (MOVE.L): FAIL - PC increment bug detected";
        end if;

        if test_passed(3) = '1' then
            report "TEST 4 (CLR.L):  PASS - No PC skip detected";
        else
            report "TEST 4 (CLR.L):  FAIL - PC increment bug detected";
        end if;

        if test_passed(4) = '1' then
            report "TEST 5 (ADD.L):  PASS - No PC skip detected";
        else
            report "TEST 5 (ADD.L):  FAIL - PC increment bug detected";
        end if;

        if test_passed(5) = '1' then
            report "TEST 6 (CMP.L):  PASS - No PC skip detected";
        else
            report "TEST 6 (CMP.L):  FAIL - PC increment bug detected";
        end if;

        if test_passed(6) = '1' then
            report "TEST 7 (MOVEA.L): PASS - No PC skip detected";
        else
            report "TEST 7 (MOVEA.L): FAIL - PC increment bug detected";
        end if;

        if test_passed(7) = '1' then
            report "TEST 8 (JSR):    PASS - No PC skip detected (pre-jump)";
        else
            report "TEST 8 (JSR):    FAIL - PC increment bug detected";
        end if;

        report " ";
        report "========================================";
        report "ANALYSIS";
        report "========================================";

        if test_passed = "00000001" then
            report "BUG IS SPECIFIC TO LEA INSTRUCTION ONLY";
            report "All other instructions with (abs).L work correctly";
        elsif test_passed(1) = '0' then
            report "BUG AFFECTS BOTH LEA AND PEA";
            report "Issue is with ea_only addressing mode";
        elsif test_passed = "00000000" then
            report "BUG AFFECTS ALL INSTRUCTIONS WITH (abs).L";
            report "Issue is systemic in absolute long EA handling";
        else
            report "BUG PATTERN IS COMPLEX - See individual test results";
        end if;

        report " ";
        report "Test complete!";
        wait;
    end process;

end behavior;
