------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- TG68040 Test Package - Common Test Utilities                            --
--                                                                          --
-- Copyright (c) 2025 Claude AI (Anthropic)                                --
--                                                                          --
-- LGPL v3                                                                  --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package test_pkg is

	-- Test result tracking
	type test_result_t is (TEST_PASS, TEST_FAIL);

	-- Clock period for 50 MHz
	constant CLK_PERIOD : time := 20 ns;

	-- Procedure: report_test
	-- Report test result with message
	procedure report_test(
		test_name : in string;
		result    : in test_result_t;
		message   : in string := ""
	);

	-- Procedure: assert_equal (std_logic_vector)
	-- Assert that two vectors are equal
	procedure assert_equal(
		actual    : in std_logic_vector;
		expected  : in std_logic_vector;
		test_name : in string
	);

	-- Procedure: assert_equal (integer)
	-- Assert that two integers are equal
	procedure assert_equal(
		actual    : in integer;
		expected  : in integer;
		test_name : in string
	);

	-- Procedure: assert_equal (std_logic)
	-- Assert that two std_logic values are equal
	procedure assert_equal(
		actual    : in std_logic;
		expected  : in std_logic;
		test_name : in string
	);

	-- Procedure: assert_true
	-- Assert that a boolean is true
	procedure assert_true(
		condition : in boolean;
		test_name : in string
	);

	-- Function: to_hstring
	-- Convert std_logic_vector to hex string
	function to_hstring(slv : std_logic_vector) return string;

end package test_pkg;

package body test_pkg is

	------------------------------------------------------------------------------
	-- Procedure: report_test
	------------------------------------------------------------------------------
	procedure report_test(
		test_name : in string;
		result    : in test_result_t;
		message   : in string := ""
	) is
	begin
		if result = TEST_PASS then
			report "PASS: " & test_name severity note;
		else
			if message /= "" then
				report "FAIL: " & test_name & " - " & message severity error;
			else
				report "FAIL: " & test_name severity error;
			end if;
		end if;
	end procedure;

	------------------------------------------------------------------------------
	-- Procedure: assert_equal (std_logic_vector)
	------------------------------------------------------------------------------
	procedure assert_equal(
		actual    : in std_logic_vector;
		expected  : in std_logic_vector;
		test_name : in string
	) is
	begin
		if actual = expected then
			report_test(test_name, TEST_PASS);
		else
			report_test(test_name, TEST_FAIL,
				"Expected " & to_hstring(expected) &
				", got " & to_hstring(actual));
		end if;
	end procedure;

	------------------------------------------------------------------------------
	-- Procedure: assert_equal (integer)
	------------------------------------------------------------------------------
	procedure assert_equal(
		actual    : in integer;
		expected  : in integer;
		test_name : in string
	) is
	begin
		if actual = expected then
			report_test(test_name, TEST_PASS);
		else
			report_test(test_name, TEST_FAIL,
				"Expected " & integer'image(expected) &
				", got " & integer'image(actual));
		end if;
	end procedure;

	------------------------------------------------------------------------------
	-- Procedure: assert_equal (std_logic)
	------------------------------------------------------------------------------
	procedure assert_equal(
		actual    : in std_logic;
		expected  : in std_logic;
		test_name : in string
	) is
	begin
		if actual = expected then
			report_test(test_name, TEST_PASS);
		else
			report_test(test_name, TEST_FAIL,
				"Expected " & std_logic'image(expected) &
				", got " & std_logic'image(actual));
		end if;
	end procedure;

	------------------------------------------------------------------------------
	-- Procedure: assert_true
	------------------------------------------------------------------------------
	procedure assert_true(
		condition : in boolean;
		test_name : in string
	) is
	begin
		if condition then
			report_test(test_name, TEST_PASS);
		else
			report_test(test_name, TEST_FAIL, "Condition is false");
		end if;
	end procedure;

	------------------------------------------------------------------------------
	-- Function: to_hstring
	------------------------------------------------------------------------------
	function to_hstring(slv : std_logic_vector) return string is
		variable l : line;
		variable result : string(1 to slv'length/4 + 2);
	begin
		-- Simple hex conversion (works for multiples of 4 bits)
		-- For production, use ieee.std_logic_textio
		return "0x" & integer'image(to_integer(unsigned(slv)));
	end function;

end package body test_pkg;
