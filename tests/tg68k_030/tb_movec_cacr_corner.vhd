-- tb_movec_cacr_corner.vhd
-- Comprehensive testbench for MOVEC Dx,CACR with corner cases
-- Tests MC68030 CACR register behavior according to specification

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_movec_cacr_corner is
end tb_movec_cacr_corner;

architecture behavior of tb_movec_cacr_corner is

  -- Clock period
  constant clk_period : time := 10 ns;

  -- Test signals
  signal clk : std_logic := '0';
  signal Reset : std_logic := '1';
  signal clkena_lw : std_logic := '0';
  signal exec_movec_wr : std_logic := '0';
  signal exec_movec_rd : std_logic := '0';
  signal brief : std_logic_vector(15 downto 0) := (others => '0');
  signal reg_QA : std_logic_vector(31 downto 0) := (others => '0');

  -- CACR register (mimicking TG68KdotC_Kernel implementation)
  signal CACR : std_logic_vector(31 downto 0) := (others => '0');
  signal movec_data : std_logic_vector(31 downto 0) := (others => '0');

  -- Cache control signals (extracted from CACR)
  signal cacr_ie : std_logic;
  signal cacr_de : std_logic;
  signal cacr_ifreeze : std_logic;
  signal cacr_dfreeze : std_logic;

  -- Test control
  signal test_running : boolean := true;
  signal test_failed : boolean := false;

