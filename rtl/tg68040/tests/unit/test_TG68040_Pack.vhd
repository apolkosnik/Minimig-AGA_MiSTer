------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_Pack                                                 --
--                                                                          --
-- Tests the TG68040 package functions and constants                       --
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
use work.TG68040_Pack.all;
use work.test_pkg.all;

entity test_TG68040_Pack is
end test_TG68040_Pack;

architecture sim of test_TG68040_Pack is

	signal test_done : boolean := false;

begin

	-- Test process
	test_proc: process
		variable addr : std_logic_vector(31 downto 0);
		variable idx : integer;
		variable tag : std_logic_vector(19 downto 0);
		variable offset : integer;
		variable page_num : std_logic_vector(19 downto 0);
		variable page_off : std_logic_vector(11 downto 0);
	begin
		report "=== Starting TG68040_Pack tests ===";

		------------------------------------------------------------------------------
		-- Test 1: CPU mode constants
		------------------------------------------------------------------------------
		report "--- Test 1: CPU Mode Constants ---";
		assert_equal(CPU_68000, "00", "CPU_68000 constant");
		assert_equal(CPU_68010, "01", "CPU_68010 constant");
		assert_equal(CPU_68020, "11", "CPU_68020 constant");
		assert_equal(CPU_68040, "10", "CPU_68040 constant");

		------------------------------------------------------------------------------
		-- Test 2: is_68040_mode function
		------------------------------------------------------------------------------
		report "--- Test 2: is_68040_mode Function ---";
		assert_true(is_68040_mode(CPU_68040), "is_68040_mode with 68040");
		assert_true(not is_68040_mode(CPU_68000), "is_68040_mode with 68000");
		assert_true(not is_68040_mode(CPU_68010), "is_68040_mode with 68010");
		assert_true(not is_68040_mode(CPU_68020), "is_68040_mode with 68020");

		------------------------------------------------------------------------------
		-- Test 3: Cache functions
		------------------------------------------------------------------------------
		report "--- Test 3: Cache Address Functions ---";

		-- Test address: 0x12345678
		-- Binary: 0001 0010 0011 0100 0101 0110 0111 1000
		-- Tag:    [31:12] = 0x12345
		-- Index:  [11:4]  = 0x67 = 103 decimal
		-- Offset: [3:0]   = 0x8  = 8 decimal
		addr := x"12345678";

		idx := cache_index(addr);
		assert_equal(idx, 103, "cache_index(0x12345678)");

		tag := cache_tag(addr);
		assert_equal(tag, x"12345", "cache_tag(0x12345678)");

		offset := cache_offset(addr);
		assert_equal(offset, 8, "cache_offset(0x12345678)");

		-- Test aligned address: 0x00001000
		addr := x"00001000";
		idx := cache_index(addr);
		assert_equal(idx, 0, "cache_index(0x00001000) - first line");

		offset := cache_offset(addr);
		assert_equal(offset, 0, "cache_offset(0x00001000) - aligned");

		-- Test last cache line: address with index = 255
		addr := x"00000FF0";
		idx := cache_index(addr);
		assert_equal(idx, 255, "cache_index(0x00000FF0) - last line");

		------------------------------------------------------------------------------
		-- Test 4: MMU page functions
		------------------------------------------------------------------------------
		report "--- Test 4: MMU Page Functions ---";

		-- Test address: 0xABCDE123
		-- Page number: [31:12] = 0xABCDE
		-- Page offset: [11:0]  = 0x123
		addr := x"ABCDE123";

		page_num := page_number(addr);
		assert_equal(page_num, x"ABCDE", "page_number(0xABCDE123)");

		page_off := page_offset(addr);
		assert_equal(page_off, x"123", "page_offset(0xABCDE123)");

		-- Test page boundary: 0x12345000
		addr := x"12345000";
		page_num := page_number(addr);
		assert_equal(page_num, x"12345", "page_number(0x12345000) - boundary");

		page_off := page_offset(addr);
		assert_equal(page_off, x"000", "page_offset(0x12345000) - zero offset");

		------------------------------------------------------------------------------
		-- Test 5: MOVEC register addresses
		------------------------------------------------------------------------------
		report "--- Test 5: MOVEC Register Addresses ---";
		assert_equal(MOVEC_SFC,  x"000", "MOVEC_SFC");
		assert_equal(MOVEC_DFC,  x"001", "MOVEC_DFC");
		assert_equal(MOVEC_CACR, x"002", "MOVEC_CACR");
		assert_equal(MOVEC_TC,   x"003", "MOVEC_TC");
		assert_equal(MOVEC_ITT0, x"004", "MOVEC_ITT0");
		assert_equal(MOVEC_ITT1, x"005", "MOVEC_ITT1");
		assert_equal(MOVEC_DTT0, x"006", "MOVEC_DTT0");
		assert_equal(MOVEC_DTT1, x"007", "MOVEC_DTT1");
		assert_equal(MOVEC_USP,  x"800", "MOVEC_USP");
		assert_equal(MOVEC_VBR,  x"801", "MOVEC_VBR");
		assert_equal(MOVEC_MMUSR,x"805", "MOVEC_MMUSR");
		assert_equal(MOVEC_URP,  x"806", "MOVEC_URP");
		assert_equal(MOVEC_SRP,  x"807", "MOVEC_SRP");

		------------------------------------------------------------------------------
		-- Test 6: Cache organization constants
		------------------------------------------------------------------------------
		report "--- Test 6: Cache Organization Constants ---";
		assert_equal(CACHE_SIZE, 4096, "CACHE_SIZE");
		assert_equal(CACHE_LINE_SIZE, 16, "CACHE_LINE_SIZE");
		assert_equal(CACHE_NUM_LINES, 256, "CACHE_NUM_LINES");
		assert_equal(CACHE_INDEX_BITS, 8, "CACHE_INDEX_BITS");
		assert_equal(CACHE_OFFSET_BITS, 4, "CACHE_OFFSET_BITS");
		assert_equal(CACHE_TAG_BITS, 20, "CACHE_TAG_BITS");

		------------------------------------------------------------------------------
		-- Test 7: MMU constants
		------------------------------------------------------------------------------
		report "--- Test 7: MMU Constants ---";
		assert_equal(PAGE_SIZE_4KB, 4096, "PAGE_SIZE_4KB");
		assert_equal(PAGE_OFFSET_BITS_4KB, 12, "PAGE_OFFSET_BITS_4KB");
		assert_equal(TLB_NUM_ENTRIES, 16, "TLB_NUM_ENTRIES");

		------------------------------------------------------------------------------
		-- Test 8: FPU constants
		------------------------------------------------------------------------------
		report "--- Test 8: FPU Constants ---";
		assert_equal(FPU_NUM_REGS, 8, "FPU_NUM_REGS");
		assert_equal(FPU_REG_WIDTH, 80, "FPU_REG_WIDTH");

		------------------------------------------------------------------------------
		-- All tests complete
		------------------------------------------------------------------------------
		report "=== All TG68040_Pack tests completed successfully ===";
		test_done <= true;
		wait;

	end process;

end sim;
