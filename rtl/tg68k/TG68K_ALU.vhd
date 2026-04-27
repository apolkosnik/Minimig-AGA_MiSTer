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

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use IEEE.numeric_std.all;
use work.TG68K_Pack.all;

entity TG68K_ALU is
generic(
		MUL_Mode : integer;			--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),	3=>no MUL,  
		MUL_Hardware : integer;		--0=>no,		1=>yes,  
		DIV_Mode : integer;			--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),	3=>no DIV,  
		BarrelShifter :integer		--0=>no,		1=>yes,		2=>switchable with CPU(1)  
		);
	port(clk						: in std_logic;
		Reset						: in std_logic;
		clkena_lw				: in std_logic:='1';
		CPU						: in std_logic_vector(1 downto 0):="10";  -- 00->68000  01->68010  10->68030
		execOPC					: in bit;
		decodeOPC				: in bit;
		exe_condition			: in std_logic;
		exec_tas					: in std_logic;
		long_start				: in bit;
		non_aligned				: in std_logic;
		check_aligned			: in std_logic;
		movem_presub			: in bit;
		set_stop					: in bit;
		Z_error 					: in bit;
		rot_bits					: in std_logic_vector(1 downto 0);
		exec						: in bit_vector(lastOpcBit downto 0);
		OP1out					: in std_logic_vector(31 downto 0);
		OP2out					: in std_logic_vector(31 downto 0);
		reg_QA					: in std_logic_vector(31 downto 0);
		reg_QB					: in std_logic_vector(31 downto 0);
		opcode					: in std_logic_vector(15 downto 0);
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

		-- BUG #397: Restore CCR on RTE format error
		restore_ccr				: in std_logic := '0';
		restored_ccr_value		: in std_logic_vector(7 downto 0) := "00000000";

		set_V_Flag				: buffer bit;
		Flags						: buffer std_logic_vector(7 downto 0);
		c_out						: buffer std_logic_vector(2 downto 0);
		addsub_q					: buffer std_logic_vector(31 downto 0);
		ALUout					: out std_logic_vector(31 downto 0)
	);
end TG68K_ALU;

architecture logic of TG68K_ALU is
-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
-- ALU and more
-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
	signal OP1in				: std_logic_vector(31 downto 0);
	signal addsub_a			: std_logic_vector(31 downto 0);
	signal addsub_b			: std_logic_vector(31 downto 0);
	signal notaddsub_b		: std_logic_vector(33 downto 0);
	signal add_result			: std_logic_vector(33 downto 0);
	signal addsub_ofl			: std_logic_vector(2 downto 0);
	signal opaddsub			: bit;
	signal c_in					: std_logic_vector(3 downto 0);
	signal flag_z				: std_logic_vector(2 downto 0);
	signal set_Flags			: std_logic_vector(3 downto 0);	--NZVC
	signal CCRin				: std_logic_vector(7 downto 0);
	signal last_Flags1		: std_logic_vector(3 downto 0);	--NZVC
	signal chk2_lower_bound	: std_logic_vector(31 downto 0);
    
--BCD
	signal bcd_pur				: std_logic_vector(9 downto 0);
	signal bcd_kor				: std_logic_vector(8 downto 0);
	signal halve_carry		: std_logic;
	signal Vflag_a				: std_logic;
	signal bcd_a_carry		: std_logic;
	signal bcd_a				: std_logic_vector(8 downto 0);
	signal result_mulu		: std_logic_vector(127 downto 0);
	signal result_div			: std_logic_vector(63 downto 0);
	signal result_div_pre	: std_logic_vector(31 downto 0);
	signal set_mV_Flag		: std_logic;
	signal V_Flag				: bit;
	
	signal rot_rot				: std_logic;
	signal rot_lsb				: std_logic;
	signal rot_msb				: std_logic;
	signal rot_X				: std_logic;
	signal rot_C				: std_logic;
	signal rot_out				: std_logic_vector(31 downto 0);
	signal asl_VFlag			: std_logic;
	signal bit_bits			: std_logic_vector(1 downto 0);
	signal bit_number			: std_logic_vector(4 downto 0);
	signal bits_out			: std_logic_vector(31 downto 0);
	signal one_bit_in			: std_logic;
	signal bchg					: std_logic;
	signal bset					: std_logic;
	
	signal mulu_sign			: std_logic;
	signal mulu_signext		: std_logic_vector(16 downto 0);
	signal muls_msb			: std_logic;
	signal mulu_reg			: std_logic_vector(63 downto 0);
	signal FAsign				: std_logic;
	signal faktorA				: std_logic_vector(31 downto 0);
	signal faktorB				: std_logic_vector(31 downto 0);
	
	signal div_reg				: std_logic_vector(63 downto 0);
	signal div_quot			: std_logic_vector(63 downto 0);
	signal div_ovl				: std_logic;
	signal div_neg				: std_logic;
	signal div_bit				: std_logic;
	signal div_sub				: std_logic_vector(32 downto 0);
	signal div_over			: std_logic_vector(32 downto 0);
	signal nozero				: std_logic;
	signal div_qsign			: std_logic;
	signal dividend			: std_logic_vector(63 downto 0);
	signal divs					: std_logic;
	signal signedOP			: std_logic;
	signal OP1_sign			: std_logic;
	signal OP2_sign			: std_logic;
	signal OP2outext			: std_logic_vector(15 downto 0);
	signal div_src_latched	: std_logic_vector(31 downto 0) := (others => '0');
	signal div_dividend_latched : std_logic_vector(63 downto 0) := (others => '0');
	signal div_signed_latched : std_logic := '0';
	signal div_word_latched  : std_logic := '0';
	signal div_64bit_latched : std_logic := '0';

	signal in_offset			: std_logic_vector(5 downto 0);
	signal datareg				: std_logic_vector(31 downto 0);
	signal insert				: std_logic_vector(31 downto 0);
	signal bf_datareg			: std_logic_vector(31 downto 0);
	signal result				: std_logic_vector(39 downto 0);
	signal result_tmp			: std_logic_vector(39 downto 0);
	signal unshifted_bitmask: std_logic_vector(31 downto 0);
	signal bf_set1				: std_logic_vector(39 downto 0);
	signal inmux0				: std_logic_vector(39 downto 0);
	signal inmux1				: std_logic_vector(39 downto 0);
	signal inmux2				: std_logic_vector(39 downto 0);
	signal inmux3				: std_logic_vector(31 downto 0);
	signal shifted_bitmask	: std_logic_vector(39 downto 0);
	signal bitmaskmux0		: std_logic_vector(37 downto 0);
	signal bitmaskmux1		: std_logic_vector(35 downto 0);
	signal bitmaskmux2		: std_logic_vector(31 downto 0);
	signal bitmaskmux3		: std_logic_vector(31 downto 0);
	signal bf_set2				: std_logic_vector(31 downto 0);
	signal shift				: std_logic_vector(39 downto 0);
	signal bf_firstbit		: std_logic_vector(5 downto 0);
	signal mux					: std_logic_vector(3 downto 0);
	signal bitnr				: std_logic_vector(4 downto 0);
	signal mask					: std_logic_vector(31 downto 0);
	signal mask_not_zero		: std_logic;
	signal bf_bset				: std_logic;
	signal bf_NFlag			: std_logic;
	signal bf_bchg				: std_logic;
	signal bf_ins				: std_logic;
	signal bf_exts				: std_logic;
	signal bf_fffo				: std_logic;
	signal bf_d32				: std_logic;
	signal bf_s32				: std_logic;
	signal index				: std_logic_vector(4 downto 0);
