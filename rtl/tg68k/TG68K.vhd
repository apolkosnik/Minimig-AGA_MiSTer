------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- This is the TOP-Level for TG68K.C to generate 68K Bus signals            --
--                                                                          --
-- Copyright (c) 2021 Tobias Gubener <tobiflex@opencores.org>               -- 
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity TG68K is
   generic(
      CPU           : std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  10->68030
      FPU_Enable    : integer := 1  -- 0=>no FPU, 1=>FPU enabled
   );
   port(        
      CLK           : in std_logic;
      RESET         : inout std_logic;
      HALT          : inout std_logic;
      BERR          : in std_logic;     -- only 68000 Stackpointer dummy for Atari ST core
      IPL           : in std_logic_vector(2 downto 0):="111";
      ADDR          : buffer std_logic_vector(31 downto 0);
      FC            : out std_logic_vector(2 downto 0);
      DATA          : inout std_logic_vector(15 downto 0);
---- bus controll      
--      BG            : out std_logic;
--      BR         	  : in std_logic:='1';
--      BGACK         : in std_logic:='1';
-- async interface      
      AS            : out std_logic;
      UDS           : out std_logic;
      LDS           : out std_logic;
      RW            : out std_logic;
      DTACK         : in std_logic;
-- sync interface      
      E             : out std_logic;
      VPA           : in std_logic;
      VMA           : out std_logic;
-- Cache memory interface (68030 only)
      cache_req     : buffer std_logic;
      cache_addr    : buffer std_logic_vector(31 downto 0);
      cache_data    : in  std_logic_vector(15 downto 0);
      cache_ack     : in  std_logic;
      cache_burst   : buffer std_logic;  -- Burst mode request (4 longwords)
      cache_burst_len : buffer std_logic_vector(2 downto 0);  -- Burst length (words to transfer)
-- Cache control
      cache_hit     : out std_logic;
      cache_miss    : out std_logic
   );
end TG68K;

ARCHITECTURE logic OF TG68K IS


COMPONENT TG68KdotC_Kernel 
   generic(
      SR_Read : integer:= 2;           --0=>user,     1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe : integer:= 2;    --0=>no,       1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode : integer:= 2;      --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,  
      DIV_Mode : integer := 2;         --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,  
      BitField : integer := 2;         --0=>no,       1=>yes,           2=>switchable with CPU(1)

      BarrelShifter : integer := 2;    --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Hardware : integer := 1;     --0=>no,       1=>yes,
      FPU_Enable : integer := 1        --0=>no FPU,   1=>FPU enabled
   );
   port(
      CPU            : in std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  10->68020  11->68030
      clk            : in std_logic;
      nReset         : in std_logic:='1';    --low active
      clkena_in      : in std_logic:='1';
      data_in        : in std_logic_vector(15 downto 0);
      IPL            : in std_logic_vector(2 downto 0):="111";
      IPL_autovector : in std_logic:='0';
      addr_out       : out std_logic_vector(31 downto 0);
      berr           : in std_logic:='0';     -- only 68000 Stackpointer dummy for Atari ST core
      FC             : out std_logic_vector(2 downto 0);
      data_write     : out std_logic_vector(15 downto 0);
      busstate       : out std_logic_vector(1 downto 0);	
      nWr            : out std_logic;
      nUDS, nLDS     : out std_logic;
      nResetOut      : out std_logic;
      skipFetch      : out std_logic;
-- Cache control interface (68030)		
      cache_cinv_req  : out std_logic;
      cache_cpush_req : out std_logic;
      cache_op_scope  : out std_logic_vector(1 downto 0);
      cache_op_cache  : out std_logic_vector(1 downto 0);
      cacr_ie         : out std_logic;
      cacr_de         : out std_logic;
      cacr_ifreeze     : out std_logic;
      cacr_dfreeze     : out std_logic;
      cacr_ibe        : out std_logic;  -- Instruction Burst Enable
      cacr_dbe        : out std_logic;  -- Data Burst Enable
      cacr_wa         : out std_logic;  -- Write Allocate
-- PMMU address interface (68030)
      pmmu_addr_log   : out std_logic_vector(31 downto 0);
      pmmu_addr_phys  : out std_logic_vector(31 downto 0);
      pmmu_cache_inhibit : out std_logic;
-- Cache operation address (68030)
      cache_op_addr   : out std_logic_vector(31 downto 0);
-- DEBUG: Supervisor mode tracking signals
      debug_SVmode        : out std_logic;
      debug_preSVmode     : out std_logic;
      debug_FlagsSR_S     : out std_logic;
      debug_changeMode    : out std_logic;
      debug_setopcode     : out std_logic;
      debug_exec_directSR : out std_logic;
      debug_exec_to_SR    : out std_logic
--      longword       : out std_logic;
--      clr_berr       : out std_logic;
   );
   END COMPONENT;

