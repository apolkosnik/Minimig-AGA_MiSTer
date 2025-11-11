------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- MC68030 Transparent Translation                                         --
--                                                                          --
-- Checks TT0 and TT1 registers for MMU bypass                             --
--                                                                          --
-- Features:                                                                --
--   - TT0 and TT1 register matching                                       --
--   - Address and function code comparison with masks                     --
--   - Priority: TT0 checked first, then TT1                               --
--   - Returns cache inhibit flag if matched                               --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_TransparentTranslation is
    port(
        -- TT0 register (from PMOVE)
        tt0_reg     : in  std_logic_vector(31 downto 0);

        -- TT1 register (from PMOVE)
        tt1_reg     : in  std_logic_vector(31 downto 0);

        -- Address to check
        virt_addr   : in  std_logic_vector(31 downto 0);

        -- Function code
        fc          : in  std_logic_vector(2 downto 0);

        -- Supervisor mode (from SR)
        supervisor  : in  std_logic;

        -- Read/write access (0=read, 1=write)
        rw          : in  std_logic;

        -- Outputs
        tt_match    : out std_logic;                      -- Transparent translation matches
        tt_ci       : out std_logic;                      -- Cache inhibit
        tt_which    : out std_logic_vector(1 downto 0)  -- 00=none, 01=TT0, 10=TT1
    );
end entity TG68K030_TransparentTranslation;

architecture rtl of TG68K030_TransparentTranslation is

    -- TT register bit positions
    constant TT_ENABLE      : integer := 31;
    constant TT_SUPER_USER  : integer := 30;
    constant TT_CACHE_INH   : integer := 29;
    constant TT_RW          : integer := 28;

    -- TT0 fields
    signal tt0_enable       : std_logic;
    signal tt0_super_user   : std_logic;
    signal tt0_cache_inh    : std_logic;
    signal tt0_rw           : std_logic;
    signal tt0_log_addr     : std_logic_vector(7 downto 0);
    signal tt0_log_mask     : std_logic_vector(7 downto 0);
    signal tt0_fc_base      : std_logic_vector(3 downto 0);
    signal tt0_fc_mask      : std_logic_vector(3 downto 0);

    -- TT1 fields
    signal tt1_enable       : std_logic;
    signal tt1_super_user   : std_logic;
    signal tt1_cache_inh    : std_logic;
    signal tt1_rw           : std_logic;
    signal tt1_log_addr     : std_logic_vector(7 downto 0);
    signal tt1_log_mask     : std_logic_vector(7 downto 0);
    signal tt1_fc_base      : std_logic_vector(3 downto 0);
    signal tt1_fc_mask      : std_logic_vector(3 downto 0);

    -- Match signals
    signal tt0_matches      : std_logic;
    signal tt1_matches      : std_logic;

