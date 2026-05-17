-- TG68K_CacheCtrl_030.vhd
--
-- MC68030 cache controller wrapper for TG68K_Cache_030.  The cache storage,
-- CACR handling glue, logical-tag lookup, and line-fill accumulator live here
-- so cpu_wrapper.v only has to arbitrate the external fill bus.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_CacheCtrl_030 is
  port(
    clk                 : in  std_logic;
    nreset              : in  std_logic;

    cpu_030             : in  std_logic;
    busstate            : in  std_logic_vector(1 downto 0);
    fc                  : in  std_logic_vector(2 downto 0);
    uds_n               : in  std_logic;
    lds_n               : in  std_logic;
    cpu_data_write      : in  std_logic_vector(15 downto 0);

    pmmu_addr_log       : in  std_logic_vector(31 downto 0);
    pmmu_addr_phys      : in  std_logic_vector(31 downto 0);
    pmmu_cache_inhibit  : in  std_logic;
    pmmu_busy           : in  std_logic;
    pmmu_fault          : in  std_logic;
    pmmu_walker_req     : in  std_logic;
    walker_active       : in  std_logic;

    z3ram_base0         : in  std_logic_vector(4 downto 0);
    z3ram_base1         : in  std_logic_vector(3 downto 0);
    z3ram_ena0          : in  std_logic;
    z3ram_ena1          : in  std_logic;
    z2ram_ena           : in  std_logic;

    cacr_ie             : in  std_logic;
    cacr_de             : in  std_logic;
    cacr_ifreeze        : in  std_logic;
    cacr_dfreeze        : in  std_logic;
    cacr_wa             : in  std_logic;
    cache_inv_req       : in  std_logic;
    cache_op_scope      : in  std_logic_vector(1 downto 0);
    cache_op_cache      : in  std_logic_vector(1 downto 0);
    cache_op_addr       : in  std_logic_vector(31 downto 0);

    cache_data          : in  std_logic_vector(15 downto 0);
    cache_ack           : in  std_logic;
    cache_req           : out std_logic;
    cache_addr          : out std_logic_vector(31 downto 0);
    cache_burst         : out std_logic;
    cache_burst_len     : out std_logic_vector(2 downto 0);
    cache_ramaddr       : out std_logic_vector(28 downto 1);

    cache_hit           : out std_logic;
    cache_miss          : out std_logic;
    cache_data_out_16   : out std_logic_vector(15 downto 0)
  );
end TG68K_CacheCtrl_030;

architecture rtl of TG68K_CacheCtrl_030 is
  signal i_cache_req       : std_logic;
  signal i_cache_addr      : std_logic_vector(31 downto 0);
  signal i_cache_data      : std_logic_vector(31 downto 0);
  signal i_cache_hit       : std_logic;
  signal i_fill_req        : std_logic;
  signal i_fill_addr       : std_logic_vector(31 downto 0);
  signal i_fill_data       : std_logic_vector(127 downto 0);
  signal i_fill_valid      : std_logic;

  signal d_cache_req       : std_logic;
  signal d_cache_addr      : std_logic_vector(31 downto 0);
  signal d_cache_we        : std_logic;
  signal d_cache_data_in   : std_logic_vector(31 downto 0);
  signal d_cache_data_out  : std_logic_vector(31 downto 0);
  signal d_cache_hit       : std_logic;
  signal d_cache_be        : std_logic_vector(3 downto 0);
  signal d_fill_req        : std_logic;
  signal d_fill_addr       : std_logic_vector(31 downto 0);
  signal d_fill_data       : std_logic_vector(127 downto 0);
  signal d_fill_valid      : std_logic;

  signal cache_xlate_ready : std_logic;
  signal fill_inhibit      : std_logic;
  signal phys_fast_cacheable : std_logic;

  signal phys_z3ram0       : std_logic;
  signal phys_z3ram1       : std_logic;
  signal phys_z2ram        : std_logic;
  signal fill_z3ram0       : std_logic;
  signal fill_z3ram1       : std_logic;
  signal fill_z2ram        : std_logic;
  signal fill_zram         : std_logic;

  signal cache_addr_int    : std_logic_vector(31 downto 0);
  signal cache_req_int     : std_logic;
  signal cache_hit_int     : std_logic;

  signal fill_count        : unsigned(2 downto 0);
  signal fill_buffer       : std_logic_vector(127 downto 0);
  signal fill_active       : std_logic;
  signal fill_owner_i      : std_logic;
  signal fill_addr_latched : std_logic_vector(31 downto 0);
  signal fill_valid_r      : std_logic;
  signal fill_owner_r      : std_logic;
  signal fill_data_r       : std_logic_vector(127 downto 0);
  signal fill_pending_i    : std_logic;
  signal fill_pending_d    : std_logic;
  signal fill_start        : std_logic;
  signal fill_accept       : std_logic;