--	signal i						: integer range 0 to 31;
--	signal i						: integer range 0 to 31;
--	signal i						: std_logic_vector(5 downto 0);

	signal hot_msb				: std_logic_vector(33 downto 0);
	signal vector				: std_logic_vector(32 downto 0);
	signal result_bs			: std_logic_vector(65 downto 0);
	signal bit_nr				: std_logic_vector(5 downto 0);
	signal bit_msb				: std_logic_vector(5 downto 0);
	signal bs_shift			: std_logic_vector(5 downto 0);
	signal bs_shift_mod		: std_logic_vector(5 downto 0);
	signal asl_over			: std_logic_vector(32 downto 0);
	signal asl_over_xor		: std_logic_vector(32 downto 0);
	signal asr_sign			: std_logic_vector(32 downto 0);
	signal msb					: std_logic;  
	signal ring					: std_logic_vector(5 downto 0);
	signal ALU					: std_logic_vector(31 downto 0);
	signal BSout				: std_logic_vector(31 downto 0);
	signal bs_V					: std_logic;  
	signal bs_C					: std_logic;  
	signal bs_X					: std_logic;  

	function chk_flags_68020(
		src : std_logic_vector(31 downto 0);
		dst : std_logic_vector(31 downto 0);
		is_word : boolean
	) return std_logic_vector is
		variable flags : std_logic_vector(3 downto 0) := (others => '0');
		variable src_w : signed(15 downto 0);
		variable dst_w : signed(15 downto 0);
		variable val_w : signed(15 downto 0);
		variable src_l : signed(31 downto 0);
		variable dst_l : signed(31 downto 0);
		variable val_l : signed(31 downto 0);
		variable src_neg : boolean;
		variable dst_neg : boolean;
		variable val_neg : boolean;
	begin
		if is_word then
			src_w := signed(src(15 downto 0));
			dst_w := signed(dst(15 downto 0));
			dst_neg := dst_w(15) = '1';
			src_neg := src_w(15) = '1';

			if dst(15 downto 0) = x"0000" then
				flags(2) := '1';
			end if;
			if dst_neg then
				flags(3) := '1';
			end if;

			if dst_neg or (dst_w > src_w) then
				val_w := src_w - dst_w;
				val_neg := val_w(15) = '1';

				if (dst_neg /= src_neg) and (val_neg /= src_neg) then
					flags(1) := '1';
				end if;

				if dst_neg then
					if (dst_w > src_w) or (not src_neg) then
						flags(0) := '1';
					end if;
				elsif not src_neg then
					flags(0) := '1';
				end if;
			end if;
		else
			src_l := signed(src);
			dst_l := signed(dst);
			dst_neg := dst_l(31) = '1';
			src_neg := src_l(31) = '1';

			if dst = x"00000000" then
				flags(2) := '1';
			end if;
			if dst_neg then
				flags(3) := '1';
			end if;

			if dst_neg or (dst_l > src_l) then
				val_l := src_l - dst_l;
				val_neg := val_l(31) = '1';

				if (dst_neg /= src_neg) and (val_neg /= src_neg) then
					flags(1) := '1';
				end if;

				if dst_neg then
					if (dst_l > src_l) or (not src_neg) then
						flags(0) := '1';
					end if;
				elsif not src_neg then
					flags(0) := '1';
				end if;
			end if;
		end if;

		return flags;
	end function;

	function divu_divzero_flags_68020(
		dst : std_logic_vector(31 downto 0);
		is_word : boolean
	) return std_logic_vector is
		variable flags : std_logic_vector(3 downto 0) := (others => '0');
	begin
		if is_word then
			flags(1) := '1';
			if dst(31) = '1' then
				flags(3) := '1';
			elsif dst(31 downto 16) = x"0000" then
				flags(2) := '1';
			end if;
		else
			flags(0) := '0';
			flags(1) := '1';
			if dst(31) = '1' then
				flags(3) := '1';
			elsif dst = x"00000000" then
				flags(2) := '1';
			end if;
		end if;

		return flags;
	end function;

	function abs_u16(val : std_logic_vector(15 downto 0)) return unsigned is
	begin
		if val(15) = '1' then
			return unsigned(not val) + 1;
		end if;
		return unsigned(val);
	end function;

	function abs_u32(val : std_logic_vector(31 downto 0)) return unsigned is
	begin
		if val(31) = '1' then
			return unsigned(not val) + 1;
		end if;
		return unsigned(val);
	end function;

	function divu_overflow_flags_68020(
		dividend      : std_logic_vector(31 downto 0);
		current_flags : std_logic_vector(3 downto 0);
		is_word       : boolean
	) return std_logic_vector is
		variable flags : std_logic_vector(3 downto 0) := current_flags;
	begin
		if is_word then
			-- WinUAE/68020+: DIVU.W overflow forces V. Z/C are left unchanged. N is
			-- forced only if the signed 32-bit dividend is negative, otherwise it is
			-- left unchanged.
			flags(1) := '1';
			if dividend(31) = '1' then
				flags(3) := '1';
			end if;
		else
			-- WinUAE divul_overflow(): V=1, C=0, Z=(low32==0), N=sign(low32).
			flags(0) := '0';
			flags(1) := '1';
			flags(2) := '0';
			flags(3) := dividend(31);
			if dividend = x"00000000" then
				flags(2) := '1';
				flags(3) := '0';
			end if;
		end if;
		return flags;
	end function;

	function divs_divzero_flags_68020(
		current_flags : std_logic_vector(3 downto 0)
	) return std_logic_vector is
		variable flags : std_logic_vector(3 downto 0) := current_flags;
	begin
		-- WinUAE/68020+: signed divide-by-zero forces N=0, Z=1, C=0 and
		-- leaves V unchanged.
		flags(3) := '0';
		flags(2) := '1';
		flags(0) := '0';
		return flags;
	end function;

	function divs_overflow_flags_68020(
		dividend : std_logic_vector(31 downto 0);
		divisor  : std_logic_vector(15 downto 0);
		quotient_abs_low8 : std_logic_vector(7 downto 0)
	) return std_logic_vector is
		variable flags        : std_logic_vector(3 downto 0) := (others => '0');
		variable dividend_abs : unsigned(31 downto 0);
		variable divisor_abs  : unsigned(15 downto 0);
	begin
		flags(1) := '1';
		dividend_abs := abs_u32(dividend);
		divisor_abs := abs_u16(divisor);

		if divisor_abs = 0 then
			return flags;
		end if;

		-- 68020/030 signed word DIV overflow keeps V=1,C=0 and derives NZ
		-- from the low byte of the absolute trial quotient unless this is
		-- absolute overflow. The final sign-adjusted quotient byte gives the
		-- wrong N state for negative divisors.
		if dividend_abs(31 downto 16) >= divisor_abs then
			return flags;
		end if;

		if quotient_abs_low8 = x"00" then
			flags(2) := '1';
		end if;
		if quotient_abs_low8(7) = '1' then
			flags(3) := '1';
		end if;

		return flags;
	end function;

	function divsl_overflow_flags_68020(
		dividend_lo : std_logic_vector(31 downto 0);
		dividend_hi : std_logic_vector(31 downto 0);
		divisor     : std_logic_vector(31 downto 0);
		is_64bit    : boolean
	) return std_logic_vector is
		variable flags     : std_logic_vector(3 downto 0) := (others => '0');
		variable a64       : signed(63 downto 0);
		variable a32       : signed(31 downto 0);
		variable ahigh     : signed(31 downto 0);
		variable divider_s : signed(31 downto 0);
	begin
		flags(1) := '1';
		a32 := signed(dividend_lo);
		divider_s := signed(divisor);

		if is_64bit then
			a64 := signed(dividend_hi & dividend_lo);
			ahigh := signed(dividend_hi);

			if ahigh = to_signed(0, 32) then
				flags(2) := '1';
				return flags;
			elsif ahigh < to_signed(0, 32) and divider_s < to_signed(0, 32) and ahigh > divider_s then
				return flags;
			elsif dividend_lo = x"00000000" then
				flags(2) := '1';
				return flags;
			elsif a32(31) /= a64(63) then
				flags(3) := '1';
				return flags;
			end if;

			return flags;
		end if;

		if dividend_lo = x"00000000" then
			flags(2) := '1';
		elsif a32(31) = '1' then
			flags(3) := '1';
		end if;

		return flags;
	end function;

	function chk2_nv_flags_68020(
		lower : std_logic_vector(31 downto 0);
		upper : std_logic_vector(31 downto 0);
		val   : std_logic_vector(31 downto 0)
	) return std_logic_vector is
		variable nv      : std_logic_vector(1 downto 0) := "00"; -- N,V
		variable lower_s : signed(31 downto 0);
		variable upper_s : signed(31 downto 0);
		variable val_s   : signed(31 downto 0);
		constant zero32  : signed(31 downto 0) := (others => '0');
	begin
		lower_s := signed(lower);
		upper_s := signed(upper);
		val_s   := signed(val);

		if val = lower or val = upper then
			return nv;
		end if;

		if lower_s < zero32 and upper_s >= zero32 then
			if val_s < lower_s then
				nv(1) := '1';
			end if;
			if val_s >= zero32 and val_s < upper_s then
				nv(1) := '1';
			end if;
			if val_s >= zero32 and (lower_s - val_s) >= zero32 then
				nv(0) := '1';
				nv(1) := '0';
				if val_s > upper_s then
					nv(1) := '1';
				end if;
			end if;
		elsif lower_s >= zero32 and upper_s < zero32 then
			if val_s >= zero32 then
				nv(1) := '1';
			end if;
			if val_s > upper_s then
				nv(1) := '1';
			end if;
			if val_s > lower_s and (upper_s - val_s) >= zero32 then
				nv(0) := '1';
				nv(1) := '0';
			end if;
		elsif lower_s >= zero32 and upper_s >= zero32 and lower_s > upper_s then
			if val_s > upper_s and val_s < lower_s then
				nv(1) := '1';
			end if;
			if val_s < zero32 and (lower_s - val_s) < zero32 then
				nv(0) := '1';
			end if;
			if val_s < zero32 and (lower_s - val_s) >= zero32 then
				nv(1) := '1';
			end if;
		elsif lower_s >= zero32 and upper_s >= zero32 and lower_s <= upper_s then
			if val_s >= zero32 and val_s < lower_s then
				nv(1) := '1';
			end if;
			if val_s > upper_s then
				nv(1) := '1';
			end if;
			if val_s < zero32 and (upper_s - val_s) < zero32 then
				nv(0) := '1';
				nv(1) := '1';
			end if;
		elsif lower_s < zero32 and upper_s < zero32 and lower_s > upper_s then
			if val_s >= zero32 then
				nv(1) := '1';
			end if;
			if val_s > upper_s and val_s < lower_s then
				nv(1) := '1';
			end if;
			if val_s >= zero32 and (val_s - lower_s) < zero32 then
				nv(1) := '0';
				nv(0) := '1';
			end if;
		elsif lower_s < zero32 and upper_s < zero32 and lower_s <= upper_s then
			if val_s < lower_s then
				nv(1) := '1';
			end if;
			if val_s < zero32 and val_s > upper_s then
				nv(1) := '1';
			end if;
			if val_s >= zero32 and (val_s - lower_s) < zero32 then
				nv(1) := '1';
				nv(0) := '1';
			end if;
		end if;

		return nv;
	end function;


