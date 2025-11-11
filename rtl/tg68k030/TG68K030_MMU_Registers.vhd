------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2025 MC68030 Implementation Team                          --
-- Based on TG68K by Tobias Gubener                                        --
--                                                                          --
-- MC68030 MMU Registers Module                                            --
--                                                                          --
-- This module implements the MC68030 MMU control registers:               --
-- - TC (Translation Control)                                              --
-- - TT0, TT1 (Transparent Translation)                                    --
-- - CRP, SRP (Root Pointers)                                              --
-- - MMUSR (MMU Status Register)                                           --
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

entity TG68K030_MMU_Registers is
    port(
        -- Clock and reset
        clk         : in std_logic;
        reset       : in std_logic;

        -- CPU status
        supervisor  : in std_logic;  -- 1=supervisor mode, 0=user mode

        -- Register access interface
        reg_addr    : in std_logic_vector(3 downto 0);  -- Register select
        reg_write   : in std_logic;                     -- Write enable
        reg_read    : in std_logic;                     -- Read enable
        reg_size    : in std_logic_vector(1 downto 0);  -- 00=long, 01=quad (64-bit)
        data_in     : in std_logic_vector(63 downto 0); -- Write data (up to 64-bit)
        data_out    : out std_logic_vector(63 downto 0);-- Read data

        -- Privilege violation
        priv_violation : out std_logic;                 -- Access from user mode

        -- MMU register outputs (for MMU logic in later phases)
        tc_out      : out std_logic_vector(31 downto 0);
        tt0_out     : out std_logic_vector(31 downto 0);
        tt1_out     : out std_logic_vector(31 downto 0);
        crp_out     : out std_logic_vector(63 downto 0);
        srp_out     : out std_logic_vector(63 downto 0);
        mmusr_out   : out std_logic_vector(15 downto 0);

        -- MMUSR update from MMU logic (for PTEST, faults)
        mmusr_update : in std_logic;
        mmusr_in     : in std_logic_vector(15 downto 0)
    );
end entity TG68K030_MMU_Registers;

architecture rtl of TG68K030_MMU_Registers is

    -- Register select codes (for reg_addr)
    constant REG_TC    : std_logic_vector(3 downto 0) := "0000";
    constant REG_TT0   : std_logic_vector(3 downto 0) := "0010";
    constant REG_TT1   : std_logic_vector(3 downto 0) := "0011";
    constant REG_CRP   : std_logic_vector(3 downto 0) := "0100";
    constant REG_SRP   : std_logic_vector(3 downto 0) := "0101";
    constant REG_MMUSR : std_logic_vector(3 downto 0) := "0110";

    -- MMU Registers
    signal tc_reg    : std_logic_vector(31 downto 0);
    signal tt0_reg   : std_logic_vector(31 downto 0);
    signal tt1_reg   : std_logic_vector(31 downto 0);
    signal crp_reg   : std_logic_vector(63 downto 0);
    signal srp_reg   : std_logic_vector(63 downto 0);
    signal mmusr_reg : std_logic_vector(15 downto 0);

