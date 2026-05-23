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
      CPU           : std_logic_vector(1 downto 0):="01"; -- 00->68000  01->68010  10->68030
      FPU_Enable    : integer := 1;                       -- 0=>FPU shell only, 1=>68881/68882 core
      FPU_Transcendental_Enable : integer := 0;           -- 0=>omit trig/log/exp core, 1=>include it
      FPU_Packed_Decimal_Enable : integer := 0            -- 0=>omit packed decimal converter, 1=>include it
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


-- Synced with TG68KdotC_Kernel entity in TG68KdotC_Kernel.vhd (Apr 2026).
-- If you add or remove ports in the kernel entity, mirror them here; default
-- binding requires the component and entity port lists to match.
COMPONENT TG68KdotC_Kernel
   generic(
      SR_Read : integer:= 2;            --0=>user,    1=>privileged,    2=>switchable with CPU(0)
      VBR_Stackframe : integer:= 2;     --0=>no,      1=>yes/extended,  2=>switchable with CPU(0)
      extAddr_Mode : integer:= 2;       --0=>no,      1=>yes,           2=>switchable with CPU(1)
      MUL_Mode : integer := 2;          --0=>16Bit,   1=>32Bit,         2=>switchable with CPU(1), 3=>no MUL
      DIV_Mode : integer := 2;          --0=>16Bit,   1=>32Bit,         2=>switchable with CPU(1), 3=>no DIV
      BitField : integer := 2;          --0=>no,      1=>yes,           2=>switchable with CPU(1)

      BarrelShifter : integer := 1;     --0=>no,      1=>yes,           2=>switchable with CPU(1)
      MUL_Hardware : integer := 1;      --0=>no,      1=>yes
      FPU_Enable : integer := 0;        --0=>FPU shell only, 1=>68881/68882 core
      FPU_Transcendental_Enable : integer := 0; --0=>omit trig/log/exp core, 1=>include it
      FPU_Packed_Decimal_Enable : integer := 0  --0=>omit packed decimal converter, 1=>include it
   );
   port(
      clk                              : in std_logic;
      nReset                           : in std_logic;            --low active
      clkena_in                        : in std_logic:='1';
      data_in                          : in std_logic_vector(15 downto 0);
      IPL                              : in std_logic_vector(2 downto 0):="111";
      IPL_autovector                   : in std_logic:='0';
      berr                             : in std_logic:='0';       -- only 68000 Stackpointer dummy
      CPU                              : in std_logic_vector(1 downto 0);
      addr_out                         : out std_logic_vector(31 downto 0);
      data_write                       : out std_logic_vector(15 downto 0);
      nWr                              : out std_logic;
      nUDS                             : out std_logic;
      nLDS                             : out std_logic;
      busstate                         : out std_logic_vector(1 downto 0);
      longword                         : out std_logic;
      nResetOut                        : out std_logic;
      FC                               : out std_logic_vector(2 downto 0);
      clr_berr                         : out std_logic;
      skipFetch                        : out std_logic;
      regin_out                        : out std_logic_vector(31 downto 0);
      CACR_out                         : out std_logic_vector(31 downto 0);
      VBR_out                          : out std_logic_vector(31 downto 0);
      cache_inv_req                    : out std_logic;
      cache_op_scope                   : out std_logic_vector(1 downto 0);
      cache_op_cache                   : out std_logic_vector(1 downto 0);
      cacr_ie                          : out std_logic;
      cacr_de                          : out std_logic;
      cacr_ifreeze                     : out std_logic;
      cacr_dfreeze                     : out std_logic;
      cacr_ibe                         : out std_logic;
      cacr_dbe                         : out std_logic;
      cacr_wa                          : out std_logic;
      pmmu_reg_we                      : out std_logic;
      pmmu_reg_re                      : out std_logic;
      pmmu_reg_sel                     : out std_logic_vector(4 downto 0);
      pmmu_reg_wdat                    : out std_logic_vector(31 downto 0);
      pmmu_reg_part                    : out std_logic;
      pmmu_addr_log                    : out std_logic_vector(31 downto 0);
      pmmu_addr_phys                   : out std_logic_vector(31 downto 0);
      pmmu_cache_inhibit               : out std_logic;
      cache_op_addr                    : out std_logic_vector(31 downto 0);
      pmmu_walker_req                  : out std_logic;
      pmmu_walker_we                   : out std_logic;
      pmmu_walker_addr                 : out std_logic_vector(31 downto 0);
      pmmu_walker_wdat                 : out std_logic_vector(31 downto 0);
      pmmu_walker_ack                  : in  std_logic;
      pmmu_walker_data                 : in  std_logic_vector(31 downto 0);
      pmmu_walker_berr                 : in  std_logic;
      debug_SVmode                     : out std_logic;
      debug_preSVmode                  : out std_logic;
      debug_FlagsSR_S                  : out std_logic;
      debug_changeMode                 : out std_logic;
      debug_setopcode                  : out std_logic;
      debug_exec_directSR              : out std_logic;
      debug_exec_to_SR                 : out std_logic;
      debug_pmove_dn_mode              : out std_logic;
      debug_pmove_dn_regnum            : out std_logic_vector(2 downto 0);
      debug_opcode                     : out std_logic_vector(15 downto 0);
      debug_state                      : out std_logic_vector(1 downto 0);
      debug_setstate                   : out std_logic_vector(1 downto 0);
      debug_last_opc_read              : out std_logic_vector(15 downto 0);
      debug_data_read                  : out std_logic_vector(31 downto 0);
      debug_direct_data                : out std_logic;
      debug_setnextpass                : out std_logic;
      debug_TG68_PC                    : out std_logic_vector(31 downto 0);
      debug_memaddr_reg                : out std_logic_vector(31 downto 0);
      debug_memaddr_delta              : out std_logic_vector(31 downto 0);
      debug_oddout                     : out std_logic;
      debug_decodeOPC                  : out std_logic;
      debug_brief                      : out std_logic_vector(15 downto 0);
      debug_moves_bus_pending          : out std_logic;
      debug_moves_writeback_pending    : out std_logic;
      debug_clkena_lw                  : out std_logic;
      debug_regfile_d0                 : out std_logic_vector(31 downto 0);
      debug_regfile_a0                 : out std_logic_vector(31 downto 0);
      debug_fline_context_valid        : out std_logic;
      debug_trap_1111                  : out std_logic;
      debug_trapmake                   : out std_logic;
      debug_pmmu_brief                 : out std_logic_vector(15 downto 0);
      debug_use_base                   : out std_logic;
      debug_rf_source_addr             : out std_logic_vector(3 downto 0);
      debug_pmove_ea_latched           : out std_logic_vector(31 downto 0);
      debug_reg_QA                     : out std_logic_vector(31 downto 0);
      debug_last_data_read             : out std_logic_vector(31 downto 0);
      debug_last_opc_pc                : out std_logic_vector(31 downto 0);
      debug_getbrief                   : out std_logic;
      debug_get_2ndopc                 : out std_logic;
      debug_fline_brief_pending        : out std_logic;
      debug_fline_opcode_pc            : out std_logic_vector(31 downto 0);
      debug_exe_PC                     : out std_logic_vector(31 downto 0);
      debug_memaddr_delta_rega         : out std_logic_vector(31 downto 0);
      debug_memaddr_delta_regb         : out std_logic_vector(31 downto 0);
      debug_addsub_q                   : out std_logic_vector(31 downto 0);
      debug_memmaskmux                 : out std_logic_vector(5 downto 0);
      debug_fline_opcode_latch         : out std_logic_vector(15 downto 0);
      debug_pmmu_ea_mode_latched       : out std_logic_vector(5 downto 0);
      debug_exec_direct_delta          : out std_logic;
      debug_exec_directPC              : out std_logic;
      debug_exec_mem_addsub            : out std_logic;
      debug_set_addrlong               : out std_logic;
      debug_mdelta_src                 : out std_logic_vector(7 downto 0);
      debug_pc_brw                     : out std_logic;
      debug_pc_word                    : out std_logic;
      debug_regfile_d1                 : out std_logic_vector(31 downto 0);
      debug_regfile_d2                 : out std_logic_vector(31 downto 0);
      debug_regfile_d3                 : out std_logic_vector(31 downto 0);
      debug_regfile_d4                 : out std_logic_vector(31 downto 0);
      debug_regfile_d5                 : out std_logic_vector(31 downto 0);
      debug_regfile_d6                 : out std_logic_vector(31 downto 0);
      debug_regfile_d7                 : out std_logic_vector(31 downto 0);
      debug_regfile_a1                 : out std_logic_vector(31 downto 0);
      debug_regfile_a2                 : out std_logic_vector(31 downto 0);
      debug_regfile_a3                 : out std_logic_vector(31 downto 0);
      debug_regfile_a4                 : out std_logic_vector(31 downto 0);
      debug_regfile_a5                 : out std_logic_vector(31 downto 0);
      debug_regfile_a6                 : out std_logic_vector(31 downto 0);
      debug_regfile_a7                 : out std_logic_vector(31 downto 0);
      debug_regfile_we                 : out std_logic;
      debug_regfile_waddr              : out std_logic_vector(3 downto 0);
      debug_regfile_wdata              : out std_logic_vector(31 downto 0);
      debug_trap_illegal               : out std_logic;
      debug_trap_priv                  : out std_logic;
      debug_trap_addr_error            : out std_logic;
      debug_trap_berr                  : out std_logic;
      debug_trap_mmu_berr              : out std_logic;
      debug_trap_vector                : out std_logic_vector(31 downto 0);
      debug_pc_add                     : out std_logic_vector(31 downto 0);
      debug_pc_dataa                   : out std_logic_vector(31 downto 0);
      debug_pc_datab                   : out std_logic_vector(31 downto 0);
      debug_pmmu_busy                  : out std_logic;
      debug_cpu_halted                 : out std_logic;
      debug_stop                       : out std_logic;
      debug_interrupt                  : out std_logic;
      debug_setendOPC                  : out std_logic;
      debug_IPL_nr                     : out std_logic_vector(2 downto 0);
      debug_micro_state                : out integer range 0 to 255;
      debug_next_micro_state           : out integer range 0 to 255;
      debug_memmask                    : out std_logic_vector(5 downto 0);
      debug_sndOPC                     : out std_logic_vector(15 downto 0);
      debug_pmmu_reg_we                : out std_logic;
      debug_pmmu_reg_re                : out std_logic;
      debug_pmmu_reg_sel               : out std_logic_vector(4 downto 0);
      debug_pmmu_reg_wdat              : out std_logic_vector(31 downto 0);
      debug_pmmu_reg_part              : out std_logic;
      debug_pmmu_reg_rdat              : out std_logic_vector(31 downto 0);
      debug_make_berr                  : out std_logic;
      debug_pmmu_fault                 : out std_logic;
      debug_berr_exception_active      : out std_logic;
      debug_pmmu_fault_dispatched      : out std_logic;
      debug_pmmu_fault_was_cleared     : out std_logic;
      debug_pmmu_fault_rw              : out std_logic;
      debug_pmmu_fault_is_insn         : out std_logic;
      debug_pmmu_fault_fc              : out std_logic_vector(2 downto 0);
      debug_trap_format_error          : out std_logic;
      debug_format_error_rte_word      : out std_logic_vector(15 downto 0);
      debug_format_error_pc            : out std_logic_vector(31 downto 0);
      debug_format_error_addr          : out std_logic_vector(31 downto 0);
      debug_format_error_sr            : out std_logic_vector(7 downto 0);
      debug_pmmu_tc                    : out std_logic_vector(31 downto 0);
      debug_pmmu_tt0                   : out std_logic_vector(31 downto 0);
      debug_pmmu_tt1                   : out std_logic_vector(31 downto 0);
      debug_pmmu_crp_hi                : out std_logic_vector(31 downto 0);
      debug_pmmu_crp_lo                : out std_logic_vector(31 downto 0);
      debug_pmmu_srp_hi                : out std_logic_vector(31 downto 0);
      debug_pmmu_srp_lo                : out std_logic_vector(31 downto 0);
      debug_pmmu_wstate                : out std_logic_vector(4 downto 0);
      debug_pmmu_atc_buserr            : out std_logic_vector(21 downto 0);
      debug_pmmu_atc_valid             : out std_logic_vector(21 downto 0);
      debug_pmmu_pending_flags         : out std_logic_vector(15 downto 0);
      debug_pmmu_fault_status          : out std_logic_vector(15 downto 0);
      debug_pmmu_saved_addr            : out std_logic_vector(31 downto 0);
      debug_pmmu_walk_desc_addr        : out std_logic_vector(31 downto 0);
      debug_pmmu_walk_desc_data        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr1_desc_addr        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr1_desc_data        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr2_desc_addr        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr2_desc_data        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr3_desc_addr        : out std_logic_vector(31 downto 0);
      debug_pmmu_ptr3_desc_data        : out std_logic_vector(31 downto 0);
      debug_pmmu_saved_fc              : out std_logic_vector(2 downto 0);
      debug_make_trace                 : out std_logic;
      debug_trace_pending_grp2         : out std_logic;
      debug_useStackframe2             : out std_logic;
      debug_exec_trap_chk              : out std_logic;
      debug_set_trap_chk               : out std_logic;
      debug_data_write_tmp             : out std_logic_vector(31 downto 0);
      debug_FlagsSR                    : out std_logic_vector(7 downto 0);
      debug_USP                        : out std_logic_vector(31 downto 0);
      debug_MSP                        : out std_logic_vector(31 downto 0);
      debug_ISP                        : out std_logic_vector(31 downto 0);
      debug_a7_is_msp                  : out std_logic;
      debug_interrupt_mode             : out std_logic;
      debug_rte_saved_mbit             : out std_logic
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
      inv_req        : in  std_logic;
      cache_op_scope : in  std_logic_vector(1 downto 0);
      cache_op_cache : in  std_logic_vector(1 downto 0);
      cache_op_addr  : in  std_logic_vector(31 downto 0);
      -- Instruction Cache Interface
      i_addr         : in  std_logic_vector(31 downto 0);
      i_addr_phys    : in  std_logic_vector(31 downto 0);
      i_fc           : in  std_logic_vector(2 downto 0);
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
      d_fc           : in  std_logic_vector(2 downto 0);
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
   SIGNAL FC_int      : std_logic_vector(2 downto 0);

   -- Cache control signals
   SIGNAL cache_enabled   : std_logic;
   SIGNAL cache_inv_req  : std_logic;
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
   SIGNAL cache_fill_owner_i : std_logic;
   SIGNAL cache_fill_addr_latched : std_logic_vector(31 downto 0);
   SIGNAL fill_pending_i : std_logic;
   SIGNAL fill_pending_d : std_logic;
   SIGNAL cache_fill_start : std_logic;
   SIGNAL cache_fill_accept : std_logic;
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
   FC <= FC_int;
   cpu1reset <= RESET OR HALT;

   -- Cache is only available when CPU(1)='1' (the 68030 slot in this tree) and either cache is enabled
   -- This signal controls the overall cache subsystem (memory interface, etc.)
   --cache_enabled <= '1' WHEN (CPU(1)='1' AND (cacr_ie='1' OR cacr_de='1')) ELSE '0';
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

      BarrelShifter => 2,        --0=>no,       1=>yes,           2=>switchable with CPU(1)
      MUL_Hardware => 1,         --0=>no,       1=>yes,
      FPU_Enable => FPU_Enable,
      FPU_Transcendental_Enable => FPU_Transcendental_Enable,
      FPU_Packed_Decimal_Enable => FPU_Packed_Decimal_Enable
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
      FC => FC_int,              -- : out std_logic_vector(2 downto 0);
      data_write => data_write,  -- : out std_logic_vector(15 downto 0);
      busstate => state,         -- : buffer std_logic_vector(1 downto 0);	
      nWr => wr,                 -- : out std_logic;
      nUDS => uds_in,            -- : out std_logic;
      nLDS => lds_in,            -- : out std_logic;
      nResetOut => nResetOut,    -- : out std_logic;
      longword => open,          -- : out std_logic;
      skipFetch => skipFetch,    -- : out std_logic
      regin_out => open,
      CACR_out => open,
      VBR_out => open,
      clr_berr => open,
      -- Cache control interface (68030)
      cache_inv_req => cache_inv_req,   -- : out std_logic;
      cache_op_scope => cache_op_scope,   -- : out std_logic_vector(1 downto 0);
      cache_op_cache => cache_op_cache,   -- : out std_logic_vector(1 downto 0);
      cacr_ie => cacr_ie,                 -- : out std_logic;
      cacr_de => cacr_de,                 -- : out std_logic;
      cacr_ifreeze => cacr_ifreeze,         -- : out std_logic;
      cacr_dfreeze => cacr_dfreeze,         -- : out std_logic;
      cacr_ibe => cacr_ibe,                 -- : out std_logic;
      cacr_dbe => cacr_dbe,                 -- : out std_logic;
      cacr_wa => cacr_wa,                   -- : out std_logic;
      -- PMMU register interface (68030)
      pmmu_reg_we => open,
      pmmu_reg_re => open,
      pmmu_reg_sel => open,
      pmmu_reg_wdat => open,
      pmmu_reg_part => open,
      -- PMMU address interface (68030)
      pmmu_addr_log => pmmu_addr_log,     -- : out std_logic_vector(31 downto 0);
      pmmu_addr_phys => pmmu_addr_phys,   -- : out std_logic_vector(31 downto 0)
      pmmu_cache_inhibit => pmmu_ch_inhibit, -- : out std_logic
      -- Cache operation address (68030)
      cache_op_addr => cache_op_addr,     -- : out std_logic_vector(31 downto 0)
      -- PMMU walker memory interface (68030)
      pmmu_walker_req => open,
      pmmu_walker_we => open,
      pmmu_walker_addr => open,
      pmmu_walker_wdat => open,
      pmmu_walker_ack => '0',
      pmmu_walker_data => (others => '0'),
      pmmu_walker_berr => '0',
      -- DEBUG: Supervisor mode tracking signals
      debug_SVmode => debug_SVmode_int,
      debug_preSVmode => debug_preSVmode_int,
      debug_FlagsSR_S => debug_FlagsSR_S_int,
      debug_changeMode => debug_changeMode_int,
      debug_setopcode => debug_setopcode_int,
      debug_exec_directSR => debug_exec_directSR_int,
      debug_exec_to_SR => debug_exec_to_SR_int,
      debug_pmove_dn_mode => open,
      debug_pmove_dn_regnum => open,
      debug_opcode => open,
      debug_state => open,
      debug_setstate => open,
      debug_last_opc_read => open,
      debug_data_read => open,
      debug_direct_data => open,
      debug_setnextpass => open,
      debug_TG68_PC => open,
      debug_memaddr_reg => open,
      debug_memaddr_delta => open,
      debug_memaddr_delta_rega => open,
      debug_memaddr_delta_regb => open,
      debug_addsub_q => open,
      debug_memmaskmux => open,
      debug_fline_opcode_latch => open,
      debug_pmmu_ea_mode_latched => open,
      debug_exec_direct_delta => open,
      debug_exec_directPC => open,
      debug_exec_mem_addsub => open,
      debug_set_addrlong => open,
      debug_mdelta_src => open,
      debug_pc_brw => open,
      debug_pc_word => open,
      debug_oddout => open,
      debug_decodeOPC => open,
      debug_brief => open,
      debug_moves_bus_pending => open,
      debug_moves_writeback_pending => open,
      debug_clkena_lw => open,
      debug_regfile_d0 => open,
      debug_regfile_d1 => open,
      debug_regfile_d2 => open,
      debug_regfile_d3 => open,
      debug_regfile_d4 => open,
      debug_regfile_d5 => open,
      debug_regfile_d6 => open,
      debug_regfile_d7 => open,
      debug_regfile_a0 => open,
      debug_regfile_a1 => open,
      debug_regfile_a2 => open,
      debug_regfile_a3 => open,
      debug_regfile_a4 => open,
      debug_regfile_a5 => open,
      debug_regfile_a6 => open,
      debug_regfile_a7 => open,
      debug_regfile_we => open,
      debug_regfile_waddr => open,
      debug_regfile_wdata => open,
      debug_fline_context_valid => open,
      debug_trap_1111 => open,
      debug_trapmake => open,
      debug_trap_illegal => open,
      debug_trap_priv => open,
      debug_trap_addr_error => open,
      debug_trap_berr => open,
      debug_trap_mmu_berr => open,
      debug_trap_vector => open,
      debug_pc_add => open,
      debug_pc_dataa => open,
      debug_pc_datab => open,
      debug_pmmu_brief => open,
      debug_use_base => open,
      debug_rf_source_addr => open,
      debug_pmove_ea_latched => open,
      debug_reg_QA => open,
      debug_pmmu_pending_flags => open,
      debug_pmmu_busy => open,
      debug_micro_state => open,
      debug_next_micro_state => open,
      debug_memmask => open,
      debug_sndOPC => open,
      debug_USP => open,
      debug_MSP => open,
      debug_ISP => open,
      debug_a7_is_msp => open,
      debug_interrupt_mode => open,
      debug_rte_saved_mbit => open
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
      inv_req       => cache_inv_req,
      cache_op_scope => cache_op_scope,
      cache_op_cache => cache_op_cache,
      cache_op_addr  => cache_op_addr,
      -- Instruction Cache Interface
      i_addr         => i_cache_addr,
      i_addr_phys    => pmmu_addr_phys,   -- Physical address from PMMU
      i_fc           => FC_int,
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
      d_fc           => FC_int,
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
   --i_cache_req <= '1' when (state="00" and CPU(1)='1' and cacr_ie='1') else '0';
   i_cache_req <= '1' when (state="00" and CPU(1)='1' and cacr_ie='1') else '0';
   i_fill_data <= cache_fill_buffer;
   -- Route fill completion only to the cache that owns the outstanding burst.
   i_fill_valid <= cache_fill_complete and cache_fill_owner_i;

   d_cache_addr <= ADDR;
   -- Data cache request only when CPU is 68030 AND cacr_de is enabled
   --d_cache_req <= '1' when ((state="10" or state="11") and CPU(1)='1' and cacr_de='1') else '0';
   d_cache_req <= '1' when ((state="10" or state="11") and CPU(1)='1' and cacr_de='1') else '0';
   d_cache_we <= not wr;
   d_cache_data_in <= data_write & data_write;  -- Replicate 16-bit data to 32-bit
   d_fill_data <= cache_fill_buffer;
   d_fill_valid <= cache_fill_complete and not cache_fill_owner_i;

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

   fill_pending_i <= i_fill_req and cacr_ibe;
   fill_pending_d <= d_fill_req and cacr_dbe;

   -- Cache memory interface - connect to SDRAM controller
   cache_req <= (cache_fill_active or (fill_pending_i or fill_pending_d)) when cache_enabled='1' else '0';
   cache_addr <= cache_fill_addr_latched when cache_fill_active='1' else
                 i_fill_addr when fill_pending_i='1' else
                 d_fill_addr;

   -- Burst mode control
   -- When IBE=1 (instruction) or DBE=1 (data), request burst transfer of 8 words
   -- Otherwise, request individual word transfers
   cache_burst <= '1' when (cache_enabled='1' and
                            (cache_fill_active='1' or fill_pending_i='1' or fill_pending_d='1')) else '0';
   cache_burst_len <= "111";  -- Always request 8 words (128-bit cache line)

   cache_fill_start <= '1' when (cache_fill_active='0' and cache_enabled='1' and
                                 (fill_pending_i='1' or fill_pending_d='1') and cache_ack='1') else '0';
   cache_fill_accept <= '1' when (cache_fill_active='1' and cache_ack='1') else '0';

   -- Cache fill process - accumulate 8 words into 128-bit cache line
   -- MC68030 cache lines are 16 bytes (128 bits) = 8 words of 16 bits each
   PROCESS (CLK, cpu1reset)
   BEGIN
      IF cpu1reset='0' THEN
         cache_fill_active <= '0';
         cache_fill_count <= "000";
         cache_fill_buffer <= (others => '0');
         cache_fill_complete <= '0';
         cache_fill_owner_i <= '0';
         cache_fill_addr_latched <= (others => '0');
      ELSIF rising_edge(CLK) THEN
         -- Default: clear completion pulse
         cache_fill_complete <= '0';

         IF cache_fill_start='1' THEN
            cache_fill_active <= '1';
            cache_fill_count <= "000";
            cache_fill_owner_i <= fill_pending_i;
            IF fill_pending_i='1' THEN
               cache_fill_addr_latched <= i_fill_addr;
            ELSE
               cache_fill_addr_latched <= d_fill_addr;
            END IF;
            cache_fill_buffer(15 downto 0) <= cache_data;
         ELSIF cache_fill_accept='1' THEN
            -- Accumulate 16-bit words into 128-bit cache line (8 words total)
            CASE cache_fill_count IS
               WHEN "000" => cache_fill_buffer(31 downto 16)   <= cache_data;
               WHEN "001" => cache_fill_buffer(47 downto 32)   <= cache_data;
               WHEN "010" => cache_fill_buffer(63 downto 48)   <= cache_data;
               WHEN "011" => cache_fill_buffer(79 downto 64)   <= cache_data;
               WHEN "100" => cache_fill_buffer(95 downto 80)   <= cache_data;
               WHEN "101" => cache_fill_buffer(111 downto 96)  <= cache_data;
               WHEN "110" => cache_fill_buffer(127 downto 112) <= cache_data;
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