BEGIN
-----------------------------------------------------------------------------
-- set OP1in
-----------------------------------------------------------------------------
PROCESS (OP2out, reg_QB, opcode, OP1out, OP1in, exe_datatype, addsub_q, execOPC, exec,
			bcd_a, result_mulu, result_div, exe_condition, bf_shift, bf_ffo_offset, mulu_reg, BSout,
			Flags, FlagsSR, bits_out, exec_tas, rot_out, exe_opcode, result, bf_fffo, bf_firstbit, bf_datareg)
	BEGIN
		ALUout <= OP1in;
		ALUout(7) <= OP1in(7) OR exec_tas;
		IF exec(opcBFwb)='1' THEN
			ALUout <= result(31 downto 0);
			IF bf_fffo='1' THEN
				ALUout <= bf_ffo_offset - bf_firstbit;
			END IF;
		END IF;
		
		OP1in <= addsub_q;
		IF exec(opcABCD)='1' OR exec(opcSBCD)='1' THEN	
			OP1in(7 downto 0) <= bcd_a(7 downto 0);
		ELSIF exec(opcMULU)='1' AND MUL_Mode/=3 THEN
			IF MUL_Hardware=0 THEN
				IF exec(write_lowlong)='1' AND (MUL_Mode=1 OR MUL_Mode=2) THEN
					OP1in <= result_mulu(31 downto 0);	
				ELSE	
					OP1in <= result_mulu(63 downto 32);
				END IF;		
			ELSE
				IF exec(write_lowlong)='1' THEN --AND (MUL_Mode=1 OR MUL_Mode=2) THEN
					OP1in <= result_mulu(31 downto 0);	
				ELSE	
--					OP1in <= result_mulu(63 downto 32);
					OP1in <= mulu_reg(31 downto 0);
				END IF;
			END IF;
		ELSIF exec(opcDIVU)='1' AND DIV_Mode/=3 THEN
			IF exe_opcode(15)='1' OR DIV_Mode=0 THEN
--			IF exe_opcode(15)='1' THEN
				OP1in <= result_div(47 downto 32)&result_div(15 downto 0);	--word 
			ELSE		--64bit
				IF exec(write_reminder)='1' THEN
					OP1in <= result_div(63 downto 32);
				ELSE	
					OP1in <= result_div(31 downto 0);	
				END IF;
			END IF;
		ELSIF exec(opcOR)='1' THEN
			OP1in <= OP2out OR OP1out;
		ELSIF exec(opcAND)='1' THEN
			OP1in <= OP2out AND OP1out;
		ELSIF exec(opcScc)='1' THEN
			OP1in(7 downto 0) <= (others=>exe_condition); 
		ELSIF exec(opcEOR)='1' THEN
			OP1in <= OP2out XOR OP1out;
--		ELSIF exec(alu_move)='1' OR exec(exg)='1' THEN
		ELSIF exec(alu_move)='1' THEN
--			OP1in <= OP2out(31 downto 8)&(OP2out(7)OR exec_tas)&OP2out(6 downto 0);
			OP1in <= OP2out;
		ELSIF exec(opcROT)='1' THEN
			OP1in <= rot_out;
		ELSIF exec(exec_BS)='1' THEN
			OP1in <= BSout;
		ELSIF exec(opcSWAP)='1' THEN	
			OP1in <= OP1out(15 downto 0)& OP1out(31 downto 16);
		ELSIF exec(opcBITS)='1' THEN
			OP1in <= bits_out;	
		ELSIF exec(opcBF)='1' THEN
			OP1in <= bf_datareg;		--new bitfieldvector for bfins - for others the old bitfieldvector
		ELSIF exec(opcMOVESR)='1' THEN
			OP1in(7 downto 0) <= Flags;
			IF exe_opcode(9)='1' THEN
				OP1in(15 downto 8) <= "00000000";
			ELSE	
				OP1in(15 downto 8) <= FlagsSR;
			END IF;
		ELSIF exec(opcPACK)='1' THEN	
			OP1in(7 downto 0) <= addsub_q(11 downto 8) & addsub_q(3 downto 0);
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- addsub
-----------------------------------------------------------------------------
PROCESS (OP1out, OP2out, execOPC, Flags, long_start, movem_presub, exe_datatype, exec, addsub_a, addsub_b, opaddsub,
	     notaddsub_b, add_result, c_in, sndOPC, non_aligned, check_aligned)
	BEGIN
		addsub_a <= OP1out;
		IF exec(get_bfoffset)='1' THEN	
			IF sndOPC(11)='1' THEN
				addsub_a <= OP1out(31)&OP1out(31)&OP1out(31)&OP1out(31 downto 3);
			ELSE
				addsub_a <= "000000000000000000000000000000"&sndOPC(10 downto 9);
			END IF;	
		END IF;
		
		IF exec(subidx)='1' THEN
			opaddsub <= '1';
		ELSE
			opaddsub <= '0';
		END IF;
		
		c_in(0) <='0';
		addsub_b <= OP2out;
		IF exec(opcUNPACK)='1' THEN
			addsub_b(15 downto 0) <= "0000" & OP2out(7 downto 4) & "0000" & OP2out(3 downto 0);
		-- PMMU postadd/presub writeback must use fixed increment/decrement sizing
		-- even if execOPC is still asserted.  Two cases:
		--   CRP/SRP (pmmu_dbl): 64-bit, +8 increment, sets pmmu_dbl flag
		--   TC/TT0/TT1 (pmmu_wr/rd): 32-bit, +4 increment, identified by pmmu_wr/rd
		-- Normal instructions (ADD, SUB, etc.) with (An)+/-(An) must NOT be caught
		-- here -- for those, execOPC='1' AND exec(pmmu_wr/rd)='0', so only the
		-- execOPC='0' branch applies (which fires during the EA/address cycle, not
		-- the execute cycle).
		ELSIF (execOPC='0' OR
		       (exec(pmmu_dbl)='1' AND (exec(presub) OR exec(postadd) OR movem_presub)='1') OR
		       ((exec(pmmu_wr)='1' OR exec(pmmu_rd)='1') AND (exec(presub) OR exec(postadd))='1')) AND
		      exec(OP2out_one)='0' AND exec(get_bfoffset)='0'THEN
			IF long_start='0' AND exe_datatype="00" AND exec(use_SP)='0' THEN
				addsub_b <= "00000000000000000000000000000001";
				-- BUG #144 FIX: Added exec(pmmu_addr_inc) for PMOVE CRP/SRP 64-bit +4 address increment
				-- pmmu_addr_inc avoids register write-back side effect that postadd would cause
				-- BUG #291 FIX: When postadd AND pmmu_dbl are set, use +8 for register update!
				-- pmmu_addr_inc is for address calculation only, pmmu_dbl is for register write-back.
				-- The priority must be: pmmu_dbl (when postadd) > pmmu_addr_inc (address only).
				ELSIF long_start='0' AND exe_datatype="10" AND (exec(presub) OR exec(postadd) OR movem_presub OR exec(pmmu_addr_inc))='1' THEN
					-- BUG #291 FIX: Check pmmu_dbl BEFORE movem_action/pmmu_addr_inc!
					-- When postadd=1 (register update), pmmu_dbl gives +8 for CRP/SRP.
					-- When postadd=0 (address calc only), pmmu_addr_inc gives +4.
					IF exec(pmmu_dbl)='1' AND (exec(presub) OR exec(postadd) OR movem_presub)='1' THEN
						addsub_b <= "00000000000000000000000000001000";
					ELSIF exec(movem_action)='1' THEN
						addsub_b <= "00000000000000000000000000000110";
					ELSIF exec(pmmu_addr_inc)='1' THEN
						addsub_b <= "00000000000000000000000000000100";
					ELSE
						addsub_b <= "00000000000000000000000000000100";
					END IF;
			ELSE
				addsub_b <= "00000000000000000000000000000010";
			END IF;
		ELSE	
			IF (exec(use_XZFlag)='1' AND Flags(4)='1') OR exec(opcCHK)='1' THEN 
				c_in(0) <= '1';
			END IF;
			opaddsub <= exec(addsub);
		END IF;

		-- patch for un-aligned movem --mikej
		if exec(movem_action)='1' OR check_aligned='1' then
		  if (movem_presub = '0') then -- up
			if (non_aligned = '1') and (long_start = '0') then -- hold
			  addsub_b <= (others => '0');
			end if;
		  else
			if (non_aligned = '1') and (long_start = '0') then
			  if (exe_datatype = "10") then
				addsub_b <= "00000000000000000000000000001000";
			  else
				addsub_b <= "00000000000000000000000000000100";
			  end if;
			end if;
		  end if;
		end if;

		IF opaddsub='0' OR long_start='1' THEN		--ADD
			notaddsub_b <= '0'&addsub_b&c_in(0);
		ELSE					--SUB
			notaddsub_b <= NOT ('0'&addsub_b&c_in(0));
		END IF;
		add_result <= (('0'&addsub_a&notaddsub_b(0))+notaddsub_b);
		c_in(1) <= add_result(9) XOR addsub_a(8) XOR addsub_b(8);
		c_in(2) <= add_result(17) XOR addsub_a(16) XOR addsub_b(16);
		c_in(3) <= add_result(33);
		addsub_q <= add_result(32 downto 1); 
		addsub_ofl(0) <= (c_in(1) XOR add_result(8) XOR addsub_a(7) XOR addsub_b(7));		--V Byte
		addsub_ofl(1) <= (c_in(2) XOR add_result(16) XOR addsub_a(15) XOR addsub_b(15));	--V Word
		addsub_ofl(2) <= (c_in(3) XOR add_result(32) XOR addsub_a(31) XOR addsub_b(31));	--V Long
		c_out <= c_in(3 downto 1);
	END PROCESS;
	
