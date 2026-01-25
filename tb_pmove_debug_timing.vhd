-- Debug testbench to show Bug #47 fix timing
-- Monitors: getbrief, brief, pmmu_reg_sel, clkena_lw
-- Shows when selector latches relative to PMOVE execution

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_debug_timing is
end tb_pmove_debug_timing;

architecture behavior of tb_pmove_debug_timing is

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
  signal pmmu_reg_re : std_logic;

  constant clk_period : time := 20 ns;
  signal test_complete : boolean := false;
  signal cycle_count : integer := 0;

  -- Instruction ROM
  type rom_type is array (0 to 127) of std_logic_vector(15 downto 0);
  signal rom : rom_type := (
    -- Reset vector
    0 => X"0000", 1 => X"1000", 2 => X"0000", 3 => X"0100",

    -- Test: PMOVE TT0,D0
    16 => X"F010",  -- PMOVE D0,...
    17 => X"0A00",  -- Extension: P-reg=TT0(00010), RW=1(read), D/A=0, Reg=0
    18 => X"4E71",  -- NOP
    19 => X"4E71",  -- NOP

    -- Second PMOVE to show selector updates
    20 => X"F011",  -- PMOVE D1,...
    21 => X"0A01",  -- Extension: P-reg=TT0(00010), RW=1(read), D/A=0, Reg=1
    22 => X"4E71",  -- NOP

    -- Third PMOVE with different register
    23 => X"F012",  -- PMOVE D2,...
    24 => X"0B02",  -- Extension: P-reg=TT1(00011), RW=1(read), D/A=0, Reg=2
    25 => X"4E71",  -- NOP

    26 => X"4E72",  -- STOP
    27 => X"2700",

    others => X"4E71"
  );

begin
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
      pmmu_reg_re => pmmu_reg_re,
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

  -- Clock
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

  -- Memory
  mem_process: process(clk)
    variable addr_int : integer;
  begin
    if rising_edge(clk) then
      if busstate = "00" or busstate = "10" then
        addr_int := to_integer(unsigned(addr_out(7 downto 1)));
        if addr_int < rom'length then
          data_in <= rom(addr_int);
        else
          data_in <= X"4E71";
        end if;
      end if;
    end if;
  end process;

  -- Cycle counter
  count_process: process(clk)
  begin
    if rising_edge(clk) then
      if nReset = '1' then
        cycle_count <= cycle_count + 1;
      end if;
    end if;
  end process;

  -- Monitor - show selector changes and PMMU reads
  monitor: process(clk)
    variable prev_sel : std_logic_vector(4 downto 0) := "00000";
    variable prev_re : std_logic := '0';
  begin
    if rising_edge(clk) then
      if nReset = '1' then
        -- Report selector changes
        if pmmu_reg_sel /= prev_sel then
          report "CYCLE " & integer'image(cycle_count) &
                 ": SEL CHANGED: " &
                 integer'image(to_integer(unsigned(prev_sel))) &
                 " -> " & integer'image(to_integer(unsigned(pmmu_reg_sel))) &
                 " (binary: " &
                 std_logic'image(pmmu_reg_sel(4)) &
                 std_logic'image(pmmu_reg_sel(3)) &
                 std_logic'image(pmmu_reg_sel(2)) &
                 std_logic'image(pmmu_reg_sel(1)) &
                 std_logic'image(pmmu_reg_sel(0)) & ")"
                 severity note;
          prev_sel := pmmu_reg_sel;
        end if;

        -- Report PMMU register reads
        if pmmu_reg_re = '1' and prev_re = '0' then
          report "CYCLE " & integer'image(cycle_count) &
                 ": PMMU READ using SEL=" &
                 integer'image(to_integer(unsigned(pmmu_reg_sel)))
                 severity note;
        end if;
        prev_re := pmmu_reg_re;

        -- Report instruction fetches (F-line opcodes)
        if busstate = "00" and addr_out(7 downto 0) >= X"20" then
          if data_in(15 downto 8) = X"F0" then
            report "CYCLE " & integer'image(cycle_count) &
                   ": FETCH PMOVE opcode $" &
                   integer'image(to_integer(unsigned(data_in)))
                   severity note;
          elsif data_in(15 downto 12) = X"0" and data_in(9) = '1' then
            report "CYCLE " & integer'image(cycle_count) &
                   ": FETCH extension word $" &
                   integer'image(to_integer(unsigned(data_in))) &
                   " SEL=" & integer'image(to_integer(unsigned(data_in(14 downto 10))))
                   severity note;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Test stimulus
  stim_process: process
  begin
    nReset <= '0';
    wait for 100 ns;
    nReset <= '1';
    wait for 50 us;

    report "=== PMOVE SELECTOR TIMING TEST COMPLETE ===" severity note;
    report "Expected sequence:" severity note;
    report "  1. SEL changes to 00010 (TT0) before first PMMU READ" severity note;
    report "  2. PMMU READ with SEL=00010" severity note;
    report "  3. SEL stays 00010 for second PMOVE TT0,D1" severity note;
    report "  4. SEL changes to 00011 (TT1) before third PMMU READ" severity note;
    report "  5. PMMU READ with SEL=00011" severity note;

    test_complete <= true;
    wait;
  end process;

end behavior;
