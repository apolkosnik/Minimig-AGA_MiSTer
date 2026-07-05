-- tb_cache_ctrl_030.vhd
-- Controller-level regression for 68030 cache hits while the PMMU is busy.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cache_ctrl_030 is
end tb_cache_ctrl_030;

architecture behavior of tb_cache_ctrl_030 is
  constant clk_period : time := 10 ns;

  signal clk                : std_logic := '0';
  signal nreset             : std_logic := '0';
  signal test_running       : boolean := true;

  signal busstate           : std_logic_vector(1 downto 0) := "01";
  signal fc                 : std_logic_vector(2 downto 0) := "010";
  signal uds_n              : std_logic := '0';
  signal lds_n              : std_logic := '0';
  signal cpu_data_write     : std_logic_vector(15 downto 0) := (others => '0');

  signal pmmu_addr_log      : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_addr_phys     : std_logic_vector(31 downto 0) := (others => '0');
  signal pmmu_cache_inhibit : std_logic := '0';
  signal pmmu_busy          : std_logic := '0';
  signal pmmu_fault         : std_logic := '0';
  signal pmmu_walker_req    : std_logic := '0';
  signal walker_active      : std_logic := '0';

  signal cache_data         : std_logic_vector(15 downto 0) := (others => '0');
  signal cache_ack          : std_logic := '0';
  signal cache_req          : std_logic;
  signal cache_addr         : std_logic_vector(31 downto 0);
  signal cache_burst        : std_logic;
  signal cache_burst_len    : std_logic_vector(2 downto 0);
  signal cache_ramaddr      : std_logic_vector(28 downto 1);
  signal cache_hit          : std_logic;
  signal cache_miss         : std_logic;
  signal cache_data_out_16  : std_logic_vector(15 downto 0);

  procedure wait_cycles(signal clk_i : in std_logic; count : integer) is
  begin
    for i in 1 to count loop
      wait until rising_edge(clk_i);
    end loop;
  end procedure;