------------------------------------------------------------------------------
--ALU
------------------------------------------------------------------------------		
PROCESS (OP1out, OP2out, CPU, exec, add_result, bcd_pur, bcd_a, bcd_kor, halve_carry, c_in)
	BEGIN
--BCD_ARITH-------------------------------------------------------------------
--04.04.2017 by Tobiflex - BCD handling with all undefined behavior!
		bcd_pur <= c_in(1)&add_result(8 downto 0);
		bcd_kor <= "000000000";
		halve_carry <= OP1out(4) XOR OP2out(4) XOR bcd_pur(5); 
		IF halve_carry='1' THEN
			bcd_kor(3 downto 0) <= "0110"; --  -6
		END IF;
		IF bcd_pur(9)='1' THEN
			bcd_kor(7 downto 4) <= "0110"; --  -60
		END IF;
		IF exec(opcABCD)='1' THEN	
			Vflag_a <= NOT bcd_pur(8) AND bcd_a(7); 
--			bcd_pur <= ('0'&OP1out(7 downto 0)&'1') + ('0'&OP2out(7 downto 0)&Flags(4));
			bcd_a <= bcd_pur(9 downto 1) + bcd_kor;
			IF (bcd_pur(4) AND (bcd_pur(3) OR bcd_pur(2)))='1' THEN
				bcd_kor(3 downto 0) <= "0110"; --  +6
			END IF;
			IF (bcd_pur(8) AND (bcd_pur(7) OR bcd_pur(6) OR (bcd_pur(5) AND bcd_pur(4) AND (bcd_pur(3) OR bcd_pur(2)))))='1' THEN
				bcd_kor(7 downto 4) <= "0110"; --  +60 
			END IF;
		ELSE --opcSBCD	
			Vflag_a <= bcd_pur(8) AND NOT bcd_a(7); 
--			bcd_pur <= ('0'&OP1out(7 downto 0)&'0') - ('0'&OP2out(7 downto 0)&Flags(4));
			bcd_a <= bcd_pur(9 downto 1) - bcd_kor;
		END IF;
		IF cpu(1)='1' THEN
			Vflag_a <= '0'; --68020
		END IF;
		bcd_a_carry <= bcd_pur(9) OR bcd_a(8);
	END PROCESS;
			
-----------------------------------------------------------------------------
-- Bits
-----------------------------------------------------------------------------
PROCESS (clk, exe_opcode, OP1out, OP2out, reg_QB, one_bit_in, bchg, bset, bit_Number, sndOPC)
	BEGIN
		IF rising_edge(clk) THEN		
	        IF  clkena_lw = '1' THEN
				bchg <= '0';
				bset <= '0';
				CASE opcode(7 downto 6) IS
					WHEN "01" =>					--bchg
						bchg <= '1';
					WHEN "11" =>					--bset
						bset <= '1';
					WHEN OTHERS => NULL;			
				END CASE;
			END IF;
		END IF;		
		
		IF exe_opcode(8)='0' THEN
			IF exe_opcode(5 downto 4)="00" THEN
				bit_number <= sndOPC(4 downto 0);
			ELSE
				bit_number <= "00"&sndOPC(2 downto 0);
			END IF;
		ELSE
			IF exe_opcode(5 downto 4)="00" THEN
				bit_number <= reg_QB(4 downto 0);
			ELSE
				bit_number <= "00"&reg_QB(2 downto 0);
			END IF;
		END IF;
						
		one_bit_in <= OP1out(conv_integer(bit_Number));
		bits_out <= OP1out;
		bits_out(conv_integer(bit_Number)) <= (bchg AND NOT one_bit_in) OR bset ;
	END PROCESS;

-----------------------------------------------------------------------------
-- Bit Field
-----------------------------------------------------------------------------	

PROCESS (clk, mux, mask, bitnr, bf_ins, bf_bchg, bf_bset, bf_exts, bf_shift, inmux0, inmux1, inmux2, inmux3, bf_set2, OP1out, OP2out, 
			result_tmp, bf_ext_in, mask_not_zero, exec, shift, datareg, bf_NFlag, result, reg_QB, unshifted_bitmask, bf_d32, bf_s32, 
			shifted_bitmask, bf_loffset, bitmaskmux0, bitmaskmux1, bitmaskmux2, bitmaskmux3, bf_width)
	BEGIN
		IF rising_edge(clk) THEN		
			IF clkena_lw = '1' THEN
				bf_bset <= '0';
				bf_bchg <= '0';
				bf_ins <= '0';
				bf_exts <= '0';
				bf_fffo <= '0';
				bf_d32 <= '0';
				bf_s32 <= '0';
--		000-bftst, 001-bfextu, 010-bfchg, 011-bfexts, 100-bfclr, 101-bfff0, 110-bfset, 111-bfins	
				IF opcode(5 downto 4) ="00" THEN
					  bf_s32 <= '1';
				END IF;
				CASE opcode(10 downto 8) IS
					WHEN "010" => bf_bchg <= '1';					--BFCHG
					WHEN "011" => bf_exts <= '1';					--BFEXTS
--					WHEN "100" => insert <= (OTHERS =>'0');	--BFCLR
					WHEN "101" => bf_fffo <= '1';					--BFFFO
					WHEN "110" => bf_bset <= '1';					--BFSET
					WHEN "111" => bf_ins <= '1';					--BFINS
									  bf_s32 <= '1';
					WHEN OTHERS => NULL;
				END CASE;
				IF opcode(4 downto 3)="00" THEN
					bf_d32 <= '1';
				END IF;
				bf_ext_out <= result(39 downto 32);
			END IF;
		END IF;
		
		IF bf_ins='1' THEN
			datareg <= reg_QB;
		ELSE
			datareg <= bf_set2;
		END IF;
		
		
-- create bitmask for operation
-- unshifted bitmask '0' => bit is in the Bitfieldvector
--					 '1' => bit isn't in the Bitfieldvector
-- Example bf_with=11    => "11111111 11111111 11111000 00000000"
-- datareg 
		unshifted_bitmask <= (OTHERS => '0'); 
		FOR i in 0 to 31 LOOP
			IF i>bf_width(4 downto 0) THEN
				datareg(i) <= '0'; 
				unshifted_bitmask(i) <= '1'; 			 
			END IF;	
		END LOOP;
		
		bf_NFlag <= datareg(conv_integer(bf_width));
		IF bf_exts='1' AND bf_NFlag='1' THEN
			bf_datareg <= datareg OR unshifted_bitmask;
		ELSE	
			bf_datareg <= datareg;
		END IF;	
		
-- shift bitmask for operation
		IF bf_loffset(4)='1' THEN 
			bitmaskmux3 <= unshifted_bitmask(15 downto 0)&unshifted_bitmask(31 downto 16);
		ELSE	
			bitmaskmux3 <= unshifted_bitmask;
		END IF;
		IF bf_loffset(3)='1' THEN 
			bitmaskmux2(31 downto 0) <= bitmaskmux3(23 downto 0)&bitmaskmux3(31 downto 24);
		ELSE	
			bitmaskmux2(31 downto 0) <= bitmaskmux3;
		END IF;
		IF bf_loffset(2)='1' THEN 
			bitmaskmux1 <= bitmaskmux2&"1111";
			IF bf_d32='1' THEN 
				bitmaskmux1(3 downto 0) <= bitmaskmux2(31 downto 28);
			END IF;
		ELSE	
			bitmaskmux1 <= "1111"&bitmaskmux2;
		END IF;
		IF bf_loffset(1)='1' THEN 
			bitmaskmux0 <= bitmaskmux1&"11";
			IF bf_d32='1' THEN 
				bitmaskmux0(1 downto 0) <= bitmaskmux1(31 downto 30);
			END IF;
		ELSE
			bitmaskmux0 <= "11"&bitmaskmux1;
		END IF;
		IF bf_loffset(0)='1' THEN 
			shifted_bitmask <= '1'&bitmaskmux0&'1';
			IF bf_d32='1' THEN 
				shifted_bitmask(0) <= bitmaskmux0(31);
			END IF;
		ELSE
			shifted_bitmask <= "11"&bitmaskmux0;
		END IF;
		
		
-- shift for ins 
		shift <= bf_ext_in&OP2out;
		IF bf_s32='1' THEN 
			shift(39 downto 32) <= OP2out(7 downto 0);
		END IF;
			
		IF bf_shift(0)='1' THEN 
			inmux0 <= shift(0)&shift(39 downto 1);
		ELSE	
			inmux0 <= shift;
		END IF;
		IF bf_shift(1)='1' THEN 
			inmux1 <= inmux0(1 downto 0)&inmux0(39 downto 2);
		ELSE
			inmux1 <= inmux0;
		END IF;
		IF bf_shift(2)='1' THEN 
			inmux2 <= inmux1(3 downto 0)&inmux1(39 downto 4);
		ELSE	
			inmux2 <= inmux1;
		END IF;
		IF bf_shift(3)='1' THEN 
			inmux3 <= inmux2(7 downto 0)&inmux2(31 downto 8);
		ELSE	
			inmux3 <= inmux2(31 downto 0);
		END IF;
		IF bf_shift(4)='1' THEN 
			bf_set2(31 downto 0) <= inmux3(15 downto 0)&inmux3(31 downto 16);
		ELSE	
			bf_set2(31 downto 0) <= inmux3;
		END IF;
		
		IF bf_ins='1' THEN
			result(31 downto 0) <= bf_set2;
			result(39 downto 32) <= bf_set2(7 downto 0);
		ELSIF bf_bchg='1' THEN
			result(31 downto 0) <= NOT OP2out;
			result(39 downto 32) <= NOT bf_ext_in;
		ELSE	
			result <= (OTHERS => '0');
		END IF;
		IF bf_bset='1' THEN
			result <= (OTHERS => '1');
		END IF;
