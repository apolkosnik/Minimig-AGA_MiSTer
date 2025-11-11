------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 MMU Registers Unit Test                                         --
--                                                                          --
-- Tests the TG68K030_MMU_Registers module                                 --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_mmu_registers_tb is
end entity test_mmu_registers_tb;

architecture behavior of test_mmu_registers_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns; -- 50 MHz

    -- Component declaration
    component TG68K030_MMU_Registers is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            supervisor     : in std_logic;
            reg_addr       : in std_logic_vector(3 downto 0);
            reg_write      : in std_logic;
            reg_read       : in std_logic;
            reg_size       : in std_logic_vector(1 downto 0);
            data_in        : in std_logic_vector(63 downto 0);
            data_out       : out std_logic_vector(63 downto 0);
            priv_violation : out std_logic;
            tc_out         : out std_logic_vector(31 downto 0);
            tt0_out        : out std_logic_vector(31 downto 0);
            tt1_out        : out std_logic_vector(31 downto 0);
            crp_out        : out std_logic_vector(63 downto 0);
            srp_out        : out std_logic_vector(63 downto 0);
            mmusr_out      : out std_logic_vector(15 downto 0);
            mmusr_update   : in std_logic;
            mmusr_in       : in std_logic_vector(15 downto 0)
        );
    end component;

    -- Signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal supervisor     : std_logic := '1';
    signal reg_addr       : std_logic_vector(3 downto 0) := (others => '0');
    signal reg_write      : std_logic := '0';
    signal reg_read       : std_logic := '0';
    signal reg_size       : std_logic_vector(1 downto 0) := "00";
    signal data_in        : std_logic_vector(63 downto 0) := (others => '0');
    signal data_out       : std_logic_vector(63 downto 0);
    signal priv_violation : std_logic;
    signal tc_out         : std_logic_vector(31 downto 0);
    signal tt0_out        : std_logic_vector(31 downto 0);
    signal tt1_out        : std_logic_vector(31 downto 0);
    signal crp_out        : std_logic_vector(63 downto 0);
    signal srp_out        : std_logic_vector(63 downto 0);
    signal mmusr_out      : std_logic_vector(15 downto 0);
    signal mmusr_update   : std_logic := '0';
    signal mmusr_in       : std_logic_vector(15 downto 0) := (others => '0');

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- Register addresses
    constant REG_TC    : std_logic_vector(3 downto 0) := "0000";
    constant REG_TT0   : std_logic_vector(3 downto 0) := "0010";
    constant REG_TT1   : std_logic_vector(3 downto 0) := "0011";
    constant REG_CRP   : std_logic_vector(3 downto 0) := "0100";
    constant REG_SRP   : std_logic_vector(3 downto 0) := "0101";
    constant REG_MMUSR : std_logic_vector(3 downto 0) := "0110";

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
    dut: TG68K030_MMU_Registers
        port map (
            clk            => clk,
            reset          => reset,
            supervisor     => supervisor,
            reg_addr       => reg_addr,
            reg_write      => reg_write,
            reg_read       => reg_read,
            reg_size       => reg_size,
            data_in        => data_in,
            data_out       => data_out,
            priv_violation => priv_violation,
            tc_out         => tc_out,
            tt0_out        => tt0_out,
            tt1_out        => tt1_out,
            crp_out        => crp_out,
            srp_out        => srp_out,
            mmusr_out      => mmusr_out,
            mmusr_update   => mmusr_update,
            mmusr_in       => mmusr_in
        );

    --------------------------------------------------------------
    -- Test stimulus
    --------------------------------------------------------------
    stim_proc: process

        -- Helper procedure for reporting test results
        procedure report_test(
            test_name : string;
            passed    : boolean
        ) is
        begin
            if passed then
                report "PASS: " & test_name severity note;
            else
                report "FAIL: " & test_name severity error;
                test_passed <= false;
            end if;
        end procedure;

        -- Helper to write 32-bit register
        procedure write_reg32(
            addr : std_logic_vector(3 downto 0);
            data : std_logic_vector(31 downto 0)
        ) is
        begin
            reg_addr  <= addr;
            data_in   <= x"00000000" & data;
            reg_size  <= "00";  -- Long-word
            reg_write <= '1';
            wait for CLK_PERIOD;
            reg_write <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- Helper to write 64-bit register
        procedure write_reg64(
            addr : std_logic_vector(3 downto 0);
            data : std_logic_vector(63 downto 0)
        ) is
        begin
            reg_addr  <= addr;
            data_in   <= data;
            reg_size  <= "01";  -- Quad-word
            reg_write <= '1';
            wait for CLK_PERIOD;
            reg_write <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- Helper to read register
        procedure read_reg(
            addr : std_logic_vector(3 downto 0)
        ) is
        begin
            reg_addr <= addr;
            reg_read <= '1';
            wait for CLK_PERIOD;
            reg_read <= '0';
            wait for CLK_PERIOD;
        end procedure;

        -- Helper to check 32-bit value
        procedure check_value32(
            test_name : string;
            actual    : std_logic_vector(31 downto 0);
            expected  : std_logic_vector(31 downto 0)
        ) is
        begin
            if actual = expected then
                report_test(test_name, true);
            else
                report "  Expected: 0x" & to_hstring(expected) &
                       ", Got: 0x" & to_hstring(actual) severity error;
                report_test(test_name, false);
            end if;
        end procedure;

        -- Helper to check 64-bit value
        procedure check_value64(
            test_name : string;
            actual    : std_logic_vector(63 downto 0);
            expected  : std_logic_vector(63 downto 0)
        ) is
        begin
            if actual = expected then
                report_test(test_name, true);
            else
                report "  Expected: 0x" & to_hstring(expected) &
                       ", Got: 0x" & to_hstring(actual) severity error;
                report_test(test_name, false);
            end if;
        end procedure;

    begin
        --------------------------------------------------------------
        -- Test 0: Reset values
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 0: Reset values" severity note;
        report "==================================" severity note;

        supervisor <= '1';
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Check all registers are zero after reset
        check_value32("TC reset value", tc_out, x"00000000");
        check_value32("TT0 reset value", tt0_out, x"00000000");
        check_value32("TT1 reset value", tt1_out, x"00000000");
        check_value64("CRP reset value", crp_out, x"0000000000000000");
        check_value64("SRP reset value", srp_out, x"0000000000000000");
        check_value32("MMUSR reset value", x"0000" & mmusr_out, x"00000000");

        --------------------------------------------------------------
        -- Test 1: TC register read/write
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: TC register" severity note;
        report "==================================" severity note;

        -- Write TC
        write_reg32(REG_TC, x"80A08000");  -- E=1, PS=10, IS=10, TIA=8
        check_value32("TC write", tc_out, x"80A08000");

        -- Read TC
        read_reg(REG_TC);
        wait for CLK_PERIOD;
        check_value32("TC read", data_out(31 downto 0), x"80A08000");

        -- Test reserved bits are masked
        write_reg32(REG_TC, x"7FFFFFFF");  -- Try to set reserved bits
        check_value32("TC reserved bits masked", tc_out, x"00FFFFFF");

        --------------------------------------------------------------
        -- Test 2: TT0 register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: TT0 register" severity note;
        report "==================================" severity note;

        -- Write TT0 with I/O space mapping (0xFF000000-0xFFFFFFFF)
        write_reg32(REG_TT0, x"FF00FF0F");  -- Base=FF00, Mask=FF, E=1, CI=1
        check_value32("TT0 write", tt0_out, x"FF00FF0B");  -- bit 2 should be masked

        -- Read TT0
        read_reg(REG_TT0);
        wait for CLK_PERIOD;
        check_value32("TT0 read", data_out(31 downto 0), x"FF00FF0B");

        --------------------------------------------------------------
        -- Test 3: TT1 register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: TT1 register" severity note;
        report "==================================" severity note;

        -- Write TT1 with ROM mapping (0xF0000000-0xF0FFFFFF)
        write_reg32(REG_TT1, x"F000F007");  -- Base=F000, Mask=F0, E=1, CI=1
        check_value32("TT1 write", tt1_out, x"F000F007");

        -- Read TT1
        read_reg(REG_TT1);
        wait for CLK_PERIOD;
        check_value32("TT1 read", data_out(31 downto 0), x"F000F007");

        --------------------------------------------------------------
        -- Test 4: CRP register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: CRP register" severity note;
        report "==================================" severity note;

        -- Write CRP pointing to table at 0x00100000
        write_reg64(REG_CRP, x"8000000000100000");  -- DT=10, Address=0x00100000
        check_value64("CRP write", crp_out, x"8000000000100000");

        -- Read CRP
        read_reg(REG_CRP);
        wait for CLK_PERIOD;
        check_value64("CRP read", data_out, x"8000000000100000");

        -- Test alignment enforcement (bits 3-0 must be 0)
        write_reg64(REG_CRP, x"800000000010000F");  -- Try to set low bits
        check_value64("CRP alignment", crp_out, x"8000000000100000");  -- Low bits masked

        --------------------------------------------------------------
        -- Test 5: SRP register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: SRP register" severity note;
        report "==================================" severity note;

        -- Write SRP pointing to table at 0x00200000
        write_reg64(REG_SRP, x"8000000000200000");
        check_value64("SRP write", srp_out, x"8000000000200000");

        -- Read SRP
        read_reg(REG_SRP);
        wait for CLK_PERIOD;
        check_value64("SRP read", data_out, x"8000000000200000");

        --------------------------------------------------------------
        -- Test 6: MMUSR register
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: MMUSR register" severity note;
        report "==================================" severity note;

        -- Write MMUSR (unusual but allowed)
        write_reg32(REG_MMUSR, x"0000FF20");  -- Set some flags
        check_value32("MMUSR write", x"0000" & mmusr_out, x"0000FF20");

        -- Read MMUSR
        read_reg(REG_MMUSR);
        wait for CLK_PERIOD;
        check_value32("MMUSR read", data_out(15 downto 0), x"FF20");

        -- Test MMUSR update from MMU logic
        mmusr_in <= x"C060";  -- Some status bits
        mmusr_update <= '1';
        wait for CLK_PERIOD;
        mmusr_update <= '0';
        wait for CLK_PERIOD;
        check_value32("MMUSR update from MMU", x"0000" & mmusr_out, x"0000C060");

        --------------------------------------------------------------
        -- Test 7: Privilege violations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: Privilege violations" severity note;
        report "==================================" severity note;

        -- Switch to user mode
        supervisor <= '0';
        wait for CLK_PERIOD;

        -- Try to write TC in user mode
        write_reg32(REG_TC, x"FFFFFFFF");
        wait for CLK_PERIOD;
        report_test("User mode write blocked", tc_out /= x"FFFFFFFF");
        report_test("Privilege violation asserted on write", priv_violation = '1');

        -- Try to read TC in user mode
        reg_read <= '1';
        reg_addr <= REG_TC;
        wait for CLK_PERIOD;
        report_test("Privilege violation asserted on read", priv_violation = '1');
        reg_read <= '0';
        wait for CLK_PERIOD;

        -- Return to supervisor mode
        supervisor <= '1';
        wait for CLK_PERIOD;
        report_test("Privilege violation cleared in supervisor", priv_violation = '0');

        --------------------------------------------------------------
        -- Test 8: Multiple register operations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Multiple register operations" severity note;
        report "==================================" severity note;

        -- Write all registers with different values
        write_reg32(REG_TC, x"80000001");
        write_reg32(REG_TT0, x"12345609");
        write_reg32(REG_TT1, x"ABCDEF0B");
        write_reg64(REG_CRP, x"C000111100300000");
        write_reg64(REG_SRP, x"C000222200400000");

        -- Verify all values independently
        check_value32("Multi-reg TC", tc_out, x"80000001");
        check_value32("Multi-reg TT0", tt0_out, x"12345609");
        check_value32("Multi-reg TT1", tt1_out, x"ABCDEF0B");
        check_value64("Multi-reg CRP", crp_out, x"C000111100300000");
        check_value64("Multi-reg SRP", srp_out, x"C000222200400000");

        --------------------------------------------------------------
        -- Test 9: Reserved bit masking comprehensive
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: Reserved bit masking" severity note;
        report "==================================" severity note;

        -- TC: bits 30-24 reserved
        write_reg32(REG_TC, x"FFFFFFFF");
        check_value32("TC reserved mask", tc_out(30 downto 24), "0000000");

        -- TT0/TT1: bits 15-12 and bit 2 reserved
        write_reg32(REG_TT0, x"FFFFFFFF");
        check_value32("TT0 bit 15-12 reserved", tt0_out(15 downto 12), "0000");
        check_value32("TT0 bit 2 reserved", std_logic_vector'(0 => tt0_out(2)), "0");

        -- CRP/SRP: bits 61-48 and 3-0 reserved/forced
        write_reg64(REG_CRP, x"FFFFFFFFFFFFFFFF");
        check_value32("CRP bits 61-48 reserved", crp_out(61 downto 48), x"0000");
        check_value32("CRP bits 3-0 forced zero", crp_out(3 downto 0), "0000");

        --------------------------------------------------------------
        -- Final report
        --------------------------------------------------------------
        wait for CLK_PERIOD * 10;

        report "==================================" severity note;
        if test_passed then
            report "ALL TESTS PASSED" severity note;
        else
            report "SOME TESTS FAILED" severity error;
        end if;
        report "==================================" severity note;

        test_complete <= true;
        wait;

    end process;

end architecture behavior;