COMPONENT TG68K_Cache_030
   port(
      clk            : in  std_logic;
      nreset         : in  std_logic;
      -- Cache Control (from CACR register)
      cacr_ie        : in  std_logic;
      cacr_de        : in  std_logic;
      cacr_ifreeze    : in  std_logic;
      cacr_dfreeze    : in  std_logic;
      cacr_wa        : in  std_logic;
      -- Cache Control Instructions
      cinv_req       : in  std_logic;
      cpush_req      : in  std_logic;
      cache_op_scope : in  std_logic_vector(1 downto 0);
      cache_op_cache : in  std_logic_vector(1 downto 0);
      cache_op_addr  : in  std_logic_vector(31 downto 0);
      -- Instruction Cache Interface
      i_addr         : in  std_logic_vector(31 downto 0);
      i_addr_phys    : in  std_logic_vector(31 downto 0);
      i_req          : in  std_logic;
      i_cache_inhibit : in  std_logic;
      i_data         : out std_logic_vector(31 downto 0);
      i_hit          : out std_logic;
      i_fill_req     : out std_logic;
      i_fill_addr    : out std_logic_vector(31 downto 0);
      i_fill_data    : in  std_logic_vector(127 downto 0);
      i_fill_valid   : in  std_logic;
      -- Data Cache Interface
      d_addr         : in  std_logic_vector(31 downto 0);
      d_addr_phys    : in  std_logic_vector(31 downto 0);
      d_req          : in  std_logic;
      d_we           : in  std_logic;
      d_cache_inhibit : in  std_logic;
      d_data_in      : in  std_logic_vector(31 downto 0);
      d_be           : in  std_logic_vector(3 downto 0);
      d_data_out     : out std_logic_vector(31 downto 0);
      d_hit          : out std_logic;
      d_fill_req     : out std_logic;
      d_fill_addr    : out std_logic_vector(31 downto 0);
      d_fill_data    : in  std_logic_vector(127 downto 0);
      d_fill_valid   : in  std_logic
   );
   END COMPONENT;

   SIGNAL data_write  : std_logic_vector(15 downto 0);
   SIGNAL r_data      : std_logic_vector(15 downto 0);
   SIGNAL cpuIPL      : std_logic_vector(2 downto 0);
   SIGNAL data_akt_s  : std_logic;
   SIGNAL data_akt_e  : std_logic;
   SIGNAL as_s        : std_logic;
   SIGNAL as_e        : std_logic;
   SIGNAL uds_s       : std_logic;
   SIGNAL uds_e       : std_logic;
   SIGNAL lds_s       : std_logic;
   SIGNAL lds_e       : std_logic;
   SIGNAL rw_s        : std_logic;
   SIGNAL rw_e        : std_logic;
   SIGNAL vpad        : std_logic;
   SIGNAL waitm       : std_logic;
   SIGNAL clkena_e    : std_logic;
   SIGNAL S_state     : std_logic_vector(1 downto 0);
   SIGNAL decode      : std_logic;
   SIGNAL wr          : std_logic;
   SIGNAL uds_in      : std_logic;
   SIGNAL lds_in      : std_logic;
   SIGNAL state       : std_logic_vector(1 downto 0);
   SIGNAL clkena      : std_logic;
   SIGNAL skipFetch   : std_logic;
   SIGNAL nResetOut   : std_logic;
   SIGNAL autovector  : std_logic;
   SIGNAL cpu1reset   : std_logic;

   -- Cache control signals
   SIGNAL cache_enabled   : std_logic;
   SIGNAL cache_cinv_req  : std_logic;
   SIGNAL cache_cpush_req : std_logic;
   SIGNAL cache_op_scope  : std_logic_vector(1 downto 0);
   SIGNAL cache_op_cache  : std_logic_vector(1 downto 0);
   SIGNAL cacr_ie         : std_logic;
   SIGNAL cacr_de         : std_logic;
   SIGNAL cacr_ifreeze     : std_logic;
   SIGNAL cacr_dfreeze     : std_logic;
   SIGNAL cacr_ibe        : std_logic;  -- Instruction Burst Enable (CACR bit 4)
   SIGNAL cacr_dbe        : std_logic;  -- Data Burst Enable (CACR bit 12)
   SIGNAL cacr_wa         : std_logic;  -- Write Allocate (CACR bit 13)

   -- PMMU address signals (68030)
   SIGNAL pmmu_addr_log   : std_logic_vector(31 downto 0);
   SIGNAL pmmu_addr_phys  : std_logic_vector(31 downto 0);
   SIGNAL pmmu_ch_inhibit : std_logic;
   SIGNAL cache_op_addr   : std_logic_vector(31 downto 0);

   -- Cache interface signals  
   SIGNAL i_cache_addr    : std_logic_vector(31 downto 0);
   SIGNAL i_cache_req     : std_logic;
   SIGNAL i_cache_data    : std_logic_vector(31 downto 0);
   SIGNAL i_cache_hit     : std_logic;
   SIGNAL i_fill_req      : std_logic;
   SIGNAL i_fill_addr     : std_logic_vector(31 downto 0);
   SIGNAL i_fill_data     : std_logic_vector(127 downto 0);
   SIGNAL i_fill_valid    : std_logic;
   
   SIGNAL d_cache_addr    : std_logic_vector(31 downto 0);
   SIGNAL d_cache_req     : std_logic;
   SIGNAL d_cache_we      : std_logic;
   SIGNAL d_cache_data_in : std_logic_vector(31 downto 0);
   SIGNAL d_cache_data_out: std_logic_vector(31 downto 0);
   SIGNAL d_cache_hit     : std_logic;
   SIGNAL d_fill_req      : std_logic;
   SIGNAL d_fill_addr     : std_logic_vector(31 downto 0);
   SIGNAL d_fill_data     : std_logic_vector(127 downto 0);
   SIGNAL d_fill_valid    : std_logic;

   -- Cache memory interface signals
   SIGNAL cache_fill_active : std_logic;
   SIGNAL cache_fill_count  : std_logic_vector(2 downto 0);  -- Changed from 1 downto 0 to support 8-word fills
   SIGNAL cache_fill_buffer : std_logic_vector(127 downto 0);
   SIGNAL cache_fill_complete : std_logic;  -- One-cycle pulse when fill is complete
   SIGNAL byte_enables      : std_logic_vector(3 downto 0);  -- Dynamic byte enables based on UDS/LDS

   type sync_state_t is (sync0, sync1, sync2, sync3, sync4, sync5, sync6, sync7, sync8, sync9);
   signal sync_state : sync_state_t;

   -- DEBUG: Supervisor mode tracking signals
   SIGNAL debug_SVmode_int        : std_logic;
   SIGNAL debug_preSVmode_int     : std_logic;
   SIGNAL debug_FlagsSR_S_int     : std_logic;
   SIGNAL debug_changeMode_int    : std_logic;
   SIGNAL debug_setopcode_int     : std_logic;
   SIGNAL debug_exec_directSR_int : std_logic;
   SIGNAL debug_exec_to_SR_int    : std_logic;