begin
  uut: entity work.TG68K_CacheCtrl_030
    port map(
      clk                 => clk,
      nreset              => nreset,
      cpu_030             => '1',
      busstate            => busstate,
      fc                  => fc,
      uds_n               => uds_n,
      lds_n               => lds_n,
      cpu_data_write      => cpu_data_write,
      pmmu_addr_log       => pmmu_addr_log,
      pmmu_addr_phys      => pmmu_addr_phys,
      pmmu_cache_inhibit  => pmmu_cache_inhibit,
      pmmu_busy           => pmmu_busy,
      pmmu_fault          => pmmu_fault,
      pmmu_walker_req     => pmmu_walker_req,
      walker_active       => walker_active,
      z3ram_base0         => "01000",
      z3ram_base1         => "0100",
      z3ram_ena0          => '1',
      z3ram_ena1          => '0',
      z2ram_ena           => '1',
      cacr_ie             => '1',
      cacr_de             => '1',
      cacr_ibe            => '1',
      cacr_dbe            => '1',
      cacr_ifreeze        => '0',
      cacr_dfreeze        => '0',
      cacr_wa             => '0',
      cache_inv_req       => '0',
      cache_op_scope      => "00",
      cache_op_cache      => "00",
      cache_op_addr       => (others => '0'),
      dma_snoop_req       => '0',
      dma_snoop_addr      => (others => '0'),
      cache_data          => cache_data,
      cache_ack           => cache_ack,
      cache_req           => cache_req,
      cache_addr          => cache_addr,
      cache_burst         => cache_burst,
      cache_burst_len     => cache_burst_len,
      cache_ramaddr       => cache_ramaddr,
      cache_hit           => cache_hit,
      cache_miss          => cache_miss,
      cache_data_out_16   => cache_data_out_16
    );

  clk_process: process
  begin
    while test_running loop
      clk <= '0';
      wait for clk_period / 2;
      clk <= '1';
      wait for clk_period / 2;
    end loop;
    wait;
  end process;

  -- Simple burst source. The controller owns address sequencing internally for
  -- the cache line; the data value only needs to be stable and non-X.
  mem_process: process(clk)
    variable word_count : unsigned(3 downto 0) := (others => '0');
  begin
    if rising_edge(clk) then
      if nreset = '0' then
        cache_ack <= '0';
        cache_data <= (others => '0');
        word_count := (others => '0');
      elsif cache_req = '1' then
        cache_ack <= '1';
        cache_data <= std_logic_vector(unsigned(cache_addr(15 downto 0)) + resize(word_count, 16));
        word_count := word_count + 1;
      else
        cache_ack <= '0';
        word_count := (others => '0');
      end if;
    end if;
  end process;

  stim_proc: process
    variable w0 : std_logic_vector(15 downto 0);
    variable w1 : std_logic_vector(15 downto 0);
  begin
    nreset <= '0';
    wait_cycles(clk, 4);
    nreset <= '1';
    wait_cycles(clk, 4);

    -- Prime an instruction line with translation complete.
    fc <= "010";
    busstate <= "00";
    pmmu_addr_log <= x"00001000";
    pmmu_addr_phys <= x"10001000";
    pmmu_busy <= '0';
    wait_cycles(clk, 24);
    wait for 1 ns;
    assert cache_hit = '1'
      report "I-cache line did not prime" severity failure;

    -- The same logical/FC access must hit while PMMU is busy. This is the
    -- performance-critical TC.E=1 case: a hit must not wait for the walker.
    pmmu_busy <= '1';
    pmmu_addr_phys <= x"20001000";
    wait_cycles(clk, 2);
    wait for 1 ns;
    assert cache_hit = '1'
      report "I-cache hit was blocked by pmmu_busy" severity failure;
    assert cache_req = '0'
      report "I-cache hit launched an external fill while pmmu_busy" severity failure;

    -- A miss while PMMU is busy must not fill using stale physical/CI state.
    pmmu_addr_log <= x"00001100";
    wait_cycles(clk, 2);
    wait for 1 ns;
    assert cache_hit = '0'
      report "I-cache unexpected hit on different logical line" severity failure;
    assert cache_req = '0'
      report "I-cache miss launched fill before translation completed" severity failure;

    -- Prime a data line and repeat the same busy-hit check for data reads.
    pmmu_busy <= '0';
    busstate <= "10";
    fc <= "001";
    pmmu_addr_log <= x"00002000";
    pmmu_addr_phys <= x"10002000";
    wait_cycles(clk, 24);
    wait for 1 ns;
    assert cache_hit = '1'
      report "D-cache line did not prime" severity failure;

    pmmu_busy <= '1';
    pmmu_addr_phys <= x"20002000";
    wait_cycles(clk, 2);
    wait for 1 ns;
    assert cache_hit = '1'
      report "D-cache hit was blocked by pmmu_busy" severity failure;
    assert cache_req = '0'
      report "D-cache hit launched an external fill while pmmu_busy" severity failure;

    pmmu_addr_log <= x"00002100";
    wait_cycles(clk, 2);
    wait for 1 ns;
    assert cache_hit = '0'
      report "D-cache unexpected hit on different logical line" severity failure;
    assert cache_req = '0'
      report "D-cache miss launched fill before translation completed" severity failure;

    -- ============================================================
    -- Byte-lane regression: odd-byte (addr+1) and offset-3 (addr+3) data
    -- accesses. The controller routes byte/word data through
    -- pmmu_addr_log(1:0):
    --   off "00" -> d_cache_data_out(15:0)   (bytes addr+0 hi, addr+1 lo)
    --   off "10" -> d_cache_data_out(31:16)  (bytes addr+2 hi, addr+3 lo)
    -- So a byte read at off "01" must equal the low byte of the off-"00"
    -- word, and off "11" must equal the low byte of the off-"10" word.
    -- ============================================================
    pmmu_busy <= '0';
    busstate <= "10";
    fc <= "001";
    pmmu_addr_log <= x"00003000";
    pmmu_addr_phys <= x"10003000";
    wait_cycles(clk, 24);
    wait for 1 ns;
    assert cache_hit = '1'
      report "Byte-lane: data line did not prime" severity failure;

    -- Capture the two 16-bit halves (offsets 00 and 10) of the longword.
    pmmu_addr_log <= x"00003000";  -- offset 00
    wait_cycles(clk, 1);
    wait for 1 ns;
    w0 := cache_data_out_16;
    pmmu_addr_log <= x"00003002";  -- offset 10
    wait_cycles(clk, 1);
    wait for 1 ns;
    w1 := cache_data_out_16;

    -- Byte addr+1 must be the low byte of the offset-00 word.
    pmmu_addr_log <= x"00003001";  -- offset 01
    wait_cycles(clk, 1);
    wait for 1 ns;
    assert cache_data_out_16 = (x"00" & w0(7 downto 0))
      report "Byte-lane: offset-01 read returned wrong byte" severity failure;

    -- Byte addr+3 must be the low byte of the offset-10 word.
    pmmu_addr_log <= x"00003003";  -- offset 11
    wait_cycles(clk, 1);
    wait for 1 ns;
    assert cache_data_out_16 = (x"00" & w1(7 downto 0))
      report "Byte-lane: offset-11 read returned wrong byte" severity failure;

    -- Write-lane check: store a distinct byte at addr+3 (odd byte -> lds),
    -- then read it back at offset 11. The old be/data_in lanes dropped this
    -- write (enabled bits 31:24 via uds, which an odd byte never asserts);
    -- the fix routes it to bits 23:16 via lds.
    busstate <= "11";              -- write cycle
    pmmu_addr_log <= x"00003003";  -- offset 11 (addr+3)
    uds_n <= '1';                  -- odd byte: upper strobe inactive
    lds_n <= '0';                  -- lower strobe active
    cpu_data_write <= x"005A";     -- byte $5A on D7:0
    wait_cycles(clk, 2);
    wait for 1 ns;
    busstate <= "10";              -- read back
    uds_n <= '0';
    lds_n <= '0';
    pmmu_addr_log <= x"00003003";
    wait_cycles(clk, 1);
    wait for 1 ns;
    assert cache_data_out_16 = x"005A"
      report "Byte-lane: offset-11 byte write/readback failed" severity failure;

    report "TG68K_CacheCtrl_030 PMMU-busy and byte-lane tests passed";
    test_running <= false;
    wait;
  end process;
end behavior;
