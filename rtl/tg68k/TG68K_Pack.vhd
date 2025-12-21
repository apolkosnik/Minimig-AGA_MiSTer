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
library IEEE;
use IEEE.std_logic_1164.all;

package TG68K_Pack is

	type micro_states is (idle, nop, ld_nn, st_nn, ld_dAn1, ld_AnXn1, ld_AnXn2, st_dAn1, ld_AnXnbd1, ld_AnXnbd2, ld_AnXnbd3,
						  ld_229_1, ld_229_2, ld_229_3, ld_229_4, st_229_1, st_229_2, st_229_3, st_229_4,   
						  st_AnXn1, st_AnXn2, bra1, bsr1, bsr2, nopnop, dbcc1, movem1, movem2, movem3, 
						  andi, pack1, pack2, pack3, op_AxAy, cmpm, link1, link2, unlink1, unlink2, int1, int2, int3, int4, rte1, rte2, rte3, 
						  rte4, rte5, rtd1, rtd2, trap00, trap0, trap1, trap2, trap3, cas1, cas2, cas21, cas22, cas23, cas24,
						  cas25, cas26, cas27, cas28, chk20, chk21, chk22, chk23, chk24,
                          trap4, trap5, trap6, movec1, moves0, moves1, movep1, movep2, movep3, movep4, movep5, rota1, bf1,
                          pmove_decode, pmove_decode_wait, pmove_mem_to_mmu_hi, pmove_mmu_to_mem_hi, pmove_mem_to_mmu_lo, pmove_mmu_to_mem_lo, ptest1, ptest2, pflush1, pload1,
                          pmove_dn_hi, pmove_dn_lo, pmmu_dn_read_wait,
                          mul1, mul2, mul_end1,  mul_end2, div1, div2, div3, div4, div_end1, div_end2,
                          fpu1, fpu2, fpu_wait, fpu_done, fpu_fmovem, fpu_fmovem_cr, fpu_fdbcc);
	
	constant opcMOVE				: integer := 0; --
	constant opcMOVEQ				: integer := 1; --
	constant opcMOVESR			: integer := 2; --
	constant opcADD				: integer := 3; --
	constant opcADDQ				: integer := 4; --
	constant opcOR					: integer := 5; --
	constant opcAND				: integer := 6; --
	constant opcEOR				: integer := 7; --
	constant opcCMP				: integer := 8; --
	constant opcROT				: integer := 9; --
	constant opcCPMAW				: integer := 10;
	constant opcEXT				: integer := 11; --
	constant opcABCD				: integer := 12; --
	constant opcSBCD				: integer := 13; --
	constant opcBITS				: integer := 14; --
	constant opcSWAP				: integer := 15; --
	constant opcScc				: integer := 16; --
	constant andiSR				: integer := 17; --
	constant eoriSR				: integer := 18; --
	constant oriSR					: integer := 19; --
	constant opcMULU				: integer := 20; --
	constant opcDIVU				: integer := 21; --
	constant dispouter			: integer := 22; --
	constant rot_nop				: integer := 23; --
	constant ld_rot_cnt			: integer := 24; --
	constant writePC_add			: integer := 25; --
	constant ea_data_OP1			: integer := 26; --
	constant ea_data_OP2			: integer := 27; --
	constant use_XZFlag			: integer := 28; --
	constant get_bfoffset		: integer := 29; --
	constant save_memaddr		: integer := 30; --
	constant opcCHK				: integer := 31; --
	constant movec_rd				: integer := 32; --
	constant movec_wr				: integer := 33; --
	constant Regwrena				: integer := 34; --
	constant update_FC			: integer := 35; --
	constant linksp				: integer := 36; --
	constant movepl				: integer := 37; --
	constant update_ld			: integer := 38; --
	constant OP1addr				: integer := 39; --
	constant write_reg			: integer := 40; --
	constant changeMode			: integer := 41; --
	constant ea_build				: integer := 42; --
	constant trap_chk				: integer := 43; --
	constant store_ea_data		: integer := 44; --
	constant addrlong				: integer := 45; --
	constant postadd				: integer := 46; --
	constant presub				: integer := 47; --
	constant subidx				: integer := 48; --
	constant no_Flags				: integer := 49; --
	constant use_SP				: integer := 50; --
	constant to_CCR				: integer := 51; --
	constant to_SR					: integer := 52; --
	constant OP2out_one			: integer := 53; --
	constant OP1out_zero			: integer := 54; --
	constant mem_addsub			: integer := 55; --
	constant addsub				: integer := 56; --
	constant directPC				: integer := 57; --
	constant direct_delta		: integer := 58; --
	constant directSR				: integer := 59; --
	constant directCCR			: integer := 60; --
	constant exg					: integer := 61; --
	constant get_ea_now			: integer := 62; --
	constant ea_to_pc				: integer := 63; --
	constant hold_dwr				: integer := 64; --
	constant to_USP				: integer := 65; --
	constant from_USP				: integer := 66; --
	constant write_lowlong		: integer := 67; --
	constant write_reminder		: integer := 68; --
	constant movem_action		: integer := 69; --
	constant briefext				: integer := 70; --
	constant get_2ndOPC			: integer := 71; --
	constant mem_byte				: integer := 72; --
	constant longaktion			: integer := 73; --
	constant opcRESET				: integer := 74; --
	constant opcBF					: integer := 75; --
	constant opcBFwb				: integer := 76; --
	constant opcPACK				: integer := 77; --
	constant opcUNPACK			: integer := 78; --
	constant hold_ea_data		: integer := 79; --
	constant store_ea_packdata	: integer := 80; --
	constant exec_BS				: integer := 81; --
	constant hold_OP2				: integer := 82; --
	constant restore_ADDR		: integer := 83; --
	constant alu_exec				: integer := 84; --
	constant alu_move				: integer := 85; --
	constant alu_setFlags		: integer := 86; --
	constant opcCHK2				: integer := 87; --
	constant opcEXTB				: integer := 88; --

    constant pmmu_rd				: integer := 89; -- PMOVE <MMU>,Dn
    constant pmmu_wr				: integer := 90; -- PMOVE Dn,<MMU>
    constant pmmu_ptest			: integer := 91; -- PTEST
    constant pmmu_pflush			: integer := 92; -- PFLUSH
    constant pmmu_pload			: integer := 93; -- PLOAD
    constant to_SSP				: integer := 94; -- Save A7 to SSP (68000/68010)
    constant from_SSP				: integer := 95; -- Load A7 from SSP (68000/68010)
    constant to_MSP				: integer := 96; -- Save A7 to MSP (68020/68030)
    constant from_MSP				: integer := 97; -- Load A7 from MSP (68020/68030)
    constant to_ISP				: integer := 98; -- Save A7 to ISP (68020/68030)
    constant from_ISP				: integer := 99; -- Load A7 from ISP (68020/68030)
    constant use_sfc_dfc			: integer := 100; -- MOVES: Use SFC/DFC for FC
    constant sfc_not_dfc			: integer := 101; -- MOVES: 1=SFC (read), 0=DFC (write)
    constant pmmu_addr_inc        : integer := 102; -- PMMU: +4 address increment for 64-bit CRP/SRP second transfer (no reg write-back)
    constant pmmu_dbl             : integer := 103; -- PMMU: CRP/SRP doubleword size for (An)+/-(An) (updates An by 8)

    constant lastOpcBit			: integer := 103;

	component TG68K_ALU
	generic(
		MUL_Mode :integer;			--0=>16Bit,		1=>32Bit,	2=>switchable with CPU(1),		3=>no MUL,  
		MUL_Hardware :integer;		--0=>no,			1=>yes,  
		DIV_Mode :integer;			--0=>16Bit,		1=>32Bit,	2=>switchable with CPU(1),		3=>no DIV,  
		BarrelShifter :integer		--0=>no,			1=>yes,		2=>switchable with CPU(1)  
		);
	port(
		clk						: in std_logic;
		Reset						: in std_logic;
		CPU						: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  10->68020  11->68030
		clkena_lw				: in std_logic:='1';
		execOPC					: in bit;
		decodeOPC				: in bit;
		exe_condition			: in std_logic;
		exec_tas					: in std_logic;
		long_start				: in bit;
		non_aligned				: in std_logic;
		check_aligned			: in std_logic;
		movem_presub			: in bit;
		set_stop					: in bit;
		Z_error					: in bit;
		rot_bits					: in std_logic_vector(1 downto 0);
		exec						: in bit_vector(lastOpcBit downto 0);
		OP1out					: in std_logic_vector(31 downto 0);
		OP2out					: in std_logic_vector(31 downto 0);
		reg_QA					: in std_logic_vector(31 downto 0);
		reg_QB					: in std_logic_vector(31 downto 0);
		opcode					: in std_logic_vector(15 downto 0);
--		datatype					: in std_logic_vector(1 downto 0);
		exe_opcode				: in std_logic_vector(15 downto 0);
		exe_datatype			: in std_logic_vector(1 downto 0);
		sndOPC					: in std_logic_vector(15 downto 0);
		last_data_read			: in std_logic_vector(15 downto 0);
		data_read				: in std_logic_vector(15 downto 0);
		FlagsSR					: in std_logic_vector(7 downto 0);
		micro_state				: in micro_states;  
		bf_ext_in				: in std_logic_vector(7 downto 0);
		bf_ext_out				: out std_logic_vector(7 downto 0);
		bf_shift					: in std_logic_vector(5 downto 0);
		bf_width					: in std_logic_vector(5 downto 0);
		bf_ffo_offset			: in std_logic_vector(31 downto 0);
		bf_loffset				: in std_logic_vector(4 downto 0);

		set_V_Flag				: buffer bit;
		Flags						: buffer std_logic_vector(7 downto 0);
		c_out						: buffer std_logic_vector(2 downto 0);
		addsub_q					: buffer std_logic_vector(31 downto 0);
		ALUout					: out std_logic_vector(31 downto 0)
	);
	end component;

	component TG68K_FPU
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;

		-- CPU Interface
		opcode					: in std_logic_vector(15 downto 0);
		extension_word			: in std_logic_vector(15 downto 0);
		fpu_enable				: in std_logic;
		supervisor_mode			: in std_logic;
		cpu_data_in				: in std_logic_vector(31 downto 0);
		cpu_address_in			: in std_logic_vector(31 downto 0);
		fpu_data_out			: out std_logic_vector(31 downto 0);

		-- FSAVE/FRESTORE Data Interface
		fsave_data_request		: in std_logic;
		fsave_data_index		: in integer range 0 to 54;
		frestore_data_write		: in std_logic;
		frestore_data_in		: in std_logic_vector(31 downto 0);

		-- FMOVEM Data Interface
		fmovem_data_request		: in std_logic;
		fmovem_reg_index		: in integer range 0 to 7;
		fmovem_data_write		: in std_logic;
		fmovem_data_in			: in std_logic_vector(79 downto 0);
		fmovem_data_out			: out std_logic_vector(79 downto 0);

		-- Control Signals
		fpu_busy				: out std_logic;
		fpu_done				: buffer std_logic;
		fpu_exception			: buffer std_logic;
		exception_code			: out std_logic_vector(7 downto 0);

		-- Status and Control Registers
		fpcr_out				: out std_logic_vector(31 downto 0);
		fpsr_out				: out std_logic_vector(31 downto 0);
		fpiar_out				: out std_logic_vector(31 downto 0);

		-- FSAVE Frame Size Handshake
		fsave_frame_size		: out integer range 4 to 216;
		fsave_size_valid		: out std_logic;

		-- MC68020/68881 Coprocessor Interface Registers (CIR)
		cir_address				: in std_logic_vector(4 downto 0);
		cir_write				: in std_logic;
		cir_read				: in std_logic;
		cir_data_in				: in std_logic_vector(15 downto 0);
		cir_data_out			: out std_logic_vector(15 downto 0);
		cir_data_valid			: buffer std_logic
	);
	end component;

	component TG68K_FPU_Decoder
	port(
		clk						: in std_logic;
		nReset					: in std_logic;

		-- Input instruction words
		opcode					: in std_logic_vector(15 downto 0);
		extension_word			: in std_logic_vector(15 downto 0);

		-- Decoder enable
		decode_enable			: in std_logic;

		-- Decoded instruction fields
		instruction_type		: out std_logic_vector(3 downto 0);
		operation_code			: out std_logic_vector(6 downto 0);
		source_format			: out std_logic_vector(2 downto 0);
		dest_format				: out std_logic_vector(2 downto 0);
		source_reg				: out std_logic_vector(2 downto 0);
		dest_reg				: out std_logic_vector(2 downto 0);
		ea_mode					: out std_logic_vector(2 downto 0);
		ea_register				: out std_logic_vector(2 downto 0);

		-- Control signals
		needs_extension_word	: out std_logic;
		valid_instruction		: out std_logic;
		privileged_instruction	: out std_logic;

		-- Exception flags
		illegal_instruction		: out std_logic;
		unsupported_instruction	: out std_logic
	);
	end component;

	component TG68K_FPU_ALU
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;

		-- Operation control
		start_operation			: in std_logic;
		operation_code			: in std_logic_vector(6 downto 0);
		rounding_mode			: in std_logic_vector(1 downto 0);

		-- Operands (IEEE 754 extended precision - 80 bits)
		operand_a				: in std_logic_vector(79 downto 0);
		operand_b				: in std_logic_vector(79 downto 0);

		-- Result
		result					: out std_logic_vector(79 downto 0);
		result_valid			: out std_logic;

		-- Status flags
		overflow				: out std_logic;
		underflow				: out std_logic;
		inexact					: out std_logic;
		invalid					: out std_logic;
		divide_by_zero			: out std_logic;

		-- Control
		operation_busy			: out std_logic;
		operation_done			: out std_logic
	);
	end component;

	component TG68K_FPU_Converter
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;

		-- Control
		start_conversion		: in std_logic;
		conversion_done			: out std_logic;
		conversion_valid		: out std_logic;

		-- Format specification
		source_format			: in std_logic_vector(2 downto 0);
		dest_format				: in std_logic_vector(2 downto 0);

		-- Input data
		data_in					: in std_logic_vector(95 downto 0);

		-- Output data
		data_out				: out std_logic_vector(79 downto 0);

		-- Exception flags
		overflow				: out std_logic;
		underflow				: out std_logic;
		inexact					: out std_logic;
		invalid					: out std_logic
	);
	end component;

	component TG68K_FPU_Transcendental
	port(
		clk						: in std_logic;
		nReset					: in std_logic;
		clkena					: in std_logic;

		-- Operation control
		start_operation			: in std_logic;
		operation_code			: in std_logic_vector(6 downto 0);

		-- Operand (IEEE 754 extended precision - 80 bits)
		operand					: in std_logic_vector(79 downto 0);

		-- Result
		result					: out std_logic_vector(79 downto 0);
		result_valid			: out std_logic;

		-- Status flags
		overflow				: out std_logic;
		underflow				: out std_logic;
		inexact					: out std_logic;
		invalid					: out std_logic;

		-- Control
		operation_busy			: out std_logic;
		operation_done			: out std_logic
	);
	end component;

	component TG68K_FPU_ConstantROM
	port(
		clk						: in std_logic;
		nReset					: in std_logic;

		-- ROM address (7-bit offset from FMOVECR instruction)
		rom_offset				: in std_logic_vector(6 downto 0);
		read_enable				: in std_logic;

		-- Output constant (IEEE 754 extended precision - 80 bits)
		constant_out			: out std_logic_vector(79 downto 0);
		constant_valid			: out std_logic
	);
	end component;

end;
