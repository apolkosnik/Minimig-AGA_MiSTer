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
		debug_regfile_a0 : out std_logic_vector(31 downto 0)
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
	-- MOVES (d16,An): extra sequencing to fetch the displacement word after the MOVES extension word.
	signal moves_d16_phase   : std_logic := '0';
	-- BUG #214: MOVES mem->CPU writeback guard - ensures destination register selection persists until writeback completes
	signal moves_writeback_pending : std_logic := '0';
	signal moves_active : std_logic := '0';
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
      mmu_config_ack => pmmu_config_ack  -- BUG #154: Acknowledge to clear error
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
  pmmu_reg_sel_int <= pmmu_brief(14 downto 10) when CPU(1) = '1' AND
                          (set(pmmu_rd)='1' OR exec(pmmu_rd)='1' OR set(pmmu_wr)='1' OR
                           exec(pmmu_wr)='1' OR set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1') else
                      pmmu_reg_sel_d when CPU(1) = '1' else
                      (others => '0');
  pmmu_reg_sel_valid <= true when (pmmu_reg_sel_int = "00010" OR pmmu_reg_sel_int = "00011" OR pmmu_reg_sel_int = "10000" OR
                                   pmmu_reg_sel_int = "10010" OR pmmu_reg_sel_int = "10011" OR pmmu_reg_sel_int = "11000")
                        else false;
  pmmu_reg_sel  <= pmmu_reg_sel_int;  -- Drive output port from internal signal
  pmmu_reg_wdat <= pmmu_reg_wdat_d when CPU(1) = '1'  else (others => '0');
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
  pmmu_reg_we_d <= '1' when CPU(1)='1' AND (set_exec(pmmu_wr)='1' OR exec(pmmu_wr)='1') AND pmmu_reg_sel_valid
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

  -- For PTEST/PLOAD/PFLUSH with EA: use EA address, else use current logical address
  pmmu_cmd_addr   <= OP1out when (micro_state = ptest1 or micro_state = pload1 or micro_state = pflush1)
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
		process(fc_internal, micro_state, moves_bus_pending, brief, SFC, DFC)
		begin
			if micro_state = moves1 or moves_bus_pending = '1' then
				-- MOVES instruction: override FC with SFC or DFC
				-- brief(11)=dr: dr=0 means read (use SFC), dr=1 means write (use DFC)
				if brief(11)='0' then
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
		elsif rising_edge(clk) then
			if clkena_in = '1' then
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
				-- Clear when bus access completes AND register writeback is done
				-- Must wait for exec(Regwrena) to complete so brief(15:12) is used for destination
				elsif (state = "00" or state = "01") and exec(Regwrena) = '0' then
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
					if micro_state = moves1 and brief(11) = '0' then
						moves_writeback_pending <= '1';
					-- Clear only after register writeback completes
					elsif moves_active = '1' and exec(Regwrena) = '1' and moves_writeback_pending = '1' then
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
					elsif opcode(5 downto 3) = "101" then
						-- Phase 0: first moves0 cycle (prepare/fetch displacement)
						-- Phase 1: second moves0 cycle (displacement available in last_data_read)
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
			IF VBR_Stackframe=1 or ((cpu(0)='1' or cpu(1)='1') and VBR_Stackframe=2) THEN
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
	
PROCESS (long_start, reg_QB, data_write_tmp, exec, data_read, data_write_mux, memmaskmux, bf_ext_out, 
		 data_write_muxin, memmask, oddout, addr)
	BEGIN
		IF exec(write_reg)='1' THEN
			data_write_muxin <= reg_QB;
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
					-- MOVES mem->CPU: use brief register index to avoid RDindex_A timing race
					IF exec(Regwrena)='1' AND opcode(15 downto 8)="00001110" AND brief(11)='0' THEN
						regfile(conv_integer(brief(15 downto 12))) <= regin;
					ELSE
						regfile(RDindex_A) <= regin;
					END IF;
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
PROCESS (opcode, rf_source_addrd, brief, setstackaddr, dest_hbits, dest_areg, dest_LDRareg, data_is_source, sndOPC, exec, set, dest_2ndHbits, dest_2ndLbits, dest_LDRHbits, dest_LDRLbits, last_data_read, last_opc_read, micro_state, pmove_dn_regnum, pmove_dn_mode, moves_bus_pending, moves_ea_areg, moves_ea_regnum)
	BEGIN
		IF exec(movem_action) ='1' THEN
			rf_dest_addr <= rf_source_addrd;
		-- BUG #214 FIX: MOVES memory->CPU writeback must use brief register
		-- This avoids using the EA register when exec(Regwrena) asserts after moves1
		ELSIF exec(Regwrena)='1' AND opcode(15 downto 8)="00001110" AND brief(11)='0' THEN
			rf_dest_addr <= brief(15 downto 12);
		-- BUG #150 FIX: MOVES bus access needs EA register for address calculation
		-- This MUST come before set(briefext) which would override with the data register
		-- The address register value goes through rf_dest_addr -> RDindex_A -> reg_QA -> memaddr_reg
		-- BUG #168 FIX: During register write phase (exec(Regwrena)='1'), use brief(15:12) for destination
		-- Otherwise the EA register would be written instead of the intended Rn from extension word
		-- BUG #214 FIX: Check brief(11) directly to determine MOVES direction
		ELSIF moves_bus_pending = '1' THEN
			IF brief(11) = '0' THEN
				-- MOVES <ea>,Rn (memory→CPU, dr=0): destination is register from brief(15:12)
				rf_dest_addr <= brief(15 downto 12);
			ELSE
				-- MOVES Rn,<ea> (CPU→memory, dr=1): destination is EA (for memory address)
				rf_dest_addr <= moves_ea_areg & moves_ea_regnum;
			END IF;
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
		ELSIF micro_state = pmove_dn_lo THEN
			-- BUG #59 FIX: PMOVE checks must come BEFORE dest_hbits!
			-- PMOVE 64-bit: LOW word goes to Dn+1 (increment register number)
			rf_dest_addr <= dest_areg&(pmove_dn_regnum + "001");
		ELSIF pmove_dn_mode = '1' THEN
			-- BUG #59 FIX: Use latched pmove_dn_regnum, not opcode(11:9) which gets overwritten!
			rf_dest_addr <= dest_areg&pmove_dn_regnum;
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
PROCESS (opcode, exe_opcode, movem_presub, movem_regaddr, source_lowbits, source_areg, sndOPC, exec, set, source_2ndLbits, source_2ndHbits, 	source_LDRLbits, source_LDRMbits, last_data_read, last_opc_read, source_2ndMbits, micro_state, pmove_dn_regnum, pmove_dn_mode, moves_bus_pending, moves_ea_areg, moves_ea_regnum)
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
		-- During moves0/moves1 states, derive from opcode directly
		-- During nop state with moves_bus_pending='1', use latched values
		-- BUG #214 FIX: For CPU->memory (dr=1), source is brief register, not EA register!
		ELSIF moves_bus_pending = '1' THEN
			IF brief(11) = '1' THEN
				-- MOVES Rn,<ea> (CPU->memory): source is data register from brief(15:12)
				rf_source_addr <= brief(15 downto 12);
			ELSE
				-- MOVES <ea>,Rn (memory->CPU): source is EA register for address calculation
				rf_source_addr <= moves_ea_areg & moves_ea_regnum;
			END IF;
		-- BUG #149 FIX: MOVES needs opcode(2:0) for EA register selection
		-- exe_opcode is NOT latched for MOVES because next_micro_state=moves0 prevents setexecOPC='1'
		-- opcode is stable during microstate execution and contains the MOVES instruction
		-- Derive address/data register from EA mode (opcode(5:3)) combinationally
		-- EA modes using address registers: 010=(An), 011=(An)+, 100=-(An), 101=(d16,An), 110=(d8,An,Xn)
		-- BUG #214 FIX: For CPU->memory (brief(11)=1), source is brief register, NOT EA register!
		ELSIF micro_state = moves0 OR micro_state = moves1 THEN
			-- Check direction: brief(11)=1 means CPU->memory (source is brief register)
			IF brief(11) = '1' THEN
				-- MOVES Rn,<ea>: source is data/address register from brief(15:12)
				rf_source_addr <= brief(15 downto 12);
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
		ELSIF pmove_dn_mode = '1' THEN
			rf_source_addr <= source_areg&pmove_dn_regnum;
		-- BUG #289 FIX: PMOVE MMU states need EA register from opcode(2:0), not opcode(11:9)
		-- For PMOVE CRP,(A7)+, opcode(2:0)="111" (A7) but opcode(11:9)="000" (wrong!)
		ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
		       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
		      (opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100") THEN
			rf_source_addr <= '1'&opcode(2 downto 0);  -- Address register for (An)/(An)+/-(An) modes
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
		ELSIF exec(ea_data_OP1)='1' AND store_in_tmp='1' THEN
			OP1out <= ea_data;
		-- BUG #291 FIX: When postadd/presub='1' AND memmaskmux(3)='1' (register update phase),
		-- use reg_QA (address register value)! The condition memmaskmux(3)='1' ensures we're
		-- not in the middle of a longword write (memmaskmux(3)='0' means second word in progress).
		-- Without this, PMOVE CRP,(A7)+ uses the current memory address instead of A7's original
		-- value for the post-increment calculation.
		ELSIF (exec(postadd)='1' OR exec(presub)='1') AND memmaskmux(3)='1' THEN
			-- Register update mode: OP1out stays as reg_QA (default)
			NULL;
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
		ELSIF pmove_mmu_read_active='1' THEN
			-- PMOVE simplification: Route PMMU register data through standard write path
			-- This must be checked BEFORE use_direct_data/store_in_tmp which may interfere
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
					data_write_tmp <= TG68_PC_add;
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
------------------------------------
--				ELSIF micro_state=trap0 THEN	
--					data_write_tmp(15 downto 0) <= trap_vector(15 downto 0);
				ELSIF exec(hold_dwr)='1' THEN
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
         pmove_disp_latched, micro_state, opcode, moves_ea_areg, moves_bus_pending, memmaskmux)
	BEGIN
		
		IF rising_edge(clk) THEN
			-- BUG FIX: Use clkena_in instead of clkena_lw for trap_vector updates
			-- During RTE format error detection, clkena_lw may be '0' (memmaskmux(3)='0')
			-- which prevented trap_format_error from updating trap_vector properly.
			-- This caused exception 8 (privilege) instead of exception 14 (format error).
			IF clkena_in='1' THEN
				trap_vector(31 downto 10) <= (others => '0');
				IF trap_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;
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
				IF (micro_state = moves0 OR micro_state = moves1 OR moves_bus_pending = '1') AND
				    (moves_ea_areg = '1' OR opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100") THEN
					memaddr_delta_rega <= (others => '0');  -- No delta for simple (An) mode
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
				-- BUG #290 FIX: For pmove_mmu_to_mem_lo, use pmove_ea_latched + 4 directly!
				-- The reg_QA timing is broken for 64-bit CRP/SRP because:
				-- 1. rf_source_addr during pmove_decode points to wrong register (D0 instead of An)
				-- 2. reg_QA reflects previous cycle's rf_source_addr, causing timing issues
				-- 3. pmove_ea_latched was captured during HI state and updated +4 at transition
					ELSIF micro_state = pmove_mmu_to_mem_lo AND
					      (opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100") AND
					      memmaskmux(3)='1' THEN
						-- BUG #290 FIX: LO state first word uses pmove_ea_latched (already has +4 from HI)
						memaddr_delta_rega <= pmove_ea_latched;
						use_base <= '0';  -- Don't use reg_QA, use latched address directly
					-- BUG #302 FIX: Special case for (An)+ mode CRP/SRP LOW word reads
					ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
					       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
					      (opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR
					       opcode(5 downto 3)="101" OR opcode(5 downto 3)="110") AND
					      memmaskmux(3)='1' THEN
						-- Modes 010/011/100: Simple (An)/(An)+/-(An) - no displacement
						-- Modes 101/110: (d16,An)/(d8,An,Xn) - displacement in pmove_disp_latched
						IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
							memaddr_delta_rega <= (others => '0');  -- No delta for simple (An) mode
						ELSE
							memaddr_delta_rega <= pmove_disp_latched;  -- BUG #197 V6: Use latched displacement
						END IF;
						use_base <= '1';  -- Force memaddr_reg = reg_QA
				-- BUG #302: Exclude (An)+ CRP/SRP in pmove_mem_to_mmu_lo from using addsub_q
				ELSIF (memmaskmux(3)='0' OR exec(mem_addsub)='1') AND NOT
				      ((micro_state = pmove_mem_to_mmu_lo) AND
				       (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") AND
				       pmmu_ea_mode_latched(5 downto 3)="011") THEN
					memaddr_delta_rega <= addsub_q;
				ELSIF set(restore_ADDR)='1' THEN
					memaddr_delta_rega <= tmp_TG68_PC;
				ELSIF exec(direct_delta)='1' THEN
					memaddr_delta_rega <= data_read;
				ELSIF exec(ea_to_pc)='1' AND setstate="00" THEN
					memaddr_delta_rega <= addr;
				ELSIF set(addrlong)='1' THEN
					memaddr_delta_rega <= last_data_read;
				-- BUG #149 FIX: MOVES states AND bus access pending need to bypass normal address calc
				-- setstate="00" during moves0/moves1 (assignment is next-cycle), but we need use_base='1'
				-- Also exclude moves_bus_pending to prevent PC increment during MOVES bus access
				ELSIF setstate="00" AND micro_state /= moves0 AND micro_state /= moves1 AND moves_bus_pending = '0' THEN
					memaddr_delta_rega <= TG68_PC_add;
				ELSIF exec(dispouter)='1' THEN
					memaddr_delta_rega <= ea_data;
					memaddr_delta_regb <= memaddr_a;
				ELSIF set_vectoraddr='1' THEN
					memaddr_delta_rega <= trap_vector_vbr;
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
        PC_dataa, PC_datab, setnextpass, last_data_read, TG68_PC_brw, TG68_PC_word, Z_error, trap_trap, trap_trapv, interrupt, tmp_TG68_PC, TG68_PC, use_VBR_Stackframe, writePCnext)
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
			IF writePCbig='1' THEN
				PC_datab(3) <= '1';
				PC_datab(1) <= '1';
			ELSE	
				PC_datab(2) <= '1';
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
		IF setstate="00" AND next_micro_state=idle AND setnextpass='0' AND (exec_write_back='0' OR state="11") AND set_rot_cnt="000001" AND set_exec(opcCHK)='0'THEN
			setendOPC <= '1';
			IF FlagsSR(2 downto 0)<IPL_nr OR IPL_nr="111"  OR make_trace='1' OR make_berr='1' THEN
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
					ELSIF (state ="00" OR TG68_PC_brw = '1') AND stop='0'  THEN
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
					END IF;
				END IF;
				IF clkena_lw='1' THEN
					interrupt <= setinterrupt;
					decodeOPC <= setopcode;
					endOPC <= setendOPC;
					execOPC <= setexecOPC;
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
						ELSIF make_berr='1' THEN
							-- BUG #159 FIX: Distinguish MMU bus error (vector 61) from normal BERR (vector 2)
							IF make_mmu_berr='1' THEN
								trap_mmu_berr <= '1';  -- Use vector 61 for MMU bus error
							ELSE
								trap_berr <= '1';  -- Use vector 2 for normal bus error
							END IF;
						ELSE
							rIPL_nr <= IPL_nr;
							IPL_vec <= "00011"&IPL_nr;            --	TH
							trap_interrupt <= '1';
						END IF;
					END IF;	
					IF micro_state=trap0 AND IPL_autovector='0' THEN 			
						IPL_vec <= last_data_read(7 downto 0);    --	TH
					END IF;	
				-- BUG #88 FIX: Capture Dn selector from opcode EA register field
				-- opcode(5:3)="000" = Dn mode, opcode(2:0) = Dn register number (D0-D7)
				-- F-Line Context: Use latched opcode when context valid
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
				-- BUG #289: F-Line Context Capture moved to clkena_in block (see lines 1815-1839)
				-- The clkena_lw block doesn't execute for PMOVE memory EA (memmask="100111")
				-- Clear F-line context when instruction completes
				IF setendOPC = '1' OR trapmake = '1' THEN
					fline_context_valid <= '0';
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
		 moves_writeback_pending, moves_active)
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
			next_micro_state <= trap0;
			-- Only need stack swap if A7 currently has user stack (preSVmode='0')
			-- If preSVmode='1', A7 already has supervisor stack, no swap needed
			-- FlagsSR(5) update to '1' is handled in sequential process (see BUG #151)
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
		IF trapmake='1' AND trapd='0' THEN
			-- Stack frame format selection (MC68030 User's Manual 6.4.3):
			-- Format #2 (6-word): TRAPV, CHK, CHK2, Divide by Zero, Trace, cpTRAPcc
			-- Format #0 (4-word): All others including privilege violation, F-line, illegal
			IF cpu(1)='1' AND (trap_trapv='1' OR set_Z_error='1' OR exec(trap_chk)='1') THEN
				next_micro_state <= trap00;
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
				-- 68020/68030: Use MSP/ISP based on interrupt_mode
				IF preSVmode='0' THEN
					-- Currently in user mode, switching to supervisor mode
					set(to_USP) <= '1';
					IF interrupt_mode='1' THEN
						set(from_ISP) <= '1';
					ELSE
						set(from_MSP) <= '1';
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
				next_micro_state <= ld_AnXn1;
				getbrief <='1';
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
								
								
								
							IF opcode(7)='1' THEN		--jsr, jmp
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
				if micro_state = ld_AnXn2 and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and  -- F-line (PMOVE/FPU/etc)
				   fline_opcode_latch(5 downto 3)="110" and  -- (d8,An,Xn) mode
				   (next_micro_state = pmove_mem_to_mmu_hi OR next_micro_state = pmove_mmu_to_mem_hi) then
					-- Latch the full computed indexed EA
					pmove_disp_latched <= addr;
				end if;
			END IF;
		END IF;

			CASE micro_state IS
				WHEN ld_nn =>		-- (nnnn).w/l=>
					set(get_ea_now) <='1';
					set(addrlong) <= '1';
					-- BUG #114 FIX: Check PMOVE FIRST, then decide setnextpass
					-- For PMOVE with (xxx).L mode, setnextpass causes PC over-increment
					-- (PC+10 instead of PC+8 for the 8-byte instruction)
					-- brief(15:13) format: "000"=TT0/TT1, "010"=TC/SRP/CRP, "011"=MMUSR
					-- BUG #146 FIX: REMOVED unconditional setnextpass <= '1' that was here!
					-- The old code set setnextpass='1' BEFORE checking for PMOVE, and the
					-- PMOVE branch never cleared it - causing PC overincrement in hardware.
					-- Now setnextpass is only set in the ELSE branch (non-PMOVE).
					-- F-Line Context: Use pmmu_brief for stable values
					IF opcode(15 downto 12)="1111" AND
					   (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") THEN
						-- PMOVE with (xxx).L: go to pmove state, NO setnextpass
						-- BUG #146 FIX: Explicitly clear setnextpass to prevent PC overincrement
						setnextpass <= '0';
						IF pmmu_brief(9)='1' THEN
							-- MMU->mem direction (read from MMU, write to memory)
							next_micro_state <= pmove_mmu_to_mem_hi;
						ELSE
							-- mem->MMU direction (read from memory, write to MMU)
							-- BUG #114 FIX: Set setstate="10" to trigger memory read at computed EA!
							-- pmove_decode uses setstate="01" for complex EA modes to let us compute EA first.
							-- Now EA is ready, set memory read state before going to pmove_mem_to_mmu_hi.
							setstate <= "10";  -- Memory read at computed EA
							-- BUG #116 FIX: Must set datatype for proper longword read!
							-- pmove_decode set datatype but it doesn't persist through state transitions.
							-- Without this, only a 16-bit word read happens, not 32-bit longword!
							-- MMUSR (11000) is 16-bit, all others (TC/TT0/TT1/CRP/SRP) are 32-bit
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- Word (16-bit) for MMUSR
							ELSE
								datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							END IF;
							next_micro_state <= pmove_mem_to_mmu_hi;
						END IF;
					ELSE
						-- Non-PMOVE: set setnextpass for normal EA processing
						setnextpass <= '1';
					END IF;
					
				WHEN st_nn =>		-- =>(nnnn).w/l
					setstate <= "11";
					set(addrlong) <= '1';
					next_micro_state <= nop;
					
				WHEN ld_dAn1 =>		-- d(An)=>, --d(PC)=>
					set(get_ea_now) <='1';
					setdisp <= '1';		--word
					-- BUG #191 FIX V2: Set setnextpass unconditionally FIRST (for normal instructions)
					-- Then override to '0' for PMOVE to prevent PC over-increment
					setnextpass <= '1';
					IF opcode(15 downto 12)="1111" AND
					   (pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011" OR pmmu_brief(15 downto 13)="000") THEN
						-- PMOVE with (d16,An): clear setnextpass to prevent PC over-increment
						setnextpass <= '0';
						IF pmmu_brief(9)='1' THEN
							-- MMU->mem direction
							-- BUG #196 FIX: Must set write state and longaktion for PMOVE TC,(d16,An)
							-- Without this, no write occurs to memory
							-- BUG #197 FIX: Must latch EA NOW while memaddr_a still contains displacement!
							-- By pmove_mmu_to_mem_hi, setdisp='0' resets memaddr_a to zero, corrupting EA.
							set(OP1addr) <= '1';  -- Latch addr (base+disp) into OP1out for write
							setstate <= "11";  -- Write state
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- MMUSR is 16-bit
							ELSE
								datatype <= "10";  -- TC/TT0/TT1 are 32-bit
								set(longaktion) <= '1';  -- Required for 32-bit write
							END IF;
							next_micro_state <= pmove_mmu_to_mem_hi;
						ELSE
							-- BUG #123 FIX: mem->MMU direction
							setstate <= "10";  -- Memory read at computed EA
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- Word (16-bit) for MMUSR
							ELSE
								datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							END IF;
							next_micro_state <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;

						-- MOVES (d16,An): after fetching the displacement word and computing EA,
						-- continue into moves1 which performs the actual data transfer using SFC/DFC.
						IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND opcode(5 downto 3)="101" THEN
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
					
				WHEN ld_AnXn2 =>
					set(get_ea_now) <='1';
					setdisp <= '1';		--brief
					setnextpass <= '1';
					
					-- PMOVE: After indexed EA is computed, jump to PMOVE microstates.
					-- Without this, PMOVE using (d8,An,Xn) / full index / memory-indirect modes
					-- computes EA but never performs the PMMU<->memory transfer.
					-- F-Line Context: Use pmmu_brief for stable values
					IF opcode(15 downto 12)="1111" AND
					   (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") THEN
						IF pmmu_brief(9)='1' THEN
							-- MMU->mem direction (read from MMU, write to memory)
							next_micro_state <= pmove_mmu_to_mem_hi;
						ELSE
							-- mem->MMU direction (read from memory, write to MMU)
							setstate <= "10";  -- Memory read at computed EA
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";  -- Word (16-bit) for MMUSR
							ELSE
								datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
							END IF;
							next_micro_state <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;
					
-------------------------------------------------------------------------------------					
					
				WHEN ld_229_1 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
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
							
							-- PMOVE: full-format indexed EA (no memory-indirect) must still dispatch
							-- into PMOVE transfer states after EA is ready.
							-- F-Line Context: Use pmmu_brief for stable values
							IF opcode(15 downto 12)="1111" AND
							   (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") THEN
								IF pmmu_brief(9)='1' THEN
									next_micro_state <= pmove_mmu_to_mem_hi;
								ELSE
									setstate <= "10";  -- Memory read at computed EA
									IF pmmu_brief(14 downto 10) = "11000" THEN
										datatype <= "01";  -- Word (16-bit) for MMUSR
									ELSE
										datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
									END IF;
									next_micro_state <= pmove_mem_to_mmu_hi;
								END IF;
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
						
						-- PMOVE: memory-indirect indexed EA completes here for some forms; dispatch.
						-- F-Line Context: Use pmmu_brief for stable values
						IF opcode(15 downto 12)="1111" AND
						   (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") THEN
							IF pmmu_brief(9)='1' THEN
								next_micro_state <= pmove_mmu_to_mem_hi;
							ELSE
								setstate <= "10";  -- Memory read at computed EA
								IF pmmu_brief(14 downto 10) = "11000" THEN
									datatype <= "01";  -- Word (16-bit) for MMUSR
								ELSE
									datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
								END IF;
								next_micro_state <= pmove_mem_to_mmu_hi;
							END IF;
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
					ELSE
						next_micro_state <= trap3;
					END IF;
				WHEN trap3 =>		-- TRAP
					set_vectoraddr <= '1';
					datatype <= "10";
					set(direct_delta) <= '1';	
					set(directPC) <= '1';
					setstate <= "10";
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
						WHEN "0000" | "0001" =>
							-- Format 0/1: 4-word frame - no additional reads needed
							-- Format 1 is "throwaway" frame used for interrupt return
							datatype <= "01";
							next_micro_state <= nop;
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
							-- Formats $3-$8, $C-$F are not valid on MC68030
							trap_format_error <= '1';
							trapmake <= '1';
					END CASE;
				WHEN rte5 =>            -- RTE
					-- Continue popping stack for formats that need multiple reads
					IF rot_cnt = "000001" THEN
						-- Last read completed - RTE is finishing
						next_micro_state <= nop;
						-- BUG #18: Clear interrupt mode only when returning to user mode (MC68030)
						-- RTE restores SR which contains S bit (supervisor mode bit in bit 5)
						-- Only clear interrupt_mode if returning to user mode (FlagsSR(5)=0)
						-- This prevents clearing interrupt_mode when RTE is called from within an interrupt handler
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
--					ELSIF brief(11 downto 0)=X"800"OR brief(11 downto 0)=X"001" OR brief(11 downto 0)=X"000" THEN
--						trap_addr_error <= '1';
--						trapmake <= '1';
					ELSE
					trap_illegal <= '1';
					trapmake <= '1';
					END IF;
					-- BUG #216 FIX: MOVEC missing state transition - was hanging forever in movec1
					-- After MOVEC completes, advance to next instruction fetch
					setstate <= "00";

					WHEN moves0 =>		-- MOVES address setup state (BUG #149 FIX)
					-- Set up register selection one cycle before memory access
					-- This allows memaddr_reg to be updated with correct An value at clock edge
					-- before moves1 starts the actual memory operation
					-- NOTE: Use opcode, not exe_opcode - exe_opcode wasn't latched for MOVES
					source_lowbits <= '1';
					IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
						source_areg <= '1';  -- (An), (An)+, -(An) modes use address register
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
						-- MOVES (d16,An): after the MOVES extension word, fetch the displacement word
						-- from the instruction stream before performing the actual data access in moves1.
						IF opcode(5 downto 3)="101" THEN
							IF moves_d16_phase='0' THEN
								-- Keep setstate="00" so PC advances and last_data_read captures the displacement
								next_micro_state <= moves0;
							ELSE
								-- Displacement is available; compute EA in ld_dAn1, then continue in moves1
								setstate <= "01";  -- stall fetch while computing EA
								next_micro_state <= ld_dAn1;
							END IF;
						ELSE
							-- setstate must NOT be "00" to reach the ELSE branch where use_base <= '1'
							-- Using "01" as an intermediate state to enable address register base loading
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
					set(opcMOVE) <= '1';
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
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';  -- SP uses special decrement rules
						END IF;
					END IF;
					-- BUG #149 FIX: Must transition to nop state to hold the data access
					-- Without this, next_micro_state defaults to idle and state goes back to "00" (fetch)
					next_micro_state <= nop;
					IF brief(11)='1' THEN
						-- MOVES Rn,<ea> - Register to Memory using DFC (dr=1)
						setstate <= "11";  -- Write to EA
						-- DFC used for write (sfc_not_dfc stays '0')
						ELSE
							-- MOVES <ea>,Rn - Memory to Register using SFC (dr=0)
							setstate <= "10";  -- Read from EA
						    set(Regwrena) <= '1';
							set(sfc_not_dfc) <= '1';  -- Use SFC for read
					set(no_Flags) <= '1';  -- BUG #220: MOVES does not affect condition codes
						END IF;
					-- END IF;  -- BUG #170: reserved bits check

                WHEN pmove_decode =>		-- PMMU instruction dispatch based on extension word
                    -- BUG #54 FIX: set_writePCbig moved to Dn mode only (line 4548)
                    -- Memory EA modes use EA builder which handles PC increment correctly
                    -- set_writePCbig <='1';  -- REMOVED - was causing +6 PC increment for memory EA
                    set(update_FC) <= '1';  -- Ensure FC reflects supervisor mode

                    -- MC68030 PMMU instruction differentiation by extension word
                        -- ALL PMMU instructions use opcode F0xx, differentiated by extension word
                        --
                        -- CRITICAL FIX: Check for valid PMOVE P-register selector FIRST!
                        -- P-register selectors (bits 14-10):
                        --   00010 (0x02): TT0  → bits 15-13 = 000 ✓
                        --   00011 (0x03): TT1  → bits 15-13 = 000 ✓
                        --   10000 (0x10): TC   → bits 15-13 = 010 ✓
                        --   10010 (0x12): SRP  → bits 15-13 = 010 ✓
                        --   10011 (0x13): CRP  → bits 15-13 = 010 ✓
                        --   11000 (0x18): MMUSR→ bits 15-13 = 011 ✓
                        --
                        -- Extension word dispatch (bits 15-13):
                        --   000: PMOVE or PMOVEFD (TT0/TT1)
                        --   001: PFLUSH 12:10 = 001
                        --   001: PLOAD 12:10 = "000"
                        --   010: PMOVE or PMOVEFD (TC/SRP/CRP)
                        --   011: PMOVE (MMUSR)
                        --   100: PTEST

                        -- -- Check for PMOVEFD FIRST (bits 15-13="000" or "010", bits 9-8="00", valid register)
                        -- -- PMOVEFD must be checked before regular PMOVE to avoid misdetection
                        -- IF (brief(15 downto 13) = "000" OR brief(15 downto 13) = "010") AND brief(8) = '1' AND
                        --    brief(14 downto 10) /= "00000" THEN
                        --     -- PMOVEFD (ea),MRn - Flush Disable variant
                        --     -- Continue to PMOVE-style handling but will be caught by CASE below
                        -- END IF;

                        -- Check if this is a valid PMOVE or PMOVEFD register selector
                        -- TT0/TT1 use format "000", TC/SRP/CRP use format "010", MMUSR uses format "011"
                        -- F-Line Context: Use pmmu_brief for stable values
                        IF (pmmu_brief(15 downto 13) = "000" AND (pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011")) OR  -- TT0/TT1
                            (pmmu_brief(15 downto 13) = "010" AND (pmmu_brief(14 downto 10) = "10000" OR pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011")) OR  -- TC/SRP/CRP
                            (pmmu_brief(15 downto 13) = "011" AND pmmu_brief(14 downto 10) = "11000" )THEN  --MMUSR
                            -- PMOVE instruction with valid register (excluding PMOVEFD)

                            -- Validate EA mode for PMOVE (MC68030):
                            -- LEGAL: Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn) incl. full/indirect forms, xxx.W, xxx.L
                            -- ILLEGAL: An, PC-relative, Immediate
                            IF opcode(5 downto 3)="001" OR  -- An direct - ILLEGAL
                                (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR  -- Immediate #<data> - ILLEGAL
                                (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN  -- PC-relative (010/011) - ILLEGAL
                                    trap_illegal <= '1';
                                    trapmake <= '1';
                            ELSE
                                -- Legal EA modes: Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn), xxx.W, xxx.L
                                IF opcode(5 downto 3)="000" THEN
                                    -- Dn direct mode - register to register transfer
                                    -- BUG #54 FIX: Only increment PC for Dn mode, not memory EA modes
                                    set_writePCbig <='1';
                                    -- MC68030 PMOVE: Direction from extension word bit 9, NOT opcode(7)
                                    -- BUG #12 FIX: Swap direction - RW=0 means WRITE to MMU, RW=1 means READ from MMU
                                    -- BUG #30 FIX: Set setstate="01" to ensure memmask="111111" (bit 3='1')
                                    -- Without this, memmask defaults to "100111" (bit 3='0'), causing clkena_lw='0',
                                    -- which prevents RDindex_A from being updated, causing reads from wrong register!
                                    setstate <= "01";
                                    IF pmmu_brief(9)='0' THEN
                                        -- PMOVE Dn,<MMU reg> - Read from Dn, write to MMU (pmmu_brief(9)=0, RW=0)
                                        -- BUG #111 FIX: REVERT BUG #96! Use set_exec(pmmu_wr) for immediate exec() layer activation
                                        -- pmmu_reg_we_d is driven by exec(pmmu_wr) ONLY (line 576), NOT set(pmmu_wr)!
                                        -- On first iteration after reset, exec(pmmu_wr) is 0, so write is dropped.
                                        -- set_exec() activates BOTH set() and exec() layers immediately, fixing first-run failure.
                                        set_exec(pmmu_wr) <= '1';
                                        -- BUG #97 FIX: Do NOT set Regwrena for WRITE!
                                        -- Register value is read directly via pmmu_dn_data <= regfile(pmove_dn_regnum)
                                        -- Setting Regwrena causes unwanted writeback that corrupts the source register!
                                        -- BUG #107 FIX: WRITE path goes to idle, NOT pmmu_dn_read_wait!
                                        -- pmmu_dn_read_wait does a register write, which corrupts the source register.
                                        IF (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011") THEN
                                            -- CRP/SRP are always 64-bit (doubleword): need second Dn transfer (Dn+1)
                                            next_micro_state <= pmove_dn_hi;
                                        ELSE
                                            -- .L (longword) - single 32-bit transfer, WRITE completes
                                            next_micro_state <= idle;
                                        END IF;
                                    ELSE
                                        -- PMOVE <MMU reg>,Dn - Read from MMU, write to Dn (pmmu_brief(9)=1, RW=1)
                                        -- BUG #105 FIX: Do NOT assert set_exec(Regwrena) here!
                                        -- Stagger read from write - pmmu_reg_rdat needs one cycle to become valid.
                                        -- Writeback happens in pmmu_dn_read_wait with datatype="10" (LONG).
                                        set(pmmu_rd) <= '1';
                                        IF (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" )THEN
                                            -- .D (doubleword) - need second Dn transfer (only CRP/SRP reach here)
                                            next_micro_state <= pmove_dn_hi;
                                        ELSE
                                            -- .L (longword) - single 32-bit transfer
                                            -- BUG #105 FIX: Go to wait state for proper timing and datatype override
                                            next_micro_state <= pmmu_dn_read_wait;
                                        END IF;
                                    END IF;
                                ELSE  -- NOT fline_opcode_latch(5 downto 3)="000" -- not Dn direct

                                    -- Memory EA modes
                                    -- MC68030 PMOVE: Direction from extension word bit 9, NOT opcode(7)
                                    -- BUG #12 FIX: Swap direction - RW=0 means WRITE to MMU, RW=1 means READ from MMU
                                    IF pmmu_brief(9)='0' THEN
                                        -- PMOVE <ea>,<MMU reg> - Read from memory, write to MMU (pmmu_brief(9)=0, RW=0)
                                        set(ea_build) <= '1';
                                        -- BUG #228 FIX: Do NOT set ea_data_OP1 here for complex EA modes!
                                        -- For (d16,An) and (d8,An,Xn), the displacement/index hasn't been
                                        -- added yet. Setting ea_data_OP1 now would trigger a memory read
                                        -- at the wrong address (just An without displacement).
                                        -- The ld_dAn1/ld_AnXn2 handlers will trigger the memory read after
                                        -- the complete EA is computed.
                                        -- ea_data_OP1 is set below only for simple EA modes.
                                        -- BUG #7 FIX: Use word (16-bit) transfer for MMUSR, longword for others
                                        IF pmmu_brief(14 downto 10) = "11000" THEN
                                            datatype <= "01";  -- Word (16-bit) for MMUSR
                                        ELSE
                                            datatype <= "10";  -- Longword (32-bit) for TC/TT0/TT1/CRP/SRP
                                        END IF;
                                        -- BUG #82 FIX: Memory->MMU must go to pmove_mem_to_mmu_hi, not pmove_mmu_to_mem_hi!
                                        -- pmove_mem_to_mmu_hi handles memory->MMU writes (uses ea_data as source)
                                        -- pmove_mmu_to_mem_hi handles MMU->memory reads (writes pmmu_reg_rdat to memory)
                                        -- BUG #114 FIX (READ direction): Handle each EA mode correctly
                                        -- BUG #228 FIX: Use fline_opcode_latch instead of opcode for EA mode!
                                        -- By the time pmove_decode runs, opcode may have been prefetched to the
                                        -- next instruction. fline_opcode_latch is stable throughout PMOVE.
                                        IF fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100" THEN
                                            -- Simple EA modes: (An), (An)+, -(An) - address already in An, do immediate read
                                            -- BUG #228 FIX: Set ea_data_OP1 here for simple EA modes
                                            set(ea_data_OP1) <= '1';
                                            -- BUG #150 FIX: Must set presub for -(An) mode to decrement address register!
                                            -- Without this, PMOVE <ea>,<MMU reg> with -(An) reads from wrong address
                                            -- and corrupts address register (doesn't decrement it).
                                            IF fline_opcode_latch(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                -- CRP/SRP are 64-bit: -(An) must decrement by 8
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
                                                    set(pmmu_dbl) <= '1';
                                                END IF;
                                                IF fline_opcode_latch(2 downto 0)="111" THEN
                                                    set(use_SP) <= '1';
                                                END IF;
                                            END IF;
                                            IF pmmu_brief(14 downto 10) /= "11000" THEN  -- Not MMUSR
                                                set(longaktion) <= '1';  -- PMOVE mem->MMU uses full 32-bit read
                                            END IF;
                                            setstate <= "10";  -- Memory read
                                            next_micro_state <= pmove_mem_to_mmu_hi;
                                        ELSIF fline_opcode_latch(5 downto 3)="111" AND (fline_opcode_latch(2 downto 0)="000" OR fline_opcode_latch(2 downto 0)="001") THEN
                                            -- BUG #114: Absolute modes (xxx).W, (xxx).L
                                            -- Address is in instruction stream - go to ld_nn to fetch it
                                            -- ld_nn will compute EA (via get_ea_now + addrlong), set memory read,
                                            -- and go to pmove_mem_to_mmu_hi
                                            setstate <= "01";  -- Extension fetch mode
                                            -- Note: ld_nn handles longaktion internally based on address size
                                            -- For (xxx).L, the longaktion was already set by the EA builder at decode time
                                            next_micro_state <= ld_nn;  -- Go to ld_nn to compute EA and trigger read
                                        ELSIF fline_opcode_latch(5 downto 3)="101" THEN
                                            -- BUG #228 FIX V6: (d16,An) mode - DO NOT set setstate="01"!
                                            -- setstate="01" puts CPU in wait mode WITHOUT fetching.
                                            -- Let default setstate="00" allow normal prefetch to fetch displacement.
                                            -- This matches how regular instructions handle (d16,An).
                                            next_micro_state <= ld_dAn1;
                                        ELSIF fline_opcode_latch(5 downto 3)="110" THEN
                                            -- BUG #228 FIX V6: (d8,An,Xn) mode - DO NOT set setstate="01"!
                                            next_micro_state <= ld_AnXn1;
                                            getbrief <= '1';
                                        END IF;
                                    ELSE
                                        -- PMOVE <MMU reg>,<ea> - Read from MMU, write to memory (brief(9)=1, RW=1)
                                        set(ea_build) <= '1';
                                        -- BUG #228 FIX: Do NOT set OP1addr here for complex EA modes!
                                        -- For (d16,An) and (d8,An,Xn), the displacement/index hasn't been
                                        -- added yet. Setting OP1addr now would latch the wrong address
                                        -- (just An without displacement). The ld_dAn1/ld_AnXn2 handlers
                                        -- will set OP1addr after the complete EA is computed.
                                        -- Only set OP1addr for simple EA modes (010, 011, 100) and
                                        -- absolute modes (111 000/001).
                                        -- BUG #9 FIX: Don't set setstate here - pmove_mmu_to_mem_hi will set it after PMMU register is read
                                        set_exec(pmmu_rd) <= '1';
                                        -- BUG #113 FIX: Only set next_micro_state for simple EA modes!
                                        -- For complex EA modes like (d16,An), (d8,An,Xn),
                                        -- the EA builder sets next_micro_state to ld_dAn1/ld_AnXn1.
                                        -- If we set next_micro_state here, it OVERRIDES the EA builder
                                        -- (micro_state CASE comes after EA builder in process, last assignment wins).
                                        -- This causes PC not to increment for displacement word.
                                        -- BUG #114 FIX: For (xxx).W and (xxx).L, we CAN set next_micro_state
                                        -- because the address fetch is handled by the memory interface via
                                        -- set(longaktion), NOT by ld_nn. Setting next_micro_state here
                                        -- bypasses ld_nn's setnextpass which causes PC over-increment.
                                        -- BUG #120 FIX: Do NOT set setstate="01" for simple EA modes!
                                        -- setstate="01" means "extension fetch mode" - wait for extension word.
                                        -- Simple modes (An), (An)+, -(An) have NO extension word, so CPU hangs waiting forever!
                                        -- Only set setstate="01" for complex modes that actually need extension fetch.
                                        -- BUG #121 FIX: Still force write state for simple modes to stop extra prefetch
                                        -- PMOVE <MMU reg>,(An)/-(An) was leaving setstate="00" here, so PC advanced an
                                        -- extra word (PC+6 instead of PC+4) before the write microstate ran.
                                        -- Set datatype early so -(An) decrement uses correct size (PMOVE opcode bits are not size-encoded)
                                        IF pmmu_brief(14 downto 10) = "11000" THEN
                                            datatype <= "01";  -- MMUSR is 16-bit
                                        ELSE
                                            datatype <= "10";  -- TC/TT0/TT1/CRP/SRP are 32-bit per transfer
                                        END IF;

                                        -- BUG #228 FIX: Use fline_opcode_latch instead of opcode for EA mode!
                                        IF fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100" THEN
                                            -- Simple EA modes: (An), (An)+, -(An) - no extra words to fetch
                                            -- Do NOT set setstate="01" here - go directly to pmove_mmu_to_mem_hi
                                            -- BUG #150 FIX: Must set presub for -(An) mode to decrement address register!
                                            -- Without this, PMOVE <MMU reg>,-(An) writes to wrong address
                                            -- and corrupts address register (doesn't decrement it).
                                            IF fline_opcode_latch(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                -- CRP/SRP are 64-bit: -(An) must decrement by 8
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
                                                    set(pmmu_dbl) <= '1';
                                                END IF;
                                                IF fline_opcode_latch(2 downto 0)="111" THEN
                                                    set(use_SP) <= '1';
                                                END IF;
                                            END IF;
                                            -- BUG #190 FIX: Must set longaktion for 32-bit memory writes!
                                            -- Without this, memmask stays at word mode and both 16-bit cycles
                                            -- write the high half. MMUSR is 16-bit, so skip it.
                                            IF pmmu_brief(14 downto 10) /= "11000" THEN  -- Not MMUSR
                                                set(longaktion) <= '1';
                                            END IF;
                                            -- BUG #228 FIX: Set OP1addr here for simple EA modes
                                            -- For (An), (An)+, -(An), the address is just the register value
                                            set(OP1addr) <= '1';
                                            setstate <= "01";  -- stall fetch to prevent stray prefetch/PC bump
                                            next_micro_state <= pmove_mmu_to_mem_hi;
                                        ELSIF fline_opcode_latch(5 downto 3)="111" AND (fline_opcode_latch(2 downto 0)="000" OR fline_opcode_latch(2 downto 0)="001") THEN
                                            -- BUG #114: Absolute modes xxx.W, xxx.L - address fetched by memory interface
                                            -- The longaktion signal handles 32-bit address fetch for xxx.L
                                            -- We can safely set next_micro_state here to bypass ld_nn's setnextpass
                                            -- Also do NOT set setstate="01" - address comes from instruction stream
                                            -- BUG #190 FIX: Must set longaktion for 32-bit memory writes (not MMUSR)
                                            IF pmmu_brief(14 downto 10) = "11000" THEN
                                                datatype <= "01";  -- MMUSR is 16-bit
                                            ELSE
                                                datatype <= "10";  -- TC/TT0/TT1/CRP/SRP are 32-bit per transfer
                                            END IF;
                                            IF pmmu_brief(14 downto 10) /= "11000" THEN  -- Not MMUSR
                                                set(longaktion) <= '1';
                                            END IF;
                                            -- BUG #228 FIX: Set OP1addr for absolute modes
                                            set(OP1addr) <= '1';
                                            next_micro_state <= pmove_mmu_to_mem_hi;
                                        ELSIF fline_opcode_latch(5 downto 3)="101" THEN
                                            -- BUG #228 FIX V6: (d16,An) mode - DO NOT set setstate="01"!
                                            -- Let normal prefetch mechanism fetch displacement word.
                                            next_micro_state <= ld_dAn1;
                                        ELSIF fline_opcode_latch(5 downto 3)="110" THEN
                                            -- BUG #228 FIX V6: (d8,An,Xn) mode - DO NOT set setstate="01"!
                                            next_micro_state <= ld_AnXn1;
                                            getbrief <= '1';
                                        END IF;
                                    END IF;
                                END IF;
                            END IF;

                            -- PLOAD
                        ELSIF pmmu_brief(15 downto 13) = "001" AND pmmu_brief(12 downto 10) = "000" THEN -- PLOAD - Control Alterable modes
                            IF opcode(5 downto 3)="001" OR  -- An direct - ILLEGAL
                            opcode(5 downto 3)="011" OR  -- (An)+ - ILLEGAL
                            (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR  -- Immediate - ILLEGAL
                            (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN  -- PC-relative - ILLEGAL
                                trap_illegal <= '1';
                                trapmake <= '1';
                            ELSE
                                set(ea_build) <= '1';
                                datatype <= "10";
                                setstate <= "10";
                                set_exec(pmmu_pload) <= '1';
                                next_micro_state <= pload1;
                            END IF;


                        ELSIF pmmu_brief(15 downto 13) = "001" AND (pmmu_brief(12 downto 10) = "001" OR
                                                               pmmu_brief(12 downto 10) = "100" OR
                                                               pmmu_brief(12 downto 10) = "110") THEN  -- PFLUSH
                            -- PFLUSH - Control Alterable modes
                            -- MC68030 PFLUSH modes (bits 12-10):
                            --   001 = PFLUSHA/PFLUSHAN (flush all, no EA)
                            --   100 = PFLUSH FC,MASK (flush by FC, no EA)
                            --   110 = PFLUSH FC,MASK,<ea> (flush by FC with EA)
                            set_exec(pmmu_pflush) <= '1';
                            IF pmmu_brief(12 downto 10) = "001" OR pmmu_brief(12 downto 10) = "100" THEN
                                -- PFLUSHA/PFLUSHAN or PFLUSH FC,MASK - no EA needed
                                -- setstate="01" holds fetch/prefetch to avoid an extra PC increment
                                setstate <= "01";  -- No EA fetch
                                next_micro_state <= pflush1;
                            ELSE
                                IF opcode(5 downto 3)="001" OR  -- An direct - ILLEGAL
                                opcode(5 downto 3)="011" OR  -- (An)+ - ILLEGAL
                                (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR  -- Immediate - ILLEGAL
                                (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN  -- PC-relative - ILLEGAL
                                    trap_illegal <= '1';
                                    trapmake <= '1';
                                ELSE
                                    set(ea_build) <= '1';
                                    datatype <= "10";
                                    setstate <= "10";
                                    next_micro_state <= pflush1;
                                END IF;
                            END IF;

                        ELSIF pmmu_brief(15 downto 13) = "100" THEN  -- PTEST
                            -- PTEST - Control Alterable modes
                            IF opcode(5 downto 3)="001" OR  -- An direct - ILLEGAL
                               opcode(5 downto 3)="011" OR  -- (An)+ - ILLEGAL
                               (opcode(5 downto 3)="111" AND opcode(2 downto 0)="100") OR  -- Immediate - ILLEGAL
                               (opcode(5 downto 3)="111" AND opcode(2 downto 1)="01") THEN  -- PC-relative - ILLEGAL
                                trap_illegal <= '1';
                                trapmake <= '1';
                            ELSE
                                set(ea_build) <= '1';
                                datatype <= "10";
                                setstate <= "10";
                                set_exec(pmmu_ptest) <= '1';
                                next_micro_state <= ptest1;
                            END IF;
                        ELSE
                            -- Invalid PMMU instruction - trigger F-line exception (Vector 11)
                            -- Note: Vectors 57/58 are 68851-only; MC68030 uses F-line for all invalid PMMU encodings
                            trap_1111 <= '1';
                            trapmake <= '1';
                        END IF;

                WHEN pmove_mem_to_mmu_hi =>
                    -- Memory->MMU: Write ea_data to PMMU register (HIGH word for 64-bit)
                    set_exec(pmmu_wr) <= '1';
                    -- Post-increment (An)+ must occur after the memory read completes
                    IF opcode(5 downto 3)="011" THEN
                        -- CRP/SRP are 64-bit: defer +8 update to pmove_mem_to_mmu_lo after the low word is read
                        IF (pmmu_brief(14 downto 10) /= "10010" AND pmmu_brief(14 downto 10) /= "10011") THEN
                            set(postadd) <= '1';
                            IF opcode(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        END IF;
                    END IF;
                    -- If CRP/SRP (64-bit), advance EA and read LOW word
                    -- F-Line Context: Use pmmu_brief for stable values
                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN  -- SRP or CRP
                        set_exec(mem_addsub) <= '1';
                        -- BUG #302 FIX: For (An)+ mode, do NOT set pmmu_addr_inc or OP1addr here!
                        -- For (An)+ mode, the +4 offset for LOW word is handled by memaddr_delta, not register update.
                        IF pmmu_ea_mode_latched(5 downto 3) /= "011" THEN  -- NOT (An)+ mode
                            set(pmmu_addr_inc) <= '1';
                            set(OP1addr) <= '1';
                        END IF;
                        datatype <= "10"; -- long
                        setstate <= "10"; -- read LOW word from memory
                        next_micro_state <= pmove_mem_to_mmu_lo;
                    ELSE
                        -- 32-bit register (TC, TT0, TT1, MMUSR) - single transfer complete
                        next_micro_state <= idle;
                    END IF;
                WHEN pmove_mmu_to_mem_hi =>
                    -- MMU -> memory write (high part for 64-bit CRP/SRP, or only part for 32-bit regs)
                    -- data_write_tmp sourced from pmmu_reg_rdat in write datapath
                    -- For CRP/SRP (64-bit), advance EA and read low part next
                    -- F-Line Context: Use pmmu_brief for stable values
                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN  -- SRP or CRP
                        -- CRP/SRP are 64-bit: write CRP_H/SRP_H (32-bit) here, then CRP_L/SRP_L in LO state
                        set_exec(mem_addsub) <= '1';
                        set(pmmu_addr_inc) <= '1';  -- BUG #144 FIX: +4 address increment for EA
                        set(OP1addr) <= '1';
                        datatype <= "10"; -- long (32-bit)
                        -- BUG #190 FIX: Do NOT set set(longaktion) here!
                        -- longaktion was already set in pmove_decode. Setting it every cycle
                        -- RESETS memmask to "100001", preventing the shift that selects low word.
                        -- set(hold_dwr) <= '1';    -- Hold data_write_tmp during second bus cycle
                        setstate <= "11"; -- write CRP_H/SRP_H (32 bits)
                        set_exec(pmmu_rd) <= '1';  -- Request CRP_L/SRP_L for next state
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
                            -- BUG #190 FIX: Do NOT set set(longaktion) here!
                            -- longaktion was already set in pmove_decode (lines 5050-5052).
                            -- Setting it again every cycle RESETS memmask to "100001", preventing
                            -- the shift that selects the low word for the second bus cycle.
                            -- set(hold_dwr) <= '1';    -- Hold data_write_tmp during second bus cycle
                        END IF;
                        -- Post-increment (An)+ must occur after the memory write completes
                        IF opcode(5 downto 3)="011" THEN
                            set(postadd) <= '1';
                            IF opcode(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        END IF;
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
                    IF opcode(5 downto 3)="011" THEN
                        set(postadd) <= '1';
                        set(pmmu_dbl) <= '1';
                        IF opcode(2 downto 0)="111" THEN
                            set(use_SP) <= '1';
                        END IF;
                    END IF;
                    -- BUG #190 FIX: Must hold data_write_tmp during second bus cycle!
                    --set(hold_dwr) <= '1';
                    set_exec(pmmu_rd) <= '1';     -- keep PMMU selector active for low word
                    setstate <= "11"; -- write low part
                    -- Return to idle to resume fetch/PC sequencing
                    next_micro_state <= idle;
                WHEN pmove_mem_to_mmu_lo =>
                    -- Memory->MMU: Low part read completed; write LOW word to MMU register
                    -- BUG #302 FIX: For (An)+ mode, DON'T use pmmu_addr_inc OR OP1addr.
                    -- OP1addr captures pmove_ea_latched with +6 offset baked in.
                    -- This avoids double-increment: offset from OP1addr + postadd+pmmu_dbl = +14 total (wrong!).
                    -- For (An)+ mode, reg_QA (base address) is used directly with postadd+pmmu_dbl for +8 increment.
                    set_exec(pmmu_wr) <= '1';
                    set_exec(mem_addsub) <= '1';  -- raise memmask bit 3 to pulse clkena_lw
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
                    setstate <= "10";             -- memory read state (data already latched)
                    next_micro_state <= idle;

                -- PMMU instruction implementations
                WHEN ptest1 =>
                    -- PTEST: Test page translation (EA already built in pmove_decode)
                    -- MC68030 PTEST format (extension word):
                    -- - Bits 15-13: "100" (PTEST identifier)
                    -- - Bits 12-10: LEVEL (0-7)
                    -- - Bit 9: R/W (0=PTESTW/write, 1=PTESTR/read)
                    -- - Bit 8: A (address register return option)
                    -- - Bits 7-5: REG (address register number if A=1)
                    -- - Bits 4-0: FC encoding (10XXX=immediate FC in bits 2-0)
                    -- - Address from EA (already in OP1out)
                    -- PMMU module updates MMUSR with test results
                    -- BUG #133 FIX: Wait for PMMU walker to complete before proceeding
                    -- WhichAmiga does "ptestw #5,(a0),#7" then immediately "pmove mmusr,(sp)"
                    -- Without waiting, PMMU hasn't updated MMUSR yet, causing MMU detection failure
                    -- BUG #147 FIX: setstate="01" prevents extra PC increment when exiting ptest1
                    setstate <= "01";  -- No fetch cycle - prevents PC over-increment
                    IF pmmu_busy = '1' THEN
                        next_micro_state <= ptest1;  -- Stay here until walker completes
                    ELSE
                        next_micro_state <= nop;  -- Walker done, MMUSR valid, proceed
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
                    setstate <= "01";  -- No fetch cycle - prevents PC over-increment
                    next_micro_state <= nop;  -- FIX: Return to normal execution after PFLUSH

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
                    setstate <= "01";  -- No fetch cycle - prevents PC over-increment
                    IF pmmu_busy = '1' THEN
                        next_micro_state <= pload1;  -- Stay here until walker completes
                    ELSE
                        next_micro_state <= nop;  -- Walker done, ATC loaded, proceed
                    END IF;

                -- PMOVE Dn direct mode for 64-bit registers (CRP/SRP)
                WHEN pmove_dn_hi =>
                    -- First transfer completed (HIGH word in/out of first register)
                    -- Now handle LOW word with next register (Dn+1)
                    -- BUG #198 FIX: Increment pmove_dn_regnum for source data from Dn+1
                    -- rf_dest_addr already handles Dn+1 for writes (line 1170)
                    -- But pmmu_dn_data needs pmove_dn_regnum incremented for reads (line 749)
                    -- BUG #122 FIX: Remove redundant set_writePCbig - already set in pmove_decode!
                    -- PMOVE instruction is only 4 bytes, PC increment already handled.
                    next_micro_state <= pmove_dn_lo;

                WHEN pmove_dn_lo =>
                    -- Second transfer for 64-bit register (LOW word)
                    -- For PMOVE <MMU>,Dn: Read LOW word to Dn+1
                    -- For PMOVE Dn,<MMU>: Write LOW word from Dn+1
                    -- BUG FIX: Use pmmu_brief(9) for direction, NOT opcode(7)!
                    -- PMOVE uses extension word bit 9 for direction, same as first transfer
                    -- BUG #12 FIX: Swap direction - RW=0 means WRITE to MMU, RW=1 means READ from MMU
                    -- BUG #122 FIX: Use setstate="11" instead of "01" to prevent PC over-increment!
                    -- setstate="01" causes extra prefetch which increments PC by +2.
                    -- setstate="11" (write) sets memmask bit 3='1' for clkena_lw without PC increment.
                    -- Same fix pattern as BUG #121 for memory EA modes.
                    -- F-Line Context: Use pmmu_brief for stable values
                    setstate <= "11";
                    IF pmmu_brief(9)='0' THEN
                        -- PMOVE Dn+1,<MMU reg> - Read from Dn+1, write LOW word to MMU (pmmu_brief(9)=0, RW=0)
                        set_exec(pmmu_wr) <= '1';
                    ELSE
                        -- PMOVE <MMU reg>,Dn+1 - Read LOW word from MMU, write to Dn+1 (pmmu_brief(9)=1, RW=1)
                        -- BUG #89 FIX: Use set(pmmu_rd) not set_exec, consistent with 32-bit Dn mode (line 4581)
                        -- reg_rdat is combinational (BUG #83), so immediate read works
                        set(pmmu_rd) <= '1';
                        set_exec(Regwrena) <= '1';
                    END IF;
                    -- BUG #90 FIX: Must use 'idle' not 'nop' to trigger setexecOPC
                    -- Same issue as BUG #20 - setexecOPC only set when next_micro_state=idle (line 1432)
                    -- Without setexecOPC, set_exec(Regwrena) never becomes exec(Regwrena), and register write fails!
                    next_micro_state <= idle;

                WHEN pmmu_dn_read_wait =>
                    -- BUG #105 FIX: Wait state for PMOVE <MMU reg>,Dn 32-bit read
                    -- CRITICAL: Force datatype="10" (LONG) to override F-line opcode default of "00" (BYTE)!
                    -- Without this, only the low byte gets written on subsequent runs (D1=$77 instead of full value).
                    -- In pmove_decode we asserted set(pmmu_rd) which changed pmmu_reg_sel combinationally.
                    -- Now pmmu_reg_rdat is valid, so we can write the full 32-bit value.
                    datatype <= "10";  -- LONG mode (not byte!)
                    -- BUG #108 FIX: ALSO set set_datatype so it propagates to exe_datatype!
                    -- The timing chain is: set_datatype (line 1974) -> exe_datatype (line 1511).
                    -- Without this, exe_datatype gets default "00" (BYTE) from opcode(7:6), causing
                    -- only the low byte to be written on consecutive runs ($77 instead of full value).
                    set_datatype <= "10";  -- Force LONG mode for exec phase!
                    set_exec(pmmu_rd) <= '1';
                    set_exec(Regwrena) <= '1';
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
			-- BUG #215 FIX: Reassert MOVES mem->CPU writeback signals
			-- BUG #219 FIX: Check state="00" not "10" because state transitions before exec latches!
			-- Timing: moves1 sets setstate="10" → nop has state="10" but setstate="00" → next cycle state="00"
			IF moves_active = '1' AND moves_writeback_pending = '1' AND state = "00" THEN
				set(Regwrena) <= '1';
				set(briefext) <= '1';  -- BUG #218: Must re-assert to select correct dest register
				set(opcMOVE) <= '1';
				set(ea_data_OP2) <= '1';
				set(use_sfc_dfc) <= '1';
				set(sfc_not_dfc) <= '1';
				set(no_Flags) <= '1';  -- BUG #220: MOVES does not affect condition codes
			END IF;
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
        if next_micro_state = pmove_mmu_to_mem_lo and micro_state = pmove_mmu_to_mem_hi and pmove_ea_captured = '0' then
            -- addr is the base address (e.g., 0x2000 for PMOVE CRP,(A7)+)
            -- LO should write to base+4 (e.g., 0x2004)
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
        if CPU(1)='1' AND (set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR exec(pmmu_wr)='1' OR exec(pmmu_rd)='1') then
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
                if micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';  -- LOW word (mem EA second read)
                elsif micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';  -- HIGH word (mem EA first read, Dn first transfer)
                else
                  pmmu_reg_part_d <= '0';  -- LOW word (default)
                end if;
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
                if micro_state = pmove_mmu_to_mem_lo OR next_micro_state = pmove_mmu_to_mem_lo then
                  pmmu_reg_part_d <= '0';  -- Force LOW part in low write state (or about to enter)
                elsif micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';  -- Force LOW part for memory->MMU low read
                elsif micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mmu_to_mem_hi OR next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';  -- HIGH word (first transfer)
                else
                  pmmu_reg_part_d <= '0';  -- LOW word (second transfer)
                end if;
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

END; 
