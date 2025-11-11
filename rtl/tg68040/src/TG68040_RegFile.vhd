------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Control Register File                                           --
--                                                                          --
-- MC68040 Control Registers (MOVEC accessible)                            --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--
-- This module implements the MC68040 control register file including:
-- - Standard 68020 registers (SFC, DFC, USP, VBR, CACR)
-- - New 68040 registers (TC, ITT0/1, DTT0/1, MMUSR, URP, SRP)
-- - MOVEC instruction support
-- - Privilege checking
--
-- Version: 0.1 (Phase 1)
-- Date: 2025-11-11
--
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68040_Pack.all;

entity TG68040_RegFile is
    generic(
        -- CPU mode: "00"=68000, "01"=68010, "11"=68020, "10"=68040
        CPU_MODE : std_logic_vector(1 downto 0) := CPU_68040
    );
    port(
        -- Clock and reset
        clk            : in std_logic;
        reset          : in std_logic;

        -- Control
        supervisor     : in std_logic;                          -- Supervisor mode

        -- MOVEC interface
        movec_en       : in std_logic;                          -- MOVEC operation enable
        movec_write    : in std_logic;                          -- 1=write to register, 0=read from register
        movec_reg      : in std_logic_vector(11 downto 0);     -- Register selector
        movec_data_in  : in std_logic_vector(31 downto 0);     -- Data to write
        movec_data_out : out std_logic_vector(31 downto 0);    -- Data read
        movec_valid    : out std_logic;                         -- Register access valid
        movec_privilege_err : out std_logic;                    -- Privilege violation

        -- Direct register access (for internal use)
        cacr_out       : out std_logic_vector(31 downto 0);    -- CACR for cache control
        tc_out         : out std_logic_vector(31 downto 0);    -- TC for MMU
        itt0_out       : out std_logic_vector(31 downto 0);    -- ITT0 for MMU
        itt1_out       : out std_logic_vector(31 downto 0);    -- ITT1 for MMU
        dtt0_out       : out std_logic_vector(31 downto 0);    -- DTT0 for MMU
        dtt1_out       : out std_logic_vector(31 downto 0);    -- DTT1 for MMU
        vbr_out        : out std_logic_vector(31 downto 0);    -- VBR for exceptions

        -- MMU status (writable via MOVEC for some bits)
        mmusr_in       : in std_logic_vector(15 downto 0);     -- MMUSR from MMU
        mmusr_out      : out std_logic_vector(15 downto 0)     -- MMUSR output
    );
end TG68040_RegFile;

architecture rtl of TG68040_RegFile is

    -- Control registers
    signal reg_sfc   : std_logic_vector(2 downto 0);    -- Source Function Code
    signal reg_dfc   : std_logic_vector(2 downto 0);    -- Destination Function Code
    signal reg_usp   : std_logic_vector(31 downto 0);   -- User Stack Pointer
    signal reg_vbr   : std_logic_vector(31 downto 0);   -- Vector Base Register
    signal reg_cacr  : std_logic_vector(31 downto 0);   -- Cache Control Register
    signal reg_msp   : std_logic_vector(31 downto 0);   -- Master Stack Pointer
    signal reg_isp   : std_logic_vector(31 downto 0);   -- Interrupt Stack Pointer

    -- MC68040 specific registers
    signal reg_tc    : std_logic_vector(31 downto 0);   -- Translation Control
    signal reg_itt0  : std_logic_vector(31 downto 0);   -- Instruction Transparent Translation 0
    signal reg_itt1  : std_logic_vector(31 downto 0);   -- Instruction Transparent Translation 1
    signal reg_dtt0  : std_logic_vector(31 downto 0);   -- Data Transparent Translation 0
    signal reg_dtt1  : std_logic_vector(31 downto 0);   -- Data Transparent Translation 1
    signal reg_mmusr : std_logic_vector(15 downto 0);   -- MMU Status Register
    signal reg_urp   : std_logic_vector(31 downto 0);   -- User Root Pointer
    signal reg_srp   : std_logic_vector(31 downto 0);   -- Supervisor Root Pointer

    -- Internal signals
    signal is_68040  : boolean;
    signal reg_valid : std_logic;
    signal priv_err  : std_logic;

