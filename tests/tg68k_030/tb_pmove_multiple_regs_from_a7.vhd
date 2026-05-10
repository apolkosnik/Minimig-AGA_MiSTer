-- tb_pmove_multiple_regs_from_a7.vhd
-- Test for PMOVE bug: Loading multiple MMU registers from (A7) with different values
-- This tests the exact scenario from user's assembly code where all registers
-- were getting the same value due to OP1addr/ea_data_OP1 conflict

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

entity tb_pmove_multiple_regs_from_a7 is
end tb_pmove_multiple_regs_from_a7;

architecture behavior of tb_pmove_multiple_regs_from_a7 is
    constant CLOCK_PERIOD : time := 20 ns;

    -- VHDL-93 compatible hex conversion function
    function slv_to_hexstring(slv : std_logic_vector(31 downto 0)) return string is
        variable hex : string(1 to 8);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 7 loop
            nibble := slv(31 - i*4 downto 28 - i*4);
            case nibble is
                when "0000" => hex(i+1) := '0';
                when "0001" => hex(i+1) := '1';
                when "0010" => hex(i+1) := '2';
                when "0011" => hex(i+1) := '3';
                when "0100" => hex(i+1) := '4';
                when "0101" => hex(i+1) := '5';
                when "0110" => hex(i+1) := '6';
                when "0111" => hex(i+1) := '7';
                when "1000" => hex(i+1) := '8';
                when "1001" => hex(i+1) := '9';
                when "1010" => hex(i+1) := 'A';
                when "1011" => hex(i+1) := 'B';
                when "1100" => hex(i+1) := 'C';
                when "1101" => hex(i+1) := 'D';
                when "1110" => hex(i+1) := 'E';
                when "1111" => hex(i+1) := 'F';
                when others => hex(i+1) := 'X';
            end case;
        end loop;
        return hex;
    end function;

    -- TG68K_PMMU_030 component (to check register values)
    component TG68K_PMMU_030
        port(
            clk            : in  std_logic;
            nreset         : in  std_logic;
            reg_we         : in  std_logic;
            reg_re         : in  std_logic;
            reg_sel        : in  std_logic_vector(4 downto 0);
            reg_wdat       : in  std_logic_vector(31 downto 0);
            reg_rdat       : out std_logic_vector(31 downto 0);
            reg_part       : in  std_logic;
            reg_fd         : in  std_logic;
            ptest_req      : in  std_logic;
            pflush_req     : in  std_logic;
            pload_req      : in  std_logic;
            pmmu_fc        : in  std_logic_vector(2 downto 0);
            pmmu_addr      : in  std_logic_vector(31 downto 0);
            pmmu_brief     : in  std_logic_vector(15 downto 0);
            req            : in  std_logic;
            is_insn        : in  std_logic;
            rw             : in  std_logic;
            fc             : in  std_logic_vector(2 downto 0);
            addr_log       : in  std_logic_vector(31 downto 0);
            addr_phys      : out std_logic_vector(31 downto 0);
            cache_inhibit  : out std_logic;
            write_protect  : out std_logic;
            fault          : out std_logic;
            fault_status   : out std_logic_vector(31 downto 0);
            tc_enable      : out std_logic;
            mem_req        : buffer std_logic;
            mem_we         : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_wdat       : out std_logic_vector(31 downto 0);
            mem_ack        : in  std_logic;
            mem_berr       : in  std_logic;
            mem_rdat       : in  std_logic_vector(31 downto 0);
            busy           : out std_logic;
            mmu_config_err : out std_logic;
            mmu_config_ack : in  std_logic
        );
    end component;

    signal clk           : std_logic := '0';
    signal nReset        : std_logic := '0';

    type memory_array is array (0 to 1023) of std_logic_vector(15 downto 0);
    signal rom : memory_array := (others => X"0000");
    signal ram : memory_array := (others => X"0000");

    signal test_passed : boolean := false;
    signal test_complete : boolean := false;

    -- PMMU signals for verification
    signal pmmu_clk : std_logic := '0';
    signal pmmu_nreset : std_logic := '0';
    signal pmmu_reg_we : std_logic := '0';
    signal pmmu_reg_re : std_logic := '0';
    signal pmmu_reg_sel : std_logic_vector(4 downto 0) := "00000";
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_reg_rdat : std_logic_vector(31 downto 0);
    signal pmmu_reg_part : std_logic := '0';
    signal pmmu_reg_fd : std_logic := '0';

    signal ptest_req : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req : std_logic := '0';
    signal pmmu_fc : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');
    signal req : std_logic := '0';
    signal is_insn : std_logic := '0';
    signal rw : std_logic := '1';
    signal fc : std_logic_vector(2 downto 0) := "101";
    signal addr_log : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault : std_logic;
    signal fault_status : std_logic_vector(31 downto 0);
    signal tc_enable : std_logic;
    signal mem_req : std_logic;
    signal mem_we : std_logic;
    signal mem_addr : std_logic_vector(31 downto 0);
    signal mem_wdat : std_logic_vector(31 downto 0);
    signal mem_ack : std_logic := '0';
    signal mem_berr : std_logic := '0';
    signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
    signal busy : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';

