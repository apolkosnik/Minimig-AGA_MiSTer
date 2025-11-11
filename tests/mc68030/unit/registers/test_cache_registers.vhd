------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Cache Registers Unit Test                                       --
--                                                                          --
-- Tests the TG68K030_Cache_Registers module (CACR and CAAR)               --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity test_cache_registers_tb is
end entity test_cache_registers_tb;

architecture behavior of test_cache_registers_tb is

    -- Clock period
    constant CLK_PERIOD : time := 20 ns;

    -- Component declaration
    component TG68K030_Cache_Registers is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            supervisor     : in std_logic;
            reg_select     : in std_logic_vector(1 downto 0);
            reg_write      : in std_logic;
            reg_read       : in std_logic;
            data_in        : in std_logic_vector(31 downto 0);
            data_out       : out std_logic_vector(31 downto 0);
            priv_violation : out std_logic;
            cacr_ei        : out std_logic;
            cacr_fi        : out std_logic;
            cacr_ci        : out std_logic;
            cacr_cei       : out std_logic;
            cacr_ibe       : out std_logic;
            cacr_ed        : out std_logic;
            cacr_fd        : out std_logic;
            cacr_cd        : out std_logic;
            cacr_cde       : out std_logic;
            cacr_dbe       : out std_logic;
            cacr_wa        : out std_logic;
            caar_addr      : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal supervisor     : std_logic := '1';
    signal reg_select     : std_logic_vector(1 downto 0) := "00";
    signal reg_write      : std_logic := '0';
    signal reg_read       : std_logic := '0';
    signal data_in        : std_logic_vector(31 downto 0) := (others => '0');
    signal data_out       : std_logic_vector(31 downto 0);
    signal priv_violation : std_logic;
    signal cacr_ei        : std_logic;
    signal cacr_fi        : std_logic;
    signal cacr_ci        : std_logic;
    signal cacr_cei       : std_logic;
    signal cacr_ibe       : std_logic;
    signal cacr_ed        : std_logic;
    signal cacr_fd        : std_logic;
    signal cacr_cd        : std_logic;
    signal cacr_cde       : std_logic;
    signal cacr_dbe       : std_logic;
    signal cacr_wa        : std_logic;
    signal caar_addr      : std_logic_vector(31 downto 0);

    -- Test control
    signal test_complete : boolean := false;
    signal test_passed   : boolean := true;

    -- Register select codes
    constant SEL_CACR : std_logic_vector(1 downto 0) := "01";
    constant SEL_CAAR : std_logic_vector(1 downto 0) := "10";

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
    dut: TG68K030_Cache_Registers
        port map (
            clk            => clk,
            reset          => reset,
            supervisor     => supervisor,
            reg_select     => reg_select,
            reg_write      => reg_write,
            reg_read       => reg_read,
            data_in        => data_in,
            data_out       => data_out,
            priv_violation => priv_violation,
            cacr_ei        => cacr_ei,
            cacr_fi        => cacr_fi,
            cacr_ci        => cacr_ci,
            cacr_cei       => cacr_cei,
            cacr_ibe       => cacr_ibe,
            cacr_ed        => cacr_ed,
            cacr_fd        => cacr_fd,
            cacr_cd        => cacr_cd,
            cacr_cde       => cacr_cde,
            cacr_dbe       => cacr_dbe,
            cacr_wa        => cacr_wa,
            caar_addr      => caar_addr
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

        procedure write_cacr(data : std_logic_vector(31 downto 0)) is
        begin
            reg_select <= SEL_CACR;
            data_in    <= data;
            reg_write  <= '1';
            wait for CLK_PERIOD;
            reg_write  <= '0';
            wait for CLK_PERIOD;
        end procedure;

        procedure write_caar(data : std_logic_vector(31 downto 0)) is
        begin
            reg_select <= SEL_CAAR;
            data_in    <= data;
            reg_write  <= '1';
            wait for CLK_PERIOD;
            reg_write  <= '0';
            wait for CLK_PERIOD;
        end procedure;

        procedure read_cacr is
        begin
            reg_select <= SEL_CACR;
            reg_read   <= '1';
            wait for CLK_PERIOD;
            reg_read   <= '0';
            wait for CLK_PERIOD;
        end procedure;

        procedure read_caar is
        begin
            reg_select <= SEL_CAAR;
            reg_read   <= '1';
            wait for CLK_PERIOD;
            reg_read   <= '0';
            wait for CLK_PERIOD;
        end procedure;

    begin
        --------------------------------------------------------------
        -- Test 0: Reset
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 0: Reset values" severity note;
        report "==================================" severity note;

        supervisor <= '1';
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        -- Check all bits are zero after reset
        report_test("CACR EI reset", cacr_ei = '0');
        report_test("CACR FI reset", cacr_fi = '0');
        report_test("CACR IBE reset", cacr_ibe = '0');
        report_test("CACR ED reset", cacr_ed = '0');
        report_test("CACR FD reset", cacr_fd = '0');
        report_test("CACR DBE reset", cacr_dbe = '0');
        report_test("CACR WA reset", cacr_wa = '0');
        report_test("CAAR reset", caar_addr = x"00000000");

        --------------------------------------------------------------
        -- Test 1: Enable both caches
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 1: Enable caches" severity note;
        report "==================================" severity note;

        write_cacr(x"00000101");  -- EI=1, ED=1
        report_test("I-cache enabled", cacr_ei = '1');
        report_test("D-cache enabled", cacr_ed = '1');
        report_test("Other bits clear", cacr_fi = '0' and cacr_fd = '0');

        -- Read back CACR
        read_cacr;
        wait for CLK_PERIOD;
        report_test("CACR readback", data_out = x"00000101");

        --------------------------------------------------------------
        -- Test 2: Freeze caches
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 2: Freeze caches" severity note;
        report "==================================" severity note;

        write_cacr(x"00000303");  -- EI=1, FI=1, ED=1, FD=1
        report_test("I-cache frozen", cacr_fi = '1');
        report_test("D-cache frozen", cacr_fd = '1');
        report_test("Caches still enabled", cacr_ei = '1' and cacr_ed = '1');

        --------------------------------------------------------------
        -- Test 3: Self-clearing bits (CI, CEI, CD, CDE)
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 3: Self-clearing bits" severity note;
        report "==================================" severity note;

        -- Clear instruction cache
        write_cacr(x"00000008");  -- CI=1
        wait for CLK_PERIOD;
        report_test("CI pulse generated", cacr_ci = '0');  -- Should be back to 0
        read_cacr;
        wait for CLK_PERIOD;
        report_test("CI reads as 0", data_out(3) = '0');  -- Self-clearing

        -- Clear instruction cache entry
        write_cacr(x"00000004");  -- CEI=1
        wait for CLK_PERIOD;
        report_test("CEI pulse generated", cacr_cei = '0');
        read_cacr;
        wait for CLK_PERIOD;
        report_test("CEI reads as 0", data_out(2) = '0');

        -- Clear data cache
        write_cacr(x"00000800");  -- CD=1
        wait for CLK_PERIOD;
        report_test("CD pulse generated", cacr_cd = '0');
        read_cacr;
        wait for CLK_PERIOD;
        report_test("CD reads as 0", data_out(11) = '0');

        -- Clear data cache entry
        write_cacr(x"00000400");  -- CDE=1
        wait for CLK_PERIOD;
        report_test("CDE pulse generated", cacr_cde = '0');
        read_cacr;
        wait for CLK_PERIOD;
        report_test("CDE reads as 0", data_out(10) = '0');

        --------------------------------------------------------------
        -- Test 4: Burst mode enable
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 4: Burst mode" severity note;
        report "==================================" severity note;

        write_cacr(x"00001111");  -- EI=1, IBE=1, ED=1, DBE=1
        report_test("I-burst enabled", cacr_ibe = '1');
        report_test("D-burst enabled", cacr_dbe = '1');

        --------------------------------------------------------------
        -- Test 5: Write allocate
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 5: Write allocate" severity note;
        report "==================================" severity note;

        write_cacr(x"00002000");  -- WA=1
        report_test("Write allocate enabled", cacr_wa = '1');

        --------------------------------------------------------------
        -- Test 6: CAAR read/write
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 6: CAAR register" severity note;
        report "==================================" severity note;

        write_caar(x"12345678");
        report_test("CAAR write", caar_addr = x"12345678");

        read_caar;
        wait for CLK_PERIOD;
        report_test("CAAR readback", data_out = x"12345678");

        -- Write different address
        write_caar(x"ABCDEF00");
        report_test("CAAR update", caar_addr = x"ABCDEF00");

        --------------------------------------------------------------
        -- Test 7: Privilege violations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 7: Privilege violations" severity note;
        report "==================================" severity note;

        -- Switch to user mode
        supervisor <= '0';
        wait for CLK_PERIOD;

        -- Try to write CACR in user mode
        write_cacr(x"FFFFFFFF");
        wait for CLK_PERIOD;
        report_test("User write blocked", cacr_ei /= '1' or priv_violation = '1');

        -- Try to read CACR in user mode
        read_cacr;
        wait for CLK_PERIOD;
        report_test("User read blocked", priv_violation = '1');

        -- Return to supervisor
        supervisor <= '1';
        wait for CLK_PERIOD;

        --------------------------------------------------------------
        -- Test 8: Reserved bits masking
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 8: Reserved bits" severity note;
        report "==================================" severity note;

        -- Try to write all 1s to CACR
        write_cacr(x"FFFFFFFF");
        read_cacr;
        wait for CLK_PERIOD;
        -- Only bits 0,1,4,8,9,12,13 should be set (persistent)
        -- Bits 2,3,10,11 are self-clearing (read as 0)
        -- Bits 5-7, 14-31 are reserved (read as 0)
        report_test("Reserved bits masked",
            data_out(7 downto 5) = "000" and
            data_out(31 downto 14) = (31 downto 14 => '0'));

        --------------------------------------------------------------
        -- Test 9: MC68020 compatibility
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 9: MC68020 CACR compatibility" severity note;
        report "==================================" severity note;

        -- MC68020 CACR: bit 0=Enable, bit 1=Freeze, bit 2=CE, bit 3=Clear
        -- Should map to MC68030 I-cache bits
        write_cacr(x"00000001");  -- 68020: Enable cache
        report_test("68020 enable maps to EI", cacr_ei = '1');

        write_cacr(x"00000002");  -- 68020: Freeze cache
        report_test("68020 freeze maps to FI", cacr_fi = '1');

        --------------------------------------------------------------
        -- Test 10: Combined operations
        --------------------------------------------------------------
        report "==================================" severity note;
        report "Test 10: Combined operations" severity note;
        report "==================================" severity note;

        -- Typical usage: Enable both caches, then clear both
        write_cacr(x"00000101");  -- Enable both
        wait for CLK_PERIOD * 2;
        write_cacr(x"00000909");  -- CI=1, CD=1, keep enabled
        wait for CLK_PERIOD;
        report_test("Clear pulses with enable", cacr_ei = '1' and cacr_ed = '1');

        -- Set CAAR then clear specific entry
        write_caar(x"00001230");  -- Address line 3 (bits 7-4 = 0011)
        write_cacr(x"00000004");  -- CEI=1
        wait for CLK_PERIOD;
        report_test("Entry clear with CAAR", cacr_cei = '0');  -- Pulse done

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
