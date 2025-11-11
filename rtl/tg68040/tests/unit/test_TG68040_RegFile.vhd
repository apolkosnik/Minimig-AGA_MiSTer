------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_RegFile                                              --
--                                                                          --
-- Tests the TG68040 control register file                                 --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;
use work.test_pkg.all;

entity test_TG68040_RegFile is
end test_TG68040_RegFile;

architecture sim of test_TG68040_RegFile is

    -- Component declaration
    component TG68040_RegFile is
        generic(
            CPU_MODE : std_logic_vector(1 downto 0) := CPU_68040
        );
        port(
            clk                 : in std_logic;
            reset               : in std_logic;
            supervisor          : in std_logic;
            movec_en            : in std_logic;
            movec_write         : in std_logic;
            movec_reg           : in std_logic_vector(11 downto 0);
            movec_data_in       : in std_logic_vector(31 downto 0);
            movec_data_out      : out std_logic_vector(31 downto 0);
            movec_valid         : out std_logic;
            movec_privilege_err : out std_logic;
            cacr_out            : out std_logic_vector(31 downto 0);
            tc_out              : out std_logic_vector(31 downto 0);
            itt0_out            : out std_logic_vector(31 downto 0);
            itt1_out            : out std_logic_vector(31 downto 0);
            dtt0_out            : out std_logic_vector(31 downto 0);
            dtt1_out            : out std_logic_vector(31 downto 0);
            vbr_out             : out std_logic_vector(31 downto 0);
            mmusr_in            : in std_logic_vector(15 downto 0);
            mmusr_out           : out std_logic_vector(15 downto 0)
        );
    end component;

    -- Test signals
    signal clk                 : std_logic := '0';
    signal reset               : std_logic := '1';
    signal supervisor          : std_logic := '1';
    signal movec_en            : std_logic := '0';
    signal movec_write         : std_logic := '0';
    signal movec_reg           : std_logic_vector(11 downto 0) := (others => '0');
    signal movec_data_in       : std_logic_vector(31 downto 0) := (others => '0');
    signal movec_data_out      : std_logic_vector(31 downto 0);
    signal movec_valid         : std_logic;
    signal movec_privilege_err : std_logic;
    signal cacr_out            : std_logic_vector(31 downto 0);
    signal tc_out              : std_logic_vector(31 downto 0);
    signal itt0_out            : std_logic_vector(31 downto 0);
    signal itt1_out            : std_logic_vector(31 downto 0);
    signal dtt0_out            : std_logic_vector(31 downto 0);
    signal dtt1_out            : std_logic_vector(31 downto 0);
    signal vbr_out             : std_logic_vector(31 downto 0);
    signal mmusr_in            : std_logic_vector(15 downto 0) := (others => '0');
    signal mmusr_out           : std_logic_vector(15 downto 0);

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

    -- Helper procedures
    procedure movec_write_reg(
        signal clk_sig      : in std_logic;
        signal en           : out std_logic;
        signal wr           : out std_logic;
        signal reg          : out std_logic_vector(11 downto 0);
        signal data         : out std_logic_vector(31 downto 0);
        constant reg_addr   : in std_logic_vector(11 downto 0);
        constant value      : in std_logic_vector(31 downto 0)
    ) is
    begin
        wait until rising_edge(clk_sig);
        en <= '1';
        wr <= '1';
        reg <= reg_addr;
        data <= value;
        wait until rising_edge(clk_sig);
        en <= '0';
        wr <= '0';
    end procedure;

    procedure movec_read_reg(
        signal clk_sig      : in std_logic;
        signal en           : out std_logic;
        signal wr           : out std_logic;
        signal reg          : out std_logic_vector(11 downto 0);
        constant reg_addr   : in std_logic_vector(11 downto 0)
    ) is
    begin
        wait until rising_edge(clk_sig);
        en <= '1';
        wr <= '0';
        reg <= reg_addr;
        wait until rising_edge(clk_sig);
        en <= '0';
    end procedure;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation (68040 mode)
    dut_68040: TG68040_RegFile
        generic map(
            CPU_MODE => CPU_68040
        )
        port map(
            clk                 => clk,
            reset               => reset,
            supervisor          => supervisor,
            movec_en            => movec_en,
            movec_write         => movec_write,
            movec_reg           => movec_reg,
            movec_data_in       => movec_data_in,
            movec_data_out      => movec_data_out,
            movec_valid         => movec_valid,
            movec_privilege_err => movec_privilege_err,
            cacr_out            => cacr_out,
            tc_out              => tc_out,
            itt0_out            => itt0_out,
            itt1_out            => itt1_out,
            dtt0_out            => dtt0_out,
            dtt1_out            => dtt1_out,
            vbr_out             => vbr_out,
            mmusr_in            => mmusr_in,
            mmusr_out           => mmusr_out
        );

    -- Test process
    test_proc: process
    begin
        report "=== Starting TG68040_RegFile tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Check all registers are zero after reset
        assert_equal(cacr_out, x"00000000", "CACR reset to 0");
        assert_equal(tc_out, x"00000000", "TC reset to 0");
        assert_equal(itt0_out, x"00000000", "ITT0 reset to 0");
        assert_equal(itt1_out, x"00000000", "ITT1 reset to 0");
        assert_equal(dtt0_out, x"00000000", "DTT0 reset to 0");
        assert_equal(dtt1_out, x"00000000", "DTT1 reset to 0");
        assert_equal(vbr_out, x"00000000", "VBR reset to 0");

        ----------------------------------------------------------------------
        -- Test 2: Write and read SFC/DFC (3-bit registers)
        ----------------------------------------------------------------------
        report "--- Test 2: SFC/DFC Registers ---";
        supervisor <= '1';

        -- Write SFC
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_SFC, x"00000005");
        wait for CLK_PERIOD;
        assert_equal(movec_valid, '1', "SFC write valid");
        assert_equal(movec_privilege_err, '0', "SFC no privilege error");

        -- Read SFC
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_SFC);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"00000005", "SFC read value");

        -- Write DFC
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_DFC, x"00000003");
        wait for CLK_PERIOD;

        -- Read DFC
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_DFC);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"00000003", "DFC read value");

        ----------------------------------------------------------------------
        -- Test 3: VBR register (32-bit)
        ----------------------------------------------------------------------
        report "--- Test 3: VBR Register ---";

        -- Write VBR
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_VBR, x"12345678");
        wait for CLK_PERIOD;
        assert_equal(vbr_out, x"12345678", "VBR direct output");

        -- Read VBR
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_VBR);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"12345678", "VBR read value");

        ----------------------------------------------------------------------
        -- Test 4: CACR register (32-bit in 68040 mode)
        ----------------------------------------------------------------------
        report "--- Test 4: CACR Register ---";

        -- Write CACR with cache enable bits
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_CACR, x"80008000");  -- DE and IE bits set
        wait for CLK_PERIOD;
        assert_equal(cacr_out, x"80008000", "CACR written");

        -- Read CACR
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_CACR);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"80008000", "CACR read value");

        ----------------------------------------------------------------------
        -- Test 5: TC register (68040 only)
        ----------------------------------------------------------------------
        report "--- Test 5: TC Register ---";

        -- Write TC
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_TC, x"80000000");  -- Enable bit set
        wait for CLK_PERIOD;
        assert_equal(tc_out, x"80000000", "TC written");
        assert_equal(movec_valid, '1', "TC write valid");

        -- Read TC
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_TC);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"80000000", "TC read value");

        ----------------------------------------------------------------------
        -- Test 6: ITT0/ITT1 registers
        ----------------------------------------------------------------------
        report "--- Test 6: ITT0/ITT1 Registers ---";

        -- Write ITT0
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_ITT0, x"ABCD0000");
        wait for CLK_PERIOD;
        assert_equal(itt0_out, x"ABCD0000", "ITT0 written");

        -- Write ITT1
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_ITT1, x"DCBA0000");
        wait for CLK_PERIOD;
        assert_equal(itt1_out, x"DCBA0000", "ITT1 written");

        -- Read ITT0
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_ITT0);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"ABCD0000", "ITT0 read value");

        -- Read ITT1
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_ITT1);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"DCBA0000", "ITT1 read value");

        ----------------------------------------------------------------------
        -- Test 7: DTT0/DTT1 registers
        ----------------------------------------------------------------------
        report "--- Test 7: DTT0/DTT1 Registers ---";

        -- Write DTT0
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_DTT0, x"1234ABCD");
        wait for CLK_PERIOD;
        assert_equal(dtt0_out, x"1234ABCD", "DTT0 written");

        -- Write DTT1
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_DTT1, x"5678DCBA");
        wait for CLK_PERIOD;
        assert_equal(dtt1_out, x"5678DCBA", "DTT1 written");

        -- Read DTT0
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_DTT0);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"1234ABCD", "DTT0 read value");

        -- Read DTT1
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_DTT1);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"5678DCBA", "DTT1 read value");

        ----------------------------------------------------------------------
        -- Test 8: URP/SRP registers
        ----------------------------------------------------------------------
        report "--- Test 8: URP/SRP Registers ---";

        -- Write URP
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_URP, x"AAAA5555");
        wait for CLK_PERIOD;

        -- Read URP
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_URP);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"AAAA5555", "URP read value");

        -- Write SRP
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_SRP, x"5555AAAA");
        wait for CLK_PERIOD;

        -- Read SRP
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_SRP);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"5555AAAA", "SRP read value");

        ----------------------------------------------------------------------
        -- Test 9: MMUSR register (read-only from external MMU)
        ----------------------------------------------------------------------
        report "--- Test 9: MMUSR Register ---";

        -- Set MMUSR from MMU
        mmusr_in <= x"ABCD";
        wait for CLK_PERIOD * 2;
        assert_equal(mmusr_out, x"ABCD", "MMUSR updated from MMU");

        -- Read MMUSR
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_MMUSR);
        wait for CLK_PERIOD;
        assert_equal(movec_data_out, x"0000ABCD", "MMUSR read value (16-bit)");

        ----------------------------------------------------------------------
        -- Test 10: Privilege checking - User mode access
        ----------------------------------------------------------------------
        report "--- Test 10: Privilege Checking ---";

        -- Switch to user mode
        supervisor <= '0';
        wait for CLK_PERIOD;

        -- Try to write VBR in user mode (should fail)
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_VBR, x"DEADBEEF");
        wait for CLK_PERIOD;
        assert_equal(movec_privilege_err, '1', "VBR user write causes privilege error");
        assert_equal(vbr_out, x"12345678", "VBR unchanged (still old value)");

        -- Try to read TC in user mode (should fail)
        movec_read_reg(clk, movec_en, movec_write, movec_reg, MOVEC_TC);
        wait for CLK_PERIOD;
        assert_equal(movec_privilege_err, '1', "TC user read causes privilege error");

        -- Return to supervisor mode
        supervisor <= '1';
        wait for CLK_PERIOD;

        ----------------------------------------------------------------------
        -- Test 11: Invalid register access
        ----------------------------------------------------------------------
        report "--- Test 11: Invalid Register ---";

        -- Try to access non-existent register
        movec_read_reg(clk, movec_en, movec_write, movec_reg, x"FFF");
        wait for CLK_PERIOD;
        assert_equal(movec_valid, '0', "Invalid register access returns invalid");

        ----------------------------------------------------------------------
        -- Test 12: CACR auto-clear bits
        ----------------------------------------------------------------------
        report "--- Test 12: CACR Auto-Clear Bits ---";

        -- Write CACR with clear cache bits set
        movec_write_reg(clk, movec_en, movec_write, movec_reg, movec_data_in,
                        MOVEC_CACR, x"8000800F");  -- DE, IE, and all clear bits
        wait for CLK_PERIOD * 2;

        -- Clear bits should auto-clear after 1 cycle
        wait for CLK_PERIOD;
        -- Bits 3,2,1,0 should be cleared, but DE and IE should remain
        assert_equal(cacr_out(31), '1', "CACR DE bit remains set");
        assert_equal(cacr_out(15), '1', "CACR IE bit remains set");
        assert_equal(cacr_out(3), '0', "CACR CDE bit auto-cleared");
        assert_equal(cacr_out(2), '0', "CACR CIE bit auto-cleared");
        assert_equal(cacr_out(1), '0', "CACR CD bit auto-cleared");
        assert_equal(cacr_out(0), '0', "CACR CI bit auto-cleared");

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All TG68040_RegFile tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
