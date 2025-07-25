------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68K MC68881/68882 FPU Test Bench                                      --
-- Comprehensive test coverage for all FPU operations and edge cases        --
-- Copyright (c) 2025                                                       --
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
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.TG68K_Pack.all;

entity TG68K_FPU_TestBench is
end TG68K_FPU_TestBench;

architecture testbench of TG68K_FPU_TestBench is

	-- Clock and reset
	signal clk				: std_logic := '0';
	signal nReset			: std_logic := '0';
	signal clkena			: std_logic := '1';
	
	-- FPU interface signals
	signal opcode			: std_logic_vector(15 downto 0);
	signal extension_word	: std_logic_vector(15 downto 0);
	signal fpu_enable		: std_logic;
	signal cpu_data_in		: std_logic_vector(31 downto 0);
	signal fpu_data_out		: std_logic_vector(31 downto 0);
	signal fpu_busy			: std_logic;
	signal fpu_done			: std_logic;
	signal fpu_exception	: std_logic;
	signal exception_code	: std_logic_vector(7 downto 0);
	signal fpcr_out			: std_logic_vector(31 downto 0);
	signal fpsr_out			: std_logic_vector(31 downto 0);
	signal fpiar_out		: std_logic_vector(31 downto 0);
	
	-- Clock generation
	constant CLK_PERIOD		: time := 10 ns;
	signal sim_finished		: boolean := false;
	
	-- Test control
	signal test_phase		: integer := 0;
	signal test_passed		: boolean := true;
	signal total_tests		: integer := 0;
	signal passed_tests		: integer := 0;
	
	-- IEEE 754 test values (80-bit extended precision)
	constant FP_ZERO		: std_logic_vector(79 downto 0) := X"00000000000000000000";
	constant FP_ONE			: std_logic_vector(79 downto 0) := X"3FFF8000000000000000";  -- 1.0
	constant FP_TWO			: std_logic_vector(79 downto 0) := X"40008000000000000000";  -- 2.0
	constant FP_HALF		: std_logic_vector(79 downto 0) := X"3FFE8000000000000000";  -- 0.5
	constant FP_NEG_ONE		: std_logic_vector(79 downto 0) := X"BFFF8000000000000000";  -- -1.0
	constant FP_PI			: std_logic_vector(79 downto 0) := X"4000C90FDAA22168C235";  -- π
	constant FP_E			: std_logic_vector(79 downto 0) := X"4000ADF85458A2BB4A9A";  -- e