begin

    is_68040 <= is_68040_mode(CPU_MODE);

    -- Direct register outputs
    cacr_out  <= reg_cacr;
    tc_out    <= reg_tc;
    itt0_out  <= reg_itt0;
    itt1_out  <= reg_itt1;
    dtt0_out  <= reg_dtt0;
    dtt1_out  <= reg_dtt1;
    vbr_out   <= reg_vbr;
    mmusr_out <= reg_mmusr;

    -- Register operations
    process(clk, reset)
    begin
        if reset = '1' then
            -- Reset all control registers to default values
            reg_sfc   <= (others => '0');
            reg_dfc   <= (others => '0');
            reg_usp   <= (others => '0');
            reg_vbr   <= (others => '0');
            reg_cacr  <= (others => '0');
            reg_msp   <= (others => '0');
            reg_isp   <= (others => '0');

            -- 68040 registers
            reg_tc    <= (others => '0');
            reg_itt0  <= (others => '0');
            reg_itt1  <= (others => '0');
            reg_dtt0  <= (others => '0');
            reg_dtt1  <= (others => '0');
            reg_mmusr <= (others => '0');
            reg_urp   <= (others => '0');
            reg_srp   <= (others => '0');

            movec_data_out <= (others => '0');
            movec_valid <= '0';
            movec_privilege_err <= '0';

        elsif rising_edge(clk) then
            -- Default outputs
            movec_valid <= '0';
            movec_privilege_err <= '0';
            reg_valid <= '0';
            priv_err <= '0';

            -- Update MMUSR from MMU (ongoing status)
            reg_mmusr <= mmusr_in;

            -- Handle cache clear bits (CACR bits that auto-clear)
            -- These bits are write-only and clear themselves
            if reg_cacr(CACR_CI) = '1' then
                reg_cacr(CACR_CI) <= '0';  -- Clear I-cache bit auto-clears
            end if;
            if reg_cacr(CACR_CD) = '1' then
                reg_cacr(CACR_CD) <= '0';  -- Clear D-cache bit auto-clears
            end if;
            if reg_cacr(CACR_CIE) = '1' then
                reg_cacr(CACR_CIE) <= '0';  -- Clear I-cache entry bit auto-clears
            end if;
            if reg_cacr(CACR_CDE) = '1' then
                reg_cacr(CACR_CDE) <= '0';  -- Clear D-cache entry bit auto-clears
            end if;

            -- MOVEC operation
            if movec_en = '1' then
                reg_valid <= '1';
                movec_valid <= '1';

                -- All MOVEC operations require supervisor mode
                if supervisor = '0' then
                    priv_err <= '1';
                    movec_privilege_err <= '1';
                else
                    -- Read or write register based on movec_reg
                    case movec_reg is
                        -- Standard 68020 registers
                        when MOVEC_SFC =>
                            if movec_write = '1' then
                                reg_sfc <= movec_data_in(2 downto 0);
                            else
                                movec_data_out <= (31 downto 3 => '0') & reg_sfc;
                            end if;

                        when MOVEC_DFC =>
                            if movec_write = '1' then
                                reg_dfc <= movec_data_in(2 downto 0);
                            else
                                movec_data_out <= (31 downto 3 => '0') & reg_dfc;
                            end if;

                        when MOVEC_USP =>
                            if movec_write = '1' then
                                reg_usp <= movec_data_in;
                            else
                                movec_data_out <= reg_usp;
                            end if;

                        when MOVEC_VBR =>
                            if movec_write = '1' then
                                reg_vbr <= movec_data_in;
                            else
                                movec_data_out <= reg_vbr;
                            end if;

                        when MOVEC_CACR =>
                            if movec_write = '1' then
                                if is_68040 then
                                    -- 68040: 32-bit CACR
                                    reg_cacr <= movec_data_in;
                                else
                                    -- 68020: 16-bit CACR, upper bits reserved
                                    reg_cacr <= (31 downto 16 => '0') & movec_data_in(15 downto 0);
                                end if;
                            else
                                movec_data_out <= reg_cacr;
                            end if;

                        when MOVEC_MSP =>
                            if movec_write = '1' then
                                reg_msp <= movec_data_in;
                            else
                                movec_data_out <= reg_msp;
                            end if;

                        when MOVEC_ISP =>
                            if movec_write = '1' then
                                reg_isp <= movec_data_in;
                            else
                                movec_data_out <= reg_isp;
                            end if;

                        -- MC68040 specific registers
                        when MOVEC_TC =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_tc <= movec_data_in;
                                else
                                    movec_data_out <= reg_tc;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_ITT0 =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_itt0 <= movec_data_in;
                                else
                                    movec_data_out <= reg_itt0;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_ITT1 =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_itt1 <= movec_data_in;
                                else
                                    movec_data_out <= reg_itt1;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_DTT0 =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_dtt0 <= movec_data_in;
                                else
                                    movec_data_out <= reg_dtt0;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_DTT1 =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_dtt1 <= movec_data_in;
                                else
                                    movec_data_out <= reg_dtt1;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_MMUSR =>
                            if is_68040 then
                                if movec_write = '1' then
                                    -- MMUSR is mostly read-only, some bits writable for testing
                                    -- For now, make it read-only
                                    null;
                                else
                                    movec_data_out <= (31 downto 16 => '0') & reg_mmusr;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_URP =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_urp <= movec_data_in;
                                else
                                    movec_data_out <= reg_urp;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        when MOVEC_SRP =>
                            if is_68040 then
                                if movec_write = '1' then
                                    reg_srp <= movec_data_in;
                                else
                                    movec_data_out <= reg_srp;
                                end if;
                            else
                                reg_valid <= '0';
                                movec_valid <= '0';
                            end if;

                        -- Invalid register
                        when others =>
                            reg_valid <= '0';
                            movec_valid <= '0';
                            movec_data_out <= (others => '0');

                    end case;
                end if;
            end if;
        end if;
    end process;

end rtl;