begin

    --------------------------------------------------------------
    -- Extract TT0 fields
    --------------------------------------------------------------
    tt0_enable     <= tt0_reg(TT_ENABLE);
    tt0_super_user <= tt0_reg(TT_SUPER_USER);
    tt0_cache_inh  <= tt0_reg(TT_CACHE_INH);
    tt0_rw         <= tt0_reg(TT_RW);
    tt0_log_addr   <= tt0_reg(23 downto 16);
    tt0_log_mask   <= tt0_reg(15 downto 8);
    tt0_fc_base    <= tt0_reg(7 downto 4);
    tt0_fc_mask    <= tt0_reg(3 downto 0);

    --------------------------------------------------------------
    -- Extract TT1 fields
    --------------------------------------------------------------
    tt1_enable     <= tt1_reg(TT_ENABLE);
    tt1_super_user <= tt1_reg(TT_SUPER_USER);
    tt1_cache_inh  <= tt1_reg(TT_CACHE_INH);
    tt1_rw         <= tt1_reg(TT_RW);
    tt1_log_addr   <= tt1_reg(23 downto 16);
    tt1_log_mask   <= tt1_reg(15 downto 8);
    tt1_fc_base    <= tt1_reg(7 downto 4);
    tt1_fc_mask    <= tt1_reg(3 downto 0);

    --------------------------------------------------------------
    -- TT0 Matching Logic
    --------------------------------------------------------------
    tt0_match_proc: process(tt0_enable, tt0_super_user, tt0_rw,
                            tt0_log_addr, tt0_log_mask,
                            tt0_fc_base, tt0_fc_mask,
                            virt_addr, fc, supervisor, rw)
        variable addr_match : std_logic;
        variable fc_match   : std_logic;
        variable mode_match : std_logic;
        variable rw_match   : std_logic;
    begin
        tt0_matches <= '0';

        -- Check if enabled
        if tt0_enable = '0' then
            return;
        end if;

        -- Check supervisor/user mode
        mode_match := '0';
        if (tt0_super_user = '1' and supervisor = '1') or
           (tt0_super_user = '0' and supervisor = '0') then
            mode_match := '1';
        end if;

        if mode_match = '0' then
            return;
        end if;

        -- Check read/write
        rw_match := '0';
        if tt0_rw = '0' then
            -- Read-only: match only if read
            if rw = '0' then
                rw_match := '1';
            end if;
        else
            -- Read/write: match both
            rw_match := '1';
        end if;

        if rw_match = '0' then
            return;
        end if;

        -- Check address match (with mask)
        addr_match := '1';
        for i in 0 to 7 loop
            if tt0_log_mask(i) = '1' then
                if virt_addr(24 + i) /= tt0_log_addr(i) then
                    addr_match := '0';
                    exit;
                end if;
            end if;
        end loop;

        if addr_match = '0' then
            return;
        end if;

        -- Check function code match (with mask)
        fc_match := '1';
        for i in 0 to 2 loop
            if tt0_fc_mask(i) = '1' then
                if fc(i) /= tt0_fc_base(i) then
                    fc_match := '0';
                    exit;
                end if;
            end if;
        end loop;

        -- All checks passed
        tt0_matches <= addr_match and fc_match;
    end process;

    --------------------------------------------------------------
    -- TT1 Matching Logic
    --------------------------------------------------------------
    tt1_match_proc: process(tt1_enable, tt1_super_user, tt1_rw,
                            tt1_log_addr, tt1_log_mask,
                            tt1_fc_base, tt1_fc_mask,
                            virt_addr, fc, supervisor, rw)
        variable addr_match : std_logic;
        variable fc_match   : std_logic;
        variable mode_match : std_logic;
        variable rw_match   : std_logic;
    begin
        tt1_matches <= '0';

        -- Check if enabled
        if tt1_enable = '0' then
            return;
        end if;

        -- Check supervisor/user mode
        mode_match := '0';
        if (tt1_super_user = '1' and supervisor = '1') or
           (tt1_super_user = '0' and supervisor = '0') then
            mode_match := '1';
        end if;

        if mode_match = '0' then
            return;
        end if;

        -- Check read/write
        rw_match := '0';
        if tt1_rw = '0' then
            -- Read-only: match only if read
            if rw = '0' then
                rw_match := '1';
            end if;
        else
            -- Read/write: match both
            rw_match := '1';
        end if;

        if rw_match = '0' then
            return;
        end if;

        -- Check address match (with mask)
        addr_match := '1';
        for i in 0 to 7 loop
            if tt1_log_mask(i) = '1' then
                if virt_addr(24 + i) /= tt1_log_addr(i) then
                    addr_match := '0';
                    exit;
                end if;
            end if;
        end loop;

        if addr_match = '0' then
            return;
        end if;

        -- Check function code match (with mask)
        fc_match := '1';
        for i in 0 to 2 loop
            if tt1_fc_mask(i) = '1' then
                if fc(i) /= tt1_fc_base(i) then
                    fc_match := '0';
                    exit;
                end if;
            end if;
        end loop;

        -- All checks passed
        tt1_matches <= addr_match and fc_match;
    end process;

    --------------------------------------------------------------
    -- Output Logic (Priority: TT0 > TT1)
    --------------------------------------------------------------
    output_proc: process(tt0_matches, tt1_matches, tt0_cache_inh, tt1_cache_inh)
    begin
        if tt0_matches = '1' then
            tt_match <= '1';
            tt_ci    <= tt0_cache_inh;
            tt_which <= "01";  -- TT0
        elsif tt1_matches = '1' then
            tt_match <= '1';
            tt_ci    <= tt1_cache_inh;
            tt_which <= "10";  -- TT1
        else
            tt_match <= '0';
            tt_ci    <= '0';
            tt_which <= "00";  -- None
        end if;
    end process;

end architecture rtl;
