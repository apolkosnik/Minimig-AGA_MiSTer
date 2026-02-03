-- Waveform-style testbench showing cycle-by-cycle behavior
-- Shows: addr, data_in, busstate, pmmu_reg_sel changes

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_waveform is
end tb_pmove_waveform;

architecture behavior of tb_pmove_waveform is

  signal clk : std_logic := '0';
  signal nReset : std_logic := '0';
  signal clkena_in : std_logic := '1';
  signal data_in : std_logic_vector(15 downto 0) := (others => '0');
  signal IPL : std_logic_vector(2 downto 0) := "111";
  signal IPL_autovector : std_logic := '0';
  signal CPU : std_logic_vector(1 downto 0) := "11";

  signal addr_out : std_logic_vector(31 downto 0);
  signal data_write : std_logic_vector(15 downto 0);
  signal nWr, nUDS, nLDS : std_logic;
  signal busstate : std_logic_vector(1 downto 0);
  signal nResetOut, FC_out : std_logic;
  signal FC : std_logic_vector(2 downto 0);
  signal pmmu_reg_sel : std_logic_vector(4 downto 0);
  signal pmmu_reg_re, pmmu_reg_we : std_logic;

  constant clk_period : time := 20 ns;
  signal test_complete : boolean := false;
  signal cycle_count : integer := 0;

  type rom_type is array (0 to 127) of std_logic_vector(15 downto 0);
  signal rom : rom_type := (
    0 => X"0000", 1 => X"1000", 2 => X"0000", 3 => X"0100",

    -- Simple test: just one PMOVE TT0,D0
    16 => X"F010",  -- PMOVE D0,...
    17 => X"0A00",  -- Ext: TT0(00010), RW=1, Dn=0
    18 => X"4E72",  -- STOP
    19 => X"2700",

    others => X"4E71"
  );

  function to_hex_char(val : std_logic_vector(3 downto 0)) return character is
  begin
    case val is
      when "0000" => return '0'; when "0001" => return '1';
      when "0010" => return '2'; when "0011" => return '3';
      when "0100" => return '4'; when "0101" => return '5';
      when "0110" => return '6'; when "0111" => return '7';
      when "1000" => return '8'; when "1001" => return '9';
      when "1010" => return 'A'; when "1011" => return 'B';
      when "1100" => return 'C'; when "1101" => return 'D';
      when "1110" => return 'E'; when "1111" => return 'F';
      when others => return 'X';
    end case;
  end function;

  function to_hex_string(val : std_logic_vector(15 downto 0)) return string is
  begin
    return to_hex_char(val(15 downto 12)) &
           to_hex_char(val(11 downto 8)) &
           to_hex_char(val(7 downto 4)) &
           to_hex_char(val(3 downto 0));
  end function;

begin
  uut: entity work.TG68KdotC_Kernel
    port map (
      clk => clk, nReset => nReset, clkena_in => clkena_in,
      data_in => data_in, IPL => IPL, IPL_autovector => IPL_autovector,
      CPU => CPU, addr_out => addr_out, data_write => data_write,
      nWr => nWr, nUDS => nUDS, nLDS => nLDS,
      busstate => busstate, nResetOut => nResetOut, FC => FC,
      pmmu_reg_sel => pmmu_reg_sel,
      pmmu_reg_re => pmmu_reg_re,
      pmmu_reg_we => pmmu_reg_we,
      pmmu_walker_req => open, pmmu_walker_ack => '0',
      pmmu_walker_addr => open, pmmu_walker_data => (others => '0'),
      cache_cinv_req => open, cache_cpush_req => open,
      cache_op_scope => open, cache_op_cache => open,
      cacr_ie => open, cacr_de => open,
      cacr_ifreeze => open, cacr_dfreeze => open,
      cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
      pmmu_reg_wdat => open, pmmu_reg_part => open,
      pmmu_addr_log => open, pmmu_addr_phys => open,
      pmmu_cache_inhibit => open, cache_op_addr => open,
      skipFetch => open, regin_out => open,
      CACR_out => open, VBR_out => open,
      longword => open, clr_berr => open,
      debug_SVmode => open, debug_preSVmode => open,
      debug_FlagsSR_S => open, debug_changeMode => open,
      debug_setopcode => open, debug_exec_directSR => open,
      debug_exec_to_SR => open
    );

  clk_process: process
  begin
    while not test_complete loop
      clk <= '0'; wait for clk_period/2;
      clk <= '1'; wait for clk_period/2;
    end loop;
    wait;
  end process;

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

  count_process: process(clk)
  begin
    if rising_edge(clk) then
      if nReset = '1' then
        cycle_count <= cycle_count + 1;
      end if;
    end if;
  end process;

  -- Waveform output: show key cycles around PMOVE
  monitor: process(clk)
    variable prev_sel : std_logic_vector(4 downto 0) := "UUUUU";
  begin
    if rising_edge(clk) then
      if nReset = '1' and cycle_count >= 25 and cycle_count <= 45 then
        report "CYC " & integer'image(cycle_count) &
               " | ADDR=$" & integer'image(to_integer(unsigned(addr_out(7 downto 0)))) &
               " | DATA=$" & to_hex_string(data_in) &
               " | BUS=" & std_logic'image(busstate(1)) & std_logic'image(busstate(0)) &
               " | SEL=" & integer'image(to_integer(unsigned(pmmu_reg_sel))) &
               " | RE=" & std_logic'image(pmmu_reg_re) &
               " | WE=" & std_logic'image(pmmu_reg_we)
               severity note;

        if pmmu_reg_sel /= prev_sel then
          report ">>> SELECTOR CHANGED: " &
                 integer'image(to_integer(unsigned(prev_sel))) &
                 " -> " & integer'image(to_integer(unsigned(pmmu_reg_sel)))
                 severity warning;
          prev_sel := pmmu_reg_sel;
        end if;
      end if;
    end if;
  end process;

  stim_process: process
  begin
    nReset <= '0'; wait for 100 ns;
    nReset <= '1'; wait for 5 us;
    test_complete <= true;
    wait;
  end process;

end behavior;