-- 		
		IF bf_ins='1' THEN
			result_tmp <= bf_ext_in&OP1out;
		ELSE	
			result_tmp <= bf_ext_in&OP2out;
		END IF;
		FOR i in 0 to 39 LOOP
			IF shifted_bitmask(i)='1' THEN	
				result(i) <= result_tmp(i);   --restore old data
			END IF;	
		END LOOP;
		
--BFFFO	
		mask <= datareg;
		bf_firstbit <= ('0'&bitnr)+mask_not_zero;
		bitnr <= "11111";
		mask_not_zero <= '1'; 
		IF mask(31 downto 28)="0000" THEN
			IF mask(27 downto 24)="0000" THEN
				IF mask(23 downto 20)="0000" THEN
					IF mask(19 downto 16)="0000" THEN
						bitnr(4) <= '0';
						IF mask(15 downto 12)="0000" THEN
							IF mask(11 downto 8)="0000" THEN
								bitnr(3) <= '0';
								IF mask(7 downto 4)="0000" THEN
									bitnr(2) <= '0';
									mux <= mask(3 downto 0);
								ELSE
									mux <= mask(7 downto 4);
								END IF;
							ELSE
								mux <= mask(11 downto 8);
								bitnr(2) <= '0';
							END IF;
						ELSE
							mux <= mask(15 downto 12);
						END IF;
					ELSE
						mux <= mask(19 downto 16);
						bitnr(3) <= '0';
						bitnr(2) <= '0';
					END IF;
				ELSE
					mux <= mask(23 downto 20);
					bitnr(3) <= '0';
				END IF;
			ELSE
				mux <= mask(27 downto 24);
				bitnr(2) <= '0';
			END IF;
		ELSE
			mux <= mask(31 downto 28);
		END IF;
		
		IF mux(3 downto 2)="00" THEN
			bitnr(1) <= '0';
			IF mux(1)='0' THEN
				bitnr(0) <= '0';
				IF mux(0)='0' THEN
					mask_not_zero <= '0'; 
				END IF;	
			END IF;	
		ELSE		
			IF mux(3)='0' THEN
				bitnr(0) <= '0';
			END IF;	
		END  IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- Rotation
-----------------------------------------------------------------------------
PROCESS (exe_opcode, OP1out, Flags, rot_bits, rot_msb, rot_lsb, rot_rot, exec, BSout)
	BEGIN
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
						rot_rot <= OP1out(7);
			WHEN "01"|"11" =>				--Word
						rot_rot <= OP1out(15);
			WHEN "10" =>					--Long
						rot_rot <= OP1out(31);
			WHEN OTHERS => NULL;
		END CASE;
	
		CASE rot_bits IS
			WHEN "00" =>					--ASL, ASR
						rot_lsb <= '0';
						rot_msb <= rot_rot;
			WHEN "01" =>					--LSL, LSR
						rot_lsb <= '0';
						rot_msb <= '0';
			WHEN "10" =>					--ROXL, ROXR
						rot_lsb <= Flags(4);
						rot_msb <= Flags(4);
			WHEN "11" =>					--ROL, ROR
						rot_lsb <= rot_rot;
						rot_msb <= OP1out(0);
			WHEN OTHERS => NULL;
		END CASE;
	
		IF exec(rot_nop)='1' THEN
			rot_out <= OP1out;
			rot_X <= Flags(4);
			IF rot_bits="10" THEN	--ROXL, ROXR
				rot_C <= Flags(4);
			ELSE	
				rot_C <= '0';
			END IF;
		ELSE
			IF exe_opcode(8)='1' THEN		--left
				rot_out <= OP1out(30 downto 0)&rot_lsb;
				rot_X <= rot_rot;
				rot_C <= rot_rot;
			ELSE						--right
				rot_X <= OP1out(0);
				rot_C <= OP1out(0);
				rot_out <= rot_msb&OP1out(31 downto 1);
				CASE exe_opcode(7 downto 6) IS
					WHEN "00" =>					--Byte
						rot_out(7) <= rot_msb;
					WHEN "01"|"11" =>				--Word
						rot_out(15) <= rot_msb;
					WHEN OTHERS => NULL;	
				END CASE;
			END IF;
			IF BarrelShifter/=0 THEN
			   rot_out <= BSout;
			END IF;
		END IF;
	END PROCESS;
		
-----------------------------------------------------------------------------
-- Barrel Shifter
-----------------------------------------------------------------------------	
process (OP1out, OP2out, opcode, bit_nr, bit_msb, bs_shift, bs_shift_mod, ring, result_bs, exe_opcode, vector, 
         rot_bits, Flags, bs_C, msb, hot_msb, asl_over, asl_over_xor, ALU, asr_sign, exec)
	begin
		ring <= "100000";
		IF rot_bits="10" THEN --ROX L/R
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
							ring <= "001001";
				WHEN "01"|"11" =>				--Word
							ring <= "010001";
				WHEN "10" =>					--Long
							ring <= "100001";
				WHEN OTHERS => NULL;
			END CASE;
		ELSE
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
							ring <= "001000";
				WHEN "01"|"11" =>				--Word
							ring <= "010000";
				WHEN "10" =>					--Long
							ring <= "100000";
				WHEN OTHERS => NULL;
			END CASE;
		END IF;	
		
		IF exe_opcode(7 downto 6)="11" OR exec(exec_BS)='0' THEN
			bs_shift <="000001";
		ELSIF exe_opcode(5)='1' THEN
			bs_shift <= OP2out(5 downto 0);
		ELSE
			bs_shift(2 downto 0) <= exe_opcode(11 downto 9);
			IF exe_opcode(11 downto 9)="000" THEN
				bs_shift(5 downto 3) <="001";
			ELSE
				bs_shift(5 downto 3) <="000";
			END IF;
		END IF;

-- calc V-Flag by ASL		
		bit_msb <= "000000";
		hot_msb <= (OTHERS =>'0');
		hot_msb(conv_integer(bit_msb)) <= '1';
		IF bs_shift < ring THEN
			bit_msb <= ring-bs_shift;
		END IF;
		asl_over_xor <= (('0'&vector(30 downto 0)) XOR ('0'&vector(31 downto 1)))&msb;
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
				asl_over_xor(8) <= '0';
			WHEN "01"|"11" =>				--Word
				asl_over_xor(16) <= '0';
			WHEN OTHERS => NULL;
		END CASE;
		asl_over <= asl_over_xor - ('0'&hot_msb(31 downto 0));	
		bs_V <= '0';
		IF rot_bits="00" AND exe_opcode(8)='1' THEN --ASL
			bs_V <= not asl_over(32);
		END IF;
		
		bs_X <= bs_C;
		IF exe_opcode(8)='0' THEN --right shift
			bs_C <= result_bs(31);
		ELSE                  --left shift
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					bs_C <= result_bs(8);
				WHEN "01"|"11" =>				--Word
					bs_C <= result_bs(16);
				WHEN "10" =>					--Long
					bs_C <= result_bs(32);
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
		
		ALU <= (others=>'-');
		IF rot_bits="11" THEN --RO L/R
			bs_X <= Flags(4);
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					ALU(7 downto 0) <= result_bs(7 downto 0) OR result_bs(15 downto 8);
					bs_C <= ALU(7);
				WHEN "01"|"11" =>				--Word
					ALU(15 downto 0) <= result_bs(15 downto 0) OR result_bs(31 downto 16);
					bs_C <= ALU(15);
				WHEN "10" =>					--Long
					ALU <= result_bs(31 downto 0) OR result_bs(63 downto 32);
					bs_C <= ALU(31);
				WHEN OTHERS => NULL;
			END CASE;
			IF exe_opcode(8)='1' THEN --left shift
				bs_C <= ALU(0);
			END IF;
		ELSIF rot_bits="10" THEN --ROX L/R
			CASE exe_opcode(7 downto 6) IS
				WHEN "00" =>					--Byte
					ALU(7 downto 0) <= result_bs(7 downto 0) OR result_bs(16 downto 9);
					bs_C <= result_bs(8) OR result_bs(17);
				WHEN "01"|"11" =>				--Word
					ALU(15 downto 0) <= result_bs(15 downto 0) OR result_bs(32 downto 17);
					bs_C <= result_bs(16) OR result_bs(33);
				WHEN "10" =>					--Long
					ALU <= result_bs(31 downto 0) OR result_bs(64 downto 33);
					bs_C <= result_bs(32) OR result_bs(65);
				WHEN OTHERS => NULL;
			END CASE;
		ELSE
			IF exe_opcode(8)='0' THEN --right shift
				ALU <= result_bs(63 downto 32);
			ELSE                  --left shift
				ALU <= result_bs(31 downto 0);
			END IF;
		END IF;
		
		IF(bs_shift = "000000") THEN
			IF rot_bits="10" THEN --ROX L/R
				bs_C <= Flags(4);
			ELSE
				bs_C <= '0';
			END IF;
			bs_X <= Flags(4);
			bs_V <= '0';
		END IF;

