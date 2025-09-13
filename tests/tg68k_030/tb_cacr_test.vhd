-- tb_cacr_test.vhd
-- Testbench for CACR register implementation in TG68KdotC_Kernel
-- Tests MOVEC operations with CACR register and self-clearing bits

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_cacr_test is
end tb_cacr_test;

architecture behavior of tb_cacr_test is

  -- Clock period
  constant clk_period : time := 10 ns;
  
  -- Test signals that would come from CPU instruction decode
  signal clk : std_logic := '0';
  signal Reset : std_logic := '1';
  signal clkena_lw : std_logic := '0';
  signal exec_movec_wr : std_logic := '0';
  signal exec_movec_rd : std_logic := '0';
  signal brief : std_logic_vector(15 downto 0) := (others => '0');
  signal reg_QA : std_logic_vector(31 downto 0) := (others => '0');
  
  -- Internal CACR register (mimicking kernel implementation)
  signal CACR : std_logic_vector(31 downto 0) := (others => '0');
  signal movec_data : std_logic_vector(31 downto 0) := (others => '0');
  
  -- Cache control signals
  signal cacr_de : std_logic;
  signal cacr_ie : std_logic;
  signal cacr_freeze : std_logic;

  -- Test control
  signal test_running : boolean := true;

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

  -- CACR Register Implementation (mimicking kernel code)
  cacr_process: process (clk)
  begin
    if rising_edge(clk) then
      if Reset = '1' then
        CACR <= (others => '0');
      elsif clkena_lw = '1' and exec_movec_wr = '1' then
        case brief(11 downto 0) is
          when X"002" => 
            -- Write to CACR with reserved bit masking (bits 31-7 read as 0)
            CACR(6 downto 0) <= reg_QA(6 downto 0);
            CACR(31 downto 7) <= (others => '0');
          when others => 
            null;
        end case;
      elsif clkena_lw = '1' then
        -- Auto-clear self-clearing bits after they've been set
        if CACR(3) = '1' or CACR(4) = '1' or CACR(5) = '1' or CACR(6) = '1' then
          CACR(6 downto 3) <= (others => '0');  -- Clear CE, CI, CD, CA bits
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
          movec_data <= CACR; -- CACR full 32-bit read
        when others => 
          null;
      end case;
    end if;
  end process;

  -- Extract cache control bits from CACR register
  cacr_de     <= CACR(0);  -- Data Cache Enable
  cacr_ie     <= CACR(1);  -- Instruction Cache Enable
  cacr_freeze <= CACR(2);  -- Cache Freeze

  -- Test stimulus
  stim_proc: process
    variable l : line;
    
    procedure wait_cycles(count : integer) is
    begin
      for i in 1 to count loop
        wait until rising_edge(clk);
      end loop;
    end procedure;
    
    procedure movec_write_cacr(data : std_logic_vector(31 downto 0)) is
    begin
      reg_QA <= data;
      brief <= X"0002"; -- MOVEC xx,CACR
      exec_movec_wr <= '1';
      clkena_lw <= '1';
      wait until rising_edge(clk);
      exec_movec_wr <= '0';
      clkena_lw <= '0';
      wait_cycles(1);
    end procedure;
    
    procedure movec_read_cacr is
    begin
      brief <= X"0002"; -- MOVEC CACR,xx
      exec_movec_rd <= '1';
      wait_cycles(1);
      exec_movec_rd <= '0';
    end procedure;

    procedure report_test(name : string; pass : boolean) is
    begin
      write(l, string'("TEST: "));
      write(l, name);
      if pass then
        write(l, string'(" - PASS"));
      else
        write(l, string'(" - FAIL"));
      end if;
      writeline(output, l);
    end procedure;

  begin
    write(l, string'("======================================"));
    writeline(output, l);
    write(l, string'("CACR Register Test"));
    writeline(output, l);
    write(l, string'("======================================"));
    writeline(output, l);

    -- Reset
    Reset <= '1';
    wait_cycles(5);
    Reset <= '0';
    wait_cycles(5);

    -- TEST 1: Basic CACR Read/Write
    write(l, string'("TEST 1: Basic CACR Operations"));
    writeline(output, l);
    
    movec_write_cacr(x"00000007"); -- DE=1, IE=1, FREEZE=1
    movec_read_cacr;
    report_test("Basic Write/Read", movec_data = x"00000007");
    report_test("DE Bit Extraction", cacr_de = '1');
    report_test("IE Bit Extraction", cacr_ie = '1');
    report_test("FREEZE Bit Extraction", cacr_freeze = '1');

    -- TEST 2: Reserved Bit Masking
    write(l, string'("TEST 2: Reserved Bit Masking"));
    writeline(output, l);
    
    movec_write_cacr(x"FFFFFFFF"); -- All bits set
    movec_read_cacr;
    report_test("Reserved Bits Masked", movec_data = x"0000007F"); -- Only bits 6-0 should be set

    -- TEST 3: Self-Clearing Bits
    write(l, string'("TEST 3: Self-Clearing Bits"));
    writeline(output, l);
    
    -- Set cache control bits (CE, CI, CD, CA)
    movec_write_cacr(x"00000078"); -- CE=1, CI=1, CD=1, CA=1 (bits 6-3)
    movec_read_cacr;
    report_test("Cache Control Bits Set", movec_data = x"00000078");
    
    -- Trigger self-clearing by enabling clock
    clkena_lw <= '1';
    wait_cycles(1);
    clkena_lw <= '0';
    wait_cycles(1);
    
    movec_read_cacr;
    report_test("Cache Control Bits Auto-Clear", movec_data = x"00000000");

    -- TEST 4: Persistent Bits Don't Clear
    write(l, string'("TEST 4: Persistent Bits"));
    writeline(output, l);
    
    movec_write_cacr(x"00000007"); -- DE=1, IE=1, FREEZE=1 (persistent)
    clkena_lw <= '1';
    wait_cycles(5); -- Multiple cycles
    clkena_lw <= '0';
    
    movec_read_cacr;
    report_test("Persistent Bits Remain", movec_data = x"00000007");

    -- TEST 5: Mixed Persistent and Self-Clearing
    write(l, string'("TEST 5: Mixed Bit Types"));
    writeline(output, l);
    
    movec_write_cacr(x"0000007F"); -- All 7 bits set
    movec_read_cacr;
    report_test("All Bits Initially Set", movec_data = x"0000007F");
    
    clkena_lw <= '1';
    wait_cycles(1);
    clkena_lw <= '0';
    wait_cycles(1);
    
    movec_read_cacr;
    -- Should have only bits 2-0 (persistent) remaining
    report_test("Only Persistent Bits Remain", movec_data = x"00000007");

    -- TEST 6: Reset Behavior
    write(l, string'("TEST 6: Reset Behavior"));
    writeline(output, l);
    
    movec_write_cacr(x"0000007F");
    Reset <= '1';
    wait_cycles(2);
    Reset <= '0';
    wait_cycles(2);
    
    movec_read_cacr;
    report_test("Reset Clears All Bits", movec_data = x"00000000");

    wait_cycles(10);
    write(l, string'("======================================"));
    writeline(output, l);
    write(l, string'("CACR Tests Completed"));
    writeline(output, l);
    write(l, string'("======================================"));
    writeline(output, l);

    test_running <= false;
    wait;
  end process;

end behavior;