begin

  cache_inst: entity work.TG68K_Cache_030
    port map(
      clk             => clk,
      nreset          => nreset,
      cacr_ie         => cacr_ie,
      cacr_de         => cacr_de,
      cacr_ifreeze    => cacr_ifreeze,
      cacr_dfreeze    => cacr_dfreeze,
      cacr_wa         => cacr_wa,
      inv_req         => cache_inv_req,
      cache_op_scope  => cache_op_scope,
      cache_op_cache  => cache_op_cache,
      cache_op_addr   => cache_op_addr,

      i_addr          => i_cache_addr,
      i_addr_phys     => pmmu_addr_phys,
      i_fc            => fc,
      i_req           => i_cache_req,
      i_cache_inhibit => fill_inhibit,
      i_data          => i_cache_data,
      i_hit           => i_cache_hit,
      i_fill_req      => i_fill_req,
      i_fill_addr     => i_fill_addr,
      i_fill_data     => i_fill_data,
      i_fill_valid    => i_fill_valid,

      d_addr          => d_cache_addr,
      d_addr_phys     => pmmu_addr_phys,
      d_fc            => fc,
      d_req           => d_cache_req,
      d_we            => d_cache_we,
      d_cache_inhibit => fill_inhibit,
      d_data_in       => d_cache_data_in,
      d_data_out      => d_cache_data_out,
      d_be            => d_cache_be,
      d_hit           => d_cache_hit,
      d_fill_req      => d_fill_req,
      d_fill_addr     => d_fill_addr,
      d_fill_data     => d_fill_data,
      d_fill_valid    => d_fill_valid
    );

  i_cache_addr <= pmmu_addr_log;
  d_cache_addr <= pmmu_addr_log;

  cache_xlate_ready <= (not pmmu_busy) and (not pmmu_fault);

  -- WinUAE/68030 behavior: cache-inhibit controls allocation.  Existing hits
  -- still satisfy the access, so lookup requests are not gated by fill_inhibit.
  i_cache_req <= '1' when cpu_030 = '1' and cacr_ie = '1' and
                          busstate = "00" and cache_xlate_ready = '1'
                 else '0';
  d_cache_req <= '1' when cpu_030 = '1' and cacr_de = '1' and
                          (busstate = "10" or busstate = "11") and
                          cache_xlate_ready = '1'
                 else '0';
  d_cache_we <= '1' when busstate = "11" else '0';

  phys_z3ram0 <= '1' when pmmu_addr_phys(31 downto 27) = z3ram_base0 and
                          z3ram_ena0 = '1'
                 else '0';
  phys_z3ram1 <= '1' when pmmu_addr_phys(31 downto 28) = z3ram_base1 and
                          z3ram_ena1 = '1'
                 else '0';
  phys_z2ram  <= '1' when pmmu_addr_phys(31 downto 24) = x"00" and
                          (pmmu_addr_phys(23) xor (pmmu_addr_phys(22) or pmmu_addr_phys(21))) = '1' and
                          z2ram_ena = '1'
                 else '0';
  phys_fast_cacheable <= phys_z3ram0 or phys_z3ram1 or phys_z2ram;
  fill_inhibit <= pmmu_cache_inhibit or (not phys_fast_cacheable);

  with pmmu_addr_log(1 downto 0) select
    d_cache_data_in <= x"0000" & cpu_data_write       when "00",
                       x"000000" & cpu_data_write(7 downto 0) when "01",
                       cpu_data_write & x"0000"       when "10",
                       cpu_data_write(7 downto 0) & x"000000" when others;

  d_cache_be <= "00" & (not uds_n) & (not lds_n) when pmmu_addr_log(1 downto 0) = "00" else
                "000" & (not lds_n)              when pmmu_addr_log(1 downto 0) = "01" else
                (not uds_n) & (not lds_n) & "00" when pmmu_addr_log(1 downto 0) = "10" else
                (not uds_n) & "000";

  process(pmmu_addr_log, busstate, i_cache_data, d_cache_data_out)
  begin
    case pmmu_addr_log(1 downto 0) is
      when "00" =>
        if busstate = "00" then
          cache_data_out_16 <= i_cache_data(15 downto 0);
        else
          cache_data_out_16 <= d_cache_data_out(15 downto 0);
        end if;
      when "10" =>
        if busstate = "00" then
          cache_data_out_16 <= i_cache_data(31 downto 16);
        else
          cache_data_out_16 <= d_cache_data_out(31 downto 16);
        end if;
      when "01" =>
        cache_data_out_16 <= x"00" & d_cache_data_out(15 downto 8);
      when others =>
        cache_data_out_16 <= x"00" & d_cache_data_out(31 downto 24);
    end case;
  end process;

  cache_hit_int <= ((i_cache_hit and i_cache_req) or
                    (d_cache_hit and d_cache_req and (not d_cache_we))) and
                   (not pmmu_fault);
  cache_hit <= cache_hit_int;
  cache_miss <= (i_fill_req or d_fill_req) when cpu_030 = '1' else '0';

  fill_pending_i <= i_fill_req;
  fill_pending_d <= d_fill_req;

  cache_addr_int <= fill_addr_latched when fill_active = '1' else
                    i_fill_addr       when fill_pending_i = '1' else
                    d_fill_addr;
  cache_addr <= cache_addr_int;

  fill_z3ram0 <= '1' when cache_addr_int(31 downto 27) = z3ram_base0 and
                          z3ram_ena0 = '1'
                 else '0';
  fill_z3ram1 <= '1' when cache_addr_int(31 downto 28) = z3ram_base1 and
                          z3ram_ena1 = '1'
                 else '0';
  fill_z2ram  <= '1' when cache_addr_int(31 downto 24) = x"00" and
                          (cache_addr_int(23) xor (cache_addr_int(22) or cache_addr_int(21))) = '1' and
                          z2ram_ena = '1'
                 else '0';
  fill_zram <= fill_z3ram0 or fill_z3ram1 or fill_z2ram;

  cache_req_int <= fill_active or
                   ((fill_pending_i or fill_pending_d) and
                    (not pmmu_busy) and (not pmmu_fault) and
                    (not pmmu_walker_req) and (not walker_active) and fill_zram);
  cache_req <= cache_req_int;
  cache_burst <= cache_req_int;
  cache_burst_len <= "111";

  cache_ramaddr(28) <= fill_zram and (not fill_z3ram0);
  cache_ramaddr(27) <= fill_zram and ((not fill_z3ram1) or cache_addr_int(27));
  cache_ramaddr(26 downto 23) <= cache_addr_int(26 downto 23) when
                                 (fill_z3ram0 = '1' or fill_z3ram1 = '1') else
                                 "0000";
  cache_ramaddr(22 downto 1) <= cache_addr_int(22 downto 1);

  fill_start <= '1' when fill_active = '0' and cache_req_int = '1' and cache_ack = '1'
                else '0';
  fill_accept <= fill_active and cache_ack;

  process(clk)
  begin
    if rising_edge(clk) then
      if nreset = '0' then
        fill_count <= (others => '0');
        fill_buffer <= (others => '0');
        fill_active <= '0';
        fill_owner_i <= '0';
        fill_addr_latched <= (others => '0');
        fill_valid_r <= '0';
        fill_owner_r <= '0';
        fill_data_r <= (others => '0');
      else
        fill_valid_r <= '0';

        if fill_start = '1' then
          fill_active <= '1';
          fill_count <= (others => '0');
          fill_owner_i <= fill_pending_i;
          if fill_pending_i = '1' then
            fill_addr_latched <= i_fill_addr;
          else
            fill_addr_latched <= d_fill_addr;
          end if;
          fill_buffer(15 downto 0) <= cache_data;
        elsif fill_accept = '1' then
          case fill_count is
            when "000" =>
              fill_buffer(31 downto 16) <= cache_data;
            when "001" =>
              fill_buffer(47 downto 32) <= cache_data;
            when "010" =>
              fill_buffer(63 downto 48) <= cache_data;
            when "011" =>
              fill_buffer(79 downto 64) <= cache_data;
            when "100" =>
              fill_buffer(95 downto 80) <= cache_data;
            when "101" =>
              fill_buffer(111 downto 96) <= cache_data;
            when "110" =>
              fill_buffer(127 downto 112) <= cache_data;
              fill_data_r <= cache_data & fill_buffer(111 downto 0);
              fill_owner_r <= fill_owner_i;
              fill_valid_r <= '1';
              fill_active <= '0';
            when others =>
              null;
          end case;

          if fill_count < to_unsigned(7, fill_count'length) then
            fill_count <= fill_count + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  i_fill_data <= fill_data_r;
  i_fill_valid <= fill_valid_r and fill_owner_r;
  d_fill_data <= fill_data_r;
  d_fill_valid <= fill_valid_r and (not fill_owner_r);

end rtl;
