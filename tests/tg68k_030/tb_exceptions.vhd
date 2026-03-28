library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_exceptions is
end tb_exceptions;

architecture behavior of tb_exceptions is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal addr : std_logic_vector(31 downto 0);
  signal data_in : std_logic_vector(15 downto 0);
  signal data_out : std_logic_vector(15 downto 0);
  signal ds, r_w : std_logic;
  signal ipl : std_logic_vector(2 downto 0) := "111";
  signal berr : std_logic := '0';
  
  -- Memory
  type ram_type is array (0 to 4096) of std_logic_vector(15 downto 0);
  signal ram : ram_type := (others => x"0000");

begin
  
  -- Clock Generation
  clk <= not clk after 10 ns;

  -- DUT Instance
  cpu: entity work.TG68KdotC_Kernel
    port map (
      clk => clk,
      nReset => not reset,
      clkena_in => '1',
      addr_out => addr,
      data_in => data_in,
      data_write => data_out,
      -- nAS => open, -- Removed
      nUDS => ds, 
      nLDS => open, 
      nWr => r_w,
      IPL => "111",
      -- nDtack => open,
      berr => berr,
      
      -- PMMU Walker Inputs
      pmmu_walker_ack => '1', -- Active High or Low? Usually Ack is active high if "ack". Or low if "ndtack". 
                              -- Entity says "pmmu_walker_ack". Line 170.
                              -- I'll check TG68K usage. Usually it is active high for "ack".
                              -- But safely '1' (ack immediately) or '0' (wait)?
                              -- If the CPU doesn't do a table walk, it doesn't matter.
                              -- I'll drive '1' to avoid hanging if it accidentally tries?
                              -- Or '0'. If it's a "Wait for Ack" logic, '0' might hang it.
      pmmu_walker_data => (others => '0'),
      pmmu_walker_berr => '0',

      CPU => "10" -- 68030 mode
    );

  -- Logic Analyzer / Tracer
  process(clk)
    variable last_addr : std_logic_vector(31 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
       -- Debug Log Every 100ns or on change
       if now < 500 ns or (r_w'event or ds'event) then
          report "TIME=" & time'image(now) & 
                 " ADDR=" & to_hstring(addr) & 
                 " DATA_IN=" & to_hstring(data_in) &
                 " DATA_OUT=" & to_hstring(data_out) &
                 " RW=" & std_logic'image(r_w) & 
                 " DS=" & std_logic'image(ds) &
                 " BERR=" & std_logic'image(berr);
       end if;

       -- Log Writes
       if r_w = '0' and ds = '0' then -- Write Cycle
          report "WRITE @ " & to_hstring(addr) & " = " & to_hstring(data_out);
       end if;
       
       -- Log Bus Error
       if berr = '1' then
          report "BUS ERROR TRIGGERED @ " & to_hstring(addr);
       end if;
    end if;
  end process;

  -- Memory & Peripherals
  process(clk)
  begin
    if rising_edge(clk) then
       -- Initialize on Reset (First few cycles)
       if now < 20 ns then
           ram(0) <= x"0000"; ram(1) <= x"1000"; -- SSP
           ram(2) <= x"0000"; ram(3) <= x"0400"; -- PC = $400
           -- Bus Error Vector ($08) points to handler
           ram(4) <= x"0000"; ram(5) <= x"0600"; 
           
           -- Code at $400
           ram(512) <= x"4E71"; -- 400: NOP
           ram(513) <= x"4E71"; -- 402: NOP
           ram(514) <= x"2039"; -- 404: MOVE.L $12345678, D0
           ram(515) <= x"1234";
           ram(516) <= x"5678";
           
           -- Handler at $600 (Word Index 768)
           ram(768) <= x"4E73"; -- 600: RTE
       elsif r_w = '0' and ds = '0' then -- Write
           ram(to_integer(unsigned(addr(12 downto 1)))) <= data_out;
       end if;
    end if;
  end process;

  data_in <= ram(to_integer(unsigned(addr(12 downto 1))));
  
  -- Reset Logic
  process
  begin
     reset <= '1';
     wait for 100 ns;
     reset <= '0';
     wait;
  end process;

  -- Bus Error Logic
  process(clk)
  begin
     if rising_edge(clk) then
        if addr = x"12345678" then
            berr <= '1'; -- Trigger Bus Error
        else
            berr <= '0';
        end if;
     end if;
  end process;

end behavior;
