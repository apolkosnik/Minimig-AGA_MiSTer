-- tb_cache030_unit.vhd
-- Unit regression for the 030 L1 cache pair (TG68K_CacheCtrl_030 +
-- TG68K_Cache_030), driven directly with no CPU. Covers the Phase 4 fixes:
--   BUG #449/#450 - D-cache byte-lane map (stores and read-hits, offsets 1/3)
--   BUG #451      - fill owner/address lock (I-miss mid-D-fill must not steal)
--   BUG #452      - pmmu_busy pulse mid-burst must not drop cache_req
--   BUG #455      - shared-IO window ($00DD4xxx) never hits or allocates
--   BUG #468      - freeze set mid-fill drops the completed line
--
-- The fill server acks 8 words back-to-back; word data is derived from the
-- byte address (f(a) = a mod 251) so every line and lane is distinguishable.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cache030_unit is
end entity;

architecture behavioral of tb_cache030_unit is

  constant CLK_PERIOD : time := 10 ns;
  signal clk    : std_logic := '0';
  signal nreset : std_logic := '0';
  signal test_done : boolean := false;

  signal busstate       : std_logic_vector(1 downto 0) := "01";
  signal fc             : std_logic_vector(2 downto 0) := "001";
  signal uds_n          : std_logic := '1';
  signal lds_n          : std_logic := '1';
  signal cpu_data_write : std_logic_vector(15 downto 0) := (others => '0');
  signal addr           : std_logic_vector(31 downto 0) := (others => '0');

  signal pmmu_cache_inhibit : std_logic := '0';
  signal pmmu_busy      : std_logic := '0';
  signal pmmu_fault     : std_logic := '0';
  signal pmmu_walker_req: std_logic := '0';
  signal walker_active  : std_logic := '0';

  signal cacr_ie        : std_logic := '0';
  signal cacr_de        : std_logic := '0';
  signal cacr_ifreeze   : std_logic := '0';
  signal cacr_dfreeze   : std_logic := '0';

  signal cache_data     : std_logic_vector(15 downto 0) := (others => '0');
  signal cache_ack      : std_logic := '0';
  signal cache_req      : std_logic;
  signal cache_addr     : std_logic_vector(31 downto 0);
  signal cache_burst    : std_logic;
  signal cache_burst_len: std_logic_vector(2 downto 0);
  signal cache_ramaddr  : std_logic_vector(28 downto 1);

  signal cache_hit      : std_logic;
  signal cache_miss     : std_logic;
  signal cache_data_out_16 : std_logic_vector(15 downto 0);

  signal serve_enable   : std_logic := '1';
  signal req_drop_seen  : std_logic := '0';
  signal watch_req      : std_logic := '0';

  signal errors : integer := 0;

  function slv_hex(value : std_logic_vector) return string is
    constant hex_chars : string := "0123456789ABCDEF";
    variable result : string(1 to value'length/4);
    variable v : std_logic_vector(value'length - 1 downto 0);
    variable nib : std_logic_vector(3 downto 0);
  begin
    v := value;
    for i in 0 to (v'length/4 - 1) loop
      nib := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
      result(i+1) := hex_chars(to_integer(unsigned(nib)) + 1);
    end loop;
    return result;
  end function;

  function f_byte(a : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(a mod 251, 8));
  end function;

  function f_word(a : integer) return std_logic_vector is
  begin
    return f_byte(a) & f_byte(a + 1);
  end function;

begin

  clk_gen: process
  begin
    while not test_done loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  uut: entity work.TG68K_CacheCtrl_030
    port map(
      clk                => clk,
      nreset             => nreset,
      cpu_030            => '1',
      busstate           => busstate,
      fc                 => fc,
      uds_n              => uds_n,
      lds_n              => lds_n,
      cpu_data_write     => cpu_data_write,
      pmmu_addr_log      => addr,
      pmmu_addr_phys     => addr,   -- identity translation for the bench
      pmmu_cache_inhibit => pmmu_cache_inhibit,
      pmmu_busy          => pmmu_busy,
      pmmu_fault         => pmmu_fault,
      pmmu_walker_req    => pmmu_walker_req,
      walker_active      => walker_active,
      z3ram_base0        => "00000",
      z3ram_base1        => "0000",
      z3ram_ena0         => '0',
      z3ram_ena1         => '0',
      z2ram_ena          => '1',
      cacr_ie            => cacr_ie,
      cacr_de            => cacr_de,
      cacr_ifreeze       => cacr_ifreeze,
      cacr_dfreeze       => cacr_dfreeze,
      cacr_wa            => '0',
      cache_inv_req      => '0',
      cache_op_scope     => "00",
      cache_op_cache     => "00",
      cache_op_addr      => (others => '0'),
      cache_data         => cache_data,
      cache_ack          => cache_ack,
      cache_req          => cache_req,
      cache_addr         => cache_addr,
      cache_burst        => cache_burst,
      cache_burst_len    => cache_burst_len,
      cache_ramaddr      => cache_ramaddr,
      cache_hit          => cache_hit,
      cache_miss         => cache_miss,
      cache_data_out_16  => cache_data_out_16
    );

  -- Fill server: on cache_req, latch the address (like Minimig's grant) and
  -- ack 8 words back-to-back from the f_word pattern.
  serve: process(clk)
    variable idx     : integer := 0;
    variable base    : integer := 0;
    variable running : boolean := false;
    variable dly     : integer := 0;
  begin
    if rising_edge(clk) then
      cache_ack <= '0';
      if not running then
        if cache_req = '1' and serve_enable = '1' then
          -- grant: latch address NOW (Minimig behavior)
          base := to_integer(unsigned(cache_addr(23 downto 0)));
          idx := 0;
          dly := 2;
          running := true;
          report "SERVE grant base=" & integer'image(base) severity note;
        end if;
      else
        if dly > 0 then
          dly := dly - 1;
        elsif idx < 8 then
          cache_ack  <= '1';
          cache_data <= f_word(base + idx*2);
          idx := idx + 1;
        else
          running := false;
        end if;
      end if;
    end if;
  end process;

  -- BUG #452 watch: cache_req must never drop while a burst is in flight
  watch: process(clk)
  begin
    if rising_edge(clk) then
      if watch_req = '1' and cache_req = '0' then
        req_drop_seen <= '1';
      end if;
    end if;
  end process;

  main: process
    variable exp : std_logic_vector(15 downto 0);

    procedure step(n : integer) is
    begin
      for i in 1 to n loop
        wait until rising_edge(clk);
      end loop;
      wait for 1 ns;
    end procedure;

    procedure idle_bus is
    begin
      busstate <= "01"; uds_n <= '1'; lds_n <= '1';
    end procedure;

    procedure fail(msg : string) is
    begin
      report "[FAIL] " & msg severity error;
      errors <= errors + 1;
      wait for 0 ns;
    end procedure;

    procedure pass(msg : string) is
    begin
      report "[PASS] " & msg severity note;
    end procedure;

    -- Present a D-read and wait until it hits (fills on miss); check data.
    procedure d_read_check(a : integer; expd : std_logic_vector(15 downto 0);
                           msg : string) is
      variable tout : integer := 0;
    begin
      addr <= std_logic_vector(to_unsigned(a, 32));
      busstate <= "10"; fc <= "001";
      if (a mod 2) = 0 then uds_n <= '0'; lds_n <= '0';
      else uds_n <= '1'; lds_n <= '0'; end if;
      wait for 1 ns;
      tout := 0;
      while cache_hit /= '1' and tout < 100 loop
        step(1);
        tout := tout + 1;
      end loop;
      if cache_hit /= '1' then
        fail(msg & ": no hit within 100 cycles");
      elsif cache_data_out_16 /= expd then
        fail(msg & ": got $" & slv_hex(cache_data_out_16) & " expected $" & slv_hex(expd));
      else
        pass(msg);
      end if;
      idle_bus;
      step(2);
    end procedure;

  begin
    report "=== 030 CACHE UNIT REGRESSION (BUG #449/#450/#451/#452/#455/#468) ===" severity note;
    step(5);
    nreset <= '1';
    cacr_ie <= '1';
    cacr_de <= '1';
    step(3);

    ------------------------------------------------------------------
    -- BUG #449/#450: byte lanes. Line at $00280000.
    ------------------------------------------------------------------
    -- word read at +0 fills the line and returns word0
    d_read_check(16#280000#, f_word(16#280000#), "word read +0 (fill + hit)");
    d_read_check(16#280002#, f_word(16#280002#), "word read +2");
    -- odd byte reads (BUG #450): expect the ODD byte on bits 7:0
    d_read_check(16#280001#, x"00" & f_byte(16#280001#), "byte read +1 (odd lane)");
    d_read_check(16#280003#, x"00" & f_byte(16#280003#), "byte read +3 (odd lane)");
    d_read_check(16#280005#, x"00" & f_byte(16#280005#), "byte read +5 (odd lane, word1)");

    -- BUG #449: byte store at +3 (LDS only) must update the cached line
    addr <= std_logic_vector(to_unsigned(16#280003#, 32));
    busstate <= "11"; uds_n <= '1'; lds_n <= '0';
    cpu_data_write <= x"5555";
    step(2);
    idle_bus; cpu_data_write <= (others => '0');
    step(2);
    d_read_check(16#280003#, x"0055", "byte store +3 visible on read-hit");
    -- sibling byte +2 must be untouched
    d_read_check(16#280002#, f_byte(16#280002#) & x"55", "word +2 after byte store +3");

    -- byte store at +1
    addr <= std_logic_vector(to_unsigned(16#280001#, 32));
    busstate <= "11"; uds_n <= '1'; lds_n <= '0';
    cpu_data_write <= x"6666";
    step(2);
    idle_bus; cpu_data_write <= (others => '0');
    step(2);
    d_read_check(16#280001#, x"0066", "byte store +1 visible on read-hit");
    d_read_check(16#280000#, f_byte(16#280000#) & x"66", "word +0 after byte store +1");

    ------------------------------------------------------------------
    -- BUG #452: pmmu_busy pulse mid-burst must not drop cache_req
    ------------------------------------------------------------------
    addr <= std_logic_vector(to_unsigned(16#280100#, 32));
    busstate <= "10"; fc <= "001"; uds_n <= '0'; lds_n <= '0';
    -- wait for the request to arm, then watch it and pulse busy
    wait until cache_req = '1' for 500 ns;
    if cache_req /= '1' then
      fail("BUG #452 setup: fill request never armed");
    else
      watch_req <= '1';
      step(2);
      pmmu_busy <= '1';   -- ATC-miss gap of an unrelated next access
      step(2);
      pmmu_busy <= '0';
      wait until cache_req = '0' for 1 us;  -- burst completes, lock releases
      watch_req <= '0';
      if req_drop_seen = '1' then
        fail("BUG #452: cache_req dropped mid-burst on pmmu_busy pulse");
      else
        pass("BUG #452: cache_req held level-stable through busy pulse");
      end if;
    end if;
    idle_bus;
    step(2);
    d_read_check(16#280102#, f_word(16#280102#), "line filled correctly across busy pulse");

    ------------------------------------------------------------------
    -- BUG #451: I-miss arriving mid-D-fill must not steal the fill
    ------------------------------------------------------------------
    addr <= std_logic_vector(to_unsigned(16#280200#, 32));
    busstate <= "10"; fc <= "001"; uds_n <= '0'; lds_n <= '0';
    wait until cache_req = '1' for 500 ns;
    step(1);
    -- switch the front-end to an I-fetch miss at a DIFFERENT line while the
    -- D fill is in flight (this is what the released CPU pipeline does)
    addr <= std_logic_vector(to_unsigned(16#280300#, 32));
    busstate <= "00"; fc <= "010"; uds_n <= '0'; lds_n <= '0';
    wait until cache_req = '0' for 1 us;   -- D fill completes
    idle_bus;
    step(3);
    -- The D line must exist with D data; the I address must NOT hit yet
    -- (its own fill happens separately, from its own address).
    addr <= std_logic_vector(to_unsigned(16#280300#, 32));
    busstate <= "00"; fc <= "010";
    wait for 1 ns;
    if cache_hit = '1' then
      fail("BUG #451: I-cache hit immediately after D fill - D line committed under I tag");
    else
      pass("BUG #451: D fill not stolen by mid-burst I miss");
    end if;
    -- let the I fill run to completion and verify it fetched from $280300
    wait until cache_req = '0' for 2 us;
    step(3);
    wait for 1 ns;
    if cache_hit = '1' and cache_data_out_16 = f_word(16#280300#) then
      pass("BUG #451: I line filled from its own address");
    else
      fail("BUG #451: I line wrong after its own fill");
    end if;
    idle_bus;
    step(2);
    d_read_check(16#280200#, f_word(16#280200#), "D line intact after I fill");

    ------------------------------------------------------------------
    -- BUG #455: shared-IO window never hits or allocates
    ------------------------------------------------------------------
    addr <= std_logic_vector(to_unsigned(16#00DD4010#, 32));
    busstate <= "10"; fc <= "001"; uds_n <= '0'; lds_n <= '0';
    step(10);
    wait for 1 ns;
    if cache_hit = '1' then
      fail("BUG #455: shared-IO window access hit the cache");
    elsif cache_req = '1' then
      fail("BUG #455: shared-IO window access started a line fill");
    else
      pass("BUG #455: shared-IO window bypasses lookup and allocation");
    end if;
    idle_bus;
    step(2);

    ------------------------------------------------------------------
    -- BUG #468: freeze set mid-fill must drop the completed line
    ------------------------------------------------------------------
    addr <= std_logic_vector(to_unsigned(16#280400#, 32));
    busstate <= "10"; fc <= "001"; uds_n <= '0'; lds_n <= '0';
    wait until cache_req = '1' for 500 ns;
    step(2);
    cacr_dfreeze <= '1';                   -- freeze while burst in flight
    wait until cache_req = '0' for 1 us;   -- orphan fill completes
    idle_bus;
    step(3);
    cacr_dfreeze <= '0';
    step(2);
    addr <= std_logic_vector(to_unsigned(16#280400#, 32));
    busstate <= "10"; fc <= "001"; uds_n <= '0'; lds_n <= '0';
    wait for 1 ns;
    if cache_hit = '1' then
      fail("BUG #468: line committed although freeze was set during the fill");
    else
      pass("BUG #468: frozen mid-fill line dropped");
    end if;
    -- and after unfreeze the line fills normally
    d_read_check(16#280400#, f_word(16#280400#), "line refills after unfreeze");

    ------------------------------------------------------------------
    report "=== SUMMARY: errors=" & integer'image(errors) & " ===" severity note;
    if errors = 0 then
      report "RESULT: PASS (0 failures)" severity note;
    else
      report "RESULT: FAIL (" & integer'image(errors) & " failures)" severity error;
    end if;
    test_done <= true;
    wait;
  end process;

end architecture;