begin

  -- Clock generation
  clk_process: process
  begin
    while test_running loop
      clk <= '0';
      wait for clk_period/2;
      clk <= '1';
      wait for clk_period/2;
    end loop;
    wait;
  end process;

  -- CACR Register Implementation (exact copy from TG68KdotC_Kernel.vhd)
  cacr_process: process (clk)
  begin
    if rising_edge(clk) then
      if Reset = '1' then
        CACR <= (others => '0');
      elsif clkena_lw = '1' and exec_movec_wr = '1' then
        case brief(11 downto 0) is
          when X"002" =>
            -- Write to CACR with proper MC68030 behavior
            CACR(1 downto 0) <= reg_QA(1 downto 0);     -- IE, FI
            -- Bits 2-3 are self-clearing command bits - NOT stored
            CACR(4) <= reg_QA(4);                        -- IBE
            CACR(7 downto 5) <= (others => '0');         -- Reserved
            CACR(9 downto 8) <= reg_QA(9 downto 8);     -- DE, FD
            -- Bits 10-11 are self-clearing command bits - NOT stored
            CACR(13 downto 12) <= reg_QA(13 downto 12); -- DBE, WA
            CACR(31 downto 14) <= (others => '0');       -- Reserved
          when others =>
            null;
        end case;
      elsif clkena_lw = '1' then
        -- Auto-clear self-clearing command bits
        if CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1' then
          CACR(2) <= '0';   -- Clear CEI
          CACR(3) <= '0';   -- Clear CI
          CACR(10) <= '0';  -- Clear CED
          CACR(11) <= '0';  -- Clear CD
        end if;
      end if;
    end if;
  end process;

  -- MOVEC read process
  movec_read_process: process(exec_movec_rd, brief, CACR)
  begin
    movec_data <= (others => '0');
    if exec_movec_rd = '1' then
      case brief(11 downto 0) is
        when X"002" =>
          movec_data <= CACR;
        when others =>
          null;
      end case;
    end if;
  end process;

  -- Extract cache control signals
  cacr_ie     <= CACR(0);  -- Instruction Cache Enable
  cacr_ifreeze <= CACR(1);  -- Instruction Cache Freeze
  cacr_de     <= CACR(8);  -- Data Cache Enable
  cacr_dfreeze <= CACR(9);  -- Data Cache Freeze

  -- Test stimulus
  stim_proc: process
    -- Helper procedures
    procedure wait_cycles(count : integer) is
    begin
      for i in 1 to count loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    procedure report_test(name : string; pass : boolean) is
      variable l : line;
    begin
      write(l, string'("  TEST: "));
      write(l, name);
      if pass then
        write(l, string'(" - PASS"));
      else
        write(l, string'(" - FAIL"));
        test_failed <= true;
      end if;
      writeline(output, l);
    end procedure;

    procedure movec_write_cacr(value : std_logic_vector(31 downto 0)) is
    begin
      reg_QA <= value;
      brief <= X"0002";  -- CACR register selector
      exec_movec_wr <= '1';
      clkena_lw <= '1';
      wait_cycles(1);
      clkena_lw <= '0';
      exec_movec_wr <= '0';
      wait_cycles(1);
    end procedure;

    procedure movec_read_cacr is
    begin
      brief <= X"0002";  -- CACR register selector
      exec_movec_rd <= '1';
      wait_cycles(1);
      exec_movec_rd <= '0';
    end procedure;
    variable l : line;
  begin
    write(l, string'("========================================="));
    writeline(output, l);
    write(l, string'("MOVEC CACR Corner Case Test"));
    writeline(output, l);
    write(l, string'("========================================="));
    writeline(output, l);

    -- Reset
    Reset <= '1';
    wait_cycles(5);
    Reset <= '0';
    wait_cycles(5);

    -- TEST 1: All zeros (should work - disabled caches)
    write(l, string'("TEST 1: All Zeros (Disabled Caches)"));
    writeline(output, l);
    movec_write_cacr(x"00000000");
    movec_read_cacr;
    report_test("Write/Read 0x00000000", movec_data = x"00000000");
    report_test("IE=0, DE=0", cacr_ie = '0' and cacr_de = '0');

    -- TEST 2: Enable IE only (bit 0)
    write(l, string'("TEST 2: Enable Instruction Cache Only"));
    writeline(output, l);
    movec_write_cacr(x"00000001");
    movec_read_cacr;
    report_test("Write/Read 0x00000001", movec_data = x"00000001");
    report_test("IE=1, DE=0", cacr_ie = '1' and cacr_de = '0');

    -- TEST 3: Enable DE only (bit 8)
    write(l, string'("TEST 3: Enable Data Cache Only"));
    writeline(output, l);
    movec_write_cacr(x"00000100");
    movec_read_cacr;
    report_test("Write/Read 0x00000100", movec_data = x"00000100");
    report_test("IE=0, DE=1", cacr_ie = '0' and cacr_de = '1');

    -- TEST 4: Enable both caches (bits 0 + 8)
    write(l, string'("TEST 4: Enable Both Caches"));
    writeline(output, l);
    movec_write_cacr(x"00000101");
    movec_read_cacr;
    report_test("Write/Read 0x00000101", movec_data = x"00000101");
    report_test("IE=1, DE=1", cacr_ie = '1' and cacr_de = '1');

    -- TEST 5: Enable with freeze (bits 0,1,8,9)
    write(l, string'("TEST 5: Enable Both Caches with Freeze"));
    writeline(output, l);
    movec_write_cacr(x"00000303");
    movec_read_cacr;
    report_test("Write/Read 0x00000303", movec_data = x"00000303");
    report_test("IE=1, FI=1, DE=1, FD=1",
                cacr_ie = '1' and cacr_ifreeze = '1' and
                cacr_de = '1' and cacr_dfreeze = '1');

    -- TEST 6: Self-clearing bits should NOT be stored (bits 2,3,10,11)
    write(l, string'("TEST 6: Self-Clearing Command Bits NOT Stored"));
    writeline(output, l);
    movec_write_cacr(x"00000C0C");  -- CEI, CI, CED, CD set
    movec_read_cacr;
    report_test("Command bits NOT in CACR", movec_data = x"00000000");
    report_test("All enables remain OFF", cacr_ie = '0' and cacr_de = '0');

    -- TEST 7: Mixed sticky + command bits
    write(l, string'("TEST 7: Mixed Sticky and Command Bits"));
    writeline(output, l);
    movec_write_cacr(x"00000D0D");  -- IE, CI, CEI, DE, CD, CED
    movec_read_cacr;
    report_test("Only sticky bits stored", movec_data = x"00000101");
    report_test("IE=1, DE=1 (commands ignored)", cacr_ie = '1' and cacr_de = '1');

    -- TEST 8: Reserved bits masked (bits 5-7, 14-31)
    write(l, string'("TEST 8: Reserved Bits Masked"));
    writeline(output, l);
    movec_write_cacr(x"FFFFFFFF");  -- All bits set
    movec_read_cacr;
    -- Should have: IE, FI, IBE, DE, FD, DBE, WA = 0x3313
    report_test("Reserved bits masked", movec_data = x"00003313");
    report_test("Sticky bits preserved",
                cacr_ie = '1' and cacr_ifreeze = '1' and
                cacr_de = '1' and cacr_dfreeze = '1');

    -- TEST 9: Write then overwrite (ensure no sticky command bits)
    write(l, string'("TEST 9: Overwrite Previous Value"));
    writeline(output, l);
    movec_write_cacr(x"00000303");  -- Enable + freeze
    movec_read_cacr;
    report_test("First write 0x00000303", movec_data = x"00000303");
    movec_write_cacr(x"00000000");  -- Disable all
    movec_read_cacr;
    report_test("Overwrite with 0x00000000", movec_data = x"00000000");
    report_test("All disabled", cacr_ie = '0' and cacr_de = '0');

    -- TEST 10: Enable with burst enable (bit 4, 12)
    write(l, string'("TEST 10: Burst Enable Bits"));
    writeline(output, l);
    movec_write_cacr(x"00001111");  -- IE, FI, IBE, DE, FD, DBE
    movec_read_cacr;
    report_test("Write/Read 0x00001111", movec_data = x"00001111");
    report_test("Burst enables work", CACR(4) = '1' and CACR(12) = '1');

    -- TEST 11: Write allocate bit (bit 13)
    write(l, string'("TEST 11: Write Allocate Bit"));
    writeline(output, l);
    movec_write_cacr(x"00002100");  -- DE with WA
    movec_read_cacr;
    report_test("Write/Read 0x00002100", movec_data = x"00002100");
    report_test("WA bit set", CACR(13) = '1');

    -- TEST 12: Alternating enable/disable
    write(l, string'("TEST 12: Alternating Enable/Disable"));
    writeline(output, l);
    for i in 1 to 3 loop
      movec_write_cacr(x"00000101");  -- Enable
      movec_read_cacr;
      report_test("Enable iteration " & integer'image(i), movec_data = x"00000101");
      movec_write_cacr(x"00000000");  -- Disable
      movec_read_cacr;
      report_test("Disable iteration " & integer'image(i), movec_data = x"00000000");
    end loop;

    -- TEST 13: Self-clearing with concurrent sticky bits
    write(l, string'("TEST 13: Self-Clearing Behavior"));
    writeline(output, l);
    movec_write_cacr(x"00000F0F");  -- All bits 0-3 and 8-11
    clkena_lw <= '1';
    wait_cycles(1);  -- Let auto-clear happen
    clkena_lw <= '0';
    wait_cycles(1);
    movec_read_cacr;
    report_test("Command bits auto-cleared", movec_data = x"00000303");
    report_test("Sticky bits remain", cacr_ie = '1' and cacr_ifreeze = '1' and
                                      cacr_de = '1' and cacr_dfreeze = '1');

    -- TEST 14: Reset clears everything
    write(l, string'("TEST 14: Reset Behavior"));
    writeline(output, l);
    movec_write_cacr(x"00003313");  -- Write max valid value
    Reset <= '1';
    wait_cycles(2);
    Reset <= '0';
    wait_cycles(2);
    movec_read_cacr;
    report_test("Reset clears CACR", movec_data = x"00000000");

    -- TEST 15: Extreme corner case - write during reset
    write(l, string'("TEST 15: Write During Reset (Should Be Ignored)"));
    writeline(output, l);
    Reset <= '1';
    movec_write_cacr(x"FFFFFFFF");  -- Try to write during reset
    Reset <= '0';
    wait_cycles(2);
    movec_read_cacr;
    report_test("Write during reset ignored", movec_data = x"00000000");

    -- Final summary
    wait_cycles(10);
    write(l, string'("========================================="));
    writeline(output, l);
    if test_failed then
      write(l, string'("MOVEC CACR CORNER TESTS: FAILED"));
    else
      write(l, string'("MOVEC CACR CORNER TESTS: PASSED"));
    end if;
    writeline(output, l);
    write(l, string'("========================================="));
    writeline(output, l);

    test_running <= false;
    wait;
  end process;

end behavior;