-- calc shift count		
		-- bs_shift_mod <= std_logic_vector(unsigned(bs_shift) rem unsigned(ring));
		-- replace the divider with logic
		CASE ring IS
			WHEN "001001" =>
				IF bs_shift = 63 THEN
					bs_shift_mod <= "000000";
				ELSIF bs_shift > 6*9-1 THEN
					bs_shift_mod <= bs_shift - 6*9;
				ELSIF bs_shift > 5*9-1 THEN
					bs_shift_mod <= bs_shift - 5*9;
				ELSIF bs_shift > 4*9-1 THEN
					bs_shift_mod <= bs_shift - 4*9;
				ELSIF bs_shift > 3*9-1 THEN
					bs_shift_mod <= bs_shift - 3*9;
				ELSIF bs_shift > 2*9-1 THEN
					bs_shift_mod <= bs_shift - 2*9;
				ELSIF bs_shift > 9-1 THEN
					bs_shift_mod <= bs_shift - 9;
				ELSE
					bs_shift_mod <= bs_shift;
				END IF;
			WHEN "010001" =>
				IF bs_shift > 3*17-1 THEN
					bs_shift_mod <= bs_shift - 3*17;
				ELSIF bs_shift > 2*17-1 THEN
					bs_shift_mod <= bs_shift - 2*17;
				ELSIF bs_shift > 17-1 THEN
					bs_shift_mod <= bs_shift - 17;
				ELSE
					bs_shift_mod <= bs_shift;
				END IF;
			WHEN "100001" =>
				IF bs_shift > 32 THEN
					bs_shift_mod <= bs_shift - 33;
				ELSE
					bs_shift_mod <= bs_shift;
				END IF;
			WHEN "001000" => bs_shift_mod <= "000" & bs_shift(2 downto 0);
			WHEN "010000" => bs_shift_mod <=  "00" & bs_shift(3 downto 0);
			WHEN "100000" => bs_shift_mod <=   "0" & bs_shift(4 downto 0);
			WHEN OTHERS => bs_shift_mod <= (OTHERS => '0');
		END CASE;

		bit_nr <= bs_shift_mod(5 downto 0);
		IF exe_opcode(8)='0' THEN  --right shift
			bit_nr <= ring-bs_shift_mod;
		END IF;
		IF rot_bits(1)='0' THEN --only shift
			IF exe_opcode(8)='0' THEN  --right shift
				bit_nr <= 32-bs_shift_mod;
			END IF;
			IF bs_shift = ring THEN
				IF exe_opcode(8)='0' THEN  --right shift
					bit_nr <= 32-ring;
				ELSE	
					bit_nr <= ring;
				END IF;
			END IF;
			IF bs_shift > ring THEN
				IF exe_opcode(8)='0' THEN  --right shift
					bit_nr <= "000000";
					bs_C <= '0';
				ELSE	
					bit_nr <= ring+1;
				END IF;
			END IF;
		END IF;
		
-- calc ASR sign		
		BSout <= ALU;
		asr_sign <= (OTHERS =>'0');	
		asr_sign(32 downto 1) <= asr_sign(31 downto 0) OR hot_msb(31 downto 0);	
		IF rot_bits="00" AND exe_opcode(8)='0' AND msb='1' THEN --ASR
			BSout <= ALU or asr_sign(32 downto 1);
			IF bs_shift > ring THEN
				bs_C <= '1';
			END IF;
		END IF;

		vector(32 downto 0) <= '0'&OP1out;
		CASE exe_opcode(7 downto 6) IS
			WHEN "00" =>					--Byte
				msb <= OP1out(7);
				vector(31 downto 8) <= X"000000";
				BSout(31 downto 8) <= X"000000";
				IF rot_bits="10" THEN --ROX L/R
					vector(8) <= Flags(4);
				END IF;
			WHEN "01"|"11" =>				--Word
				msb <= OP1out(15);
				vector(31 downto 16) <= X"0000";
				BSout(31 downto 16) <= X"0000";
				IF rot_bits="10" THEN --ROX L/R
					vector(16) <= Flags(4);
				END IF;
			WHEN "10" =>					--Long
				msb <= OP1out(31);
				IF rot_bits="10" THEN --ROX L/R
					vector(32) <= Flags(4);
				END IF;
			WHEN OTHERS => NULL;
		END CASE;
		result_bs <= std_logic_vector(unsigned('0'&X"00000000"&vector) sll to_integer(unsigned(bit_nr(5 downto 0)))); 

  end process;

  
------------------------------------------------------------------------------
--CCR op
------------------------------------------------------------------------------		
PROCESS (clk, Reset, exe_opcode, exe_datatype, Flags, last_data_read, OP2out, OP1out, chk2_lower_bound, flag_z, OP1IN, c_out, addsub_ofl,
	     bcd_a, bcd_a_carry, Vflag_a, exec, micro_state)
		variable chk2_lower : std_logic_vector(31 downto 0);
		variable chk2_upper : std_logic_vector(31 downto 0);
		variable chk2_val   : std_logic_vector(31 downto 0);
		variable chk2_nv    : std_logic_vector(1 downto 0);
		variable chk2_size  : std_logic_vector(1 downto 0);
	BEGIN
		IF exec(andiSR)='1' THEN
			CCRin <= Flags AND last_data_read(7 downto 0);
		ELSIF exec(eoriSR)='1' THEN
			CCRin <= Flags XOR last_data_read(7 downto 0);
		ELSIF exec(oriSR)='1' THEN
			CCRin <= Flags OR last_data_read(7 downto 0);
		ELSE	
			CCRin <= OP2out(7 downto 0);
		END IF;	
		
------------------------------------------------------------------------------
--Flags
------------------------------------------------------------------------------		
		flag_z <= "000";
		IF exec(use_XZFlag)='1' AND flags(2)='0' THEN
			flag_z <= "000";
		ELSIF OP1in(7 downto 0)="00000000" THEN
			flag_z(0) <= '1';
			IF OP1in(15 downto 8)="00000000" THEN
				flag_z(1) <= '1';
				IF OP1in(31 downto 16)="0000000000000000" THEN
					flag_z(2) <= '1';	
				END IF;
			END IF;
		END IF;
		