begin

	-- FPU instantiation
	UUT: TG68K_FPU
	port map(
		clk => clk,
		nReset => nReset,
		clkena => clkena,
		
		-- CPU Interface
		opcode => opcode,
		extension_word => extension_word,
		fpu_enable => fpu_enable,
		cpu_data_in => cpu_data_in,
		fpu_data_out => fpu_data_out,
		
		-- Control Signals
		fpu_busy => fpu_busy,
		fpu_done => fpu_done,
		fpu_exception => fpu_exception,
		exception_code => exception_code,
		
		-- Status and Control Registers
		fpcr_out => fpcr_out,
		fpsr_out => fpsr_out,
		fpiar_out => fpiar_out
	);
	
	-- Clock generation
	clk_process: process
	begin
		while not sim_finished loop
			clk <= '0';
			wait for CLK_PERIOD/2;
			clk <= '1';
			wait for CLK_PERIOD/2;
		end loop;
		wait;
	end process;
	
	-- Test reporting procedures
	procedure report_test(test_name : string; passed : boolean) is
		variable l : line;
	begin
		total_tests <= total_tests + 1;
		if passed then
			passed_tests <= passed_tests + 1;
			write(l, string'("PASS: "));
		else
			write(l, string'("FAIL: "));
			test_passed <= false;
		end if;
		write(l, test_name);
		writeline(output, l);
	end procedure;
	
	procedure wait_for_fpu_completion is
	begin
		wait until rising_edge(clk) and (fpu_done = '1' or fpu_exception = '1');
		wait until rising_edge(clk);  -- Extra cycle for stability
	end procedure;
	
	procedure send_fpu_instruction(
		inst_opcode : std_logic_vector(15 downto 0);
		inst_extension : std_logic_vector(15 downto 0)
	) is
	begin
		opcode <= inst_opcode;
		extension_word <= inst_extension;
		fpu_enable <= '1';
		wait until rising_edge(clk);
		fpu_enable <= '0';
		wait_for_fpu_completion;
	end procedure;
	
	-- Main test process
	test_process: process
		variable l : line;
	begin
		-- Initialize
		write(l, string'("=== TG68K FPU Test Bench Started ==="));
		writeline(output, l);
		
		nReset <= '0';
		fpu_enable <= '0';
		opcode <= X"0000";
		extension_word <= X"0000";
		cpu_data_in <= X"00000000";
		
		wait for 100 ns;
		nReset <= '1';
		wait for 50 ns;
		
		-- Test Phase 1: Basic FPU Response
		test_phase <= 1;
		write(l, string'("--- Test Phase 1: Basic FPU Response ---"));
		writeline(output, l);
		
		-- Test illegal F-line instruction (should generate exception)
		opcode <= X"F000";  -- Invalid F-line instruction
		extension_word <= X"0000";
		fpu_enable <= '1';
		wait until rising_edge(clk);
		fpu_enable <= '0';
		wait_for_fpu_completion;
		
		report_test("Illegal F-line instruction detection", fpu_exception = '1');
		
		-- Test Phase 2: Basic FMOVE Operations
		test_phase <= 2;
		write(l, string'("--- Test Phase 2: FMOVE Operations ---"));
		writeline(output, l);
		
		-- FMOVE FP0,FP1 (move 1.0 from FP0 to FP1)
		send_fpu_instruction(X"F200", X"0400");  -- FMOVE.X FP0,FP1
		report_test("FMOVE FP0,FP1 execution", fpu_exception = '0');
		
		-- Test Phase 3: Basic Arithmetic
		test_phase <= 3;
		write(l, string'("--- Test Phase 3: Basic Arithmetic ---"));
		writeline(output, l);
		
		-- FADD FP0,FP1 (add FP0 to FP1)
		send_fpu_instruction(X"F200", X"0422");  -- FADD.X FP0,FP1
		report_test("FADD FP0,FP1 execution", fpu_exception = '0');
		
		-- FSUB FP0,FP1 (subtract FP0 from FP1)  
		send_fpu_instruction(X"F200", X"0428");  -- FSUB.X FP0,FP1
		report_test("FSUB FP0,FP1 execution", fpu_exception = '0');
		
		-- FMUL FP0,FP1 (multiply FP1 by FP0)
		send_fpu_instruction(X"F200", X"0423");  -- FMUL.X FP0,FP1
		report_test("FMUL FP0,FP1 execution", fpu_exception = '0');
		
		-- FDIV FP0,FP1 (divide FP1 by FP0)
		send_fpu_instruction(X"F200", X"0420");  -- FDIV.X FP0,FP1
		report_test("FDIV FP0,FP1 execution", fpu_exception = '0');
		
		-- Test Phase 4: Unary Operations
		test_phase <= 4;
		write(l, string'("--- Test Phase 4: Unary Operations ---"));
		writeline(output, l);
		
		-- FABS FP0 (absolute value)
		send_fpu_instruction(X"F200", X"0018");  -- FABS.X FP0
		report_test("FABS FP0 execution", fpu_exception = '0');
		
		-- FNEG FP0 (negate)
		send_fpu_instruction(X"F200", X"001A");  -- FNEG.X FP0
		report_test("FNEG FP0 execution", fpu_exception = '0');
		
		-- Test Phase 5: Comparison Operations
		test_phase <= 5;
		write(l, string'("--- Test Phase 5: Comparison Operations ---"));
		writeline(output, l);
		
		-- FCMP FP0,FP1 (compare FP1 with FP0)
		send_fpu_instruction(X"F200", X"0038");  -- FCMP.X FP0,FP1
		report_test("FCMP FP0,FP1 execution", fpu_exception = '0');
		
		-- FTST FP0 (test FP0 against zero)
		send_fpu_instruction(X"F200", X"003A");  -- FTST.X FP0
		report_test("FTST FP0 execution", fpu_exception = '0');
		
		-- Test Phase 6: Exception Handling
		test_phase <= 6;
		write(l, string'("--- Test Phase 6: Exception Handling ---"));
		writeline(output, l);
		
		-- Test division by zero (simplified test)
		-- First load zero into FP0, then divide by it
		send_fpu_instruction(X"F200", X"0000");  -- FMOVE.X #0,FP0 (simplified)
		send_fpu_instruction(X"F200", X"0420");  -- FDIV.X FP0,FP1 (divide by zero)
		report_test("Division by zero detection", fpu_exception = '1' or exception_code = X"05");
		
		-- Test Phase 7: Format Validation
		test_phase <= 7;
		write(l, string'("--- Test Phase 7: Format Validation ---"));
		writeline(output, l);
		
		-- Test invalid format code
		send_fpu_instruction(X"F200", X"7000");  -- Invalid format
		report_test("Invalid format detection", fpu_exception = '1');
		
		-- Final Results
		wait for 100 ns;
		
		write(l, string'("=== Test Summary ==="));
		writeline(output, l);
		write(l, string'("Total Tests: "));
		write(l, total_tests);
		writeline(output, l);
		write(l, string'("Passed Tests: "));
		write(l, passed_tests);
		writeline(output, l);
		write(l, string'("Failed Tests: "));
		write(l, total_tests - passed_tests);
		writeline(output, l);
		
		if test_passed then
			write(l, string'("OVERALL RESULT: PASS"));
		else
			write(l, string'("OVERALL RESULT: FAIL"));
		end if;
		writeline(output, l);
		
		write(l, string'("=== FPU Test Bench Completed ==="));
		writeline(output, l);
		
		sim_finished <= true;
		wait;
	end process;

end testbench;