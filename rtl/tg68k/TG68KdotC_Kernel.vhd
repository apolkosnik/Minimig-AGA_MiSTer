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
use ieee.std_logic_arith.all;
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
		MUL_Hardware : integer := 1;		--0=>no,			1=>yes,  
		FPU_Enable : integer := 1			--0=>no FPU,		1=>FPU enabled
		);
	port(clk						: in std_logic;
		nReset					: in std_logic;			--low active
		clkena_in				: in std_logic:='1';
		data_in					: in std_logic_vector(15 downto 0);
		IPL						: in std_logic_vector(2 downto 0):="111";
		IPL_autovector			: in std_logic:='0';
		berr						: in std_logic:='0';					-- only 68000 Stackpointer dummy
		CPU						: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  11->68020(only some parts - yet)
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
		CACR_out					: out std_logic_vector( 3 downto 0);
		VBR_out					: out std_logic_vector(31 downto 0)
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
	
	-- MC68020 Coprocessor Interface Register selection
	signal cir_register_select	: std_logic_vector(4 downto 0);
	
	-- FPU condition evaluation
	signal fpu_condition_result	: std_logic;
	
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
	signal trap_fpu_bsun		: bit;  -- FPU Branch/Set on Unordered (Vector 48)
	signal trap_fpu_inexact	: bit;  -- FPU Inexact (Vector 49)
	signal fpu_cpgen_complete	: bit;  -- Flag to indicate FPU cpGEN instruction completing  
	signal trap_fpu_divzero	: bit;  -- FPU Divide by Zero (Vector 50)
	signal trap_fpu_unfl		: bit;  -- FPU Underflow (Vector 51)
	signal trap_fpu_operr		: bit;  -- FPU Operand Error (Vector 52)
	signal trap_fpu_ovfl		: bit;  -- FPU Overflow (Vector 53)
	signal trap_fpu_snan		: bit;  -- FPU Signaling NaN (Vector 54)
	signal trap_fpu_trap		: bit;  -- FPU Conditional Trap (FTRAPcc)
	signal trapmake			: bit;
	signal trapd				: bit;
	signal trap_SR				: std_logic_vector(7 downto 0);
	signal make_trace			: std_logic;
	signal make_berr			: std_logic;
	signal useStackframe2	: std_logic;
	
	-- FPU signals
	signal fpu_enable_sig	: std_logic;
	signal fpu_busy			: std_logic;
	signal fpu_complete		: std_logic;
	signal fpu_exception		: std_logic;
	signal fpu_exception_code	: std_logic_vector(7 downto 0);
	signal fpu_data_out		: std_logic_vector(31 downto 0);
	signal fpu_fpcr			: std_logic_vector(31 downto 0);
	signal fpu_fpsr			: std_logic_vector(31 downto 0);
	signal fpu_fpiar			: std_logic_vector(31 downto 0);
	-- FPU Interface signals (CPU manages all memory operations)
	signal fpu_cpu_data_in		: std_logic_vector(31 downto 0);
	-- MC68020 Coprocessor State Frame signals
	signal fsave_counter		: integer range 0 to 54 := 0;  -- Increased for BUSY frames (216/4 = 54 longwords)
	signal fsave_predecr_flag	: bit := '0';  -- Special flag for FSAVE predecrement by frame size
	signal fsave_frame_size		: integer range 4 to 216 := 4;  -- Dynamic frame size (bytes)
	signal coprocessor_format_word	: std_logic_vector(31 downto 0) := X"00000004";  -- MC68020 format word
	signal fsave_size_determined	: std_logic := '0';  -- Flag indicating frame size has been determined
	signal cpSAVE_state		: integer range 0 to 3 := 0;  -- 0=read save CIR, 1=process format, 2=save data, 3=done
	signal cpRESTORE_state		: integer range 0 to 3 := 0;  -- 0=write format, 1=read restore CIR, 2=restore data, 3=done
	signal fsave_base_address	: std_logic_vector(31 downto 0);
	signal fsave_opcode_detected	: std_logic := '0';
	signal fpu_data_request     : std_logic := '0';
	signal frestore_data_write  : std_logic := '0';
	signal frestore_data_in     : std_logic_vector(31 downto 0);
	
	-- FPU timeout counter to prevent hangs
	signal timeout_counter		: integer range 0 to 255 := 0;  -- Timeout counter for FPU operations
	constant TIMEOUT_LIMIT_CPU	: integer := 100;  -- Maximum cycles to wait for FPU completion
	
	-- FMOVEM CPU-managed interface signals
	signal fmovem_data_request  : std_logic := '0';
	signal fmovem_reg_index     : integer range 0 to 7 := 0;
	signal fmovem_data_write    : std_logic := '0';
	signal fmovem_data_in       : std_logic_vector(79 downto 0) := (others => '0');
	signal fmovem_data_out      : std_logic_vector(79 downto 0) := (others => '0');
	
	-- FMOVEM state machine variables
	signal fmovem_active        : std_logic := '0';
	signal fmovem_reg_mask      : std_logic_vector(7 downto 0) := (others => '0');
	signal fmovem_direction     : std_logic := '0';  -- 0=to memory, 1=from memory
	signal fmovem_reg_count     : integer range 0 to 7 := 0;
	
	signal set_stop			: bit;
	signal stop					: bit;
	signal trap_vector		: std_logic_vector(31 downto 0);
	signal trap_vector_vbr	: std_logic_vector(31 downto 0);
	signal USP					: std_logic_vector(31 downto 0);
	signal SSP					: std_logic_vector(31 downto 0);
	signal MSP					: std_logic_vector(31 downto 0);  -- Master Stack Pointer (68020+)
	signal ISP					: std_logic_vector(31 downto 0);  -- Interrupt Stack Pointer (68020+)
	signal interrupt_mode		: std_logic := '0';  -- 0=normal supervisor, 1=interrupt processing
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
	signal CACR					: std_logic_vector(3 downto 0);
	signal DFC					: std_logic_vector(2 downto 0);
	signal SFC					: std_logic_vector(2 downto 0);
	

	signal set					: bit_vector(lastOpcBit downto 0);
	signal set_exec			: bit_vector(lastOpcBit downto 0);
	signal exec					: bit_vector(lastOpcBit downto 0);

	signal micro_state		: micro_states;
	signal next_micro_state	: micro_states;
	


BEGIN  

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
		CPU => CPU,								--: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  11->68020(only some parts - yet)
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

	-- FPU instantiation (MC68881/68882 compatible)
	FPU_GEN: if FPU_Enable = 1 generate
		FPU: TG68K_FPU
		port map(
			clk => clk,
			nReset => nReset,
			clkena => clkena_lw,
			
			-- CPU Interface
			opcode => opcode,
			extension_word => sndOPC,  -- Use second opcode as extension word
			fpu_enable => fpu_enable_sig,
			cpu_data_in => fpu_cpu_data_in,  -- Convert 16-bit data to 32-bit
			cpu_address_in => addr,  -- Effective address for FSAVE/FRESTORE
			fpu_data_out => fpu_data_out,
			
			-- FSAVE/FRESTORE Data Interface (CPU manages all memory operations)
			fsave_data_request => fpu_data_request,
			fsave_data_index => fsave_counter,
			frestore_data_write => frestore_data_write,
			frestore_data_in => frestore_data_in,
			
			-- FMOVEM Data Interface (CPU manages all memory operations)
			fmovem_data_request => fmovem_data_request,
			fmovem_reg_index => fmovem_reg_index,
			fmovem_data_write => fmovem_data_write,
			fmovem_data_in => fmovem_data_in,
			fmovem_data_out => fmovem_data_out,
			
			-- Control Signals
			fpu_busy => fpu_busy,
			fpu_done => fpu_complete,
			fpu_exception => fpu_exception,
			exception_code => fpu_exception_code,
			
			-- Status and Control Registers
			fpcr_out => fpu_fpcr,
			fpsr_out => fpu_fpsr,
			fpiar_out => fpu_fpiar
		);
		
		-- FPU enable signal control process
		process(clk, nReset)
		begin
			if nReset = '0' then
				fpu_enable_sig <= '0';  -- Initialize FPU enable signal to inactive
			elsif rising_edge(clk) then
				if clkena_lw = '1' then
					-- Enable FPU during FPU microcode states OR when F-line instruction detected
					if micro_state = fpu1 or micro_state = fpu2 or micro_state = fpu_wait or 
					   micro_state = fpu_done or micro_state = fpu_fmovem or micro_state = fpu_fmovem_cr or
					   (opcode(15 downto 12) = "1111" AND 
					    (opcode(11 downto 9) = "001" OR opcode(8 downto 6) = "000")) then
						fpu_enable_sig <= '1';
					else
						fpu_enable_sig <= '0';
					end if;
				end if;
			end if;
		end process;
	end generate;

	FPU_DISABLE: if FPU_Enable = 0 generate
		fpu_enable_sig <= '0';
		fpu_busy <= '0';
		fpu_complete <= '0';
		fpu_exception <= '0';
		fpu_exception_code <= (others => '0');
		fpu_data_out <= (others => '0');
		fpu_fpcr <= (others => '0');
		fpu_fpsr <= (others => '0');
		fpu_fpiar <= (others => '0');
	end generate;

	-- AMR - let the parent module know this is a longword access.  (Easy way to enable burst writes.)
	longword <= not memmaskmux(3);
	
	long_start_alu <= to_bit(NOT memmaskmux(3));
	execOPC_ALU <= execOPC OR exec(alu_exec);
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


	-- Memory Interface: CPU manages all memory operations
	nWr <= '0' WHEN state="11" ELSE '1';
	busstate <= state;
	nResetOut <= '0' WHEN exec(opcRESET)='1' ELSE '1';
	
	-- does shift for byte access. note active low me
	-- should produce address error on 68000
	memmaskmux <= memmask when addr(0) = '1' else memmask(4 downto 0) & '1';
	nUDS <= memmaskmux(5);
	nLDS <= memmaskmux(4);
	clkena_lw <= '1' WHEN clkena_in='1' AND memmaskmux(3)='1' ELSE '0';
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
			IF VBR_Stackframe=1 or (cpu(0)='1' and VBR_Stackframe=2) THEN
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
					regfile(RDindex_A) <= regin;
				END IF;
				
				IF exec(to_USP)='1' THEN
					USP <= reg_QA;
				END IF;	
				
				IF exec(to_SSP)='1' THEN
					SSP <= reg_QA;
				END IF;	
			END IF;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- Write Reg
-----------------------------------------------------------------------------
PROCESS (OP1in, reg_QA, Regwrena_now, Bwrena, Lwrena, exe_datatype, WR_AReg, movem_actiond, exec, ALUout, memaddr, memaddr_a, ea_only, USP, movec_data, fpu_data_out, micro_state, opcode, fsave_predecr_flag, fpu_condition_result)
	BEGIN
		regin <= ALUout;
		IF exec(save_memaddr)='1' THEN
			regin <= memaddr;	
		ELSIF exec(presub)='1' AND fsave_predecr_flag='1' THEN
			-- FSAVE predecrement: write the frame-size decremented address back to register
			regin <= memaddr_a;
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
		ELSIF FPU_Enable = 1 AND micro_state = fpu_done THEN
			IF opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" THEN
				IF opcode(8 downto 6) = "111" AND opcode(5 downto 3) = "000" THEN
					-- FMOVE FPcr,Dn - route FPU control register data to CPU data register
					regin <= fpu_data_out;
				ELSIF opcode(8 downto 6) = "010" AND opcode(5 downto 3) = "000" THEN
					-- FScc Dn - set conditional byte in register
					IF fpu_condition_result = '1' THEN
						regin <= X"000000FF";
					ELSE
						regin <= X"00000000";
					END IF;
				END IF;
			END IF;
		END IF;
		
		IF Bwrena='1' THEN
			regin(15 downto 8) <= reg_QA(15 downto 8);
		END IF;
		IF Lwrena='0' THEN
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
PROCESS (opcode, rf_source_addrd, brief, setstackaddr, dest_hbits, dest_areg, dest_LDRareg, data_is_source, sndOPC, exec, set, dest_2ndHbits, dest_2ndLbits, dest_LDRHbits, dest_LDRLbits, last_data_read)
	BEGIN
		IF exec(movem_action) ='1' THEN
			rf_dest_addr <= rf_source_addrd;
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
PROCESS (opcode, movem_presub, movem_regaddr, source_lowbits, source_areg, sndOPC, exec, set, source_2ndLbits, source_2ndHbits, 	source_LDRLbits, source_LDRMbits, last_data_read, source_2ndMbits)
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
		ELSIF source_lowbits='1' THEN
			rf_source_addr <= source_areg&opcode(2 downto 0);
		ELSIF exec(linksp)='1' THEN
			rf_source_addr <= "1111";
		ELSE
			rf_source_addr <= source_areg&opcode(11 downto 9);
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP1out
-----------------------------------------------------------------------------
PROCESS (reg_QA, store_in_tmp, ea_data, long_start, addr, exec, memmaskmux)
	BEGIN
		OP1out <= reg_QA;
		IF exec(OP1out_zero)='1' THEN
			OP1out <= (OTHERS => '0');	
		ELSIF exec(ea_data_OP1)='1' AND store_in_tmp='1' THEN
			OP1out <= ea_data;
		ELSIF exec(movem_action)='1' OR memmaskmux(3)='0' OR exec(OP1addr)='1' THEN 
			OP1out <= addr;
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP2out
-----------------------------------------------------------------------------
PROCESS (OP2out, reg_QB, exe_opcode, exe_datatype, execOPC, exec, use_direct_data, 
	     store_in_tmp, data_write_tmp, ea_data)
	BEGIN
		OP2out(15 downto 0) <= reg_QB(15 downto 0);
		OP2out(31 downto 16) <= (OTHERS => OP2out(15));
		IF exec(OP2out_one)='1' THEN
			OP2out(15 downto 0) <= "1111111111111111";
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
				ELSIF FPU_Enable = 1 AND (micro_state = fpu_wait OR micro_state = fpu_done OR micro_state = fpu2) THEN
					-- FPU operation - use FPU output data
					-- For FScc, check if it's a conditional set operation
					IF opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND 
					   opcode(8 downto 6) = "010" THEN
						-- FScc operation - set conditional byte
						IF fpu_condition_result = '1' THEN
							data_write_tmp <= X"000000FF";
						ELSE
							data_write_tmp <= X"00000000";
						END IF;
					ELSE
						data_write_tmp <= fpu_data_out;
					END IF;
				ELSE	
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
-- MC68020 Coprocessor Interface Register Selection Logic
-----------------------------------------------------------------------------
PROCESS (micro_state, opcode, sndOPC, state)
	BEGIN
		-- Default: Response register for status reads
		cir_register_select <= "00000";  -- Response Register (0x00)
		
		-- Dynamic CIR register selection based on operation type
		IF (micro_state = fpu1 OR micro_state = fpu2 OR micro_state = fpu_wait) AND
		   FPU_Enable = 1 AND opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" THEN
			
			-- Determine register based on FPU operation type and microstate
			CASE opcode(8 downto 6) IS
				WHEN "000" =>  -- cpGEN - General FPU operations (FADD, FMUL, etc.)
					IF micro_state = fpu1 THEN
						cir_register_select <= "00001";  -- Command Register (0x01) - write command word
					ELSE
						cir_register_select <= "00000";  -- Response Register (0x00) - read response primitives
					END IF;
					
				WHEN "100" =>  -- cpSAVE - FSAVE operation  
					-- MC68020 cpSAVE protocol: Read Save CIR, then write state frame
					IF cpSAVE_state = 0 THEN
						cir_register_select <= "00011";  -- Save CIR (0x03) - read format word
					ELSE
						cir_register_select <= "00000";  -- Not used during memory operations  
					END IF;
					
				WHEN "101" =>  -- cpRESTORE - FRESTORE operation
					-- MC68020 cpRESTORE protocol: Write format to Restore CIR, read response
					IF cpRESTORE_state = 0 THEN
						cir_register_select <= "00011";  -- Restore CIR (0x03) - write format word
					ELSIF cpRESTORE_state = 1 THEN
						cir_register_select <= "00011";  -- Restore CIR (0x03) - read response
					ELSE
						cir_register_select <= "00000";  -- Not used during memory operations
					END IF;
					
				WHEN "001" | "010" | "011" =>  -- FDBcc, FScc, FTRAPcc - conditional operations
					IF micro_state = fpu1 THEN
						cir_register_select <= "00100";  -- Condition CIR (0x04) - write condition selector
					ELSE
						cir_register_select <= "00000";  -- Response Register (0x00) - read true/false result
					END IF;
					
				WHEN OTHERS => -- Other coprocessor operations
					cir_register_select <= "00000";  -- Response Register (0x00) - default
			END CASE;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- FPU Condition Evaluation Logic
-----------------------------------------------------------------------------
PROCESS (sndOPC, fpu_FPSR)
	VARIABLE condition_code : std_logic_vector(4 downto 0);
	BEGIN
		-- Extract condition code from extension word (bits 4:0)
		condition_code := sndOPC(4 downto 0);
		
		-- Evaluate FPU condition based on FPSR status bits
		-- FPSR condition codes: N=bit 31, Z=bit 30, I=bit 29, NaN=bit 28
		CASE condition_code IS
			WHEN "00000" =>  -- F (False)
				fpu_condition_result <= '0';
			WHEN "00001" =>  -- EQ (Equal) - Z set
				fpu_condition_result <= fpu_FPSR(30);
			WHEN "00010" =>  -- OGT (Ordered Greater Than) - !(NaN | Z | N)
				fpu_condition_result <= NOT (fpu_FPSR(28) OR fpu_FPSR(30) OR fpu_FPSR(31));
			WHEN "00011" =>  -- OGE (Ordered Greater or Equal) - Z | !(NaN | N)
				fpu_condition_result <= fpu_FPSR(30) OR NOT (fpu_FPSR(28) OR fpu_FPSR(31));
			WHEN "00100" =>  -- OLT (Ordered Less Than) - N & !(NaN | Z)
				fpu_condition_result <= fpu_FPSR(31) AND NOT (fpu_FPSR(28) OR fpu_FPSR(30));
			WHEN "00101" =>  -- OLE (Ordered Less or Equal) - Z | (N & !NaN)
				fpu_condition_result <= fpu_FPSR(30) OR (fpu_FPSR(31) AND NOT fpu_FPSR(28));
			WHEN "00110" =>  -- OGL (Ordered Greater or Less) - !(NaN | Z)
				fpu_condition_result <= NOT (fpu_FPSR(28) OR fpu_FPSR(30));
			WHEN "00111" =>  -- OR (Ordered) - !NaN
				fpu_condition_result <= NOT fpu_FPSR(28);
			WHEN "01000" =>  -- UN (Unordered) - NaN
				fpu_condition_result <= fpu_FPSR(28);
			WHEN "01001" =>  -- UEQ (Unordered or Equal) - NaN | Z
				fpu_condition_result <= fpu_FPSR(28) OR fpu_FPSR(30);
			WHEN "01010" =>  -- UGT (Unordered or Greater Than) - NaN | !(N | Z)
				fpu_condition_result <= fpu_FPSR(28) OR NOT (fpu_FPSR(31) OR fpu_FPSR(30));
			WHEN "01011" =>  -- UGE (Unordered or Greater or Equal) - NaN | Z | !N
				fpu_condition_result <= fpu_FPSR(28) OR fpu_FPSR(30) OR NOT fpu_FPSR(31);
			WHEN "01100" =>  -- ULT (Unordered or Less Than) - NaN | (N & !Z)
				fpu_condition_result <= fpu_FPSR(28) OR (fpu_FPSR(31) AND NOT fpu_FPSR(30));
			WHEN "01101" =>  -- ULE (Unordered or Less or Equal) - NaN | Z | N
				fpu_condition_result <= fpu_FPSR(28) OR fpu_FPSR(30) OR fpu_FPSR(31);
			WHEN "01110" =>  -- NE (Not Equal) - !(Z & !NaN)
				fpu_condition_result <= NOT (fpu_FPSR(30) AND NOT fpu_FPSR(28));
			WHEN "01111" =>  -- T (True)
				fpu_condition_result <= '1';
			WHEN OTHERS =>  -- SF, SEQ, GT, GE, LT, LE, GL, GLE, NGLE, NGL, NLE, NLT, NGE, NGT, SNE, ST
				-- Additional signaling conditions - simplified to always false
				fpu_condition_result <= '0';
		END CASE;
	END PROCESS;

-----------------------------------------------------------------------------
-- MC68020 Coprocessor Format Word Generation
-----------------------------------------------------------------------------
PROCESS (fpu_busy, fpu_exception, fpu_fpsr)
	BEGIN
		-- Generate proper MC68020 coprocessor format words
		-- Based on current FPU state and MC68020 specification Table 7-2
		
		IF fpu_busy = '1' THEN
			-- FPU is busy - return "Not Ready, Come Again" format
			coprocessor_format_word <= X"01" & X"00" & X"0000";  -- Format $01, length don't care
		ELSIF fpu_exception = '1' OR fpu_fpsr /= X"00000000" THEN
			-- FPU has state - return valid format with IDLE state
			coprocessor_format_word <= X"60" & X"3C" & X"0000";  -- Format $60, length 60 bytes
		ELSE
			-- FPU in reset state - return empty/reset format
			coprocessor_format_word <= X"00" & X"04" & X"0000";  -- Format $00, length 4 bytes  
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- MEM_IO 
-----------------------------------------------------------------------------
PROCESS (clk, setdisp, memaddr_a, briefdata, memaddr_delta, setdispbyte, datatype, interrupt, rIPL_nr, IPL_vec,
         memaddr_reg, memaddr_delta_rega, memaddr_delta_regb, reg_QA, use_base, VBR, last_data_read, trap_vector, exec, set, cpu, use_VBR_Stackframe)
	BEGIN
		
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
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
				-- FPU Exception Vectors (MC68881/68882 compatible)
				IF trap_fpu_bsun='1' THEN
					trap_vector(9 downto 0) <= "00" & X"C0";  -- Vector 48 (0xC0)
				END IF;	
				IF trap_fpu_inexact='1' THEN
					trap_vector(9 downto 0) <= "00" & X"C4";  -- Vector 49 (0xC4)
				END IF;	
				IF trap_fpu_divzero='1' THEN
					trap_vector(9 downto 0) <= "00" & X"C8";  -- Vector 50 (0xC8)
				END IF;	
				IF trap_fpu_unfl='1' THEN
					trap_vector(9 downto 0) <= "00" & X"CC";  -- Vector 51 (0xCC)
				END IF;	
				IF trap_fpu_operr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"D0";  -- Vector 52 (0xD0)
				END IF;	
				IF trap_fpu_ovfl='1' THEN
					trap_vector(9 downto 0) <= "00" & X"D4";  -- Vector 53 (0xD4)
				END IF;	
				IF trap_fpu_snan='1' THEN
					trap_vector(9 downto 0) <= "00" & X"D8";  -- Vector 54 (0xD8)
				END IF;
				IF trap_fpu_trap='1' THEN
					trap_vector(9 downto 0) <= "00" & X"DC";  -- Vector 55 (0xDC) - FTRAPcc
				END IF;	
				IF trap_interrupt='1' or set_vectoraddr = '1' THEN
					trap_vector(9 downto 0) <= IPL_vec & "00";      --TH
				END IF;	
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
			IF fsave_predecr_flag = '1' THEN
				-- Special case for FSAVE: decrement current register value by frame size
				-- Use ALU to calculate (reg_QA - frame_size) properly
				CASE fsave_frame_size IS
					WHEN 4 =>   -- NULL frame
						memaddr_a <= reg_QA + X"FFFFFFFC";  -- Current register + (-4 in two's complement)
					WHEN 60 =>  -- IDLE frame  
						memaddr_a <= reg_QA + X"FFFFFFC4";  -- Current register + (-60 in two's complement)
					WHEN 216 => -- BUSY frame
						memaddr_a <= reg_QA + X"FFFFFF28";  -- Current register + (-216 in two's complement)
					WHEN OTHERS =>
						memaddr_a <= reg_QA + X"FFFFFFC4";  -- Default to IDLE frame size
				END CASE;
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
				IF memmaskmux(3)='0' OR exec(mem_addsub)='1' THEN
					memaddr_delta_rega <= addsub_q;
				ELSIF set(restore_ADDR)='1' THEN
					memaddr_delta_rega <= tmp_TG68_PC;
				ELSIF exec(direct_delta)='1' THEN
					memaddr_delta_rega <= data_read;
				ELSIF exec(ea_to_pc)='1' AND setstate="00" THEN
					memaddr_delta_rega <= addr;
				ELSIF set(addrlong)='1' THEN
					memaddr_delta_rega <= last_data_read;
				ELSIF setstate="00" THEN
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

		memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb;
		-- if access done, and not aligned, don't increment
		addr <= memaddr_reg+memaddr_delta;
		-- CPU manages all memory operations including FSAVE/FRESTORE
		-- MC68020 Coprocessor Interface: Generate proper CPU space addresses for FPU
		IF (micro_state = fpu1 OR micro_state = fpu2 OR micro_state = fpu_wait) AND
		   FPU_Enable = 1 AND opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" THEN
			-- CPU Space Cycle for MC68882 FPU coprocessor interface
			-- Format per MC68020 User's Manual Figure 7-3:
			-- A31-A20 = 0 (always zero)
			-- A19-A16 = 0010 (CPU space type $2 for coprocessor access)
			-- A15-A13 = 001 (FPU coprocessor ID from opcode bits 11-9)
			-- A12-A5 = 0 (always zero during coprocessor access)
			-- A4-A0 = CIR register selector (00000-11111)
			addr_out <= X"000" &       -- A31-A20: always zero (12 bits)
			           "0010" &        -- A19-A16: CPU space type $2 (coprocessor access)
			           "001" &         -- A15-A13: FPU coprocessor ID  
			           "00000000" &    -- A12-A5: always zero (8 bits)
			           cir_register_select;  -- A4-A0: Dynamic CIR register selection
		ELSE
			-- Normal memory operations
			addr_out <= memaddr_reg + memaddr_delta;
		END IF;

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
        PC_dataa, PC_datab, setnextpass, last_data_read, TG68_PC_brw, TG68_PC_word, Z_error, trap_trap, trap_trapv, interrupt, tmp_TG68_PC, TG68_PC, use_VBR_Stackframe, writePCnext, fpu_cpgen_complete, micro_state, sndOPC)
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
			-- CRITICAL FIX: Don't increment PC when completing FPU cpGEN instructions
			-- These instructions (like FTST) have already positioned PC correctly after fetching extension word
			IF fpu_cpgen_complete = '0' THEN
				PC_datab(1) <= '1';
			END IF;
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
			ELSIF stop='0' AND NOT (micro_state = fpu1 OR micro_state = fpu2 OR micro_state = fpu_wait) THEN
				-- CRITICAL FIX: Don't set setopcode when in FPU states that haven't completed
				setopcode <= '1';
			END IF;
		END IF;	
		setexecOPC <= '0';
		IF setstate="00" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) THEN
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
				fpu_cpgen_complete <= '0';  -- Initialize FPU cpGEN complete flag
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
				END IF;	
				IF clkena_lw='1' THEN
					interrupt <= setinterrupt;
					decodeOPC <= setopcode;
					endOPC <= setendOPC;
					execOPC <= setexecOPC;
					-- Clear FPU cpGEN complete flag when starting a new instruction
					IF setopcode = '1' THEN
						fpu_cpgen_complete <= '0';
					END IF;
--					IF setexecOPC='1' OR set(alu_exec)='1' THEN
--						execOPC_ALU <= '1';
--					ELSE
--						execOPC_ALU <= '0';
--					END IF;
					
					exe_datatype <= set_datatype;
					exe_opcode <= opcode;

					if(trap_berr='0') then
						make_berr <= (berr OR make_berr);
					else
						make_berr <= '0';
					end if;
						
					stop <= set_stop OR (stop AND NOT setinterrupt);
					IF setinterrupt='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
--						TG68_PC_word <= '0';
						make_berr <= '0';
						trap_berr <= '0';
						IF make_trace='1' THEN
							trap_trace <= '1';
						ELSIF make_berr='1' THEN
							trap_berr <= '1';
						ELSE	
							rIPL_nr <= IPL_nr;
							IPL_vec <= "00011"&IPL_nr;            --	TH		
							trap_interrupt <= '1';
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
					FC(1) <= NOT setstate(1) OR (PCbase AND NOT setstate(0));
					FC(0) <= setstate(1) AND (NOT PCbase OR setstate(0));
					IF interrupt='1' THEN
						FC(1 downto 0) <= "11";
					END IF;
					-- MC68020 Coprocessor Interface: CPU Space Cycles for FPU operations
					IF (micro_state = fpu1 OR micro_state = fpu2 OR micro_state = fpu_wait) AND
					   FPU_Enable = 1 AND opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" THEN
						FC(1 downto 0) <= "11";  -- CPU space FC1-FC0 = 11
						-- Generate proper coprocessor address format:
						-- A19-A16 = 0010 (coprocessor access)
						-- A15-A13 = 001 (FPU coprocessor ID)  
						-- A12-A5 = operation type and register
						-- A4-A1 = CIR register selector
					END IF;	
					
					IF state="11" THEN
						exec_write_back <= '0';
					ELSIF setstate="10" AND setaddrvalue='0' AND write_back='1' THEN
						exec_write_back <= '1';
					-- CRITICAL FIX: Clear exec_write_back when FPU operations complete to allow endOPC generation
					-- Clear exec_write_back when FPU operations complete
					ELSIF FPU_Enable = 1 AND next_micro_state = idle AND 
					      (micro_state = fpu_done OR micro_state = fpu_wait OR micro_state = fpu2) THEN
						exec_write_back <= '0';
					END IF;
					
					-- CRITICAL FIX: Set flag early for cpGEN FPU instructions to prevent PC over-increment
					-- These instructions have already positioned PC correctly via get_2ndOPC
					-- Set the flag as soon as we detect this is a cpGEN instruction
					IF opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND
					   opcode(8 downto 6) = "000" AND (micro_state = fpu1 OR micro_state = fpu2 OR 
					   micro_state = fpu_wait OR micro_state = fpu_done) THEN  -- cpGEN instructions including FTST
						fpu_cpgen_complete <= '1';
					END IF;	
					IF (state="10" AND addrvalue='0' AND write_back='1' AND setstate/="10") OR set_rot_cnt/="000001" OR (stop='1' AND interrupt='0') OR set_exec(opcCHK)='1' THEN
						state <= "01";
						memmask <= "111111";
						addrvalue <= '0';
					ELSIF execOPC='1' AND exec_write_back='1' THEN
						state <= "11";
						FC(1 downto 0) <= "01";
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
							memmask <= "100001";
							wbmemmask <= "100001";
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
							memmask <= "100111";
							wbmemmask <= "100111";
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
					IF getbrief='1' THEN
						IF state(1)='1' THEN
							brief <= last_opc_read(15 downto 0);
						ELSE
							brief <= data_read(15 downto 0);
						END IF;
					END IF;	
					
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
				
				-- FPU operations are now handled via CPU-managed FSAVE/FRESTORE
				-- No separate memory interface needed
				
				-- FPU CPU Data Interface - Provide correct data source to FPU
				-- For register direct operations (FMOVE.L D0,FP1), use register file
				-- For memory operations, use data bus
				IF (micro_state = fpu1 OR micro_state = fpu_wait) AND 
				   opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND
				   opcode(8 downto 6) = "000" AND opcode(5 downto 3) = "000" THEN
					-- FPU instruction with data register direct source (Dn)
					-- Use register file output instead of data bus
					fpu_cpu_data_in <= reg_QA;  -- D0-D7 register value
				ELSIF (micro_state = fpu1 OR micro_state = fpu_wait) AND
				      opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND
				      opcode(8 downto 6) = "000" AND opcode(5 downto 3) = "001" THEN
					-- FPU instruction with address register direct source (An)
					-- Use register file output instead of data bus  
					fpu_cpu_data_in <= reg_QA;  -- A0-A7 register value
				ELSE
					-- Memory or other operations - use data bus
					fpu_cpu_data_in <= X"0000" & data_in;
				END IF;
				
				-- FRESTORE data path: Send memory read data to FPU only during FRESTORE operations
				IF micro_state = fpu1 AND opcode(8 downto 6) = "101" THEN
					frestore_data_in <= data_read;
				END IF;
				
				-- FPU data size conversion removed - CPU handles all memory operations directly
				-- REMOVED BROKEN SECTION TEMPORARILY
			END IF;	
			IF clkena_lw='1' THEN
				exec <= set;
				exec(alu_move) <= set(opcMOVE) OR set(alu_move);
				exec(alu_setFlags) <= set(opcADD) OR set(alu_setFlags);
				exec_tas <= '0';
				-- Original behavior: presub operations need ALU in subtract mode EXCEPT for FSAVE
				IF set(presub) = '1' AND NOT (opcode(15 downto 6) = "1111001001" AND opcode(5 downto 3) = "100") THEN
					-- Normal predecrement: needs ALU subtract for address calculation  
					exec(subidx) <= '1';
				ELSE
					exec(subidx) <= set(subidx);
				END IF;
				exec(presub) <= set(presub);  -- CRITICAL FIX: Transfer presub signal for FSAVE predecrement
				IF setexecOPC='1' THEN
					exec <= set_exec OR set;
					exec(alu_move) <= set_exec(opcMOVE) OR set(opcMOVE) OR set(alu_move);
					exec(alu_setFlags) <= set_exec(opcADD) OR set(opcADD) OR set(alu_setFlags);
					exec_tas <= set_exec_tas;
					-- Handle presub -> subidx conversion in setexecOPC path too
					IF (set_exec(presub) = '1' OR set(presub) = '1') AND NOT (opcode(15 downto 6) = "1111001001" AND opcode(5 downto 3) = "100") THEN
						exec(subidx) <= '1';
					ELSE
						exec(subidx) <= set_exec(subidx) OR set(subidx);
					END IF;
					exec(presub) <= set_exec(presub) OR set(presub);  -- Maintain presub through setexecOPC
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
				FC(2) <= '1';
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
				IF trap_berr='1' OR trap_illegal='1' OR trap_addr_error='1' OR trap_priv='1' OR trap_1010='1' OR trap_1111='1' THEN
					make_trace <= '0';
					FlagsSR(7) <= '0';
				END IF;
				IF set(changeMode)='1' THEN
					preSVmode <= NOT preSVmode;
					FlagsSR(5) <= NOT preSVmode;
					FC(2) <= NOT preSVmode;
				END IF;
				IF micro_state=trap3 THEN
					FlagsSR(7) <= '0';
				END IF;
				IF trap_trace='1' AND state="10" THEN
					make_trace <= '0';
				END IF;
				IF exec(directSR)='1' OR set_stop='1' THEN
					FlagsSR <= data_read(15 downto 8);
				END IF;	
				IF interrupt='1' AND trap_interrupt='1' THEN
					FlagsSR(2 downto 0) <=rIPL_nr;
				END IF;	
				IF exec(to_SR)='1' THEN
					FlagsSR(7 downto 0) <= SRin;	--SR
					FC(2) <= SRin(5);
				ELSIF exec(update_FC)='1' THEN
					FC(2) <= FlagsSR(5);
				END IF;
				IF interrupt='1' THEN
					FC(2) <= '1';
				END IF;	
				IF cpu(1)='0' THEN
					FlagsSR(4) <= '0';
					FlagsSR(6) <= '0';
				END IF;
				-- Update condition codes from FPU FPSR
				IF FPU_Enable = 1 AND micro_state = fpu_done THEN
					-- Map FPU condition codes from FPSR to CPU CCR
					-- FPSR bits 31-28 contain condition codes
					FlagsSR(3) <= fpu_fpsr(31);  -- N (negative)
					FlagsSR(2) <= fpu_fpsr(30);  -- Z (zero)
					FlagsSR(1) <= '0';           -- V (overflow)
					FlagsSR(0) <= '0';           -- C (carry)
					-- Special handling for FTST to ensure proper completion
					IF opcode(6 downto 0) = "0111010" THEN
						-- FTST operation - ensure clean transition to next instruction
						NULL; -- Condition codes already updated above
					END IF;
				END IF;
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
		 long_start, set_datatype, sndOPC, set_exec, exec, ea_build_now, reg_QA, reg_QB, make_berr, trap_berr,
		 fpu_complete, fpu_exception, fpu_exception_code, fsave_counter, timeout_counter, fsave_frame_size, fsave_predecr_flag,
		 fmovem_reg_mask, fmovem_reg_count, fmovem_direction, fpu_condition_result)
	BEGIN
		TG68_PC_brw <= '0';	
		setstate <= "00";
		setaddrvalue <= '0';
		Regwrena_now <= '0';
		-- Initialize FPU trap signals to prevent latches
		trap_fpu_divzero <= '0';
		trap_fpu_operr <= '0';
		trap_fpu_ovfl <= '0';
		trap_fpu_unfl <= '0';
		trap_fpu_inexact <= '0';
		trap_fpu_snan <= '0';
		trap_fpu_bsun <= '0';
		trap_fpu_trap <= '0';
		-- Initialize FPU interface signals to prevent latches
		fpu_data_request <= '0';
		-- Initialize FMOVEM signals to prevent latches
		fmovem_reg_mask <= (others => '0');
		fmovem_direction <= '0';
		fmovem_reg_count <= 0;
		fmovem_data_request <= '0';
		fmovem_reg_index <= 0;
		fmovem_data_write <= '0';
		interrupt_mode <= '0';
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
		trapmake <='0';
		set_vectoraddr <='0';
		writeSR <= '0';
		set_stop <= '0';
--		illegal_write_mode <= '0';
--		illegal_read_mode <= '0';
--		illegal_byteaddr <= '0';
		set_Z_error <= '0';
		check_aligned <='0';

		-- Default to idle - only route to FPU if current instruction is actually FPU
		-- CRITICAL FIX: Only route to fpu1 if the CURRENT instruction is FPU, not just because we're in an FPU state
		-- This prevents infinite looping where non-FPU instructions get routed to FPU
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
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
		IF trapmake='1' AND trapd='0' THEN
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
	if micro_state = int1 or (interrupt = '1' and trap_trace = '1') then
	  if preSVmode = '0' then
		set(changeMode) <= '1';
	  end if;
	  setstate <= "01";
	end if;
		
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
			-- Set interrupt mode for proper ISP selection (68020+)
			interrupt_mode <= '1';
		END IF;
			
		IF set(changeMode)='1' THEN		
			-- 68020 three-stack model: USP, MSP, ISP
			-- Save current stack pointer and prepare for mode switch
			IF preSVmode='0' THEN
				-- Currently in user mode, switching to supervisor mode
				-- Save current A7 (USP) to USP storage
				set(to_USP) <= '1';
				-- Load appropriate supervisor stack pointer into A7
				IF interrupt_mode='1' THEN
					-- Load ISP for interrupt processing
					set(from_ISP) <= '1';
				ELSE
					-- Load MSP for normal supervisor mode
					set(from_MSP) <= '1';
				END IF;
			ELSE
				-- Currently in supervisor mode, switching to user mode  
				-- Save current A7 to appropriate supervisor storage
				IF interrupt_mode='1' THEN
					-- Save ISP 
					set(to_ISP) <= '1';
				ELSE
					-- Save MSP
					set(to_MSP) <= '1';
				END IF;
				-- Load USP into A7
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

		IF (ea_build_now='1' AND decodeOPC='1') OR exec(ea_build)='1' THEN
			CASE opcode(5 downto 3) IS		--source
				WHEN "010"|"011"|"100" =>						-- -(An)+
					set(get_ea_now) <='1';
					setnextpass <= '1';
					IF opcode(3)='1' THEN	--(An)+
						set(postadd) <= '1';
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
				ELSIF opcode(11 downto 9)="111" THEN		--MOVES not in 68000
					IF cpu(0)='1' AND opcode(7 downto 6)/="11" AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
						IF SVmode='1' THEN
							--TODO: implement MOVES
							trap_illegal <= '1';
							trapmake <= '1';
						ELSE
							trap_priv <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
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
								IF (nextpass='1' OR opcode(5 downto 4)="00") AND exec(opcCHK)='0' AND micro_state=idle AND 
								   NOT (opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001") THEN
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
									IF SR_Read=0 OR (cpu(0)='0' AND SR_Read=2) OR SVmode='1'  THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';							-- im 68000 wird auch erst gelesen
										IF cpu(0)='1' AND state="10" AND addrvalue='0' THEN
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
									IF SR_Read=1 OR (cpu(0)='1' AND SR_Read=2) THEN
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
									IF cpu(0)='1' AND state="10" AND addrvalue='0' THEN
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
											-- CRITICAL FIX: Only set movem_action for actual MOVEM instructions
											-- FPU instructions also use get_ea_now but should not trigger MOVEM logic
											IF movem_run='1' AND opcode(15 downto 12) = "0100" AND opcode(7)='1' THEN
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
										IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
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
										IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND exec(ea_build)='1')THEN
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
										
									WHEN "1111010"|"1111011" =>  									--movec
										IF cpu="00" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSIF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											datatype <= "10";	--Long
											IF last_data_read(11 downto 0)=X"800" THEN
												set(from_USP) <= '1';
												IF opcode(0)='1' THEN
													set(to_USP) <= '1';
												END IF;
											END IF;
											IF opcode(0)='0' THEN
												set_exec(movec_rd) <= '1';
											ELSE		
												set_exec(movec_wr) <= '1';
											END IF;
											IF decodeOPC='1' THEN
												next_micro_state <= movec1;
												getbrief <='1';
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
							IF cpu(0)='1' AND state="10" AND addrvalue='0' THEN
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
--		000-bftst, 001-bfextu, 010-bfchg, 011-bfexts, 100-bfclr, 101-bfffo, 110-bfset, 111-bfins								
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
				-- Check if this is an FPU instruction and FPU is enabled
				IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
					-- FPU coprocessor ID = 001 (0xF200-0xF3FF) for MC68881/68882 FPU
					-- Coprocessor ID 000 is reserved for MC68851 PMMU
					
					-- Check instruction type by bits 8:6
					IF opcode(8 downto 6) = "001" THEN
						-- FBcc - Floating-Point Branch Conditional (F280-F2BF)
						-- Check if this is word or long displacement
						IF decodeOPC='1' THEN
							IF opcode(5 downto 0) = "000000" THEN
								-- FBcc.W - Word displacement follows
								set(get_2ndOPC) <= '1';
								next_micro_state <= fpu1;  -- Will handle as cpGEN conditional
							ELSE
								-- FBcc.L - Long displacement follows
								set(longaktion) <= '1';
								next_micro_state <= fpu1;  -- Will handle as cpGEN conditional
							END IF;
						END IF;
					ELSIF opcode(8 downto 6) = "010" OR opcode(8 downto 6) = "011" THEN
						-- FScc/FTRAPcc - handle as cpGEN conditional instructions
						IF decodeOPC='1' THEN
							-- FScc and FTRAPcc are single-word when EA mode is Dn
							-- Check if EA mode is data register direct (bits 5:3 = 000)
							IF opcode(5 downto 3) = "000" THEN
								-- Single-word instruction - no extension word needed
								next_micro_state <= fpu1;
							ELSE
								-- Two-word instruction - need extension word for memory EA
								set(get_2ndOPC) <= '1';
								next_micro_state <= fpu1;
							END IF;
						END IF;
					ELSIF opcode(8 downto 6) = "100" OR opcode(8 downto 6) = "101" THEN
						-- FSAVE/FRESTORE - handle with special decoder logic below
						-- Fall through to cpSAVE/cpRESTORE handling
					ELSE
						-- Regular FPU instructions (FMOVE, FADD, etc.)
						-- Check if this is a single-word FPU instruction (cpGEN with register source)
						-- FTST with FPU register source (F201) is only one word
						IF decodeOPC='1' THEN
							-- Check if source is FPU register (bits 5:3 = 000 means FPU register mode)
							IF opcode(8 downto 6) = "000" AND opcode(5 downto 3) = "000" THEN
								-- Single-word cpGEN instruction with FPU register source
								-- No second word needed - go directly to FPU execution
								next_micro_state <= fpu1;
							ELSE
								-- Two-word instruction - need extension word
								set(get_2ndOPC) <= '1';
								next_micro_state <= fpu1;
							END IF;
						END IF;
					END IF;
					-- Don't trap - handle with FPU
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="100" THEN --cpSAVE
					-- Allow predecrement addressing mode for FSAVE
					IF opcode(5 downto 3)="100" THEN
						-- FSAVE -(An) - valid addressing mode for any address register, continue processing
						IF opcode(11 downto 9)/="000" THEN
							-- Check if this is FPU FSAVE (coprocessor ID = 001)
							IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
								-- FSAVE for MC68881/68882 - CPU manages memory, FPU provides data
								IF decodeOPC='1' THEN
									next_micro_state <= fpu2;
								END IF;
							ELSIF SVmode='1' THEN
								-- Other coprocessors (002-007) not present in this system
								-- Generate F-line exception for coprocessor not present
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF SVmode='1' THEN
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						-- All other supported FSAVE addressing modes: (An), (An)+, (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
						IF opcode(11 downto 9)/="000" THEN
							-- Check if this is FPU FSAVE (coprocessor ID = 001)
							IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
								-- FSAVE for MC68881/68882 - CPU manages memory, FPU provides data
								IF decodeOPC='1' THEN
									next_micro_state <= fpu2;
								END IF;
							ELSIF SVmode='1' THEN
								-- Other coprocessors (002-007) not present in this system
								-- Generate F-line exception for coprocessor not present
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF SVmode='1' THEN
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="101" THEN --cpRESTORE
					-- Allow postincrement addressing mode for FRESTORE
					IF opcode(5 downto 3)="011" THEN
						-- FRESTORE (An)+ - valid addressing mode for any address register, continue processing
						IF opcode(5 downto 1)/="11110" THEN
							-- Check if this is FPU FRESTORE (coprocessor ID = 001)
							IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
								-- FRESTORE for MC68881/68882 - route to FPU
								IF decodeOPC='1' THEN
									next_micro_state <= fpu1;
								END IF;
							ELSIF SVmode='1' THEN
								-- Other coprocessors (002-007) not present in this system
								-- Generate F-line exception for coprocessor not present
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_1111 <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						-- All other supported FRESTORE addressing modes: (An), -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L
						IF opcode(5 downto 1)/="11110" THEN
							-- Check if this is FPU FRESTORE (coprocessor ID = 001)
							IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
								-- FRESTORE for MC68881/68882 - route to FPU
								IF decodeOPC='1' THEN
									next_micro_state <= fpu1;
								END IF;
							ELSIF SVmode='1' THEN
								-- Other coprocessors (002-007) not present in this system
								-- Generate F-line exception for coprocessor not present
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_1111 <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				-- Add missing coprocessor instruction types
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="000" THEN --cpGEN (General coprocessor instructions)
					-- Check if this is FPU instruction (coprocessor ID = 001)
					IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
						-- FPU general instruction - route to FPU
						-- Check if this is FNOP (F$280) which is single-word, others need extension word
						IF opcode(5 downto 0) = "000000" THEN
							-- FNOP - single word instruction, no extension word needed
							IF decodeOPC='1' THEN
								next_micro_state <= fpu1;
							END IF;
						ELSE
							-- Other cpGEN FPU instructions need extension word
							IF decodeOPC='1' THEN
								set(get_2ndOPC) <= '1';
								next_micro_state <= fpu1;
							END IF;
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="001" THEN --cpDBcc (Coprocessor conditional branch/decrement)
					-- Check if this is FPU instruction (coprocessor ID = 001)
					IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
						-- FPU conditional branch - route to FPU
						-- All FPU instructions are two-word instructions requiring extension word fetch
						IF decodeOPC='1' THEN
							set(get_2ndOPC) <= '1';
							next_micro_state <= fpu1;
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="010" THEN --cpScc (Coprocessor set conditionally)
					-- Check if this is FPU instruction (coprocessor ID = 001)
					IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
						-- FPU set conditionally - route to FPU
						-- All FPU instructions are two-word instructions requiring extension word fetch
						IF decodeOPC='1' THEN
							set(get_2ndOPC) <= '1';
							next_micro_state <= fpu1;
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="011" THEN --cpTRAPcc (Coprocessor trap conditionally)
					-- Check if this is FPU instruction (coprocessor ID = 001)
					IF FPU_Enable = 1 AND opcode(11 downto 9) = "001" THEN
						-- FPU trap conditionally - route to FPU
						-- All FPU instructions are two-word instructions requiring extension word fetch
						IF decodeOPC='1' THEN
							set(get_2ndOPC) <= '1';
							next_micro_state <= fpu1;
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSE
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
-- microcode state machine
-----------------------------------------------------------------------------


			CASE micro_state IS
				WHEN ld_nn =>		-- (nnnn).w/l=>
					set(get_ea_now) <='1';
					setnextpass <= '1';
					set(addrlong) <= '1';
					
				WHEN st_nn =>		-- =>(nnnn).w/l
					setstate <= "11";
					set(addrlong) <= '1';
					next_micro_state <= nop;
					
				WHEN ld_dAn1 =>		-- d(An)=>, --d(PC)=>
					set(get_ea_now) <='1';
					setdisp <= '1';		--word
					setnextpass <= '1';
					
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
						IF trap_interrupt='1' OR trap_trace='1' OR trap_berr='1' OR 
						   trap_1111='1' OR trap_1010='1' OR trap_illegal='1' OR 
						   trap_priv='1' OR trap_addr_error='1' THEN
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
											-- check for stack frame format #2
					if last_data_in(15 downto 12)="0010" then
										  -- read another 32 bits in this case
						setstate <= "10"; -- read
						datatype <= "10"; -- long word
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state <= rte5;
					else
						datatype <= "01";
						next_micro_state <= nop;
					end if;
				WHEN rte5 =>            -- RTE
					next_micro_state <= nop;
					-- Clear interrupt mode when returning from exception (68020+)
					interrupt_mode <= '0';
-------------------------------------

				WHEN rtd1 =>		-- RTD
					next_micro_state <= rtd2;
				WHEN rtd2 =>		-- RTD
					setstackaddr <= '1';
					set(Regwrena) <= '1';
					
				WHEN movec1 =>		-- MOVEC
					set(briefext) <= '1';
					set_writePCbig <='1';
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
				
				-- FPU state handlers
				WHEN fpu1 =>
					-- MC68020 cpGEN Protocol Implementation
					-- Step 1: Write instruction command word to Command CIR
					-- Step 2: Read Response CIR for coprocessor status and response primitives
					
					-- Check instruction type and follow appropriate MC68020 coprocessor protocol
					IF opcode(8 downto 6) = "000" THEN
						-- cpGEN instruction - follow MC68020 coprocessor protocol
						IF state = "00" THEN
							-- Phase 1: Write command word to Command CIR (register 0x01)
							-- CPU space cycle with FC=111, A4-A0=00001 (Command register)
							setstate <= "01";  -- Write cycle to coprocessor
							next_micro_state <= fpu2;  -- Proceed to read Response CIR
							skipFetch <= '1';
						END IF;
					ELSIF opcode(8 downto 6) = "001" OR opcode(8 downto 6) = "010" OR opcode(8 downto 6) = "011" THEN
						-- Conditional instructions (FDBcc, FScc, FTRAPcc) - follow conditional protocol
						IF state = "00" THEN
							-- Phase 1: Write condition selector to Condition CIR (register 0x04)
							-- CPU space cycle with FC=111, A4-A0=00100 (Condition register)
							setstate <= "01";  -- Write cycle to coprocessor
							next_micro_state <= fpu2;  -- Proceed to read Response CIR for true/false result
							skipFetch <= '1';
						END IF;
					ELSIF opcode(8 downto 6) = "100" THEN
						-- cpSAVE instruction - follow MC68020 coprocessor state frame protocol
						IF state = "00" THEN
							-- Phase 1: Read Save CIR (register 0x03) for format word
							-- CPU space cycle with FC=111, A4-A0=00011 (Save CIR)
							setstate <= "10";  -- Read cycle from coprocessor
							next_micro_state <= fpu2;  -- Process format word and begin save
							skipFetch <= '1';
						END IF;
					ELSIF opcode(8 downto 6) = "101" THEN
						-- cpRESTORE instruction - follow MC68020 coprocessor state frame protocol
						IF state = "00" THEN
							-- Phase 1: Write format word to Restore CIR (register 0x03)
							-- Format word read from memory at EA
							-- CPU space cycle with FC=111, A4-A0=00011 (Restore CIR)
							setstate <= "01";  -- Write cycle to coprocessor
							next_micro_state <= fpu2;  -- Read Restore CIR for response
							skipFetch <= '1';
						END IF;
					ELSE
						-- Non-cpGEN instructions (FSAVE, FRESTORE) - handle addressing modes
						-- This ensures predecrement/postincrement operations work correctly
						
						-- Check if this is a regular FPU instruction that needs addressing mode processing
						IF opcode(8 downto 6) /= "100" AND opcode(8 downto 6) /= "101" THEN
						-- Regular FPU instruction (FMOVE, FADD, FSUB, FTST, etc.)
						-- Handle addressing modes based on EA field in bits 5:0
						
						-- CRITICAL: Prevent register writes for FPU instructions that don't write to CPU registers
						-- Check the FPU operation code and instruction type
						-- CRITICAL FIX: FTST is a cpGEN instruction (opcode bits 8:6 = 000), not here
						-- Remove FTST from this check as it's handled through cpGEN protocol
						IF sndOPC(6 downto 0) = "0111000" OR    -- FCMP (compare operands)
						   sndOPC(6 downto 0) = "0111010" OR    -- FTST (test operand)
						   (sndOPC(6 downto 0) = "0000000" AND opcode(13 downto 10) = "0000") OR  -- FNOP (no operation)
						   (opcode(8 downto 6) = "001" AND opcode(5 downto 3) = "111" AND 
						    (opcode(2 downto 0) = "010" OR opcode(2 downto 0) = "011")) OR  -- FBcc.W/FBcc.L (branch)
						   (opcode(8 downto 6) = "011" AND opcode(5 downto 3) = "111" AND 
						    opcode(2 downto 0) = "100") THEN  -- FTRAPcc (trap conditionally)
							-- These operations should never write to CPU data/address registers
							skipFetch <= '1';  -- Prevent further instruction fetches
							set_exec(Regwrena) <= '0';
							set_exec(save_memaddr) <= '0';
							set_exec(get_ea_now) <= '0';
							set_exec(write_reg) <= '0';
						END IF;
						
						-- For source operand addressing (typically bits 5:0 in FPU instructions)
						-- Handle different addressing modes
						IF opcode(5 downto 3) = "000" THEN
							-- Data register direct mode (Dn) - FMOVE.L D0,FP1, etc.
							-- Set up register file to read the specified data register
							datatype <= "10";  -- Longword
							source_lowbits <= '1';  -- Select register from bits 2:0
							source_areg <= '0';     -- Data register
							-- Need to wait one cycle for register to be read
							IF state = "00" THEN
								setstate <= "01";  -- Wait state for register read
								next_micro_state <= fpu1;
							ELSE
								-- Register has been read, proceed to FPU operation
								next_micro_state <= fpu_wait;
							END IF;
							skipFetch <= '1';  -- Don't fetch while waiting
						ELSIF opcode(5 downto 3) = "001" THEN
							-- Address register direct mode (An) 
							datatype <= "10";  -- Longword
							source_lowbits <= '1';  -- Select register from bits 2:0
							source_areg <= '1';     -- Address register
							-- Need to wait one cycle for register to be read
							IF state = "00" THEN
								setstate <= "01";  -- Wait state for register read
								next_micro_state <= fpu1;
							ELSE
								-- Register has been read, proceed to FPU operation
								next_micro_state <= fpu_wait;
							END IF;
							skipFetch <= '1';  -- Don't fetch while waiting
						ELSIF opcode(5 downto 3) = "100" THEN
							-- Predecrement addressing mode -(An)
							set(presub) <= '1';
							setstackaddr <= '1';
							IF opcode(2 downto 0) = "111" THEN
								set(use_SP) <= '1';  -- Use stack pointer
							END IF;
							-- Set appropriate datatype based on FPU operation size
							-- Most FPU operations use longwords by default
							datatype <= "10";  -- Longword
							source_lowbits <= '1';  -- Select register from bits 2:0
							source_areg <= '1';     -- Address register
							-- Need to wait one cycle for register to be read
							IF state = "00" THEN
								setstate <= "01";  -- Wait state for register read
								next_micro_state <= fpu1;
							ELSE
								-- Register has been read, proceed to FPU operation
								next_micro_state <= fpu_wait;
							END IF;
							skipFetch <= '1';  -- Don't fetch while waiting
						ELSIF opcode(5 downto 3) = "011" THEN
							-- Postincrement addressing mode (An)+
							set(postadd) <= '1';
							setstackaddr <= '1';
							IF opcode(2 downto 0) = "111" THEN
								set(use_SP) <= '1';  -- Use stack pointer
							END IF;
							datatype <= "10";  -- Longword
							source_lowbits <= '1';  -- Select register from bits 2:0
							source_areg <= '1';     -- Address register
							-- Need to wait one cycle for register to be read
							IF state = "00" THEN
								setstate <= "01";  -- Wait state for register read
								next_micro_state <= fpu1;
							ELSE
								-- Register has been read, proceed to FPU operation
								next_micro_state <= fpu_wait;
							END IF;
							skipFetch <= '1';  -- Don't fetch while waiting
						ELSE
							-- Other addressing modes
							next_micro_state <= fpu_wait;  -- Go to FPU wait for execution
						END IF;
					END IF;
					
					-- Now handle specific FPU instruction types
					IF opcode(8 downto 6) = "101" THEN
						-- FRESTORE - MC68882 compatible implementation with all addressing modes
						-- Read 15 longwords (60 bytes) from memory
						
						datatype <= "10";  -- Longword access
						
						CASE opcode(5 downto 3) IS
							WHEN "010" =>  -- (An) - Address Register Indirect
								setstate <= "10";  -- Memory read
								set(get_ea_now) <= '1';
								IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
									next_micro_state <= fpu1;  -- Continue for more reads
								ELSE
									setstate <= "00";  -- Ensure proper endOPC condition
									next_micro_state <= fpu_done;  -- All done
								END IF;
								
							WHEN "011" =>  -- (An)+ - Address Register Indirect with Postincrement
								setstate <= "10";  -- Memory read
								set(get_ea_now) <= '1';
								set(postadd) <= '1';  -- Postincrement by 4 bytes
								IF opcode(2 downto 0) = "111" THEN
									set(use_SP) <= '1';  -- Use A7 if (A7)+
									setstackaddr <= '1';  -- Update stack pointer
								END IF;
								IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
									next_micro_state <= fpu1;  -- Continue for more reads
								ELSE
									setstate <= "00";  -- Ensure proper endOPC condition
									next_micro_state <= fpu_done;  -- All done
								END IF;
								
							WHEN "100" =>  -- -(An) - Address Register Indirect with Predecrement
								-- CRITICAL FIX: Separate predecrement and memory operations for proper DSACK timing
								IF state = "00" THEN
									-- Phase 1: Calculate predecrement address and update register
									set(presub) <= '1';  -- Predecrement by 4 bytes
									IF opcode(2 downto 0) = "111" THEN
										set(use_SP) <= '1';  -- Use A7 if -(A7)
										setstackaddr <= '1';  -- Update stack pointer
									END IF;
									setstate <= "01";  -- Wait for register update to complete
									next_micro_state <= fpu1;  -- Stay in fpu1 for next phase
								ELSE
									-- Phase 2: Start memory read after register update completed
									setstate <= "10";  -- Memory read
									IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
										next_micro_state <= fpu1;  -- Continue for more reads
									ELSE
										setstate <= "00";  -- Ensure proper endOPC condition
										next_micro_state <= fpu_done;  -- All done
									END IF;
								END IF;
								
							WHEN "101" =>  -- (d16,An) - Address Register Indirect with Displacement
								IF fsave_counter = 0 THEN
									-- First read: Calculate EA, then continue in fpu_done
									set(store_ea_data) <= '1';
									next_micro_state <= ld_dAn1;  -- Calculate EA first
								ELSE
									-- Subsequent reads: EA already calculated, use it directly
									setstate <= "10";  -- Memory read
									IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
										next_micro_state <= fpu1;  -- Continue for more reads
									ELSE
										setstate <= "00";  -- Ensure proper endOPC condition
										next_micro_state <= fpu_done;  -- All done
									END IF;
								END IF;
								
							WHEN "110" =>  -- (d8,An,Xn) - Address Register Indirect with Index
								IF fsave_counter = 0 THEN
									-- First read: Calculate EA, then continue in fpu_done
									set(store_ea_data) <= '1';
									next_micro_state <= ld_AnXn1;  -- Calculate EA first
									getbrief <= '1';
								ELSE
									-- Subsequent reads: EA already calculated, use it directly
									setstate <= "10";  -- Memory read
									IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
										next_micro_state <= fpu1;  -- Continue for more reads
									ELSE
										setstate <= "00";  -- Ensure proper endOPC condition
										next_micro_state <= fpu_done;  -- All done
									END IF;
								END IF;
								
							WHEN "111" =>  -- Absolute addressing modes
								CASE opcode(2 downto 0) IS
									WHEN "000" =>  -- (xxxx).w - Absolute Short
										IF fsave_counter = 0 THEN
											-- First read: Calculate EA, then continue in fpu_done
											set(store_ea_data) <= '1';
											next_micro_state <= ld_nn;
										ELSE
											-- Subsequent reads: EA already calculated, use it directly
											setstate <= "10";  -- Memory read
											IF fsave_counter < 14 THEN
												next_micro_state <= fpu1;  -- Continue for more reads
											ELSE
												setstate <= "00";  -- Ensure proper endOPC condition
												next_micro_state <= fpu_done;  -- All done
											END IF;
										END IF;
										
									WHEN "001" =>  -- (xxxx).l - Absolute Long
										IF fsave_counter = 0 THEN
											-- First read: Calculate EA, then continue in fpu_done
											set(store_ea_data) <= '1';
											set(longaktion) <= '1';
											next_micro_state <= ld_nn;
										ELSE
											-- Subsequent reads: EA already calculated, use it directly
											setstate <= "10";  -- Memory read
											IF fsave_counter < 14 THEN
												next_micro_state <= fpu1;  -- Continue for more reads
											ELSE
												setstate <= "00";  -- Ensure proper endOPC condition
												next_micro_state <= fpu_done;  -- All done
											END IF;
										END IF;
										
									WHEN OTHERS =>
										-- Invalid addressing modes (PC-relative not allowed)
										setstate <= "00";  -- Ensure proper endOPC condition
										next_micro_state <= fpu_done;
								END CASE;
								
							WHEN OTHERS =>
								-- Invalid addressing modes (Dn, An not allowed for FRESTORE)
								setstate <= "00";  -- Ensure proper endOPC condition
								next_micro_state <= fpu_done;
						END CASE;
					ELSIF opcode(8 downto 6) = "110" THEN
						-- FMOVEM instruction - multiple register move
						-- Check if this is control register FMOVEM or FP register FMOVEM
						IF sndOPC(12 downto 10) /= "000" AND sndOPC(7 downto 0) = "00000000" THEN
							-- FMOVEM control registers (FPCR/FPSR/FPIAR)
							-- Start FMOVEM control register operation
							fmovem_active <= '1';
							fmovem_reg_mask <= sndOPC(12 downto 10) & "00000";  -- Control register mask in upper bits
							fmovem_direction <= sndOPC(13);         -- 0=to memory, 1=from memory
							fmovem_reg_count <= 0;                  -- Start processing
							next_micro_state <= fpu_fmovem_cr;      -- Control register FMOVEM state
						ELSIF sndOPC(7 downto 0) = "00000000" THEN
							-- No registers selected - operation complete
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= fpu_done;
						ELSE
							-- FP register FMOVEM
							-- Start FMOVEM operation
							-- Initialize FMOVEM state variables
							fmovem_active <= '1';
							fmovem_reg_mask <= sndOPC(7 downto 0);  -- Register mask from extension word
							fmovem_direction <= sndOPC(13);         -- 0=to memory, 1=from memory
							fmovem_reg_count <= 0;                  -- Start with register 0
							next_micro_state <= fpu_fmovem;         -- FP register FMOVEM state
						END IF;
						ELSE
							-- Regular FPU arithmetic operation
							-- next_micro_state already set by addressing mode handling above
							NULL;  -- Don't override the state set by addressing mode
						END IF;
					END IF;  -- End of cpGEN vs non-cpGEN check
					
				WHEN fpu2 =>
					-- MC68020 Coprocessor Protocol - Phase 2: Read Response CIR
					-- Handle both cpGEN and conditional instructions
					IF opcode(8 downto 6) = "000" THEN
						-- cpGEN instruction - read Response CIR for coprocessor status
						IF state = "00" THEN
							-- Phase 2: Read Response CIR (register 0x00) for response primitives
							-- CPU space cycle with FC=111, A4-A0=00000 (Response register)
							setstate <= "10";  -- Read cycle from coprocessor
							next_micro_state <= fpu_wait;  -- Analyze response and continue
							skipFetch <= '1';
						END IF;
					ELSIF opcode(8 downto 6) = "001" OR opcode(8 downto 6) = "010" OR opcode(8 downto 6) = "011" THEN
						-- Conditional instruction - read Response CIR for true/false result
						IF state = "00" THEN
							-- Phase 2: Read Response CIR (register 0x00) for condition result
							-- CPU space cycle with FC=111, A4-A0=00000 (Response register)
							setstate <= "10";  -- Read cycle from coprocessor
							next_micro_state <= fpu_wait;  -- Process condition result
							skipFetch <= '1';
						END IF;
					ELSIF opcode(8 downto 6) = "100" THEN
						-- cpSAVE instruction - process format word from Save CIR
						-- data_read contains format word from coprocessor
						-- Process format word and begin state frame save to memory
						next_micro_state <= fpu_wait;  -- Continue with memory operations
					ELSIF opcode(8 downto 6) = "101" THEN
						-- cpRESTORE instruction - read Restore CIR for response
						IF state = "00" THEN
							-- Phase 2: Read Restore CIR (register 0x03) for response
							-- CPU space cycle with FC=111, A4-A0=00011 (Restore CIR)
							setstate <= "10";  -- Read cycle from coprocessor
							next_micro_state <= fpu_wait;  -- Process response and continue
							skipFetch <= '1';
						END IF;
					ELSE
						-- FSAVE - MC68882 compatible implementation with all addressing modes
						-- Write 15 longwords (60 bytes) to memory
					
					datatype <= "10";  -- Longword access
					-- CRITICAL FIX: Force correct datatype for all FSAVE operations
					-- This prevents byte mode from previous instructions corrupting registers
					set_datatype <= "10";  -- Ensure exe_datatype gets updated
					
					CASE opcode(5 downto 3) IS
						WHEN "010" =>  -- (An) - Address Register Indirect
							set(get_ea_now) <= '1';
							fpu_data_request <= '1';  -- Request data from FPU
							IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
								setstate <= "11";  -- Memory write
								next_micro_state <= fpu2;  -- Continue for more writes
							ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
								-- This is the last write
								IF state = "00" THEN
									-- Ready to initiate last write
									setstate <= "11";           -- Final memory write
									next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
								ELSE
									-- Last write is in progress, wait for completion
									next_micro_state <= fpu2;   -- Keep waiting
								END IF;
							ELSE
								-- All writes complete, go to idle
								setstate <= "00";  -- Ensure proper endOPC condition
								next_micro_state <= idle;   -- All done
							END IF;
							
						WHEN "011" =>  -- (An)+ - Address Register Indirect with Postincrement
							set(get_ea_now) <= '1';
							set(postadd) <= '1';  -- Postincrement by 4 bytes
							IF opcode(2 downto 0) = "111" THEN
								set(use_SP) <= '1';  -- Use A7 if (A7)+
							END IF;
							fpu_data_request <= '1';  -- Request data from FPU
							IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
								setstate <= "11";  -- Memory write
								next_micro_state <= fpu2;  -- Continue for more writes
							ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
								-- This is the last write
								IF state = "00" THEN
									-- Ready to initiate last write
									setstate <= "11";           -- Final memory write
									next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
								ELSE
									-- Last write is in progress, wait for completion
									next_micro_state <= fpu2;   -- Keep waiting
								END IF;
							ELSE
								-- All writes complete, go to idle
								setstate <= "00";  -- Ensure proper endOPC condition
								set_rot_cnt <= "000001";  -- Reset rotation counter
								setnextpass <= '0';  -- Clear nextpass
								-- CRITICAL: Clear all FSAVE-related flags to prevent interference
								-- fsave_predecr_flag cleared in clocked process
								set(presub) <= '0';
								set(subidx) <= '0';
								next_micro_state <= idle;   -- All done
							END IF;
							
						WHEN "100" =>  -- -(An) - Address Register Indirect with Predecrement
							-- FIXED: Two-phase predecrement for proper register update timing
							-- Frame size is determined in clocked process based on fsave_predecr_flag
							
							IF fsave_counter = 0 THEN
								-- First write requires two phases for proper timing
								IF state = "00" THEN
									-- Phase 1: Calculate predecrement address and update register
									set(get_ea_now) <= '1';           -- Calculate effective address
									set(presub) <= '1';               -- Predecrement by frame size
									
									IF opcode(2 downto 0) = "111" THEN
										set(use_SP) <= '1';           -- Use stack pointer if -(A7)
										setstackaddr <= '1';          -- Ensure update goes to stack pointer
									END IF;
									
									set(Regwrena) <= '1';             -- Update An with decremented value
									setstate <= "01";                 -- Wait for register update to complete
									next_micro_state <= fpu2;         -- Stay in fpu2 for next phase
								ELSE
									-- Phase 2: Start memory write after register update completed
									fpu_data_request <= '1';          -- Request data from FPU
									setstate <= "11";                 -- Memory write
									next_micro_state <= fpu2;         -- Continue for more writes
								END IF;
								
							ELSE
								-- Subsequent writes: Use saved base address + offset
								-- The base address was calculated and saved during first write
								set(mem_addsub) <= '1';               -- Use memory address with offset
								
								fpu_data_request <= '1';              -- Request data from FPU
								
								IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
									setstate <= "11";                 -- Memory write
									next_micro_state <= fpu2;         -- More writes to do
								ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
									-- This is the last write
									setstate <= "11";                 -- Final memory write
									next_micro_state <= fpu2;         -- Stay to monitor completion
								ELSE
									-- All writes complete, go to idle
									setstate <= "00";                 -- Ensure proper endOPC condition
									next_micro_state <= idle;         -- All done
								END IF;
							END IF;
							
						WHEN "101" =>  -- (d16,An) - Address Register Indirect with Displacement
							IF fsave_counter = 0 THEN
								-- First write: Calculate EA, then continue in fpu_done
								set(store_ea_data) <= '1';
								next_micro_state <= ld_dAn1;  -- Calculate EA first
							ELSE
								-- Subsequent writes: EA already calculated, use it directly
								setstate <= "11";  -- Memory write
								fpu_data_request <= '1';  -- Request data from FPU
								IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
									next_micro_state <= fpu2;  -- Continue for more writes
								ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
									-- This is the last write
									IF state = "00" THEN
										-- Ready to initiate last write
										setstate <= "11";           -- Final memory write
										next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
									ELSE
										-- Last write is in progress, wait for completion
										next_micro_state <= fpu2;   -- Keep waiting
									END IF;
								ELSE
									-- All writes complete, go to idle
									setstate <= "00";  -- Ensure proper endOPC condition
									next_micro_state <= idle;   -- All done
								END IF;
							END IF;
							
						WHEN "110" =>  -- (d8,An,Xn) - Address Register Indirect with Index
							IF fsave_counter = 0 THEN
								-- First write: Calculate EA, then continue in fpu_done
								set(store_ea_data) <= '1';
								next_micro_state <= ld_AnXn1;  -- Calculate EA first
								getbrief <= '1';
							ELSE
								-- Subsequent writes: EA already calculated, use it directly
								setstate <= "11";  -- Memory write
								fpu_data_request <= '1';  -- Request data from FPU
								IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
									next_micro_state <= fpu2;  -- Continue for more writes
								ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
									-- This is the last write
									IF state = "00" THEN
										-- Ready to initiate last write
										setstate <= "11";           -- Final memory write
										next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
									ELSE
										-- Last write is in progress, wait for completion
										next_micro_state <= fpu2;   -- Keep waiting
									END IF;
								ELSE
									-- All writes complete, go to idle
									setstate <= "00";  -- Ensure proper endOPC condition
									next_micro_state <= idle;   -- All done
								END IF;
							END IF;
							
						WHEN "111" =>  -- Absolute addressing modes
							CASE opcode(2 downto 0) IS
								WHEN "000" =>  -- (xxxx).w - Absolute Short
									IF fsave_counter = 0 THEN
										-- First write: Calculate EA, then continue in fpu_done
										set(store_ea_data) <= '1';
										next_micro_state <= ld_nn;
									ELSE
										-- Subsequent writes: EA already calculated, use it directly
										setstate <= "11";  -- Memory write
										fpu_data_request <= '1';  -- Request data from FPU
										IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
											next_micro_state <= fpu2;  -- Continue for more writes
										ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
											-- This is the last write
											IF state = "00" THEN
												-- Ready to initiate last write
												setstate <= "11";           -- Final memory write
												next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
											ELSE
												-- Last write is in progress, wait for completion
												next_micro_state <= fpu2;   -- Keep waiting
											END IF;
										ELSE
											-- All writes complete, go to idle
											setstate <= "00";  -- Ensure proper endOPC condition
											next_micro_state <= idle;   -- All done
										END IF;
									END IF;
									
								WHEN "001" =>  -- (xxxx).l - Absolute Long
									IF fsave_counter = 0 THEN
										-- First write: Calculate EA, then continue in fpu_done
										set(store_ea_data) <= '1';
										set(longaktion) <= '1';
										next_micro_state <= ld_nn;
									ELSE
										-- Subsequent writes: EA already calculated, use it directly
										setstate <= "11";  -- Memory write
										fpu_data_request <= '1';  -- Request data from FPU
										IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
											next_micro_state <= fpu2;  -- Continue for more writes
										ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
											-- This is the last write
											IF state = "00" THEN
												-- Ready to initiate last write
												setstate <= "11";           -- Final memory write
												next_micro_state <= fpu2;   -- Stay in fpu2 to monitor completion
											ELSE
												-- Last write is in progress, wait for completion
												next_micro_state <= fpu2;   -- Keep waiting
											END IF;
										ELSE
											-- All writes complete, go to idle
											setstate <= "00";  -- Ensure proper endOPC condition
											next_micro_state <= idle;   -- All done
										END IF;
									END IF;
									
								WHEN OTHERS =>
									-- Invalid addressing modes (PC-relative not allowed)
									-- Don't leave setstate in bad state
									next_micro_state <= idle;
							END CASE;
							
						WHEN OTHERS =>
							-- Invalid addressing modes (Dn, An not allowed for FSAVE)
							next_micro_state <= idle;
					END CASE;
					END IF;  -- End of cpGEN vs FSAVE check in fpu2
					
				WHEN fpu_wait =>
					-- MC68020 cpGEN Protocol - Phase 3: Handle Response Primitives
					-- For cpGEN instructions, analyze response from Response CIR
					-- For other instructions, wait for FPU completion
					
					IF opcode(8 downto 6) = "000" THEN
						-- cpGEN instruction - handle response primitives from Response CIR
						-- Response primitives include: $00=null, $01=ca, $02=na, etc.
						-- For now, simplified: proceed directly to completion
						-- Real implementation would decode response primitive from data_read
						-- and handle requests for additional data, exceptions, etc.
						
						-- CRITICAL FIX: Ensure proper state for cpGEN completion
						setstate <= "00";  -- Clear state to allow proper endOPC generation
						setnextpass <= '0';  -- Clear nextpass to prevent instruction pipeline issues
						set_rot_cnt <= "000001";  -- Reset rotation counter
						-- CRITICAL FIX: Clear execution flags early to prevent overlap
						set_exec <= (others => '0');
						-- Clear any pending operations
						set(presub) <= '0';
						set(subidx) <= '0';
						write_back <= '0';
						
						next_micro_state <= fpu_done;  -- Complete the cpGEN instruction
					ELSIF opcode(8 downto 6) = "001" OR opcode(8 downto 6) = "010" OR opcode(8 downto 6) = "011" THEN
						-- Conditional instruction - process true/false result from Response CIR
						-- data_read contains the condition result from coprocessor
						-- CPU completes the instruction based on this result
						
						-- Use actual condition result from FPU condition evaluation
						-- Complete the appropriate action based on condition result
						
						CASE opcode(8 downto 6) IS
							WHEN "001" =>  -- FBcc or FDBcc
								-- Check addressing mode to distinguish FBcc from FDBcc
								IF opcode(5 downto 3) = "111" AND (opcode(2 downto 0) = "010" OR opcode(2 downto 0) = "011") THEN
									-- FBcc - Branch conditionally (mode 111, reg 010=word or 011=long)
									-- The condition has been evaluated, go to done state
									next_micro_state <= fpu_done;
								ELSE
									-- FDBcc - Decrement and branch conditionally
									-- Step 1: Decrement data register (Dn = opcode bits 2:0)
									-- Step 2: If condition false OR Dn = -1, continue; else branch
									IF fpu_condition_result = '0' THEN
										-- Condition false - continue to next instruction
										next_micro_state <= fpu_done;
									ELSE
										-- Condition true - implement decrement and branch logic
										-- TODO: Implement register decrement
										next_micro_state <= fpu_done;
									END IF;
								END IF;
								
							WHEN "010" =>  -- FScc - Set byte conditionally  
								-- Set destination byte: $FF if condition true, $00 if false
								-- Destination addressing mode in opcode bits 5:0
								datatype <= "00";  -- Byte operation
								-- FScc operation will be handled via set mechanism
								-- Handle destination EA
								CASE opcode(5 downto 3) IS
									WHEN "000" =>  -- Dn
										dest_hbits <= '1';
										dest_areg <= '0';
										set_exec(Regwrena) <= '1';
										-- Don't use write_reg for FScc; handled via regin
										next_micro_state <= fpu_done;
									WHEN "010" =>  -- (An)
										set(no_Flags) <= '1';
										setstate <= "11";  -- Write cycle
										next_micro_state <= fpu_done;
									WHEN "011" =>  -- (An)+
										set(no_Flags) <= '1';
										set(postadd) <= '1';
										set_exec(Regwrena) <= '1';
										setstate <= "11";  -- Write cycle
										next_micro_state <= fpu_done;
									WHEN "100" =>  -- -(An)
										set(no_Flags) <= '1';
										set(presub) <= '1';
										set_exec(Regwrena) <= '1';
										setstate <= "11";  -- Write cycle
										next_micro_state <= fpu_done;
									WHEN "101" =>  -- d16(An)
										-- Need to fetch displacement
										set(get_ea_now) <= '1';
										set(ea_build) <= '1';
										next_micro_state <= fpu_done;
									WHEN "110" =>  -- d8(An,Xn)
										-- Need to fetch extension word
										set(get_ea_now) <= '1';
										set(ea_build) <= '1';
										next_micro_state <= fpu_done;
									WHEN "111" =>
										CASE opcode(2 downto 0) IS
											WHEN "000" =>  -- xxx.W
												set(get_ea_now) <= '1';
												set(ea_build) <= '1';
												next_micro_state <= fpu_done;
											WHEN "001" =>  -- xxx.L
												set(get_ea_now) <= '1';
												set(ea_build) <= '1';
												set(longaktion) <= '1';
												next_micro_state <= fpu_done;
											WHEN OTHERS =>
												-- Invalid EA for FScc
												trap_illegal <= '1';
												trapmake <= '1';
												next_micro_state <= idle;
										END CASE;
									WHEN OTHERS =>
										-- An direct not allowed
										trap_illegal <= '1';
										trapmake <= '1';
										next_micro_state <= idle;
								END CASE;
								
							WHEN "011" =>  -- FTRAPcc - Trap conditionally
								-- Generate FTRAP exception if condition is true
								IF fpu_condition_result = '1' THEN
									-- Condition true - generate FTRAP exception
									trap_fpu_trap <= '1';
									trapmake <= '1';
									next_micro_state <= fpu_done;
								ELSE
									-- Condition false - continue to next instruction
									next_micro_state <= fpu_done;
								END IF;
								
							WHEN OTHERS =>
								next_micro_state <= fpu_done;
						END CASE;
					ELSE
						-- Non-cpGEN instructions - wait for FPU to complete operation with timeout protection
						-- Add timeout to prevent hanging on FPU operations
						IF timeout_counter > TIMEOUT_LIMIT_CPU THEN
							-- Timeout - force completion to prevent hang
							next_micro_state <= fpu_done;
						ELSIF fpu_complete = '1' THEN
						IF fpu_exception = '1' THEN
							-- FPU generated an exception - use proper MC68881/68882 exception vectors
							-- Map exception codes to proper FPU exception vectors (48-54)
							CASE fpu_exception_code IS
								WHEN X"05" =>  -- Divide by zero
									trap_fpu_divzero <= '1';
								WHEN X"0C" =>  -- Invalid operation / Operand error
									trap_fpu_operr <= '1';
								WHEN X"0D" =>  -- Overflow
									trap_fpu_ovfl <= '1';
								WHEN X"0E" =>  -- Underflow
									trap_fpu_unfl <= '1';
								WHEN X"0F" =>  -- Inexact result
									trap_fpu_inexact <= '1';
								WHEN X"10" =>  -- Signaling NaN
									trap_fpu_snan <= '1';
								WHEN OTHERS =>  -- Unknown exception, use operand error
									trap_fpu_operr <= '1';
							END CASE;
							trapmake <= '1';
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= idle;
						ELSE
							setstate <= "00";  -- Ensure proper endOPC condition for normal completion
							next_micro_state <= fpu_done;
						END IF;
					END IF;  -- End of fpu_complete check
					END IF;  -- End of cpGEN vs non-cpGEN check in fpu_wait
					
				WHEN fpu_done =>
					-- FPU operation completed successfully
					-- Note: CCR update for FPU operations handled in sequential process
					
					-- CRITICAL FIX: Handle cpGEN instructions (like FTST) first
					IF opcode(8 downto 6) = "000" THEN
						-- cpGEN instruction completed (including FTST)
						-- Ensure clean transition to next instruction
						set_exec(Regwrena) <= '0';
						set_exec(save_memaddr) <= '0';
						set_exec(get_ea_now) <= '0';
						set_exec(write_reg) <= '0';
						fpu_data_request <= '0';
						setnextpass <= '0';
						setstate <= "00";
						set_rot_cnt <= "000001";
						set(subidx) <= '0';
						set(presub) <= '0';
						-- CRITICAL FIX: Clear all execution flags to prevent instruction overlap
						set_exec <= (others => '0');
						-- CRITICAL FIX: Force write_back clear to ensure proper endOPC generation
						-- This prevents the instruction pipeline from stalling
						write_back <= '0';
						next_micro_state <= idle;
					-- Check if this is FSAVE with complex addressing mode that needed EA calculation
					ELSIF opcode(15 downto 6) = "1111001001" AND exec(store_ea_data) = '1' THEN
						-- FSAVE - continue with memory writes after EA calculation is complete
						datatype <= "10";  -- Longword access
						fpu_data_request <= '1';  -- Request data from FPU
						IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
							setstate <= "11";  -- Memory write
							next_micro_state <= fpu_done;  -- Continue for more writes
						ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
							-- This is the last write
							IF state = "00" THEN
								-- Ready to initiate last write
								setstate <= "11";           -- Final memory write
								next_micro_state <= fpu_done;   -- Stay in fpu_done to monitor completion
							ELSE
								-- Last write is in progress, wait for completion
								next_micro_state <= fpu_done;   -- Keep waiting
							END IF;
						ELSE
							-- All writes complete, go to idle
							setstate <= "00";  -- Ensure proper endOPC condition
							-- CRITICAL FIX: Clear ALU flags to prevent register corruption after FSAVE
							-- BUT preserve FSAVE predecrement flag until register write completes  
							set(subidx) <= '0';           -- Clear ALU subtraction mode
							IF NOT (opcode(15 downto 6) = "1111001001" AND opcode(5 downto 3) = "100" AND fsave_predecr_flag = '1') THEN
								set(presub) <= '0';       -- Clear predecrement flag (except during active FSAVE predecrement)
							END IF;
							next_micro_state <= idle;       -- All done
						END IF;
					-- Check if this is FRESTORE with complex addressing mode that needed EA calculation
					ELSIF opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND 
					      opcode(8 downto 6) = "101" AND exec(store_ea_data) = '1' THEN
						-- FRESTORE - continue with memory reads after EA calculation is complete
						datatype <= "10";  -- Longword access
						IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
							setstate <= "10";  -- Memory read
							next_micro_state <= fpu1;  -- Continue for more reads in fpu1 state
						ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
							-- This is the last read
							IF state = "00" THEN
								-- Ready to initiate last read
								setstate <= "10";           -- Final memory read
								next_micro_state <= fpu_done;   -- Stay in fpu_done to monitor completion
							ELSE
								-- Last read is in progress, wait for completion
								next_micro_state <= fpu_done;   -- Keep waiting
							END IF;
						ELSE
							-- All reads complete, go to idle
							setstate <= "00";  -- Ensure proper endOPC condition
							set_rot_cnt <= "000001";  -- CRITICAL: Reset rot_cnt for endOPC generation
							-- CRITICAL FIX: Clear ALU flags to prevent register corruption after FRESTORE
							-- FRESTORE doesn't use predecrement, so always clear presub 
							set(subidx) <= '0';           -- Clear ALU subtraction mode
							set(presub) <= '0';           -- Clear predecrement flag
							next_micro_state <= idle;   -- All done
						END IF;
					-- Handle FMOVE control register to data register (FMOVE.L FPCR,Dn)
					ELSIF FPU_Enable = 1 AND opcode(15 downto 12) = "1111" AND opcode(11 downto 9) = "001" AND 
					   opcode(8 downto 6) = "111" AND opcode(5 downto 3) = "000" THEN
						-- This is FMOVE FPcr,Dn - set register write enable
						set(Regwrena) <= '1';
						datatype <= "10";  -- Long word (32-bit control register)
						-- CRITICAL FIX: Clear all signals that could block endOPC generation
						setnextpass <= '0';           -- Clear nextpass flag that blocks endOPC
						setstate <= "00";  -- Ensure proper endOPC condition
						set_rot_cnt <= "000001";  -- CRITICAL: Reset rot_cnt for endOPC generation
						-- CRITICAL FIX: Clear ALU flags to prevent register corruption after FPU operations
						-- FMOVE control register doesn't use predecrement, so always clear presub
						set(subidx) <= '0';           -- Clear ALU subtraction mode
						set(presub) <= '0';           -- Clear predecrement flag
						-- FBcc implementation would go here
						-- TODO: Implement FBcc branch handling properly without multiple drivers
						next_micro_state <= idle;
						setnextpass <= '0';
						setstate <= "00";
						set_rot_cnt <= "000001";
						set(subidx) <= '0';
						set(presub) <= '0';
						next_micro_state <= idle;
					ELSIF sndOPC(6 downto 0) = "0111010" OR    -- FTST
					      sndOPC(6 downto 0) = "0111000" OR    -- FCMP
					      (sndOPC(6 downto 0) = "0000000" AND opcode(13 downto 10) = "0000") OR  -- FNOP
					      (opcode(8 downto 6) = "001" AND opcode(5 downto 3) = "111" AND 
					       (opcode(2 downto 0) = "010" OR opcode(2 downto 0) = "011")) OR  -- FBcc
					      (opcode(8 downto 6) = "011" AND opcode(5 downto 3) = "111" AND 
					       opcode(2 downto 0) = "100") THEN  -- FTRAPcc
						-- Operations that don't write to CPU registers
						-- CRITICAL: Prevent any register write operations
						set_exec(Regwrena) <= '0';
						set_exec(save_memaddr) <= '0';
						set_exec(get_ea_now) <= '0';
						set_exec(write_reg) <= '0';
						-- Clear all other signals
						fpu_data_request <= '0';
						setnextpass <= '0';
						setstate <= "00";
						set_rot_cnt <= "000001";
						set(subidx) <= '0';
						set(presub) <= '0';
						
						-- CRITICAL FIX: cpGEN instructions like FTST have already positioned PC correctly
						-- The fpu_cpgen_complete flag will be set in the clocked process
						
						next_micro_state <= idle;
					ELSE
						-- Default case for simple FPU operations (FMOVE, arithmetic operations)
						-- Reset FPU interface to prevent conflicts with subsequent CPU instructions
						fpu_data_request <= '0';      -- Clear FPU data request
						fmovem_data_request <= '0';   -- Clear FMOVEM request
						fmovem_data_write <= '0';     -- Clear FMOVEM write
						-- CRITICAL FIX: Clear all signals that could block endOPC generation
						setnextpass <= '0';           -- Clear nextpass flag that blocks endOPC
						setstate <= "00";             -- Ensure proper endOPC condition for all FPU operations
						set_rot_cnt <= "000001";      -- CRITICAL: Reset rot_cnt for endOPC generation
						-- CRITICAL FIX: Clear ALU flags to prevent register corruption after FPU operations
						-- BUT preserve FSAVE predecrement flag until register write completes
						set(subidx) <= '0';           -- Clear ALU subtraction mode
						IF NOT (opcode(15 downto 6) = "1111001001" AND opcode(5 downto 3) = "100" AND fsave_predecr_flag = '1') THEN
							set(presub) <= '0';       -- Clear predecrement flag (except during active FSAVE predecrement)
						END IF;
						
						-- CRITICAL FIX: cpGEN FPU instructions have already positioned PC correctly
						-- The fpu_cpgen_complete flag will be set in the clocked process
						
						next_micro_state <= idle;     -- Return to idle for next instruction
					END IF;
					
				WHEN fpu_fmovem =>
					-- FMOVEM multi-register transfer state
					-- Process each register bit in the mask sequentially
					
					-- Find next register to transfer
					IF fmovem_reg_mask(fmovem_reg_count) = '1' THEN
						-- This register needs to be transferred
						fmovem_data_request <= '1';
						fmovem_reg_index <= fmovem_reg_count;
						
						-- Check direction: 0=FP registers to memory, 1=memory to FP registers
						IF fmovem_direction = '0' THEN
							-- FMOVEM FP0-FP7,<ea> - store registers to memory
							-- CRITICAL FIX: Separate address mode setup and memory operations for proper DSACK timing
							IF (opcode(5 downto 3) = "100" OR opcode(5 downto 3) = "011") AND state = "00" THEN
								-- Phase 1: Set up predecrement/postincrement address mode
								IF opcode(5 downto 3) = "100" THEN
									-- Predecrement mode -(An)
									set(presub) <= '1';
								ELSE
									-- Postincrement mode (An)+
									set(postadd) <= '1';
								END IF;
								setstackaddr <= '1';
								IF opcode(2 downto 0) = "111" THEN
									set(use_SP) <= '1';  -- Use stack pointer
								END IF;
								setstate <= "01";  -- Wait for address calculation
								next_micro_state <= fpu_fmovem;  -- Stay in fpu_fmovem for next phase
							ELSE
								-- Phase 2: Start memory operation after address setup completed (or direct addressing)
								datatype <= "10";  -- Longword transfers
								set(write_reg) <= '1';
								set(get_ea_now) <= '1';
							END IF;
						ELSE
							-- FMOVEM <ea>,FP0-FP7 - load registers from memory
							-- Set up memory read to load FP register
							fmovem_data_write <= '1';
							-- Address calculation handled by EA processing
							set(get_ea_now) <= '1';
							datatype <= "10";  -- Longword transfers
						END IF;
						
						-- Move to next register for next cycle
						IF fmovem_reg_count < 7 THEN
							fmovem_reg_count <= fmovem_reg_count + 1;
							next_micro_state <= fpu_fmovem;  -- Continue processing
						ELSE
							-- All registers processed
							fmovem_active <= '0';
							fmovem_data_request <= '0';
							fmovem_data_write <= '0';
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= fpu_done;
						END IF;
					ELSE
						-- This register not selected in mask, skip to next
						IF fmovem_reg_count < 7 THEN
							fmovem_reg_count <= fmovem_reg_count + 1;
							next_micro_state <= fpu_fmovem;  -- Continue processing
						ELSE
							-- All registers processed
							fmovem_active <= '0';
							fmovem_data_request <= '0';
							fmovem_data_write <= '0';
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= fpu_done;
						END IF;
					END IF;
					
				WHEN fpu_fmovem_cr =>
					-- FMOVEM control register transfer state  
					-- Process FPCR, FPSR, FPIAR based on mask in extension word bits 12:10
					-- Bit 12=FPCR, Bit 11=FPSR, Bit 10=FPIAR
					
					-- Determine which control register to process based on count
					-- Control registers are processed in order: FPCR(0), FPSR(1), FPIAR(2)
					IF (fmovem_reg_count = 0 AND fmovem_reg_mask(7) = '1') OR    -- FPCR (bit 12 mapped to bit 7)
					   (fmovem_reg_count = 1 AND fmovem_reg_mask(6) = '1') OR    -- FPSR (bit 11 mapped to bit 6)
					   (fmovem_reg_count = 2 AND fmovem_reg_mask(5) = '1') THEN  -- FPIAR (bit 10 mapped to bit 5)
						
						-- This control register needs to be transferred
						-- Check direction: 0=control registers to memory, 1=memory to control registers
						IF fmovem_direction = '0' THEN
							-- FMOVEM FPCR/FPSR/FPIAR,<ea> - store control registers to memory
							-- Set up for memory write operation
							IF opcode(5 downto 3) = "100" THEN
								-- Predecrement mode -(An)
								set(presub) <= '1';
								setstackaddr <= '1';
								IF opcode(2 downto 0) = "111" THEN
									set(use_SP) <= '1';  -- Use stack pointer
								END IF;
							ELSIF opcode(5 downto 3) = "011" THEN
								-- Postincrement mode (An)+
								set(postadd) <= '1';
								setstackaddr <= '1';
								IF opcode(2 downto 0) = "111" THEN
									set(use_SP) <= '1';  -- Use stack pointer
								END IF;
							END IF;
							-- Control registers are 32-bit (longword)
							datatype <= "10";  -- Longword transfers
							set(write_reg) <= '1';
							set(get_ea_now) <= '1';
						ELSE
							-- FMOVEM <ea>,FPCR/FPSR/FPIAR - load control registers from memory
							-- Set up for memory read operation
							set(get_ea_now) <= '1';
							datatype <= "10";  -- Longword transfers
						END IF;
						
						-- Move to next control register for next cycle
						IF fmovem_reg_count < 2 THEN  -- Only 3 control registers (0,1,2)
							fmovem_reg_count <= fmovem_reg_count + 1;
							next_micro_state <= fpu_fmovem_cr;  -- Continue processing
						ELSE
							-- All control registers processed
							fmovem_active <= '0';
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= fpu_done;
						END IF;
					ELSE
						-- This control register not selected in mask, skip to next
						IF fmovem_reg_count < 2 THEN  -- Only 3 control registers (0,1,2)
							fmovem_reg_count <= fmovem_reg_count + 1;
							next_micro_state <= fpu_fmovem_cr;  -- Continue processing
						ELSE
							-- All control registers processed
							fmovem_active <= '0';
							setstate <= "00";  -- Ensure proper endOPC condition
							next_micro_state <= fpu_done;
						END IF;
					END IF;
	
				WHEN idle =>
					-- Idle state - ready for next instruction
					-- Default routing is handled by the logic at lines 1710-1717
					-- This case ensures proper state machine handling when in idle
					NULL;  -- Let default next_micro_state assignment handle instruction routing
					
				WHEN OTHERS => NULL;
			END CASE;
	END PROCESS;  -- End of main decode process that started at line 1581

-----------------------------------------------------------------------------
-- FSAVE counter and state management
-----------------------------------------------------------------------------
PROCESS (clk, Reset)
BEGIN
	IF rising_edge(clk) THEN
		IF Reset='1' THEN
			micro_state <= ld_nn;
			fsave_counter <= 0;
			fsave_predecr_flag <= '0';
			fsave_frame_size <= 4;
			coprocessor_format_word <= X"00000004";  -- Empty/Reset format
			fsave_size_determined <= '0';
			cpSAVE_state <= 0;
			cpRESTORE_state <= 0;
			timeout_counter <= 0;
		ELSIF clkena_lw='1' THEN
			trapd <= trapmake;
			micro_state <= next_micro_state;
			
			-- Manage FPU timeout counter
			IF micro_state = fpu_wait THEN
				-- Increment timeout counter while waiting for FPU
				IF timeout_counter < 255 THEN
					timeout_counter <= timeout_counter + 1;
				END IF;
			ELSE
				-- Reset timeout counter when not in fpu_wait state
				timeout_counter <= 0;
			END IF;
			
			-- Handle FSAVE/FRESTORE counter and control signals
			
			-- FSAVE handling - support all addressing modes
			-- Set fsave_predecr_flag BEFORE transitioning to fpu2 to avoid race condition
			IF micro_state = idle AND opcode(15 downto 9) = "1111001" AND opcode(8 downto 6) = "100" AND 
			   next_micro_state = fpu2 AND fsave_counter = 0 THEN
				-- About to enter FSAVE for first time with any addressing mode
				-- Set 60-byte decrement flag for predecrement modes BEFORE state transition
				IF opcode(5 downto 3) = "100" THEN
					fsave_predecr_flag <= '1';
				END IF;
			ELSIF (micro_state = fpu2 OR micro_state = fpu_done) AND state = "00" THEN
				-- Memory write completed for FSAVE (in either fpu2 or fpu_done state)
				
				-- Frame size determination on first write
				IF fsave_counter = 0 AND fsave_size_determined = '0' THEN
					-- First write: get frame format from FPU and determine size
					-- Query FPU for current state to determine appropriate frame type
					IF fpu_busy = '1' THEN
						-- FPU is busy executing an operation - save BUSY frame
						coprocessor_format_word <= X"D8" & X"D8" & X"0000";  -- MC68882 BUSY frame ($D8 = version 13, BUSY)
						fsave_frame_size <= 216;      -- 216 bytes = 54 longwords
					ELSIF fpu_exception = '1' OR fpu_fpsr /= X"00000000" THEN
						-- FPU has exceptions or non-zero state - save IDLE frame
						coprocessor_format_word <= X"60" & X"3C" & X"0000";  -- MC68882 IDLE frame ($60 = version 6, IDLE)
						fsave_frame_size <= 60;       -- 60 bytes = 15 longwords
					ELSE
						-- FPU is in reset state - save IDLE frame for compatibility
						-- CRITICAL FIX: MC68882 always saves at least IDLE frame
						coprocessor_format_word <= X"60" & X"3C" & X"0000";  -- MC68882 IDLE frame
						fsave_frame_size <= 60;       -- 60 bytes = 15 longwords
					END IF;
					fsave_size_determined <= '1';
				END IF;
				
				-- Increment counter based on frame size
				IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
					fsave_counter <= fsave_counter + 1;
				ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
					-- Final write completed - reset for next FSAVE
					fsave_counter <= 0;
					fsave_size_determined <= '0';
				END IF;
				
				-- Clear single-use signals after register write completes for predecrement
				-- CRITICAL FIX: Keep fsave_predecr_flag active until register is actually written
				IF opcode(5 downto 3) /= "100" THEN
					-- Clear flag for non-predecrement modes immediately
					fsave_predecr_flag <= '0';
				ELSIF fsave_counter > 0 AND exec(presub) = '0' THEN
					-- For predecrement: only clear after first write AND register update complete
					fsave_predecr_flag <= '0';
				END IF;
			END IF;
			
			-- FRESTORE handling
			IF micro_state = fpu1 AND state = "10" AND setstate = "00" AND
			   opcode(8 downto 6) = "101" THEN
				-- Memory read completed for FRESTORE
				
				-- Frame size determination on first read
				IF fsave_counter = 0 AND fsave_size_determined = '0' THEN
					-- First read: analyze frame format from data_read
					coprocessor_format_word <= data_read;  -- Complete format word
					CASE data_read(31 downto 24) IS
						WHEN X"18" =>
							-- NULL frame = 4 bytes (1 longword only)
							fsave_frame_size <= 4;
							WHEN X"60" =>
							-- MC68882 IDLE frame = 60 bytes (15 longwords)
							fsave_frame_size <= 60;
							WHEN X"D8" =>
							-- MC68882 BUSY frame = 216 bytes (54 longwords)
							fsave_frame_size <= 216;
							WHEN OTHERS =>
							-- Check frame type by format bits
							IF data_read(27 downto 24) = X"8" THEN
								-- Format $XX18 = NULL frame (check lower nibble = 8)
								fsave_frame_size <= 4;
							ELSIF data_read(31 downto 28) /= X"0" AND data_read(27 downto 24) = X"8" THEN
								-- Format $XX18 where XX != 0 = IDLE frame  
								fsave_frame_size <= 60;
							ELSIF data_read(31 downto 28) /= X"0" AND data_read(27 downto 24) = X"4" THEN
								-- Format $XXB4 = BUSY frame (lower nibble = 4, upper nibble = B)
								fsave_frame_size <= 216;
							ELSE
								-- Default to IDLE frame for unknown formats
								fsave_frame_size <= 60;
							END IF;
					END CASE;
					fsave_size_determined <= '1';
				END IF;
				
				-- Increment counter based on frame size
				IF (fsave_counter + 1) * 4 < fsave_frame_size THEN
					fsave_counter <= fsave_counter + 1;
					-- Send data to FPU
					frestore_data_write <= '1';
				ELSIF (fsave_counter + 1) * 4 = fsave_frame_size THEN
					-- Final read completed - reset for next FRESTORE
					fsave_counter <= 0;
					fsave_size_determined <= '0';
					-- Send final data to FPU
					frestore_data_write <= '1';
				END IF;
			END IF;
			
			-- Reset counter when returning to idle
			IF micro_state = idle THEN
				fsave_counter <= 0;
				fsave_predecr_flag <= '0';
				fsave_size_determined <= '0';
			END IF;
		END IF;
	END IF;
END PROCESS;

-----------------------------------------------------------------------------
-- FPU Wait Counter Process removed - CPU-managed FPU operations are immediate
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- MOVEC
-----------------------------------------------------------------------------
  process (clk, SFC, DFC, VBR, CACR, MSP, ISP, brief)
  begin
	-- all other hexa codes should give illegal isntruction exception
	if rising_edge(clk) then
	  if Reset = '1' then
		VBR <= (others => '0');
		CACR <= (others => '0');
		-- Initialize 68020+ stack pointers to default values
		MSP <= (others => '0');  -- Master Stack Pointer
		ISP <= (others => '0');  -- Interrupt Stack Pointer
	  elsif clkena_lw = '1' and exec(movec_wr) = '1' then
		case brief(11 downto 0) is
		  when X"000" => SFC <= reg_QA(2 downto 0); -- SFC -- 68010+
		  when X"001" => DFC <= reg_QA(2 downto 0); -- DFC -- 68010+
		  when X"002" => CACR <= reg_QA(3 downto 0); -- 68020+
		  when X"800" => NULL; -- USP -- 68010+
		  when X"801" => VBR <= reg_QA; -- 68010+
		  when X"802" => NULL; -- CAAR -- 68020+
		  when X"803" => MSP <= reg_QA; -- MSP -- 68020+
		  when X"804" => ISP <= reg_QA; -- ISP -- 68020+
		  when others => NULL;
		end case;
	  elsif clkena_lw = '1' then
		-- Handle stack pointer save operations during mode switches
		if exec(to_MSP) = '1' then
			MSP <= reg_QA;
		end if;
		if exec(to_ISP) = '1' then
			ISP <= reg_QA;
		end if;
	  end if;
	end if;

	movec_data <= (others => '0');
	case brief(11 downto 0) is
		when X"000" => movec_data <= "00000000000000000000000000000" & SFC;
		when X"001" => movec_data <= "00000000000000000000000000000" & DFC;
	  when X"002" => movec_data <= "0000000000000000000000000000" & (CACR AND "0011");

	  when X"801" => 
		movec_data <= VBR;
	  when X"803" => 
		movec_data <= MSP;  -- MSP read support
	  when X"804" => 
		movec_data <= ISP;  -- ISP read support
	  when others => NULL;
	end case;
  end process;

  CACR_out <= CACR;
  VBR_out <= VBR;
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
				ELSIF (exec(movem_action)='1' OR set(movem_action) ='1') AND movem_run='1' THEN
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
END; 