--					--Flags NZVC
		IF exe_datatype="00" THEN 						--Byte
			set_flags <= OP1IN(7)&flag_z(0)&addsub_ofl(0)&c_out(0);
			IF exec(opcABCD)='1' OR exec(opcSBCD)='1' THEN	
				set_flags(0) <= bcd_a_carry;
				set_flags(1) <= Vflag_a;
			END IF;
		ELSIF exe_datatype="10" OR exec(opcCPMAW)='1' THEN 						--Long
			set_flags <= OP1IN(31)&flag_z(2)&addsub_ofl(2)&c_out(2);
		ELSE 						--Word
			set_flags <= OP1IN(15)&flag_z(1)&addsub_ofl(1)&c_out(1);
		END IF;
		
		IF rising_edge(clk) THEN		
			IF Reset='1' THEN
				Flags(7 downto 0) <= "00000000"; 
				chk2_lower_bound <= (OTHERS => '0');
			ELSIF clkena_lw = '1' THEN
				IF micro_state = chk21 THEN
					-- CHK2.L reaches chk23 with only the upper bound on OP2out.
					-- Keep the lower bound from chk21 so long N matches byte/word.
					chk2_lower_bound <= OP2out;
				END IF;
				IF exec(directSR)='1' THEN
					Flags(7 downto 0) <= data_read(7 downto 0);
				END IF;
				IF set_stop='1' THEN
					Flags(7 downto 0) <= data_read(7 downto 0);
					Flags(7 downto 5) <= "000";  -- STOP loads SR but reserved CCR bits remain zero
				END IF;
				IF exec(directCCR)='1' THEN
					Flags(7 downto 0) <= data_read(7 downto 0);
					Flags(7 downto 5) <= "000";  -- Reserved CCR bits must always be zero (MC68030 UM)
				END IF;
				-- BUG #397 FIX: Restore pre-RTE CCR on format error.
				-- directSR loaded frame CCR which is now invalid.
				-- Last-assignment-wins ensures this overrides directSR above.
				IF restore_ccr='1' THEN
					Flags(7 downto 0) <= restored_ccr_value;
				END IF;
				
				IF exec(opcROT)='1' AND decodeOPC='0' THEN
					asl_VFlag <= ((set_flags(3) XOR rot_rot) OR asl_VFlag);	
				ELSE	
					asl_VFlag <= '0';
				END IF;	
				IF exec(to_CCR)='1' THEN
					Flags(7 downto 0) <= CCRin(7 downto 0);			--CCR
				ELSIF Z_error='1' THEN
					IF micro_state = trap0 THEN
						IF CPU(1)='1' THEN
							IF div_word_latched='1' THEN
								IF div_signed_latched='0' THEN
									Flags(3 downto 0) <= divu_divzero_flags_68020(div_dividend_latched(47 downto 16), true);
								ELSE
									Flags(3 downto 0) <= divs_divzero_flags_68020(Flags(3 downto 0));
								END IF;
							ELSIF div_signed_latched='0' THEN
								Flags(3 downto 0) <= divu_divzero_flags_68020(div_dividend_latched(31 downto 0), false);
							ELSE
								Flags(3 downto 0) <= divs_divzero_flags_68020(Flags(3 downto 0));
							END IF;
						ELSE
							-- Legacy 68000/010 path.
							IF exe_opcode(8)='0' THEN
								Flags(3 downto 0) <= '0'&NOT reg_QA(31)&"00";
							ELSE
								Flags(3 downto 0) <= "0100";
							END IF;
						END IF;
					END IF;
				ELSIF exec(no_Flags)='0' THEN
					last_Flags1 <= Flags(3 downto 0);
					IF exec(opcADD)='1' THEN
						Flags(4) <= set_flags(0);
					ELSIF exec(opcROT)='1' AND rot_bits/="11" AND exec(rot_nop)='0' THEN
						Flags(4) <= rot_X; 	
					ELSIF exec(exec_BS)='1' THEN
						Flags(4) <= BS_X; 	
					END IF;
					
					IF (exec(opcCMP) OR exec(alu_setFlags))='1' THEN
						Flags(3 downto 0) <= set_flags;
					ELSIF exec(opcDIVU)='1' AND DIV_Mode/=3 THEN
						IF V_Flag='1' THEN	
							IF CPU(1)='1' THEN
								IF div_word_latched='1' THEN
									IF div_signed_latched='0' THEN
										Flags(3 downto 0) <= divu_overflow_flags_68020(div_dividend_latched(47 downto 16), Flags(3 downto 0), true);
									ELSE
										Flags(3 downto 0) <= divs_overflow_flags_68020(div_dividend_latched(47 downto 16), div_src_latched(15 downto 0), div_reg(7 downto 0));
									END IF;
								ELSIF div_signed_latched='0' THEN
									Flags(3 downto 0) <= divu_overflow_flags_68020(div_dividend_latched(31 downto 0), Flags(3 downto 0), false);
								ELSE
									Flags(3 downto 0) <= divsl_overflow_flags_68020(
										div_dividend_latched(31 downto 0),
										div_dividend_latched(63 downto 32),
										div_src_latched,
										div_64bit_latched='1'
									);
								END IF;
							ELSE
								Flags(3 downto 0) <= "1010";
							END IF;
						ELSIF div_word_latched='1' THEN
							Flags(3 downto 0) <= OP1IN(15)&flag_z(1)&"00";
						ELSE
							Flags(3 downto 0) <= OP1IN(31)&flag_z(2)&"00";
						END IF;
					ELSIF exec(write_reminder)='1' AND MUL_Mode/=3 THEN -- z-flag MULU.l
						Flags(3) <= set_flags(3);
						Flags(2) <= set_flags(2) AND Flags(2);
						Flags(1) <= '0';
						Flags(0) <= '0';
					ELSIF exec(write_lowlong)='1' AND (MUL_Mode=1 OR MUL_Mode=2) THEN  -- flag MULU.l
						Flags(3) <= set_flags(3);
						Flags(2) <= set_flags(2);
						Flags(1) <= set_mV_Flag;	--V
						Flags(0) <= '0';
					ELSIF exec(opcOR)='1' OR exec(opcAND)='1' OR exec(opcEOR)='1' OR exec(opcMOVE)='1' OR exec(opcMOVEQ)='1' OR exec(opcSWAP)='1' OR exec(opcBF)='1' OR (exec(opcMULU)='1' AND MUL_Mode/=3) THEN
						Flags(1 downto 0) <= "00";
						Flags(3 downto 2) <= set_flags(3 downto 2);
						IF exec(opcBF)='1' THEN
							Flags(3) <= bf_NFlag;
						END IF;	
					ELSIF exec(opcROT)='1' THEN
						Flags(3 downto 2) <= set_flags(3 downto 2);
						Flags(0) <= rot_C;
						IF rot_bits="00" AND ((set_flags(3) XOR rot_rot) OR asl_VFlag)='1' THEN		--ASL/ASR
							Flags(1) <= '1';
						ELSE		
							Flags(1) <= '0';
						END IF;	
					ELSIF exec(exec_BS)='1' THEN
						Flags(3 downto 2) <= set_flags(3 downto 2);
						Flags(0) <= BS_C;
						Flags(1) <= BS_V;
					ELSIF exec(opcBITS)='1' THEN
						Flags(2) <= NOT one_bit_in;	
					ELSIF exec(opcCHK2)='1' THEN		--micro_state = chk23
--micro_state	 chk21   chk22   chk23
--OP1out      		UB		R			R
--OP2out				LB		LB			UB
----lower bound first
						-- BUG #444 FIX: For CHK2/CMP2 with bit 15 set, the compared
						-- register is treated as a full longword, but the bounds still
						-- use the instruction size encoded in the opcode. The previous
						-- code reused exe_datatype for both, which broke CHK2.B A-reg
						-- compares seen in cputest BASIC.
						chk2_size := exe_opcode(10 downto 9);
						IF sndOPC(15)='1' THEN
							chk2_val := OP1out;
						ELSE
							CASE chk2_size IS
								WHEN "00" =>
									chk2_val := std_logic_vector(resize(signed(OP1out(7 downto 0)), 32));
								WHEN "01" =>
									chk2_val := std_logic_vector(resize(signed(OP1out(15 downto 0)), 32));
								WHEN OTHERS =>
									chk2_val := OP1out;
							END CASE;
						END IF;

						CASE chk2_size IS
							WHEN "00" =>
								chk2_lower := std_logic_vector(resize(signed(OP2out(15 downto 8)), 32));
								chk2_upper := std_logic_vector(resize(signed(OP2out(7 downto 0)), 32));
							WHEN "01" =>
								chk2_lower := std_logic_vector(resize(signed(chk2_lower_bound(15 downto 0)), 32));
								chk2_upper := std_logic_vector(resize(signed(OP2out(15 downto 0)), 32));
							WHEN OTHERS =>
								chk2_lower := chk2_lower_bound;
								chk2_upper := OP2out;
						END CASE;
						chk2_nv := chk2_nv_flags_68020(chk2_lower, chk2_upper, chk2_val);

						-- 68020/030 CHK2/CMP2 sets N/V from the range topology, but C/Z come
						-- from the final in-range/equality test, not from the internal compare
						-- microstates. This matches WinUAE's setchk2undefinedflags() + the
						-- surrounding C/Z logic used by the generated CHK2 handlers.
						Flags(0) <= '0';
						Flags(2) <= '0';
						IF chk2_val = chk2_lower OR chk2_val = chk2_upper THEN
							Flags(2) <= '1';
						ELSIF signed(chk2_lower) <= signed(chk2_upper) THEN
							IF signed(chk2_val) < signed(chk2_lower) OR signed(chk2_val) > signed(chk2_upper) THEN
								Flags(0) <= '1';
							END IF;
						ELSIF signed(chk2_val) > signed(chk2_upper) AND signed(chk2_val) < signed(chk2_lower) THEN
							Flags(0) <= '1';
						END IF;
						Flags(1) <= chk2_nv(0);
						Flags(3) <= chk2_nv(1);
					ELSIF exec(opcCHK)='1' THEN
						IF CPU(1)='1' THEN
							IF exe_datatype="01" THEN
								Flags(3 downto 0) <= chk_flags_68020(OP2out, OP1out, true);
							ELSE
								Flags(3 downto 0) <= chk_flags_68020(OP2out, OP1out, false);
							END IF;
						ELSE	
							IF exe_datatype="01" THEN 						--Word
								Flags(3) <= OP1out(15);
							ELSE	
								Flags(3) <= OP1out(31);
							END IF;	
							IF OP1out(15 downto 0)=X"0000" AND (exe_datatype="01" OR OP1out(31 downto 16)=X"0000") THEN
								Flags(2) <='1';
							ELSE	
								Flags(2) <='0';
							END IF;	
							Flags(1) <= '0';
							Flags(0) <= '0';
						END IF;
					END IF;
				END IF;	
			END IF;	
				-- Live writes to CCR/SR must clear the unused low-byte bits on
				-- 68020/030. Stack-driven restores (RTR/RTE/directSR) keep the
				-- stacked image, so do not mask them here unconditionally.
				IF exec(to_CCR)='1' THEN
					Flags(7 downto 5) <= "000";
				END IF;
		END IF;	
	END PROCESS;
	
---------------------------------------------------------------------------------
------ MULU/MULS
---------------------------------------------------------------------------------	
PROCESS (exe_opcode, OP2out, muls_msb, mulu_reg, FAsign, mulu_sign, reg_QA, faktorA, faktorB, result_mulu, signedOP)
--PROCESS (exec, reg_QA, OP2out, faktorA, faktorB, signedOP)
	BEGIN
	IF MUL_Hardware=1 THEN
