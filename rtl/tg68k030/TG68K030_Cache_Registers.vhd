------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2025 MC68030 Implementation Team                          --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- MC68030 Cache Control Registers Module                                  --
--                                                                          --
-- This module implements the MC68030 cache control registers:             --
-- - CACR (Cache Control Register) - enhanced from 68020                   --
-- - CAAR (Cache Address Register) - new in 68030                          --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify--
-- it under the terms of the GNU Lesser General Public License as published--
-- by the Free Software Foundation, either version 3 of the License, or    --
-- (at your option) any later version.                                     --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K030_Cache_Registers is
    port(
        -- Clock and reset
        clk         : in std_logic;
        reset       : in std_logic;

        -- CPU status
        supervisor  : in std_logic;  -- 1=supervisor mode, 0=user mode

        -- Register access interface
        reg_select  : in std_logic_vector(1 downto 0);  -- 00=none, 01=CACR, 10=CAAR
        reg_write   : in std_logic;                     -- Write enable
        reg_read    : in std_logic;                     -- Read enable
        data_in     : in std_logic_vector(31 downto 0); -- Write data
        data_out    : out std_logic_vector(31 downto 0);-- Read data

        -- Privilege violation
        priv_violation : out std_logic;                 -- Access from user mode

        -- CACR outputs (for cache control logic)
        cacr_ei     : out std_logic;  -- Enable instruction cache
        cacr_fi     : out std_logic;  -- Freeze instruction cache
        cacr_ci     : out std_logic;  -- Clear instruction cache (pulse)
        cacr_cei    : out std_logic;  -- Clear instruction cache entry (pulse)
        cacr_ibe    : out std_logic;  -- Instruction burst enable
        cacr_ed     : out std_logic;  -- Enable data cache
        cacr_fd     : out std_logic;  -- Freeze data cache
        cacr_cd     : out std_logic;  -- Clear data cache (pulse)
        cacr_cde    : out std_logic;  -- Clear data cache entry (pulse)
        cacr_dbe    : out std_logic;  -- Data burst enable
        cacr_wa     : out std_logic;  -- Write allocate

        -- CAAR output
        caar_addr   : out std_logic_vector(31 downto 0)  -- Cache address
    );
end entity TG68K030_Cache_Registers;

architecture rtl of TG68K030_Cache_Registers is

    -- Register select codes
    constant SEL_NONE : std_logic_vector(1 downto 0) := "00";
    constant SEL_CACR : std_logic_vector(1 downto 0) := "01";
    constant SEL_CAAR : std_logic_vector(1 downto 0) := "10";

    -- CACR bit positions
    constant CACR_EI  : integer := 0;   -- Enable instruction cache
    constant CACR_FI  : integer := 1;   -- Freeze instruction cache
    constant CACR_CEI : integer := 2;   -- Clear instruction cache entry
    constant CACR_CI  : integer := 3;   -- Clear instruction cache
    constant CACR_IBE : integer := 4;   -- Instruction burst enable
    constant CACR_ED  : integer := 8;   -- Enable data cache
    constant CACR_FD  : integer := 9;   -- Freeze data cache
    constant CACR_CDE : integer := 10;  -- Clear data cache entry
    constant CACR_CD  : integer := 11;  -- Clear data cache
    constant CACR_DBE : integer := 12;  -- Data burst enable
    constant CACR_WA  : integer := 13;  -- Write allocate

    -- Cache Control Register - storage for persistent bits
    signal cacr_reg : std_logic_vector(31 downto 0);

    -- Cache Address Register
    signal caar_reg : std_logic_vector(31 downto 0);

    -- Self-clearing pulse signals (for CI, CEI, CD, CDE)
    signal clear_icache       : std_logic;
    signal clear_icache_entry : std_logic;
    signal clear_dcache       : std_logic;
    signal clear_dcache_entry : std_logic;