begin

    -- Output register values
    tc_out    <= tc_reg;
    tt0_out   <= tt0_reg;
    tt1_out   <= tt1_reg;
    crp_out   <= crp_reg;
    srp_out   <= srp_reg;
    mmusr_out <= mmusr_reg;

    -- Privilege check: all MMU registers are supervisor only
    priv_violation <= (reg_write or reg_read) and (not supervisor);

    --------------------------------------------------------------
    -- Register write process
    --------------------------------------------------------------
    process(clk, reset)
        variable write_data_32 : std_logic_vector(31 downto 0);
        variable write_data_64 : std_logic_vector(63 downto 0);
    begin
        if reset = '1' then
            -- Reset all registers to default values
            tc_reg    <= (others => '0');  -- 0x00000000 - MMU disabled
            tt0_reg   <= (others => '0');  -- 0x00000000 - Transparent translation disabled
            tt1_reg   <= (others => '0');  -- 0x00000000 - Transparent translation disabled
            crp_reg   <= (others => '0');  -- 0x0000000000000000 - Invalid descriptor
            srp_reg   <= (others => '0');  -- 0x0000000000000000 - Invalid descriptor
            mmusr_reg <= (others => '0');  -- 0x0000 - All status clear

        elsif rising_edge(clk) then

            -- MMUSR can be updated by MMU logic (PTEST results, faults)
            if mmusr_update = '1' then
                mmusr_reg <= mmusr_in;
            end if;

            -- Register write (only if supervisor mode)
            if reg_write = '1' and supervisor = '1' then

                -- Extract write data based on size
                if reg_size = "01" then  -- Quad-word (64-bit)
                    write_data_64 := data_in;
                else  -- Long-word (32-bit) - default
                    write_data_32 := data_in(31 downto 0);
                end if;

                case reg_addr is

                    -- TC - Translation Control (32-bit)
                    when REG_TC =>
                        -- Write TC, enforce reserved bits = 0
                        tc_reg(31)    <= write_data_32(31);  -- E bit
                        tc_reg(30 downto 24) <= (others => '0');  -- Reserved
                        tc_reg(23)    <= write_data_32(23);  -- SRE bit
                        tc_reg(22)    <= write_data_32(22);  -- FCL bit
                        tc_reg(21 downto 0) <= write_data_32(21 downto 0);  -- PS, IS, TI fields

                    -- TT0 - Transparent Translation 0 (32-bit)
                    when REG_TT0 =>
                        -- Write TT0, mask reserved bits
                        tt0_reg(31 downto 16) <= write_data_32(31 downto 16);  -- Base address
                        tt0_reg(15 downto 12) <= (others => '0');  -- Reserved
                        tt0_reg(11 downto 4)  <= write_data_32(11 downto 4);   -- Mask
                        tt0_reg(3)            <= write_data_32(3);              -- E bit
                        tt0_reg(2)            <= '0';  -- Reserved
                        tt0_reg(1 downto 0)   <= write_data_32(1 downto 0);    -- CI, R/W

                    -- TT1 - Transparent Translation 1 (32-bit)
                    when REG_TT1 =>
                        -- Write TT1, mask reserved bits (same as TT0)
                        tt1_reg(31 downto 16) <= write_data_32(31 downto 16);
                        tt1_reg(15 downto 12) <= (others => '0');
                        tt1_reg(11 downto 4)  <= write_data_32(11 downto 4);
                        tt1_reg(3)            <= write_data_32(3);
                        tt1_reg(2)            <= '0';
                        tt1_reg(1 downto 0)   <= write_data_32(1 downto 0);

                    -- CRP - CPU Root Pointer (64-bit)
                    when REG_CRP =>
                        -- Upper 32 bits: DT, limit
                        crp_reg(63 downto 62) <= write_data_64(63 downto 62);  -- DT
                        crp_reg(61 downto 48) <= (others => '0');  -- Reserved
                        crp_reg(47 downto 32) <= write_data_64(47 downto 32);  -- Limit
                        -- Lower 32 bits: Address (enforce 16-byte alignment)
                        crp_reg(31 downto 4)  <= write_data_64(31 downto 4);   -- Address
                        crp_reg(3 downto 0)   <= (others => '0');  -- Must be 0 (alignment)

                    -- SRP - Supervisor Root Pointer (64-bit)
                    when REG_SRP =>
                        -- Same format as CRP
                        srp_reg(63 downto 62) <= write_data_64(63 downto 62);
                        srp_reg(61 downto 48) <= (others => '0');
                        srp_reg(47 downto 32) <= write_data_64(47 downto 32);
                        srp_reg(31 downto 4)  <= write_data_64(31 downto 4);
                        srp_reg(3 downto 0)   <= (others => '0');

                    -- MMUSR - MMU Status Register (16-bit, read-mostly)
                    when REG_MMUSR =>
                        -- Software can write MMUSR (though unusual)
                        mmusr_reg(15 downto 8) <= write_data_32(15 downto 8);  -- Flags
                        mmusr_reg(7)  <= '0';  -- Reserved
                        mmusr_reg(6)  <= write_data_32(6);   -- T bit
                        mmusr_reg(5)  <= write_data_32(5);   -- R bit
                        mmusr_reg(4 downto 3) <= write_data_32(4 downto 3);  -- N field
                        mmusr_reg(2 downto 0) <= (others => '0');  -- Reserved

                    when others =>
                        -- Invalid register address - do nothing
                        null;

                end case;
            end if;
        end if;
    end process;

    --------------------------------------------------------------
    -- Register read process (combinational)
    --------------------------------------------------------------
    process(reg_addr, reg_read, supervisor, tc_reg, tt0_reg, tt1_reg,
            crp_reg, srp_reg, mmusr_reg)
    begin
        -- Default output
        data_out <= (others => '0');

        -- Register read (only if supervisor mode)
        if reg_read = '1' and supervisor = '1' then
            case reg_addr is

                when REG_TC =>
                    -- Read TC (32-bit in lower half)
                    data_out(63 downto 32) <= (others => '0');
                    data_out(31 downto 0)  <= tc_reg;

                when REG_TT0 =>
                    -- Read TT0 (32-bit in lower half)
                    data_out(63 downto 32) <= (others => '0');
                    data_out(31 downto 0)  <= tt0_reg;

                when REG_TT1 =>
                    -- Read TT1 (32-bit in lower half)
                    data_out(63 downto 32) <= (others => '0');
                    data_out(31 downto 0)  <= tt1_reg;

                when REG_CRP =>
                    -- Read CRP (64-bit)
                    data_out <= crp_reg;

                when REG_SRP =>
                    -- Read SRP (64-bit)
                    data_out <= srp_reg;

                when REG_MMUSR =>
                    -- Read MMUSR (16-bit in lowest 16 bits)
                    data_out(63 downto 16) <= (others => '0');
                    data_out(15 downto 0)  <= mmusr_reg;

                when others =>
                    -- Invalid register - return zeros
                    data_out <= (others => '0');

            end case;
        end if;
    end process;

end architecture rtl;