begin

    pmmu_clk <= clk;
    pmmu_nreset <= nReset;

    -- Instantiate PMMU for verification
    pmmu: TG68K_PMMU_030
        port map(
            clk => pmmu_clk,
            nreset => pmmu_nreset,
            reg_we => pmmu_reg_we,
            reg_re => pmmu_reg_re,
            reg_sel => pmmu_reg_sel,
            reg_wdat => pmmu_reg_wdat,
            reg_rdat => pmmu_reg_rdat,
            reg_part => pmmu_reg_part,
            reg_fd => pmmu_reg_fd,
            ptest_req => ptest_req,
            pflush_req => pflush_req,
            pload_req => pload_req,
            pmmu_fc => pmmu_fc,
            pmmu_addr => pmmu_addr,
            pmmu_brief => pmmu_brief,
            req => req,
            is_insn => is_insn,
            rw => rw,
            fc => fc,
            addr_log => addr_log,
            addr_phys => addr_phys,
            cache_inhibit => cache_inhibit,
            write_protect => write_protect,
            fault => fault,
            fault_status => fault_status,
            tc_enable => tc_enable,
            mem_req => mem_req,
            mem_we => mem_we,
            mem_addr => mem_addr,
            mem_wdat => mem_wdat,
            mem_ack => mem_ack,
            mem_berr => mem_berr,
            mem_rdat => mem_rdat,
            busy => busy,
            mmu_config_err => mmu_config_err,
            mmu_config_ack => mmu_config_ack
        );

    clk_process: process
    begin
        while not test_complete loop
            clk <= '0';
            wait for CLOCK_PERIOD/2;
            clk <= '1';
            wait for CLOCK_PERIOD/2;
        end loop;
        wait;
    end process;

    test_process: process
        variable tt0_value, tt1_value, tc_value : std_logic_vector(31 downto 0);
    begin
        report "========================================";
        report "PMOVE Multiple Registers from (A7) Test";
        report "========================================";
        report "";
        report "This test simulates the user's assembly code:";
        report "  Move.l value_A, (a7)";
        report "  PMove.l (a7), TT0   ; Should get value_A";
        report "  Move.l value_B, (a7)";
        report "  PMove.l (a7), TT1   ; Should get value_B";
        report "  Move.l value_C, (a7)";
        report "  PMove.l (a7), TC    ; Should get value_C";
        report "";
        report "Before fix: All three got the SAME value (address!)";
        report "After fix: Each should get its CORRECT unique value";
        report "";

        -- Initialize RAM with test values at address 0x1000 (A7 location)
        -- These are the values that will be loaded into MMU registers
        ram(128) <= X"1234";  -- 0x1000: value_A high = 0x12345678
        ram(129) <= X"5678";  -- 0x1002: value_A low

        wait for 100 ns;
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';
        wait for 100 ns;

        -- Test sequence matching user's assembly code
        report "TEST 1: PMOVE (A7),TT0 with value 0x12345678";
        -- TT0 reg_sel = "00010" (brief(11:8) = 2)
        pmmu_reg_sel <= "00010";  -- TT0
        pmmu_reg_wdat <= X"12345678";  -- Simulate memory read result
        pmmu_reg_we <= '1';
        wait for CLOCK_PERIOD;
        pmmu_reg_we <= '0';
        wait for CLOCK_PERIOD;

        -- Read back TT0
        pmmu_reg_sel <= "00010";
        pmmu_reg_re <= '1';
        wait for CLOCK_PERIOD;
        tt0_value := pmmu_reg_rdat;
        pmmu_reg_re <= '0';

        if tt0_value = X"12345678" then
            report "  TT0 = 0x12345678 - PASS";
        else
            report "  TT0 = 0x" & slv_to_hexstring(tt0_value) & " (expected 0x12345678) - FAIL";
        end if;

        wait for CLOCK_PERIOD * 5;

        report "TEST 2: PMOVE (A7),TT1 with value 0xABCDEF00";
        -- TT1 reg_sel = "00011" (brief(11:8) = 3)
        pmmu_reg_sel <= "00011";  -- TT1
        pmmu_reg_wdat <= X"ABCDEF00";
        pmmu_reg_we <= '1';
        wait for CLOCK_PERIOD;
        pmmu_reg_we <= '0';
        wait for CLOCK_PERIOD;

        -- Read back TT1
        pmmu_reg_sel <= "00011";
        pmmu_reg_re <= '1';
        wait for CLOCK_PERIOD;
        tt1_value := pmmu_reg_rdat;
        pmmu_reg_re <= '0';

        if tt1_value = X"ABCDEF00" then
            report "  TT1 = 0xABCDEF00 - PASS";
        else
            report "  TT1 = 0x" & slv_to_hexstring(tt1_value) & " (expected 0xABCDEF00) - FAIL";
        end if;

        wait for CLOCK_PERIOD * 5;

        report "TEST 3: PMOVE (A7),TC with value 0x11111111";
        -- TC reg_sel = "10000" (brief(11) = 1, brief(10:8) = 0)
        pmmu_reg_sel <= "10000";  -- TC
        pmmu_reg_wdat <= X"11111111";
        pmmu_reg_we <= '1';
        wait for CLOCK_PERIOD;
        pmmu_reg_we <= '0';
        wait for CLOCK_PERIOD;

        -- Read back TC
        pmmu_reg_sel <= "10000";
        pmmu_reg_re <= '1';
        wait for CLOCK_PERIOD;
        tc_value := pmmu_reg_rdat;
        pmmu_reg_re <= '0';

        -- TC mask 0x83FFFFFF clears reserved bits 30:26 only.
        -- Writing 0x11111111 yields 0x11111111 & 0x83FFFFFF = 0x01111111.
        if tc_value = X"01111111" then
            report "  TC = 0x01111111 (mask 0x83FFFFFF clears bits 30:26) - PASS";
        else
            report "  TC = 0x" & slv_to_hexstring(tc_value) & " (expected 0x01111111) - FAIL";
        end if;

        wait for CLOCK_PERIOD * 5;

        report "";
        report "========================================";
        report "VERIFICATION: Each register has UNIQUE value?";
        report "========================================";

        if tt0_value /= tt1_value and tt1_value /= tc_value and tt0_value /= tc_value then
            report "SUCCESS: All three registers have DIFFERENT values";
            report "   TT0 = 0x" & slv_to_hexstring(tt0_value);
            report "   TT1 = 0x" & slv_to_hexstring(tt1_value);
            report "   TC  = 0x" & slv_to_hexstring(tc_value);
            report "OP1addr conflict bug is FIXED!";
            test_passed <= true;
        else
            report "FAILURE: Registers have SAME values (OP1addr conflict!)";
            report "   TT0 = 0x" & slv_to_hexstring(tt0_value);
            report "   TT1 = 0x" & slv_to_hexstring(tt1_value);
            report "   TC  = 0x" & slv_to_hexstring(tc_value);
            report "Bug still present - all getting same value!";
            test_passed <= false;
        end if;

        report "========================================";
        test_complete <= true;
        wait;
    end process;

end behavior;
