------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2020 Tobias Gubener                                   -- 
-- Patches by MikeJ, Till Harbaum, Rok Krajnk, ...                          --
-- Subdesign fAMpIGA by TobiFlex                                            --
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

-- 14.10.2020 TG bugfix chk2.b
-- 13.10.2020 TG go back to old aligned design and bugfix chk2
-- 11.10.2020 TG next try CHK2 flags
-- 10.10.2020 TG bugfix division N-flag
-- 09.10.2020 TG bugfix division overflow
-- 2/3.10.2020 some tweaks by retrofun, gyurco and robinsonb5
-- 17.03.2020 TG bugfix move data to (extended address)
-- 13.03.2020 TG bugfix extended addess mode - thanks Adam Polkosnik
-- 15.02.2020 TG bugfix DIVS.W with result $8000
-- 08.01.2020 TH fix the byte-mirroring
-- 25.11.2019 TG bugfix ILLEGAL.B handling
-- 24.11.2019 TG next try CMP2 and CHK2.l
-- 24.11.2019 retrofun(RF) commit ILLEGAL.B handling 
-- 18.11.2019 TG insert CMP2 and CHK2.l
-- 17.11.2019 TG insert CAS and CAS2
-- 10.11.2019 TG insert TRAPcc
-- 08.11.2019 TG bugfix movem in 68020 mode
-- 06.11.2019 TG bugfix CHK
-- 06.11.2019 TG bugfix flags and stackframe DIVU
-- 04.11.2019 TG insert RTE from TH
-- 03.11.2019 TG insert TrapV from TH 
-- 03.11.2019 TG bugfix MUL 64Bit 
-- 03.11.2019 TG rework barrel shifter - some other tweaks
-- 02.11.2019 TG bugfig N-Flag and Z-Flag for DIV
-- 30.10.2019 TG bugfix RTR in 68020-mode
-- 30.10.2019 TG bugfix BFINS again
-- 19.10.2019 TG insert some bugfixes from apolkosnik
-- 05.12.2018 TG insert RTD opcode
-- 03.12.2018 TG insert barrel shifter
-- 01.11.2017 TG bugfix V-Flag for ASL/ASR - thanks Peter Graf
-- 29.05.2017 TG decode 0x4AFB as illegal, needed for QL BKP - thanks Peter Graf
-- 21.05.2017 TG insert generic for hardware multiplier for MULU & MULS
-- 04.04.2017 TG change GPL to LGPL
-- 04.04.2017 TG BCD handling with all undefined behavior! 
-- 02.04.2017 TG bugfix Bitfield Opcodes 
-- 19.03.2017 TG insert PACK/UNPACK  
-- 19.03.2017 TG bugfix CMPI ...(PC) - thanks Till Harbaum
--     ???    MJ bugfix non_aligned movem access
-- add berr handling 10.03.2013 - needed for ATARI Core

-- bugfix session 07/08.Feb.2013
-- movem ,-(an)
-- movem (an)+,          - thanks  Gerhard Suttner
-- btst dn,#data         - thanks  Peter Graf
-- movep                 - thanks  Till Harbaum
-- IPL vector            - thanks  Till Harbaum
--  

-- optimize Register file

-- to do 68010:
-- (MOVEC)
-- BKPT
-- MOVES
--
-- to do 68020:
-- (CALLM)
-- (RETM)

-- bugfix CHK2, CMP2
-- rework barrel shifter 
-- CHK2
-- CMP2
-- cpXXX Coprozessor stuff

-- done 020:
-- CAS, CAS2
-- TRAPcc
-- PACK
-- UNPK
-- Bitfields
-- address modes
-- long bra
-- DIVS.L, DIVU.L
-- LINK long
-- MULS.L, MULU.L
-- extb.l

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use work.TG68K_Pack.all;

entity TG68KdotC_Kernel is
	generic(
		SR_Read : integer:= 2;				--0=>user,		1=>privileged,		2=>switchable with CPU(0)
		VBR_Stackframe : integer:= 2;		--0=>no,			1=>yes/extended,	2=>switchable with CPU(0)
		extAddr_Mode : integer:= 2;		--0=>no,			1=>yes,				2=>switchable with CPU(1)
		MUL_Mode : integer := 2;			--0=>16Bit,		1=>32Bit,			2=>switchable with CPU(1),  3=>no MUL,  
		DIV_Mode : integer := 2;			--0=>16Bit,		1=>32Bit,			2=>switchable with CPU(1),  3=>no DIV,  
		BitField : integer := 2;			--0=>no,			1=>yes,				2=>switchable with CPU(1) 
		
		BarrelShifter : integer := 1;		--0=>no,			1=>yes,				2=>switchable with CPU(1)  
		MUL_Hardware : integer := 1		--0=>no,			1=>yes,  
		);
	port(clk						: in std_logic;
		nReset					: in std_logic;			--low active
		clkena_in				: in std_logic:='1';
		data_in					: in std_logic_vector(15 downto 0);
		IPL						: in std_logic_vector(2 downto 0):="111";
		IPL_autovector			: in std_logic:='0';
		berr						: in std_logic:='0';					-- only 68000 Stackpointer dummy
		CPU						: in std_logic_vector(1 downto 0);  -- 00->68000  01->68010  10->68030 (with PMMU)
		addr_out					: out std_logic_vector(31 downto 0);
		data_write				: out std_logic_vector(15 downto 0);
		nWr						: out std_logic;
		nUDS						: out std_logic;
		nLDS						: out std_logic;
		busstate					: out std_logic_vector(1 downto 0);	-- 00-> fetch code 10->read data 11->write data 01->no memaccess
		longword					: out std_logic;
		nResetOut				: out std_logic;
		FC							: out std_logic_vector(2 downto 0);
		clr_berr					: out std_logic;
-- for debug
		skipFetch				: out std_logic;
		regin_out				: out std_logic_vector(31 downto 0);
		CACR_out					: out std_logic_vector(31 downto 0);
		VBR_out					: out std_logic_vector(31 downto 0);
-- Cache control interface (68030)
		cache_inv_req			: out std_logic;  -- Cache invalidation request (from CACR bits)
		cache_op_scope			: out std_logic_vector(1 downto 0);
		cache_op_cache			: out std_logic_vector(1 downto 0);
		cacr_ie					: out std_logic;
		cacr_de					: out std_logic;
		cacr_ifreeze				: out std_logic;
		cacr_dfreeze				: out std_logic;
		cacr_ibe				: out std_logic;  -- Instruction Burst Enable (CACR bit 4)
		cacr_dbe				: out std_logic;  -- Data Burst Enable (CACR bit 12)
		cacr_wa				: out std_logic;  -- Write Allocate (CACR bit 13)
-- PMMU register interface (68030)
		pmmu_reg_we				: out std_logic;
		pmmu_reg_re				: out std_logic;
		pmmu_reg_sel			: out std_logic_vector(4 downto 0);
		pmmu_reg_wdat			: out std_logic_vector(31 downto 0);
		pmmu_reg_part			: out std_logic;
-- PMMU address interface (68030)
		pmmu_addr_log			: out std_logic_vector(31 downto 0);
		pmmu_addr_phys			: out std_logic_vector(31 downto 0);
		pmmu_cache_inhibit		: out std_logic;
-- Cache operation address (68030)
		cache_op_addr			: out std_logic_vector(31 downto 0);
-- PMMU walker memory interface (68030) - connects to real memory via cpu_wrapper
		pmmu_walker_req		: out std_logic;
		pmmu_walker_we		: out std_logic;  -- MC68030 U/M bit: write enable for descriptor updates
		pmmu_walker_addr		: out std_logic_vector(31 downto 0);
		pmmu_walker_wdat		: out std_logic_vector(31 downto 0);  -- MC68030 U/M bit: write data
		pmmu_walker_ack		: in  std_logic;
		pmmu_walker_data		: in  std_logic_vector(31 downto 0);
		pmmu_walker_berr		: in  std_logic;  -- MC68030: Bus error during table walk (sets MMUSR B bit)
-- DEBUG: Supervisor mode tracking signals
		debug_SVmode			: out std_logic;
		debug_preSVmode		: out std_logic;
		debug_FlagsSR_S		: out std_logic;
		debug_changeMode		: out std_logic;
		debug_setopcode		: out std_logic;
		debug_exec_directSR	: out std_logic;
		debug_exec_to_SR		: out std_logic;
-- DEBUG: PMOVE Dn simplified mechanism (BUG #70)
		debug_pmove_dn_mode : out std_logic;
		debug_pmove_dn_regnum : out std_logic_vector(2 downto 0);
-- DEBUG: BUG #213 - Export internal opcode being decoded
		debug_opcode : out std_logic_vector(15 downto 0);
-- DEBUG: BUG #213 - Pipeline debugging
		debug_state : out std_logic_vector(1 downto 0);
		debug_setstate : out std_logic_vector(1 downto 0);
		debug_last_opc_read : out std_logic_vector(15 downto 0);
		debug_data_read : out std_logic_vector(31 downto 0);
		debug_direct_data : out std_logic;
		debug_setnextpass : out std_logic;
-- DEBUG: BUG #213 - Address generation and opcode capture
		debug_TG68_PC : out std_logic_vector(31 downto 0);
		debug_memaddr_reg : out std_logic_vector(31 downto 0);
		debug_memaddr_delta : out std_logic_vector(31 downto 0);
		debug_oddout : out std_logic;
		debug_decodeOPC : out std_logic;
-- DEBUG: MOVES instruction trace signals
		debug_brief : out std_logic_vector(15 downto 0);
		debug_moves_bus_pending : out std_logic;
		debug_moves_writeback_pending : out std_logic;
		debug_clkena_lw : out std_logic;
		debug_regfile_d0 : out std_logic_vector(31 downto 0);
		debug_regfile_a0 : out std_logic_vector(31 downto 0);
-- DEBUG: F-line exception diagnosis
		debug_fline_context_valid : out std_logic;
		debug_trap_1111 : out std_logic;
		debug_trapmake : out std_logic;
		debug_pmmu_brief : out std_logic_vector(15 downto 0);
-- DEBUG: Address computation diagnosis
		debug_use_base : out std_logic;
		debug_rf_source_addr : out std_logic_vector(3 downto 0);
		debug_pmove_ea_latched : out std_logic_vector(31 downto 0);
		debug_reg_QA : out std_logic_vector(31 downto 0);
-- DEBUG: Extended debug ports for comprehensive testbench
		debug_last_data_read : out std_logic_vector(31 downto 0);
		debug_last_opc_pc : out std_logic_vector(31 downto 0);
		debug_getbrief : out std_logic;
		debug_get_2ndopc : out std_logic;
		debug_fline_brief_pending : out std_logic;
		debug_fline_opcode_pc : out std_logic_vector(31 downto 0);
		debug_exe_PC : out std_logic_vector(31 downto 0);
		debug_memaddr_delta_rega : out std_logic_vector(31 downto 0);
		debug_memaddr_delta_regb : out std_logic_vector(31 downto 0);
		debug_addsub_q : out std_logic_vector(31 downto 0);
		debug_memmaskmux : out std_logic_vector(5 downto 0);
		debug_fline_opcode_latch : out std_logic_vector(15 downto 0);
		debug_pmmu_ea_mode_latched : out std_logic_vector(5 downto 0);
		debug_exec_direct_delta : out std_logic;
		debug_exec_directPC : out std_logic;
		debug_exec_mem_addsub : out std_logic;
		debug_set_addrlong : out std_logic;
		debug_mdelta_src : out std_logic_vector(7 downto 0);
		debug_pc_brw : out std_logic;
		debug_pc_word : out std_logic;
		debug_regfile_d1 : out std_logic_vector(31 downto 0);
		debug_regfile_d2 : out std_logic_vector(31 downto 0);
		debug_regfile_d3 : out std_logic_vector(31 downto 0);
		debug_regfile_d4 : out std_logic_vector(31 downto 0);
		debug_regfile_d5 : out std_logic_vector(31 downto 0);
		debug_regfile_d6 : out std_logic_vector(31 downto 0);
		debug_regfile_d7 : out std_logic_vector(31 downto 0);
		debug_regfile_a1 : out std_logic_vector(31 downto 0);
		debug_regfile_a2 : out std_logic_vector(31 downto 0);
		debug_regfile_a3 : out std_logic_vector(31 downto 0);
		debug_regfile_a4 : out std_logic_vector(31 downto 0);
		debug_regfile_a5 : out std_logic_vector(31 downto 0);
		debug_regfile_a6 : out std_logic_vector(31 downto 0);
		debug_regfile_a7 : out std_logic_vector(31 downto 0);
		debug_regfile_we : out std_logic;
		debug_regfile_waddr : out std_logic_vector(3 downto 0);
		debug_regfile_wdata : out std_logic_vector(31 downto 0);
		debug_trap_illegal : out std_logic;
		debug_trap_priv : out std_logic;
		debug_trap_addr_error : out std_logic;
		debug_trap_berr : out std_logic;
		debug_trap_mmu_berr : out std_logic;
		debug_trap_vector : out std_logic_vector(31 downto 0);
		debug_pc_add : out std_logic_vector(31 downto 0);
		debug_pc_dataa : out std_logic_vector(31 downto 0);
		debug_pc_datab : out std_logic_vector(31 downto 0);
		debug_pmmu_busy : out std_logic;
		debug_micro_state : out integer range 0 to 255;
		debug_next_micro_state : out integer range 0 to 255;
		debug_memmask : out std_logic_vector(5 downto 0);
		debug_sndOPC : out std_logic_vector(15 downto 0);
		debug_pmmu_reg_we : out std_logic;
		debug_pmmu_reg_re : out std_logic;
		debug_pmmu_reg_sel : out std_logic_vector(4 downto 0);
		debug_pmmu_reg_wdat : out std_logic_vector(31 downto 0);
		debug_pmmu_reg_part : out std_logic;
		debug_pmmu_reg_rdat : out std_logic_vector(31 downto 0);
		debug_make_berr : out std_logic;
		debug_pmmu_fault : out std_logic
		);
end TG68KdotC_Kernel;

architecture logic of TG68KdotC_Kernel is


	signal use_VBR_Stackframe	: std_logic;

	signal syncReset			: std_logic_vector(3 downto 0);
	signal Reset				: std_logic;
	signal clkena_lw			: std_logic;
	signal TG68_PC				: std_logic_vector(31 downto 0);
	signal tmp_TG68_PC		: std_logic_vector(31 downto 0);
	signal TG68_PC_add		: std_logic_vector(31 downto 0);
	signal PC_dataa			: std_logic_vector(31 downto 0);
	signal PC_datab			: std_logic_vector(31 downto 0);
	signal memaddr				: std_logic_vector(31 downto 0);
	signal state				: std_logic_vector(1 downto 0);
	signal datatype			: std_logic_vector(1 downto 0);
	signal set_datatype		: std_logic_vector(1 downto 0);
	signal exe_datatype		: std_logic_vector(1 downto 0);
	signal setstate			: std_logic_vector(1 downto 0);
	signal setaddrvalue		: std_logic;
	signal addrvalue			: std_logic;

	signal opcode				: std_logic_vector(15 downto 0);
	signal exe_opcode			: std_logic_vector(15 downto 0);
	signal sndOPC				: std_logic_vector(15 downto 0);

	signal exe_pc				: std_logic_vector(31 downto 0);--TH
	signal last_opc_pc		: std_logic_vector(31 downto 0);--TH
	signal last_opc_read		: std_logic_vector(15 downto 0);
	signal registerin			: std_logic_vector(31 downto 0);
	signal reg_QA				: std_logic_vector(31 downto 0);
	signal reg_QB				: std_logic_vector(31 downto 0);
	signal Wwrena,Lwrena		: bit;
	signal Bwrena				: bit;
	signal Regwrena_now		: bit;
	signal rf_dest_addr		: std_logic_vector(3 downto 0);
	signal rf_source_addr	: std_logic_vector(3 downto 0);
	signal rf_source_addrd	: std_logic_vector(3 downto 0);
   
	signal regin				: std_logic_vector(31 downto 0);
	type   regfile_t is array(0 to 15) of std_logic_vector(31 downto 0);
	signal regfile				: regfile_t := (OTHERS => (OTHERS => '0')); -- mikej stops sim X issues;
	signal RDindex_A			: integer range 0 to 15;
	signal RDindex_B			: integer range 0 to 15;
	signal WR_AReg				: std_logic;


	signal addr					: std_logic_vector(31 downto 0);
	signal memaddr_reg		: std_logic_vector(31 downto 0);
	signal memaddr_delta		: std_logic_vector(31 downto 0);
	signal memaddr_delta_rega	: std_logic_vector(31 downto 0);
	signal memaddr_delta_regb	: std_logic_vector(31 downto 0);
	signal use_base			: bit;
	
	signal ea_data				: std_logic_vector(31 downto 0);
	signal OP1out				: std_logic_vector(31 downto 0);
	signal OP2out				: std_logic_vector(31 downto 0);
	signal OP1outbrief		: std_logic_vector(15 downto 0);
	signal OP1in				: std_logic_vector(31 downto 0);
	signal ALUout	: std_logic_vector(31 downto 0);
	signal data_write_tmp	: std_logic_vector(31 downto 0);
	signal data_write_muxin	: std_logic_vector(31 downto 0);
	signal data_write_mux	: std_logic_vector(47 downto 0);
	signal nextpass			: bit;
	signal setnextpass		: bit;
	signal setdispbyte		: bit;
	signal setdisp				: bit;
	signal regdirectsource	:bit;		-- checken !!!
	signal addsub_q			: std_logic_vector(31 downto 0);
	signal briefdata			: std_logic_vector(31 downto 0);
	signal c_out				: std_logic_vector(2 downto 0);

	signal mem_address		: std_logic_vector(31 downto 0);
	signal memaddr_a			: std_logic_vector(31 downto 0);

	-- BUG #197 FIX V6: Latch the DISPLACEMENT during ld_dAn1, not the final address
	-- memaddr_a contains displacement only when setdisp='1' (during ld_dAn1)
	-- After ld_dAn1, setdisp='0' resets memaddr_a to zero
	-- So we must preserve the displacement value to use in pmove states
	signal pmove_disp_latched : std_logic_vector(31 downto 0);  -- Latched displacement
	signal pmove_ea_latched	: std_logic_vector(31 downto 0);
	signal pmove_ea_captured : std_logic := '0';  -- BUG #289: Flag to capture EA only once per instruction

	signal TG68_PC_brw		: bit;
	signal TG68_PC_word		: bit;
	signal getbrief			: bit;
	signal brief				: std_logic_vector(15 downto 0);
	signal data_is_source	: bit;
	signal store_in_tmp		: bit;
	signal write_back			: bit;
	signal exec_write_back	: bit;
	signal setstackaddr		: bit;
	signal writePC				: bit;
	signal writePCbig			: bit;
	signal set_writePCbig	: bit;
	signal writePCnext		: bit;
	signal setopcode			: bit;
	signal decodeOPC			: bit;
	signal execOPC				: bit;
	signal execOPC_ALU		: bit;
	signal setexecOPC			: bit;
	signal endOPC				: bit;
	signal setendOPC			: bit;
	signal Flags				: std_logic_vector(7 downto 0);	-- ...XNZVC
	signal FlagsSR				: std_logic_vector(7 downto 0);	-- T.S.0III
	signal SRin					: std_logic_vector(7 downto 0);
	signal exec_DIRECT		: bit;
	signal exec_tas			: std_logic;
	signal set_exec_tas		: std_logic;

	signal exe_condition		: std_logic;
	signal ea_only				: bit;
	signal source_areg		: std_logic;
	signal source_lowbits	: bit;
	-- BUG #149 FIX: Track MOVES bus access in progress
	-- This signal is set when moves1 schedules a bus access and cleared when it completes
	-- It's used to maintain source_areg/source_lowbits and prevent address corruption
	signal moves_bus_pending : std_logic := '0';
	signal moves_ea_areg     : std_logic := '0';  -- Latched: is EA an address register mode?
	signal moves_ea_regnum   : std_logic_vector(2 downto 0) := "000";  -- Latched EA register number
	-- MOVES (d16,An) and (d8,An,Xn): extra sequencing for extension words after MOVES extension.
	signal moves_d16_phase   : std_logic := '0';
	-- BUG #214: MOVES mem->CPU writeback guard - ensures destination register selection persists until writeback completes
	signal moves_writeback_pending : std_logic := '0';
	signal moves_active : std_logic := '0';
	-- BUG #318: Latched MOVES extension word fields
	-- For indexed/absolute EA modes, brief gets overwritten with the EA extension word.
	-- These latched values preserve the MOVES-specific info (direction and register).
	signal moves_direction : std_logic := '0';  -- Latched brief(11): 0=mem->CPU(SFC), 1=CPU->mem(DFC)
	signal moves_reg : std_logic_vector(3 downto 0) := "0000";  -- Latched brief(15:12): D/A + reg#
	-- BUG #322: Latched EA for MOVES complex addressing modes (d16,An), (d8,An,Xn), (xxx).W/L
	-- The EA computed during ld_dAn1/ld_AnXn2/ld_nn is only valid for one cycle in memaddr_delta_rega.
	-- By the time moves1 executes, it's overwritten. These signals preserve the EA.
	signal moves_ea_latched : std_logic_vector(31 downto 0) := (others => '0');
	signal moves_ea_use_base : bit := '0';  -- '1'=displacement mode (use reg_QA base), '0'=absolute
	signal source_LDRLbits 	: bit;
	signal source_LDRMbits 	: bit;
	signal source_2ndHbits	: bit;
	signal source_2ndMbits	: bit;
	signal source_2ndLbits	: bit;
	signal dest_areg			: std_logic;
	signal dest_LDRareg		: std_logic;
	signal dest_LDRHbits		: bit;
	signal dest_LDRLbits		: bit;
	signal dest_2ndHbits		: bit;
	signal dest_2ndLbits		: bit;
	signal dest_hbits			: bit;
	signal rot_bits			: std_logic_vector(1 downto 0);
	signal set_rot_bits		: std_logic_vector(1 downto 0);
	signal rot_cnt				: std_logic_vector(5 downto 0);
	signal set_rot_cnt		: std_logic_vector(5 downto 0);
	signal movem_actiond		: bit;
	signal movem_regaddr		: std_logic_vector(3 downto 0);
	signal movem_mux			: std_logic_vector(3 downto 0);
	signal movem_presub		: bit;
	signal movem_run			: bit;
	signal ea_calc_b			: std_logic_vector(31 downto 0);
	signal set_direct_data	: bit;
	signal use_direct_data	: bit;
	signal direct_data		: bit;

	signal set_V_Flag			: bit;
	signal set_vectoraddr	: bit;
	signal writeSR				: bit;
	signal trap_berr			: bit;
	signal trap_illegal		: bit;
	signal trap_addr_error	: bit;
	signal trap_priv			: bit;
	signal trap_trace			: bit;
	signal trap_1010			: bit;
	signal trap_1111			: bit;
	signal trap_trap			: bit;
	signal trap_trapv			: bit;
	signal trap_interrupt	: bit;
	signal trap_mmu_config	: bit;  -- MC68030 MMU Configuration Exception (vector 56)
	signal trap_mmu_berr    : bit;  -- BUG #159: MC68030 MMU Bus Error (vector 61)
	signal trap_format_error : bit; -- BUG #211: MC68030 Format Error during RTE (vector 14)
	signal rte_format_word  : std_logic_vector(15 downto 0);
	-- Note: Vectors 57 ($E4) and 58 ($E8) are 68851-only, not used on MC68030
	signal trapmake			: bit;
	signal trapd				: bit;
	signal trap_SR				: std_logic_vector(7 downto 0);
	signal make_trace			: std_logic;
	signal make_berr			: std_logic;
	signal make_mmu_berr     : std_logic;  -- BUG #159: Distinguish MMU bus error from normal BERR
	signal berr_exception_active : std_logic;  -- MC68030: Bus error exception processing window
	signal cpu_halted        : std_logic;  -- MC68030: Double bus fault halt (cleared only by reset)
	signal pmmu_fault_dispatched : std_logic;  -- BUG #400: Tracks if current pmmu_fault was already dispatched as bus error
	signal useStackframe2	: std_logic;
	
	signal set_stop			: bit;
	signal stop					: bit;
	signal trap_vector		: std_logic_vector(31 downto 0);
	signal trap_vector_vbr	: std_logic_vector(31 downto 0);
	signal USP					: std_logic_vector(31 downto 0);
	signal SSP					: std_logic_vector(31 downto 0);  -- Supervisor Stack Pointer (68000/68010)
	signal MSP					: std_logic_vector(31 downto 0);  -- BUG #18: Master Stack Pointer (68020+)
	signal ISP					: std_logic_vector(31 downto 0);  -- BUG #18: Interrupt Stack Pointer (68020+)
	signal interrupt_mode		: std_logic := '0';  -- BUG #18: 0=normal supervisor, 1=interrupt processing
	signal format1_chain_active : std_logic := '0';  -- MC68030: Set during Format $1 RTE dual-frame chain
--	signal illegal_write_mode	: bit;
--	signal illegal_read_mode	: bit;
--	signal illegal_byteaddr		: bit;

	signal IPL_nr				: std_logic_vector(2 downto 0);
	signal rIPL_nr				: std_logic_vector(2 downto 0);
	signal IPL_vec				: std_logic_vector(7 downto 0);
	signal interrupt			: bit;
	signal setinterrupt		: bit;
	signal SVmode				: std_logic;
	signal preSVmode			: std_logic;
	signal Suppress_Base		: bit;
	signal set_Suppress_Base: bit;
	signal set_Z_error 		: bit;
	signal Z_error 			: bit;
	signal ea_build_now		: bit;	
	signal build_logical		: bit;	
	signal build_bcd			: bit;	
	
	signal data_read			: std_logic_vector(31 downto 0);
	signal bf_ext_in			: std_logic_vector(7 downto 0);
	signal bf_ext_out			: std_logic_vector(7 downto 0);
--	signal byte					: bit;
	signal long_start			: bit;
	signal long_start_alu	: bit;
	signal non_aligned		: std_logic;
	signal check_aligned		: std_logic;
	signal long_done			: bit;
	signal memmask				: std_logic_vector(5 downto 0);
	signal set_memmask		: std_logic_vector(5 downto 0);
	signal memread				: std_logic_vector(3 downto 0);
	signal wbmemmask			: std_logic_vector(5 downto 0);
	signal memmaskmux			: std_logic_vector(5 downto 0);
	signal oddout				: std_logic;
	signal set_oddout			: std_logic;
	signal PCbase				: std_logic;
	signal set_PCbase			: std_logic;
		 
	signal last_data_read	: std_logic_vector(31 downto 0);
	signal last_data_in		: std_logic_vector(31 downto 0);

	signal bf_offset			: std_logic_vector(5 downto 0);
	signal bf_width			: std_logic_vector(5 downto 0);
	signal bf_bhits			: std_logic_vector(5 downto 0);
	signal bf_shift			: std_logic_vector(5 downto 0);
	signal alu_width			: std_logic_vector(5 downto 0);
	signal alu_bf_shift		: std_logic_vector(5 downto 0);
	signal bf_loffset			: std_logic_vector(5 downto 0);
	signal bf_full_offset	: std_logic_vector(31 downto 0);
	signal alu_bf_ffo_offset: std_logic_vector(31 downto 0);
	signal alu_bf_loffset	: std_logic_vector(5 downto 0);

	signal movec_data			: std_logic_vector(31 downto 0);
	signal VBR					: std_logic_vector(31 downto 0);
	signal CACR					: std_logic_vector(31 downto 0);
	-- 68020/030 Cache Address Register (CAAR). Present for compatibility; no side effects here.
	signal CAAR                : std_logic_vector(31 downto 0);
	signal DFC					: std_logic_vector(2 downto 0);
	signal SFC					: std_logic_vector(2 downto 0);

	-- PMMU (68030) interface signals (Phase 1 scaffold)
		-- PMMU register signals (now declared as output ports)
	signal pmmu_reg_rdat    : std_logic_vector(31 downto 0);
	signal pmmu_src_data    : std_logic_vector(31 downto 0);
	signal pmmu_dn_data     : std_logic_vector(31 downto 0);  -- BUG #39: Direct register file read for Dn mode
	-- BUG #70 SIMPLIFICATION (per BUILD_238): Simple 2-signal mechanism
	-- BUILD_238 showed complex queue (for DESTINATION) was broken, simple mechanism (for SOURCE) worked
	-- Unify both SOURCE and DESTINATION to use same simple capture/clear mechanism
	signal pmove_dn_regnum  : std_logic_vector(2 downto 0);   -- Data register selector (D0-D7) captured in pmove_decode state
	signal pmove_dn_mode    : std_logic;                      -- Flag: '1' when PMOVE uses Dn mode (set in pmove_decode, cleared in setexecOPC)
	signal pmove_mmu_read_active : std_logic;                 -- Flag: '1' when PMOVE MMU->memory is active
	-- F-Line instruction context latch (captures at decode time for stable values)
	signal fline_opcode_latch  : std_logic_vector(15 downto 0) := (others => '0');
	signal fline_opcode_pc     : std_logic_vector(31 downto 0) := (others => '0');
	signal fline_brief_latch   : std_logic_vector(15 downto 0) := (others => '0');
	signal fline_context_valid : std_logic := '0';
	signal fline_is_pmmu       : std_logic := '0';
	signal fline_is_fpu        : std_logic := '0';
	signal fline_has_brief     : std_logic := '0';
	signal pmmu_ea_mode_latched  : std_logic_vector(5 downto 0);  -- BUG #302: Latch EA mode+reg bits
	-- Helper signals: use latched values when F-line context valid
	signal pmmu_brief          : std_logic_vector(15 downto 0);
	signal pmmu_opcode         : std_logic_vector(15 downto 0);
	signal pmmu_reg_part_d  : std_logic;
	signal pmmu_reg_we_d    : std_logic;
	signal pmmu_reg_re_d    : std_logic;
	signal pmmu_reg_sel_d   : std_logic_vector(4 downto 0);
	signal pmmu_reg_sel_int : std_logic_vector(4 downto 0);  -- BUG #119: Internal signal for VHDL-93 compatibility
	signal pmmu_reg_sel_valid : boolean;  -- Valid selector gating for PMMU register access
	-- BUG #53 FIX: 1-stage pipeline - these 2-stage signals no longer needed
	-- signal pmmu_reg_sel_pending : std_logic;  -- REMOVED: Old 2-stage pipeline
	-- signal pmmu_reg_sel_latch : std_logic_vector(15 downto 0);  -- REMOVED: Old 2-stage pipeline
	signal pmmu_reg_wdat_d  : std_logic_vector(31 downto 0);
	signal pmmu_reg_fd_d    : std_logic;

	-- DIAGNOSTIC: Track brief and pmmu_reg_sel_d timing
	signal dbg_brief_capture : std_logic_vector(15 downto 0);
	signal dbg_pmmu_reg_sel_when_set : std_logic_vector(4 downto 0);
	signal dbg_brief_when_sel_set : std_logic_vector(15 downto 0);

	signal pmmu_req         : std_logic;
	signal pmmu_is_insn     : std_logic;
	signal pmmu_rw          : std_logic;
	signal pmmu_fc          : std_logic_vector(2 downto 0);
	signal pmmu_fc_from_dn  : std_logic_vector(2 downto 0);  -- FC value from Dn register for PTEST/PLOAD/PFLUSH
	signal pmmu_addr_log_int : std_logic_vector(31 downto 0);
	signal pmmu_addr_phys_int : std_logic_vector(31 downto 0);
	signal pmmu_desc_addr : std_logic_vector(31 downto 0); -- Physical address of last descriptor
	signal pmmu_debug_mmusr : std_logic_vector(15 downto 0); -- Direct MMUSR readout from PMMU
	signal pmmu_ptest_a : std_logic; -- Control signal for PTEST/PLOAD A-bit writeback
	
	-- Cache operation control signals
	signal cache_op_scope_int : std_logic_vector(1 downto 0);
	signal cache_op_cache_int : std_logic_vector(1 downto 0);
	signal pmmu_ch_inhibit  : std_logic;
	signal pmmu_wr_protect  : std_logic;
	signal pmmu_fault       : std_logic;
	signal pmmu_fault_stat  : std_logic_vector(31 downto 0);
	signal pmmu_tc_en       : std_logic;
	
	-- PMMU instruction control signals
	signal pmmu_ptest_req   : std_logic;
	signal pmmu_pflush_req  : std_logic;
	signal pmmu_pload_req   : std_logic;
	signal pmmu_cmd_fc      : std_logic_vector(2 downto 0);
	signal pmmu_cmd_addr    : std_logic_vector(31 downto 0);
	signal pmmu_cmd_rw      : std_logic;  -- For PTEST/PLOAD: 0=write test, 1=read test
	signal pmmu_cmd_brief   : std_logic_vector(15 downto 0);  -- Store brief word for PMMU instructions
	
	-- Cache control signals (declared as output ports, no need for internal signals)

	-- PMMU walker memory interface (internal stub - will be connected to real memory in future)
	signal pmmu_mem_req   : std_logic;
	signal pmmu_mem_we    : std_logic;  -- MC68030 U/M bit: write enable for descriptor updates
	signal pmmu_mem_addr  : std_logic_vector(31 downto 0);
	signal pmmu_mem_wdat  : std_logic_vector(31 downto 0);  -- MC68030 U/M bit: write data
	signal pmmu_mem_ack   : std_logic;
	signal pmmu_mem_berr  : std_logic;  -- Bus error during walker access (sets MMUSR B bit)
	signal pmmu_mem_rdat  : std_logic_vector(31 downto 0);
	signal pmmu_busy      : std_logic;
	signal pmmu_config_err : std_logic;
	signal pmmu_config_ack : std_logic;  -- BUG #154: Acknowledge MMU config exception to clear error

	-- Internal FC signal (VHDL-93 compatibility)
	signal fc_internal    : std_logic_vector(2 downto 0);
	

	signal set					: bit_vector(lastOpcBit downto 0);
	signal set_exec			: bit_vector(lastOpcBit downto 0);
	signal exec					: bit_vector(lastOpcBit downto 0);

	signal micro_state		: micro_states;
	signal next_micro_state	: micro_states;


--   -- Function to map brief(11:8) to PMMU register select
--   function pmmu_sel_from_brief(b : std_logic_vector(14 downto 10)) return std_logic_vector is
--     variable s : std_logic_vector(3 downto 0);
--   begin
--     case b is
--       when "00010" => s := x"0"; -- TT0 (Transparent Translation 0) - 0x02
--       when "00011" => s := x"1"; -- TT1 (Transparent Translation 1) - 0x03
--       when "10000" => s := x"2"; -- TC (Translation Control) - 0x10
--       when "10010" => s := x"3"; -- SRP (Supervisor Root Pointer) - 0x12
--       when "10011" => s := x"4"; -- CRP (CPU Root Pointer) - 0x13
--       when "11000" => s := x"5"; -- MMUSR (MMU Status Register) - 0x18
--       when others => s := x"6"; -- invalid/not supported
--     end case;
--     return s;
--   end function;


BEGIN  

  -- PMMU (68030) instance (identity translation for now)
  PMMU_030: entity work.TG68K_PMMU_030
    port map(
      clk           => clk,
      nreset        => nReset,

      reg_we        => pmmu_reg_we_d,
      reg_re        => pmmu_reg_re_d,
      -- BUG #119 FIX: Use combinational pmmu_reg_sel_int instead of registered pmmu_reg_sel_d
      -- pmmu_reg_sel_int uses brief(14:10) directly when write enable is active
      reg_sel       => pmmu_reg_sel_int,
      -- BUG #119 FIX: Use combinational pmmu_src_data instead of registered pmmu_reg_wdat_d
      -- pmmu_reg_we_d is combinational (fires on set_exec(pmmu_wr)), but pmmu_reg_wdat_d
      -- is registered (latched on next clock edge). This timing mismatch means PMMU sees
      -- reg_we='1' but reg_wdat still has OLD value (0 if first PMOVE).
      -- pmmu_src_data is combinational and has correct value when reg_we asserts.
      reg_wdat      => pmmu_src_data,
      reg_rdat      => pmmu_reg_rdat,
      reg_part      => pmmu_reg_part_d,
      reg_fd        => pmmu_reg_fd_d,

      ptest_req     => pmmu_ptest_req,
      pflush_req    => pmmu_pflush_req,
      pload_req     => pmmu_pload_req,
      pmmu_fc       => pmmu_cmd_fc,
      pmmu_addr     => pmmu_cmd_addr,
      pmmu_brief    => brief,

      req           => pmmu_req,
      is_insn       => pmmu_is_insn,
      rw            => pmmu_rw,
      fc            => pmmu_fc,
      addr_log      => pmmu_addr_log_int,
      addr_phys     => pmmu_addr_phys_int,
      cache_inhibit => pmmu_ch_inhibit,
      write_protect => pmmu_wr_protect,
      fault         => pmmu_fault,
      fault_status  => pmmu_fault_stat,
      tc_enable     => pmmu_tc_en,
      mem_req       => pmmu_mem_req,
      mem_we        => pmmu_mem_we,
      mem_addr      => pmmu_mem_addr,
      mem_wdat      => pmmu_mem_wdat,
      mem_ack       => pmmu_mem_ack,
      mem_berr      => pmmu_mem_berr,  -- Bus error from external watchdog/timeout
      mem_rdat      => pmmu_mem_rdat,
      busy          => pmmu_busy,
      mmu_config_err => pmmu_config_err,
      mmu_config_ack => pmmu_config_ack, -- BUG #154: Acknowledge to clear error
      ptest_desc_addr => pmmu_desc_addr, -- Physical address of last descriptor
      debug_mmusr => pmmu_debug_mmusr
    );

--   -- PMMU register interface connected (enabled for 68030)
--   pmmu_reg_we   <= pmmu_reg_we_d when CPU = "11" else '0';
--   pmmu_reg_re   <= pmmu_reg_re_d when CPU = "11" else '0';
--   pmmu_reg_sel  <= pmmu_reg_sel_d when CPU = "11" else (others => '0');
--   pmmu_reg_wdat <= pmmu_reg_wdat_d when CPU = "11" else (others => '0');
--   pmmu_reg_part <= pmmu_reg_part_d when CPU = "11" else '0';

  -- F-Line Context: Helper signals select latched values when context valid
  pmmu_brief  <= fline_brief_latch when fline_context_valid = '1' else brief;
  pmmu_opcode <= fline_opcode_latch when fline_context_valid = '1' else opcode;

  -- PMMU register interface connected (enabled for 68020-30)
  pmmu_reg_we   <= pmmu_reg_we_d when CPU(1) = '1' else '0';
  pmmu_reg_re   <= pmmu_reg_re_d when CPU(1) = '1'  else '0';
  -- BUG #84 FIX: Use brief(14:10) directly during PMOVE to avoid 1-cycle delay
  -- pmmu_reg_sel_d is registered - first PMOVE sees 0 (reset value), returns wrong data
  -- Using brief directly ensures reg_sel is valid immediately when set(pmmu_rd) asserted
  -- BUG #119 FIX: Also check set_exec(pmmu_wr/pmmu_rd) for memory transfers
  -- pmove_mem_to_mmu_hi uses set_exec(pmmu_wr), pmove_decode MMU->mem uses set_exec(pmmu_rd)
  -- Use internal signal for VHDL-93 compatibility (cannot read output port)
  -- F-Line Context: pmmu_brief uses latched values when context valid
  -- BUG #363 FIX: Also activate selector when in/transitioning to pmove_mmu_to_mem states!
  -- Complex EA modes (d16,d8Xn,abs) route through ld_dAn1/ld_AnXn2/ld_nn before reaching
  -- pmove_mmu_to_mem_hi. These EA states don't set any pmmu_rd/wr signals, so pmmu_reg_sel_int
  -- fell back to stale pmmu_reg_sel_d, causing data_write_tmp to capture zeros.
  -- The data_write_tmp capture fires on next_micro_state=pmove_mmu_to_mem_hi/lo, so the
  -- register selector must be active at the same time.
  -- BUG #388 FIX: Also activate selector for pmove_mem_to_mmu_hi/lo states!
  -- Memory->MMU transfers also need valid register selector for pmmu_reg_we_d gating.
  pmmu_reg_sel_int <= pmmu_brief(14 downto 10) when CPU(1) = '1' AND
                          (set(pmmu_rd)='1' OR exec(pmmu_rd)='1' OR set(pmmu_wr)='1' OR
                           exec(pmmu_wr)='1' OR set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR
                           micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo OR
                           micro_state=pmove_mem_to_mmu_hi OR micro_state=pmove_mem_to_mmu_lo OR
                           next_micro_state=pmove_mmu_to_mem_hi OR next_micro_state=pmove_mmu_to_mem_lo OR
                           next_micro_state=pmove_mem_to_mmu_hi OR next_micro_state=pmove_mem_to_mmu_lo) else
                      pmmu_reg_sel_d when CPU(1) = '1' else
                      (others => '0');

  -- PTEST/PLOAD 'A' Bit Support: Register writeback control
  -- Valid when PTEST/PLOAD completes (busy='0') and 'A' bit (brief bit 8) is set
  -- Use pmmu_brief since F-Line context handles brief latching
  pmmu_ptest_a <= '1' when (micro_state=ptest1 or micro_state=pload1) and pmmu_busy='0' and pmmu_brief(8)='1' else '0';
  pmmu_reg_sel_valid <= true when (pmmu_reg_sel_int = "00010" OR pmmu_reg_sel_int = "00011" OR pmmu_reg_sel_int = "10000" OR
                                   pmmu_reg_sel_int = "10010" OR pmmu_reg_sel_int = "10011" OR pmmu_reg_sel_int = "11000")
                        else false;
  pmmu_reg_sel  <= pmmu_reg_sel_int;  -- Drive output port from internal signal
  -- BUG #119 FIX (continued): Use combinational pmmu_src_data to match what PMMU actually receives
  pmmu_reg_wdat <= pmmu_src_data when CPU(1) = '1'  else (others => '0');
  pmmu_reg_part <= pmmu_reg_part_d when CPU(1) = '1'  else '0';

  -- PMMU address interface (for cache virtually-indexed, physically-tagged operation)
  pmmu_addr_log  <= pmmu_addr_log_int;   -- Logical address (for cache indexing)
  pmmu_addr_phys <= pmmu_addr_phys_int;  -- Physical address (for cache tagging)
  
  -- PMMU instruction control
  pmmu_ptest_req  <= '1' when exec(pmmu_ptest) = '1' else '0';
  pmmu_pflush_req <= '1' when exec(pmmu_pflush) = '1' else '0';
  pmmu_pload_req  <= '1' when exec(pmmu_pload) = '1' else '0';

  -- BUG #19 FIX: Make pmmu_reg_we_d and pmmu_reg_re_d combinational (not sequential)
  -- Sequential signals with clkena gating caused missed writes when clkena_in wasn't '1' every cycle
  -- Now these signals follow exec() directly, like pmmu_ptest_req/pflush_req/pload_req
  -- BUG #29 FIX: Critical timing issue - write enable vs data latch mismatch!
  -- Originally used exec() only to avoid register addressing timing races.
  -- BUG #118 FIX: Also accept set_exec(pmmu_wr) so PMOVE memory->MMU writes still assert WE
  -- even when clkena_lw is gated off (memmaskmux(3)='0') in pmove_mem_to_mmu_hi.
  -- Dn mode: Uses pmmu_dn_data from register file
  -- Memory mode: Uses ea_data captured in pmove_mem_to_mmu_hi/pmove_mem_to_mmu_lo states
  -- BUG #117 FIX: Use brief(14:10) directly for validity check, not pmmu_reg_sel_d (registered)
  -- pmmu_reg_sel_d is one cycle late - first PMOVE after reset has pmmu_reg_sel_d="00000"
  -- which fails the validity check and causes pmmu_reg_we/re to stay '0'
  -- This matches BUG #84 fix on line 553 which uses brief(14:10) for pmmu_reg_sel
  -- BUG #307 FIX: Use set_exec(pmmu_wr) ONLY, not exec(pmmu_wr).
  -- exec(pmmu_wr) persists one cycle after PMOVE write ends, causing spurious write with stale data.
  -- BUG #365 FIX: Gate with clkena_lw! Without it, the PMMU module writes on EVERY rising_edge(clk)
  -- while micro_state=pmove_mem_to_mmu_hi (since set_exec is combinational), picking up stale/garbage
  -- data_read values during bus cycle address phases and after bus completion.
  -- With clkena_lw gating, the write fires exactly once: on the clock edge where the bus cycle
  -- completes and data_read has valid bus data. set_exec(pmmu_wr) is still active at this edge
  -- because micro_state hasn't advanced yet (it advances in the same rising_edge).
  pmmu_reg_we_d <= '1' when CPU(1)='1' AND set_exec(pmmu_wr)='1' AND pmmu_reg_sel_valid
                         AND clkena_lw='1'
                   else '0';
  -- BUG #81 REAL FIX: Must check BOTH set(pmmu_rd) and exec(pmmu_rd)!
  -- pmove_decode Dn read uses set(pmmu_rd), pmove_dn_lo uses exec(pmmu_rd)
  -- Without set(pmmu_rd) check, pmmu_reg_re stays '0' for pmove_decode reads!
  -- BUG #117 FIX: Use brief(14:10) directly for validity check (same as write enable)
  -- BUG #119 FIX: Also check set_exec(pmmu_rd) for MMU->memory reads (pmove_decode uses set_exec)
  pmmu_reg_re_d <= '1' when CPU(1)='1' AND (set(pmmu_rd)='1' OR exec(pmmu_rd)='1' OR set_exec(pmmu_rd)='1') AND pmmu_reg_sel_valid
                   else '0';

  -- PMOVE simplification: Route pmmu_reg_rdat through OP2out for MMU->memory writes
  -- Active during pmove_mmu_to_mem_hi/lo states (same conditions as old data_write_tmp special case)
  pmove_mmu_read_active <= '1' when (micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo
                                     OR next_micro_state=pmove_mmu_to_mem_hi OR next_micro_state=pmove_mmu_to_mem_lo)
                           else '0';

  -- For PTEST/PFLUSH/PLOAD: use FC from brief word per MC68030 spec
  -- MC68030 PTEST/PLOAD/PFLUSH FC encoding (extension word bits 4-0):
  --   10XXX: Immediate FC value in bits 2-0 (XXX) - 3-bit FC value (0-7)
  --   01DDD: FC from Dn register (DDD = register number, bits 2-0)
  --   00000: FC from SFC register
  --   00001: FC from DFC register
  --   All others: Reserved
  --
  -- BUG FIX: Implement proper FC selector logic per MC68030 spec
  -- Check bits 4-3 to determine FC source, then extract value accordingly
  -- F-Line Context: pmmu_brief uses latched values when context valid
  pmmu_cmd_fc     <= pmmu_brief(2 downto 0) when ((exec(pmmu_ptest) = '1' or exec(pmmu_pload) = '1' or
                                              (exec(pmmu_pflush) = '1' and pmmu_brief(12 downto 8) /= "00000" and pmmu_brief(12 downto 8) /= "00100" and pmmu_brief(12 downto 8) /= "01000"))
                                              and pmmu_brief(4 downto 3) = "10")  -- Immediate FC (3-bit value in bits 2-0)
                     else pmmu_fc_from_dn when ((exec(pmmu_ptest) = '1' or exec(pmmu_pload) = '1' or
                                    (exec(pmmu_pflush) = '1' and pmmu_brief(12 downto 8) /= "00000" and pmmu_brief(12 downto 8) /= "00100" and pmmu_brief(12 downto 8) /= "01000"))
                                    and pmmu_brief(4 downto 3) = "01")  -- FC from Dn register (Dn specified by pmmu_brief(2:0))
                     else SFC when ((exec(pmmu_ptest) = '1' or exec(pmmu_pload) = '1' or
                                    (exec(pmmu_pflush) = '1' and pmmu_brief(12 downto 8) /= "00000" and pmmu_brief(12 downto 8) /= "00100" and pmmu_brief(12 downto 8) /= "01000"))
                                    and pmmu_brief(4 downto 0) = "00000")  -- FC from SFC
                     else DFC when ((exec(pmmu_ptest) = '1' or exec(pmmu_pload) = '1' or
                                    (exec(pmmu_pflush) = '1' and pmmu_brief(12 downto 8) /= "00000" and pmmu_brief(12 downto 8) /= "00100" and pmmu_brief(12 downto 8) /= "01000"))
                                    and pmmu_brief(4 downto 0) = "00001")  -- FC from DFC
                     else fc_internal;

  -- BUG #397 FIX: Use exec() bits instead of micro_state for pmmu_cmd_addr mux.
  -- exec(pmmu_ptest/pload/pflush) and exec(OP1addr) are latched at the same clkena_lw edge,
  -- so OP1out=addr is valid when these exec bits are '1'. Using micro_state was wrong because
  -- micro_state advances past ptest1/pload1/pflush1 at the same edge that sets exec().
  pmmu_cmd_addr   <= OP1out when (exec(pmmu_ptest) = '1' or exec(pmmu_pload) = '1' or exec(pmmu_pflush) = '1')
                     else pmmu_addr_log_int;
  
  -- Cache invalidation control
  -- MC68030 uses CACR self-clearing bits for cache invalidation:
  --   Bit 2: CEI - Clear Entry in Instruction Cache
  --   Bit 3: CI - Clear Instruction Cache
  --   Bit 10: CED - Clear Entry in Data Cache
  --   Bit 11: CD - Clear Data Cache
  cache_inv_req  <= '1' when (CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1') else '0';

  -- Cache operation scope and cache selection for 68030 CACR bits
  process(CACR)
  begin
    -- CACR self-clearing bits: determine operation type
    cache_op_scope_int <= "10";  -- All caches (global invalidation)
    if CACR(3) = '1' then
      cache_op_cache_int <= "10";  -- CI (bit 3): Clear Instruction Cache only
    elsif CACR(11) = '1' then
      cache_op_cache_int <= "01";  -- CD (bit 11): Clear Data Cache only
    elsif CACR(2) = '1' or CACR(10) = '1' then
      cache_op_cache_int <= "11";  -- CEI (bit 2) or CED (bit 10): Clear Entry operations
    else
      cache_op_cache_int <= "00";  -- Default: no operation
    end if;
  end process;

  -- Connect internal signals to outputs
  cache_op_scope <= cache_op_scope_int;
  cache_op_cache <= cache_op_cache_int;

  -- Cache operation address: use physical address from PMMU
  cache_op_addr <= pmmu_addr_phys_int;

  -- Cache inhibit from PMMU
  pmmu_cache_inhibit <= pmmu_ch_inhibit;
  
  -- CACR (Cache Control Register) bit definitions for MC68030:
  -- Bit 0 (IE): Instruction Cache Enable (sticky)
  -- Bit 1 (FI): Instruction Cache Freeze - inhibit replacement (sticky)
  -- Bit 2 (CEI): Clear Entry in Instruction Cache (self-clearing, 68040)
  -- Bit 3 (CI): Clear Instruction Cache (self-clearing)
  -- Bit 4 (IBE): Instruction Burst Enable (sticky)
  -- Bits 7-5: Reserved (should read as 0, writes ignored)
  -- Bit 8 (DE): Data Cache Enable (sticky)
  -- Bit 9 (FD): Data Cache Freeze (sticky, used by AmigaOS for 68030 detection)
  -- Bit 10 (CED): Clear Entry in Data Cache (self-clearing, 68040)
  -- Bit 11 (CD): Clear Data Cache (self-clearing)
  -- Bit 12 (DBE): Data Burst Enable (sticky)
  -- Bit 13 (WA): Write Allocate (sticky)
  -- Bits 31-14: Reserved (should read as 0, writes ignored)
  
  -- Extract cache control bits from CACR register

  cacr_ie     <= CACR(0);  -- Instruction Cache Enable
  cacr_ifreeze <= CACR(1);  -- ICache Freeze
  cacr_ibe    <= CACR(4);  -- Instruction Burst Enable
  cacr_de     <= CACR(8);  -- Data Cache Enable
  cacr_dfreeze <= CACR(9);  -- DCache Freeze
  cacr_dbe    <= CACR(12); -- Data Burst Enable
  cacr_wa     <= CACR(13); -- Write Allocate
  -- PMOVE Dn source selects live register file using the latched selector
  -- BUG #112 V3 FIX: During pmove_decode, use opcode(2:0) DIRECTLY instead of pmove_dn_regnum!
  -- pmove_dn_regnum is registered - it only updates at END of clock cycle.
  -- But pmmu_dn_data is combinational - it reads the OLD pmove_dn_regnum during pmove_decode,
  -- causing the write to use the wrong Dn (from the previous instruction).
  -- This explains why first run works (pmove_dn_regnum=0 from reset) but second run fails
  -- (pmove_dn_regnum still has D1 from previous PMOVE TT0,D1).
  -- F-Line Context: Use pmmu_opcode for stable values
  pmmu_dn_data <= regfile(conv_integer(pmmu_opcode(2 downto 0))) when (micro_state = pmove_decode AND pmmu_opcode(5 downto 3) = "000")
                  else regfile(conv_integer(pmove_dn_regnum));

  -- Source data for PMMU register writes: from Dn normally, or from memory read in pmove_mem_to_mmu_hi
  -- PMOVE <ea>,<MMU reg>: use data_read (combinational) so the freshly returned bus data is written immediately
  -- pmove_decode_wait already ensured the bus cycle finished; data_read carries the just-fetched operand without waiting for the ea_data register update
  pmmu_src_data   <= data_read when (micro_state = pmove_mem_to_mmu_hi or micro_state = pmove_mem_to_mmu_lo) else
                     pmmu_dn_data;

  -- Drive PMMU request metadata
  pmmu_req      <= '1' when (state /= "01" and pmmu_tc_en = '1') else '0'; -- active only when MMU enabled
  pmmu_is_insn  <= '1' when state = "00" else '0';
  pmmu_rw       <= '0' when state = "11" else '1';
  pmmu_fc       <= fc_internal;

  -- FC from Dn for PTEST/PLOAD/PFLUSH: Read Dn register specified by brief(2:0), extract FC from bits [2:0]
  -- MC68030 spec: When brief(4:3) = "01", FC comes from Dn(2:0) where n = brief(2:0)
  -- F-Line Context: Use pmmu_brief for stable values
  pmmu_fc_from_dn <= regfile(conv_integer(pmmu_brief(2 downto 0)))(2 downto 0);

  -- PMMU Memory Interface: Connect to external memory arbiter in cpu_wrapper
  -- The walker requests are routed to real memory to read actual page table descriptors
  pmmu_walker_req  <= pmmu_mem_req;
  pmmu_walker_we   <= pmmu_mem_we;  -- MC68030 U/M bit: forward write enable
  pmmu_walker_addr <= pmmu_mem_addr;
  pmmu_walker_wdat <= pmmu_mem_wdat;  -- MC68030 U/M bit: forward write data
  pmmu_mem_ack     <= pmmu_walker_ack;
  pmmu_mem_rdat    <= pmmu_walker_data;
  pmmu_mem_berr    <= pmmu_walker_berr;  -- MC68030: Bus error from external memory

ALU: TG68K_ALU   
	generic map(
		MUL_Mode => MUL_Mode,				--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),		3=>no MUL,
		MUL_Hardware => MUL_Hardware,		--0=>no,		1=>yes,
		DIV_Mode => DIV_Mode,				--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),		3=>no DIV,
		BarrelShifter => BarrelShifter	--0=>no,		1=>yes,		2=>switchable with CPU(1)  
		)
	port map(
		clk => clk,								--: in std_logic;
		Reset => Reset,						--: in std_logic;
		CPU => CPU,								--: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  10->68030
		clkena_lw => clkena_lw,				--: in std_logic:='1';
		execOPC => execOPC_ALU,				--: in bit;
		decodeOPC => decodeOPC,				--: in bit;
		exe_condition => exe_condition,	--: in std_logic;
		exec_tas => exec_tas,				--: in std_logic;
		long_start => long_start_alu,		--: in bit;
		non_aligned => non_aligned,
		check_aligned => check_aligned,
		movem_presub => movem_presub,		--: in bit;
		set_stop => set_stop,				--: in bit;
		Z_error => Z_error,					--: in bit;

		rot_bits => rot_bits,				--: in std_logic_vector(1 downto 0);
		exec => exec,							--: in bit_vector(lastOpcBit downto 0);
		OP1out => OP1out,						--: in std_logic_vector(31 downto 0);
		OP2out => OP2out,						--: in std_logic_vector(31 downto 0);
		reg_QA => reg_QA,						--: in std_logic_vector(31 downto 0);
		reg_QB => reg_QB,						--: in std_logic_vector(31 downto 0);
		opcode => opcode,						--: in std_logic_vector(15 downto 0);
		exe_opcode => exe_opcode,			--: in std_logic_vector(15 downto 0);
		exe_datatype => exe_datatype,		--: in std_logic_vector(1 downto 0);
		sndOPC => sndOPC,						--: in std_logic_vector(15 downto 0);
		last_data_read => last_data_read(15 downto 0),	--: in std_logic_vector(31 downto 0);
		data_read => data_read(15 downto 0),		 		--: in std_logic_vector(31 downto 0);
		FlagsSR => FlagsSR,					--: in std_logic_vector(7 downto 0);
		micro_state => micro_state,		--: in micro_states;  
		bf_ext_in => bf_ext_in,
		bf_ext_out => bf_ext_out,
		bf_shift => alu_bf_shift,
		bf_width => alu_width,
		bf_ffo_offset => alu_bf_ffo_offset,
		bf_loffset => alu_bf_loffset(4 downto 0),

		set_V_Flag => set_V_Flag,			--: buffer bit;
		Flags => Flags,					 	--: buffer std_logic_vector(8 downto 0);
		c_out => c_out,					 	--: buffer std_logic_vector(2 downto 0);
		addsub_q => addsub_q,				--: buffer std_logic_vector(31 downto 0);
		ALUout => ALUout						--: buffer std_logic_vector(31 downto 0)
	);

	-- AMR - let the parent module know this is a longword access.  (Easy way to enable burst writes.)
	longword <= not memmaskmux(3);
	
	long_start_alu <= to_bit(NOT memmaskmux(3));
	execOPC_ALU <= execOPC OR exec(alu_exec);
	
		-- Drive FC output from internal signal (VHDL-93 compatibility)
		-- BUG #149 FIX: Add combinational override for MOVES instruction FC.
		-- Also apply during the actual bus access (moves_bus_pending='1') so MOVES uses
		-- SFC/DFC even if the micro_state advances while the bus cycle is in progress.
		-- BUG #318 FIX: Use latched moves_direction instead of brief(11).
		-- For indexed/absolute EA modes, brief gets overwritten with the EA extension
		-- word before moves1 executes, so brief(11) is no longer the MOVES direction bit.
		process(fc_internal, micro_state, moves_bus_pending, moves_direction, SFC, DFC)
		begin
			if micro_state = moves1 or moves_bus_pending = '1' then
				-- MOVES instruction: override FC with SFC or DFC
				-- moves_direction: 0=read (use SFC), 1=write (use DFC)
				if moves_direction='0' then
					FC <= SFC;  -- Read operation uses SFC
				else
					FC <= DFC;  -- Write operation uses DFC
				end if;
			else
				FC <= fc_internal;
			end if;
		end process;

	-- BUG #149 FIX: Track MOVES bus access in progress
	-- This process latches the EA register info when moves1 schedules a bus access
	-- and maintains it until the bus access completes
	process(clk, nReset)
	begin
		if nReset = '0' then
			moves_bus_pending <= '0';
			moves_ea_areg <= '0';
			moves_ea_regnum <= "000";
			moves_active <= '0';
			moves_direction <= '0';
			moves_reg <= "0000";
		elsif rising_edge(clk) then
			if clkena_in = '1' then
				-- BUG #318 FIX: Latch MOVES extension word fields when first entering moves0.
				-- At this point, brief still has the MOVES extension word ($xxxx).
				-- For indexed/absolute EA modes, brief gets overwritten later with the
				-- EA extension word, so these latched values preserve direction and register.
				if micro_state = moves0 and moves_d16_phase = '0' then
					moves_direction <= brief(11);  -- 0=mem->CPU(SFC), 1=CPU->mem(DFC)
					moves_reg <= brief(15 downto 12);  -- D/A bit + register number
				end if;
				-- BUG #322 FIX: Latch EA for MOVES complex addressing modes.
				-- The displacement/address computed by ld_dAn1/ld_AnXn2/ld_nn is only valid
				-- for one cycle in memaddr_delta_rega. By moves1, it's overwritten.
				-- (d16,An): memaddr_a = displacement from setdisp='1'
				if micro_state = ld_dAn1 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "101" then
					moves_ea_latched <= memaddr_a;
					moves_ea_use_base <= '1';  -- base = An
				end if;
				-- (d8,An,Xn) brief/full format: memaddr_a = indexed offset from setdisp='1'/briefext
				if micro_state = ld_AnXn2 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					moves_ea_latched <= memaddr_a;
					-- BUG #331 FIX: Check BS bit for base register suppression.
					-- Full-format (brief(8)='1'): BS=brief(7), 1=suppress base.
					-- Brief-format (brief(8)='0'): bit 7 is d8 sign bit, always use base.
					-- Memory indirect postindex: ld_AnXn2 is reached from ld_229_4
					-- when brief(6)='0' AND brief(2)='1'. The base register was already
					-- resolved into the intermediate address (An+BD -> indirect read).
					-- The final EA = indirect_pointer + index. Don't add base again.
					-- NOTE: I/IS field (bits 2:0) only valid for full-format (bit 8=1).
					-- For brief-format, bits 2:0 are displacement - don't misinterpret.
					if brief(8) = '1' and brief(2 downto 0) /= "000" then
						moves_ea_use_base <= '0';  -- memory indirect: base already resolved
					elsif brief(8) = '1' and brief(7) = '1' then
						moves_ea_use_base <= '0';  -- full-format BS=1: suppress base
					else
						moves_ea_use_base <= '1';  -- brief-format or BS=0: use base An
					end if;
				end if;
				-- BUG #330 FIX: (d8,An,Xn) full-format: latch EA during ld_229_1.
				-- Full-format extension words bypass ld_AnXn2 and go through ld_229_1.
				-- Without this, moves_ea_latched stays $0 and MOVES writes to address 0.
				-- BUG #332 FIX: When BD=word is being fetched (state="00"), memaddr_a reads
				-- last_data_read which still has the EXTENSION WORD, not the BD word.
				-- The BD word is in data_read (combinational from bus). Use data_read
				-- directly for IS=1 path (ld_229_1 -> moves1, no ld_AnXn2 to correct it).
				-- For IS=0 path, the ld_AnXn2 capture will override this with the correct
				-- index+BD value (fixed via memaddr_delta_rega BUG #332 fix).
				if micro_state = ld_229_1 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					if brief(5) = '1' and state = "00" then
						-- BD=word/long being fetched this cycle: use data_read (bus data)
						-- data_read is sign-extended for word fetches (memread(0)='1')
						moves_ea_latched <= data_read;
					else
						-- BD=null or non-fetch state: memaddr_a is correct (0 for null)
						moves_ea_latched <= memaddr_a;
					end if;
					-- BUG #331 FIX: Check BS bit (brief(7)) for base suppression.
					-- ld_229_1 is always full-format (brief(8)='1'), so just check BS.
					if brief(7) = '1' then
						moves_ea_use_base <= '0';  -- BS=1: suppress base register
					else
						moves_ea_use_base <= '1';  -- BS=0: use base register An
					end if;
				end if;
				-- Memory indirect: latch EA from ld_229_4 (non-postindex path).
				-- ea_data = indirect pointer (read from memory at ld_229_3).
				-- For WORD/LONG outer displacement, use data_read (combinational from bus)
				-- because last_data_read is stale (not yet updated with OD word).
				-- For NULL outer displacement, ea_data alone is the final EA.
				-- Base register was already resolved through the indirection chain,
				-- so moves_ea_use_base='0' (no base register addition in moves1).
				if micro_state = ld_229_4 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					if brief(1) = '1' then
						-- WORD/LONG outer displacement: ea_data + data_read
						moves_ea_latched <= ea_data + data_read;
					else
						-- NULL outer displacement: indirect pointer only
						moves_ea_latched <= ea_data;
					end if;
					moves_ea_use_base <= '0';  -- base resolved through indirection
				end if;
				-- (xxx).W/L: absolute address
				if micro_state = ld_nn and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "111" then
					if opcode(2 downto 0) = "001" then
						-- BUG #325 FIX: Absolute LONG without longaktion.
						-- High word was fetched during moves0 and stored in last_opc_read.
						-- Low word is being fetched this cycle in data_read.
						-- Assemble the full 32-bit address from both halves.
						moves_ea_latched <= last_opc_read & data_read(15 downto 0);
					else
						-- Absolute WORD: sign-extended 16-bit address in last_data_read
						moves_ea_latched <= last_data_read;
					end if;
					moves_ea_use_base <= '0';  -- absolute, no base register
				end if;
				-- Set when moves1 schedules a bus access
				if micro_state = moves1 then
					moves_bus_pending <= '1';
					-- Latch EA register info: (An) modes use address registers
					if opcode(5 downto 3) = "010" or opcode(5 downto 3) = "011" or opcode(5 downto 3) = "100" then
						moves_ea_areg <= '1';
					else
						moves_ea_areg <= '0';
					end if;
					moves_ea_regnum <= opcode(2 downto 0);
				-- BUG #316 FIX: Use micro_state = idle for reliable context clear
				-- Previous check (state="00" AND moves_bus_active='0') had timing window:
				-- moves_bus_active clears same cycle as state="00", but VHDL pre-edge
				-- semantics mean the check sees old moves_bus_active='1', then next cycle
				-- state is already "01" (fetch), so condition never becomes true.
				-- Using micro_state = idle works because idle persists for at least
				-- one full clock when instruction completes, and all MOVES states != idle.
				-- BUG #323c: Clear moves_bus_pending immediately when returning to idle.
				-- Previously checked exec(Regwrena)='0' too, but this kept mbp='1' during
				-- the deferred writeback cycle, overriding rf_dest_addr/rf_source_addr and
				-- corrupting the next instruction's register selection.
				elsif micro_state = idle then
					moves_bus_pending <= '0';
				end if;
				if micro_state = moves0 or micro_state = moves1 then
					moves_active <= '1';
				elsif moves_active = '1' and moves_bus_pending = '0' and moves_writeback_pending = '0' then
					moves_active <= '0';
				end if;
			end if;
		end if;
		end process;

		-- BUG #214 FIX: MOVES mem->CPU writeback guard
		-- This tracks when a memory->CPU MOVES needs to write to a register
		-- and ensures the destination register selection persists until exec(Regwrena) fires
		-- Prevents premature reversion to EA register if clkena_lw is suppressed
		process(clk, nReset)
		begin
			if nReset = '0' then
				moves_writeback_pending <= '0';
			elsif rising_edge(clk) then
				if clkena_in = '1' then
					-- Set when moves1 schedules a memory->CPU MOVES (dr=0)
					-- BUG #318 FIX: Use latched moves_direction instead of brief(11)
					if micro_state = moves1 and moves_direction = '0' then
						moves_writeback_pending <= '1';
					-- BUG #323 FIX: Clear when direct register write fires (state="10"
					-- with last word of transfer). memmaskmux(3)='1' matches clkena_lw='1'
					-- which is when the register file process performs the direct write.
					elsif state = "10" and memmaskmux(3) = '1' and moves_writeback_pending = '1' then
						moves_writeback_pending <= '0';
					end if;
				end if;
			end if;
		end process;

		-- MOVES (d16,An) needs an extra cycle after the MOVES extension word
		-- to fetch the displacement word from the instruction stream.
		process(clk, nReset)
		begin
			if nReset = '0' then
				moves_d16_phase <= '0';
			elsif rising_edge(clk) then
				if clkena_in = '1' then
					if micro_state /= moves0 then
						moves_d16_phase <= '0';
					elsif opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" then
						-- Phase 0: first moves0 cycle (fetch extra word from instruction stream)
						-- Phase 1: second moves0 cycle (word available in last_opc_read/last_data_read)
						-- Used for d16 (mode 101) and indexed (mode 110) addressing modes
						if moves_d16_phase = '0' then
							moves_d16_phase <= '1';
						else
							moves_d16_phase <= '0';
						end if;
					else
						moves_d16_phase <= '0';
					end if;
				end if;
			end if;
		end process;

		process (memmaskmux)
		begin
			non_aligned <= '0';
		if (memmaskmux(5 downto 4) = "01") or (memmaskmux(5 downto 4) = "10") then
			non_aligned <= '1';
		end if;
	end process;
-----------------------------------------------------------------------------
-- Bus control
-----------------------------------------------------------------------------
   regin_out <= regin;


	nWr <= '0' WHEN state="11" ELSE '1';
	busstate <= state;
	nResetOut <= '0' WHEN exec(opcRESET)='1' ELSE '1';
	
	-- does shift for byte access. note active low me
	-- should produce address error on 68000
	memmaskmux <= memmask when addr(0) = '1' else memmask(4 downto 0) & '1';
	nUDS <= memmaskmux(5);
	nLDS <= memmaskmux(4);
	clkena_lw <= '1' WHEN clkena_in='1' AND memmaskmux(3)='1' ELSE '0';  -- Remove pmmu_busy deadlock condition
	clr_berr <= '1' WHEN setopcode='1' AND trap_berr='1' ELSE '0';
	
	PROCESS (clk, nReset)
	BEGIN
		IF nReset='0' THEN
			syncReset <= "0000";
			Reset <= '1'; 
	  	ELSIF rising_edge(clk) THEN
			IF clkena_in='1' THEN
				syncReset <= syncReset(2 downto 0)&'1';
				Reset <= NOT syncReset(3);	
			END IF;
		END IF;
		IF rising_edge(clk) THEN
			-- BUG FIX: Enable VBR and extended stack frames for 68010+ (cpu(0)='1') AND 68030 (cpu(1)='1')
			-- Original code only checked cpu(0), but CPU="10" (68030 in Minimig) has cpu(0)='0'
			-- This caused 68000-style stack frames without vector offset, breaking MMU detection
			IF VBR_Stackframe=1 or (cpu /="00" and VBR_Stackframe=2) THEN
				use_VBR_Stackframe<='1';
			ELSE
				use_VBR_Stackframe<='0';
			END IF;
		END IF;
	END PROCESS;
			
PROCESS (clk, long_done, last_data_in, data_in, addr, long_start, memmaskmux, memread, memmask, data_read)
	BEGIN
		IF memmaskmux(4)='0' THEN
			data_read <= last_data_in(15 downto 0)&data_in;
		ELSE
			data_read <= last_data_in(23 downto 0)&data_in(15 downto 8);
		END IF;
		IF memread(0)='1' OR (memread(1 downto 0)="10" AND memmaskmux(4)='1')THEN
			data_read(31 downto 16) <= (OTHERS=>data_read(15));
		END IF;	
		
		IF rising_edge(clk) THEN	
			IF clkena_lw='1' AND state="10" THEN
				IF memmaskmux(4)='0' THEN
					bf_ext_in <= last_data_in(23 downto 16);
				ELSE
					bf_ext_in <= last_data_in(31 downto 24);
				END IF;
			END IF;	
			IF Reset='1' THEN
				last_data_read <= (OTHERS => '0');
			ELSIF clkena_in='1' THEN
				IF state="00" OR exec(update_ld)='1' THEN 
					last_data_read <= data_read;
					IF state(1)='0' AND memmask(1)='0' THEN
						last_data_read(31 downto 16) <= last_opc_read;
					ELSIF state(1)='0' OR memread(1)='1' THEN
						last_data_read(31 downto 16) <= (OTHERS=>data_in(15));
					END IF;
				END IF;
				last_data_in <= last_data_in(15 downto 0)&data_in(15 downto 0);
				
			END IF;
		END IF;
				long_start <= to_bit(NOT memmask(1));
				long_done <= to_bit(NOT memread(1));
	END PROCESS;

	-- Latch the RTE format/vector word so format decode is stable across bus activity.
	-- BUG FIX: Use last_data_in which is already captured during normal read flow.
	-- RTE format word latch: Capture the format/vector word during rte3->rte4 transition
	-- The format word is read in rte2 (setstate="10"), then we idle in rte3 waiting for data.
	-- In rte3, state is transitioning from "10" (read) to "01" (idle), and data_in has the format word.
	-- Capture using clkena_in (not clkena_lw) since rte3 is an idle state (setstate="01").
	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				rte_format_word <= (others => '0');
			ELSIF clkena_in='1' THEN
				-- Capture when the read completes: state is transitioning from "10" to "01"
				-- At this moment, data_in has the format word from the just-completed read
				IF micro_state = rte3 AND next_micro_state = rte4 THEN
					rte_format_word <= data_in;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	-- MC68030: Format $1 dual-frame chain tracking (registered to avoid combinational latch)
	-- When RTE encounters Format $1 with M=1, this flag tracks the dual-frame chain
	-- so the swap-back (MSP->ISP) executes after the second frame completes.
	-- Must be registered (not combinational) to prevent delta-cycle re-evaluation from
	-- canceling the swap-back set signals in the main combinational process.
	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				format1_chain_active <= '0';
			ELSIF clkena_lw='1' THEN
				IF setopcode='1' THEN
					format1_chain_active <= '0';
				ELSIF micro_state = rte4 THEN
					IF rte_format_word(15 downto 12) = "0001" AND FlagsSR(4)='1' AND cpu(1)='1' THEN
						format1_chain_active <= '1';
					ELSIF (rte_format_word(15 downto 12) = "0000" OR rte_format_word(15 downto 12) = "0011") AND format1_chain_active='1' THEN
						format1_chain_active <= '0';
					END IF;
				ELSIF micro_state = rte5 AND rot_cnt = "000001" AND format1_chain_active='1' THEN
					format1_chain_active <= '0';
				END IF;
			END IF;
		END IF;
	END PROCESS;

PROCESS (long_start, reg_QB, data_write_tmp, exec, data_read, data_write_mux, memmaskmux, bf_ext_out,
		 data_write_muxin, memmask, oddout, addr,
		 moves_bus_pending, moves_direction, moves_reg, addsub_q, opcode, micro_state, TG68_PC,
		 trap_SR, Flags, last_opc_read, trap_vector)
	BEGIN
        -- MC68030 Bus Error Stack Frame Data Multiplexer
        IF micro_state = berr1 OR micro_state = berr3 THEN
            data_write_muxin <= (others => '0'); -- Internal registers (implementation-defined)
        ELSIF micro_state = berr2 THEN
            -- Data Output Buffer ($18-$1B): Data being written when fault occurred
            data_write_muxin <= data_write_tmp;
        ELSIF micro_state = berr5 THEN
            -- Instruction Pipe ($0C-$0F): Stage B (opcode) and Stage C (prefetch)
            data_write_muxin <= opcode & last_opc_read(15 downto 0);
        ELSIF micro_state = berr4 THEN
            -- Fault Address: Use current CPU address output
            data_write_muxin <= addr;
        ELSIF micro_state = berr6 THEN
            -- SSW ($0A) & Internal ($08): Stub SSW ($0000)
            data_write_muxin <= (others => '0');
        ELSIF micro_state = berr7 THEN
            -- PC Lo ($04) & Format/Vector ($06)
            -- data_write_muxin is 32-bit. High Word=PC Lo, Low Word=Format.
            -- Stack grows down: PUSH Long writes [SP-4]..[SP-1].
            -- Mem[Offset $04] = PC Lo (High 16 of Long). Mem[Offset $06] = Format (Low 16).
            -- Format $A = short bus fault frame (16 words)
            -- Vector offset from trap_vector (e.g., $08=bus error, $F4=MMU bus error)
            data_write_muxin <= TG68_PC(15 downto 0) & "1010" & trap_vector(11 downto 0); 
        ELSIF micro_state = berr8 THEN
            -- SR ($00) & PC Hi ($02).
            -- High Word = SR (saved at decode time). Low Word = PC Hi.
            -- Mem[Offset 0] = SR. Mem[Offset 2] = PC Hi.
            data_write_muxin <= (trap_SR & Flags) & TG68_PC(31 downto 16);
		ELSIF exec(write_reg)='1' THEN
			-- BUG #328 FIX: Forward post-modified address register value when
			-- MOVES CPU->mem source register (from extension word) matches the
			-- EA address register with auto-modify (postadd/presub).
			-- reg_QB reads the OLD value before the clock-edge writeback.
			-- addsub_q has the correct updated value (An +/- size).
			-- Guard with long_start='0' to avoid intermediate delta during
			-- longaktion first cycle (where addsub_b=2 instead of 4).
			IF moves_bus_pending = '1' AND moves_direction = '1' AND
			   (exec(postadd) = '1' OR exec(presub) = '1') AND
			   moves_reg = ('1' & opcode(2 downto 0)) AND
			   long_start = '0' THEN
				data_write_muxin <= addsub_q;
			ELSE
				data_write_muxin <= reg_QB;
			END IF;
		ELSE
			data_write_muxin <= data_write_tmp;
		END IF;
		
		IF BitField=0 THEN
			IF oddout=addr(0) THEN
				data_write_mux <= "--------"&"--------"&data_write_muxin;
			ELSE
				data_write_mux <= "--------"&data_write_muxin&"--------";
			END IF;
		ELSE
			IF oddout=addr(0) THEN
				data_write_mux <= "--------"&bf_ext_out&data_write_muxin;
			ELSE
				data_write_mux <= bf_ext_out&data_write_muxin&"--------";
			END IF;
		END IF;
		
		IF memmaskmux(1)='0' THEN
			data_write <= data_write_mux(47 downto 32);
		ELSIF memmaskmux(3)='0' THEN	
			data_write <= data_write_mux(31 downto 16);
		ELSE
-- a single byte shows up on both bus halfs
			IF memmaskmux(5 downto 4) = "10" THEN
				data_write <= data_write_mux(7 downto 0) & data_write_mux(7 downto 0);
			ELSIF memmaskmux(5 downto 4) = "01" THEN
				data_write <= data_write_mux(15 downto 8) & data_write_mux(15 downto 8);
			ELSE
				data_write <= data_write_mux(15 downto 0);
			END IF;
		END IF;
		IF exec(mem_byte)='1' THEN	--movep
			data_write <= data_write_tmp(15 downto 8) & data_write_tmp(15 downto 8);
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- Registerfile
-----------------------------------------------------------------------------
PROCESS (clk, regfile, RDindex_A, RDindex_B, exec)
	BEGIN
		reg_QA <= regfile(RDindex_A);
		reg_QB <= regfile(RDindex_B);
		IF rising_edge(clk) THEN
		    IF clkena_lw='1' THEN
				rf_source_addrd <= rf_source_addr;
				WR_AReg <= rf_dest_addr(3);
				RDindex_A <= conv_integer(rf_dest_addr(3 downto 0));
				RDindex_B <= conv_integer(rf_source_addr(3 downto 0));
				IF Wwrena='1' THEN
					regfile(RDindex_A) <= regin;
				END IF;
				-- BUG #323 FIX: Direct MOVES mem->CPU register write.
				-- Writes data_read directly to the destination register during the
				-- bus read cycle (state="10"), bypassing the exec pipeline entirely.
				-- This avoids the deferred writeback at state="00" which conflicted
				-- with the next instruction's decode (set signals overriding MOVEA etc).
				-- data_read is the 32-bit assembled bus value (handles long/word/byte).
				-- For longword, clkena_lw='1' only on the second word, so data_read
				-- contains the full 32-bit value at that point.
				-- BUG #327 FIX: Sign-extend byte/word writes to address registers.
				-- MC68030 spec: MOVES to An with byte/word size must sign-extend
				-- to 32 bits, same as MOVEA.W/MOVEA.B behavior.
				-- moves_reg(3)='1' means address register (A0-A7).
				IF moves_writeback_pending = '1' AND state = "10" THEN
					CASE exe_datatype IS
						WHEN "00" =>  -- Byte
							IF moves_reg(3) = '1' THEN  -- An: sign-extend byte to 32 bits
								regfile(conv_integer(moves_reg)) <= (31 downto 8 => data_read(7)) & data_read(7 downto 0);
							ELSE  -- Dn: write only bits 7:0
								regfile(conv_integer(moves_reg))(7 downto 0) <= data_read(7 downto 0);
							END IF;
						WHEN "01" =>  -- Word
							IF moves_reg(3) = '1' THEN  -- An: sign-extend word to 32 bits
								regfile(conv_integer(moves_reg)) <= (31 downto 16 => data_read(15)) & data_read(15 downto 0);
							ELSE  -- Dn: write only bits 15:0
								regfile(conv_integer(moves_reg))(15 downto 0) <= data_read(15 downto 0);
							END IF;
						WHEN OTHERS =>  -- Long: write full 32 bits
							regfile(conv_integer(moves_reg)) <= data_read;
					END CASE;
				END IF;
			END IF;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- Write Reg
-----------------------------------------------------------------------------
-- BUG #20 FIX: Added pmmu_reg_rdat to sensitivity list
-- Without it, PMOVE TC,Dn doesn't update Dn when pmmu_reg_rdat changes
PROCESS (OP1in, reg_QA, Regwrena_now, Bwrena, Lwrena, exe_datatype, WR_AReg, movem_actiond, exec, ALUout, memaddr, memaddr_a, ea_only, USP, SSP, MSP, ISP, movec_data, pmmu_reg_rdat)
	BEGIN
		regin <= ALUout;
		IF exec(save_memaddr)='1' THEN
			regin <= memaddr;
		ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN
			regin <= memaddr_a;
		ELSIF exec(from_USP)='1' THEN
			regin <= USP;
		ELSIF exec(from_SSP)='1' THEN
			regin <= SSP;
		ELSIF exec(from_MSP)='1' THEN
			regin <= MSP;
		ELSIF exec(from_ISP)='1' THEN
			regin <= ISP;
		ELSIF exec(movec_rd)='1' THEN
			regin <= movec_data;
		ELSIF pmmu_ptest_a='1' THEN
			-- PTEST/PLOAD A-bit: Return descriptor address
			regin <= pmmu_desc_addr;
		ELSIF set(pmmu_rd)='1' OR exec(pmmu_rd)='1' THEN
			-- BUG #85 FIX: Allow BOTH set(pmmu_rd) and exec(pmmu_rd)!
			-- BUG #83 made reg_rdat COMBINATIONAL, so it's valid immediately.
			-- Dn mode uses set(pmmu_rd), memory modes use exec(pmmu_rd).
			regin <= pmmu_reg_rdat;
		END IF;

		-- BUG #25 FIX: Don't preserve register bits for PMMU reads!
		-- PMMU always writes full 32-bit values, so we should not mix with old register data.
		-- BUG #85: Now check both set(pmmu_rd) and exec(pmmu_rd)
		IF Bwrena='1' AND set(pmmu_rd)='0' AND exec(pmmu_rd)='0' THEN
			regin(15 downto 8) <= reg_QA(15 downto 8);
		END IF;
		IF Lwrena='0' AND set(pmmu_rd)='0' AND exec(pmmu_rd)='0' THEN
			regin(31 downto 16) <= reg_QA(31 downto 16);
		END IF;

		Bwrena <= '0';
		Wwrena <= '0';
		Lwrena <= '0';
		IF exec(presub)='1' OR exec(postadd)='1' OR exec(changeMode)='1' THEN		-- -(An)+
			Wwrena <= '1';
			Lwrena <= '1';
		ELSIF Regwrena_now='1' THEN		--dbcc	
			Wwrena <= '1';
		ELSIF exec(Regwrena)='1' THEN		--read (mem)
			Wwrena <= '1';
			CASE exe_datatype IS
				WHEN "00" =>		--BYTE
					Bwrena <= '1';
				WHEN "01" =>		--WORD
					IF WR_AReg='1' OR movem_actiond='1' THEN
						Lwrena <='1';
					END IF;
				WHEN OTHERS =>		--LONG
					Lwrena <= '1';
			END CASE;
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set dest regaddr
-----------------------------------------------------------------------------
PROCESS (opcode, rf_source_addrd, brief, setstackaddr, dest_hbits, dest_areg, dest_LDRareg, data_is_source, sndOPC, exec, set, dest_2ndHbits, dest_2ndLbits, dest_LDRHbits, dest_LDRLbits, last_data_read, last_opc_read, micro_state, next_micro_state, pmove_dn_regnum, pmove_dn_mode, fline_context_valid, fline_opcode_latch, moves_bus_pending, moves_ea_areg, moves_ea_regnum, moves_direction, moves_reg, setopcode)
	BEGIN
		IF exec(movem_action) ='1' THEN
			rf_dest_addr <= rf_source_addrd;
		ELSIF pmmu_ptest_a='1' THEN
			-- PTEST/PLOAD A-bit: Destination Address Register from bits 7-5
			rf_dest_addr <= '1' & pmmu_brief(7 downto 5);
		-- BUG #323 FIX: During MOVES bus access, rf_dest_addr must point to the EA
		-- register (An) for address calculation AND for postadd/presub register updates.
		-- The MOVES destination register write is handled by direct write in the register
		-- file process, so rf_dest_addr never needs to point to moves_reg.
		-- BUG #326 FIX: Guard with setopcode='0' AND micro_state /= idle to prevent
		-- contaminating the next instruction's register selection. moves_bus_pending
		-- stays '1' for up to two cycles after MOVES completes:
		-- Cycle N (last bus write): setopcode='1' -> blocked by setopcode guard
		-- Cycle N+1 (idle): micro_state=idle -> blocked by idle guard
		ELSIF moves_bus_pending = '1' AND setopcode = '0' AND micro_state /= idle THEN
			rf_dest_addr <= moves_ea_areg & moves_ea_regnum;
		-- BUG #150 FIX: Also handle moves0/moves1 states to set up RDindex_A one cycle early
		-- (RDindex_A is registered, so we need the correct value one cycle BEFORE bus access)
		ELSIF micro_state = moves0 OR micro_state = moves1 THEN
			-- Use EA register from opcode for address
			IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR
			   opcode(5 downto 3)="100" OR opcode(5 downto 3)="101" OR
			   opcode(5 downto 3)="110" THEN
				rf_dest_addr <= '1'&opcode(2 downto 0);  -- Address register
			ELSE
				rf_dest_addr <= '0'&opcode(2 downto 0);  -- Data register or absolute
			END IF;
		ELSIF set(briefext)='1' THEN
			rf_dest_addr <= brief(15 downto 12);
		ELSIF set(get_bfoffset)='1' THEN
--			IF opcode(15 downto 12)="1110" THEN
				rf_dest_addr <= '0'&sndOPC(8 downto 6);
--			ELSE
--				rf_dest_addr <= sndOPC(9 downto 6);
--			END IF;
		ELSIF dest_2ndHbits='1' THEN
			rf_dest_addr <= dest_LDRareg&sndOPC(14 downto 12);
		ELSIF dest_LDRHbits='1' THEN
			rf_dest_addr <= last_data_read(15 downto 12);
		ELSIF dest_LDRLbits='1' THEN
			rf_dest_addr <= '0'&last_data_read(2 downto 0);
		ELSIF dest_2ndLbits='1' THEN
			rf_dest_addr <= '0'&sndOPC(2 downto 0);
		ELSIF setstackaddr='1' THEN
			rf_dest_addr <= "1111";
		ELSIF micro_state = pmove_dn_lo OR next_micro_state = pmove_dn_lo THEN
			-- BUG #59 FIX: PMOVE checks must come BEFORE dest_hbits!
			-- PMOVE 64-bit: LOW word goes to Dn+1 (increment register number)
			-- BUG #376 FIX: Also check next_micro_state = pmove_dn_lo to set
			-- rf_dest_addr ONE CYCLE EARLY. RDindex_A is registered, so the
			-- register file write uses the PREVIOUS cycle's rf_dest_addr.
			-- Without this, both HI and LO word writes target Dn instead of Dn/Dn+1.
			rf_dest_addr <= dest_areg&(pmove_dn_regnum + "001");
		ELSIF micro_state = pmove_decode AND fline_context_valid = '1' AND fline_opcode_latch(5 downto 3) = "000" THEN
			-- BUG #376 FIX: During pmove_decode, pmove_dn_mode is not yet set
			-- (it's registered, set at the NEXT clock edge). And opcode may have been
			-- overwritten by prefetch. Use fline_opcode_latch for correct Dn register.
			-- This ensures rf_dest_addr is correct ONE CYCLE BEFORE the HI word write fires.
			rf_dest_addr <= '0' & fline_opcode_latch(2 downto 0);
		ELSIF micro_state = pmove_decode AND fline_context_valid = '1' AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			-- BUG #397 FIX: During pmove_decode, set rf_dest_addr for (An)/(An)+/-(An)
			-- modes so RDindex_A gets the EA register ONE CYCLE BEFORE ptest1/pload1/pflush1
			-- reads reg_QA via memaddr_reg. Without this, opcode(2:0) may be stale.
			rf_dest_addr <= '1' & fline_opcode_latch(2 downto 0);
		ELSIF pmove_dn_mode = '1' AND fline_context_valid = '1' THEN
			-- BUG #59 FIX: Use latched pmove_dn_regnum, not opcode(11:9) which gets overwritten!
			-- BUG #398 FIX: Guard with fline_context_valid to prevent stale pmove_dn_mode from
			-- overriding rf_dest_addr for subsequent non-PMMU instructions. pmove_dn_mode is
			-- cleared at setexecOPC but exec(pmmu_wr) OLD value delays clearing by one cycle,
			-- causing MOVEA.L after PMOVE D0,TT0 to write to A0 instead of A1.
			rf_dest_addr <= dest_areg&pmove_dn_regnum;
		-- BUG #384 FIX: PMOVE memory mode states need EA register from fline_opcode_latch,
		-- not opcode! By pmove_mmu_to_mem/mem_to_mmu time, opcode has been overwritten by
		-- prefetch. Without this, set(postadd)/set(presub) write-back targets the wrong
		-- register (e.g., A0 instead of A1), corrupting address registers.
		-- This mirrors the rf_source_addr fix at BUG #377.
		-- BUG #397 FIX: Also applies to ptest1/pload1/pflush1 - they need the EA register
		-- for addr/OP1out via memaddr_reg=reg_QA. Without this, addresses with non-zero
		-- high byte (e.g. $FF000100 for PTEST TT0 match) get corrupted.
		ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
		       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo OR
		       micro_state = ptest1 OR micro_state = pload1 OR micro_state = pflush1) AND
		      fline_context_valid = '1' AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			rf_dest_addr <= '1'&fline_opcode_latch(2 downto 0);
		ELSIF dest_hbits='1' THEN
			rf_dest_addr <= dest_areg&opcode(11 downto 9);
		ELSE
			IF opcode(5 downto 3)="000" OR data_is_source='1' THEN
				rf_dest_addr <= dest_areg&opcode(2 downto 0);
			ELSE
				rf_dest_addr <= '1'&opcode(2 downto 0);
			END IF;
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set source regaddr
-----------------------------------------------------------------------------
PROCESS (opcode, exe_opcode, movem_presub, movem_regaddr, source_lowbits, source_areg, sndOPC, exec, set, source_2ndLbits, source_2ndHbits, 	source_LDRLbits, source_LDRMbits, last_data_read, last_opc_read, source_2ndMbits, micro_state, pmove_dn_regnum, pmove_dn_mode, fline_context_valid, fline_opcode_latch, moves_bus_pending, moves_ea_areg, moves_ea_regnum, moves_direction, moves_reg, setopcode)
	BEGIN
		IF exec(movem_action)='1' OR set(movem_action) ='1' THEN
			IF movem_presub='1' THEN
				rf_source_addr <= movem_regaddr XOR "1111";
			ELSE
				rf_source_addr <= movem_regaddr;
			END IF;
		ELSIF source_2ndLbits='1' THEN
			rf_source_addr <= '0'&sndOPC(2 downto 0);
		ELSIF source_2ndHbits='1' THEN
			rf_source_addr <= '0'&sndOPC(14 downto 12);
		ELSIF source_2ndMbits='1' THEN
			rf_source_addr <= '0'&sndOPC(8 downto 6);
		ELSIF source_LDRLbits='1' THEN
			rf_source_addr <= '0'&last_data_read(2 downto 0);
		ELSIF source_LDRMbits='1' THEN
			rf_source_addr <= '0'&last_data_read(8 downto 6);
		-- BUG #149 FIX: MOVES bus access uses latched EA register info
		-- BUG #318 FIX: Use latched moves_direction/moves_reg instead of brief
		-- BUG #326 FIX: Guard with setopcode='0' AND micro_state /= idle to prevent
		-- contaminating the next instruction's register selection. moves_bus_pending
		-- stays '1' for up to two cycles after MOVES completes:
		-- Cycle N (last bus write): setopcode='1' -> blocked by setopcode guard
		-- Cycle N+1 (idle): micro_state=idle -> blocked by idle guard
		ELSIF moves_bus_pending = '1' AND setopcode = '0' AND micro_state /= idle THEN
			IF moves_direction = '1' THEN
				-- MOVES Rn,<ea> (CPU->memory): source is data register from moves_reg
				rf_source_addr <= moves_reg;
			ELSE
				-- MOVES <ea>,Rn (memory->CPU): source is EA register for address calculation
				rf_source_addr <= moves_ea_areg & moves_ea_regnum;
			END IF;
		-- BUG #149 FIX: MOVES needs opcode(2:0) for EA register selection
		-- BUG #318 FIX: Use latched moves_direction/moves_reg instead of brief
		ELSIF micro_state = moves0 OR micro_state = moves1 THEN
			-- Check direction: moves_direction=1 means CPU->memory (source is moves_reg)
			IF moves_direction = '1' THEN
				-- MOVES Rn,<ea>: source is data/address register from moves_reg
				rf_source_addr <= moves_reg;
			ELSE
				-- MOVES <ea>,Rn: source is EA register for address calculation
				IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR
				   opcode(5 downto 3)="100" OR opcode(5 downto 3)="101" OR
				   opcode(5 downto 3)="110" THEN
					rf_source_addr <= '1'&opcode(2 downto 0);  -- Address register
				ELSE
					rf_source_addr <= '0'&opcode(2 downto 0);  -- Data register or absolute
				END IF;
			END IF;
		ELSIF source_lowbits='1' THEN
			rf_source_addr <= source_areg&opcode(2 downto 0);
		ELSIF exec(linksp)='1' THEN
			rf_source_addr <= "1111";
		ELSIF micro_state = pmove_dn_lo THEN
			-- PMOVE Dn→MMU 64-bit: LOW word source is Dn+1 (increment register number)
			rf_source_addr <= source_areg&(pmove_dn_regnum + "001");
		ELSIF pmove_dn_mode = '1' AND fline_context_valid = '1' THEN
			-- BUG #398 FIX: Guard with fline_context_valid (same as rf_dest_addr fix)
			rf_source_addr <= source_areg&pmove_dn_regnum;
		-- BUG #289 FIX: PMOVE MMU states need EA register from opcode(2:0), not opcode(11:9)
		-- For PMOVE CRP,(A7)+, opcode(2:0)="111" (A7) but opcode(11:9)="000" (wrong!)
		-- BUG #377 FIX: Use fline_opcode_latch instead of opcode! By pmove_mmu_to_mem/mem_to_mmu
		-- time, opcode may have been overwritten by prefetch of the next instruction.
		ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
		       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			rf_source_addr <= '1'&fline_opcode_latch(2 downto 0);  -- Address register for (An)/(An)+/-(An) modes
		ELSE
			rf_source_addr <= source_areg&opcode(11 downto 9);
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP1out
-----------------------------------------------------------------------------
PROCESS (reg_QA, store_in_tmp, ea_data, long_start, addr, exec, memmaskmux, micro_state, pmove_ea_latched)
	BEGIN
		OP1out <= reg_QA;
		IF exec(OP1out_zero)='1' THEN
			OP1out <= (OTHERS => '0');
		-- BUG FIX: When postadd/presub is active during register update phase,
		-- OP1out MUST be reg_QA (the address register) for the increment calculation.
		-- This must be checked BEFORE ea_data_OP1 which has conflicting priority.
		-- Without this, PMOVE (An)+,TC corrupts An with (ea_data + increment) instead
		-- of (An + increment) because set(ea_data_OP1) and set(postadd) are both set.
		ELSIF (exec(postadd)='1' OR exec(presub)='1') AND memmaskmux(3)='1' THEN
			-- Register update mode: OP1out stays as reg_QA (default)
			NULL;
		ELSIF exec(ea_data_OP1)='1' AND store_in_tmp='1' THEN
			OP1out <= ea_data;
		ELSIF exec(movem_action)='1' OR memmaskmux(3)='0' OR exec(OP1addr)='1' THEN
			-- BUG #289 V6: Use pmove_ea_latched only for LO state's first word
			-- HI state uses addr throughout (it's valid due to use_base='1')
			-- LO state's first word needs pmove_ea_latched (base+4), second word uses addr
			IF micro_state = pmove_mmu_to_mem_lo AND memmaskmux(3)='1' THEN
				OP1out <= pmove_ea_latched;
			ELSE
				OP1out <= addr;
			END IF;
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP2out
-----------------------------------------------------------------------------
PROCESS (OP2out, reg_QB, exe_opcode, exe_datatype, execOPC, exec, use_direct_data,
	     store_in_tmp, data_write_tmp, ea_data, pmove_mmu_read_active, pmmu_reg_rdat)
	BEGIN
		OP2out(15 downto 0) <= reg_QB(15 downto 0);
		OP2out(31 downto 16) <= (OTHERS => OP2out(15));
		IF exec(OP2out_one)='1' THEN
			OP2out(15 downto 0) <= "1111111111111111";
		ELSIF pmove_mmu_read_active='1' AND exec(postadd)='0' AND exec(presub)='0' THEN
			-- PMOVE simplification: Route PMMU register data through standard write path
			-- This must be checked BEFORE use_direct_data/store_in_tmp which may interfere
			-- Guard: exclude postadd/presub phases - during address register writeback
			-- OP2out must carry the normal increment value, not the PMMU register data
			OP2out <= pmmu_reg_rdat;
		ELSIF use_direct_data='1' OR (exec(exg)='1' AND execOPC='1') OR exec(get_bfoffset)='1' THEN
			OP2out <= data_write_tmp;
		ELSIF (exec(ea_data_OP1)='0' AND store_in_tmp='1') OR exec(ea_data_OP2)='1' THEN
			OP2out <= ea_data;
		ELSIF exec(opcMOVEQ)='1' THEN
			OP2out(7 downto 0) <= exe_opcode(7 downto 0);
			OP2out(15 downto 8) <= (OTHERS => exe_opcode(7));
		ELSIF exec(opcADDQ)='1' THEN
			OP2out(2 downto 0) <= exe_opcode(11 downto 9);
			IF exe_opcode(11 downto 9)="000" THEN
				OP2out(3) <='1';
			ELSE
				OP2out(3) <='0';
			END IF;
			OP2out(15 downto 4) <= (OTHERS => '0');
		ELSIF exe_datatype="10" AND exec(opcEXT)='0'  THEN 
			OP2out(31 downto 16) <= reg_QB(31 downto 16);
		END IF;
		IF exec(opcEXTB)='1' THEN
			OP2out(31 downto 8) <= (OTHERS => OP2out(7));		
		END IF;
	END PROCESS;
	

-----------------------------------------------------------------------------
-- handle EA_data, data_write
-----------------------------------------------------------------------------
PROCESS (clk)
	BEGIN
     	IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				store_in_tmp <='0';
				direct_data <= '0';
				use_direct_data <= '0';
				Z_error <= '0';
				writePCnext <= '0';
			ELSIF clkena_lw='1' THEN
				useStackframe2<='0';
				direct_data <= '0';
				IF exec(hold_OP2)='1' THEN
					use_direct_data <= '1';
				END IF;
				IF set_direct_data='1' THEN
					direct_data <= '1';
					use_direct_data <= '1';
				ELSIF endOPC='1' OR set(ea_data_OP2)='1' THEN	
					use_direct_data <= '0';
				END IF;	
				exec_DIRECT <= set_exec(opcMOVE);
				
				IF endOPC='1' THEN
					store_in_tmp <='0';
					Z_error <= '0';
					writePCnext <= '0';
				ELSE
					IF set_Z_error='1'  THEN
						Z_error <= '1';
					END IF;	
					IF set_exec(opcMOVE)='1' AND state="11" THEN
						use_direct_data <= '1';
					END IF;

					IF state="10" OR exec(store_ea_packdata)='1' THEN
						store_in_tmp <= '1'; 
					END IF;
					IF direct_data='1' AND state="00" THEN
						store_in_tmp <= '1'; 
					END IF;	
				END IF;
				
				IF state="10" AND exec(hold_ea_data)='0' THEN
					ea_data <= data_read;
				ELSIF exec(get_2ndOPC)='1' THEN
					ea_data <= addr;
				ELSIF exec(store_ea_data)='1' OR (direct_data='1' AND state="00") THEN
					ea_data <= last_data_read;
				END IF;	
				
				IF writePC='1' THEN
					data_write_tmp <= TG68_PC;
				ELSIF exec(writePC_add)='1' THEN
					-- BUG #387 FIX: Use exe_pc for exceptions that occur during instruction decode
					-- (illegal instruction vector=0x10, privilege violation vector=0x20).
					-- These exceptions fire after extension words are fetched, so TG68_PC_add is over-incremented.
					IF trap_vector(9 downto 0) = "00" & X"10" OR trap_vector(9 downto 0) = "00" & X"20" THEN
						data_write_tmp <= exe_pc;
					ELSE
						data_write_tmp <= TG68_PC_add;
					END IF;
-- paste and copy form TH	---------
				elsif micro_state=trap00 THEN
					data_write_tmp <= exe_pc; --TH
					useStackframe2<='1';
					writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR Z_error;
				elsif micro_state = trap0 then
		  -- this is only active for 010+ since in 000 writePC is
		  -- true in state trap0
--					if trap_trace='1' or set_exec(opcTRAPV)='1' or Z_error='1' then
					IF	useStackframe2='1' THEN
						-- stack frame format #2
						data_write_tmp(15 downto 0) <= "0010" & trap_vector(11 downto 0); --TH
					else
						data_write_tmp(15 downto 0) <= "0000" & trap_vector(11 downto 0);
						writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR Z_error;
					end if;
				elsif micro_state = int3 then
					-- MC68030: Format $1 throwaway frame format/vector word
					data_write_tmp(15 downto 0) <= "0001" & trap_vector(11 downto 0);
------------------------------------
--				ELSIF micro_state=trap0 THEN
--					data_write_tmp(15 downto 0) <= trap_vector(15 downto 0);
				-- BUG #391 FIX: Bypass hold_dwr at the CRP/SRP HI/LO write boundary.
				-- At clkena_lw with micro_state=pmove_mmu_to_mem_lo, the HI longword bus
				-- write is completing and we need data_write_tmp to be refreshed with CRP_L
				-- (via pmmu_reg_rdat with reg_part_d='0'). Without this bypass, hold_dwr
				-- keeps CRP_H in data_write_tmp, causing the LO write to duplicate CRP_H.
				-- On non-clkena_lw cycles (during actual bus words), hold_dwr correctly
				-- preserves the data_write_tmp value.
				ELSIF exec(hold_dwr)='1' AND NOT (clkena_lw='1' AND micro_state=pmove_mmu_to_mem_lo) THEN
					data_write_tmp <= data_write_tmp;
				ELSIF micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo
				      OR next_micro_state=pmove_mmu_to_mem_hi OR next_micro_state=pmove_mmu_to_mem_lo THEN
					-- MMU->memory: source data from PMMU register readback (ORIGINAL LOGIC)
					data_write_tmp <= pmmu_reg_rdat;
				ELSIF exec(exg)='1' THEN
					data_write_tmp <= OP1out;
				ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN		-- ist for pea
					data_write_tmp <= addr;
				ELSIF execOPC='1' THEN
					data_write_tmp <= ALUout;
				ELSIF (exec_DIRECT='1' AND state="10") THEN
					data_write_tmp <= data_read;
					IF  exec(movepl)='1' THEN
						data_write_tmp(31 downto 8) <= data_write_tmp(23 downto 0);
					END IF;
                ELSIF exec(movepl)='1' THEN
                    data_write_tmp(15 downto 0) <= reg_QB(31 downto 16);
                ELSIF direct_data='1' THEN
                    data_write_tmp <= last_data_read;
                ELSIF writeSR='1'THEN
                    data_write_tmp(15 downto 0) <= trap_SR(7 downto 0)& Flags(7 downto 0);
                ELSE
                    -- Default path: includes PMOVE MMU->memory via pmove_mmu_read_active routing through OP2out
                    data_write_tmp <= OP2out;
                END IF;
			END IF;	
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- brief
-----------------------------------------------------------------------------
PROCESS (brief, OP1out, OP1outbrief, cpu)
	BEGIN
		IF brief(11)='1' THEN
			OP1outbrief <= OP1out(31 downto 16);
		ELSE
			OP1outbrief <= (OTHERS=>OP1out(15));
		END IF;
		briefdata <= OP1outbrief&OP1out(15 downto 0);
		IF extAddr_Mode=1 OR (cpu(1)='1' AND extAddr_Mode=2) THEN
			CASE brief(10 downto 9) IS
				WHEN "00" => briefdata <= OP1outbrief&OP1out(15 downto 0);
				WHEN "01" => briefdata <= OP1outbrief(14 downto 0)&OP1out(15 downto 0)&'0';
				WHEN "10" => briefdata <= OP1outbrief(13 downto 0)&OP1out(15 downto 0)&"00";
				WHEN "11" => briefdata <= OP1outbrief(12 downto 0)&OP1out(15 downto 0)&"000";
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- MEM_IO 
-----------------------------------------------------------------------------
PROCESS (clk, setdisp, memaddr_a, briefdata, memaddr_delta, setdispbyte, datatype, interrupt, rIPL_nr, IPL_vec,
         memaddr_reg, memaddr_delta_rega, memaddr_delta_regb, reg_QA, use_base, VBR, last_data_read, trap_vector, exec, set, cpu, use_VBR_Stackframe,
         pmove_disp_latched, micro_state, opcode, fline_opcode_latch, moves_ea_areg, moves_bus_pending, memmaskmux,
         moves_ea_latched, moves_ea_use_base, pmove_ea_latched, pmmu_brief)
	BEGIN
		
		IF rising_edge(clk) THEN
			-- BUG FIX: Use clkena_in instead of clkena_lw for trap_vector updates
			-- During RTE format error detection, clkena_lw may be '0' (memmaskmux(3)='0')
			-- which prevented trap_format_error from updating trap_vector properly.
			-- This caused exception 8 (privilege) instead of exception 14 (format error).
			IF clkena_in='1' THEN
				trap_vector(31 downto 10) <= (others => '0');
				IF trap_addr_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"0C";
				END IF;
				IF trap_illegal='1' THEN
					trap_vector(9 downto 0) <= "00" & X"10";
				END IF;
				IF set_Z_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"14";
				END IF;
				IF exec(trap_chk)='1' THEN
					trap_vector(9 downto 0) <= "00" & X"18";
				END IF;
				IF trap_trapv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"1C";
				END IF;
				IF trap_priv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"20";
				END IF;
				IF trap_trace='1' THEN
					trap_vector(9 downto 0) <= "00" & X"24";
				END IF;
				IF trap_1010='1' THEN
					trap_vector(9 downto 0) <= "00" & X"28";
				END IF;
				IF trap_1111='1' THEN
					trap_vector(9 downto 0) <= "00" & X"2C";
				END IF;
				IF trap_trap='1' THEN
					trap_vector(9 downto 0) <= "0010" & opcode(3 downto 0) & "00";
				END IF;
				IF trap_interrupt='1' or set_vectoraddr = '1' THEN
					trap_vector(9 downto 0) <= IPL_vec & "00";      --TH
				END IF;
				IF trap_mmu_config='1' THEN
					trap_vector(9 downto 0) <= "11" & X"80";  -- Vector 56 (0xE0) - MMU Configuration Error
				END IF;
				-- BUG #402 FIX: trap_berr and trap_mmu_berr must come AFTER
				-- set_vectoraddr to have higher priority (VHDL last-assignment-wins).
				-- berr8 sets set_vectoraddr='1' which would override trap_vector
				-- with IPL_vec, corrupting the bus error vector address.
				IF trap_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;
				IF trap_mmu_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"F4";  -- Vector 61 (0xF4) - MC68030 MMU Bus Error
				END IF;
				IF trap_format_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"38";  -- Vector 14 (0x38) - Format Error
				END IF;
				-- Note: Vectors 57 ($E4) and 58 ($E8) are 68851-only, not MC68030
			END IF;
		END IF;
		IF use_VBR_Stackframe='1' THEN
			trap_vector_vbr <= trap_vector+VBR;
		ELSE		
			trap_vector_vbr <= trap_vector;
		END IF;		
		
		memaddr_a(4 downto 0) <= "00000";
		memaddr_a(7 downto 5) <= (OTHERS=>memaddr_a(4));
		memaddr_a(15 downto 8) <= (OTHERS=>memaddr_a(7));
		memaddr_a(31 downto 16) <= (OTHERS=>memaddr_a(15));
		IF setdisp='1' THEN
			IF exec(briefext)='1' THEN
				memaddr_a <= briefdata+memaddr_delta;
			ELSIF setdispbyte='1' THEN
				memaddr_a(7 downto 0) <= last_data_read(7 downto 0);
			ELSE
				memaddr_a <= last_data_read;
			END IF;	 
			ELSIF set(presub)='1' THEN
				-- PMOVE CRP/SRP are 64-bit (doubleword): -(An) must predecrement by 8 bytes
				IF set(pmmu_dbl)='1' THEN
					memaddr_a(4 downto 0) <= "11000";
				ELSIF set(longaktion)='1' THEN	
					memaddr_a(4 downto 0) <= "11100";
				ELSIF datatype="00" AND set(use_SP)='0' THEN
					memaddr_a(4 downto 0) <= "11111";
				ELSE
					memaddr_a(4 downto 0) <= "11110";
				END IF;	
		ELSIF interrupt='1' THEN
			memaddr_a(4 downto 0) <= '1'&rIPL_nr&'0';	
		END IF;	 
		
		IF rising_edge(clk) THEN
			IF clkena_in='1' THEN
				IF exec(get_2ndOPC)='1' OR (state="10" AND memread(0)='1') THEN
					tmp_TG68_PC <= addr;
				END IF;
				use_base <= '0';
				memaddr_delta_regb <= (others => '0');
				-- BUG #149 FIX: MOVES states AND bus access pending need use_base='1' for address register EA
				-- CRITICAL: Do NOT set use_base during decode! That would corrupt the extension word fetch.
				-- Only set use_base during moves0/moves1 states when we actually need the EA address.
				-- Also maintain use_base='1' during moves_bus_pending when the actual bus access happens.
				-- MOVES opcode: 0000 1110 ss mmm rrr (opcode(15:8)="00001110")
				-- BUG #318 FIX: When MOVES bus cycle completes, force PC-based addressing.
				-- Without this, the next fetch uses EA address instead of PC because
				-- the moves_bus_pending condition below forces use_base='1' and delta=0.
				-- CRITICAL: Must fire on the LAST bus cycle (state(1)='1', memmaskmux(3)='1')
				-- as well as state="00". memaddr_delta_rega is registered, so the assignment
				-- during the last bus cycle takes effect on the NEXT cycle (the fetch).
				-- The current bus cycle still uses the previous EA-based values.
				IF moves_bus_pending = '1' AND
				   (state = "00" OR (state(1) = '1' AND memmaskmux(3) = '1' AND setstate = "00")) AND
				   micro_state /= moves0 AND micro_state /= moves1 THEN
					memaddr_delta_rega <= TG68_PC_add;
					-- use_base stays '0' (default), addr = 0 + TG68_PC = PC
				-- BUG #317 FIX: Only zero delta on FIRST word of longword (memmaskmux(3)='1')
				-- During second word (memmaskmux(3)='0'), allow the +2 increment via addsub
				-- Without this, MOVES.L writes both words to the same address!
				-- BUG #329 FIX: Removed MOVES -(An) handler that forced addr=addsub_q.
				-- During moves1, exec(presub) isn't active yet so the ALU uses addsub_b=2
				-- even for longword (which needs -4). The ELSE branch at the end of this
				-- chain correctly uses memaddr_a which IS -4 for longaktion presub
				-- (via set(presub)='1' AND set(longaktion)='1' at line 1719-1720).
				-- This also fixes BUG #321 (MOVES -(An) pre-decrement) via the same path.
				-- BUG #322 FIX: MOVES complex EA modes - use latched displacement/address.
				-- For (d16,An), (d8,An,Xn), and (xxx).W/L, the EA computed by ld_dAn1/ld_AnXn2/ld_nn
				-- is stored in memaddr_delta_rega for only one cycle. By the time moves1 runs,
				-- the ELSE branch overwrites it with memaddr_a=0. Use the latched values instead.
				ELSIF (micro_state = moves1 OR moves_bus_pending = '1') AND
				    opcode(15 downto 8) = "00001110" AND opcode(7 downto 6) /= "11" AND
				    (opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" OR opcode(5 downto 3) = "111") AND
				    memmaskmux(3)='1' THEN
					memaddr_delta_rega <= moves_ea_latched;
					use_base <= moves_ea_use_base;
				-- MOVES (An)/(An)+: use base register directly (addr = reg_QA + 0)
				ELSIF (micro_state = moves0 OR micro_state = moves1 OR moves_bus_pending = '1') AND
				    (moves_ea_areg = '1' OR opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100") AND
				    opcode(5 downto 3) /= "100" AND
				    memmaskmux(3)='1' THEN
					memaddr_delta_rega <= (others => '0');  -- No delta for simple (An)/(An)+ mode, first word only
					use_base <= '1';  -- Force memaddr_reg = reg_QA
				-- BUG #172 FIX: PMOVE with simple EA modes needs use_base='1'
				-- Without this, PMOVE TC,(An) writes to wrong address (PC+offset instead of An)
				-- Must force use_base='1' during pmove_mmu_to_mem and pmove_mem_to_mmu states for (An)/-(An) modes
				-- BUG #197 FIX V6: Extend to mode 101 (d16,An) and other displacement modes
				-- For displacement modes, use pmove_disp_latched (captured during ld_dAn1 when setdisp='1')
				-- Cannot use memaddr_a here because it's zero (setdisp='0' outside ld_dAn1)
				-- BUG #289 FIX: Added memmaskmux(3)='1' check - only set zero delta on FIRST word
				-- During second word of longword write, memmaskmux(3)='0', so we need the +2 increment
				-- Without this, both words of a longword write go to the same address
				-- BUG #290+#340 FIX: For ALL PMOVE LO states, use pmove_ea_latched as the address.
				-- Root cause: last_data_read is STALE during LO state execution.
				-- For d16,An: last_data_read was overwritten by instruction prefetch (next opcode word).
				-- For mem_to_mmu: last_data_read was overwritten by the HI word just read from memory.
				-- pmove_ea_latched was captured during the HI->LO transition as addr+4, which is correct.
				-- use_base='0' because pmove_ea_latched is an absolute address, not a register-relative offset.
				-- BUG #388 FIX: Guard with setstate /= "00"! When pmove_mem_to_mmu_lo retires with
				-- setstate="00" (fetch), this ELSIF still fires and latches pmove_ea_latched into
				-- memaddr_delta_rega. Since this is a registered process, the value persists into the
				-- NEXT cycle (idle/fetch), corrupting the fetch address with the PMOVE data address
				-- instead of the PC. This causes the CPU to fetch from the CRP/SRP data address,
				-- latching garbage as the next opcode (illegal instruction trap).
					ELSIF (micro_state = pmove_mmu_to_mem_lo OR micro_state = pmove_mem_to_mmu_lo) AND
					      memmaskmux(3)='1' AND setstate /= "00" THEN
						memaddr_delta_rega <= pmove_ea_latched;
						use_base <= '0';
					
					-- BUG #302 FIX: Special case for (An)+ mode CRP/SRP LOW word reads
					-- BUG #339 FIX: pmove_decode handling - memmaskmux not reliable during decode
					-- BUG #355 FIX: Guard with setstate /= "00" to prevent fetch address corruption!
					-- BUG #382 FIX: Must verify this is a PMMU instruction using pmmu_brief(15:13)!
					ELSIF micro_state = pmove_decode AND setstate /= "00" AND
					      fline_opcode_latch(15 downto 12)="1111" AND
					      (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") AND
					      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
						-- Modes 010/011: Simple (An)/(An)+ - no delta
						IF fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" THEN
						memaddr_delta_rega <= (others => '0');
						use_base <= '1';
						
						-- Mode 100: -(An) - Latch presub decrement during decode
						-- addsub_q is STALE here because exec(presub) won't be active
						-- until next cycle (set(presub) was just assigned combinationally).
						-- Use memaddr_a which has the correct -4/-8 from the combinational
						-- presub path (lines 1873-1883) that uses set(presub) directly.
						ELSE  -- Must be 100 based on outer condition
							memaddr_delta_rega <= memaddr_a;  -- Correct -4/-8 from combinational presub
							use_base <= '1';
						END IF;
					
					-- BUG #339 FIX: PMOVE execution states with memmaskmux guard
					-- NOTE: For LO states, the ELSIF at line 1953 fires FIRST (earlier in chain)
					-- using pmove_ea_latched. This ELSIF effectively only handles HI states,
					-- where last_data_read is still valid (not yet overwritten by prefetch/read data).
					-- BUG #355 FIX: Guard with setstate /= "00" to prevent fetch address corruption!
					-- BUG #382 FIX: Must verify this is a PMMU instruction using pmmu_brief(15:13)!
					ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
					       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
					      fline_opcode_latch(15 downto 12)="1111" AND
					      (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") AND
					      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR
					       fline_opcode_latch(5 downto 3)="100" OR
					       fline_opcode_latch(5 downto 3)="101" OR fline_opcode_latch(5 downto 3)="110" OR
					       fline_opcode_latch(5 downto 3)="111") AND
					      memmaskmux(3)='1' AND setstate /= "00" THEN
						-- BUG #390 FIX: CRP/SRP 64-bit READ path - at the exec->LO-read
						-- transition (micro_state=pmove_mem_to_mmu_hi), set use_base='0' so the
						-- combinational override at memaddr_delta can use pmove_ea_latched
						-- (= EA + 4) directly as an absolute address. Works for ALL EA modes
						-- because pmove_ea_latched is always EA+4 regardless of addressing mode.
						-- This check must be BEFORE the EA mode dispatch because last_data_read
						-- is stale (overwritten by HI read data) for displacement modes.
						IF micro_state = pmove_mem_to_mmu_hi AND
						   (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
							use_base <= '0';
						-- (An) / (An)+ / -(An) modes: zero delta, use register base
						-- For -(An), the register was already decremented by presub during
						-- pmove_decode, so use zero delta with the base register (which now
						-- holds the decremented value). Without mode "100" here, the stale
						-- -4 delta from pmove_decode persists, causing addr = An(-4) + (-4) = An-8.
						ELSIF fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011"
						   OR fline_opcode_latch(5 downto 3)="100" THEN
							memaddr_delta_rega <= (others => '0');
							use_base <= '1';
						-- (d16,An) mode: displacement in last_data_read, register base
						ELSIF fline_opcode_latch(5 downto 3)="101" THEN
							memaddr_delta_rega <= last_data_read;
							use_base <= '1';
						-- (d8,An,Xn) mode: preserve indexed offset from pmmu_ld_AnXn2
						-- BUG #386 FIX V2: During pmmu_ld_AnXn2, the ELSE branch registered
						-- memaddr_delta_rega = Xn + d8 (the indexed offset) with use_base='1'.
						-- Combined with use_base='1' here, addr = An + (Xn + d8) = correct EA.
						-- Cannot use pmove_disp_latched because addr during pmmu_ld_AnXn2 had
						-- the index register (not base register) in reg_QA, giving Xn+d8 only.
						ELSIF fline_opcode_latch(5 downto 3)="110" THEN
							-- memaddr_delta_rega: no assignment = keep Xn+d8 from pmmu_ld_AnXn2
							use_base <= '1';
						-- (xxx).W / (xxx).L absolute address
						-- BUG #387 FIX: For (xxx).L, last_data_read only has the low 16-bit
						-- address word. Use pmove_disp_latched which has the full 32-bit address
						-- latched during pmmu_ld_nn second pass.
						-- For (xxx).W, last_data_read is still correct (sign-extended 16-bit).
						ELSIF fline_opcode_latch(5 downto 3)="111" THEN
							IF fline_opcode_latch(2 downto 0)="001" THEN
								memaddr_delta_rega <= pmove_disp_latched;  -- (xxx).L: full 32-bit address
								report "BUG387_USE: (xxx).L delta=" & integer'image(conv_integer(pmove_disp_latched)) & " micro=" & micro_states'image(micro_state) severity note;
							ELSE
								memaddr_delta_rega <= last_data_read;  -- (xxx).W: sign-extended 16-bit
								report "BUG387_USE: (xxx).W delta=" & integer'image(conv_integer(last_data_read)) severity note;
							END IF;
							use_base <= '0';
						END IF;
				-- BUG #302: Exclude (An)+ CRP/SRP in pmove_mem_to_mmu_lo from using addsub_q
				-- BUG #339: Exclude PMOVE -(An) to preserve latched delta from pmove_decode
				-- BUG #341: When a write bus cycle completes (state="11", last word
				-- memmaskmux(3)='1') and returns to idle (setstate="00"), exec(mem_addsub)
				-- is still '1' from the instruction's set() values. This causes addsub_q
				-- (data_address+4) to be latched into memaddr_delta_rega instead of
				-- TG68_PC_add (PC+2). The wrong address is used for the first fetch cycle,
				-- corrupting last_opc_read. Fix: exclude this case so we fall through to
				-- the setstate="00" ELSIF at line 2033 which correctly uses TG68_PC_add.
				ELSIF (memmaskmux(3)='0' OR exec(mem_addsub)='1') AND NOT
				      ((micro_state = pmove_mem_to_mmu_lo) AND
				       (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") AND
				       pmmu_ea_mode_latched(5 downto 3)="011") AND NOT
				      -- BUG #392 FIX: Only block addsub_q for -(An) during setup (state /= "11").
				      -- During the actual bus write (state="11"), addsub_q provides the +2 word
				      -- increment needed for the second half of a longword transfer. Without this,
				      -- both words of CRP_hi write to the same address, corrupting the upper word.
				      ((micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo) AND
				       fline_opcode_latch(5 downto 3)="100" AND state /= "11") AND NOT
				      (state="11" AND memmaskmux(3)='1' AND setstate="00") THEN
					memaddr_delta_rega <= addsub_q;
				ELSIF set(restore_ADDR)='1' THEN
					memaddr_delta_rega <= tmp_TG68_PC;
				ELSIF exec(direct_delta)='1' THEN
					memaddr_delta_rega <= data_read;
				ELSIF exec(ea_to_pc)='1' AND setstate="00" THEN
					memaddr_delta_rega <= addr;
				-- BUG #387 FIX V6: During pmmu_ld_nn second pass for (xxx).L mode,
				-- set(addrlong) would overwrite memaddr_delta_rega with stale last_data_read
				-- (which contains garbage from the unnecessary third fetch). Override with
				-- pmove_disp_latched which has the correct full 32-bit address assembled
				-- during the first pass (addr_hi from last_opc_read + addr_lo from data_read).
				ELSIF set(addrlong)='1' AND micro_state = pmmu_ld_nn AND
				      fline_context_valid = '1' AND
				      fline_opcode_latch(5 downto 3)="111" AND fline_opcode_latch(2 downto 0)="001" THEN
					memaddr_delta_rega <= pmove_disp_latched;
					use_base <= '0';
					report "BUG387_V6: pmmu_ld_nn override, disp=" & integer'image(conv_integer(pmove_disp_latched)) severity note;
				ELSIF set(addrlong)='1' THEN
					memaddr_delta_rega <= last_data_read;
				-- BUG #149 FIX: MOVES bus access pending needs to bypass normal address calc
				-- Exclude moves_bus_pending to prevent PC increment during MOVES bus access
				-- BUG #322 FIX: Removed moves0 exclusion - moves0 with setstate="00" is a fetch cycle
				-- that needs PC-based addressing. The exclusion was corrupting the address for
				-- displacement/indexed/absolute EA modes that need to read from the instruction stream.
				-- moves1 exclusion also removed since moves1 never has setstate="00" (always "10" or "11").
				ELSIF setstate="00" AND moves_bus_pending = '0' THEN
					memaddr_delta_rega <= TG68_PC_add;
				ELSIF exec(dispouter)='1' THEN
					memaddr_delta_rega <= ea_data;
					memaddr_delta_regb <= memaddr_a;
				ELSIF set_vectoraddr='1' THEN
					memaddr_delta_rega <= trap_vector_vbr;
				-- BUG #332 FIX: MOVES full-format BD=word fetch timing fix.
				-- During ld_229_1 with state="00" (BD word fetch), memaddr_a reads
				-- last_data_read which still has the EXTENSION WORD, not the BD word.
				-- The BD word is in data_read (combinational from bus) but hasn't been
				-- registered into last_data_read yet. Use data_read directly so that
				-- memaddr_delta_rega has the correct displacement for ld_AnXn2 (IS=0 path).
				-- For BD=word: data_read is sign-extended (memread(0)='1' during state="00").
				ELSIF micro_state = ld_229_1 AND state = "00" AND brief(5) = '1' AND
				      opcode(15 downto 8) = "00001110" AND opcode(7 downto 6) /= "11" AND
				      opcode(5 downto 3) = "110" THEN
					memaddr_delta_rega <= data_read;
					IF brief(7) = '0' THEN
						use_base <= '1';  -- BS=0: use base register
					END IF;
					-- BS=1: use_base stays '0' (default)
				-- BUG #393 FIX: Hold address during PLOAD/PTEST/PFLUSH walker execution.
				-- The EA was computed by PMMU EA builders (pmmu_ld_dAn1/AnXn2/nn) and
				-- registered into memaddr_delta_rega on the transition to pload1/ptest1/pflush1.
				-- Without this hold, the ELSE default overwrites it with memaddr_a=0 (setdisp='0'),
				-- causing addr to revert to reg_QA (losing displacement/index/absolute offset).
				ELSIF (micro_state = pload1 OR micro_state = ptest1 OR micro_state = pflush1) AND
				      fline_context_valid = '1' AND setstate /= "00" THEN
					memaddr_delta_rega <= memaddr_delta_rega;  -- hold computed EA
					use_base <= use_base;  -- hold (0 for absolute, 1 for register-relative)
				ELSE
					memaddr_delta_rega <= memaddr_a;
					IF interrupt='0' AND Suppress_Base='0' THEN
--					IF interrupt='0' AND Suppress_Base='0' AND setstate(1)='1' THEN
						use_base <= '1';
					END IF;
				END IF;
					
		-- only used for movem address update
--					IF (long_done='0' AND state(1)='1') OR movem_presub='0' THEN
					if ((memread(0) = '1') and state(1) = '1') or movem_presub = '0' then -- fix for unaligned movem mikej
						memaddr <= addr;
					END IF;
			END IF;
		END IF;

		-- BUG #302: Combinational +4 offset for (An)+ CRP/SRP LOW word reads
		IF (micro_state = pmove_mem_to_mmu_lo) AND
		   (next_micro_state = pmove_mem_to_mmu_lo OR next_micro_state = idle) AND
		   (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") AND
		   pmmu_ea_mode_latched(5 downto 3)="011" THEN
			-- Add +4 base offset, +2 more for second word of longword
			IF memmaskmux(3)='1' THEN
				memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb + X"00000006";
			ELSE
				memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb + X"00000004";
			END IF;
		ELSE
			memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb;
		END IF;

		-- if access done, and not aligned, don't increment
        addr <= memaddr_reg+memaddr_delta;
        -- route logical address through PMMU for translation
        pmmu_addr_log_int <= memaddr_reg + memaddr_delta;

		IF use_base='0' THEN
			memaddr_reg <= (others=>'0');
		ELSE
			memaddr_reg <= reg_QA;
		END IF;
    END PROCESS;
    
-----------------------------------------------------------------------------
-- PC Calc + fetch opcode
-----------------------------------------------------------------------------
PROCESS (clk, IPL, setstate, addrvalue, state, exec_write_back, set_direct_data, next_micro_state, stop, make_trace, make_berr, IPL_nr, FlagsSR, set_rot_cnt, opcode, writePCbig, set_exec, exec,
        PC_dataa, PC_datab, setnextpass, last_data_read, TG68_PC_brw, TG68_PC_word, Z_error, trap_trap, trap_trapv, interrupt, tmp_TG68_PC, TG68_PC, use_VBR_Stackframe, writePCnext, pmove_dn_mode, cpu_halted)
	BEGIN
	
		PC_dataa <= TG68_PC;
		IF TG68_PC_brw = '1' THEN
			PC_dataa <= tmp_TG68_PC;
		END IF;
		
		PC_datab(2 downto 0) <= (others => '0');
		PC_datab(3) <= PC_datab(2);
		PC_datab(7 downto 4) <= (others => PC_datab(3));
		PC_datab(15 downto 8) <= (others => PC_datab(7));
		PC_datab(31 downto 16) <= (others => PC_datab(15));
		IF interrupt='1' THEN
			PC_datab(2 downto 1) <= "11";
		END IF;
		IF exec(writePC_add) ='1' THEN
			-- BUG #54 FIX: Use pmove_dn_mode to trigger +2 increment (Command Word skip) for PMOVE Dn
			-- writePCbig appears disconnected/uninitialized.
			-- BUG #352 FIX: REMOVED pmove_dn_mode PC increment! 
			-- Standard prefetch already advances PC past the extension word.
			-- This +2 caused a DOUBLE increment (jump to +4 from expected).
			-- IF pmove_dn_mode='1' THEN
			--	PC_datab(1) <= '1'; -- +2
			-- ELSIF writePCbig='1' OR set_writePCbig='1' THEN
			IF writePCbig='1' OR set_writePCbig='1' THEN
				-- BUG #54/#350 FIX: writePCbig must increment by +2, NOT +10!
				-- Used by PMOVE (Dn/Mem) and MOVEC to skip the Command Word (4-byte instr total).
				-- Previous logic (bit 3 + bit 1) added +10, causing massive PC jump!
				-- +2 via bit 1 ensures proper skipping of the 2-byte extension word.
				PC_datab(1) <= '1'; -- +2
			ELSE	
				PC_datab(2) <= '1'; -- +4 (Default)
			END IF;
			IF (use_VBR_Stackframe='0' AND (trap_trap='1' OR trap_trapv='1' OR exec(trap_chk)='1' OR Z_error='1')) OR writePCnext='1' THEN
				PC_datab(1) <= '1';
			END IF;
		ELSIF state="00" THEN
			PC_datab(1) <= '1';
		END IF;	
		IF TG68_PC_brw = '1' THEN	
			IF TG68_PC_word='1' THEN
				PC_datab <= last_data_read;
			ELSE
				PC_datab(7 downto 0) <= opcode(7 downto 0);
			END IF;
		END IF;

		TG68_PC_add <= PC_dataa+PC_datab;
		
		setopcode <= '0';
		setendOPC <= '0';
		setinterrupt <= '0';
		-- BUG #340 FIX: PMOVE/FPU completes with next_micro_state=nop (not idle), must set setendOPC
		-- to clear fline_context_valid, allowing subsequent F-line opcodes to latch
		-- Only applies when fline_context_valid='1' to avoid affecting non-F-line nop transitions
		-- BUG #349 FIX: Allow setstate="01" for F-line retirement!
		-- PMOVE Mem->MMU handlers use setstate="01" to stall and prevent PC fetch/increment.
		-- This prevented setendOPC from firing, leaving fline_context_valid='1', which in turn
		-- prevented the NEXT instruction from updating the F-line latches, causing an F-Line trap.
		-- BUG #356/361 FIX: Prevent setendOPC during PMMU Dn retirement (pmove_decode, pmmu_dn_read_wait)
		-- to avoid latching the extension word as the next opcode. The retirement will happen via
		-- the normal idle transition after the stall cycle completes.
		-- BUG #369 FIX: Also exclude ptest1/pflush1/pload1 - same stale opcode problem.
		-- When these states retire with setstate="00", state is still "01" from the stall cycle,
		-- causing opcode <= last_opc_read (stale extension word) instead of data_read (next instr).
		IF (setstate="00" OR (setstate="01" AND fline_context_valid='1')) AND next_micro_state=idle AND setnextpass='0' AND (exec_write_back='0' OR state="11") AND set_rot_cnt="000001" AND set_exec(opcCHK)='0' AND micro_state /= pmmu_dn_read_wait AND micro_state /= pmove_decode AND micro_state /= pmove_mem_to_mmu_hi AND micro_state /= pmove_mem_to_mmu_lo AND micro_state /= pmove_mmu_to_mem_hi AND micro_state /= pmove_mmu_to_mem_lo AND micro_state /= ptest1 AND micro_state /= pflush1 AND micro_state /= pload1 AND cpu_halted='0' THEN
			setendOPC <= '1';
			-- BUG #400 FIX: Also check pmmu_fault directly (not just make_berr) for immediate
			-- bus error dispatch. make_berr is registered and won't reflect pmmu_fault until
			-- the NEXT clkena_lw edge, allowing the CPU to advance past the faulting instruction.
			-- By checking pmmu_fault combinationally, the bus error is caught at the same edge
			-- where the faulting memory write completes (state="11"->"00").
			IF FlagsSR(2 downto 0)<IPL_nr OR IPL_nr="111"  OR make_trace='1' OR make_berr='1'
			   OR (pmmu_tc_en='1' AND pmmu_fault='1' AND trap_berr='0' AND trap_mmu_berr='0') THEN
				setinterrupt <= '1';
			ELSIF stop='0' THEN
				setopcode <= '1';
			END IF;
		END IF;	
		setexecOPC <= '0';
		-- BUG #32 FIX: Allow setstate="01" for PMMU operations ONLY!
		-- Bug #30 sets setstate="01" to enable clkena_lw, but original check only allowed setstate="00".
		-- This prevented setexecOPC for PMMU register reads, breaking exec(Regwrena) transfer.
		-- BUG #34 FIX: setstate="01" is used by MANY operations (20+ places), not just PMMU!
		-- Allowing it unconditionally breaks AmigaOS boot (yellow screen)!
		-- Only allow setstate="01" when PMMU operations are pending in set_exec layer.
		IF setstate="00" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) THEN
			setexecOPC <= '1';
		ELSIF setstate="01" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) AND
		      (set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR set(pmmu_rd)='1') THEN
			-- CRITICAL: Only for PMMU Dn mode operations! Other operations using setstate="01" don't need setexecOPC.
			-- BUG #111 FIX: Removed set(pmmu_wr) check - now using set_exec(pmmu_wr) for Dn WRITE (line 4644)
			-- Check for: set_exec(pmmu_wr) (pmove_decode Dn writes), set_exec(pmmu_rd) (pmove_dn_lo reads),
			--            set(pmmu_rd) (pmove_decode Dn reads)
			setexecOPC <= '1';
		END IF;
		
		IPL_nr <= NOT IPL;
		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				state <= "01";
				addrvalue <= '0';
				opcode <= X"2E79"; 					--move $0,a7
				trap_interrupt <= '0';
				interrupt <= '0';
				last_opc_read  <= X"4EF9";			--jmp nn.l
				TG68_PC <= X"00000004";
				decodeOPC <= '0';
				endOPC <= '0';
				TG68_PC_word <= '0';
				execOPC <= '0';
--				execOPC_ALU <= '0';
				stop <= '0';
				rot_cnt <="000001";
--				byte <= '0';
--				IPL_nr <= "000";
				trap_trace <= '0';
					trap_berr <= '0';
					writePCbig <= '0';
--				recall_last <= '0';
					Suppress_Base <= '0';
					make_berr <= '0';
					berr_exception_active <= '0';
					cpu_halted <= '0';
					pmmu_fault_dispatched <= '0';
					memmask <= "111111";
					exec_write_back <= '0';
					-- BUG #70 SIMPLIFICATION: Simple 2-signal initialization
					pmove_dn_regnum <= (others => '0');
					pmove_dn_mode <= '0';
					-- F-Line context latch initialization
					fline_opcode_latch <= (others => '0');
					fline_brief_latch <= (others => '0');
					fline_context_valid <= '0';
					fline_is_pmmu <= '0';
					fline_is_fpu <= '0';
					fline_has_brief <= '0';
					pmmu_ea_mode_latched <= (others => '0');  -- BUG #302: Initialize EA mode latch
			ELSE
--				IPL_nr <= NOT IPL;
				IF clkena_in='1' THEN
					memmask <= memmask(3 downto 0)&"11";
					memread <= memread(1 downto 0)&memmaskmux(5 downto 4);
--					IF wbmemmask(5 downto 4)="11" THEN
--						wbmemmask <= memmask;
--					END IF;
					IF exec(directPC)='1' THEN
						TG68_PC <= data_read;
					ELSIF exec(ea_to_pc)='1' THEN
						TG68_PC <= addr;
					ELSIF (state ="00" OR TG68_PC_brw = '1') AND stop='0'
					      AND NOT (micro_state = pmmu_ld_nn AND nextpass = '1') THEN
						TG68_PC <= TG68_PC_add;
					END IF;

					-- BUG #53 FIX: Move extension word capture to clkena_in block (1-stage pipeline)
					-- Previously in clkena_lw block, which never executed for PMOVE memory EA modes!
					-- PMOVE memory EA sets memmask="100111" → clkena_lw='0' → brief never captured
					IF getbrief='1' THEN
						IF state(1)='1' THEN
							brief <= last_opc_read(15 downto 0);
						ELSE
							brief <= data_read(15 downto 0);
						END IF;
					END IF;

					-- pmmu_ld_AnXn1 brief latch: For PMOVE (d8,An,Xn) mode,
					-- the EA brief extension word was fetched during the state="00"
					-- bus cycle alongside pmove_decode.  During pmove_decode, state="00"
					-- so data_read has the current bus data (the EA brief word).
					-- last_opc_read still has the PREVIOUS cycle's value (the PMOVE
					-- extension word) because it hasn't been updated yet at this point
					-- in the process (clkena_lw block updates it at line 2542).
					-- Use data_read, matching the getbrief mechanism for state(1)='0'.
					IF micro_state = pmove_decode AND next_micro_state = pmmu_ld_AnXn1 THEN
						brief <= data_read(15 downto 0);
					END IF;

					-- BUG #318/322 FIX: MOVES indexed mode (d8,An,Xn) brief loading
					-- Replaced two-phase approach (phase 1 loaded from last_opc_read) with
					-- getbrief='1' in moves0 which loads brief from data_read at rising edge.
					-- The old phase 1 code is no longer needed.

					-- BUG #289 FIX: F-Line context capture must be in clkena_in block!
					-- The clkena_lw block doesn't execute for PMOVE memory EA (memmask="100111").
					-- By the time clkena_lw='1', brief has advanced to next instruction (NOP).
					-- Fix: Capture fline context from same source as brief, at same time.
					-- CRITICAL: Use next_micro_state, not micro_state! At this clock edge,
					-- micro_state still has the OLD value. next_micro_state has the value
					-- that micro_state will become, which is pmove_decode when getbrief fired.
					IF next_micro_state = pmove_decode AND fline_context_valid = '0' THEN
						fline_opcode_latch <= opcode;
						-- Capture from SAME source as brief to avoid timing issues
						IF state(1)='1' THEN
							fline_brief_latch <= last_opc_read(15 downto 0);
						ELSE
							fline_brief_latch <= data_read(15 downto 0);
						END IF;
						fline_is_pmmu <= '1';
						fline_is_fpu <= '0';
						fline_has_brief <= '1';  -- PMMU instructions with memory EA have extension word
						pmmu_ea_mode_latched <= opcode(5 downto 0);  -- BUG #302: Latch EA mode+reg bits
						fline_context_valid <= '1';
						fline_opcode_pc <= TG68_PC;
					END IF;

					-- BUG #355 FIX: Move PMMU/Dn mode context logic to clkena_in block!
					-- This logic was in clkena_lw, but PMU memory EA modes often skip clkena_lw.
					IF micro_state = pmove_decode THEN
						IF fline_context_valid = '1' THEN
							-- Use latched opcode for stable values during execution
							IF fline_opcode_latch(5 downto 3) = "000" THEN
								pmove_dn_regnum <= fline_opcode_latch(2 downto 0);
								pmove_dn_mode <= '1';
							ELSE
								pmove_dn_mode <= '0';
							END IF;
						ELSIF opcode(5 downto 3) = "000" THEN
							pmove_dn_regnum <= opcode(2 downto 0);  -- Dn from opcode EA
							pmove_dn_mode <= '1';
						ELSE
							pmove_dn_mode <= '0';  -- Clear for non-Dn modes
						END IF;
					-- BUG #198 FIX: Increment pmove_dn_regnum for second half of 64-bit PMOVE
					ELSIF micro_state = pmove_dn_hi THEN
						-- Transition from pmove_dn_hi to pmove_dn_lo: increment for Dn+1
						pmove_dn_regnum <= pmove_dn_regnum + "001";
					END IF;

					-- BUG #356 FIX: Clear F-line context in clkena_in block!
					-- Must use setendOPC from previous cycle (latched as endOPC or seen directly).
					-- Using setendOPC directly is safe in clkena_in as it's the Combinatorial Retire signal.
					-- BUG #362 FIX: Removed pmove_dn_lo from exclusion list!
					-- When setendOPC fires during pmove_dn_lo, the 64-bit Dn transfer IS complete
					-- (next_micro_state=idle). Keeping fline_context_valid='1' after this caused
					-- subsequent PMOVE instructions to fail to capture their fline_opcode_latch,
					-- resulting in stale opcode(5:3) dispatching as Dn mode instead of memory mode.
					IF (setendOPC = '1' OR trapmake = '1') AND micro_state /= pmove_decode AND micro_state /= pmove_dn_hi AND micro_state /= pmmu_dn_read_wait THEN
						fline_context_valid <= '0';
					END IF;

					-- BUG #389 FIX V2: Clear exec_write_back when PMMU states retire to idle!
					-- MOVED FROM clkena_lw BLOCK TO clkena_in BLOCK to fix hardware lockup.
					-- exec_write_back blocks setendOPC (line 2376: exec_write_back='0' OR state="11").
					-- When pmove_mem_to_mmu_hi/lo retire with setstate="00" and state="10" from EA read,
					-- exec_write_back='1' blocks setopcode, causing decodeOPC='0' on next instruction.
					-- CRITICAL: Must execute in clkena_in block! If in clkena_lw block, it only runs
					-- when memmaskmux(3)='1'. PMMU retirement may have memmaskmux(3)='0', causing
					-- clkena_lw='0', so the clear never executes → permanent lockup on hardware.
					IF (micro_state=pmove_mem_to_mmu_hi OR micro_state=pmove_mem_to_mmu_lo) AND
					   next_micro_state=idle AND setstate="00" THEN
						exec_write_back <= '0';
					END IF;
				END IF;
				IF clkena_lw='1' THEN
					interrupt <= setinterrupt;
					decodeOPC <= setopcode;
					endOPC <= setendOPC;
					execOPC <= setexecOPC;
					-- BUG #400 FIX: Clear dispatched flag when PMMU fault_reg is cleared
					-- (happens when a new translation request is issued, e.g., berr stack push)
					if pmmu_fault = '0' then
						pmmu_fault_dispatched <= '0';
					end if;
--					IF setexecOPC='1' OR set(alu_exec)='1' THEN
--						execOPC_ALU <= '1';
--					ELSE
--						execOPC_ALU <= '0';
--					END IF;
					
					exe_datatype <= set_datatype;
					exe_opcode <= opcode;

					if(trap_berr='0' and trap_mmu_berr='0') then
						if pmmu_tc_en = '1' then
							make_berr <= (berr OR make_berr OR pmmu_fault);  -- Include PMMU faults when MMU enabled
							-- BUG #159 FIX: Track if PMMU fault is a bus error (B bit = pmmu_fault_stat(15))
							-- This determines whether to use vector 2 (normal BERR) or vector 61 (MMU BERR)
							if pmmu_fault = '1' and pmmu_fault_stat(15) = '1' then
								make_mmu_berr <= '1';
							else
								make_mmu_berr <= make_mmu_berr;  -- Keep previous value
							end if;
						else
							make_berr <= (berr OR make_berr);  -- No PMMU faults when MMU disabled
							make_mmu_berr <= '0';
						end if;
					else
						-- MC68030 Double bus fault detection: bus error/fault during bus error processing
						-- Per MC68030UM Section 8.4: "If a bus error is detected during exception
						-- processing of a bus error, the processor enters the halted state."
						-- BUG #400 FIX: Only trigger on NEW pmmu_fault (pmmu_fault_dispatched='0').
						-- The stale pmmu_fault from the just-dispatched bus error persists until
						-- a new translation request clears fault_reg. Without this guard, every
						-- PMMU bus error would immediately trigger a false double bus fault.
						if cpu(1) = '1' and (berr = '1' or (pmmu_tc_en = '1' and pmmu_fault = '1' and pmmu_fault_dispatched = '0')) then
							cpu_halted <= '1';
							-- synthesis translate_off
							report "DOUBLE BUS FAULT: fault during bus error exception processing - CPU HALTED" severity warning;
							-- synthesis translate_on
						end if;
						make_berr <= '0';
						make_mmu_berr <= '0';
					end if;

					stop <= set_stop OR (stop AND NOT setinterrupt);
					IF setinterrupt='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
--						TG68_PC_word <= '0';
						make_berr <= '0';
						make_mmu_berr <= '0';  -- BUG #159: Clear MMU BERR flag
						trap_berr <= '0';
						trap_mmu_berr <= '0';  -- BUG #159: Clear MMU BERR trap
						IF make_trace='1' THEN
							trap_trace <= '1';
						-- BUG #400 FIX: Also check pmmu_fault directly for same-cycle dispatch
						ELSIF make_berr='1' OR (pmmu_tc_en='1' AND pmmu_fault='1' AND trap_berr='0' AND trap_mmu_berr='0') THEN
							-- MC68030 Double bus fault detection: bus error while still in berr exception window
							-- This catches the case where the handler instruction fetch faults
							IF cpu(1) = '1' AND berr_exception_active = '1' THEN
								cpu_halted <= '1';
								-- synthesis translate_off
								report "DOUBLE BUS FAULT: bus error at handler dispatch - CPU HALTED" severity warning;
								-- synthesis translate_on
							ELSE
								-- BUG #159 FIX: Distinguish MMU bus error (vector 61) from normal BERR (vector 2)
								-- BUG #400 FIX: Also check pmmu_fault_stat directly for same-cycle dispatch
								IF make_mmu_berr='1' OR (pmmu_fault='1' AND pmmu_fault_stat(15)='1') THEN
									trap_mmu_berr <= '1';  -- Use vector 61 for MMU bus error
								ELSE
									trap_berr <= '1';  -- Use vector 2 for normal bus error
								END IF;
								-- BUG #400 FIX: Mark pmmu_fault as dispatched to prevent false
								-- double bus fault from stale fault_reg before new translation clears it
								if pmmu_fault = '1' then
									pmmu_fault_dispatched <= '1';
								end if;
								berr_exception_active <= '1';
							END IF;
						ELSE
							rIPL_nr <= IPL_nr;
							IPL_vec <= "00011"&IPL_nr;            --	TH
							trap_interrupt <= '1';
							berr_exception_active <= '0';
						END IF;
					END IF;
					IF micro_state=trap0 AND IPL_autovector='0' THEN 			
						IPL_vec <= last_data_read(7 downto 0);    --	TH
					END IF;	

					IF state="00" THEN
						last_opc_read <= data_read(15 downto 0);
						last_opc_pc <= tg68_pc;--TH
					END IF;	
					IF setopcode='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
						TG68_PC_word <= '0';
						trap_berr <= '0';
						-- MC68030: Clear berr exception window when normal instruction fetches
						-- Don't clear if trap_berr was still active (it reads the OLD value here)
						-- or if make_berr is pending - handler fetch may have faulted
						IF trap_berr='0' AND make_berr='0' THEN
							berr_exception_active <= '0';
						END IF;
						-- BUG #65 FIX: Do NOT clear pmove_dn_mode here!
						-- pmove_dn_mode is now cleared ONLY when queue becomes empty (lines 1765-1766)
					ELSIF opcode(7 downto 0)="00000000" OR opcode(7 downto 0)="11111111" OR data_is_source='1' THEN
						TG68_PC_word <= '1';
					END IF;	
					
					IF exec(get_bfoffset)='1' THEN
						alu_width <= bf_width;
						alu_bf_shift <= bf_shift;
						alu_bf_loffset <= bf_loffset;
						alu_bf_ffo_offset <= bf_full_offset+bf_width+1;
					END IF;
					memread <= "1111";
					fc_internal(1) <= NOT setstate(1) OR (PCbase AND NOT setstate(0));
					fc_internal(0) <= setstate(1) AND (NOT PCbase OR setstate(0));
					IF interrupt='1' THEN
						fc_internal(1 downto 0) <= "11";
					END IF;
					-- MOVES instruction FC override (uses SFC/DFC instead of current FC)
					-- Note: Only override fc_internal(1 downto 0) here; fc_internal(2) is set elsewhere in clocked process
					IF set(use_sfc_dfc)='1' OR exec(use_sfc_dfc)='1' THEN
						IF set(sfc_not_dfc)='1' OR exec(sfc_not_dfc)='1' THEN
							fc_internal(1 downto 0) <= SFC(1 downto 0);  -- Use SFC for memory read
						ELSE
							fc_internal(1 downto 0) <= DFC(1 downto 0);  -- Use DFC for memory write
						END IF;
					END IF;

					IF state="11" THEN
						exec_write_back <= '0';
					ELSIF setstate="10" AND setaddrvalue='0' AND write_back='1' THEN
						exec_write_back <= '1';
					-- BUG #389 FIX V2: PMMU retirement clearing moved to clkena_in block (line 2584)
					-- to ensure it executes regardless of memmaskmux(3) state.
					END IF;	
					IF (state="10" AND addrvalue='0' AND write_back='1' AND setstate/="10") OR set_rot_cnt/="000001" OR (stop='1' AND interrupt='0') OR set_exec(opcCHK)='1' THEN
						state <= "01";
						memmask <= "111111";
						addrvalue <= '0';
					ELSIF execOPC='1' AND exec_write_back='1' THEN
						state <= "11";
						fc_internal(1 downto 0) <= "01";
						memmask <= wbmemmask;
						addrvalue <= '0';
					ELSE	
						state <= setstate;
						addrvalue <= setaddrvalue; 
						IF setstate="01" THEN
							memmask <= "111111";
							wbmemmask <= "111111";
						ELSIF exec(get_bfoffset)='1' THEN
							memmask <= set_memmask;
							wbmemmask <= set_memmask;
							oddout <= set_oddout;
						ELSIF set(longaktion)='1' THEN
							-- -- BUG #190 FIX: Only initialize longaktion memmask if NOT already in sequence!
							-- -- Without this check, memmask keeps resetting to "100001" every cycle,
							-- -- preventing the shift that selects the low word for the second bus cycle.
							-- IF memmask /= "100001" AND memmask /= "000111" AND memmask /= "011111" THEN
							 	memmask <= "100001";
							 	wbmemmask <= "100001";
							-- END IF;
							oddout <= '0';
--						ELSIF set_datatype="00" AND setstate(1)='1' AND setaddrvalue='0' THEN	
						ELSIF set_datatype="00" AND setstate(1)='1' THEN	
							memmask <= "101111";
							wbmemmask <= "101111";
							IF set(mem_byte)='1' THEN
								oddout <= '0';
							ELSE
								oddout <= '1';
							END IF;	
						ELSE
							-- -- BUG #190 FIX: Don't override memmask if in longword write sequence!
							-- -- Longword write uses memmask sequence: "100001" -> "000111" -> "011111" -> "111111"
							-- -- The shift at line 1662 (memmask <= memmask(3:0)&"11") advances the sequence.
							-- -- Without this check, the default memmask="100111" overrides the shift,
							-- -- causing both 16-bit writes to use the same data (high word duplicated).
							-- IF memmask /= "100001" AND memmask /= "000111" AND memmask /= "011111" THEN
								memmask <= "100111";
								wbmemmask <= "100111";
							-- END IF;
							oddout <= '0';
						END IF;	
					END IF;

					IF decodeOPC='1' THEN
						rot_bits <= set_rot_bits;
						writePCbig <= '0';
					ELSE	
						writePCbig <= set_writePCbig OR writePCbig; 
					END IF;
					IF decodeOPC='1' OR exec(ld_rot_cnt)='1' OR rot_cnt/="000001" THEN
						rot_cnt <= set_rot_cnt;
					END IF;
					
					IF set_Suppress_Base='1' THEN
						Suppress_Base <= '1';
					ELSIF setstate(1)='1' OR (ea_only='1' AND set(get_ea_now)='1') THEN
						Suppress_Base <= '0';
					END IF;
					-- BUG #53 FIX: Extension word capture moved to clkena_in block (line 1482)
					-- Old code removed from clkena_lw block to prevent multiple drivers
					-- IF getbrief='1' THEN
					-- 	IF state(1)='1' THEN
					-- 		brief <= last_opc_read(15 downto 0);
					-- 	ELSE
					-- 		brief <= data_read(15 downto 0);
					-- 	END IF;
					-- END IF;

					IF setopcode='1' AND berr='0' THEN
						IF state="00" THEN
							opcode <= data_read(15 downto 0);
							exe_pc <= tg68_pc;--TH
						ELSE
							opcode <= last_opc_read(15 downto 0);
							exe_pc <= last_opc_pc;--TH
						END IF;
						nextpass <= '0';
					ELSIF setinterrupt='1' OR setopcode='1' THEN
						opcode <= X"4E71";		--nop
						nextpass <= '0';
					ELSE
--						IF setnextpass='1' OR (regdirectsource='1' AND state="00") THEN
						IF setnextpass='1' OR regdirectsource='1' THEN
							nextpass <= '1';
						END IF;
					END IF;

					IF decodeOPC='1' OR interrupt='1' THEN
						trap_SR <= FlagsSR;
					END IF;
				END IF;
			END IF;
		END IF;

		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				PCbase <= '1';
			ELSIF clkena_lw='1' THEN
				PCbase <= set_PCbase OR PCbase;
				IF setexecOPC='1' OR (state(1)='1' AND movem_run='0') THEN
					PCbase <= '0';
				END IF;
			END IF;
				IF clkena_lw='1' THEN
					exec <= set;
				exec(alu_move) <= set(opcMOVE) OR set(alu_move);
				exec(alu_setFlags) <= set(opcADD) OR set(alu_setFlags);
				exec_tas <= '0';
				exec(subidx) <= set(presub) or set(subidx);
					IF setexecOPC='1' THEN
						exec <= set_exec OR set;
					exec(alu_move) <= set_exec(opcMOVE) OR set(opcMOVE) OR set(alu_move);
					exec(alu_setFlags) <= set_exec(opcADD) OR set(opcADD) OR set(alu_setFlags);
					exec_tas <= set_exec_tas;
					-- BUG #70 SIMPLIFICATION: Clear pmove_dn_mode when instruction completes
					-- BUG #81 FIX: Don't clear during PMOVE Dn read - register write happens NEXT cycle!
					-- BUG #106 FIX: Keep pmove_dn_mode alive while exec(pmmu_rd) OR exec(Regwrena) active!
					-- BUG #112 FIX V2: Must check set_exec(pmmu_wr) and set(pmmu_wr) as well as exec(pmmu_wr)!
					-- VHDL signal timing: exec is being assigned from set_exec OR set on line 1702, but signal
					-- assignments don't take effect until end of process. So exec(pmmu_wr) shows the OLD value,
					-- not the NEW value being set up. Must check ALL THREE layers to prevent early clear!
					IF set(pmmu_rd)='0' AND exec(pmmu_rd)='0' AND
					   set_exec(pmmu_wr)='0' AND set(pmmu_wr)='0' AND exec(pmmu_wr)='0' AND
					   exec(Regwrena)='0' THEN
						pmove_dn_mode <= '0';
					END IF;
					END IF;	
				exec(get_2ndOPC) <= set(get_2ndOPC) OR setopcode;

				END IF;
			END IF;
		END PROCESS;
	
------------------------------------------------------------------------------
--prepare Bitfield Parameters
------------------------------------------------------------------------------		
PROCESS (clk, Reset, sndOPC, reg_QA, reg_QB, bf_width, bf_offset, bf_bhits, opcode, setstate, bf_shift)
	BEGIN
		IF sndOPC(11)='1' THEN
			bf_offset <= '0'&reg_QA(4 downto 0);
		ELSE
			bf_offset <= '0'&sndOPC(10 downto 6);
		END IF;	
		IF sndOPC(11)='1' THEN
			bf_full_offset <= reg_QA;
		ELSE
			bf_full_offset <= (others => '0');
			bf_full_offset(4 downto 0) <= sndOPC(10 downto 6);
		END IF;	
		
		bf_width(5) <= '0';
		IF sndOPC(5)='1' THEN
			bf_width(4 downto 0) <= reg_QB(4 downto 0)-1;
		ELSE
			bf_width(4 downto 0) <= sndOPC(4 downto 0)-1;
		END IF;	
		bf_bhits <= bf_width+bf_offset;
		set_oddout <= NOT bf_bhits(3);
		

-- bf_loffset is used for the shifted_bitmask
		IF opcode(10 downto 8)="111" THEN --INS
			bf_loffset <= 32-bf_shift;
		ELSE
			bf_loffset <= bf_shift;
		END IF;
		bf_loffset(5) <= '0';
		
		IF opcode(4 downto 3)="00" THEN
			IF opcode(10 downto 8)="111" THEN --INS
				bf_shift <= bf_bhits+1;
			ELSE
				bf_shift <= 31-bf_bhits;
			END IF;
			bf_shift(5) <= '0';
		ELSE
			IF opcode(10 downto 8)="111" THEN --INS
				bf_shift <= "011001"+("000"&bf_bhits(2 downto 0));
				bf_shift(5) <= '0';
			ELSE
				bf_shift <= "000"&("111"-bf_bhits(2 downto 0));
			END IF;
			bf_offset(4 downto 3) <= "00";
		END IF;
		
		CASE bf_bhits(5 downto 3) IS
			WHEN "000" =>
				set_memmask <= "101111";
			WHEN "001" =>
				set_memmask <= "100111";
			WHEN "010" =>
				set_memmask <= "100011";
			WHEN "011" =>
				set_memmask <= "100001";
			WHEN OTHERS =>
				set_memmask <= "100000";
		END CASE;	
		IF setstate="00" THEN
			set_memmask <= "100111";
		END IF;
	END PROCESS;		
	
------------------------------------------------------------------------------
--SR op
------------------------------------------------------------------------------		
PROCESS (clk, Reset, FlagsSR, last_data_read, OP2out, exec)
	BEGIN
		IF exec(andiSR)='1' THEN
			SRin <= FlagsSR AND last_data_read(15 downto 8);
		ELSIF exec(eoriSR)='1' THEN
			SRin <= FlagsSR XOR last_data_read(15 downto 8);
		ELSIF exec(oriSR)='1' THEN
			SRin <= FlagsSR OR last_data_read(15 downto 8);
		ELSE	
			SRin <= OP2out(15 downto 8);
		END IF;	
		
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				fc_internal(2) <= '1';
				SVmode <= '1';
				preSVmode <= '1';
				FlagsSR <= "00100111";
				make_trace <= '0';
			ELSIF clkena_lw = '1' THEN
				IF setopcode='1' THEN
					make_trace <= FlagsSR(7);
					IF set(changeMode)='1' THEN
						SVmode <= NOT SVmode; 
					ELSE
						SVmode <= preSVmode;
					END IF;	
				END IF;
				IF trap_berr='1' OR trap_illegal='1' OR trap_addr_error='1' OR trap_priv='1' OR trap_1010='1' OR trap_1111='1' OR trap_mmu_config='1' OR trap_mmu_berr='1' THEN
					make_trace <= '0';
					FlagsSR(7) <= '0';
				END IF;
				IF set(changeMode)='1' THEN
					preSVmode <= NOT preSVmode;
					FlagsSR(5) <= NOT preSVmode;
					fc_internal(2) <= NOT preSVmode;
				END IF;
				IF micro_state=trap3 THEN
					FlagsSR(7) <= '0';
				END IF;
				IF trap_trace='1' AND state="10" THEN
					make_trace <= '0';
				END IF;
				IF exec(directSR)='1' OR set_stop='1' THEN
					FlagsSR <= data_read(15 downto 8);
					-- -- BUG #15 FIX: Sync preSVmode with SR bit 13 (supervisor bit) on RTE
					-- -- When RTE restores SR from stack, preSVmode must track the restored S bit
					-- -- Without this, supervisor->user transitions fail, breaking MMU detection!
					-- preSVmode <= data_read(13);
				END IF;
				IF interrupt='1' AND trap_interrupt='1' THEN
					FlagsSR(2 downto 0) <=rIPL_nr;
					-- MC68030: Clear M bit on interrupt entry (handler uses ISP)
					IF cpu(1)='1' THEN
						FlagsSR(4) <= '0';
					END IF;
				END IF;
				IF exec(to_SR)='1' THEN
					FlagsSR(7 downto 0) <= SRin;	--SR
					fc_internal(2) <= SRin(5);
					-- -- BUG #15 FIX: Sync preSVmode with SR bit 5 (supervisor bit in low byte) on MOVE to SR
					-- -- When MOVE to SR or MOVE to CCR executes, preSVmode must track the new S bit
					-- -- Without this, MOVE #$0000,SR (enter user mode) doesn't work, breaking MMU detection!
					-- preSVmode <= SRin(5);
				ELSIF exec(update_FC)='1' THEN
					fc_internal(2) <= FlagsSR(5);
				END IF;
				-- MOVES instruction FC(2) override
				IF set(use_sfc_dfc)='1' OR exec(use_sfc_dfc)='1' THEN
					IF set(sfc_not_dfc)='1' OR exec(sfc_not_dfc)='1' THEN
						fc_internal(2) <= SFC(2);  -- Use SFC(2) for supervisor bit
					ELSE
						fc_internal(2) <= DFC(2);  -- Use DFC(2) for supervisor bit
					END IF;
				END IF;
				IF interrupt='1' THEN
					fc_internal(2) <= '1';
				END IF;
				IF cpu(1)='0' THEN
					FlagsSR(4) <= '0';
					FlagsSR(6) <= '0';
				END IF;
				FlagsSR(3) <= '0';
			END IF;
		END IF;	
	END PROCESS;

-----------------------------------------------------------------------------
-- decode opcode
-----------------------------------------------------------------------------
PROCESS (clk, cpu, OP1out, OP2out, opcode, exe_condition, nextpass, micro_state, decodeOPC, state, setexecOPC, Flags, FlagsSR, direct_data, build_logical,
		 build_bcd, set_Z_error, trapd, movem_run, last_data_read, set, set_V_Flag, z_error, trap_trace, trap_interrupt,
		 SVmode, preSVmode, stop, long_done, ea_only, setstate, addrvalue, execOPC, exec_write_back, exe_datatype,
		 datatype, interrupt, c_out, trapmake, rot_cnt, brief, addr, trap_trapv, last_data_in, use_VBR_Stackframe,
		 long_start, set_datatype, sndOPC, set_exec, exec, ea_build_now, reg_QA, reg_QB, make_berr, trap_berr, last_opc_read,
		 moves_writeback_pending, moves_active, pmmu_opcode, pmmu_brief)
	BEGIN
		TG68_PC_brw <= '0';	
		setstate <= "00";
		setaddrvalue <= '0';
		Regwrena_now <= '0';
		movem_presub <= '0';
		setnextpass <= '0';
		regdirectsource <= '0';
		setdisp <= '0';
		setdispbyte <= '0';
		getbrief <= '0';
		dest_LDRareg <= '0';
		dest_areg <= '0';
		source_areg <= '0';
		data_is_source <= '0';
		write_back <= '0';
		setstackaddr <= '0';
		writePC <= '0';
		ea_build_now <= '0';
--		set_rot_bits <= "00";
		set_rot_bits <= opcode(4 downto 3);
		set_rot_cnt <= "000001";
		dest_hbits <= '0';
		source_lowbits <= '0';
		source_LDRLbits <= '0';
		source_LDRMbits <= '0';
		source_2ndHbits <= '0';
		source_2ndMbits <= '0';
		source_2ndLbits <= '0';
		dest_LDRHbits <= '0';
		dest_LDRLbits <= '0';
		dest_2ndHbits <= '0';
		dest_2ndLbits <= '0';
		ea_only <= '0';
		set_direct_data <= '0';
		set_exec_tas <= '0';
		trap_illegal <='0';
		trap_addr_error <= '0';
		trap_priv <='0';
		trap_1010 <='0';
		trap_1111 <='0';
		trap_trap <='0';
		trap_trapv <= '0';
		trap_mmu_config <= '0';
		trap_format_error <= '0';
		-- Note: trap_mmu_berr is NOT set here - only in sequencer process (BUG #159)
		trapmake <='0';
		set_vectoraddr <='0';
		writeSR <= '0';
		set_stop <= '0';
--		illegal_write_mode <= '0';
--		illegal_read_mode <= '0';
--		illegal_byteaddr <= '0';
		set_Z_error <= '0';
		check_aligned <='0';

		-- MC68030 MMU Configuration Exception (vector 56)
		-- Triggered when invalid TC/CRP/SRP values are written to PMMU registers
		IF pmmu_config_err = '1' THEN
			trap_mmu_config <= '1';
			trapmake <= '1';
			-- synthesis translate_off
			report "TRAPMAKE_MMU_CONFIG: micro_state=" & micro_states'image(micro_state) severity warning;
			-- synthesis translate_on
		END IF;

		next_micro_state <= idle;
		build_logical <= '0';
		build_bcd <= '0';
		skipFetch <= make_berr;
		set_writePCbig <= '0';
--		set_recall_last <= '0';
		set_Suppress_Base <= '0';
		set_PCbase <= '0';
						
		IF rot_cnt/="000001" THEN
			set_rot_cnt <= rot_cnt-1;
		END IF;	
		set_datatype <= datatype;
		
		set <= (OTHERS=>'0');
		set_exec <= (OTHERS=>'0');
		set(update_ld) <= '0';
--		odd_start <= '0';
------------------------------------------------------------------------------
--Sourcepass
------------------------------------------------------------------------------		
		CASE opcode(7 downto 6) IS
			WHEN "00" => datatype <= "00";		--Byte
			WHEN "01" => datatype <= "01";		--Word
			WHEN OTHERS => datatype <= "10";	--Long
		END CASE;

		IF execOPC='1' AND exec_write_back='1' THEN
			set(restore_ADDR) <= '1';
		END IF;
		
		IF interrupt='1' AND trap_berr='1' THEN
			-- MC68030 bus errors MUST use berr1-berr8 to push Format $A (16-word) frame.
			-- Format $0 from trap0 path would crash any handler expecting Format $A.
			IF cpu(1)='1' THEN
				next_micro_state <= berr1;
			ELSE
				next_micro_state <= trap0;
			END IF;
			-- BUG #401 FIX: Set setstackaddr at dispatch so RDindex_A latches A7 ("1111")
			-- ONE CYCLE BEFORE berr1's first memory write.
			setstackaddr <= '1';
			-- Only need stack swap if A7 currently has user stack (preSVmode='0')
			-- If preSVmode='1', A7 already has supervisor stack, no swap needed
			-- FlagsSR(5) update to '1' is handled in sequential process (see BUG #151)
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
		IF trapmake='1' AND trapd='0' THEN
			-- synthesis translate_off
			report "TRAP_TAKEN: mmu_cfg=" & bit'image(trap_mmu_config) &
			       " illegal=" & bit'image(trap_illegal) &
			       " priv=" & bit'image(trap_priv) &
			       " f1111=" & bit'image(trap_1111) &
			       " berr=" & bit'image(trap_berr) &
			       " ms=" & micro_states'image(micro_state) &
			       " opc=" & integer'image(conv_integer(opcode)) severity warning;
			-- synthesis translate_on
			-- Stack frame format selection (MC68030 User's Manual 6.4.3):
			-- Format #2 (6-word): TRAPV, CHK, CHK2, Divide by Zero, Trace, cpTRAPcc
			-- Format #0 (4-word): All others including privilege violation, F-line, illegal
            -- Format #A (16-word): Bus Error (MC68030)
			IF cpu(1)='1' AND trap_berr='1' THEN
				next_micro_state <= berr1;
				-- BUG #401 FIX: Set setstackaddr at dispatch (see interrupt path above)
				setstackaddr <= '1';
			ELSIF cpu(1)='1' AND (trap_trapv='1' OR set_Z_error='1' OR exec(trap_chk)='1' OR trap_mmu_config='1') THEN
				next_micro_state <= trap00;  -- Format #2 (6-word) per MC68030 UM Table 8-4
			else
				next_micro_state <= trap0;
			end if;
			IF use_VBR_Stackframe='0' THEN
				set(writePC_add) <= '1';
--				set_datatype <= "10";
			END IF;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;
		IF micro_state=int1 OR (interrupt='1' AND trap_trace='1') THEN
-- paste and copy form TH	---------
			if trap_trace='1' AND cpu(1) = '1' then
				next_micro_state <= trap00;  --TH
			else
				next_micro_state <= trap0;
			end if;
------------------------------------
--			next_micro_state <= trap0;
--			IF cpu(0)='0' THEN
--				set_datatype <= "10";
--			END IF;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;

		IF setexecOPC='1' AND FlagsSR(5)/=preSVmode THEN
			set(changeMode) <= '1';
--			setstate <= "01";
--			next_micro_state <= nop;
		END IF;

		IF interrupt='1' AND trap_interrupt='1'THEN
--			skipFetch <= '1';
			next_micro_state <= int1;
			set(update_ld) <= '1';
			setstate <= "10";
			-- BUG #18: Set interrupt mode for proper ISP selection (68020+)
			interrupt_mode <= '1';
		END IF;
			
		-- BUG #18: Stack pointer switching on mode changes (68020/68030)
		IF set(changeMode)='1' THEN
			IF cpu(1)='1' THEN
				-- 68020/68030: Use MSP/ISP based on M bit and interrupt_mode
				IF preSVmode='0' THEN
					-- Currently in user mode, switching to supervisor mode
					set(to_USP) <= '1';
					IF interrupt_mode='1' THEN
						set(from_ISP) <= '1';   -- Interrupts: always ISP
					ELSIF FlagsSR(4)='1' THEN
						set(from_MSP) <= '1';   -- Non-interrupt, M=1: MSP
					ELSE
						set(from_ISP) <= '1';   -- Non-interrupt, M=0: ISP
					END IF;
				ELSE
					-- Currently in supervisor mode, switching to user mode
					-- BUG #167 FIX: Save A7 to BOTH MSP and ISP
					-- After reset, ISP=0 because the initial A7 value was never synced.
					-- When switching to user mode, save current A7 to both shadow registers
					-- so that future interrupt (uses ISP) and RTE (uses MSP) both work correctly.
					set(to_ISP) <= '1';
					set(to_MSP) <= '1';
					set(from_USP) <= '1';
				END IF;
			ELSE
				-- 68000/68010: Simple USP/SSP switching
				set(to_USP) <= '1';
				set(from_USP) <= '1';
			END IF;
			setstackaddr <='1';
		END IF;

		IF ea_only='0' AND set(get_ea_now)='1' THEN
			setstate <= "10";
--			set_recall_last <= '1';
--			set(update_ld) <= '0';
		END IF;

		IF setstate(1)='1' AND set_datatype(1)='1' THEN
			set(longaktion) <= '1';
		END IF;

		-- BUG #22 FIX: Removed early EA building for PMMU instructions
		-- PMMU instructions must decode extension word FIRST in pmove_decode, then build EA
		-- Early EA building caused duplicate EA operation and extra PC increment
		-- (Removed lines that set ea_build_now for PMMU instructions)

		IF (ea_build_now='1' AND decodeOPC='1') OR exec(ea_build)='1' THEN
			-- BUG #228 FIX: For PMOVE with exec(ea_build)='1', the live opcode may have been
			-- prefetched to the next instruction. We must use fline_opcode_latch for EA mode.
			-- Handle PMOVE displacement modes specially BEFORE the CASE to ensure correct state transition.
			-- CRITICAL: Do NOT set setstate="01" here! pmove_decode already set it for the
			-- displacement fetch. Let the default setstate="00" take effect so that
			-- last_data_read gets updated with the displacement.
			-- BUG #228 FIX V2: Also check set(ea_build)='1'! For PMOVE memory EA modes,
			-- clkena_lw='0' (memmask="100111"), so exec(ea_build) is NOT updated from set(ea_build).
			-- Without this, the EA builder never fires and next_micro_state stays at idle.
			IF (exec(ea_build)='1' OR set(ea_build)='1') AND fline_context_valid='1' AND fline_is_pmmu='1' AND
			   fline_opcode_latch(5 downto 3)="101" THEN
				-- PMOVE with (d16,An) mode - use fline_opcode_latch for EA mode
				next_micro_state <= ld_dAn1;
				-- NOTE: setstate defaults to "00" which is correct for displacement processing
			ELSIF (exec(ea_build)='1' OR set(ea_build)='1') AND fline_context_valid='1' AND fline_is_pmmu='1' AND
			   fline_opcode_latch(5 downto 3)="110" THEN
				-- PMOVE with (d8,An,Xn) mode - use fline_opcode_latch for EA mode
				-- NOTE: Do NOT set getbrief here. The brief is latched directly from
				-- last_opc_read in the clocked process (pmmu_ld_AnXn1 brief latch).
				next_micro_state <= ld_AnXn1;
			ELSE
			CASE opcode(5 downto 3) IS		--source
				WHEN "010"|"011"|"100" =>						-- -(An)+
					set(get_ea_now) <='1';
					-- BUG #54/#212 UNIFIED FIX: Centralized PMMU detection in EA builder
					-- Regular instructions: ea_build_now='1' fires during decode (correct timing)
					-- PMOVE: exec(ea_build)='1' fires after extension fetch, suppress setnextpass
					-- CAS/CHK2/DIVUL/MULS: exec(ea_build)='1' but NOT PMMU, allow setnextpass
					IF ea_build_now='1' AND decodeOPC='1' THEN
						setnextpass <= '1';  -- Regular instructions (immediate EA build)
					ELSIF exec(ea_build)='1' AND NOT (fline_context_valid='1' AND fline_is_pmmu='1') THEN
						setnextpass <= '1';  -- Non-PMMU deferred EA (CAS/CHK2/DIVUL/MULS/future FPU)
					END IF;
					IF opcode(3)='1' THEN	--(An)+
						-- BUG #290 FIX: Suppress postadd for 64-bit PMMU registers (CRP/SRP)
						-- For CRP/SRP (64-bit), the postadd with pmmu_dbl happens in pmove_mmu_to_mem_lo
						-- and pmove_mem_to_mmu_lo states, not here. Setting it here would cause
						-- a premature +4 increment during the HI state.
						IF NOT (fline_context_valid='1' AND fline_is_pmmu='1' AND
						        (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011")) THEN
							set(postadd) <= '1';
						END IF;
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;	 	
					IF opcode(5)='1' THEN	-- -(An)
							set(presub) <= '1';
							IF opcode(2 downto 0)="111" THEN
								set(use_SP) <= '1';
						END IF;
					END IF;	 	
				WHEN "101" =>				--(d16,An)
					next_micro_state <= ld_dAn1;
					-- BUG #228 FIX: Do NOT set setstate="01" for PMOVE!
					-- pmove_decode already set setstate="01" for the displacement fetch cycle.
					-- The default setstate="00" here is correct - it allows last_data_read to
					-- be updated with the displacement value before ld_dAn1 uses it.
				WHEN "110" =>				--(d8,An,Xn)
					next_micro_state <= ld_AnXn1;
					getbrief <='1';
				WHEN "111" =>
					CASE opcode(2 downto 0) IS
						WHEN "000" =>				--(xxxx).w
							next_micro_state <= ld_nn;
						WHEN "001" =>				--(xxxx).l
							set(longaktion) <= '1';
							next_micro_state <= ld_nn;
						WHEN "010" =>				--(d16,PC)
							next_micro_state <= ld_dAn1;
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "011" =>				--(d8,PC,Xn)
							next_micro_state <= ld_AnXn1;
							getbrief <= '1';
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "100" =>				--#data
							setnextpass <= '1';
							set_direct_data <= '1';
							IF datatype="10" THEN
								set(longaktion) <= '1';
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				WHEN OTHERS => NULL;
			END CASE;
			END IF;  -- BUG #227: Close the IF for PMOVE (d16,An) special handling
		END IF;
------------------------------------------------------------------------------
--prepare opcode
------------------------------------------------------------------------------
		CASE opcode(15 downto 12) IS
-- 0000 ----------------------------------------------------------------------------
			WHEN "0000" =>
			IF opcode(8)='1' AND opcode(5 downto 3)="001" THEN --movep
				datatype <= "00";				--Byte
				set(use_SP) <= '1';		--addr+2
				set(no_Flags) <='1';
				IF opcode(7)='0' THEN  --to register
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVE) <= '1';
					set(movepl) <= '1';
				END IF;
				IF decodeOPC='1' THEN
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						set_direct_data <= '1';		-- to register
					END IF;
					next_micro_state <= movep1;
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <='1';
				END IF;
			ELSE
				IF opcode(8)='1' OR opcode(11 downto 9)="100" THEN		--Bits
					IF opcode(5 downto 3)/="001" AND --ea An illegal mode
					   (opcode(8 downto 3)/="000111" OR opcode(2)='0') AND --BTST bit number static illegal modes
					   (opcode(8 downto 2)/="1001111" OR opcode(1 downto 0)="00") AND --BTST bit number dynamic illegal modes
					   (opcode(7 downto 6)="00" OR opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --BCHG, BCLR, BSET illegal modes
						set_exec(opcBITS) <= '1';
						set_exec(ea_data_OP1) <= '1';
						IF opcode(7 downto 6)/="00" THEN
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							write_back <= '1';
						END IF;
						IF opcode(5 downto 4)="00" THEN
							datatype <= "10";			--Long
						ELSE
							datatype <= "00";			--Byte
						END IF;
						IF opcode(8)='0' THEN
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
						ELSE
							ea_build_now <= '1';
						END IF;
                ELSE
                    trap_illegal <= '1';
                    trapmake <= '1';
                END IF;
				ELSIF opcode(8 downto 6)="011" THEN			--CAS/CAS2/CMP2/CHK2
					IF cpu(1)='1' THEN
						IF opcode(11)='1' THEN					--CAS/CAS2
							IF (opcode(10 downto 9)/="00" AND --CAS illegal size
							   opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) OR --ea illegal modes
							   (opcode(10)='1' AND opcode(5 downto 0)="111100") THEN --CAS2
								CASE opcode(10 downto 9) IS
									WHEN "01" => datatype <= "00";		--Byte
									WHEN "10" => datatype <= "01";		--Word
									WHEN OTHERS => datatype <= "10";	--Long
								END CASE;
								IF opcode(10)='1' AND opcode(5 downto 0)="111100" THEN --CAS2
									IF decodeOPC='1' THEN
										set(get_2ndOPC) <= '1';
										next_micro_state <= cas21;
									END IF;
								ELSE											--CAS
									IF decodeOPC='1' THEN
										next_micro_state <= nop;
										set(get_2ndOPC) <= '1';
										set(ea_build) <= '1';
									END IF;
									-- BUG #212 REMOVED: Workaround no longer needed with centralized PMMU detection
									-- Centralized fix at line 2400 handles (An) mode for all deferred EA instructions
									IF micro_state=idle AND nextpass='1' THEN
										source_2ndLbits <= '1';
										set(ea_data_OP1) <= '1';
										set(addsub) <= '1';
										set(alu_exec) <= '1';
										set(alu_setFlags) <= '1';
										setstate <= "01";
										next_micro_state <= cas1;
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE				--CMP2/CHK2
							IF opcode(10 downto 9)/="11" AND --illegal size
							   opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal modes
								set(trap_chk) <= '1';
								datatype <= opcode(10 downto 9);
								IF decodeOPC='1' THEN
									next_micro_state <= nop;
									set(get_2ndOPC) <= '1';
									set(ea_build) <= '1';
								END IF;
								IF set(get_ea_now)='1' THEN
									set(mem_addsub) <= '1';
									set(OP1addr) <= '1';
								END IF;
								-- BUG #212 REMOVED: Workaround no longer needed with centralized PMMU detection
								-- Centralized fix at line 2400 handles (An) mode for all deferred EA instructions
								IF micro_state=idle AND nextpass='1' THEN
									setstate <= "10";
									set(hold_OP2) <='1';
									IF exe_datatype/="00" THEN
										check_aligned <='1';
									END IF;
									next_micro_state <= chk20;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(11 downto 8)="1110" AND opcode(7 downto 6)/="11" THEN		--MOVES (68010+)
					-- BUG #142 FIX: MOVES opcode is 0000 1110 ss mm mrrr
					-- Was checking for "1101" (wrong!) and size="11" (invalid!)
					-- Correct: bits 11:8 = 1110 ($E), size = 00/01/10 (byte/word/long)
					-- Privileged instruction - uses SFC/DFC for memory access
					-- BUG FIX: Check cpu(0) OR cpu(1) for 68010+ detection (68030 has cpu(1)='1')
					IF cpu(0)='1' OR cpu(1)='1' THEN  -- 68010+ (including 68030)
						-- Valid EA modes: all except immediate (111/100), PC-relative (111/010,011), and An direct (001)
						IF opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
							IF SVmode='1' THEN
								datatype <= opcode(7 downto 6);
								-- BUG #149 FIX: Set source_lowbits to select EA register from opcode(2:0)
								-- For (An) modes, we also need source_areg='1' to select address registers
								source_lowbits <= '1';
								IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
									source_areg <= '1';  -- (An), (An)+, -(An) modes use address register
								END IF;
								IF decodeOPC='1' THEN
									next_micro_state <= moves0;  -- BUG #149: Go to moves0 first to set up address
									getbrief <='1';
								END IF;
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(11 downto 9)="111" THEN		--other 0000111x instructions
					trap_illegal <= '1';
					trapmake <= '1';
				ELSE								--andi, ...xxxi
					IF opcode(7 downto 6)/="11" AND opcode(5 downto 3)/="001" THEN --ea An illegal mode
						IF opcode(11 downto 9)="000" THEN	--ORI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="001" THEN	--ANDI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcAND) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="010" OR opcode(11 downto 9)="011" THEN	--SUBI, ADDI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN
								set_exec(opcADD) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="101" THEN	--EORI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="110" THEN	--CMPI
							IF opcode(5 downto 3)/="111" OR opcode(2)='0' THEN
								set_exec(opcCMP) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF (set_exec(opcor) OR set_exec(opcand) OR set_exec(opcADD) OR set_exec(opcEor) OR set_exec(opcCMP))='1' THEN
							IF opcode(7)='0' AND opcode(5 downto 0)="111100" AND (set_exec(opcAND) OR set_exec(opcOR) OR set_exec(opcEOR))='1' THEN		--SR
								IF decodeOPC='1' AND SVmode='0' AND opcode(6)='1' THEN  --SR
									trap_priv <= '1';
									trapmake <= '1';
								ELSE
									set(no_Flags) <= '1';
									IF decodeOPC='1' THEN
										IF opcode(6)='1' THEN
											set(to_SR) <= '1';
										END IF;
										set(to_CCR) <= '1';
										set(andiSR) <= set_exec(opcAND);
										set(eoriSR) <= set_exec(opcEOR);
										set(oriSR) <= set_exec(opcOR);
										setstate <= "01";
										next_micro_state <= nopnop;
									END IF;
								END IF;
							ELSIF opcode(7)='0' OR opcode(5 downto 0)/="111100" OR (set_exec(opcand) OR set_exec(opcor) OR set_exec(opcEor))='0' THEN
								IF decodeOPC='1' THEN
									next_micro_state <= andi;
									set(get_2ndOPC) <='1';
									set(ea_build) <= '1';
									set_direct_data <= '1';
									IF datatype="10" THEN
										set(longaktion) <= '1';
									END IF;
								END IF;
								IF opcode(5 downto 4)/="00" THEN
									set_exec(ea_data_OP1) <= '1';
								END IF;
								IF opcode(11 downto 9)/="110" THEN	--CMPI
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									write_back <= '1';
								END IF;
								IF opcode(10 downto 9)="10" THEN	--CMPI, SUBI
									set(addsub) <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
			END IF;
				
-- 0001, 0010, 0011 -----------------------------------------------------------------
			WHEN "0001"|"0010"|"0011" =>				--move.b, move.l, move.w
				IF ((opcode(11 downto 10)="00" OR opcode(8 downto 6)/="111") AND --illegal dest ea
				   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND --illegal src ea
				   (opcode(13)='1' OR (opcode(8 downto 6)/="001" AND opcode(5 downto 3)/="001"))) THEN --byte src address reg direct, byte movea
					set_exec(opcMOVE) <= '1';
					ea_build_now <= '1';
					IF opcode(8 downto 6)="001" THEN
						set(no_Flags) <= '1';
					END IF;
					IF opcode(5 downto 4)="00" THEN	--Dn, An
						IF opcode(8 downto 7)="00" THEN
							set_exec(Regwrena) <= '1';
						END IF;
					END IF;
					CASE opcode(13 downto 12) IS
						WHEN "01" => datatype <= "00";		--Byte
						WHEN "10" => datatype <= "10";		--Long
						WHEN OTHERS => datatype <= "01";	--Word
					END CASE;
					source_lowbits <= '1';					-- Dn=>  An=>
					IF opcode(3)='1' THEN
						source_areg <= '1';
					END IF;

					IF nextpass='1' OR opcode(5 downto 4)="00" THEN
						dest_hbits <= '1';
						IF opcode(8 downto 6)/="000" THEN
							dest_areg <= '1';
						END IF;
					END IF;

					IF micro_state=idle AND (nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1')) THEN
						CASE opcode(8 downto 6) IS		--destination
							WHEN "000"|"001" =>						--Dn,An
									set_exec(Regwrena) <= '1';
							WHEN "010"|"011"|"100" =>					--destination -(an)+
								IF opcode(6)='1' THEN	--(An)+
									set(postadd) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								IF opcode(8)='1' THEN	-- -(An)
									set(presub) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								setstate <= "11";
								next_micro_state <= nop;
								IF nextpass='0' THEN
									set(write_reg) <= '1';
								END IF;
								IF ea_build_now='1' AND decodeOPC='1' THEN
									setnextpass <= '1';
								END IF;
							WHEN "101" =>				--(d16,An)
								next_micro_state <= st_dAn1;
--								getbrief <= '1';
							WHEN "110" =>				--(d8,An,Xn)
								next_micro_state <= st_AnXn1;
								getbrief <= '1';
							WHEN "111" =>
								CASE opcode(11 downto 9) IS
									WHEN "000" =>				--(xxxx).w
										next_micro_state <= st_nn;
									WHEN "001" =>				--(xxxx).l
										set(longaktion) <= '1';
										next_micro_state <= st_nn;
									WHEN OTHERS => NULL;
								END CASE;
							WHEN OTHERS => NULL;
						END CASE;
					END IF;
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;
---- 0100 ----------------------------------------------------------------------------		
			WHEN "0100" =>				--rts_group
				IF opcode(8)='1' THEN		--lea, extb.l, chk
					IF opcode(6)='1' THEN		--lea, extb.l
						IF opcode(11 downto 9)="100" AND opcode(5 downto 3)="000" THEN --extb.l
							IF opcode(7)='1' AND cpu(1)='1' THEN
								source_lowbits <= '1';
								set_exec(opcEXT) <= '1';
								set_exec(opcEXTB) <= '1';
								set_exec(opcMOVE) <= '1';
								set_exec(Regwrena) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF opcode(7)='1' AND
							   (opcode(5)='1' OR opcode(4 downto 3)="10") AND
							   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal opcodes
								source_lowbits <= '1';
								source_areg <= '1';
								ea_only <= '1';
								set_exec(Regwrena) <= '1';
								set_exec(opcMOVE) <='1';
								set(no_Flags) <='1';
								IF opcode(5 downto 3)="010" THEN  	--lea (Am),An
									dest_areg <= '1';
									dest_hbits <= '1';
								ELSE
									ea_build_now <= '1';
								END IF;	
								IF set(get_ea_now)='1' THEN
									setstate <= "01";
									set_direct_data <= '1';
								END IF;
								IF setexecOPC='1' THEN
									dest_areg <= '1';
									dest_hbits <= '1';
								END IF;
							ELSE
								trap_illegal <='1';
								trapmake <='1';
							END IF;
						END IF;
					ELSE								--chk
						IF opcode(5 downto 3)/="001" AND --ea An illegal mode
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
							IF opcode(7)='1' THEN
								datatype <= "01";	--Word
								set(trap_chk) <= '1';
								IF (c_out(1)='0' OR OP1out(15)='1' OR OP2out(15)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSIF cpu(1)='1' THEN   --chk long for 68020
								datatype <= "10";	--Long
								set(trap_chk) <= '1';
								IF (c_out(2)='0' OR OP1out(31)='1' OR OP2out(31)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';		-- chk long for 68020
								trapmake <= '1';
							END IF;
							IF opcode(7)='1' OR cpu(1)='1' THEN
								IF (nextpass='1' OR opcode(5 downto 4)="00") AND exec(opcCHK)='0' AND micro_state=idle THEN
									set_exec(opcCHK) <= '1';
								END IF;
								ea_build_now <= '1';
								set(addsub) <= '1';
								IF setexecOPC='1' THEN
									dest_hbits <= '1';
									source_lowbits <='1';
								END IF;
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE
					CASE opcode(11 downto 9) IS
						WHEN "000"=>
							IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
								IF opcode(7 downto 6)="11" THEN					--move from SR
									-- BUG FIX: Check both cpu(0) and cpu(1) for 68000 detection
									-- Only 68000 (cpu="00") allows user mode MOVE from SR
									-- 68010+ (cpu(0)='1') and 68030 (cpu(1)='1') require supervisor mode
									IF SR_Read=0 OR (cpu(0)='0' AND cpu(1)='0' AND SR_Read=2) OR SVmode='1'  THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';							-- im 68000 wird auch erst gelesen
										-- BUG FIX: Check cpu(0) OR cpu(1) for 68010+ optimization
										IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
											skipFetch <= '1';
										END IF;
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE									--negx
									ea_build_now <= '1';
									set_exec(use_XZFlag) <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "001"=>
							IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
								IF opcode(7 downto 6)="11" THEN					--move from CCR 68010
									-- BUG FIX: Check cpu(0) OR cpu(1) for 68010+ detection (68030 has cpu(1)='1')
									IF SR_Read=1 OR ((cpu(0)='1' OR cpu(1)='1') AND SR_Read=2) THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';							-- im 68000 wird auch erst gelesen
--										IF state="10" THEN
--											skipFetch <= '1';
--										END IF;
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								ELSE											--clr
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcAND) <= '1';
									-- BUG FIX: Check cpu(0) OR cpu(1) for 68010+ optimization
									IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
										skipFetch <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "010"=>
							IF opcode(7 downto 6)="11" THEN					--move to CCR
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
									ea_build_now <= '1';
									datatype <= "01";
									source_lowbits <= '1';
									IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
										set(to_CCR) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE											--neg
								IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "011"=>										--not, move toSR
							IF opcode(7 downto 6)="11" THEN					--move to SR
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
									IF SVmode='1' THEN
										ea_build_now <= '1';
										datatype <= "01";
										source_lowbits <= '1';
										IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											set(to_SR) <= '1';
											set(to_CCR) <= '1';
										END IF;
										IF exec(to_SR)='1' OR (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											setstate <="01";
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE											--not
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcEOR) <= '1';
									set_exec(ea_data_OP1) <= '1';
									IF opcode(5 downto 3)="000" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP2out_one) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "100"|"110"=>
							IF opcode(7)='1' THEN			--movem, ext
								IF opcode(5 downto 3)="000" AND opcode(10)='0' THEN		--ext
									source_lowbits <= '1';
									set_exec(opcEXT) <= '1';
									set_exec(opcMOVE) <= '1';
									set_exec(Regwrena) <= '1';	
									IF opcode(6)='0' THEN
										datatype <= "01";		--WORD
										set_exec(opcEXTB) <= '1';
									END IF;
								ELSE													--movem
--								IF opcode(11 downto 7)="10001" OR opcode(11 downto 7)="11001" THEN	--MOVEM
									IF (opcode(10)='1' OR ((opcode(5)='1' OR opcode(4 downto 3)="10") AND
									   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND
									   (opcode(10)='0' OR (opcode(5 downto 4)/="00" AND
									   opcode(5 downto 3)/="100" AND
									   opcode(5 downto 2)/="1111")) THEN --ea illegal modes
										ea_only <= '1';
										set(no_Flags) <= '1';
										IF opcode(6)='0' THEN
											datatype <= "01";		--Word transfer
										END IF;
										IF (opcode(5 downto 3)="100" OR opcode(5 downto 3)="011") AND state="01" THEN	-- -(An), (An)+
											set_exec(save_memaddr) <= '1';
											set_exec(Regwrena) <= '1';
										END IF;
										IF opcode(5 downto 3)="100" THEN	-- -(An)
											movem_presub <= '1';
											set(subidx) <= '1';
										END IF;
										IF state="10" AND addrvalue='0' THEN
											set(Regwrena) <= '1';
											set(opcMOVE) <= '1';
										END IF;
										IF decodeOPC='1' THEN
											set(get_2ndOPC) <='1';
											IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
												next_micro_state <= movem1;
											ELSE
												next_micro_state <= nop;
												set(ea_build) <= '1';
											END IF;
										END IF;
										IF set(get_ea_now)='1' THEN
											IF movem_run='1' THEN
												set(movem_action) <= '1';
												IF opcode(10)='0' THEN
													setstate <="11";
													set(write_reg) <= '1';
												ELSE
													setstate <="10";
												END IF;
												next_micro_state <= movem2;
												set(mem_addsub) <= '1';
											ELSE
												setstate <="01";
											END IF;
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								END IF;	
							ELSE
								IF opcode(10)='1' THEN						--MUL.L, DIV.L 68020
	 --FPGA Multiplier for long
									IF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND--ea An illegal mode
									   MUL_Hardware=1 AND (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2))) THEN
										IF decodeOPC='1' THEN
											next_micro_state <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										-- BUG #212 REMOVED: (An) workaround no longer needed with centralized PMMU detection
										-- Original: (opcode(5 downto 4)="00" ...) handles Dn mode
										-- Centralized fix at line 2400 handles (An) mode for all deferred EA instructions
										IF (micro_state=idle AND nextpass='1') OR
										   (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
											dest_2ndHbits <= '1';
											datatype <= "10";
											set(opcMULU) <= '1';
											set(write_lowlong) <= '1';
											IF sndOPC(10)='1' THEN
												setstate <="01";
												next_micro_state <= mul_end2;
											END IF;
											set(Regwrena) <= '1';
										END IF;
										source_lowbits <='1';
										datatype <= "10";

	 --no FPGA Multiplier
									ELSIF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND --ea An illegal mode
									   ((opcode(6)='1' AND (DIV_Mode=1 OR (cpu(1)='1' AND DIV_Mode=2))) OR
									   (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2)))) THEN
										IF decodeOPC='1' THEN
											next_micro_state <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										-- BUG #212 REMOVED: (An) workaround no longer needed with centralized PMMU detection
										-- Original: (opcode(5 downto 4)="00" ...) handles Dn mode
										-- Centralized fix at line 2400 handles (An) mode for all deferred EA instructions
										IF (micro_state=idle AND nextpass='1') OR
										   (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
											setstate <="01";
											dest_2ndHbits <= '1';
											source_2ndLbits <= '1';
											IF opcode(6)='1' THEN
												next_micro_state <= div1;
											ELSE
												next_micro_state <= mul1;
												set(ld_rot_cnt) <= '1';
											END IF;
										END IF;
										source_lowbits <='1';
										IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN	
											dest_hbits <= '1';
										END IF;
										datatype <= "10";
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
					
								ELSE							--pea, swap
									IF opcode(6)='1' THEN
										datatype <= "10";
										IF opcode(5 downto 3)="000" THEN 		--swap
											set_exec(opcSWAP) <= '1';
											set_exec(Regwrena) <= '1';	
										ELSIF opcode(5 downto 3)="001" THEN 		--bkpt
											trap_illegal <= '1';
											trapmake <= '1';
										ELSE									--pea
											IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
											   opcode(5 downto 3)/="100" AND
											   opcode(5 downto 2)/="1111" THEN --ea illegal modes
												ea_only <= '1';
												ea_build_now <= '1';
												IF nextpass='1' AND micro_state=idle THEN
													set(presub) <= '1';
													setstackaddr <='1';
													setstate <="11";
													next_micro_state <= nop;
												END IF;
												IF set(get_ea_now)='1' THEN
													setstate <="01";
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;
									ELSE
										IF opcode(5 downto 3)="001" THEN --link.l
											datatype <= "10";
											set_exec(opcADD) <= '1';						--for displacement
											set_exec(Regwrena) <= '1';
											set(no_Flags) <= '1';
											IF decodeOPC='1' THEN
												set(linksp) <= '1';
												set(longaktion) <= '1';
												next_micro_state <= link1;
												set(presub) <= '1';
												setstackaddr <='1';
												set(mem_addsub) <= '1';
												source_lowbits <= '1';
												source_areg <= '1';
												set(store_ea_data) <= '1';
											END IF;
										ELSE						--nbcd
											IF opcode(5 downto 3)/="001" AND --ea An illegal mode
											   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
												ea_build_now <= '1';
												set_exec(use_XZFlag) <= '1';
												write_back <='1';
												set_exec(opcADD) <= '1';
												set_exec(opcSBCD) <= '1';
												set(addsub) <= '1';
												source_lowbits <= '1';
												IF opcode(5 downto 4)="00" THEN
													set_exec(Regwrena) <= '1';
												END IF;
												IF setexecOPC='1' THEN
													set(OP1out_zero) <= '1';
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;	
									END IF;
								END IF;
							END IF;
--0x4AXX							
						WHEN "101"=>						--tst, tas  4aFC - illegal
--							IF opcode(7 downto 2)="111111" THEN   --illegal
							IF opcode(7 downto 3)="11111" AND opcode(2 downto 1)/="00" THEN   --0x4AFC illegal  --0x4AFB BKP Sinclair QL
								trap_illegal <= '1';
								trapmake <= '1';
							ELSE
								IF (opcode(7 downto 6)/="11" OR --tas
								   (opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND --ea illegal modes
								   ((opcode(7 downto 6)/="00" OR (opcode(5 downto 3)/="001")) AND
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) THEN
									ea_build_now <= '1';
									IF setexecOPC='1' THEN
										source_lowbits <= '1';
										IF opcode(3)='1' THEN			--MC68020...
											source_areg <= '1';
										END IF;
									END IF;
									set_exec(opcMOVE) <= '1';
									IF opcode(7 downto 6)="11" THEN		--tas
										set_exec_tas <= '1';
										write_back <= '1';
										datatype <= "00";				--Byte
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
----						WHEN "110"=>
						WHEN "111"=>					--4EXX
--
--											ea_only <= '1';
--											ea_build_now <= '1';
--											IF nextpass='1' AND micro_state=idle THEN
--												set(presub) <= '1';
--												setstackaddr <='1';
--												set(mem_addsub) <= '1';
--												setstate <="11";
--												next_micro_state <= nop;
--											END IF;
--											IF set(get_ea_now)='1' THEN
--												setstate <="01";
--											END IF;
--								
								
								
								
							-- BUG #318 FIX: Exclude MOVES from JMP/JSR path
							-- MOVES has opcode(7)='1' but it's NOT a JMP/JSR! During MOVES execution,
							-- opcode gets overwritten with extension word, so we can't check opcode bits.
							-- Instead, check micro_state - if in moves0/moves1, it's MOVES not JMP/JSR
							IF opcode(7)='1' AND micro_state /= moves0 AND micro_state /= moves1 THEN		--jsr, jmp (but NOT MOVES)
								IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
								   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal modes
									datatype <= "10";
									ea_only <= '1';
									ea_build_now <= '1';
									IF exec(ea_to_pc)='1' THEN
										next_micro_state <= nop;
									END IF;
									IF nextpass='1' AND micro_state=idle AND opcode(6)='0' THEN
										set(presub) <= '1';
										setstackaddr <='1';
										setstate <="11";
										next_micro_state <= nopnop;
									END IF;
								
									IF micro_state=ld_AnXn1 AND brief(8)='0'THEN			--JMP/JSR n(Ax,Dn)
										skipFetch <= '1';
									END IF;
									IF state="00" THEN
										writePC <= '1';
									END IF;
									set(hold_dwr) <= '1';
									IF set(get_ea_now)='1' THEN					--jsr
										IF exec(longaktion)='0' OR long_done='1' THEN
											skipFetch <= '1';
										END IF;
										setstate <="01";
										set(ea_to_pc) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE						--
								CASE opcode(6 downto 0) IS
									WHEN "1000000"|"1000001"|"1000010"|"1000011"|"1000100"|"1000101"|"1000110"|"1000111"|		--trap
									     "1001000"|"1001001"|"1001010"|"1001011"|"1001100"|"1001101"|"1001110"|"1001111" =>		--trap
											trap_trap <='1';
											trapmake <= '1';
									
									WHEN "1010000"|"1010001"|"1010010"|"1010011"|"1010100"|"1010101"|"1010110"|"1010111"=> 		--link word
										datatype <= "10";
										set_exec(opcADD) <= '1';						--for displacement
										set_exec(Regwrena) <= '1';
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											next_micro_state <= link1;
											set(presub) <= '1';
											setstackaddr <='1';
											set(mem_addsub) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											set(store_ea_data) <= '1';
										END IF;
									
									WHEN "1011000"|"1011001"|"1011010"|"1011011"|"1011100"|"1011101"|"1011110"|"1011111" =>		--unlink
										datatype <= "10";
										set_exec(Regwrena) <= '1';
										set_exec(opcMOVE) <= '1';						
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											setstate <= "01";
											next_micro_state <= unlink1;
											set(opcMOVE) <= '1';
											set(Regwrena) <= '1';
											setstackaddr <='1';
											source_lowbits <= '1';
											source_areg <= '1';
										END IF;
									
									WHEN "1100000"|"1100001"|"1100010"|"1100011"|"1100100"|"1100101"|"1100110"|"1100111" =>		--move An,USP
										IF SVmode='1' THEN
--											set(no_Flags) <= '1';
											set(to_USP) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											datatype <= "10";
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
									
									WHEN "1101000"|"1101001"|"1101010"|"1101011"|"1101100"|"1101101"|"1101110"|"1101111" =>		--move USP,An
										IF SVmode='1' THEN
--											set(no_Flags) <= '1';
											set(from_USP) <= '1';
											datatype <= "10";
											set_exec(Regwrena) <= '1';
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
									
									WHEN "1110000" =>					--reset
										IF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											set(opcRESET) <= '1';
											IF decodeOPC='1' THEN
												set(ld_rot_cnt) <= '1'; 
												set_rot_cnt <= "000000";
											END IF;
										END IF;
										
									WHEN "1110001" =>					--nop
									
									WHEN "1110010" =>					--stop
										IF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											IF decodeOPC='1' THEN
												setnextpass <= '1';
												set_stop <= '1';	
											END IF;
											IF stop='1' THEN
												skipFetch <= '1';
											END IF;		
											
										END IF;
									
									WHEN "1110011"|"1110111" =>  									--rte/rtr
										IF SVmode='1' OR opcode(2)='1' THEN
											IF decodeOPC='1' THEN
												setstate <= "10";
												set(postadd) <= '1';
												setstackaddr <= '1';
												IF opcode(2)='1' THEN
													set(directCCR) <= '1';
												ELSE
													set(directSR) <= '1';
												END IF;
												next_micro_state <= rte1;
											END IF;
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
										
									WHEN "1110100" =>  									--rtd
										datatype <= "10";
										IF decodeOPC='1' THEN
											setstate <= "10";
											set(postadd) <= '1';
											setstackaddr <= '1';
											set(direct_delta) <= '1';
											set(directPC) <= '1';
											set_direct_data <= '1';
											next_micro_state <= rtd1;
										END IF;
										
										
									WHEN "1110101" =>  									--rts
										datatype <= "10";
										IF decodeOPC='1' THEN
											setstate <= "10";
											set(postadd) <= '1';
											setstackaddr <= '1';
											set(direct_delta) <= '1';	
											set(directPC) <= '1';
											next_micro_state <= nopnop;
										END IF;
										
									WHEN "1110110" =>  									--trapv
										IF decodeOPC='1' THEN
											setstate <= "01";
										END IF;	
										IF Flags(1)='1' AND state="01" THEN
											trap_trapv <= '1';
											trapmake <= '1';
										END IF;
										
									WHEN "1111000" =>  									--CINV/CPUSH (68040+ only, NOT 68030)
										-- MC68030 does not support CINV/CPUSH instructions
										-- MC68030 uses CACR register bits (via MOVEC) for cache control:
										--   CI (bit 3) = Clear Instruction Cache
										--   CEI (bit 2) = Clear Entry in Instruction Cache
										--   CD (bit 11) = Clear Data Cache
										--   CED (bit 10) = Clear Entry in Data Cache
										-- CINV/CPUSH were introduced in MC68040
										trap_illegal <= '1';
										trapmake <= '1';
									
									WHEN "1111010"|"1111011" =>  									--movec
										IF cpu="00" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSIF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											datatype <= "10";	--Long
											-- BUG #193 FIX: Removed register selector decode from here!
											-- Using last_data_read before getbrief has loaded brief is WRONG
											-- This caused MOVEC to use stale data (BSET immediate $0003)
											-- Moved to movec1 state where brief is valid
											IF opcode(0)='0' THEN
												set_exec(movec_rd) <= '1';
											ELSE
												set_exec(movec_wr) <= '1';
											END IF;
											IF decodeOPC='1' THEN
												next_micro_state <= movec1;
												getbrief <='1';
												-- BUG #193 FIX: Set setnextpass to ensure PC increments before brief capture
												-- Without this, brief captures stale data from opcode fetch cycle
												-- causing extension word to be wrong (shows as NOP after BSET)
												setnextpass <= '1';
											END IF;
										END IF;
									
									WHEN OTHERS =>	
										trap_illegal <= '1';
										trapmake <= '1';
								END CASE;	
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				END IF;	
--					
---- 0101 ----------------------------------------------------------------------------
			WHEN "0101" => 								--subq, addq
					IF opcode(7 downto 6)="11" THEN --dbcc
						IF opcode(5 downto 3)="001" THEN --dbcc
							IF decodeOPC='1' THEN
								next_micro_state <= dbcc1;
								set(OP2out_one) <= '1';
								data_is_source <= '1';
							END IF;
						ELSIF opcode(5 downto 3)="111" AND (opcode(2 downto 1)="01" OR opcode(2 downto 0)="100") THEN	--trapcc
							IF cpu(1)='1' THEN							-- only 68020+
								IF opcode(2 downto 1)="01" THEN
									IF decodeOPC='1' THEN
										IF opcode(0)='1' THEN			--long
											set(longaktion) <= '1';
										END IF;
										next_micro_state <= nop;
									END IF;
								ELSE
									IF decodeOPC='1' THEN
										setstate <= "01";
									END IF;
								END IF;
								IF exe_condition='1' AND decodeOPC='0' THEN
									trap_trapv <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSIF (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --Scc
							datatype <= "00";			--Byte
							ea_build_now <= '1';
							write_back <= '1';
							set_exec(opcScc) <= '1';
							-- BUG FIX: Check cpu(0) OR cpu(1) for 68010+ optimization
							IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
								skipFetch <= '1';
							END IF;
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE					--addq, subq
						IF opcode(7 downto 3)/="00001" AND
						   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
							ea_build_now <= '1';
							IF opcode(5 downto 3)="001" THEN
								set(no_Flags) <= '1';
							END IF;
							IF opcode(8)='1' THEN
								set(addsub) <= '1';
							END IF;
							write_back <= '1';
							set_exec(opcADDQ) <= '1';
							set_exec(opcADD) <= '1';
							set_exec(ea_data_OP1) <= '1';
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
--				
---- 0110 ----------------------------------------------------------------------------		
			WHEN "0110" =>				--bra,bsr,bcc
				datatype <= "10";
				
				IF micro_state=idle THEN
					IF opcode(11 downto 8)="0001" THEN		--bsr
						set(presub) <= '1';
						setstackaddr <='1';
						IF opcode(7 downto 0)="11111111" THEN
							next_micro_state <= bsr2;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state <= bsr2;
						ELSE	
							next_micro_state <= bsr1;
							setstate <= "11";
							writePC <= '1';
						END IF;
					ELSE									--bra
						IF opcode(7 downto 0)="11111111" THEN
							next_micro_state <= bra1;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state <= bra1;
						ELSE
							setstate <= "01";
							next_micro_state <= bra1;
						END IF;
					END IF;
				END IF;	
				
-- 0111 ----------------------------------------------------------------------------		
			WHEN "0111" =>				--moveq
				IF opcode(8)='0' THEN
					datatype <= "10";		--Long
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVEQ) <= '1';
					set_exec(opcMOVE) <= '1';
					dest_hbits <= '1';
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;
				
---- 1000 ----------------------------------------------------------------------------		
			WHEN "1000" => 								--or	
				IF opcode(7 downto 6)="11" THEN	--divu, divs
					IF DIV_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
						IF opcode(5 downto 4)="00" THEN	--Dn, An
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							setstate <="01";
							next_micro_state <= div1;
						END IF;
						ea_build_now <= '1';
						IF z_error='0' AND set_V_Flag='0' THEN
							set_exec(Regwrena) <= '1';
						END IF;
							source_lowbits <='1';
						IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN	--sbcd, pack , unpack
					IF opcode(7 downto 6)="00" THEN	--sbcd
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcSBCD) <= '1';
						set(addsub) <= '1';
					ELSIF opcode(7 downto 6)="01" OR opcode(7 downto 6)="10" THEN	--pack , unpack
						set_exec(ea_data_OP1) <= '1';
						set(no_Flags) <= '1';
						source_lowbits <='1';
						IF opcode(7 downto 6) = "01" THEN	--pack
							set_exec(opcPACK) <= '1';
							datatype <= "01";				--Word
						ELSE								--unpk
							set_exec(opcUNPACK) <= '1';
							datatype <= "00";				--Byte
						END IF;
						IF opcode(3)='0' THEN
							IF opcode(7 downto 6) = "01" THEN	--pack
								set_datatype <= "00";		--Byte
							ELSE								--unpk
								set_datatype <= "01";		--Word
							END IF;
							set_exec(Regwrena) <= '1';
							dest_hbits <= '1';
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
--								set_direct_data <= '1';
								set(store_ea_packdata) <= '1';
								set(store_ea_data) <= '1';
							END IF;
						ELSE				-- pack -(Ax),-(Ay)
							write_back <= '1';
							IF decodeOPC='1' THEN
								next_micro_state <= pack1;
								set_direct_data <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE									--or
					IF opcode(7 downto 6)/="11" AND --illegal opmode
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
						set_exec(opcOR) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
				
---- 1001, 1101 -----------------------------------------------------------------------		
			WHEN "1001"|"1101" => 						--sub, add
				IF opcode(8 downto 3)/="000001" AND --byte src address reg direct
				   (((opcode(8)='0' OR opcode(7 downto 6)="11") AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
				   (opcode(8)='1' AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
					set_exec(opcADD) <= '1';
					ea_build_now <= '1';
					IF opcode(14)='0' THEN
						set(addsub) <= '1';
					END IF;
					IF opcode(7 downto 6)="11" THEN	--	--adda, suba
						IF opcode(8)='0' THEN	--adda.w, suba.w
							datatype <= "01";	--Word
						END IF;
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF opcode(3)='1' THEN
							source_areg <= '1';
						END IF;
						set(no_Flags) <= '1';
						IF setexecOPC='1' THEN
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
					ELSE
						IF opcode(8)='1' AND opcode(5 downto 4)="00" THEN		--addx, subx
							build_bcd <= '1';
						ELSE							--sub, add
							build_logical <= '1';
						END IF;
					END IF;
				ELSE
						trap_illegal <= '1';
						trapmake <= '1';
				END IF;
--				
---- 1010 ----------------------------------------------------------------------------		
			WHEN "1010" => 							--Trap 1010
				trap_1010 <= '1';
				trapmake <= '1';
---- 1011 ----------------------------------------------------------------------------		
			WHEN "1011" => 							--eor, cmp
				IF opcode(7 downto 6)="11" THEN	--CMPA
					IF opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00" THEN --illegal src ea
						ea_build_now <= '1';
						IF opcode(8)='0' THEN	--cmpa.w
							datatype <= "01";	--Word
							set_exec(opcCPMAW) <= '1';
						END IF;
						set_exec(opcCMP) <= '1';
						IF setexecOPC='1' THEN
							source_lowbits <='1';
							IF opcode(3)='1' THEN
								source_areg <= '1';
							END IF;
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
						set(addsub) <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE	--cmpm, eor, cmp
					IF opcode(8)='1' THEN
						IF opcode(5 downto 3)="001" THEN		--cmpm
							ea_build_now <= '1';
							set_exec(opcCMP) <= '1';
							IF decodeOPC='1' THEN
								IF opcode(2 downto 0)="111" THEN
									set(use_SP) <= '1';
								END IF;
								setstate <= "10";
								set(update_ld) <= '1';
								set(postadd) <= '1';
								next_micro_state <= cmpm;
							END IF;
							set_exec(ea_data_OP1) <= '1';
							set(addsub) <= '1';
						ELSE						--EOR
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN --illegal dst ea
								ea_build_now <= '1';
								build_logical <= '1';
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE							--CMP
						IF opcode(8 downto 3)/="000001" AND --byte src address reg direct
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --illegal src ea
							ea_build_now <= '1';
							build_logical <= '1';
							set_exec(opcCMP) <= '1';
							set(addsub) <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				END IF;
--				
---- 1100 ----------------------------------------------------------------------------		
			WHEN "1100" => 								--and, exg
				IF opcode(7 downto 6)="11" THEN	--mulu, muls
					IF MUL_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
						IF opcode(5 downto 4)="00" THEN	--Dn, An
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN	
							IF MUL_Hardware=0 THEN
								setstate <="01";
								set(ld_rot_cnt) <= '1';
								next_micro_state <= mul1;
							ELSE
								set_exec(write_lowlong) <= '1';
								set_exec(opcMULU) <= '1';
							END IF;
						END IF;
						ea_build_now <= '1';
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF (nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
						IF setexecOPC='1' THEN
							datatype <= "10";
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN	--exg, abcd
					IF opcode(7 downto 6)="00" THEN	--abcd
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcABCD) <= '1';
					ELSE									--exg
						IF opcode(7 downto 4)="0100" OR opcode(7 downto 3)="10001" THEN
							datatype <= "10";
							set(Regwrena) <= '1';
							set(exg) <= '1';
							set(alu_move) <= '1';
							IF opcode(6)='1' AND opcode(3)='1' THEN
								dest_areg <= '1';
								source_areg <= '1';
							END IF;
							IF decodeOPC='1' THEN
								setstate <= "01";
							ELSE
								dest_hbits <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE									--and
					IF opcode(7 downto 6)/="11" AND --illegal opmode
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
						set_exec(opcAND) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
--				
---- 1110 ----------------------------------------------------------------------------		
			WHEN "1110" => 								--rotation / bitfield
				IF opcode(7 downto 6)="11" THEN
					IF opcode(11)='0' THEN
					   IF (opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
							IF BarrelShifter=0 THEN
								set_exec(opcROT) <= '1';
							ELSE
								set_exec(exec_BS) <='1';
							END IF;
							ea_build_now <= '1';
							datatype <= "01";
							set_rot_bits <= opcode(10 downto 9);
							set_exec(ea_data_OP1) <= '1';
							write_back <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE		--bitfield
						IF BitField=0 OR (cpu(1)='0' AND BitField=2) OR
						   ((opcode(10 downto 9)="11" OR opcode(10 downto 8)="010" OR opcode(10 downto 8)="100") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR (opcode(5 downto 3)="111" AND opcode(2 downto 1)/="00"))) OR
						   ((opcode(10 downto 9)="00" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR opcode(5 downto 2)="1111")) THEN
							trap_illegal <= '1';
							trapmake <= '1';
						ELSE
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
							set_exec(opcBF) <= '1';
--		000-bftst, 001-bfextu, 010-bfchg, 011-bfexts, 100-bfclr, 101-bfff0, 110-bfset, 111-bfins								
							IF opcode(10)='1' OR opcode(8)='0' THEN
								set_exec(opcBFwb) <= '1';			--'1' for tst,chg,clr,ffo,set,ins    --'0' for extu,exts
							END IF;
							IF opcode(10 downto 8)="111" THEN	--BFINS
								set_exec(ea_data_OP1) <= '1';
							END IF;
							IF opcode(10 downto 8)="010" OR opcode(10 downto 8)="100" OR opcode(10 downto 8)="110" OR opcode(10 downto 8)="111" THEN
								write_back <= '1';
							END IF;
							ea_only <= '1';
							IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							IF opcode(4 downto 3)="00" THEN
								IF opcode(10 downto 8)/="000" THEN
									set_exec(Regwrena) <= '1';
								END IF;
								IF exec(ea_build)='1' THEN
									dest_2ndHbits <= '1';
									source_2ndLbits <= '1';
									set(get_bfoffset) <='1';
									setstate <= "01";
								END IF;
							END IF;
							IF set(get_ea_now)='1' THEN
								setstate <= "01";
							END IF;
							IF exec(get_ea_now)='1' THEN
								dest_2ndHbits <= '1';
								source_2ndLbits <= '1';
								set(get_bfoffset) <='1';
								setstate <= "01";
								set(mem_addsub) <='1';
								next_micro_state <= bf1;
							END IF;
							IF setexecOPC='1' THEN
								IF opcode(10 downto 8)="111" THEN	--BFINS
									source_2ndHbits <= '1';
								ELSE
									source_lowbits <= '1';
								END IF;
								IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN	--BFEXT, BFFFO
									dest_2ndHbits <= '1';
								END IF;
							END IF;
						END IF;
					END IF;
				ELSE
					data_is_source <= '1';
					IF BarrelShifter=0 OR (cpu(1)='0' AND BarrelShifter=2) THEN
						set_exec(opcROT) <= '1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
						IF decodeOPC='1' THEN
							IF opcode(5)='1' THEN
								next_micro_state <= rota1;
								set(ld_rot_cnt) <= '1';
								setstate <= "01";
							ELSE
								set_rot_cnt(2 downto 0) <= opcode(11 downto 9);
								IF opcode(11 downto 9)="000" THEN
									set_rot_cnt(3) <='1';
								ELSE
									set_rot_cnt(3) <='0';
								END IF;
							END IF;
						END IF;
					ELSE
						set_exec(exec_BS) <='1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
					END IF;
				END IF;
--				
---- 1111 ----------------------------------------------------------------------------		
			WHEN "1111" =>
                -- PMMU (68030): Only specific PMMU instructions, not broad F000-F0FF range
                -- PMMU instructions: F000 (PMOVE), F010 (PFLUSH), F018 (PTEST), F028 (PLOAD)
                -- BUG FIX: Must handle PMMU instructions FIRST before falling through to cpSAVE/cpRESTORE
                -- The opcode check must be complete here, not relying on IF-ELSIF fallthrough
                --IF cpu="11" AND opcode(11 downto 8)="0000" THEN -- F000: PMOVE
                IF cpu(1)='1' AND opcode(11 downto 8)="0000" THEN -- F000-F0FF: All PMMU instructions
					-- BUG #209 FIX: PMMU instructions require supervisor mode
					IF SVmode='1' THEN
						-- Fetch extension word to determine PMMU instruction type
						IF decodeOPC='1' THEN
							set(get_2ndOPC) <= '1';
							-- BUG #366 FIX: For complex EA modes (d16, d8Xn, abs), keep setstate="00"
							-- so pmove_decode runs with bus active (state="00"), fetching the
							-- displacement/brief/address word. For simple modes (Dn, An, (An), (An)+,
							-- -(An)), set "01" to suppress fetch (no additional words needed).
							IF opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" OR opcode(5 downto 3) = "111" THEN
								null;  -- setstate stays "00" (default): fetch displacement/brief/address
							ELSE
								setstate <= "01";  -- Simple modes: suppress fetch (PC already at +4)
							END IF;
							getbrief <= '1';  -- FIX: Must load brief for PMMU instruction dispatch
							next_micro_state <= pmove_decode;
						-- BUG #150 FIX: Removed setstate <= "01" that was added for BUG #147.
						-- That fix broke PMOVE by preventing extension word fetch from completing.
						-- The extension word is fetched via get_2ndOPC and getbrief during
						-- the normal state="00" (instruction fetch) - forcing idle state breaks this.

						-- BUG #22 FIX: DO NOT build EA here! PMMU instructions build EA in pmove_decode
						-- after decoding the extension word. Early EA building causes duplicate
						-- EA operation which increments PC by 2 extra bytes (6 instead of 4).
						-- The ea_build in pmove_decode (line 4488) is the correct place for PMMU EA building.
						END IF;
					ELSE
						trap_priv <= '1';
						trapmake <= '1';
					END IF;
				--ELSIF cpu="11" AND opcode(8 downto 6)="100" THEN --cpSAVE
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="100" THEN --cpSAVE
					-- cpSAVE valid EA modes: control alterable or predecrement
					-- Valid: (An), -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
					-- Invalid: Dn, An, (An)+, #imm, (d16,PC), (d8,PC,Xn)
					IF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND
					   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
						-- Valid EA mode for cpSAVE - this is a PRIVILEGED instruction
						IF SVmode='1' THEN
							-- Supervisor mode without FPU: F-line exception
							trap_1111 <= '1';
							trapmake <= '1';
						ELSE
							-- User mode: privilege violation (cpSAVE is privileged)
							trap_priv <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						-- Invalid EA mode: F-line exception regardless of mode
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				--ELSIF cpu="11" AND opcode(8 downto 6)="101" THEN --cpRESTORE
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="101" THEN --cpRESTORE
					-- cpRESTORE valid EA modes: control or postincrement
					-- Valid: (An), (An)+, (d16,An), (d8,An,Xn), (xxx).W, (xxx).L, (d16,PC), (d8,PC,Xn)
					-- Invalid: Dn, An, -(An), #imm
					-- Mode 111 valid: reg 0-3 only (absolute and PC-relative, NOT #imm which is reg 4)
					IF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="100" AND
					   (opcode(5 downto 3)/="111" OR opcode(2)='0') THEN
						-- Valid EA mode for cpRESTORE - this is a PRIVILEGED instruction
						IF SVmode='1' THEN
							-- Supervisor mode without FPU: F-line exception
							trap_1111 <= '1';
							trapmake <= '1';
						ELSE
							-- User mode: privilege violation (cpRESTORE is privileged)
							trap_priv <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						-- Invalid EA mode: F-line exception regardless of mode
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSE
					-- Unrecognized F-line instruction (cpGEN, cpBcc, etc.)
					-- FPU/coprocessor instructions without hardware support
					-- MC68030: F-line exception (vector 11) regardless of supervisor/user mode
					-- FPU general instructions like FADD, FMUL are NOT privileged
					trap_1111 <= '1';
					trapmake <= '1';
				END IF;
--							
----      ----------------------------------------------------------------------------		
			WHEN OTHERS =>
				trap_illegal <= '1';
				trapmake <= '1';

		END CASE;

-- use for AND, OR, EOR, CMP
		IF build_logical='1' THEN
			ea_build_now <= '1';
			IF set_exec(opcCMP)='0' AND (opcode(8)='0' OR opcode(5 downto 4)="00" ) THEN					
				set_exec(Regwrena) <= '1';
			END IF;
			IF opcode(8)='1' THEN
				write_back <= '1';
				set_exec(ea_data_OP1) <= '1';
			ELSE
				source_lowbits <='1';
				IF opcode(3)='1' THEN		--use for cmp
					source_areg <= '1';
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <= '1';
				END IF;
			END IF;
		END IF;
		
-- use for ABCD, SBCD
		IF build_bcd='1' THEN
			set_exec(use_XZFlag) <= '1';
			set_exec(ea_data_OP1) <= '1';
			write_back <= '1';
			source_lowbits <='1';
			IF opcode(3)='1' THEN
				IF decodeOPC='1' THEN
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					setstate <= "10";
					set(update_ld) <= '1';
					set(presub) <= '1';
					next_micro_state <= op_AxAy;
					dest_areg <= '1';				--???
				END IF;
			ELSE
				dest_hbits <= '1';
				set_exec(Regwrena) <= '1';
			END IF;
		END IF;


------------------------------------------------------------------------------
------------------------------------------------------------------------------
		IF set_Z_error='1'  THEN		-- divu by zero
			trapmake <= '1';			--wichtig for USP
			IF trapd='0' THEN
				writePC <= '1';
			END IF;			
		END IF;	
		
-----------------------------------------------------------------------------
-- execute microcode
-----------------------------------------------------------------------------
		IF rising_edge(clk) THEN
	        IF Reset='1' THEN
				micro_state <= ld_nn;
				pmmu_config_ack <= '0';  -- BUG #154: Reset ack signal
				pmove_disp_latched <= (others => '0');  -- BUG #197 V6: Initialize displacement latch
			ELSIF clkena_lw='1' THEN
				trapd <= trapmake;
				micro_state <= next_micro_state;
				-- BUG #228: Flag management moved to clkena_in block (see above line ~1953)
				-- BUG #154 FIX: Acknowledge MMU config error when trap is taken
				-- This clears mmu_config_error in PMMU to prevent infinite exception loop
				if trap_mmu_config='1' and trapd='0' then
					pmmu_config_ack <= '1';
				else
					pmmu_config_ack <= '0';
				end if;
				-- BUG #197 FIX V9: Latch DISPLACEMENT during ld_dAn1 when setdisp='1'
				-- memaddr_a contains the displacement ONLY when setdisp='1' (during ld_dAn1)
				-- After ld_dAn1, setdisp='0' resets memaddr_a to zero, so we must capture it here
				-- CRITICAL: Use fline_opcode_latch (stable) instead of opcode (may be unstable during EA building)
				-- CORRECTED: Check opcode EA mode bits (5:3) for displacement modes, not pmmu_brief register class
				if micro_state = ld_dAn1 and setdisp='1' and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and  -- F-line (PMOVE/FPU/etc)
				   (fline_opcode_latch(5 downto 3)="101" OR fline_opcode_latch(5 downto 3)="110") then  -- (d16,An) or (d8,An,Xn) modes
					-- This is an F-line instruction with displacement addressing mode
					pmove_disp_latched <= memaddr_a;
					report "BUG197_DEBUG: Latching displacement" severity note;
					report "  memaddr_a (latched disp) = " & integer'image(conv_integer(memaddr_a)) & " decimal" severity note;
					report "  fline_opcode_latch EA mode = " & integer'image(conv_integer(fline_opcode_latch(5 downto 3))) & " (should be 5 or 6)" severity note;
				end if;
				-- BUG #225 FIX: For (d8,An,Xn) mode 110, latch full computed indexed EA in ld_AnXn2
				-- At this point, addr contains the complete indexed EA (An + Xn + d8)
				-- Must latch it before transitioning to PMOVE states which would overwrite it
				-- BUG #386 FIX: Also check pmmu_ld_AnXn2! PMMU instructions use pmmu_ld_AnXn2
				-- (not ld_AnXn2) for (d8,An,Xn) mode. Without this, pmove_disp_latched stays
				-- at 0, causing PMOVE (d8,An,Xn) to read/write from address 0.
				if (micro_state = ld_AnXn2 OR micro_state = pmmu_ld_AnXn2) and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and  -- F-line (PMOVE/FPU/etc)
				   fline_opcode_latch(5 downto 3)="110" and  -- (d8,An,Xn) mode
				   (next_micro_state = pmove_mem_to_mmu_hi OR next_micro_state = pmove_mmu_to_mem_hi) then
					-- Latch the full computed indexed EA
					pmove_disp_latched <= addr;
				end if;
				-- BUG #387 DEBUG: Trace pmmu_ld_nn state at clkena_lw time
				if micro_state = pmmu_ld_nn and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and
				   fline_opcode_latch(5 downto 3)="111" and fline_opcode_latch(2 downto 0)="001" then
					if nextpass = '0' then
						report "BUG387_LW: nextpass=0 last_opc_read=" & integer'image(conv_integer(last_opc_read)) & " data_read=" & integer'image(conv_integer(data_read(15 downto 0))) severity note;
						pmove_disp_latched <= last_opc_read & data_read(15 downto 0);
					else
						report "BUG387_LW: nextpass=1 last_opc_read=" & integer'image(conv_integer(last_opc_read)) & " data_read=" & integer'image(conv_integer(data_read(15 downto 0))) severity note;
					end if;
				end if;
			END IF;
		END IF;

		CASE micro_state IS

				WHEN ld_nn =>		-- (nnnn).w/l=> CPU ONLY (PMMU uses pmmu_ld_nn)
					set(get_ea_now) <='1';
					set(addrlong) <= '1';
					-- MOVES: After absolute address is loaded, go to moves1 for data transfer using SFC/DFC
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
					   opcode(5 downto 3)="111" THEN
						setnextpass <= '0';
						setstate <= "01";  -- BUG #322: Prevent fetch, preserve absolute address
						ea_only <= '1';
						next_micro_state <= moves1;
					ELSE
						-- Normal CPU instruction: set setnextpass for standard EA processing
						setnextpass <= '1';
					END IF;

				WHEN st_nn =>		-- =>(nnnn).w/l
					setstate <= "11";
					set(addrlong) <= '1';
					next_micro_state <= nop;
					
				WHEN ld_dAn1 =>		-- d(An)=>, --d(PC)=> CPU ONLY (PMMU uses pmmu_ld_dAn1)
					set(get_ea_now) <='1';
					setdisp <= '1';		--word
					setnextpass <= '1';
					-- MOVES (d16,An): after fetching displacement word, route to moves1 for SFC/DFC transfer
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND opcode(5 downto 3)="101" THEN
						setnextpass <= '0';
						setstate <= "01";
						ea_only <= '1';
						next_micro_state <= moves1;
					END IF;
						
					WHEN ld_AnXn1 =>		-- d(An,Xn)=>, --d(PC,Xn)=>
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';		--byte	
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state <= ld_AnXn2;
					ELSE	
						IF brief(7)='1'THEN		--suppress Base
							set_suppress_base <= '1';
						ELSIF exec(dispouter)='1' THEN
							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN --NULL Base Displacement
							setstate <= "01";
						ELSE  --WORD Base Displacement
							IF brief(4)='1' THEN
								set(longaktion) <= '1'; --LONG Base Displacement
							END IF;
						END IF;
						next_micro_state <= ld_229_1;
					END IF;
					
				WHEN ld_AnXn2 =>		-- CPU ONLY (PMMU uses pmmu_ld_AnXn2)
					set(get_ea_now) <='1';
					setdisp <= '1';		--brief
					setnextpass <= '1';
					-- MOVES: After indexed EA is computed, go to moves1 for SFC/DFC transfer
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
					   opcode(5 downto 3)="110" THEN
						setnextpass <= '0';
						setstate <= "01";
						ea_only <= '1';
						next_micro_state <= moves1;
					END IF;

-------------------------------------------------------------------------------------

				WHEN ld_229_1 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>  CPU ONLY (PMMU uses pmmu_ld_229_1)
					IF brief(5)='1' THEN    --Base Displacement
						setdisp <= '1';		--add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN --Preindex or Index
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state <= ld_AnXn2;
						ELSE
							next_micro_state <= ld_229_2;
						END IF;
					ELSE
						IF brief(1 downto 0)="00" THEN
							set(get_ea_now) <='1';
							setnextpass <= '1';
							-- MOVES: full-format indexed EA dispatch to moves1 for SFC/DFC transfer
							IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
							   opcode(5 downto 3)="110" THEN
								setnextpass <= '0';
								setstate <= "01";
								ea_only <= '1';
								next_micro_state <= moves1;
							END IF;
						ELSE
							setstate <= "10";
							setaddrvalue <= '1';
							set(longaktion) <= '1';
							next_micro_state <= ld_229_3;
						END IF;
					END IF;

				WHEN ld_229_2 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					setdisp <= '1';		-- add Index
					setstate <= "10";
					setaddrvalue <= '1';
					set(longaktion) <= '1';
					next_micro_state <= ld_229_3;
				
				WHEN ld_229_3 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set_suppress_base <= '1';
					set(dispouter) <= '1'; 	
					IF brief(1)='0' THEN --NULL Outer Displacement
						setstate <= "01";
					ELSE  --WORD Outer Displacement
						IF brief(0)='1' THEN
							set(longaktion) <= '1'; --LONG Outer Displacement
						END IF;
					END IF;
					next_micro_state <= ld_229_4;
				
				WHEN ld_229_4 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					IF brief(1)='1' THEN  -- Outer Displacement
						setdisp <= '1';	  --add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN --Postindex
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state <= ld_AnXn2;
					ELSE
						set(get_ea_now) <='1';
						setnextpass <= '1';
						
						-- MOVES: memory-indirect EA completes here; dispatch to moves1
						-- for SFC/DFC bus transfer. Without this, MOVES falls through
						-- normal pipeline causing wrong FC, address, and data corruption.
						IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
						   opcode(5 downto 3)="110" THEN
							setnextpass <= '0';
							setstate <= "01";
							ea_only <= '1';
							next_micro_state <= moves1;
						END IF;
					END IF;

----------------------------------------------------------------------------------------
				-- PMMU-SPECIFIC EA BUILDERS: Use fline_opcode_latch and pmmu_brief exclusively
				-- These states are ONLY for PMMU instructions (PMOVE, PTEST, PFLUSH, PLOAD)
				----------------------------------------------------------------------------------------

				WHEN pmmu_ld_nn =>		-- PMMU (xxx).W / (xxx).L
					-- BUG #387 FIX: Do NOT set get_ea_now/addrlong during pass 1 of (xxx).L!
					-- Pass 1 only fetches the second address word from the instruction stream.
					-- Setting get_ea_now triggers setstate <= "10" at line 3196, which cascades
					-- through set(longaktion) at line 3202, corrupting memmask to "100001".
					-- This causes extra bus cycles with clkena_lw='0' where PC advances without
					-- progress, overrunning the next instruction by 4 bytes.
					IF nextpass='0' AND fline_opcode_latch(2 downto 0)="001" THEN
						-- First word of .L address fetched, stay in pmmu_ld_nn for second word
						setstate <= "00";  -- Allow fetch of second word
						setnextpass <= '1';
						next_micro_state <= pmmu_ld_nn;
					ELSE
						-- Second word of .L or single word of .W fetched, proceed to EA
						set(get_ea_now) <='1';
						set(addrlong) <= '1';
						setnextpass <= '0';
						-- BUG #393 FIX: Route PLOAD/PTEST/PFLUSH to walker handlers
						IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
							set(OP1addr) <= '1';
							setstate <= "01";
							IF pmmu_brief(15 downto 13) = "100" THEN
								next_micro_state <= ptest1;
							ELSIF pmmu_brief(12 downto 10) = "000" THEN
								next_micro_state <= pload1;
							ELSE
								next_micro_state <= pflush1;
							END IF;
						ELSIF pmmu_brief(9)='1' THEN
							-- MMU->mem direction (read from MMU, write to memory)
							setstate <= "01";
							next_micro_state <= pmove_mmu_to_mem_hi;
						ELSE
							-- mem->MMU direction (read from memory, write to MMU)
							setstate <= "10";  -- Memory read at computed EA
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- Word (16-bit) for MMUSR
							ELSE
								datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							END IF;
							set(longaktion) <= '1';  -- BUG #395 FIX: Required for 32-bit read!
							next_micro_state <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;

				WHEN pmmu_ld_dAn1 =>		-- PMMU (d16,An)
					set(get_ea_now) <='1';
					setdisp <= '1';		-- Load displacement word
				-- BUG #395 FIX: Set use_SP for (d16,A7) mode
				IF fline_opcode_latch(2 downto 0)="111" THEN
					set(use_SP) <= '1';
				END IF;
					setnextpass <= '0';  -- Always clear for PMMU
					-- BUG #393 FIX: Route PLOAD/PTEST/PFLUSH to walker handlers
					IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
						set(OP1addr) <= '1';
						setstate <= "01";
						IF pmmu_brief(15 downto 13) = "100" THEN
							next_micro_state <= ptest1;
						ELSIF pmmu_brief(12 downto 10) = "000" THEN
							next_micro_state <= pload1;
						ELSE
							next_micro_state <= pflush1;
						END IF;
					ELSIF pmmu_brief(9)='1' THEN
						-- MMU->mem direction
						setstate <= "01";
						next_micro_state <= pmove_mmu_to_mem_hi;
					ELSE
						-- mem->MMU direction
						set(OP1addr) <= '1';  -- Latch EA (base+disp) while setdisp active
						setstate <= "10";  -- Memory read at computed EA
						IF pmmu_brief(14 downto 10) = "11000" THEN
							datatype <= "01";  -- Word (16-bit) for MMUSR
						ELSE
							datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							set(longaktion) <= '1';  -- Required for 32-bit read
						END IF;
						next_micro_state <= pmove_mem_to_mmu_hi;
					END IF;

				WHEN pmmu_ld_AnXn1 =>		-- PMMU (d8,An,Xn) first phase
					-- brief was already latched in pmove_decode via getbrief
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						-- Simple brief format
						setdisp <= '1';		-- byte
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state <= pmmu_ld_AnXn2;
					ELSE
						-- Full format - route to pmmu_ld_229_1
						IF brief(7)='1'THEN		-- suppress Base
							set_suppress_base <= '1';
						ELSIF exec(dispouter)='1' THEN
							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN -- NULL Base Displacement
							setstate <= "01";
						ELSE  -- WORD Base Displacement
							IF brief(4)='1' THEN
								set(longaktion) <= '1'; -- LONG Base Displacement
							END IF;
						END IF;
						next_micro_state <= pmmu_ld_229_1;
					END IF;

				WHEN pmmu_ld_AnXn2 =>		-- PMMU (d8,An,Xn) second phase
					set(get_ea_now) <='1';
					setdisp <= '1';		-- brief
					setnextpass <= '0';  -- Always clear for PMMU
					-- BUG #393 FIX: Route PLOAD/PTEST/PFLUSH to walker handlers
					IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
						set(OP1addr) <= '1';
						setstate <= "01";
						IF pmmu_brief(15 downto 13) = "100" THEN
							next_micro_state <= ptest1;
						ELSIF pmmu_brief(12 downto 10) = "000" THEN
							next_micro_state <= pload1;
						ELSE
							next_micro_state <= pflush1;
						END IF;
					ELSIF pmmu_brief(9)='1' THEN
						-- MMU->mem direction
						setstate <= "01";
						next_micro_state <= pmove_mmu_to_mem_hi;
					ELSE
						-- mem->MMU direction
						setstate <= "10";  -- Memory read at computed EA
						IF pmmu_brief(14 downto 10) = "11000" THEN
							datatype <= "01";  -- Word (16-bit) for MMUSR
						ELSE
							datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							set(longaktion) <= '1';  -- BUG #395 FIX: Required for 32-bit read!
						END IF;
						next_micro_state <= pmove_mem_to_mmu_hi;
					END IF;

				WHEN pmmu_ld_229_1 =>		-- PMMU full-format indexed (bd,An,Xn) phase 1
					IF brief(5)='1' THEN    -- Base Displacement
						setdisp <= '1';		-- add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN -- Preindex or Index
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state <= pmmu_ld_AnXn2;
						ELSE
							next_micro_state <= pmmu_ld_229_2;
						END IF;
					ELSE
						IF brief(1 downto 0)="00" THEN
							set(get_ea_now) <='1';
							setnextpass <= '0';  -- Always clear for PMMU
							-- BUG #393 FIX: Route PLOAD/PTEST/PFLUSH to walker handlers
							IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
								set(OP1addr) <= '1';
								setstate <= "01";
								IF pmmu_brief(15 downto 13) = "100" THEN
									next_micro_state <= ptest1;
								ELSIF pmmu_brief(12 downto 10) = "000" THEN
									next_micro_state <= pload1;
								ELSE
									next_micro_state <= pflush1;
								END IF;
							ELSIF pmmu_brief(9)='1' THEN
								setstate <= "01";
								next_micro_state <= pmove_mmu_to_mem_hi;
							ELSE
								setstate <= "10";  -- Memory read at computed EA
								IF pmmu_brief(14 downto 10) = "11000" THEN
									datatype <= "01";  -- Word (16-bit) for MMUSR
								ELSE
									datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
								set(longaktion) <= '1';  -- BUG #395 FIX: Required for 32-bit read!
								END IF;
								next_micro_state <= pmove_mem_to_mmu_hi;
							END IF;
						ELSE
							setstate <= "10";
							setaddrvalue <= '1';
							set(longaktion) <= '1';
							next_micro_state <= pmmu_ld_229_3;
						END IF;
					END IF;

				WHEN pmmu_ld_229_2 =>		-- PMMU full-format indexed (bd,An,Xn) phase 2
					setdisp <= '1';		-- add Index
					setstate <= "10";
					setaddrvalue <= '1';
					set(longaktion) <= '1';
					next_micro_state <= pmmu_ld_229_3;

				WHEN pmmu_ld_229_3 =>		-- PMMU full-format indexed (bd,An,Xn) phase 3
					set_suppress_base <= '1';
					set(dispouter) <= '1';
					IF brief(1)='0' THEN -- NULL Outer Displacement
						setstate <= "01";
					ELSE  -- WORD Outer Displacement
						IF brief(0)='1' THEN
							set(longaktion) <= '1'; -- LONG Outer Displacement
						END IF;
					END IF;
					next_micro_state <= pmmu_ld_229_4;

				WHEN pmmu_ld_229_4 =>		-- PMMU full-format indexed (bd,An,Xn) phase 4
					IF brief(1)='1' THEN  -- Outer Displacement
						setdisp <= '1';	  -- add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN -- Postindex
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state <= pmmu_ld_AnXn2;
					ELSE
						set(get_ea_now) <='1';
						setnextpass <= '0';  -- Always clear for PMMU
						-- BUG #393 FIX: Route PLOAD/PTEST/PFLUSH to walker handlers
						IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
							set(OP1addr) <= '1';
							setstate <= "01";
							IF pmmu_brief(15 downto 13) = "100" THEN
								next_micro_state <= ptest1;
							ELSIF pmmu_brief(12 downto 10) = "000" THEN
								next_micro_state <= pload1;
							ELSE
								next_micro_state <= pflush1;
							END IF;
						ELSIF pmmu_brief(9)='1' THEN
							setstate <= "01";
							next_micro_state <= pmove_mmu_to_mem_hi;
						ELSE
							setstate <= "10";  -- Memory read at computed EA
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- Word (16-bit) for MMUSR
							ELSE
							set(longaktion) <= '1';  -- BUG #395 FIX: Required for 32-bit read!
								datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							END IF;
							next_micro_state <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;

----------------------------------------------------------------------------------------
				WHEN st_dAn1 =>		-- =>d(An)
					setstate <= "11";
					setdisp <= '1';		--word
					next_micro_state <= nop;
					
				WHEN st_AnXn1 =>		-- =>d(An,Xn)
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';		--byte	
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state <= st_AnXn2;
					ELSE	
						IF brief(7)='1'THEN		--suppress Base
							set_suppress_base <= '1';
--						ELSIF exec(dispouter)='1' THEN
--							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN --NULL Base Displacement
							setstate <= "01";
						ELSE  --WORD Base Displacement
							IF brief(4)='1' THEN
								set(longaktion) <= '1'; --LONG Base Displacement
							END IF;
						END IF;
						next_micro_state <= st_229_1;
					END IF;
					
				WHEN st_AnXn2 =>
					setstate <= "11";
					setdisp <= '1';		--brief	
					set(hold_dwr) <= '1';
					next_micro_state <= nop;
					
-------------------------------------------------------------------------------------					
					
				WHEN st_229_1 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					IF brief(5)='1' THEN    --Base Displacement
						setdisp <= '1';		--add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN --Preindex or Index
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state <= st_AnXn2;
						ELSE	
							next_micro_state <= st_229_2;
						END IF;	
					ELSE
						IF brief(1 downto 0)="00" THEN
							setstate <= "11";
							next_micro_state <= nop;
						ELSE
							set(hold_dwr) <= '1';
							setstate <= "10";
							set(longaktion) <= '1';
							next_micro_state <= st_229_3;
						END IF;
					END IF;
					
				WHEN st_229_2 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					setdisp <= '1';		-- add Index
					set(hold_dwr) <= '1';
					setstate <= "10";
					set(longaktion) <= '1';
					next_micro_state <= st_229_3;
				
				WHEN st_229_3 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set(hold_dwr) <= '1';
					set_suppress_base <= '1';
					set(dispouter) <= '1'; 	
					IF brief(1)='0' THEN --NULL Outer Displacement
						setstate <= "01";
					ELSE  --WORD Outer Displacement
						IF brief(0)='1' THEN
							set(longaktion) <= '1'; --LONG Outer Displacement
						END IF;
					END IF;
					next_micro_state <= st_229_4;
				
				WHEN st_229_4 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set(hold_dwr) <= '1';
					IF brief(1)='1' THEN  -- Outer Displacement
						setdisp <= '1';	  --add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN --Postindex
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state <= st_AnXn2;
					ELSE
						setstate <= "11";
						next_micro_state <= nop;
					END IF;
					
----------------------------------------------------------------------------------------				
				WHEN bra1 =>		--bra
					IF exe_condition='1' THEN
						TG68_PC_brw <= '1';	--pc+0000
						next_micro_state <= nop;
						if long_start='0' then
							skipFetch <= '1'; -- AMR/GS - can't skip fetch for bra.l
						end if;
					END IF;
					
				WHEN bsr1 =>		--bsr short
					TG68_PC_brw <= '1';	
					next_micro_state <= nop;
					
				WHEN bsr2 =>		--bsr
					IF long_start='0' THEN	
						TG68_PC_brw <= '1';	
						skipFetch <= '1';	-- AMR - can't skip fetch for bsr.l
					END IF;
					set(longaktion) <= '1';
					writePC <= '1';
					setstate <= "11";
					next_micro_state <= nopnop;
					setstackaddr <='1';
				WHEN nopnop =>		--bsr
					next_micro_state <= nop;

				WHEN dbcc1 =>		--dbcc
					IF exe_condition='0' THEN
						Regwrena_now <= '1';
						IF c_out(1)='1' THEN
							skipFetch <= '1';				
							next_micro_state <= nop;
							TG68_PC_brw <= '1';	
						END IF;	
					END IF;

				WHEN chk20 =>			--if C is set -> signed compare
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state <= chk21;
				WHEN chk21 =>			-- check lower bound
					dest_2ndHbits <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";	--long
						dest_LDRareg <= '1';
						IF opcode(10 downto 9)="00" THEN
							set(opcEXTB) <= '1';
						END IF;
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state <= chk22;
				WHEN chk22 =>			--check upper bound
					dest_2ndHbits <= '1';
					set(ea_data_OP2) <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";	--long
						dest_LDRareg <= '1';
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(opcCHK2) <= '1';
					set(opcEXTB) <= exec(opcEXTB);
					IF sndOPC(11)='1' THEN
						setstate <="01";
						next_micro_state <= chk23;
					END IF;
				WHEN chk23 =>
						setstate <="01";
						next_micro_state <= chk24;
				WHEN chk24 =>
					IF Flags(0)='1'THEN
						trapmake <= '1';
					END IF;
					
					
				WHEN cas1 =>
						setstate <="01";
						next_micro_state <= cas2;
				WHEN cas2 =>
					source_2ndMbits <= '1';
					IF Flags(2)='1'THEN
						setstate<="11";
						set(write_reg) <= '1';
						set(restore_ADDR) <= '1';
						next_micro_state <= nop;
					ELSE
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						dest_2ndLbits <= '1';
						set(alu_move) <= '1';
					END IF;
					
				WHEN cas21 =>
					dest_2ndHbits <= '1';
					dest_LDRareg <= sndOPC(15);
					set(get_ea_now) <='1';
					next_micro_state <= cas22;
				WHEN cas22 =>
					setstate <= "01";
					source_2ndLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					next_micro_state <= cas23;
				WHEN cas23 =>
					dest_LDRHbits <= '1';
					set(get_ea_now) <='1';
					next_micro_state <= cas24;
				WHEN cas24 =>
					IF Flags(2)='1'THEN
						set(alu_setFlags) <= '1';
					END IF;
					setstate <="01";
					set(hold_dwr) <= '1';
					source_LDRLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					next_micro_state <= cas25;
				WHEN cas25 =>
					setstate <= "01";
					set(hold_dwr) <= '1';
					next_micro_state <= cas26;
				WHEN cas26 =>
					IF Flags(2)='1'THEN -- write Update 1 to Destination 1
						source_2ndMbits <= '1';
						set(write_reg) <= '1';
						dest_2ndHbits <= '1';
						dest_LDRareg <= sndOPC(15);
						setstate <= "11";
						set(get_ea_now) <='1';
						next_micro_state <= cas27;
					ELSE		   			-- write Destination 2 to Compare 2 first
						set(hold_dwr) <= '1';
						set(hold_OP2) <='1';
						dest_LDRLbits <= '1';
						set(alu_move) <= '1';
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						next_micro_state <= cas28;
					END IF;
				WHEN cas27 =>				-- write Update 2 to Destination 2
					source_LDRMbits <= '1';
					set(write_reg) <= '1';
					dest_LDRHbits <= '1';
					setstate <= "11";
					set(get_ea_now) <='1';
					next_micro_state <= nopnop;
				WHEN cas28 =>				-- write Destination 1 to Compare 1 second
					dest_2ndLbits <= '1';
					set(alu_move) <= '1';
					set(Regwrena) <= '1';
					
				WHEN movem1 =>		--movem
					IF last_data_read(15 downto 0)/=X"0000" THEN
						setstate <="01";
						IF opcode(5 downto 3)="100" THEN
							set(mem_addsub) <= '1';
							IF cpu(1)='1' THEN
								set(Regwrena) <= '1';	--tg
							END IF;
						END IF;
						next_micro_state <= movem2;
					END IF;
				WHEN movem2 =>		--movem
					IF movem_run='0' THEN
						setstate <="01";
					ELSE	
						set(movem_action) <= '1';
						set(mem_addsub) <= '1';
						next_micro_state <= movem2;
						IF opcode(10)='0' THEN
							setstate <="11";
							set(write_reg) <= '1';
						ELSE
							setstate <="10";
						END IF;
					END IF;	

				WHEN andi =>		--andi
					IF opcode(5 downto 4)/="00" THEN
						setnextpass <= '1';
					END IF;

				WHEN pack1 =>		-- pack -(Ax),-(Ay)
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';	
					set(update_ld) <= '1';
					setstate <= "10";
					set(presub) <= '1';
					next_micro_state <= pack2;
					dest_areg <= '1';				
				WHEN pack2 =>	
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';	
					set_direct_data <= '1';
					IF opcode(7 downto 6) = "01" THEN	--pack
						datatype <= "00";		--Byte
					ELSE								--unpk
						datatype <= "01";		--Word
					END IF;
					set(presub) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";
					next_micro_state <= pack3;
				WHEN pack3 =>	
					skipFetch <= '1';
					
				WHEN op_AxAy =>		-- op -(Ax),-(Ay)
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(presub) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";

				WHEN cmpm =>		-- cmpm (Ay)+,(Ax)+
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(postadd) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";
					
				WHEN link1 =>		-- link
					setstate <="11";
					source_areg <= '1';
					set(opcMOVE) <= '1';
					set(Regwrena) <= '1';
					next_micro_state <= link2;
				WHEN link2 =>		-- link
					setstackaddr <='1';
					set(ea_data_OP2) <= '1';
					
				WHEN unlink1 =>		-- unlink
					setstate <="10";
					setstackaddr <='1';
					set(postadd) <= '1';
					next_micro_state <= unlink2;
				WHEN unlink2 =>		-- unlink
					set(ea_data_OP2) <= '1';
					
-- paste and copy form TH	---------	
				WHEN trap00 =>          -- TRAP format #2
					next_micro_state <= trap0;
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
------------------------------------
				WHEN trap0 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					IF use_VBR_Stackframe='1' THEN	--68010
						set(writePC_add) <= '1';
						datatype <= "01";
--						set_datatype <= "10";
						next_micro_state <= trap1;
					ELSE
						IF trap_interrupt='1' OR trap_trace='1' OR trap_berr='1' THEN
							writePC <= '1';
						END IF;
						datatype <= "10";
						next_micro_state <= trap2;
					END IF;

				WHEN trap1 =>		-- TRAP
					IF trap_interrupt='1' OR trap_trace='1' THEN
						writePC <= '1';
					END IF;
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					next_micro_state <= trap2;
				WHEN trap2 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					IF trap_berr='1' THEN
						next_micro_state <= trap4;
					ELSIF cpu(1)='1' AND trap_interrupt='1' AND trap_SR(4)='1' THEN
						-- MC68030: M=1 interrupt dual-frame - push throwaway on ISP
						next_micro_state <= int2;
					ELSE
						next_micro_state <= trap3;
					END IF;
				-- MC68030: Interrupt dual-frame push (M=1)
				-- After trap2 pushes SR to MSP, swap to ISP and push Format $1 throwaway frame
				WHEN int2 =>
					-- Swap from MSP to ISP for throwaway frame
					set(to_MSP) <= '1';     -- Save current A7 to MSP register
					set(from_ISP) <= '1';   -- Load ISP into A7
					set(Regwrena) <= '1';   -- Enable register file write for A7 update
					setstackaddr <= '1';
					setstate <= "01";        -- Idle: let swap settle
					next_micro_state <= int3;
				WHEN int3 =>
					-- Push Format $1 format/vector word (16-bit) on ISP
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";        -- Write
					datatype <= "01";        -- 16-bit
					-- data_write_tmp set in mux (Format $1 word)
					next_micro_state <= int4;
				WHEN int4 =>
					-- Push Format $1 PC (32-bit) on ISP
					writePC <= '1';          -- data_write_tmp <= TG68_PC
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";        -- Write
					datatype <= "10";        -- 32-bit
					next_micro_state <= int5;
				WHEN int5 =>
					-- Push Format $1 SR (16-bit) on ISP, then load handler
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";        -- Write
					datatype <= "01";        -- 16-bit
					writeSR <= '1';          -- data_write_tmp <= trap_SR & Flags
					next_micro_state <= trap3;  -- Load handler vector

				WHEN trap3 =>		-- TRAP
					set_vectoraddr <= '1';
					datatype <= "10";
					set(direct_delta) <= '1';
					set(directPC) <= '1';
					setstate <= "10";
					next_micro_state <= nopnop;

                -- MC68030 Bus Error Stack Frame Generation (Format $A - Short Bus Fault)
                -- Pushes 16 words (8 Longs) to the stack.
                -- Order: Internal($1E/1C) -> DataOut($1A/18) -> Internal($16/14) -> FaultAddr($12/10)
                --        -> InstrPipe($0E/0C) -> SSW($0A/08) -> Format/PC_Lo($06/04) -> SR/PC_Hi($02/00)
                WHEN berr1 => -- Push Internal Regs ($1C-$1F) - Stub
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr2;
                WHEN berr2 => -- Push Data Output Buffer ($18-$1B) - Stub
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr3;
                WHEN berr3 => -- Push Internal Regs ($14-$17) - Stub
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr4;
                WHEN berr4 => -- Push Fault Address ($10-$13) - Capture current Addr
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr5;
                WHEN berr5 => -- Push Instruction Pipe ($0C-$0F) - Stub
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr6;
                WHEN berr6 => -- Push SSW ($0A) & Internal ($08) - SSW Stub
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr7;
                WHEN berr7 => -- Push Format/Vector ($06) & PC Lo ($04)
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state <= berr8;
                WHEN berr8 => -- Push PC Hi ($02) & SR ($00) -> Exit to Handler
                    setstate <= "11";
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    -- Exit logic (matches trap3)
                    set_vectoraddr <= '1';
                    set(direct_delta) <= '1';	
                    set(directPC) <= '1';
                    next_micro_state <= nopnop;

				WHEN trap4 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state <= trap5;
				WHEN trap5 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					writeSR <= '1';
					next_micro_state <= trap6;
				WHEN trap6 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state <= trap3;
					
										-- return from exception - RTE
										-- fetch PC and status register from stack
										-- 010+ fetches another word containing
										-- the 12 bit vector offset and the
										-- frame format. If the frame format is
										-- 2 another two words have to be taken
										-- from the stack
				WHEN rte1 =>		-- RTE
					datatype <= "10";
					setstate <= "10";
					set(postadd) <= '1';
					setstackaddr <= '1';
					set(directPC) <= '1';	
					IF use_VBR_Stackframe='0' OR opcode(2)='1' THEN	--opcode(2)='1' => opcode is RTR
						set(update_FC) <= '1';
						set(direct_delta) <= '1';	
					END IF;
					next_micro_state <= rte2;
				WHEN rte2 =>		-- RTE
					datatype <= "01";
					set(update_FC) <= '1';
					IF use_VBR_Stackframe='1' AND opcode(2)='0' THEN
												-- 010+ reads another word
						setstate <= "10";
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state <= rte3;
					ELSE
						next_micro_state <= nop;
					END IF;
--				WHEN rte3 =>			-- RTE
--					next_micro_state <= nop;
----					set(update_FC) <= '1';
-- paste and copy form TH	---------	
				when rte3 => -- RTE
					setstate <= "01"; -- idle state to wait
											-- for input data to
											-- arrive
					next_micro_state <= rte4;
				WHEN rte4 =>         -- RTE
					-- MC68030 stack frame format validation (bits 15-12 of format/vector word)
					-- MC68030 User's Manual Section 6.4 - Exception Stack Frames:
					--   Format $0: 4-word frame (8 bytes) - short format, most exceptions
					--   Format $1: 4-word frame (8 bytes) - throwaway, interrupt return
					--   Format $2: 6-word frame (12 bytes) - CHK, CHK2, cpTRAPcc, TRAPV, Trace, Div0, MMU config
					--   Format $9: 10-word frame (20 bytes) - coprocessor mid-instruction
					--   Format $A: 16-word frame (32 bytes) - short bus fault
					--   Format $B: 46-word frame (92 bytes) - long bus fault
					-- Format code is in bits 15-12 of the format/vector word
					CASE rte_format_word(15 downto 12) IS
						WHEN "0001" =>
							-- MC68030 Format $1: Throwaway frame - chain to second frame
							-- SR already restored from this frame. FlagsSR(4) = M bit from throwaway SR.
							IF cpu(1)='1' THEN
								IF FlagsSR(4)='1' THEN
									-- M=1: second frame on MSP, swap ISP->MSP
									-- format1_chain_active set by registered process
									set(to_ISP) <= '1';
									set(from_MSP) <= '1';
									set(Regwrena) <= '1';  -- Enable register file write for A7 update
								END IF;
								-- M=0: second frame on ISP (current stack), no swap needed
								setstackaddr <= '1';
								setstate <= "01";         -- Idle for swap to settle
								next_micro_state <= rte6; -- Read SR from second frame
							ELSE
								-- 68000/68010: no Format $1 chaining, treat as normal
								datatype <= "01";
								next_micro_state <= nop;
							END IF;
						WHEN "0000" | "0011" =>
							-- Format $0/$3: 4-word frame - no additional reads needed
							-- Format 3 is accepted by real MC68030 hardware as 4-word frame
							datatype <= "01";
							next_micro_state <= nop;
							IF format1_chain_active='1' THEN
								-- Swap back after dual-frame: save A7 to MSP, load ISP
								set(to_MSP) <= '1';
								set(from_ISP) <= '1';
								set(Regwrena) <= '1';  -- Enable register file write for A7 update
								setstackaddr <= '1';
								setstate <= "01";  -- Idle: ensures memmask="111111" so clkena_lw='1' for register write
								-- format1_chain_active cleared by registered process
							END IF;
							-- Clear interrupt mode when returning to user mode
							IF FlagsSR(5)='0' THEN
								interrupt_mode <= '0';
							END IF;
						WHEN "0010" =>
							-- Format 2: 6-word frame - read 1 more longword (4 bytes)
							setstate <= "10"; -- read
							datatype <= "10"; -- long word
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000001"; -- 1 longword remaining
							next_micro_state <= rte5;
						WHEN "1001" =>
							-- Format 9: 10-word frame - read 3 more longwords (12 bytes)
							setstate <= "10"; -- read
							datatype <= "10"; -- long word
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000011"; -- 3 longwords remaining
							next_micro_state <= rte5;
						WHEN "1010" =>
							-- Format A: 16-word frame - read 6 more longwords (24 bytes)
							setstate <= "10"; -- read
							datatype <= "10"; -- long word
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000110"; -- 6 longwords remaining
							next_micro_state <= rte5;
						WHEN "1011" =>
							-- Format B: 46-word frame - read 21 more longwords (84 bytes)
							setstate <= "10"; -- read
							datatype <= "10"; -- long word
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "010101"; -- 21 longwords remaining
							next_micro_state <= rte5;
						WHEN OTHERS =>
							-- Invalid format for MC68030 - generate Format Error exception (vector 14)
							-- Formats $4-$8, $C-$F are not valid on MC68030
							trap_format_error <= '1';
							trapmake <= '1';
					END CASE;
				WHEN rte5 =>            -- RTE
					-- Continue popping stack for formats that need multiple reads
					IF rot_cnt = "000001" THEN
						-- Last read completed - RTE is finishing
						next_micro_state <= nop;
						-- MC68030: Swap back after dual-frame if needed
						IF format1_chain_active='1' THEN
							set(to_MSP) <= '1';
							set(from_ISP) <= '1';
							set(Regwrena) <= '1';  -- Enable register file write for A7 update
							setstackaddr <= '1';
							setstate <= "01";  -- Idle: ensures memmask="111111" so clkena_lw='1' for register write
							-- format1_chain_active cleared by registered process
						END IF;
						-- BUG #18: Clear interrupt mode only when returning to user mode (MC68030)
						IF FlagsSR(5)='0' THEN
							interrupt_mode <= '0';
						END IF;
					ELSE
						-- More longwords to read
						setstate <= "10"; -- read
						datatype <= "10"; -- long word
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state <= rte5;
					END IF;

				-- MC68030: RTE Format $1 chain - read SR from second stack frame
				WHEN rte6 =>
					-- A7 now points to the correct stack (MSP or ISP based on M bit)
					setstate <= "10";            -- Read
					set(postadd) <= '1';         -- Post-increment A7
					setstackaddr <= '1';         -- Use stack address
					set(directSR) <= '1';        -- Load SR from this read
					datatype <= "01";            -- 16-bit (SR word)
					next_micro_state <= rte1;    -- Continue with PC read
-------------------------------------

				WHEN rtd1 =>		-- RTD
					next_micro_state <= rtd2;
				WHEN rtd2 =>		-- RTD
					setstackaddr <= '1';
					set(Regwrena) <= '1';
					
				WHEN movec1 =>		-- MOVEC
					set(briefext) <= '1';
					set_writePCbig <='1';
					-- BUG #193 FIX: Decode stack pointer registers using brief (now valid after getbrief)
					-- This was incorrectly done during decode using last_data_read
					IF brief(11 downto 0)=X"800" THEN
						set(from_USP) <= '1';
						IF opcode(0)='1' THEN
							set(to_USP) <= '1';
						END IF;
					ELSIF cpu(1)='1' THEN
						-- 68020+: MSP/ISP are separate control registers
						CASE brief(11 downto 0) IS
							WHEN X"803" =>  -- MSP (Master Stack Pointer)
								set(from_MSP) <= '1';
								IF opcode(0)='1' THEN
									set(to_MSP) <= '1';
								END IF;
							WHEN X"804" =>  -- ISP (Interrupt Stack Pointer)
								set(from_ISP) <= '1';
								IF opcode(0)='1' THEN
									set(to_ISP) <= '1';
								END IF;
							WHEN OTHERS =>
								NULL;
						END CASE;
					END IF;
					-- MC68030 MOVEC: Per MC68030 User's Manual Table 4-2
					-- 68000: SFC(000), DFC(001), USP(800), VBR(801)
					-- 68020+: Add CACR(002), CAAR(802), MSP(803), ISP(804)
					-- NOTE: All PMMU registers (TC, TT0, TT1, CRP, SRP, MMUSR) are PMOVE-only!
					IF (brief(11 downto 0)=X"000" OR brief(11 downto 0)=X"001" OR brief(11 downto 0)=X"800" OR brief(11 downto 0)=X"801") OR
					   (cpu(1)='1' AND (brief(11 downto 0)=X"002" OR brief(11 downto 0)=X"802" OR brief(11 downto 0)=X"803" OR brief(11 downto 0)=X"804")) THEN
						IF opcode(0)='0' THEN
							set(Regwrena) <= '1';
						END IF;
						-- BUG #216/#387 FIX: Valid register - advance to next instruction
						setstate <= "00";
--					ELSIF brief(11 downto 0)=X"800"OR brief(11 downto 0)=X"001" OR brief(11 downto 0)=X"000" THEN
--						trap_addr_error <= '1';
--						trapmake <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
						-- BUG #387 FIX: Invalid register (ITT0/DTT0/URP/DRP) - trap without fetch
						-- Don't set setstate here; trap dispatch (line 3019) will set setstate="01"
					END IF;

					WHEN moves0 =>		-- MOVES address setup state (BUG #149 FIX)
					-- Set up register selection one cycle before memory access
					-- This allows memaddr_reg to be updated with correct An value at clock edge
					-- before moves1 starts the actual memory operation
					-- NOTE: Use opcode, not exe_opcode - exe_opcode wasn't latched for MOVES
					source_lowbits <= '1';
					IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
						source_areg <= '1';  -- (An), (An)+, -(An) modes use address register
					END IF;
					-- BUG #324 FIX: Pre-set ALU subtract direction for -(An) mode.
					-- memaddr_delta_rega is REGISTERED (latched at clkena_lw edge), and during
					-- moves1 it latches addsub_q. But addsub_q uses the CURRENT exec (from
					-- moves0's set), which doesn't have presub/subidx. By setting subidx here
					-- in moves0, exec(subidx)='1' is ready during moves1, making addsub_q
					-- correctly subtract (An - size) instead of add (An + size).
					-- Note: We set subidx, NOT presub, to avoid triggering Wwrena (register write).
					IF opcode(5 downto 3)="100" THEN
						set(subidx) <= '1';
					END IF;
					-- FIX: Set datatype for correct address adjustment in (An)+/-(An) modes
					datatype <= opcode(7 downto 6);
					set_datatype <= opcode(7 downto 6);
					set(no_Flags) <= '1';  -- BUG #220: MOVES does not affect condition codes
                    -- BUG #149 FIX: Set FC override signals one cycle early
					-- This way exec(use_sfc_dfc) will be '1' in moves1 when the bus op happens
					-- brief(11)=dr: dr=1 means write (use DFC), dr=0 means read (use SFC)
					set(use_sfc_dfc) <= '1';
						IF brief(11)='0' THEN
							set(sfc_not_dfc) <= '1';  -- Read operation uses SFC

						END IF;
						-- BUG #322 FIX: Eliminated two-phase moves0 approach.
						-- The displacement/brief word is being fetched THIS cycle (state="00").
						-- last_data_read will contain it at the next rising edge.
						-- Go directly to the EA handler - no second moves0 cycle needed.
						-- The old two-phase approach caused phase 1 to fetch from wrong address
						-- (BUG #149 exclusion corrupted addr) AND overwrite the displacement data.
						IF opcode(5 downto 3)="101" THEN
							-- (d16,An): displacement word fetched this cycle, available in last_data_read
							-- at ld_dAn1 which uses setdisp='1' to read it
							setstate <= "01";  -- prevent next cycle from fetching
							next_micro_state <= ld_dAn1;
						ELSIF opcode(5 downto 3)="110" THEN
							-- (d8,An,Xn): EA extension word fetched this cycle
							-- Load it into brief via getbrief for ld_AnXn1
							getbrief <= '1';
							setstate <= "01";
							next_micro_state <= ld_AnXn1;
						ELSIF opcode(5 downto 3)="111" THEN
							-- Absolute modes: route to ld_nn for address fetch
							-- BUG #325 FIX: Do NOT use longaktion for absolute LONG mode.
							-- moves0 runs at state="00" which already fetches the first address word
							-- (high word). Using longaktion would cause ld_nn to fetch 2 MORE words
							-- via the memmask="100001" sequence, giving 3 total fetches for a 2-word
							-- address and overincrementing PC by 2 bytes.
							-- Instead, let ld_nn run at state="00" for one cycle to fetch the second
							-- (low) word. The 32-bit address is assembled in the EA capture from
							-- last_opc_read (high, from moves0) & data_read (low, from ld_nn).
							-- For absolute WORD, setstate="01" prevents an extra fetch (only 1 word needed,
							-- already fetched during moves0).
							IF opcode(2 downto 0)="001" THEN
								NULL;  -- xxx.L: state stays "00" for one more fetch (the low word)
							ELSE
								setstate <= "01";  -- xxx.W: word already fetched, prevent extra fetch
							END IF;
							next_micro_state <= ld_nn;
						ELSE
							-- Simple (An), (An)+, -(An) modes: go directly to moves1
							setstate <= "01";
							next_micro_state <= moves1;
						END IF;

				WHEN moves1 =>		-- MOVES instruction
					-- MC68030 MOVES extension word format:
					-- Bit 15: D/A (0=Dn, 1=An)
					-- Bits 14-12: Register number (0-7)
					-- Bit 11: Direction (dr):
					--   dr=1: Rn->EA (write to memory, use DFC)
					--   dr=0: EA->Rn (read from memory, use SFC)
					-- Bits 10-0: Reserved (must be zeros per MC68030 spec)
					-- BUG #170 FIX: Validate reserved bits are zero
					-- MC68030 spec says these must be zero; non-zero should trap as illegal
					-- IF brief(10 downto 0) /= "00000000000" THEN
					-- 	trap_illegal <= '1';
					-- 	trapmake <= '1';
					-- ELSE
					-- BUG #222 FIX: MOVES opcode bits 7:6 encode size (00=byte, 01=word, 10=long)
					-- Must set datatype for correct memmask and byte lane selection
					datatype <= opcode(7 downto 6);
					set_datatype <= opcode(7 downto 6);
					set(briefext) <= '1';  -- Use brief(15)&brief(14:12) for register selection
					-- BUG #149 FIX: REMOVED set_writePCbig - was causing PC to be set to EA!
					-- PC increment is handled by the extension word fetch (getbrief)
					-- Same fix as BUG #54 for pmove_decode
					-- BUG #319 FIX: REMOVED set(opcMOVE) - it causes exec(alu_move)='1' on the
					-- next cycle, which makes ALUout=OP2out instead of addsub_q. This corrupts
					-- the postadd/presub register writeback (A0 gets D2 value instead of A0+2).
					-- BUG #320 FIX: Use set(write_reg) for CPU->mem to route reg_QB directly
					-- to data_write_muxin, bypassing the registered data_write_tmp.
					set(use_sfc_dfc) <= '1';  -- Use SFC/DFC for FC override
					set(no_Flags) <= '1';  -- BUG #220: MOVES does not affect condition codes (MC68030 spec)
					-- BUG #149 FIX: Keep source_lowbits set to maintain EA register selection
					-- memaddr_reg is updated every clock, so we need correct rf_source_addr continuously
					-- NOTE: Use opcode, not exe_opcode - exe_opcode wasn't latched for MOVES
					source_lowbits <= '1';
					IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
						source_areg <= '1';  -- (An), (An)+, -(An) modes use address register
					END IF;
					-- FIX: Handle (An)+ and -(An) addressing modes with correct size
					IF opcode(5 downto 3)="011" THEN  -- (An)+
						set(postadd) <= '1';
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';  -- SP uses special increment rules
						END IF;
					END IF;
					IF opcode(5 downto 3)="100" THEN  -- -(An)
						set(presub) <= '1';
						set(addsub) <= '1';  -- BUG #324: Ensure ALU subtracts when execOPC='1'
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';  -- SP uses special decrement rules
						END IF;
					END IF;
					-- BUG #149 FIX: Must transition to nop state to hold the data access
					-- Without this, next_micro_state defaults to idle and state goes back to "00" (fetch)
					-- BUG #325 FIX: For complex EA modes (d16/indexed/absolute), use nopnop
					-- instead of nop. After the bus operation, nop causes setendOPC to fire
					-- immediately (next_micro_state=idle, setstate="00"). At this point
					-- state is "11"/"10" (bus cycle), so opcode <= last_opc_read (line 2231).
					-- But last_opc_read still contains the displacement/index/address word
					-- from the instruction stream, NOT the next instruction.
					-- nopnop->nop adds one cycle: the nopnop cycle has next_micro_state=nop
					-- which blocks setendOPC. Then state transitions to "00" (fetch), and
					-- when setendOPC fires in the nop cycle, opcode <= data_read (line 2228)
					-- which is the freshly fetched next instruction word.
					-- Simple modes (An)/(An)+/-(An) don't need this because moves0's
					-- state="00" cycle already fetched the next instruction into last_opc_read.
					IF opcode(5 downto 3)="101" OR opcode(5 downto 3)="110" OR opcode(5 downto 3)="111" THEN
						next_micro_state <= nopnop;
					ELSE
						next_micro_state <= nop;
					END IF;
					IF moves_direction='1' THEN
						-- MOVES Rn,<ea> - Register to Memory using DFC (dr=1)
						setstate <= "11";  -- Write to EA
						set(write_reg) <= '1';  -- BUG #320: Route reg_QB directly to bus data
						-- DFC used for write (sfc_not_dfc stays '0')
						ELSE
							-- MOVES <ea>,Rn - Memory to Register using SFC (dr=0)
							setstate <= "10";  -- Read from EA
							-- BUG #323a: Do NOT set Regwrena here! Setting it causes a premature
							-- register write during the bus access cycle with wrong data (ALUout
							-- instead of bus read data). The deferred writeback at the end of
							-- this process (line ~6155) handles the register write after bus data
							-- is available, using moves_writeback_pending.
							set(sfc_not_dfc) <= '1';  -- Use SFC for read
							set(no_Flags) <= '1';  -- BUG #220: MOVES does not affect condition codes
						END IF;
					-- END IF;  -- BUG #170: reserved bits check

                WHEN pmove_decode =>		-- PMMU instruction dispatch based on extension word
                    setstate <= "01";       -- Suppress fetch during dispatch (PC already at +4)
                    set(update_FC) <= '1';  -- Ensure FC reflects supervisor mode
                    
                    -- F-Line Context: Use pmmu_brief for stable values
                    IF (pmmu_brief(15 downto 13) = "000" AND (pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011")) OR  -- TT0/TT1
                        (pmmu_brief(15 downto 13) = "010" AND (pmmu_brief(14 downto 10) = "10000" OR pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011")) OR  -- TC/SRP/CRP
                        (pmmu_brief(15 downto 13) = "011" AND pmmu_brief(14 downto 10) = "11000" ) THEN  --MMUSR
                        
                        -- PMOVE
                        -- BUG #377 FIX: Use pmmu_opcode (latched F-line opcode) instead of opcode!
                        -- By pmove_decode time, opcode may have been overwritten by prefetch.
                        -- fline_opcode_latch preserves the original F-line opcode EA mode bits.
                        IF pmmu_opcode(5 downto 3)="001" OR (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') OR (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2 downto 1)="01") THEN
                             trap_illegal <= '1';
                             trapmake <= '1';
                        ELSE
                             -- Valid EA
                             IF pmmu_opcode(5 downto 3)="000" THEN
                                -- Dn mode: 4 bytes (Opcode + Extension).
                                -- PC increment handled by standard prefetch cycle (already at +4).
                                IF pmmu_brief(9)='1' THEN
                                    -- Read from MMU
                                    set(pmmu_rd) <= '1';
                                    IF (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011") THEN
                                        -- BUG #376 FIX: 64-bit CRP/SRP Dn read - HI word needs
                                        -- exec(Regwrena) + exec(pmmu_rd) at pmove_dn_hi to write Dn.
                                        -- MUST use set() not set_exec() because setexecOPC='0' when
                                        -- next_micro_state != idle. exec <= set propagates unconditionally.
                                        set(Regwrena) <= '1';
                                        -- Also set set_exec(pmmu_rd) to ensure the clocked PMMU
                                        -- reg_sel/reg_part setup block (line 6926) outer condition fires.
                                        -- set_exec won't propagate to exec (setexecOPC='0'), but it
                                        -- satisfies the outer condition for reg_part_d/reg_sel_d setup.
                                        set_exec(pmmu_rd) <= '1';
                                        datatype <= "10"; -- Longword for HI word
                                        next_micro_state <= pmove_dn_hi;
                                    ELSE
                                        -- BUG #375 FIX: Route through pmmu_dn_read_wait for proper
                                        -- register write-back timing. set_exec(pmmu_rd) persists to
                                        -- pmmu_dn_read_wait where exec(pmmu_rd) triggers Regwrena.
                                        -- At idle, both exec(pmmu_rd) and exec(Regwrena) are active,
                                        -- so regin=pmmu_reg_rdat AND Wwrena='1' -> correct write.
                                        set_exec(pmmu_rd) <= '1';
                                        IF pmmu_brief(14 downto 10) = "11000" THEN
                                            datatype <= "01"; -- Word for MMUSR
                                        ELSE
                                            datatype <= "10"; -- Longword for TC/TT0/TT1
                                        END IF;
                                        -- Keep setstate="01" from line 6097 - suppress fetch during transition
                                        next_micro_state <= pmmu_dn_read_wait;
                                    END IF;
                                ELSE
                                    -- Write to MMU
                                    set_exec(pmmu_wr) <= '1';
                                    IF (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011") THEN
                                        -- BUG #376 FIX: 64-bit CRP/SRP Dn write. The first write at
                                        -- pmove_decode uses stale reg_part (1-cycle pipeline delay).
                                        -- At pmove_dn_hi, set_exec(pmmu_wr) fires again with correct
                                        -- reg_part='1' (HI). At pmove_dn_lo, write LO word with
                                        -- reg_part='0'. The stale first write gets overwritten.
                                        datatype <= "10"; -- Longword
                                        next_micro_state <= pmove_dn_hi;
                                    ELSE
                                        -- BUG #361 FIX: Use setstate=01 + idle with fline_context_valid
                                        setstate <= "00";
                                        next_micro_state <= idle;
                                    END IF;
                                END IF;
                             ELSE
                                -- Memory EA modes
                                set(ea_build) <= '1';
                                IF pmmu_brief(14 downto 10) = "11000" THEN
                                    datatype <= "01"; -- Word for MMUSR
                                ELSE
                                    datatype <= "10"; -- Longword for others
                                END IF;
                                
                                -- Transition based on EA mode
                                -- BUG #377 FIX: Use pmmu_opcode throughout (fline_opcode_latch)
                                CASE pmmu_opcode(5 downto 3) IS
                                    WHEN "010" | "011" | "100" =>
                                        -- (An), (An)+, -(An)
                                        -- BUG #398 FIX: Clear ea_build for simple modes!
                                        -- The ea_build set at line 6460 persists as exec(ea_build)
                                        -- into pmove_mmu_to_mem_hi / pmove_mem_to_mmu_hi, causing
                                        -- the EA builder (line 3264) to re-fire and assert
                                        -- presub/postadd/get_ea_now again. This results in DOUBLE
                                        -- presub for -(An) and DOUBLE postadd for (An)+, corrupting
                                        -- the address register. Same fix as BUG #387 for mode "111".
                                        set(ea_build) <= '0';
                                        IF pmmu_brief(9)='1' THEN
                                            -- MMU -> Memory
                                            set_exec(pmmu_rd) <= '1';
                                            set(OP1addr) <= '1';
                                            IF pmmu_opcode(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN set(pmmu_dbl)<='1'; END IF;
                                            END IF;
                                            -- BUG #395 FIX: Set use_SP for A7 in ALL modes (An), (An)+, -(An)
                                            IF pmmu_opcode(2 downto 0)="111" THEN set(use_SP)<='1'; END IF;
                                            setstate <= "01";
                                            next_micro_state <= pmove_mmu_to_mem_hi;
                                        ELSE
                                            -- Memory -> MMU
                                            set(ea_data_OP1) <= '1';
                                            IF pmmu_opcode(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN set(pmmu_dbl)<='1'; END IF;
                                            END IF;
                                            -- BUG #395 FIX: Set use_SP for A7 in ALL modes (An), (An)+, -(An)
                                            IF pmmu_opcode(2 downto 0)="111" THEN set(use_SP)<='1'; END IF;
                                            -- BUG #395 FIX: set longaktion for 32-bit registers (TC/TT0/TT1/CRP/SRP)
                                            IF pmmu_brief(14 downto 10) /= "11000" THEN
                                                set(longaktion) <= '1';  -- All except MMUSR (16-bit)
                                            END IF;
                                            setstate <= "10";
                                            next_micro_state <= pmove_mem_to_mmu_hi;
                                        END IF;
                                    WHEN "101" =>
                                        -- (d16,An): Displacement word was fetched during pmove_decode
                                        -- Route to PMMU-specific state that uses fline_opcode_latch/pmmu_brief
                                        setstate <= "01";
                                        next_micro_state <= pmmu_ld_dAn1;
                                    WHEN "110" =>
                                        -- (d8,An,Xn): EA brief word was fetched during the
                                        -- state="00" bus cycle that ran alongside pmove_decode.
                                        -- It is now in last_opc_read.  Do NOT use getbrief here
                                        -- because state(1)='0' would capture data_read (the NEXT
                                        -- word on the bus) instead of last_opc_read.  The brief
                                        -- is latched from last_opc_read in the clocked process
                                        -- (search: "pmmu_ld_AnXn1 brief latch").
                                        setstate <= "01";
                                        next_micro_state <= pmmu_ld_AnXn1;
                                    WHEN "111" =>
                                        -- BUG #387 FIX: Override ea_build for mode "111" (absolute)
                                        -- pmmu_ld_nn is self-contained and handles address loading
                                        -- independently. With ea_build='1', exec(ea_build) carries
                                        -- into pmmu_ld_nn, causing the generic EA decoder (line 3218)
                                        -- to fire. For (xxx).L, this sets set(longaktion) at line 3285,
                                        -- corrupting memmask to "100001" during pass 1 and causing
                                        -- extra bus cycles that overrun PC by 4 bytes.
                                        set(ea_build) <= '0';
                                        IF pmmu_opcode(2 downto 0) = "000" THEN
                                            -- (xxx).W: Address fetched during pmove_decode
                                            -- Route to PMMU-specific state that uses fline_opcode_latch/pmmu_brief
                                            setstate <= "01";
                                            next_micro_state <= pmmu_ld_nn;
                                        ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                            -- (xxx).L: addr_hi fetched during pmove_decode, need state="00" to fetch addr_lo
                                            -- Route to PMMU-specific state that uses fline_opcode_latch/pmmu_brief
                                            -- Override the default setstate="01" (line 6147) - we need a bus
                                            -- cycle to fetch the second address word.
                                            setstate <= "00";
                                            next_micro_state <= pmmu_ld_nn;
                                        ELSE
                                            trap_illegal <= '1';
                                            trapmake <= '1';
                                        END IF;
                                    WHEN OTHERS =>
                                        trap_illegal <= '1';
                                        trapmake <= '1';
                                END CASE;
                             END IF;
                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "001" AND pmmu_brief(12 downto 10) = "000" THEN
                        -- PLOAD
                        -- BUG #393 FIX: Use pmmu_opcode for EA mode checks (same as BUG #377 for PMOVE)
                        -- BUG #393 FIX: Mode-specific dispatch through PMMU EA builders for correct
                        -- address computation. Previously used generic set(ea_build) which computed
                        -- addresses incorrectly for (d16,An), (d8,An,Xn), (xxx).W, (xxx).L modes.
                        -- Control alterable modes only: Dn/An/(An)+/-(An)/PC-rel/imm are illegal
                        IF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                           pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') THEN
                             trap_illegal <= '1';
                             trapmake <= '1';
                        ELSE
                             set_exec(pmmu_pload) <= '1';
                             datatype <= "10";
                             CASE pmmu_opcode(5 downto 3) IS
                                 WHEN "010" =>
                                     -- (An): EA is register value, goes directly to pload1
                                     setstate <= "01";
                                     next_micro_state <= pload1;
                                 WHEN "101" =>
                                     -- (d16,An): Route through PMMU EA builder for displacement
                                     setstate <= "01";
                                     next_micro_state <= pmmu_ld_dAn1;
                                 WHEN "110" =>
                                     -- (d8,An,Xn): Route through PMMU EA builder for index
                                     setstate <= "01";
                                     next_micro_state <= pmmu_ld_AnXn1;
                                 WHEN "111" =>
                                     -- Absolute addressing
                                     IF pmmu_opcode(2 downto 0) = "000" THEN
                                         -- (xxx).W: Address word already fetched
                                         setstate <= "01";
                                         next_micro_state <= pmmu_ld_nn;
                                     ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                         -- (xxx).L: Need state="00" to fetch second address word
                                         setstate <= "00";
                                         next_micro_state <= pmmu_ld_nn;
                                     ELSE
                                         trap_illegal <= '1';
                                         trapmake <= '1';
                                     END IF;
                                 WHEN OTHERS =>
                                     trap_illegal <= '1';
                                     trapmake <= '1';
                             END CASE;
                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "001" AND (pmmu_brief(12 downto 10) = "001" OR pmmu_brief(12 downto 10) = "100" OR pmmu_brief(12 downto 10) = "110") THEN
                        -- PFLUSH
                        set_exec(pmmu_pflush) <= '1';
                        IF pmmu_brief(12 downto 10) = "110" THEN
                             -- PFLUSH with EA: same mode-specific dispatch as PLOAD (BUG #393)
                             IF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                                pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                                (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') THEN
                                 trap_illegal <= '1';
                                 trapmake <= '1';
                             ELSE
                                 datatype <= "10";
                                 CASE pmmu_opcode(5 downto 3) IS
                                     WHEN "010" =>
                                         setstate <= "01";
                                         next_micro_state <= pflush1;
                                     WHEN "101" =>
                                         setstate <= "01";
                                         next_micro_state <= pmmu_ld_dAn1;
                                     WHEN "110" =>
                                         setstate <= "01";
                                         next_micro_state <= pmmu_ld_AnXn1;
                                     WHEN "111" =>
                                         IF pmmu_opcode(2 downto 0) = "000" THEN
                                             setstate <= "01";
                                             next_micro_state <= pmmu_ld_nn;
                                         ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                             setstate <= "00";
                                             next_micro_state <= pmmu_ld_nn;
                                         ELSE
                                             trap_illegal <= '1';
                                             trapmake <= '1';
                                         END IF;
                                     WHEN OTHERS =>
                                         trap_illegal <= '1';
                                         trapmake <= '1';
                                 END CASE;
                             END IF;
                        ELSE
                             setstate <= "01";
                             next_micro_state <= pflush1;
                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "100" THEN
                        -- PTEST
                        -- BUG #393 FIX: Mode-specific dispatch (same as PLOAD fix)
                        -- Control modes: Dn/An/(An)+/-(An)/imm are illegal (PC-rel allowed but not yet supported)
                        IF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                           pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') THEN
                             trap_illegal <= '1';
                             trapmake <= '1';
                        ELSE
                             set_exec(pmmu_ptest) <= '1';
                             datatype <= "10";
                             CASE pmmu_opcode(5 downto 3) IS
                                 WHEN "010" =>
                                     setstate <= "01";
                                     next_micro_state <= ptest1;
                                 WHEN "101" =>
                                     setstate <= "01";
                                     next_micro_state <= pmmu_ld_dAn1;
                                 WHEN "110" =>
                                     setstate <= "01";
                                     next_micro_state <= pmmu_ld_AnXn1;
                                 WHEN "111" =>
                                     IF pmmu_opcode(2 downto 0) = "000" THEN
                                         setstate <= "01";
                                         next_micro_state <= pmmu_ld_nn;
                                     ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                         setstate <= "00";
                                         next_micro_state <= pmmu_ld_nn;
                                     ELSE
                                         trap_illegal <= '1';
                                         trapmake <= '1';
                                     END IF;
                                 WHEN OTHERS =>
                                     trap_illegal <= '1';
                                     trapmake <= '1';
                             END CASE;
                        END IF;
                    ELSE
                        trap_1111 <= '1';
                        trapmake <= '1';
                    END IF;

                WHEN pmove_mem_to_mmu_hi =>

                    -- Memory->MMU: Write ea_data to PMMU register (HIGH word for 64-bit)
                    set_exec(pmmu_wr) <= '1';
                    -- Post-increment (An)+ must occur after the memory read completes
                    -- BUG FIX: Must use fline_opcode_latch, not opcode (same as pmove_mmu_to_mem_hi fix)
                    IF fline_opcode_latch(5 downto 3)="011" THEN
                        -- CRP/SRP are 64-bit: defer +8 update to pmove_mem_to_mmu_lo after the low word is read
                        IF (pmmu_brief(14 downto 10) /= "10010" AND pmmu_brief(14 downto 10) /= "10011") THEN
                            set(postadd) <= '1';
                            IF fline_opcode_latch(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        END IF;
                    END IF;
                    -- If CRP/SRP (64-bit), advance EA and read LOW word
                    -- F-Line Context: Use pmmu_brief for stable values
                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN  -- SRP or CRP
                        report "DEBUG_PMOVE_HI: CRP/SRP data_read=$" &
                               integer'image(conv_integer(data_read(31 downto 16))) & "_" &
                               integer'image(conv_integer(data_read(15 downto 0))) &
                               " addr=$" & integer'image(conv_integer(addr)) &
                               " state=" & integer'image(conv_integer(state))
                        severity note;
                        set_exec(mem_addsub) <= '1';
                        -- BUG #302 FIX: For (An)+ mode, do NOT set pmmu_addr_inc or OP1addr here!
                        -- For (An)+ mode, the +4 offset for LOW word is handled by memaddr_delta, not register update.
                        IF pmmu_ea_mode_latched(5 downto 3) /= "011" THEN  -- NOT (An)+ mode
                            set(pmmu_addr_inc) <= '1';
                            set(OP1addr) <= '1';
                        END IF;
                        datatype <= "10"; -- long
                        -- BUG C FIX: MUST set longaktion for 32-bit LO word read!
                        -- The HI word read consumed the longaktion from pmove_decode
                        -- (memmask shifted through "100001"->"000111"->"011111"->"111111").
                        -- Without re-asserting, the LO read defaults to word mode (16-bit only).
                        set(longaktion) <= '1';
                        setstate <= "10"; -- read LOW word from memory
                        next_micro_state <= pmove_mem_to_mmu_lo;
                    ELSE
                        -- 32-bit register (TC, TT0, TT1, MMUSR) - single transfer complete
                        -- BUG #347/351 FIX: Single Prefetch Cycle!
                        -- setstate="00" + nop ensures we run exactly one fetch cycle.
                        -- pflush1 caused double fetch.
                        -- BUG #389 FIX: exec_write_back is cleared in clocked process (line 2684-2694).
                        -- exec_write_back was set when transitioning to pmove_mem_to_mmu_hi (line 2687).
                        -- setendOPC requires (exec_write_back='0' OR state="11"), but state="10" from EA read.
                        -- This blocks setopcode from firing, causing decodeOPC='0' on next instruction,
                        -- which prevents ea_build from setting setnextpass for immediate operands.
                        setstate <= "00";

                        -- BUG #348 FIX: Must set datatype! Memory read defaulted to Word (01) or Byte (00).
                        IF pmmu_brief(14 downto 10) = "11000" THEN
                            datatype <= "01"; -- Word (16-bit) for MMUSR
                        ELSE
                            datatype <= "10"; -- Longword (32-bit) for TC/TT0/TT1
                        END IF;
                        -- BUG #346/360 FIX: Retire to idle with fetch enabled
                        setstate <= "00";
                        next_micro_state <= idle;
                    END IF;


                WHEN pmove_mmu_to_mem_hi =>
                    -- MMU -> memory write (high part for 64-bit CRP/SRP, or only part for 32-bit regs)
                    -- data_write_tmp sourced from pmmu_reg_rdat in write datapath
                    -- For CRP/SRP (64-bit), advance EA and read low part next
                    -- F-Line Context: Use pmmu_brief for stable values
                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN  -- SRP or CRP
                        -- CRP/SRP are 64-bit: write HI word here UNCONDITIONALLY for all EA modes.
                        -- Match bed1fad approach: ld_dAn1/ld_AnXn2 just transition here without writing,
                        -- so THIS state always does the HI write. pmmu_reg_part_d='1' was set in the
                        -- previous cycle (from next_micro_state=pmove_mmu_to_mem_hi condition).
                        set_exec(mem_addsub) <= '1';
                        set(pmmu_addr_inc) <= '1';  -- +4 address increment for LO write
                        set(OP1addr) <= '1';
                        datatype <= "10"; -- long (32-bit)
                        set(longaktion) <= '1';  -- BUG #379 FIX: Need longaktion for 32-bit bus write
                        set(hold_dwr) <= '1';  -- BUG #379 FIX: Hold data during bus write
                        setstate <= "11"; -- write CRP_H/SRP_H (32 bits)
                        set_exec(pmmu_rd) <= '1';  -- Keep PMMU selector active
                        next_micro_state <= pmove_mmu_to_mem_lo;
                    ELSE
                        -- BUG #9 FIX: Setup write for 32-bit PMMU registers (TC/TT0/TT1) or 16-bit MMUSR
                        -- BUG #92 FIX: MMUSR is 16-bit, not 32-bit! Check register selector.
                        -- BUG #197 FIX: For simple EA modes (An)/(An)+/-(An), must latch OP1addr here.
                        -- For displacement modes (d16,An), OP1addr was already latched in ld_dAn1 (line 4226).
                        -- Redundant set() calls are safe - last one before exec() wins.
                        set(OP1addr) <= '1';
                        IF pmmu_brief(14 downto 10) = "11000" THEN
                            datatype <= "01"; -- Word (16-bit) for MMUSR
                        ELSE
                            -- TC/TT0/TT1 are 32-bit
                            datatype <= "10"; -- Longword (32-bit)
                            -- BUG A FIX: MUST re-assert longaktion for 32-bit write!
                            -- longaktion from pmove_decode was killed by setstate="01"
                            -- at memmask priority chain (line 2397: setstate="01" -> memmask="111111"
                            -- overrides set(longaktion) -> memmask="100001"). Re-assert here
                            -- so that setstate="11" (line 6310) + set(longaktion) produces
                            -- memmask="100001" for a proper two-cycle 32-bit bus transfer.
                            -- (Previous BUG #190 comment was wrong - longaktion does NOT persist
                            -- across states when setstate="01" overrides it.)
                            set(longaktion) <= '1';
                        END IF;
                        -- Post-increment (An)+ must occur after the memory write completes
                        -- BUG FIX: Must use fline_opcode_latch, not opcode! By the time
                        -- pmove_mmu_to_mem_hi executes, opcode may have been overwritten
                        -- by prefetch of the next instruction, so (An)+/-(An) mode checks
                        -- on opcode(5:3) would never match.
                        IF fline_opcode_latch(5 downto 3)="011" THEN
                            set(postadd) <= '1';
                            IF fline_opcode_latch(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        -- -(An) register writeback: The set(presub) in pmove_decode (line 6122)
                        -- handles the register decrement. The EA-level presub logic also
                        -- asserts set(presub) when opcode(5:3)="100" in state="01".
                        -- No additional presub needed here — it would cause double-decrement.
                        END IF;
                        -- BUG #379 FIX: Hold data_write_tmp during longword bus write!
                        -- Without this, the second bus half-cycle (clkena_lw='1') re-evaluates
                        -- data_write_tmp. Since micro_state=pmmu_dn_read_wait (not pmove_mmu_to_mem_hi),
                        -- the ELSIF chain falls through to data_write_tmp<=OP2out, corrupting the LO word.
                        set(hold_dwr) <= '1';
                        setstate <= "11"; -- write
                        next_micro_state <= nop;
                    END IF;
                WHEN pmove_mmu_to_mem_lo =>
                    -- MMU -> memory write of low part (for CRP/SRP)
                    -- data_write_tmp sourced from pmmu_reg_rdat in write datapath
                    -- BUG #190 FIX: EA must be +4 from HI state! pmmu_addr_inc adds 4 to address.
                    -- The comment "Hold EA computed in HI transfer" was WRONG - HI state pmmu_addr_inc
                    -- didn't persist, so LO state was writing to same address as HI!
                    set(mem_addsub) <= '1';  -- Must use set(), not set_exec() - setexecOPC=0 in write state
                    set(OP1addr) <= '1';
                    set(pmmu_addr_inc) <= '1';  -- BUG #190 FIX: Add 4 to address for CRP_L/SRP_L write
                    datatype <= "10";  -- long write for low word
                    set_datatype <= "10";  -- propagate to exe_datatype for bus mask/datapath
                    -- BUG #190 V6: set(longaktion) is safe now with sequence check at line 1896!
                    -- The check prevents memmask reset when already in sequence ("100001"/"000111"/"011111"),
                    -- allowing the shift to progress while still initializing new longword writes.
                    set(longaktion) <= '1';  -- Required for 32-bit CRP_L/SRP_L write
                    -- Post-increment (An)+ for CRP/SRP must add 8 total; update here once using pmmu_dbl
                    -- BUG FIX: Must use fline_opcode_latch, not opcode (same as pmove_mmu_to_mem_hi fix)
                    IF fline_opcode_latch(5 downto 3)="011" THEN
                        set(postadd) <= '1';
                        set(pmmu_dbl) <= '1';
                        IF fline_opcode_latch(2 downto 0)="111" THEN
                            set(use_SP) <= '1';
                        END IF;
                    END IF;
                    -- BUG #379 FIX: Must hold data_write_tmp during bus write!
                    set(hold_dwr) <= '1';
                    set_exec(pmmu_rd) <= '1';     -- keep PMMU selector active for low word
                    setstate <= "11"; -- write low part
                    -- Return to idle to resume fetch/PC sequencing
                    next_micro_state <= idle;
                WHEN pmove_mem_to_mmu_lo =>
                    -- Memory->MMU: Low part read completed; write LOW word to MMU register
                    report "DEBUG_PMOVE_LO: data_read=$" &
                           integer'image(conv_integer(data_read(31 downto 16))) & "_" &
                           integer'image(conv_integer(data_read(15 downto 0))) &
                           " din=$" & integer'image(conv_integer(data_in)) &
                           " ldi=$" & integer'image(conv_integer(last_data_in(15 downto 0))) &
                           " addr=$" & integer'image(conv_integer(addr)) &
                           " mm=" & integer'image(conv_integer(memmask)) &
                           " st=" & integer'image(conv_integer(state)) &
                           " clk_lw=" & std_logic'image(clkena_lw)
                    severity note;
                    -- BUG #302 FIX: For (An)+ mode, DON'T use pmmu_addr_inc OR OP1addr.
                    -- OP1addr captures pmove_ea_latched with +6 offset baked in.
                    -- This avoids double-increment: offset from OP1addr + postadd+pmmu_dbl = +14 total (wrong!).
                    -- For (An)+ mode, reg_QA (base address) is used directly with postadd+pmmu_dbl for +8 increment.
                    set_exec(pmmu_wr) <= '1';
                    -- BUG #367 FIX: Removed set_exec(mem_addsub) that was causing memmask wait
                    -- cycles, keeping micro_state at pmove_mem_to_mmu_lo for extra cycles and
                    -- firing duplicate PMMU writes. No memory operation happens here - the LO
                    -- word data was already read during the pmove_mem_to_mmu_hi -> _lo transition.
                    IF pmmu_ea_mode_latched(5 downto 3) /= "011" THEN
                        -- Non-(An)+ modes: use OP1addr and pmmu_addr_inc for address offset
                        set(OP1addr) <= '1';
                        set(pmmu_addr_inc) <= '1';
                    ELSE
                        -- (An)+ mode: Don't use OP1addr or pmmu_addr_inc (offset handled by memaddr_delta).
                        -- Set post-increment for +8 register writeback from base (reg_QA).
                        set(postadd) <= '1';
                        set(pmmu_dbl) <= '1';
                        IF pmmu_ea_mode_latched(2 downto 0) = "111" THEN
                            set(use_SP) <= '1';
                        END IF;
                    END IF;
                    datatype <= "10";             -- long for proper memmask
                    set_datatype <= "10";         -- propagate to exe_datatype for bus mask
                    -- BUG #368 FIX: Use setstate="01" (stall) instead of "00" (fetch) to prevent:
                    -- 1. PC over-increment from premature setopcode firing
                    -- 2. Address routing corruption (setstate="00" bypasses PMOVE ELSIF in memaddr_delta chain,
                    --    causing LO read address to use TG68_PC_add instead of base+4)
                    -- The PMMU write still fires because pmmu_reg_we_d is gated by set_exec(pmmu_wr) + clkena_lw
                    -- (line 774), not setexecOPC.
                    -- BUG #381 FIX: Use idle instead of pmmu_dn_read_wait to allow setendOPC firing!
                    -- setendOPC requires next_micro_state=idle (line 2276). Without setendOPC, fline_context_valid
                    -- stays '1', causing subsequent CRP/SRP to reuse stale fline_opcode_latch.
                    -- BUG #389 FIX: exec_write_back cleared in clocked process (same as pmove_mem_to_mmu_hi).
                    setstate <= "00";
                    next_micro_state <= idle;

                -- PMMU instruction implementations
                WHEN ptest1 =>
                    -- PTEST: Test page translation (EA already built in pmove_decode)
                    -- MC68030 PTEST format (extension word):
                    -- - Bits 15-13: "100" (PTEST identifier)
                    -- - Bits 12-10: LEVEL (1-7, number of table levels to search)
                    -- - Bit 9: R/W (0=PTESTW/write, 1=PTESTR/read)
                    -- - Bit 8: A (address register return option)
                    -- - Bits 7-5: REG (address register number if A=1)
                    -- - Bits 4-0: FC specification (10XXX=immediate, 01XXX=Dn, 00000=SFC, 00001=DFC)
                    -- - Address from EA (already in OP1out)
                    -- PMMU module updates MMUSR with test results
                    -- BUG #133 FIX: Wait for PMMU walker to complete before proceeding
                    -- WhichAmiga does "ptestw #5,(a0),#7" then immediately "pmove mmusr,(sp)"
                    -- Without waiting, PMMU hasn't updated MMUSR yet, causing MMU detection failure
                    -- BUG #147 FIX: setstate="01" prevents extra PC increment when exiting ptest1
                    -- BUG #354 FIX: Must use setstate="00" for FINAL transition to force Fetch!
                    -- BUG #372 FIX: set_exec(pmmu_ptest) in pmove_decode never reaches exec because
                    -- setexecOPC requires setstate="00"/"01" but EA build uses setstate="10".
                    -- Use set(pmmu_ptest) here so exec picks it up via "exec <= set" on clkena_lw.
                    set(pmmu_ptest) <= '1';
                    set(OP1addr) <= '1';  -- BUG #393 FIX: Route addr to OP1out for pmmu_cmd_addr
                    setstate <= "01";  -- Default to "01" (stall) while waiting
                    -- synthesis translate_off
                    -- report "PTEST1: exec_pt=" & bit'image(exec(pmmu_ptest)) & " RDiA=" & integer'image(RDindex_A) &
                    --        " addr31=" & std_logic'image(addr(31)) & std_logic'image(addr(30)) &
                    --          std_logic'image(addr(29)) & std_logic'image(addr(28)) &
                    --          std_logic'image(addr(27)) & std_logic'image(addr(26)) &
                    --          std_logic'image(addr(25)) & std_logic'image(addr(24)) &
                    --        " mra31=" & std_logic'image(memaddr_reg(31)) & std_logic'image(memaddr_reg(30)) &
                    --          std_logic'image(memaddr_reg(29)) & std_logic'image(memaddr_reg(28)) &
                    --          std_logic'image(memaddr_reg(27)) & std_logic'image(memaddr_reg(26)) &
                    --          std_logic'image(memaddr_reg(25)) & std_logic'image(memaddr_reg(24)) &
                    --        " ub=" & bit'image(use_base) severity note;
                    -- synthesis translate_on
                    -- BUG FIX: Must wait for exec(pmmu_ptest) to be latched before checking busy.
                    -- Same timing issue as pload1: on first ptest1 cycle, exec(pmmu_ptest)='0',
                    -- so pmmu_ptest_req='0'. Without this guard, ptest1 exits immediately, and the
                    -- PMMU captures the wrong address (pmmu_addr_log_int instead of OP1out).
                    IF exec(pmmu_ptest) = '0' OR pmmu_busy = '1' THEN
                        next_micro_state <= ptest1;  -- Stay here until request sent and walker completes
                    ELSE
                        -- PTEST A-bit support via pmmu_ptest_a control signal
                        IF pmmu_brief(8)='1' THEN
                            set_exec(Regwrena) <= '1';
                            datatype <= "10"; -- Ensure longword write
                        END IF;
                        -- BUG #370 FIX: Use two-phase retirement via pmmu_dn_read_wait buffer.
                        -- Direct transition to idle with setstate="00" causes stale opcode:
                        -- state is "01" at the clock edge when ptest1 retires, so
                        -- opcode <= last_opc_read (stale extension word $9E15) instead of
                        -- opcode <= data_read (correct next instruction).
                        -- Routing through pmmu_dn_read_wait (excluded from setendOPC) lets
                        -- state transition to "00" first. Then when setendOPC fires in idle,
                        -- state is already "00" and opcode gets data_read (correct).
                        setstate <= "01";
                        next_micro_state <= pmmu_dn_read_wait;
                    END IF;

                WHEN pflush1 =>
                    -- PFLUSH: Flush pages from ATC (EA built in pmove_decode if needed)
                    -- MC68030 PFLUSH variants already decoded in pmove_decode:
                    -- - PFLUSHA:   brief(12:8)="00000" - flush all
                    -- - PFLUSHAN:  brief(12:8)="01000" - flush all non-global
                    -- - PFLUSH:    brief(12)='0', brief(11)='0' - flush with FC/EA
                    -- - PFLUSHN:   brief(12)='0', brief(11)='1' - flush non-global with FC/EA
                    -- PMMU module handles actual flush operation
                    -- BUG #147 FIX: setstate="01" prevents extra PC increment when exiting pflush1
                    -- Without this, setstate defaults to "00" (fetch), causing PC+2 over-increment
                    -- BUG #372 FIX: Propagate pflush request to exec via set layer
                    set(pmmu_pflush) <= '1';
                    set(OP1addr) <= '1';  -- BUG #393 FIX: Route addr to OP1out for pmmu_cmd_addr
                    setstate <= "01";  -- No fetch cycle - prevents PC over-increment
                    IF pmmu_busy = '1' THEN
                        next_micro_state <= pflush1;
                    ELSE
                        -- BUG #370 FIX: Use two-phase retirement (same as ptest1)
                        setstate <= "01";
                        next_micro_state <= pmmu_dn_read_wait;
                    END IF;

                WHEN pload1 =>
                    -- PLOAD: Load page into ATC (EA already built in pmove_decode)
                    -- MC68030 PLOAD format:
                    -- - FC from brief(12:10)
                    -- BUG #13 FIX: R/W from brief(9): 0=PLOADW (write), 1=PLOADR (read) - same as PTEST
                    -- - Address from EA (already in OP1out)
                    -- PMMU module performs page table walk and loads result into ATC
                    -- BUG #134 FIX: Wait for PMMU walker to complete before proceeding
                    -- PLOAD does a full page table walk, must wait for walker to finish
                    -- BUG #147 FIX: setstate="01" prevents extra PC increment when exiting pload1
                    -- BUG #372 FIX: Propagate pload request to exec via set layer
                    set(pmmu_pload) <= '1';
                    set(OP1addr) <= '1';  -- BUG #393 FIX: Route addr to OP1out for pmmu_cmd_addr
                    setstate <= "01";  -- No fetch cycle - prevents PC over-increment
                    -- BUG FIX: Must wait for exec(pmmu_pload) to be latched before checking busy.
                    -- On first pload1 cycle, set(pmmu_pload)='1' but exec(pmmu_pload)='0' (not yet in exec).
                    -- Without this guard, pload1 exits immediately (busy='0'), and by the time the PMMU
                    -- edge detector fires, micro_state has moved to pmmu_dn_read_wait, so pmmu_cmd_addr
                    -- switches from OP1out (correct EA) to pmmu_addr_log_int (wrong instruction fetch addr).
                    -- The guard keeps micro_state=pload1 for one extra cycle, ensuring the PMMU captures
                    -- the correct EA address from OP1out when the edge fires.
                    IF exec(pmmu_pload) = '0' OR pmmu_busy = '1' THEN
                        next_micro_state <= pload1;  -- Stay here until request sent and walker completes
                    ELSE
                        -- PLOAD A-bit support via pmmu_ptest_a control signal
                        IF pmmu_brief(8)='1' THEN
                            set_exec(Regwrena) <= '1';
                            datatype <= "10"; -- Ensure longword write
                        END IF;
                        -- BUG #370 FIX: Use two-phase retirement (same as ptest1)
                        setstate <= "01";
                        next_micro_state <= pmmu_dn_read_wait;
                    END IF;

                WHEN pmove_dn_hi =>
                    -- First transfer completed (HIGH word in/out of first register)
                    -- Now handle LOW word with next register (Dn+1)
                    -- BUG #198 FIX: Increment pmove_dn_regnum for source data from Dn+1
                    -- rf_dest_addr already handles Dn+1 for writes (line 1170)
                    -- But pmmu_dn_data needs pmove_dn_regnum incremented for reads (line 749)
                    -- BUG #122 FIX: Remove redundant set_writePCbig - already set in pmove_decode!
                    -- PMOVE instruction is only 4 bytes, PC increment already handled.
                    -- BUG #361 FIX: Do NOT set setstate here - let it inherit from pmove_decode
                    -- Setting setstate="01" here causes fetch suppression to carry into pmove_dn_lo
                    -- BUG #376 FIX: Both directions need signals at pmove_dn_hi.
                    IF pmmu_brief(9)='1' THEN
                        -- READ direction: Chain exec signals so LO word write
                        -- fires at pmove_dn_lo where rf_dest_addr correctly selects Dn+1.
                        -- MUST use set() not set_exec() because setexecOPC='0' when
                        -- next_micro_state != idle. exec <= set propagates unconditionally.
                        set(pmmu_rd) <= '1';
                        set(Regwrena) <= '1';
                    ELSE
                        -- WRITE direction: Fire HI word write here (deferred from pmove_decode).
                        -- reg_part_d='1' (HI) was set at pmove_decode and is now latched.
                        set_exec(pmmu_wr) <= '1';
                    END IF;
                    datatype <= "10"; -- Longword
                    next_micro_state <= pmove_dn_lo;

                WHEN pmove_dn_lo =>
                    -- Second transfer for 64-bit register (LOW word)
                    -- For PMOVE <MMU>,Dn: Read LOW word to Dn+1
                    -- For PMOVE Dn,<MMU>: Write LOW word from Dn+1
                    -- BUG FIX: Use pmmu_brief(9) for direction, NOT opcode(7)!
                    -- PMOVE uses extension word bit 9 for direction, same as first transfer
                    -- BUG #12 FIX: Swap direction - RW=0 means WRITE to MMU, RW=1 means READ from MMU
                    IF pmmu_brief(9)='0' THEN
                        -- PMOVE Dn+1,<MMU reg> - Read from Dn+1, write LOW word to MMU (pmmu_brief(9)=0, RW=0)
                        set_exec(pmmu_wr) <= '1';
                    ELSE
                        -- PMOVE <MMU reg>,Dn+1 - Read LOW word from MMU, write to Dn+1 (pmmu_brief(9)=1, RW=1)
                        -- BUG #376 FIX: LO word write already fires from exec(Regwrena)
                        -- and exec(pmmu_rd) set at pmove_dn_hi. micro_state=pmove_dn_lo
                        -- correctly routes rf_dest_addr to Dn+1. Just retire.
                        datatype <= "10"; -- Longword for LO word
                    END IF;
                    -- BUG #346/360 FIX: Retire to idle with fetch enabled
                    setstate <= "00";
                    next_micro_state <= idle;

                WHEN pmmu_dn_read_wait =>
                    -- BUG #303/353 FIX: Repurposed as general PMU retirement wait state.
                    -- Handle Dn register write-back for PMOVE <MMU>,Dn 32-bit read.
                    -- BUG #375 FIX: Also persist pmmu_rd to idle so regin=pmmu_reg_rdat
                    -- when exec(Regwrena) fires. Without this, regin falls through to ALUout.
                    -- BUG #388 FIX: Check set_exec(pmmu_rd) because set_exec doesn't propagate
                    -- to exec during micro-state transitions (setexecOPC='0'), and set(pmmu_rd)
                    -- doesn't persist across cycles.
                    IF exec(pmmu_rd)='1' OR set(pmmu_rd)='1' OR set_exec(pmmu_rd)='1' THEN
                        set_exec(pmmu_rd) <= '1';  -- Persist to idle
                        set_exec(Regwrena) <= '1';
                        -- Handle MMUSR (16-bit) vs TC/TT0/TT1 (32-bit)
                        IF pmmu_brief(14 downto 10) = "11000" THEN
                            datatype <= "01";
                            set_datatype <= "01";
                        ELSE
                            datatype <= "10";
                            set_datatype <= "10";
                        END IF;
                    END IF;
                    -- BUG #361 FIX: Enable fetch for final retirement
                    setstate <= "00";
                    next_micro_state <= idle;

				WHEN movep1 =>		-- MOVEP d(An)
					setdisp <= '1';	
					set(mem_addsub) <= '1';	
					set(mem_byte) <= '1';
					set(OP1addr) <= '1';		
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep2;
				WHEN movep2 =>		
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';	
					    set(OP1addr) <= '1';		
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep3;
				WHEN movep3 =>		
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';	
					    set(OP1addr) <= '1';		
						set(mem_byte) <= '1';
						IF opcode(7)='0' THEN
							setstate <= "10";
						ELSE
							setstate <= "11";
						END IF;
						next_micro_state <= movep4;
					ELSE	
						datatype <= "01";		--Word
					END IF;
				WHEN movep4 =>		
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep5;
				WHEN movep5 =>		
					datatype <= "10";		--Long
					
				WHEN mul1	=>		-- mulu
					IF opcode(15)='1' OR MUL_Mode=0 THEN
						set_rot_cnt <= "001110";
					ELSE
						set_rot_cnt <= "011110";
					END IF;
					setstate <="01";
					next_micro_state <= mul2;
				WHEN mul2	=>		-- mulu
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state <= mul_end1;

					ELSE	
						next_micro_state <= mul2;
					END IF;
				WHEN mul_end1	=>		-- mulu
					IF opcode(15)='0' THEN
						set(hold_OP2) <= '1';
					END IF;
					datatype <= "10";
					set(opcMULU) <= '1';
					IF opcode(15)='0' AND (MUL_Mode=1 OR MUL_Mode=2) THEN
						dest_2ndHbits <= '1';
						set(write_lowlong) <= '1';
						IF sndOPC(10)='1' THEN
							setstate <="01";
							next_micro_state <= mul_end2;
						END IF;	
						set(Regwrena) <= '1';
					END IF;
					datatype <= "10";
				WHEN mul_end2	=>		-- divu
					dest_2ndLbits <= '1';
					set(write_reminder) <= '1';
					set(Regwrena) <= '1';
					set(opcMULU) <= '1';

				WHEN div1	=>		-- divu
					setstate <="01";
					next_micro_state <= div2;
				WHEN div2	=>		-- divu
					IF (OP2out(31 downto 16)=x"0000" OR opcode(15)='1' OR DIV_Mode=0) AND OP2out(15 downto 0)=x"0000" THEN		--div zero
						set_Z_error <= '1';
					ELSE
						next_micro_state <= div3;
					END IF;
					set(ld_rot_cnt) <= '1'; 
					setstate <="01";
				WHEN div3	=>		-- divu
					IF opcode(15)='1' OR DIV_Mode=0 THEN
						set_rot_cnt <= "001101";
					ELSE
						set_rot_cnt <= "011101";
					END IF;
					setstate <="01";
					next_micro_state <= div4;
				WHEN div4	=>		-- divu
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state <= div_end1;
					ELSE	
						next_micro_state <= div4;
					END IF;
				WHEN div_end1	=>		-- divu
					IF z_error='0' AND set_V_Flag='0' THEN
						set(Regwrena) <= '1';
					END IF;
					IF opcode(15)='0' AND (DIV_Mode=1 OR DIV_Mode=2) THEN
						dest_2ndLbits <= '1';
						set(write_reminder) <= '1';
						next_micro_state <= div_end2;
						setstate <="01";
					END IF;
					set(opcDIVU) <= '1';
					datatype <= "10";
				WHEN div_end2	=>		-- divu
					IF exec(Regwrena)='1' THEN
						set(Regwrena) <= '1';
					ELSE	
						set(no_Flags) <= '1';
					END IF;
					dest_2ndHbits <= '1';
					set(opcDIVU) <= '1';
					
				WHEN rota1	=>
					IF OP2out(5 downto 0)/="000000" THEN
						set_rot_cnt <= OP2out(5 downto 0);
					ELSE
						set_exec(rot_nop) <= '1';
					END IF;
					
				WHEN bf1 =>
					setstate <="10";

				WHEN OTHERS => NULL;
			END CASE;
			-- BUG #323 FIX: Deferred writeback REMOVED. The register write for
			-- MOVES mem->CPU is now performed directly in the register file process
			-- during the bus read cycle (state="10"), bypassing the exec pipeline.
			-- The old deferred writeback at state="00" conflicted with the next
			-- instruction's decode (set signals overriding MOVEA, etc).
			IF moves_active = '1' AND (micro_state = moves0 OR micro_state = moves1 OR moves_writeback_pending = '1') THEN
				set(no_Flags) <= '1';
			END IF;
		END PROCESS;

-----------------------------------------------------------------------------
-- PMMU PMOVE micro-state
-----------------------------------------------------------------------------
  -- PMMU handled within main decode state machine (WHEN pmove_decode)

-----------------------------------------------------------------------------
-- MOVEC
-----------------------------------------------------------------------------
  process (clk, SFC, DFC, VBR, CACR, CAAR, USP, SSP, MSP, ISP, brief, pmmu_reg_rdat)
  begin
	-- all other hexa codes should give illegal isntruction exception
	if rising_edge(clk) then
	  if Reset = '1' then
		VBR <= (others => '0');
		CACR <= (others => '0');
		CAAR <= (others => '0');
		USP <= (others => '0');   -- BUG #18: Initialize USP
		SSP <= (others => '0');   -- BUG #18: Initialize SSP
		MSP <= (others => '0');   -- BUG #18: Initialize MSP
		ISP <= (others => '0');   -- BUG #18: Initialize ISP
	  elsif clkena_lw = '1' and exec(movec_wr) = '1' then
		case brief(11 downto 0) is
		  when X"000" => SFC <= reg_QA(2 downto 0); -- SFC -- 68010+
		  when X"001" => DFC <= reg_QA(2 downto 0); -- DFC -- 68010+
		  when X"002" =>
		    -- Write to CACR with proper MC68030 behavior
		    -- MC68030 uses CACR bits for cache invalidation (no CINV/CPUSH instructions):
		    --   Bit 0: EI - Enable Instruction Cache (sticky)
		    --   Bit 1: FI - Freeze Instruction Cache (sticky)
		    --   Bit 2: CEI - Clear Entry in I-Cache (self-clearing)
		    --   Bit 3: CI - Clear Instruction Cache (self-clearing)
		    --   Bit 4: IBE - Instruction Burst Enable (sticky)
		    --   Bit 8: ED - Enable Data Cache (sticky)
		    --   Bit 9: FD - Freeze Data Cache (sticky)
		    --   Bit 10: CED - Clear Entry in D-Cache (self-clearing)
		    --   Bit 11: CD - Clear Data Cache (self-clearing)
		    --   Bit 12: DBE - Data Burst Enable (sticky)
		    --   Bit 13: WA - Write Allocate (sticky)
		    -- Self-clearing bits MUST be written to trigger cache_inv_req
		    -- They auto-clear on the next clkena_lw cycle
		    CACR(4 downto 0) <= reg_QA(4 downto 0);   -- EI, FI, CEI, CI, IBE
		    CACR(7 downto 5) <= (others => '0');       -- Reserved bits
		    CACR(13 downto 8) <= reg_QA(13 downto 8); -- ED, FD, CED, CD, DBE, WA
		    CACR(31 downto 14) <= (others => '0');     -- Reserved bits
		  when X"800" => USP <= reg_QA; -- BUG #18: USP -- 68010+
		  when X"801" => VBR <= reg_QA; -- 68010+
		  when X"802" => CAAR <= reg_QA; -- CAAR -- 68020+
		  when X"803" => MSP <= reg_QA; -- BUG #18: MSP -- 68020+
		  when X"804" => ISP <= reg_QA; -- BUG #18: ISP -- 68020+
		  when others => NULL;
		end case;
  elsif clkena_lw = '1' then
    -- BUG #18: Handle stack pointer save operations during mode switches
    if exec(to_USP) = '1' then
      USP <= reg_QA;
    end if;
    if exec(to_SSP) = '1' then
      SSP <= reg_QA;
    end if;
    if exec(to_MSP) = '1' then
      MSP <= reg_QA;
    end if;
    if exec(to_ISP) = '1' then
      ISP <= reg_QA;
    end if;
    -- Auto-clear self-clearing command bits after they've been set
    -- MC68030 spec: bits 2 (CEI), 3 (CI), 10 (CED), 11 (CD) are self-clearing
    if CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1' then
      CACR(2) <= '0';   -- Clear CEI (Clear Entry in Instruction Cache)
      CACR(3) <= '0';   -- Clear CI (Clear Instruction Cache)
      CACR(10) <= '0';  -- Clear CED (Clear Entry in Data Cache)
      CACR(11) <= '0';  -- Clear CD (Clear Data Cache)
    end if;
	  end if;
	end if;

	movec_data <= (others => '0');
	case brief(11 downto 0) is
		when X"000" => movec_data <= "00000000000000000000000000000" & SFC;
		when X"001" => movec_data <= "00000000000000000000000000000" & DFC;
	  when X"002" => movec_data <= CACR; -- CACR full 32-bit read
	  when X"800" => movec_data <= USP;  -- BUG #18: USP -- 68010+
	  when X"801" => movec_data <= VBR;  -- 68010+
	  when X"802" => movec_data <= CAAR; -- 68020+
	  when X"803" => movec_data <= MSP;  -- BUG #18: MSP -- 68020+
	  when X"804" => movec_data <= ISP;  -- BUG #18: ISP -- 68020+
	  when others => NULL;
	end case;
  end process;


  CACR_out <= CACR;
  VBR_out <= VBR;

-----------------------------------------------------------------------------
-- PMMU (68030) PMOVE register moves (Dn + memory read forms)
-----------------------------------------------------------------------------

  -- Drive PMMU register interface during PMOVE execution
  process(clk)
    -- variable sel   : std_logic_vector(3 downto 0);
  begin
    if rising_edge(clk) then
      if Reset = '1' then
        -- BUG #19 FIX: pmmu_reg_we_d and pmmu_reg_re_d are combinational (lines 564/568), don't reset them here
        -- pmmu_reg_we_d   <= '0';  -- REMOVED - combinational signal
        -- pmmu_reg_re_d   <= '0';  -- REMOVED - combinational signal
        pmmu_reg_sel_d  <= (others => '0');
        pmmu_reg_wdat_d <= (others => '0');
        pmmu_reg_part_d <= '0';
        pmmu_reg_fd_d   <= '0';
        -- BUG #199 FIX: Initialize pmove_ea_latched
        pmove_ea_latched <= (others => '0');
      elsif clkena_in='1' then
        -- BUG #19 FIX: pmmu_reg_we_d and pmmu_reg_re_d are combinational, don't drive them here
        -- Clear PMMU control signals by default (single-cycle pulses)
        -- pmmu_reg_we_d   <= '0';  -- REMOVED - combinational signal
        -- pmmu_reg_re_d   <= '0';  -- REMOVED - combinational signal

        -- BUG #199 FIX: Capture EA for EVERY PMOVE memory write operation!
        -- Each PMOVE must latch its own computed EA, not reuse a stale value from first PMOVE.
        -- BUG #290 FIX: Capture EA on TRANSITION from HI to LO
        -- Problem: The previous logic used memmaskmux(3)='0' to detect second word, but by
        -- the time memmaskmux(3)='0', micro_state has already transitioned to LO!
        -- Instead, capture on the transition cycle when next_micro_state=LO and micro_state=HI.
        -- At this point, addr contains the base address (first word of HI was just written).
        -- Capture addr directly (it's the base) and add 4 for LO's start address.
        if ((next_micro_state = pmove_mmu_to_mem_lo and micro_state = pmove_mmu_to_mem_hi) or
            (next_micro_state = pmove_mem_to_mmu_lo and micro_state = pmove_mem_to_mmu_hi)) and
            pmove_ea_captured = '0' then
            -- addr is the base address (e.g., 0x1012 for PMOVE CRP,($12,A0))
            -- LO should read/write at base+4 (e.g., 0x1016)
            report "DEBUG_EA_CAPTURE: addr=$" & integer'image(conv_integer(addr)) &
                   " ea_latched will be $" & integer'image(conv_integer(addr + 4))
            severity note;
            pmove_ea_latched <= addr + 4;
            pmove_ea_captured <= '1';
        end if;
        -- Clear flag when instruction completes
        if setendOPC = '1' or trapmake = '1' then
            pmove_ea_captured <= '0';
        end if;

        -- PMMU instruction handling (only on 68030)
        -- Handle both set() for immediate execution and exec() for deferred execution
        -- BUG #109 FIX: Only latch pmmu_reg_wdat_d during WRITE operations, NOT READ!
        -- During PMOVE TT0,D1 READ, pmmu_src_data = pmmu_dn_data = D1's value, which
        -- incorrectly corrupts the write data latch with the destination register's value.
        -- This caused TT0 to get corrupted with D1's value on subsequent operations.
        -- BUG #111 V3 FIX: OUTER condition must check set_exec() layers!
        -- On first PMOVE after reset, set_exec(pmmu_wr) is assigned but exec(pmmu_wr) is still 0.
        -- If we only check exec(pmmu_wr), the latch block never executes on first iteration,
        -- so pmmu_reg_sel_d stays at 0 and the write fails.
        -- Must include set_exec(pmmu_wr) and set_exec(pmmu_rd) to catch first iteration!
        -- BUG #376 FIX: Also include set(pmmu_rd) and set(pmmu_wr) in outer condition!
        -- 64-bit Dn read path uses set(pmmu_rd) (not set_exec) because setexecOPC='0'
        -- when next_micro_state != idle. Without this, reg_part_d/reg_sel_d setup is
        -- skipped entirely, causing stale reg_part and wrong HI/LO word selection.
        if CPU(1)='1' AND (set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR set(pmmu_wr)='1' OR set(pmmu_rd)='1' OR exec(pmmu_wr)='1' OR exec(pmmu_rd)='1') then
          -- Latch source data only when actually WRITING to PMMU to ensure correct value
          pmmu_reg_wdat_d <= pmmu_src_data;
          -- MMU registers (TT0, TT1, MMUSR, etc.) are PMOVE-only on MC68030
          -- MOVEC attempts to access these registers trigger illegal instruction exceptions

          -- PMOVE instruction handling (only if MOVEC is not active to avoid conflicts)
          -- BUG #111 V2 FIX: Also check set_exec(pmmu_wr) to catch first iteration!
          -- On first iteration, set_exec(pmmu_wr) is set but set()/exec() are still 0,
          -- so pmmu_reg_sel_d doesn't get set, causing write to fail.
          -- F-Line Context: Use pmmu_brief for stable values
          if set_exec(pmmu_wr) = '1' OR set(pmmu_wr) = '1' OR exec(pmmu_wr) = '1' then
            -- PMOVE Dn -> <MMU reg>
            if pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011" OR pmmu_brief(14 downto 10) = "10000" OR
               pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" OR pmmu_brief(14 downto 10) = "11000" then
              pmmu_reg_sel_d  <= pmmu_brief(14 downto 10);
              -- For CRP/SRP choose part: HIGH word first, LOW word second
              -- BUG #188 FIX: Use next_micro_state for early setup (same fix as READ path)
              if (pmmu_brief(14 downto 10) = "10010") or (pmmu_brief(14 downto 10) = "10011") then
                -- BUG #389 V2 FIX: Gate reg_part_d on clkena_lw, not just clkena_in.
                -- This process runs on clkena_in='1', but during bus wait states (clkena_lw='0'),
                -- next_micro_state already shows the NEXT transition (e.g., pmove_mem_to_mmu_lo),
                -- causing reg_part_d to be prematurely overwritten to '0' before the PMMU write
                -- (which requires clkena_lw='1') can read the correct '1' value.
                if clkena_lw='1' then
                if micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';  -- LOW word (mem EA second read)
                -- BUG #376 FIX: Also force LOW for Dn 64-bit write LO word
                elsif micro_state = pmove_dn_lo OR next_micro_state = pmove_dn_lo then
                  pmmu_reg_part_d <= '0';  -- LOW word (Dn 64-bit second transfer)
                elsif micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';  -- HIGH word (mem EA first read, Dn first transfer)
                else
                  pmmu_reg_part_d <= '0';  -- LOW word (default)
                end if;
                end if; -- clkena_lw
              end if;
              -- Check if this is PMOVEFD (Flush Disable): pmmu_brief(15:13)="001" AND pmmu_brief(9:8)="01" (R/W = 0 & FD=1)
              -- BUG FIX: Check bits 9-8 (not 12-8) to avoid register selector overlap in bits 14-10
              if (pmmu_brief(15 downto 13) = "000" or pmmu_brief(15 downto 13) = "010") and pmmu_brief(8) = '1' then
                pmmu_reg_fd_d <= '1';  -- PMOVEFD - disable ATC flush
              else
                pmmu_reg_fd_d <= '0';  -- Normal PMOVE - flush ATC
              end if;
              -- BUG #19 FIX: pmmu_reg_we_d is combinational (line 564), don't drive it here
              -- pmmu_reg_we_d   <= '1';  -- REMOVED - combinational signal
            end if;
          end if;

          -- BUG #125 FIX: Also check set_exec(pmmu_rd) to match pmmu_reg_re_d (line 602)!
          -- pmove_decode (line 4796), pmove_mmu_to_mem_hi (line 4929), and pmove_dn_lo (line 5042)
          -- all use set_exec(pmmu_rd). Without this, pmmu_reg_sel_d gets stale value and
          -- all subsequent reads return the same wrong register ("same values in all MMU registers")!
          -- F-Line Context: Use pmmu_brief for stable values
          if set(pmmu_rd) = '1' OR exec(pmmu_rd) = '1' OR set_exec(pmmu_rd) = '1' then
            -- PMOVE <MMU reg> -> Dn or memory
            if pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011" OR pmmu_brief(14 downto 10) = "10000" OR
               pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" OR pmmu_brief(14 downto 10) = "11000" then
              pmmu_reg_sel_d <= pmmu_brief(14 downto 10);
              -- For CRP/SRP choose part: HIGH word first, LOW word second
              -- BUG #188 FIX: Use next_micro_state to set pmmu_reg_part_d ONE CYCLE EARLIER!
              -- pmmu_reg_part_d is REGISTERED, but pmmu_reg_rdat is COMBINATIONAL.
              -- When micro_state transitions to pmove_mmu_to_mem_lo, pmmu_reg_part_d still has
              -- the OLD value ('1') from pmove_mmu_to_mem_hi, causing pmmu_reg_rdat to return
              -- the HIGH word instead of LOW word (duplicating high word to both locations).
              -- By checking next_micro_state, we set pmmu_reg_part_d='0' one cycle early,
              -- so it's already correct when we enter pmove_mmu_to_mem_lo.
              if (pmmu_brief(14 downto 10) = "10010") or (pmmu_brief(14 downto 10) = "10011") then
                -- BUG #389 V2 FIX: Gate reg_part_d on clkena_lw (same fix as write path)
                if clkena_lw='1' then
                if micro_state = pmove_mmu_to_mem_lo OR next_micro_state = pmove_mmu_to_mem_lo then
                  pmmu_reg_part_d <= '0';  -- Force LOW part in low write state (or about to enter)
                elsif micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';  -- Force LOW part for memory->MMU low read
                -- BUG #376 FIX: Also force LOW when transitioning to pmove_dn_lo for 64-bit Dn read.
                -- Without this, pmove_dn_hi keeps reg_part_d='1' (HI) and the LO word read
                -- at pmove_dn_lo gets the HI word data instead.
                elsif micro_state = pmove_dn_lo OR next_micro_state = pmove_dn_lo then
                  pmmu_reg_part_d <= '0';  -- Force LOW part for Dn 64-bit read LO word
                elsif micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mmu_to_mem_hi OR next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';  -- HIGH word (first transfer)
                else
                  pmmu_reg_part_d <= '0';  -- LOW word (second transfer)
                end if;
                end if; -- clkena_lw
              end if;
              -- BUG FIX: PMOVE reads never flush ATC (MC68030 spec: only writes can flush)
              -- Always set flush disable for read operations
              pmmu_reg_fd_d <= '1';
              -- BUG #19 FIX: pmmu_reg_re_d is combinational (line 568), don't drive it here
              -- pmmu_reg_re_d  <= '1';  -- REMOVED - combinational signal
            end if;
          end if;

          -- BUG #189 FIX: Early reg_part setup for 64-bit CRP/SRP registers
          -- The pmmu_reg_part_d updates inside pmmu_wr/pmmu_rd blocks run TOO LATE!
          -- By the time set_exec(pmmu_wr)='1' fires, we're already in the write state
          -- and pmmu_reg_part_d still has the OLD value from the previous cycle.
          -- Solution: Set pmmu_reg_part_d based on next_micro_state BEFORE entering
          -- the write/read state, independent of pmmu_wr/pmmu_rd signals.
          -- This runs AFTER the pmmu_wr/pmmu_rd blocks, so it takes priority (last assignment wins).
          -- BUG #199 FIX: Remove the entire BUG #189 fix block - it conflicts with the pmmu_rd/pmmu_wr blocks above
          -- The pmmu_rd block (lines 5948-5959) already handles pmmu_reg_part_d correctly.
          -- The BUG #189 fix was trying to solve a problem that doesn't exist if the pmmu_rd block works.

        end if;

        -- BUG #389 V2 FIX: Early reg_part setup for CRP/SRP memory mode writes.
        -- The reg_part setup inside the set_exec(pmmu_wr) gate (above) doesn't fire during
        -- pmove_decode for memory mode because pmmu_wr is not set at decode time.
        -- pmmu_reg_part_d is REGISTERED, so the PMMU always sees the value from the
        -- PREVIOUS clkena_lw edge. Without early setup, the PMMU sees stale reg_part
        -- during pmove_mem_to_mmu_hi and writes to CRP_L instead of CRP_H.
        -- Fix: Set reg_part_d based on next_micro_state one cycle early.
        -- This runs AFTER the pmmu_wr/rd blocks, so last-assignment-wins overrides them.
        -- CRITICAL: Must gate on clkena_lw='1', NOT just clkena_in='1'!
        -- During bus wait states (clkena_in='1', clkena_lw='0'), next_micro_state already
        -- shows the NEXT transition (e.g., pmove_mem_to_mmu_lo), which would prematurely
        -- overwrite reg_part_d to '0' before the PMMU write fires (requires clkena_lw='1').
        if clkena_lw='1' then
        if CPU(1)='1' and (pmmu_brief(14 downto 10) = "10010" or pmmu_brief(14 downto 10) = "10011") then
            if next_micro_state = pmove_mem_to_mmu_hi or next_micro_state = pmove_mmu_to_mem_hi then
                pmmu_reg_part_d <= '1';  -- HI word will be accessed next cycle
            elsif next_micro_state = pmove_mem_to_mmu_lo or next_micro_state = pmove_mmu_to_mem_lo then
                pmmu_reg_part_d <= '0';  -- LO word will be accessed next cycle
            end if;
        end if;
        end if; -- clkena_lw
      end if;
    end if;
  end process;
-----------------------------------------------------------------------------
-- Conditions
-----------------------------------------------------------------------------
PROCESS (exe_opcode, Flags)
	BEGIN
		CASE exe_opcode(11 downto 8) IS
			WHEN X"0" => exe_condition <= '1';
			WHEN X"1" => exe_condition <= '0';
			WHEN X"2" => exe_condition <=  NOT Flags(0) AND NOT Flags(2);
			WHEN X"3" => exe_condition <= Flags(0) OR Flags(2);
			WHEN X"4" => exe_condition <= NOT Flags(0);
			WHEN X"5" => exe_condition <= Flags(0);
			WHEN X"6" => exe_condition <= NOT Flags(2);
			WHEN X"7" => exe_condition <= Flags(2);
			WHEN X"8" => exe_condition <= NOT Flags(1);
			WHEN X"9" => exe_condition <= Flags(1);
			WHEN X"a" => exe_condition <= NOT Flags(3);
			WHEN X"b" => exe_condition <= Flags(3);
			WHEN X"c" => exe_condition <= (Flags(3) AND Flags(1)) OR (NOT Flags(3) AND NOT Flags(1));
			WHEN X"d" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1));
			WHEN X"e" => exe_condition <= (Flags(3) AND Flags(1) AND NOT Flags(2)) OR (NOT Flags(3) AND NOT Flags(1) AND NOT Flags(2));
			WHEN X"f" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1)) OR Flags(2);
			WHEN OTHERS => NULL;
		END CASE;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- Movem
-----------------------------------------------------------------------------
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				movem_actiond <= exec(movem_action); 
				IF decodeOPC='1' THEN
					sndOPC <= data_read(15 downto 0);
				ELSIF exec(movem_action)='1' OR set(movem_action) ='1' THEN
					CASE movem_regaddr IS
						WHEN "0000" => sndOPC(0)  <= '0';
						WHEN "0001" => sndOPC(1)  <= '0';
						WHEN "0010" => sndOPC(2)  <= '0';
						WHEN "0011" => sndOPC(3)  <= '0';
						WHEN "0100" => sndOPC(4)  <= '0';
						WHEN "0101" => sndOPC(5)  <= '0';
						WHEN "0110" => sndOPC(6)  <= '0';
						WHEN "0111" => sndOPC(7)  <= '0';
						WHEN "1000" => sndOPC(8)  <= '0';
						WHEN "1001" => sndOPC(9)  <= '0';
						WHEN "1010" => sndOPC(10) <= '0';
						WHEN "1011" => sndOPC(11) <= '0';
						WHEN "1100" => sndOPC(12) <= '0';
						WHEN "1101" => sndOPC(13) <= '0';
						WHEN "1110" => sndOPC(14) <= '0';
						WHEN "1111" => sndOPC(15) <= '0';
						WHEN OTHERS => NULL;
					END CASE;
				END IF;
			END IF;
		END IF;
	END PROCESS;
	
PROCESS (sndOPC, movem_mux)
	BEGIN
		movem_regaddr <="0000";
		movem_run <= '1';
		IF sndOPC(3 downto 0)="0000" THEN
			IF sndOPC(7 downto 4)="0000" THEN
				movem_regaddr(3) <= '1';
				IF sndOPC(11 downto 8)="0000" THEN
					IF sndOPC(15 downto 12)="0000" THEN
						movem_run <= '0';
					END IF;
					movem_regaddr(2) <= '1';
					movem_mux <= sndOPC(15 downto 12);
				ELSE
					movem_mux <= sndOPC(11 downto 8);
				END IF;
			ELSE
				movem_mux <= sndOPC(7 downto 4);
				movem_regaddr(2) <= '1';
			END IF;
		ELSE
			movem_mux <= sndOPC(3 downto 0);
		END IF;
		IF movem_mux(1 downto 0)="00" THEN
			movem_regaddr(1) <= '1';
			IF movem_mux(2)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;	
		ELSE		
			IF movem_mux(0)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;	
		END  IF;
	END PROCESS;

-- MC68030 address routing: direct when MMU disabled, translated when enabled
addr_out <= pmmu_addr_log_int when pmmu_tc_en = '0' else pmmu_addr_phys_int;

-- DEBUG: Output supervisor mode tracking signals for analysis
-- Convert bit type to std_logic for output
debug_SVmode <= '1' when SVmode='1' else '0';
debug_preSVmode <= '1' when preSVmode='1' else '0';
debug_FlagsSR_S <= FlagsSR(5);
debug_changeMode <= '1' when set(changeMode)='1' else '0';
debug_setopcode <= '1' when setopcode='1' else '0';
debug_exec_directSR <= '1' when exec(directSR)='1' else '0';
debug_exec_to_SR <= '1' when exec(to_SR)='1' else '0';

-- DEBUG: PMOVE Dn simplified mechanism (BUG #70)
debug_pmove_dn_mode <= pmove_dn_mode;
debug_pmove_dn_regnum <= pmove_dn_regnum;

-- DEBUG: BUG #213 - Export internal opcode being decoded
debug_opcode <= opcode;

-- DEBUG: BUG #213 - Pipeline debugging
debug_state <= state;
debug_setstate <= setstate;
debug_last_opc_read <= last_opc_read;
debug_data_read <= data_read;
debug_direct_data <= '1' when direct_data='1' else '0';
debug_setnextpass <= '1' when setnextpass='1' else '0';

-- DEBUG: BUG #213 - Address generation and opcode capture
debug_TG68_PC <= TG68_PC;
debug_memaddr_reg <= memaddr_reg;
debug_memaddr_delta <= memaddr_delta;
debug_oddout <= oddout;
debug_decodeOPC <= '1' when decodeOPC='1' else '0';

-- DEBUG: MOVES instruction trace signals
debug_brief <= brief;
debug_moves_bus_pending <= moves_bus_pending;
debug_moves_writeback_pending <= moves_writeback_pending;
debug_clkena_lw <= clkena_lw;
debug_regfile_d0 <= regfile(0);
debug_regfile_a0 <= regfile(8);

-- DEBUG: F-line exception diagnosis
debug_fline_context_valid <= fline_context_valid;
debug_trap_1111 <= '1' when trap_1111='1' else '0';
debug_trapmake <= '1' when trapmake='1' else '0';
debug_pmmu_brief <= pmmu_brief;

-- DEBUG: Address computation diagnosis
debug_use_base <= '1' when use_base='1' else '0';
debug_rf_source_addr <= rf_source_addr;
debug_pmove_ea_latched <= pmove_ea_latched;
debug_reg_QA <= reg_QA;

-- DEBUG: Extended debug port assignments
debug_last_data_read <= last_data_read;
debug_last_opc_pc <= last_opc_pc;
debug_getbrief <= '1' when getbrief='1' else '0';
debug_get_2ndopc <= '0';
debug_fline_brief_pending <= '0';
debug_fline_opcode_pc <= fline_opcode_pc;
debug_exe_PC <= exe_pc;
debug_memaddr_delta_rega <= memaddr_delta_rega;
debug_memaddr_delta_regb <= memaddr_delta_regb;
debug_addsub_q <= addsub_q;
debug_memmaskmux <= memmaskmux;
debug_fline_opcode_latch <= fline_opcode_latch;
debug_pmmu_ea_mode_latched <= pmmu_ea_mode_latched;
debug_exec_direct_delta <= '1' when exec(direct_delta)='1' else '0';
debug_exec_directPC <= '1' when exec(directPC)='1' else '0';
debug_exec_mem_addsub <= '1' when exec(mem_addsub)='1' else '0';
debug_set_addrlong <= '1' when set(addrlong)='1' else '0';
debug_mdelta_src <= x"00";
debug_pc_brw <= '1' when TG68_PC_brw='1' else '0';
debug_pc_word <= '1' when TG68_PC_word='1' else '0';
debug_regfile_d1 <= regfile(1);
debug_regfile_d2 <= regfile(2);
debug_regfile_d3 <= regfile(3);
debug_regfile_d4 <= regfile(4);
debug_regfile_d5 <= regfile(5);
debug_regfile_d6 <= regfile(6);
debug_regfile_d7 <= regfile(7);
debug_regfile_a1 <= regfile(9);
debug_regfile_a2 <= regfile(10);
debug_regfile_a3 <= regfile(11);
debug_regfile_a4 <= regfile(12);
debug_regfile_a5 <= regfile(13);
debug_regfile_a6 <= regfile(14);
debug_regfile_a7 <= regfile(15);
debug_regfile_we <= '1' when (Lwrena='1' or Wwrena='1' or Bwrena='1') else '0';
debug_regfile_waddr <= rf_dest_addr;
debug_regfile_wdata <= regin;
debug_trap_illegal <= '1' when trap_illegal='1' else '0';
debug_trap_priv <= '1' when trap_priv='1' else '0';
debug_trap_addr_error <= '1' when trap_addr_error='1' else '0';
debug_trap_berr <= '1' when trap_berr='1' else '0';
debug_trap_mmu_berr <= '1' when trap_mmu_berr='1' else '0';
debug_trap_vector <= trap_vector;
debug_pc_add <= TG68_PC_add;
debug_pc_dataa <= PC_dataa;
debug_pc_datab <= PC_datab;
debug_pmmu_busy <= pmmu_busy;
debug_micro_state <= micro_states'pos(micro_state);
debug_next_micro_state <= micro_states'pos(next_micro_state);
debug_memmask <= memmask;
debug_sndOPC <= sndOPC;
debug_pmmu_reg_we <= pmmu_reg_we_d;
debug_pmmu_reg_re <= pmmu_reg_re_d;
debug_pmmu_reg_sel <= pmmu_reg_sel_int;
debug_pmmu_reg_wdat <= pmmu_reg_wdat_d;
debug_pmmu_reg_part <= pmmu_reg_part_d;
debug_pmmu_reg_rdat <= x"0000" & pmmu_debug_mmusr;
debug_make_berr <= make_berr;
debug_pmmu_fault <= pmmu_fault;

END;
