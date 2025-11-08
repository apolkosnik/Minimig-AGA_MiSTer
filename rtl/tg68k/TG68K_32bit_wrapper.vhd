------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- 32-BIT WRAPPER for TG68K CPU Core                                        --
--                                                                          --
-- This wrapper converts the 16-bit TG68K interface to 32-bit wide         --
-- for improved memory bandwidth and performance                           --
--                                                                          --
-- Copyright (c) 2025 Based on TG68K by Tobias Gubener                     --
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
use ieee.std_logic_unsigned.all;

entity TG68K_32bit_wrapper is
   generic(
      SR_Read : integer:= 2;           --0=>user,     1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe : integer:= 2;    --0=>no,       1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode : integer:= 2;      --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,
      DIV_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,
      BitField : integer := 2          --0=>no,       1=>yes,           2=>switchable with CPU(1)
   );
   port(
      CPU            : in std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  11->68020
      clk            : in std_logic;
      nReset         : in std_logic:='1';    --low active
      clkena_in      : in std_logic:='1';
      data_in        : in std_logic_vector(31 downto 0);   -- 32-bit data input
      IPL            : in std_logic_vector(2 downto 0):="111";
      IPL_autovector : in std_logic:='0';
      addr_out       : out std_logic_vector(31 downto 0);
      berr           : in std_logic:='0';
      FC             : out std_logic_vector(2 downto 0);
      data_write     : out std_logic_vector(31 downto 0);  -- 32-bit data output
      busstate       : out std_logic_vector(1 downto 0);
      nWr            : out std_logic;
      nBE            : out std_logic_vector(3 downto 0);   -- 4 byte enables (active low)
                                                             -- nBE(3) = bits 31:24
                                                             -- nBE(2) = bits 23:16
                                                             -- nBE(1) = bits 15:8
                                                             -- nBE(0) = bits 7:0
      nResetOut      : out std_logic;
      skipFetch      : out std_logic;
      longword       : out std_logic;
      regin_out      : out std_logic_vector(31 downto 0);
      CACR_out       : out std_logic_vector(3 downto 0);
      VBR_out        : out std_logic_vector(31 downto 0)
   );
end TG68K_32bit_wrapper;

architecture logic of TG68K_32bit_wrapper is

   COMPONENT TG68KdotC_Kernel
      generic(
         SR_Read : integer:= 2;
         VBR_Stackframe : integer:= 2;
         extAddr_Mode : integer:= 2;
         MUL_Mode : integer := 2;
         DIV_Mode : integer := 2;
         BitField : integer := 2;
         BarrelShifter : integer := 2;
         MUL_Hardware : integer := 1
      );
      port(
         CPU            : in std_logic_vector(1 downto 0):="01";
         clk            : in std_logic;
         nReset         : in std_logic:='1';
         clkena_in      : in std_logic:='1';
         data_in        : in std_logic_vector(15 downto 0);
         IPL            : in std_logic_vector(2 downto 0):="111";
         IPL_autovector : in std_logic:='0';
         addr_out       : out std_logic_vector(31 downto 0);
         berr           : in std_logic:='0';
         FC             : out std_logic_vector(2 downto 0);
         data_write     : out std_logic_vector(15 downto 0);
         busstate       : out std_logic_vector(1 downto 0);
         nWr            : out std_logic;
         nUDS, nLDS     : out std_logic;
         nResetOut      : out std_logic;
         skipFetch      : out std_logic;
         longword       : out std_logic;
         regin_out      : out std_logic_vector(31 downto 0);
         CACR_out       : out std_logic_vector(3 downto 0);
         VBR_out        : out std_logic_vector(31 downto 0)
      );
   END COMPONENT;

   -- Internal signals for 16-bit TG68K core
   signal core_data_in    : std_logic_vector(15 downto 0);
   signal core_data_write : std_logic_vector(15 downto 0);
   signal core_nUDS       : std_logic;
   signal core_nLDS       : std_logic;
   signal core_addr       : std_logic_vector(31 downto 0);
   signal core_longword   : std_logic;
   signal core_busstate   : std_logic_vector(1 downto 0);

BEGIN

   -- Instantiate the 16-bit TG68K core
   cpu_core: TG68KdotC_Kernel
      generic map(
         SR_Read => SR_Read,
         VBR_Stackframe => VBR_Stackframe,
         extAddr_Mode => extAddr_Mode,
         MUL_Mode => MUL_Mode,
         DIV_Mode => DIV_Mode,
         BitField => BitField,
         BarrelShifter => 2,
         MUL_Hardware => 1
      )
      PORT MAP(
         CPU => CPU,
         clk => clk,
         nReset => nReset,
         clkena_in => clkena_in,
         data_in => core_data_in,
         IPL => IPL,
         IPL_autovector => IPL_autovector,
         addr_out => core_addr,
         berr => berr,
         FC => FC,
         data_write => core_data_write,
         busstate => core_busstate,
         nWr => nWr,
         nUDS => core_nUDS,
         nLDS => core_nLDS,
         nResetOut => nResetOut,
         skipFetch => skipFetch,
         longword => core_longword,
         regin_out => regin_out,
         CACR_out => CACR_out,
         VBR_out => VBR_out
      );

   -- Pass through signals
   addr_out <= core_addr;
   busstate <= core_busstate;
   longword <= core_longword;

   -- Generate 4 byte enables from UDS/LDS and address
   -- TG68K uses address bits to select which half of 32-bit bus to access
   process(core_longword, core_nUDS, core_nLDS, core_addr)
   begin
      if core_longword = '1' then
         -- Longword access: enable all 4 bytes for aligned access
         nBE <= "0000";
      else
         -- Word or byte access: enable appropriate bytes based on address
         if core_addr(1) = '0' then
            -- Accessing upper word (bits 31:16)
            nBE <= core_nUDS & core_nLDS & '1' & '1';
         else
            -- Accessing lower word (bits 15:0)
            nBE <= '1' & '1' & core_nUDS & core_nLDS;
         end if;
      end if;
   end process;

   -- Data input routing: select correct 16 bits from 32-bit bus based on address
   core_data_in <= data_in(31 downto 16) when core_addr(1) = '0' else data_in(15 downto 0);

   -- Data output routing: place 16-bit write data in correct position on 32-bit bus
   data_write <= core_data_write & core_data_write &core_data_write & core_data_write when core_longword = '1' else
                 core_data_write & x"0000" when core_addr(1) = '0' else
                 x"0000" & core_data_write;

end logic;