BEGIN  
   DATA <= data_write WHEN data_akt_e='1' OR data_akt_s='1' ELSE "ZZZZZZZZZZZZZZZZ";
   AS <= as_s AND as_e;
   RW <= rw_s AND rw_e;
   UDS <= uds_s AND uds_e;
   LDS <= lds_s AND lds_e;
   
   RESET <= '0' WHEN nResetOut='0' ELSE 'Z';
   HALT <=  '0' WHEN nResetOut='0' ELSE 'Z';
   cpu1reset <= RESET OR HALT;

   -- Cache is only available on 68030 (CPU="11") AND when either I-cache or D-cache is enabled
   -- This signal controls the overall cache subsystem (memory interface, etc.)
   --cache_enabled <= '1' WHEN (CPU="11" AND (cacr_ie='1' OR cacr_de='1')) ELSE '0';
   cache_enabled <= '1' WHEN (CPU(1)='1' AND (cacr_ie='1' OR cacr_de='1')) ELSE '0';

   -- Cache control comes from CPU core CACR register
   -- Individual i_cache_req and d_cache_req check their specific enable bits (cacr_ie, cacr_de)
   -- Note: cacr_ie, cacr_de, cacr_ifreeze, cacr_dfreeze now come from CPU core

cpu1: TG68KdotC_Kernel 
   generic map(
      SR_Read => 2,              --0=>user,     1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe => 2,       --0=>no,       1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode => 2,         --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Mode => 2,             --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,  
      DIV_Mode => 2,             --0=>16Bit,    1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,  
      BitField => 2,             --0=>no,       1=>yes,           2=>switchable with CPU(1) 

      BarrelShifter => 0,        --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Hardware => 1,         --0=>no,       1=>yes,
      FPU_Enable => FPU_Enable   --0=>no FPU,   1=>FPU enabled
   )
   PORT MAP(
      CPU => CPU,                -- : in std_logic_vector(1 downto 0):="01";  -- 00->68000  01->68010  10->68030
      clk => CLK,                -- : in std_logic;
      nReset => cpu1reset,       -- : in std_logic:='1';       --low active
      clkena_in => clkena,       -- : in std_logic:='1';
      data_in => r_data,         -- : in std_logic_vector(15 downto 0);
      IPL => cpuIPL,             -- : in std_logic_vector(2 downto 0):="111";
      IPL_autovector => autovector, -- : in std_logic:='0';
      addr_out => ADDR,          -- : buffer std_logic_vector(31 downto 0);
      berr => BERR,              -- : in std_logic:='0';     -- only 68000 Stackpointer dummy for Atari ST core
      FC => FC,                  -- : out std_logic_vector(2 downto 0);
      data_write => data_write,  -- : out std_logic_vector(15 downto 0);
      busstate => state,         -- : buffer std_logic_vector(1 downto 0);	
      nWr => wr,                 -- : out std_logic;
      nUDS => uds_in,            -- : out std_logic;
      nLDS => lds_in,            -- : out std_logic;
      nResetOut => nResetOut,    -- : out std_logic;
      skipFetch => skipFetch,    -- : out std_logic
      -- Cache control interface (68030)
      cache_cinv_req => cache_cinv_req,   -- : out std_logic;
      cache_cpush_req => cache_cpush_req, -- : out std_logic;
      cache_op_scope => cache_op_scope,   -- : out std_logic_vector(1 downto 0);
      cache_op_cache => cache_op_cache,   -- : out std_logic_vector(1 downto 0);
      cacr_ie => cacr_ie,                 -- : out std_logic;
      cacr_de => cacr_de,                 -- : out std_logic;
      cacr_ifreeze => cacr_ifreeze,         -- : out std_logic;
      cacr_dfreeze => cacr_dfreeze,         -- : out std_logic;
      cacr_ibe => cacr_ibe,                 -- : out std_logic;
      cacr_dbe => cacr_dbe,                 -- : out std_logic;
      cacr_wa => cacr_wa,                   -- : out std_logic;
      -- PMMU address interface (68030)
      pmmu_addr_log => pmmu_addr_log,     -- : out std_logic_vector(31 downto 0);
      pmmu_addr_phys => pmmu_addr_phys,   -- : out std_logic_vector(31 downto 0)
      pmmu_cache_inhibit => pmmu_ch_inhibit, -- : out std_logic
      -- Cache operation address (68030)
      cache_op_addr => cache_op_addr,     -- : out std_logic_vector(31 downto 0)
      -- DEBUG: Supervisor mode tracking signals
      debug_SVmode => debug_SVmode_int,
      debug_preSVmode => debug_preSVmode_int,
      debug_FlagsSR_S => debug_FlagsSR_S_int,
      debug_changeMode => debug_changeMode_int,
      debug_setopcode => debug_setopcode_int,
      debug_exec_directSR => debug_exec_directSR_int,
      debug_exec_to_SR => debug_exec_to_SR_int
   );
 
   PROCESS (CLK)
   BEGIN
      IF falling_edge(CLK) THEN
         IF sync_state=sync5 THEN
            E <= '1';
         END IF;
         IF sync_state=sync9 THEN
            E <= '0';
         END IF;
      END IF;
      
      IF rising_edge(CLK) THEN
         CASE sync_state IS
            WHEN sync0  => sync_state <= sync1;
            WHEN sync1  => sync_state <= sync2;
            WHEN sync2  => sync_state <= sync3;
            WHEN sync3  => sync_state <= sync4;
                        VMA <= VPA;
                        vpad <= VPA;
                        autovector <= NOT VPA;
            WHEN sync4  => sync_state <= sync5;
            WHEN sync5  => sync_state <= sync6;
            WHEN sync6  => sync_state <= sync7;
            WHEN sync7  => sync_state <= sync8;
            WHEN sync8  => sync_state <= sync9;
            WHEN OTHERS => sync_state <= sync0;
                        VMA <= '1';
         END CASE;
      END IF;
   END PROCESS;


   PROCESS (state, clkena_e, skipFetch)
   BEGIN
      IF state="01" OR clkena_e='1' OR skipFetch='1' THEN
         clkena <= '1';
      ELSE 
         clkena <= '0';
      END IF;
   END PROCESS;

