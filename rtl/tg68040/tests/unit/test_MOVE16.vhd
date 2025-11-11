------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Unit Test: TG68040_MOVE16                                               --
--                                                                          --
-- Tests the MOVE16 instruction implementation                             --
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

entity test_MOVE16 is
end test_MOVE16;

architecture sim of test_MOVE16 is

    -- Component declaration
    component TG68040_MOVE16 is
        port(
            clk            : in std_logic;
            reset          : in std_logic;
            enable         : in std_logic;
            mode           : in move16_mode_t;
            reg_num        : in std_logic_vector(2 downto 0);
            abs_addr       : in std_logic_vector(31 downto 0);
            reg_data_in    : in std_logic_vector(31 downto 0);
            reg_data_out   : out std_logic_vector(31 downto 0);
            reg_write_en   : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_data_write : out std_logic_vector(31 downto 0);
            mem_data_read  : in std_logic_vector(31 downto 0);
            mem_write      : out std_logic;
            mem_read       : out std_logic;
            mem_ready      : in std_logic;
            done           : out std_logic;
            addr_error     : out std_logic;
            busy           : out std_logic
        );
    end component;

    -- Test signals
    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal enable         : std_logic := '0';
    signal mode           : move16_mode_t := MOVE16_AN_INC_TO_ABS;
    signal reg_num        : std_logic_vector(2 downto 0) := "000";
    signal abs_addr       : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_data_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_data_out   : std_logic_vector(31 downto 0);
    signal reg_write_en   : std_logic;
    signal mem_addr       : std_logic_vector(31 downto 0);
    signal mem_data_write : std_logic_vector(31 downto 0);
    signal mem_data_read  : std_logic_vector(31 downto 0) := (others => '0');
    signal mem_write      : std_logic;
    signal mem_read       : std_logic;
    signal mem_ready      : std_logic := '1';
    signal done           : std_logic;
    signal addr_error     : std_logic;
    signal busy           : std_logic;

    signal test_done : boolean := false;

    constant CLK_PERIOD : time := 20 ns;

    -- Memory model (simple array)
    type memory_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal memory : memory_t := (others => (others => '0'));

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    -- DUT instantiation
    dut: TG68040_MOVE16
        port map(
            clk            => clk,
            reset          => reset,
            enable         => enable,
            mode           => mode,
            reg_num        => reg_num,
            abs_addr       => abs_addr,
            reg_data_in    => reg_data_in,
            reg_data_out   => reg_data_out,
            reg_write_en   => reg_write_en,
            mem_addr       => mem_addr,
            mem_data_write => mem_data_write,
            mem_data_read  => mem_data_read,
            mem_write      => mem_write,
            mem_read       => mem_read,
            mem_ready      => mem_ready,
            done           => done,
            addr_error     => addr_error,
            busy           => busy
        );

    -- Simple memory model
    mem_proc: process(clk)
        variable addr_index : integer;
    begin
        if rising_edge(clk) then
            if mem_read = '1' then
                -- Read from memory
                addr_index := to_integer(unsigned(mem_addr(11 downto 2)));
                if addr_index < 1024 then
                    mem_data_read <= memory(addr_index);
                else
                    mem_data_read <= (others => 'X');
                end if;
            elsif mem_write = '1' then
                -- Write to memory
                addr_index := to_integer(unsigned(mem_addr(11 downto 2)));
                if addr_index < 1024 then
                    memory(addr_index) <= mem_data_write;
                end if;
            end if;
        end if;
    end process;

    -- Test process
    test_proc: process
    begin
        report "=== Starting MOVE16 tests ===";

        ----------------------------------------------------------------------
        -- Test 1: Reset behavior
        ----------------------------------------------------------------------
        report "--- Test 1: Reset Behavior ---";
        reset <= '1';
        wait for CLK_PERIOD * 5;
        reset <= '0';
        wait for CLK_PERIOD * 2;

        assert_equal(busy, '0', "Not busy after reset");
        assert_equal(done, '0', "Not done after reset");
        assert_equal(addr_error, '0', "No address error after reset");

        ----------------------------------------------------------------------
        -- Test 2: Aligned transfer (An)+, (xxx).L
        ----------------------------------------------------------------------
        report "--- Test 2: Aligned Transfer (An)+, (xxx).L ---";

        -- Setup source memory (address 0x00000010)
        memory(4) <= x"11111111";  -- bytes 0-3
        memory(5) <= x"22222222";  -- bytes 4-7
        memory(6) <= x"33333333";  -- bytes 8-11
        memory(7) <= x"44444444";  -- bytes 12-15

        -- Setup parameters
        mode <= MOVE16_AN_INC_TO_ABS;
        reg_num <= "000";  -- A0
        reg_data_in <= x"00000010";  -- Source address (aligned)
        abs_addr <= x"00000100";     -- Destination address (aligned)

        -- Start operation
        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        -- Wait for completion
        wait until done = '1' or addr_error = '1' for CLK_PERIOD * 100;

        assert_equal(done, '1', "Transfer completed");
        assert_equal(addr_error, '0', "No address error");

        -- Check destination memory
        assert_equal(memory(64), x"11111111", "Dest bytes 0-3");
        assert_equal(memory(65), x"22222222", "Dest bytes 4-7");
        assert_equal(memory(66), x"33333333", "Dest bytes 8-11");
        assert_equal(memory(67), x"44444444", "Dest bytes 12-15");

        -- Check register postincrement
        wait for CLK_PERIOD;
        if reg_write_en = '1' then
            assert_equal(reg_data_out, x"00000020", "A0 postincremented (+16)");
        end if;

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 3: Aligned transfer (xxx).L, (An)+
        ----------------------------------------------------------------------
        report "--- Test 3: Aligned Transfer (xxx).L, (An)+ ---";

        -- Setup source memory (address 0x00000200)
        memory(128) <= x"AAAAAAAA";
        memory(129) <= x"BBBBBBBB";
        memory(130) <= x"CCCCCCCC";
        memory(131) <= x"DDDDDDDD";

        mode <= MOVE16_ABS_TO_AN_INC;
        reg_num <= "001";  -- A1
        reg_data_in <= x"00000300";  -- Destination address (aligned)
        abs_addr <= x"00000200";     -- Source address (aligned)

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or addr_error = '1' for CLK_PERIOD * 100;

        assert_equal(done, '1', "Transfer completed");
        assert_equal(addr_error, '0', "No address error");

        -- Check destination memory
        assert_equal(memory(192), x"AAAAAAAA", "Dest bytes 0-3");
        assert_equal(memory(193), x"BBBBBBBB", "Dest bytes 4-7");
        assert_equal(memory(194), x"CCCCCCCC", "Dest bytes 8-11");
        assert_equal(memory(195), x"DDDDDDDD", "Dest bytes 12-15");

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 4: Misaligned source address (should error)
        ----------------------------------------------------------------------
        report "--- Test 4: Misaligned Source Address ---";

        mode <= MOVE16_AN_INC_TO_ABS;
        reg_data_in <= x"00000011";  -- NOT 16-byte aligned
        abs_addr <= x"00000400";     -- Aligned

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or addr_error = '1' for CLK_PERIOD * 20;

        assert_equal(addr_error, '1', "Address error for misaligned source");
        assert_equal(done, '0', "Not done due to error");

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 5: Misaligned destination address (should error)
        ----------------------------------------------------------------------
        report "--- Test 5: Misaligned Destination Address ---";

        mode <= MOVE16_AN_INC_TO_ABS;
        reg_data_in <= x"00000020";  -- Aligned
        abs_addr <= x"00000405";     -- NOT 16-byte aligned

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or addr_error = '1' for CLK_PERIOD * 20;

        assert_equal(addr_error, '1', "Address error for misaligned dest");

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 6: Non-postincrement mode (An), (xxx).L
        ----------------------------------------------------------------------
        report "--- Test 6: Non-Postincrement Mode ---";

        memory(256) <= x"12345678";
        memory(257) <= x"9ABCDEF0";
        memory(258) <= x"11223344";
        memory(259) <= x"55667788";

        mode <= MOVE16_AN_TO_ABS;
        reg_data_in <= x"00000400";  -- Source (aligned)
        abs_addr <= x"00000500";     -- Destination (aligned)

        enable <= '1';
        wait for CLK_PERIOD;
        enable <= '0';

        wait until done = '1' or addr_error = '1' for CLK_PERIOD * 100;

        assert_equal(done, '1', "Transfer completed");
        assert_equal(memory(320), x"12345678", "Dest correct");

        -- Check NO register update (non-postincrement)
        wait for CLK_PERIOD * 3;
        assert_equal(reg_write_en, '0', "No register update for non-postinc");

        wait for CLK_PERIOD * 5;

        ----------------------------------------------------------------------
        -- Test 7: Alignment helper functions
        ----------------------------------------------------------------------
        report "--- Test 7: Alignment Helper Functions ---";

        assert_true(is_aligned_16(x"00000000"), "0x00000000 is aligned");
        assert_true(is_aligned_16(x"00000010"), "0x00000010 is aligned");
        assert_true(is_aligned_16(x"00001000"), "0x00001000 is aligned");
        assert_true(not is_aligned_16(x"00000001"), "0x00000001 not aligned");
        assert_true(not is_aligned_16(x"0000001F"), "0x0000001F not aligned");

        assert_equal(align_to_16(x"00000000"), x"00000000", "align 0x00");
        assert_equal(align_to_16(x"0000001F"), x"00000010", "align 0x1F -> 0x10");
        assert_equal(align_to_16(x"00001234"), x"00001230", "align 0x1234 -> 0x1230");

        ----------------------------------------------------------------------
        -- All tests complete
        ----------------------------------------------------------------------
        report "=== All MOVE16 tests completed successfully ===";
        test_done <= true;
        wait;

    end process;

end sim;