--		IF exe_opcode(15)='1' OR MUL_Mode=0 THEN	-- 16 Bit
		IF MUL_Mode=0 THEN	-- 16 Bit
			IF signedOP='1' AND reg_QA(15)='1' THEN
				faktorA <= X"FFFFFFFF";
			ELSE	
				faktorA <= X"00000000";
			END IF;
			IF signedOP='1' AND OP2out(15)='1' THEN
				faktorB <= X"FFFFFFFF";
			ELSE	
				faktorB <= X"00000000";
			END IF;
			result_mulu(63 downto 0) <= (faktorA(15 downto 0) & reg_QA(15 downto 0)) * (faktorB(15 downto 0) & OP2out(15 downto 0));
		ELSE
			IF exe_opcode(15)='1' THEN	-- 16 Bit
				IF signedOP='1' AND reg_QA(15)='1' THEN
					faktorA <= X"FFFFFFFF";
				ELSE	
					faktorA <= X"00000000";
				END IF;
				IF signedOP='1' AND OP2out(15)='1' THEN
					faktorB <= X"FFFFFFFF";
				ELSE	
					faktorB <= X"00000000";
				END IF;
			ELSE	
				faktorA(15 downto 0) <= reg_QA(31 downto 16);
				faktorB(15 downto 0) <= OP2out(31 downto 16);
				IF signedOP='1' AND reg_QA(31)='1' THEN
					faktorA(31 downto 16) <= X"FFFF";
				ELSE	
					faktorA(31 downto 16) <= X"0000";
				END IF;
				IF signedOP='1' AND OP2out(31)='1' THEN
					faktorB(31 downto 16) <= X"FFFF";
				ELSE	
					faktorB(31 downto 16) <= X"0000";
				END IF;
			END IF;
			result_mulu(127 downto 0) <= (faktorA(31 downto 16) & faktorA(31 downto 0) & reg_QA(15 downto 0)) * (faktorB(31 downto 16) & faktorB(31 downto 0) & OP2out(15 downto 0));
		END IF;
--	END PROCESS;
-------------------------------------------------------------------------------
---- MULU/MULS
-------------------------------------------------------------------------------	
--PROCESS (exe_opcode, OP2out, muls_msb, mulu_reg, FAsign, mulu_sign, reg_QA, faktorB, result_mulu, signedOP)
--	BEGIN
	ELSE
		IF (signedOP='1' AND faktorB(31)='1') OR FAsign='1' THEN
			muls_msb <= mulu_reg(63);
		ELSE
			muls_msb <= '0';
		END IF;	
		
		IF signedOP='1' AND faktorB(31)='1' THEN
			mulu_sign <= '1';
		ELSE
			mulu_sign <= '0';
		END IF;	
		
		IF MUL_Mode=0 THEN	-- 16 Bit
			result_mulu(63 downto 32) <= muls_msb&mulu_reg(63 downto 33);	
			result_mulu(15 downto 0) <= 'X'&mulu_reg(15 downto 1);	
			IF mulu_reg(0)='1' THEN
				IF FAsign='1' THEN
					result_mulu(63 downto 47) <= (muls_msb&mulu_reg(63 downto 48)-(mulu_sign&faktorB(31 downto 16)));	
				ELSE
					result_mulu(63 downto 47) <= (muls_msb&mulu_reg(63 downto 48)+(mulu_sign&faktorB(31 downto 16)));	
				END IF;
			END IF;	
		ELSE				-- 32 Bit
			result_mulu(63 downto 0) <= muls_msb&mulu_reg(63 downto 1);	
			IF mulu_reg(0)='1' THEN
				IF FAsign='1' THEN
					result_mulu(63 downto 31) <= (muls_msb&mulu_reg(63 downto 32)-(mulu_sign&faktorB));	
				ELSE
					result_mulu(63 downto 31) <= (muls_msb&mulu_reg(63 downto 32)+(mulu_sign&faktorB));	
				END IF;
			END IF;	
		END IF;
		IF exe_opcode(15)='1' OR MUL_Mode=0 THEN
			faktorB(31 downto 16) <= OP2out(15 downto 0);
			faktorB(15 downto 0) <= (OTHERS=>'0');
		ELSE	
			faktorB <= OP2out;
		END IF;
	END IF;
		IF (result_mulu(63 downto 32)=X"00000000" AND (signedOP='0' OR result_mulu(31)='0')) OR
			(result_mulu(63 downto 32)=X"FFFFFFFF" AND signedOP='1' AND result_mulu(31)='1') THEN
			set_mV_Flag <= '0';
		ELSE	
			set_mV_Flag <= '1';
		END IF;
	END PROCESS;
	
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				IF MUL_Hardware=0 THEN
					IF micro_state=mul1 THEN
						mulu_reg(63 downto 32) <= (OTHERS=>'0');
						IF divs='1' AND ((exe_opcode(15)='1' AND reg_QA(15)='1') OR (exe_opcode(15)='0' AND reg_QA(31)='1')) THEN				--MULS Neg faktor
							FAsign <= '1';
							mulu_reg(31 downto 0) <= 0-reg_QA;
						ELSE
							FAsign <= '0';
							mulu_reg(31 downto 0) <= reg_QA;
						END IF;	
					ELSIF exec(opcMULU)='0' THEN
						mulu_reg <= result_mulu(63 downto 0);	
					END IF;
				ELSE	
					mulu_reg(31 downto 0) <= result_mulu(63 downto 32);
				END IF;
			END IF;
		END IF;
	END PROCESS;
		
-------------------------------------------------------------------------------
---- DIVU/DIVS
-------------------------------------------------------------------------------
		
PROCESS (execOPC, OP1out, OP2out, div_reg, div_neg, div_bit, div_sub, div_quot, OP1_sign, div_over, result_div, reg_QA, opcode, sndOPC, divs, exe_opcode, reg_QB, 
	     signedOP, nozero, div_qsign, OP2outext, result_div_pre)
	BEGIN
		divs <= (opcode(15) AND opcode(8)) OR (NOT opcode(15) AND sndOPC(11));
		dividend(15 downto 0) <= (OTHERS=> '0');
		dividend(63 downto 32) <= (OTHERS=> divs AND reg_QA(31));
		IF exe_opcode(15)='1' OR DIV_Mode=0 THEN --DIV.W
			dividend(47 downto 16) <= reg_QA;
			div_qsign <= result_div_pre(15);
		ELSE												  --DIV.l
			dividend(31 downto 0) <= reg_QA;
			IF exe_opcode(14)='1' AND sndOPC(10)='1' THEN
				dividend(63 downto 32) <= reg_QB;
			END IF;
			div_qsign <= result_div_pre(31);
		END IF;
		IF signedOP='1' OR opcode(15)='0' THEN 
			OP2outext <= OP2out(31 downto 16);
		ELSE
			OP2outext <= (OTHERS=> '0');
		END IF;
		IF signedOP='1' AND OP2out(31) ='1' THEN
			div_sub <= (div_reg(63 downto 31))+('1'&OP2out(31 downto 0));
		ELSE
			div_sub <= (div_reg(63 downto 31))-('0'&OP2outext(15 downto 0)&OP2out(15 downto 0));
		END IF;	
		IF DIV_Mode=0 THEN
			div_bit <= div_sub(16);
		ELSE
			div_bit <= div_sub(32);
		END IF;
		IF div_bit='1' THEN
			div_quot(63 downto 32) <= div_reg(62 downto 31);	
		ELSE
			div_quot(63 downto 32) <= div_sub(31 downto 0);	
		END IF;	
		div_quot(31 downto 0) <= div_reg(30 downto 0)&NOT div_bit;
		
		IF div_neg='1' THEN
			result_div_pre(31 downto 0) <= 0-div_quot(31 downto 0);

		ELSE
			result_div_pre(31 downto 0) <= div_quot(31 downto 0);
		END IF;	
		
		IF (((nozero='1' OR div_bit='0') AND signedOP='1' AND (OP2out(31) XOR OP1_sign XOR div_qsign)='1' )	--Overflow DIVS
			OR (signedOP='0' AND div_over(32)='0')) AND DIV_Mode/=3 THEN	--Overflow DIVU
			set_V_Flag <= '1';
		ELSE	
			set_V_Flag <= '0';
		END IF;
	END PROCESS;
	
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				IF micro_state/=div_end2 THEN
					V_Flag <= set_V_Flag;
				END IF;
				signedOP <= divs;
					IF micro_state=div1 THEN
						div_dividend_latched <= dividend;
						div_signed_latched <= divs;
						IF exe_opcode(15)='1' OR DIV_Mode=0 THEN
							div_word_latched <= '1';
						ELSE
							div_word_latched <= '0';
						END IF;
						IF exe_opcode(15)='0' AND exe_opcode(14)='1' AND sndOPC(10)='1' THEN
							div_64bit_latched <= '1';
						ELSE
							div_64bit_latched <= '0';
						END IF;
						nozero <= '0';
					IF divs='1' AND dividend(63)='1' THEN				-- Neg dividend
						OP1_sign <= '1';
						div_reg <= 0-dividend;
					ELSE
						OP1_sign <= '0';
						div_reg <= dividend;
					END IF;	
				ELSE
					div_reg <= div_quot;	
					nozero <= NOT div_bit OR nozero;
				END IF;
				IF micro_state=div2 THEN
					div_src_latched <= OP2out;
					div_neg <= signedOP AND (OP2out(31) XOR OP1_sign);
					IF DIV_Mode=0 THEN
						div_over(32 downto 16) <= ('0'&div_reg(47 downto 32))-('0'&OP2out(15 downto 0));
					ELSE	
						div_over <= ('0'&div_reg(63 downto 32))-('0'&OP2outext(15 downto 0)&OP2out(15 downto 0));
					END IF;	
				END IF;
				IF exec(write_reminder)='0' THEN
					result_div(31 downto 0) <= result_div_pre;
					IF OP1_sign='1' THEN
						result_div(63 downto 32) <= 0-div_quot(63 downto 32);
					ELSE
						result_div(63 downto 32) <= div_quot(63 downto 32);
					END IF;	
				END IF;
			END IF;
		END IF;
	END PROCESS;
END;
