-- Simple testbench for PMOVE register selector latching
-- Tests: PMOVE D0,TT0; PMOVE D1,TT1; PMOVE TT0,D2; PMOVE TT1,D3
-- Expected: D2=$12345670 (TT0), D3=$00000001 (TT1)
-- Bug #47: Selector not latching correctly, reads return wrong register

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_selector_simple is
end tb_pmove_selector_simple;

architecture behavior of tb_pmove_selector_simple is

  -- Signals
  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal IPL_autovector : std_logic := '0';
  signal CPU : std_logic_vector(1 downto 0) := "11";  -- 68030

  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr : std_logic;
  signal nUDS : std_logic;
  signal nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal nResetOut : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);

  -- Test control
  constant clk_period : time := 20 ns;  -- 50 MHz
  signal test_complete : boolean := false;

  -- Instruction ROM
  type rom_type is array (0 to 127) of std_logic_vector(15 downto 0);
  signal rom : rom_type := (
    -- Address 0x0000: Reset vector
    0 => X"0000",  -- Initial SSP high
    1 => X"1000",  -- Initial SSP low
    2 => X"0000",  -- Initial PC high
    3 => X"0100",  -- Initial PC low (start at 0x100)

    -- Address 0x0100: Test program
    -- MOVE.L #$12345678,D0
    16 => X"203C",  -- MOVE.L #imm,D0
    17 => X"1234",
    18 => X"5678",

    -- MOVE.L #$00000001,D1
    19 => X"223C",  -- MOVE.L #imm,D1
    20 => X"0000",
    21 => X"0001",

    -- PMOVE D0,TT0  (opcode $F010, extension word $0200)
    22 => X"F010",  -- PMOVE D0,TT0
    23 => X"0200",  -- Extension: P-reg=TT0(00010), RW=0(write), D/A=0, Reg=0

    -- PMOVE D1,TT1  (opcode $F011, extension word $0201)
    24 => X"F011",  -- PMOVE D1,TT1
    25 => X"0201",  -- Extension: P-reg=TT1(00011), RW=0(write), D/A=0, Reg=1

    -- PMOVE TT0,D2  (opcode $F012, extension word $0A02)
    26 => X"F012",  -- PMOVE TT0,D2
    27 => X"0A02",  -- Extension: P-reg=TT0(00010), RW=1(read), D/A=0, Reg=2

    -- PMOVE TT1,D3  (opcode $F013, extension word $0A03)
    28 => X"F013",  -- PMOVE TT1,D3
    29 => X"0A03",  -- Extension: P-reg=TT1(00011), RW=1(read), D/A=0, Reg=3

    -- STOP to end
    30 => X"4E72",  -- STOP
    31 => X"2700",  -- SR value

    others => X"4E71"  -- NOP
  );

begin
  -- Instantiate the CPU
  uut: entity work.TG68KdotC_Kernel
    port map (
      clk => clk,
      nReset => nReset,
      clkena_in => clkena_in,
      data_in => data_in,
      IPL => IPL,
      IPL_autovector => IPL_autovector,
      CPU => CPU,
      addr_out => addr_out,
      data_write => data_write,
      nWr => nWr,
      nUDS => nUDS,
      nLDS => nLDS,
      busstate => busstate,
      nResetOut => nResetOut,
      FC => FC,
      pmmu_reg_sel => pmmu_reg_sel,
      pmmu_walker_req => open,
      pmmu_walker_ack => '0',
      pmmu_walker_addr => open,
      pmmu_walker_data => (others => '0'),
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
      pmmu_reg_we => open,
      pmmu_reg_re => open,
      pmmu_reg_wdat => open,
      pmmu_reg_part => open,
      pmmu_addr_log => open,
      pmmu_addr_phys => open,
      pmmu_cache_inhibit => open,
      cache_op_addr => open,
      skipFetch => open,
      regin_out => open,
      CACR_out => open,
      VBR_out => open,
      longword => open,
      clr_berr => open,
      debug_SVmode => open,
      debug_preSVmode => open,
      debug_FlagsSR_S => open,
      debug_changeMode => open,
      debug_setopcode => open,
      debug_exec_directSR => open,
      debug_exec_to_SR => open
    );

  -- Clock generation
  clk_process: process
  begin
    while not test_complete loop
      clk <= '0';
      wait for clk_period/2;
      clk <= '1';
      wait for clk_period/2;
    end loop;
    wait;
  end process;

  -- Memory simulation
  mem_process: process(clk)
    variable addr_int : integer;
  begin
    if rising_edge(clk) then
      if busstate = "00" or busstate = "10" then  -- Read cycle
        addr_int := to_integer(unsigned(addr_out(7 downto 1)));
        if addr_int < rom'length then
          data_in <= rom(addr_int);
        else
          data_in <= X"4E71";  -- NOP for unmapped addresses
        end if;
      end if;
    end if;
  end process;

  -- Monitor process
  monitor: process(clk)
    variable cycle_count : integer := 0;
  begin
    if rising_edge(clk) then
      if nReset = '1' then
        cycle_count := cycle_count + 1;

        -- Report selector changes
        if pmmu_reg_sel /= "00000" then
          report "CYCLE " & integer'image(cycle_count) &
                 ": pmmu_reg_sel=" & integer'image(to_integer(unsigned(pmmu_reg_sel))) &
                 " (binary: " &
                 std_logic'image(pmmu_reg_sel(4)) &
                 std_logic'image(pmmu_reg_sel(3)) &
                 std_logic'image(pmmu_reg_sel(2)) &
                 std_logic'image(pmmu_reg_sel(1)) &
                 std_logic'image(pmmu_reg_sel(0)) & ")"
                 severity note;
        end if;
      end if;
    end if;
  end process;

  -- Test stimulus
  stim_process: process
  begin
    -- Reset
    nReset <= '0';
    wait for 100 ns;
    nReset <= '1';

    -- Let the test run
    wait for 100 us;

    report "=== PMOVE SELECTOR TEST COMPLETE ===" severity note;
    report "Check selector sequence: should be 00010 (TT0), 00011 (TT1), 00010 (TT0), 00011 (TT1)" severity note;

    test_complete <= true;
    wait;
  end process;

end behavior;
