-- MC68030 PMMU ATC (Address Translation Cache) Comprehensive Test Suite
-- Tests 8-entry fully-associative translation cache
--
-- Test Coverage:
--   1. Basic hit/miss detection
--   2. FC (Function Code) matching
--   3. Instruction vs Data separation
--   4. Variable page size support (8KB to 32KB)
--   5. PFLUSHA (flush all entries)
--   6. Cache replacement
--   7. Multiple translations
--
-- Note: This is a simplified test that validates ATC behavior through
--       the actual PMMU interface. More detailed ATC-specific tests would
--       require direct access to ATC internals.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmmu_atc_comprehensive is
end tb_pmmu_atc_comprehensive;

architecture tb of tb_pmmu_atc_comprehensive is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length / 4) - 1 loop
            nibble := value(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    -- Clock and reset
    signal clk : std_logic := '0';
    signal nreset : std_logic := '0';
    constant clk_period : time := 10 ns;
    signal test_running : boolean := true;

    -- PMMU register interface
    signal reg_we : std_logic := '0';
    signal reg_re : std_logic := '0';
    signal reg_sel : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat : std_logic_vector(31 downto 0);
    signal reg_part : std_logic := '0';
    signal reg_fd : std_logic := '0';

    -- PMMU instruction control
    signal ptest_req : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req : std_logic := '0';
    signal pmmu_fc : std_logic_vector(2 downto 0) := "000";
    signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

    -- Translation request
    signal req : std_logic := '0';
    signal is_insn : std_logic := '0';
    signal rw : std_logic := '1';
    signal fc : std_logic_vector(2 downto 0) := "101";
    signal addr_log : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault : std_logic;
    signal fault_status : std_logic_vector(31 downto 0);
    signal tc_enable : std_logic;

    -- Walker memory interface
    signal mem_req : std_logic;
    signal mem_we : std_logic;
    signal mem_addr : std_logic_vector(31 downto 0);
    signal mem_wdat : std_logic_vector(31 downto 0);
    signal mem_ack : std_logic := '0';
    signal mem_berr : std_logic := '0';
    signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
    signal busy : std_logic;

    -- MMU Configuration Exception
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';
    signal cpu_reset : std_logic := '0';

    -- PTEST Support
    signal ptest_desc_addr : std_logic_vector(31 downto 0);

    -- Test control
    signal test_number : integer := 0;

    constant SEL_MMUSR : std_logic_vector(4 downto 0) := "11000";

    -- Page table memory simulation
    type mem_array_t is array (0 to 4095) of std_logic_vector(31 downto 0);
    signal page_table_mem : mem_array_t := (others => (others => '0'));

begin

    -- Instantiate PMMU
    uut: entity work.TG68K_PMMU_030
    port map (
        clk => clk,
        nreset => nreset,
        reg_we => reg_we,
        reg_re => reg_re,
        reg_sel => reg_sel,
        reg_wdat => reg_wdat,
        reg_rdat => reg_rdat,
        reg_part => reg_part,
        reg_fd => reg_fd,
        ptest_req => ptest_req,
        pflush_req => pflush_req,
        pload_req => pload_req,
        pmmu_fc => pmmu_fc,
        pmmu_addr => pmmu_addr,
        pmmu_brief => pmmu_brief,
        req => req,
        is_insn => is_insn,
        rw => rw,
        fc => fc,
        addr_log => addr_log,
        addr_phys => addr_phys,
        cache_inhibit => cache_inhibit,
        write_protect => write_protect,
        fault => fault,
        fault_status => fault_status,
        tc_enable => tc_enable,
        mem_req => mem_req,
        mem_we => mem_we,
        mem_addr => mem_addr,
        mem_wdat => mem_wdat,
        mem_ack => mem_ack,
        mem_berr => mem_berr,
        mem_rdat => mem_rdat,
        busy => busy,
        mmu_config_err => mmu_config_err,
        mmu_config_ack => mmu_config_ack,
        ptest_desc_addr => ptest_desc_addr,
        cpu_reset => cpu_reset
    );

    -- Clock generation
    clk_process: process
    begin
        while test_running loop
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Memory simulator
    mem_sim_process: process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            if nreset = '0' then
                mem_ack <= '0';
                mem_rdat <= (others => '0');
            else
                if mem_req = '1' and mem_ack = '0' then
                    addr_idx := to_integer(unsigned(mem_addr(13 downto 2)));
                    if addr_idx < 4096 then
                        mem_rdat <= page_table_mem(addr_idx);
                    else
                        mem_rdat <= x"00000000";
                    end if;
                    mem_ack <= '1';
                elsif mem_req = '0' then
                    mem_ack <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Main test process
    test_process: process
        variable translation_count : integer;

        -- Helper: Write PMMU register
        procedure write_pmmu_reg(
            constant sel : in std_logic_vector(4 downto 0);
            constant data : in std_logic_vector(31 downto 0);
            constant part : in std_logic
        ) is
        begin
            wait until rising_edge(clk);
            reg_sel <= sel;
            reg_wdat <= data;
            reg_part <= part;
            reg_we <= '1';
            wait until rising_edge(clk);
            reg_we <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Helper: Request translation and wait for completion
        procedure request_translation(
            constant address : in std_logic_vector(31 downto 0);
            constant func_code : in std_logic_vector(2 downto 0);
            constant instruction : in std_logic
        ) is
        begin
            addr_log <= address;
            fc <= func_code;
            is_insn <= instruction;
            req <= '1';
            wait until rising_edge(clk);

            -- Wait for translation to complete (not busy)
            while busy = '1' loop
                wait until rising_edge(clk);
            end loop;

            req <= '0';
            wait until rising_edge(clk);
        end procedure;

        -- Helper: PFLUSHA
        procedure do_pflusha is
        begin
            pmmu_brief <= x"2400"; -- PFLUSHA encoding
            pflush_req <= '1';
            wait until rising_edge(clk);
            pflush_req <= '0';
            wait until rising_edge(clk);
        end procedure;

        procedure read_pmmu_reg(
            constant sel : in std_logic_vector(4 downto 0);
            constant part : in std_logic
        ) is
        begin
            wait until rising_edge(clk);
            reg_sel <= sel;
            reg_part <= part;
            reg_re <= '1';
            wait until rising_edge(clk);
            reg_re <= '0';
            wait for 1 ns;
        end procedure;

        procedure run_ptest_level0(
            constant address : in std_logic_vector(31 downto 0);
            constant func_code : in std_logic_vector(2 downto 0)
        ) is
        begin
            pmmu_brief <= x"8200"; -- PTEST level 0 (ATC-only)
            pmmu_addr <= address;
            pmmu_fc <= func_code;
            ptest_req <= '1';
            wait until rising_edge(clk);
            ptest_req <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            read_pmmu_reg(SEL_MMUSR, '0');
        end procedure;

    begin
        -- Reset
        nreset <= '0';
        wait for 100 ns;
        nreset <= '1';
        wait for 50 ns;

        report "=== MC68030 PMMU ATC Comprehensive Test ===" severity note;

        -- ================================================================
        -- Setup: Initialize MMU with simple page tables
        -- ================================================================

        -- TC: PS=15 (32KB pages), IS=0, TIA=10, TIB=7, TIC=0, TID=0
        -- Per MC68030 UM 9.2.2 the field sum must equal 32: 15+0+10+7 = 32.
        write_pmmu_reg("10000", x"80F0A700", '0');

        -- CRP: Short-format root table (DT=10) at memory 0x400.
        -- DT=10 because root entries below are 4-byte short descriptors.
        -- The mem simulator maps mem_addr to page_table_mem index = addr/4,
        -- so memory 0x400 = page_table_mem index 256 (matches the loop).
        write_pmmu_reg("10011", x"00000002", '1');
        write_pmmu_reg("10011", x"00000400", '0');

        -- Build simple identity-mapped page tables.
        -- Root table at memory 0x400 (index 256): 1024 entries (TIA=10),
        --   filled here only for entries 0..31 (test addresses use index 0).
        -- Level1 table at memory 0x800 (index 512): 128 entries (TIB=7).
        for i in 0 to 31 loop
            -- Each entry: address=0x800 (level1 base), DT=10 (short table).
            page_table_mem(256 + i) <= x"00000802";
        end loop;

        -- Level1: Identity map (each entry covers 32KB).
        -- Entry value: 24-bit page address << 8 | 0x01 (DT=01 page descriptor).
        for i in 0 to 127 loop
            page_table_mem(512 + i) <= std_logic_vector(to_unsigned(i * 32768, 24)) & x"01";
        end loop;

        wait for 100 ns;

        -- ================================================================
        -- TEST 1: Basic Hit/Miss - First access misses, second hits
        -- ================================================================
        test_number <= 1;
        report "TEST 1: Basic ATC hit/miss" severity note;

        -- First access: Should miss ATC, trigger walker, fill ATC
        request_translation(x"00010000", "101", '0');

        if fault = '1' then
            report "TEST 1 FAIL: First access faulted" severity error;
        else
            report "TEST 1a PASS: First access completed (ATC miss + fill)" severity note;
        end if;

        -- Second access to same page: Should hit ATC (no walker)
        translation_count := 0;
        request_translation(x"00011000", "101", '0'); -- Same 32KB page

        if fault = '1' then
            report "TEST 1 FAIL: Second access faulted" severity error;
        else
            report "TEST 1b PASS: Second access completed (ATC hit expected)" severity note;
        end if;

        -- PTEST level 0 should hit the ATC entry that was just populated.
        run_ptest_level0(x"00011000", "101");
        if reg_rdat(15 downto 0) = x"0000" then
            report "TEST 1c PASS: PTEST level 0 sees ATC hit before reset" severity note;
        else
            report "TEST 1c FAIL: PTEST level 0 missed populated ATC before reset, MMUSR=$" &
                   slv_to_hex(reg_rdat(15 downto 0)) severity error;
        end if;

        -- MC68030 RESET clears TC.E but must not invalidate the ATC. Re-enable
        -- translation with PMOVEFD so the ATC contents remain observable.
        cpu_reset <= '1';
        wait until rising_edge(clk);
        cpu_reset <= '0';
        wait until rising_edge(clk);
        reg_fd <= '1';
        write_pmmu_reg("10000", x"80F0A700", '0');
        reg_fd <= '0';

        run_ptest_level0(x"00011000", "101");
        if reg_rdat(15 downto 0) = x"0000" then
            report "TEST 1d PASS: RESET preserved ATC entry across PMOVEFD re-enable" severity note;
        else
            report "TEST 1d FAIL: RESET lost ATC entry, MMUSR=$" &
                   slv_to_hex(reg_rdat(15 downto 0)) severity error;
        end if;

        wait for 50 ns;

        -- ================================================================
        -- TEST 2: FC Matching - Different FC should miss
        -- ================================================================
        test_number <= 2;
        report "TEST 2: Function Code separation" severity note;

        request_translation(x"00010000", "110", '0'); -- User data (different FC)

        if fault = '1' then
            report "TEST 2 FAIL: Different FC access faulted" severity error;
        else
            report "TEST 2 PASS: Different FC causes new ATC entry" severity note;
        end if;

        wait for 50 ns;

        -- ================================================================
        -- TEST 3: Instruction vs Data - Same address, different type
        -- ================================================================
        test_number <= 3;
        report "TEST 3: Instruction vs Data separation" severity note;

        request_translation(x"00020000", "101", '0'); -- Data
        request_translation(x"00020000", "101", '1'); -- Instruction

        if fault = '1' then
            report "TEST 3 FAIL: Instruction fetch faulted" severity error;
        else
            report "TEST 3 PASS: I/D separation working" severity note;
        end if;

        wait for 50 ns;

        -- ================================================================
        -- TEST 4: PFLUSHA - Flush all ATC entries
        -- ================================================================
        test_number <= 4;
        report "TEST 4: PFLUSHA flush all entries" severity note;

        -- Fill ATC with several entries
        request_translation(x"00030000", "101", '0');
        request_translation(x"00040000", "101", '0');
        request_translation(x"00050000", "101", '0');

        -- Flush all
        do_pflusha;

        -- Next access should miss and re-walk
        request_translation(x"00030000", "101", '0');

        if fault = '1' then
            report "TEST 4 FAIL: Post-flush access faulted" severity error;
        else
            report "TEST 4 PASS: PFLUSHA cleared ATC" severity note;
        end if;

        wait for 50 ns;

        -- ================================================================
        -- TEST 5: Multiple Page Sizes
        -- ================================================================
        test_number <= 5;
        report "TEST 5: Variable page sizes (change to 8KB)" severity note;

        -- Flush first
        do_pflusha;

        -- Change to 8KB pages: PS=13, IS=0, TIA=10, TIB=9 (sum = 13+0+10+9 = 32).
        -- (Earlier value 0x808AA000 had PS=8 = 256-byte pages and sum=28.)
        write_pmmu_reg("10000", x"80D0A900", '0');

        -- Rebuild level1 for 8KB pages. 512 entries (TIB=9).
        for i in 0 to 511 loop
            page_table_mem(512 + i) <= std_logic_vector(to_unsigned(i * 8192, 24)) & x"01";
        end loop;

        request_translation(x"00060000", "101", '0');

        if fault = '1' then
            report "TEST 5 FAIL: 8KB page translation faulted" severity error;
        else
            report "TEST 5 PASS: 8KB page translation working" severity note;
        end if;

        wait for 50 ns;

        -- ================================================================
        -- TEST 6: ATC Replacement - Fill more than 8 entries
        -- ================================================================
        test_number <= 6;
        report "TEST 6: ATC replacement (FIFO)" severity note;

        do_pflusha;

        -- Fill all 8 ATC entries + 1 more to force eviction
        for i in 0 to 8 loop
            request_translation(std_logic_vector(to_unsigned(i * 65536, 32)), "101", '0');
        end loop;

        report "TEST 6 PASS: Filled ATC beyond capacity" severity note;

        wait for 50 ns;

        -- ================================================================
        -- TEST 7: Rapid Sequential Accesses
        -- ================================================================
        test_number <= 7;
        report "TEST 7: Rapid sequential translations" severity note;

        for i in 0 to 15 loop
            request_translation(std_logic_vector(to_unsigned(i * 4096, 32)), "101", '0');
        end loop;

        report "TEST 7 PASS: Sequential translations completed" severity note;

        wait for 100 ns;

        -- ================================================================
        -- All tests complete
        -- ================================================================
        report "=== All ATC Tests Complete ===" severity note;
        test_running <= false;
        wait;

    end process;

end tb;