PROCESS (CLK, RESET, state, as_s, as_e, rw_s, rw_e, uds_s, uds_e, lds_s, lds_e)
   BEGIN
      IF RESET='0' THEN
         S_state <= "11";
         as_s <= '1';
         rw_s <= '1';
         uds_s <= '1';
         lds_s <= '1';
         data_akt_s <= '0';
      ELSIF rising_edge(CLK) THEN
         as_s <= '1';
         rw_s <= '1';
         uds_s <= '1';
         lds_s <= '1';
         data_akt_s <= '0';
         CASE S_state IS
            WHEN "00" =>
                      IF state/="01" AND skipFetch='0' THEN
                         IF wr='1' THEN
                            uds_s <= uds_in;
                            lds_s <= lds_in;
                         END IF;
                         as_s <= '0';
                         rw_s <= wr;
                         S_state <= "01";
                      END IF;
            WHEN "01" => 
                      as_s <= '0';
                      rw_s <= wr;
                      uds_s <= uds_in;
                      lds_s <= lds_in;
                      S_state <= "10";
            WHEN "10" =>
                      data_akt_s <= NOT wr;
                      r_data <= DATA;
                      IF waitm='0' OR (vpad='0' AND sync_state=sync9) THEN
                         S_state <= "11";
                      ELSE	
                         as_s <= '0';
                         rw_s <= wr;
                         uds_s <= uds_in;
                         lds_s <= lds_in;
                      END IF;
            WHEN "11" =>
                      S_state <= "00";
            WHEN OTHERS => null;
         END CASE;
      END IF;
      
      IF RESET='0' THEN
         as_e <= '1';
         rw_e <= '1';
         uds_e <= '1';
         lds_e <= '1';
         clkena_e <= '0';
         data_akt_e <= '0';
      ELSIF falling_edge(CLK) THEN
         as_e <= '1';
         rw_e <= '1';
         uds_e <= '1';
         lds_e <= '1';
         clkena_e <= '0';
         data_akt_e <= '0';
         CASE S_state IS
            WHEN "00" =>
                      cpuIPL <= IPL;      --for HALT command
            WHEN "01" =>
                      data_akt_e <= NOT wr;
                      as_e <= '0';
                      rw_e <= wr;
                      uds_e <= uds_in;
                      lds_e <= lds_in;
            WHEN "10" =>
                      rw_e <= wr;
                      data_akt_e <= NOT wr;
                      cpuIPL <= IPL;
                      waitm <= DTACK;
            WHEN OTHERS =>
                      clkena_e <= '1';
         END CASE;
      END IF;
   END PROCESS;

   -- Cache instantiation (68030 only)
   cache_inst: TG68K_Cache_030 
   port map(
      clk            => CLK,
      nreset         => cpu1reset,
      -- Cache Control (from CACR register)
      cacr_ie        => cacr_ie,
      cacr_de        => cacr_de,
      cacr_ifreeze    => cacr_ifreeze,
      cacr_dfreeze    => cacr_dfreeze,
      cacr_wa        => cacr_wa,
      -- Cache Control Instructions
      cinv_req       => cache_cinv_req,
      cpush_req      => cache_cpush_req,
      cache_op_scope => cache_op_scope,
      cache_op_cache => cache_op_cache,
      cache_op_addr  => cache_op_addr,
      -- Instruction Cache Interface
      i_addr         => i_cache_addr,
      i_addr_phys    => pmmu_addr_phys,   -- Physical address from PMMU
      i_req          => i_cache_req,
      i_cache_inhibit => pmmu_ch_inhibit,  -- Cache inhibit from PMMU
      i_data         => i_cache_data,
      i_hit          => i_cache_hit,
      i_fill_req     => i_fill_req,
      i_fill_addr    => i_fill_addr,
      i_fill_data    => i_fill_data,
      i_fill_valid   => i_fill_valid,
      -- Data Cache Interface
      d_addr         => d_cache_addr,
      d_addr_phys    => pmmu_addr_phys,   -- Physical address from PMMU
      d_req          => d_cache_req,
      d_we           => d_cache_we,
      d_cache_inhibit => pmmu_ch_inhibit,  -- Cache inhibit from PMMU
      d_be           => byte_enables,     -- Dynamic byte enables based on UDS/LDS
      d_data_in      => d_cache_data_in,
      d_data_out     => d_cache_data_out,
      d_hit          => d_cache_hit,
      d_fill_req     => d_fill_req,
      d_fill_addr    => d_fill_addr,
      d_fill_data    => d_fill_data,
      d_fill_valid   => d_fill_valid
   );

   -- Cache interface logic for 68030
   i_cache_addr <= ADDR;
   -- Instruction cache request only when CPU is 68030 AND cacr_ie is enabled
   --i_cache_req <= '1' when (state="00" and CPU="11" and cacr_ie='1') else '0';
   i_cache_req <= '1' when (state="00" and CPU(1)='1' and cacr_ie='1') else '0';
   i_fill_data <= cache_fill_buffer;
   -- Use registered completion signal to ensure buffer is fully filled before asserting valid
   i_fill_valid <= cache_fill_complete;

   d_cache_addr <= ADDR;
   -- Data cache request only when CPU is 68030 AND cacr_de is enabled
   --d_cache_req <= '1' when ((state="10" or state="11") and CPU="11" and cacr_de='1') else '0';
   d_cache_req <= '1' when ((state="10" or state="11") and CPU(1)='1' and cacr_de='1') else '0';
   d_cache_we <= not wr;
   d_cache_data_in <= data_write & data_write;  -- Replicate 16-bit data to 32-bit
   d_fill_data <= cache_fill_buffer;
   -- Use registered completion signal to ensure buffer is fully filled before asserting valid
   d_fill_valid <= cache_fill_complete;

   -- Calculate byte enables from UDS/LDS
   -- For 68030, the cache module needs to know which bytes are being written
   -- Use internal signals uds_s and lds_s (can't read output ports UDS/LDS in VHDL)
   -- Simplified logic: conditions 1-3 cover all valid access types
   byte_enables <= "1111" when (uds_s='0' and lds_s='0') else  -- Word access (both strobes active)
                   "1100" when (uds_s='0') else                 -- Upper byte only (UDS active)
                   "0011" when (lds_s='0') else                 -- Lower byte only (LDS active)
                   "0000";  -- No access (both strobes inactive)

   -- Cache hit/miss logic
   cache_hit <= (i_cache_hit and i_cache_req) or (d_cache_hit and d_cache_req);
   cache_miss <= ((not i_cache_hit and i_cache_req) or (not d_cache_hit and d_cache_req)) when cache_enabled='1' else '0';

   -- Cache memory interface - connect to SDRAM controller
   cache_req <= (i_fill_req or d_fill_req) when cache_enabled='1' else '0';
   cache_addr <= i_fill_addr when i_fill_req='1' else d_fill_addr;

   -- Burst mode control
   -- When IBE=1 (instruction) or DBE=1 (data), request burst transfer of 8 words
   -- Otherwise, request individual word transfers
   cache_burst <= '1' when (cache_enabled='1' and
                            ((i_fill_req='1' and cacr_ibe='1') or
                             (d_fill_req='1' and cacr_dbe='1'))) else '0';
   cache_burst_len <= "111";  -- Always request 8 words (128-bit cache line)

   -- Cache fill process - accumulate 8 words into 128-bit cache line
   -- MC68030 cache lines are 16 bytes (128 bits) = 8 words of 16 bits each
   PROCESS (CLK, cpu1reset)
   BEGIN
      IF cpu1reset='0' THEN
         cache_fill_active <= '0';
         cache_fill_count <= "000";
         cache_fill_buffer <= (others => '0');
         cache_fill_complete <= '0';
      ELSIF rising_edge(CLK) THEN
         -- Default: clear completion pulse
         cache_fill_complete <= '0';

         IF cache_req='1' and cache_ack='1' THEN
            -- Start cache fill sequence
            IF cache_fill_active='0' THEN
               cache_fill_active <= '1';
               cache_fill_count <= "000";
            END IF;
         END IF;

         IF cache_fill_active='1' and cache_ack='1' THEN
            -- Accumulate 16-bit words into 128-bit cache line (8 words total)
            CASE cache_fill_count IS
               WHEN "000" => cache_fill_buffer(15 downto 0)    <= cache_data;
               WHEN "001" => cache_fill_buffer(31 downto 16)   <= cache_data;
               WHEN "010" => cache_fill_buffer(47 downto 32)   <= cache_data;
               WHEN "011" => cache_fill_buffer(63 downto 48)   <= cache_data;
               WHEN "100" => cache_fill_buffer(79 downto 64)   <= cache_data;
               WHEN "101" => cache_fill_buffer(95 downto 80)   <= cache_data;
               WHEN "110" => cache_fill_buffer(111 downto 96)  <= cache_data;
               WHEN "111" => cache_fill_buffer(127 downto 112) <= cache_data;
                             cache_fill_active <= '0';
                             -- Generate completion pulse AFTER last word is stored
                             cache_fill_complete <= '1';
               WHEN OTHERS => NULL;
            END CASE;

            IF cache_fill_count /= "111" THEN  -- Changed from "11" to "111"
               cache_fill_count <= cache_fill_count + 1;
            END IF;
         END IF;
      END IF;
   END PROCESS;

END;