begin

    -- Output CACR control bits
    cacr_ei  <= cacr_reg(CACR_EI);
    cacr_fi  <= cacr_reg(CACR_FI);
    cacr_ibe <= cacr_reg(CACR_IBE);
    cacr_ed  <= cacr_reg(CACR_ED);
    cacr_fd  <= cacr_reg(CACR_FD);
    cacr_dbe <= cacr_reg(CACR_DBE);
    cacr_wa  <= cacr_reg(CACR_WA);

    -- Output self-clearing pulses
    cacr_ci  <= clear_icache;
    cacr_cei <= clear_icache_entry;
    cacr_cd  <= clear_dcache;
    cacr_cde <= clear_dcache_entry;

    -- Output CAAR
    caar_addr <= caar_reg;

    -- Privilege check: all cache registers are supervisor only
    priv_violation <= (reg_write or reg_read) and (not supervisor);

    --------------------------------------------------------------
    -- Register write process
    --------------------------------------------------------------
    process(clk, reset)
    begin
        if reset = '1' then
            -- Reset CACR to default (both caches disabled)
            cacr_reg <= (others => '0');

            -- Reset CAAR
            caar_reg <= (others => '0');

            -- Clear pulses
            clear_icache       <= '0';
            clear_icache_entry <= '0';
            clear_dcache       <= '0';
            clear_dcache_entry <= '0';

        elsif rising_edge(clk) then

            -- Default: clear the self-clearing pulses
            clear_icache       <= '0';
            clear_icache_entry <= '0';
            clear_dcache       <= '0';
            clear_dcache_entry <= '0';

            -- Register write (only if supervisor mode)
            if reg_write = '1' and supervisor = '1' then

                case reg_select is

                    when SEL_CACR =>
                        -- Write CACR
                        -- Persistent bits (R/W)
                        cacr_reg(CACR_EI)  <= data_in(CACR_EI);   -- Enable I-cache
                        cacr_reg(CACR_FI)  <= data_in(CACR_FI);   -- Freeze I-cache
                        cacr_reg(CACR_IBE) <= data_in(CACR_IBE);  -- I-burst enable
                        cacr_reg(CACR_ED)  <= data_in(CACR_ED);   -- Enable D-cache
                        cacr_reg(CACR_FD)  <= data_in(CACR_FD);   -- Freeze D-cache
                        cacr_reg(CACR_DBE) <= data_in(CACR_DBE);  -- D-burst enable
                        cacr_reg(CACR_WA)  <= data_in(CACR_WA);   -- Write allocate

                        -- Self-clearing bits (write-only, trigger pulses)
                        if data_in(CACR_CI) = '1' then
                            clear_icache <= '1';  -- Pulse for one cycle
                        end if;

                        if data_in(CACR_CEI) = '1' then
                            clear_icache_entry <= '1';  -- Pulse for one cycle
                        end if;

                        if data_in(CACR_CD) = '1' then
                            clear_dcache <= '1';  -- Pulse for one cycle
                        end if;

                        if data_in(CACR_CDE) = '1' then
                            clear_dcache_entry <= '1';  -- Pulse for one cycle
                        end if;

                        -- Reserved bits forced to 0 (bits 5-7, 14-31)
                        cacr_reg(7 downto 5)   <= (others => '0');
                        cacr_reg(31 downto 14) <= (others => '0');

                    when SEL_CAAR =>
                        -- Write CAAR - simple 32-bit address
                        caar_reg <= data_in;

                    when others =>
                        -- No register selected
                        null;

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------
    -- Register read process (combinational)
    --------------------------------------------------------------
    process(reg_select, reg_read, supervisor, cacr_reg, caar_reg)
        variable cacr_read : std_logic_vector(31 downto 0);
    begin
        -- Default output
        data_out <= (others => '0');

        -- Register read (only if supervisor mode)
        if reg_read = '1' and supervisor = '1' then
            case reg_select is

                when SEL_CACR =>
                    -- Read CACR
                    -- Self-clearing bits (CI, CEI, CD, CDE) always read as 0
                    cacr_read := (others => '0');
                    cacr_read(CACR_EI)  := cacr_reg(CACR_EI);
                    cacr_read(CACR_FI)  := cacr_reg(CACR_FI);
                    -- CEI (bit 2) reads as 0 (self-clearing)
                    -- CI (bit 3) reads as 0 (self-clearing)
                    cacr_read(CACR_IBE) := cacr_reg(CACR_IBE);
                    cacr_read(CACR_ED)  := cacr_reg(CACR_ED);
                    cacr_read(CACR_FD)  := cacr_reg(CACR_FD);
                    -- CDE (bit 10) reads as 0 (self-clearing)
                    -- CD (bit 11) reads as 0 (self-clearing)
                    cacr_read(CACR_DBE) := cacr_reg(CACR_DBE);
                    cacr_read(CACR_WA)  := cacr_reg(CACR_WA);
                    -- Reserved bits read as 0
                    data_out <= cacr_read;

                when SEL_CAAR =>
                    -- Read CAAR
                    data_out <= caar_reg;

                when others =>
                    -- Invalid register
                    data_out <= (others => '0');

            end case;
        end if;
    end process;

end architecture rtl;
