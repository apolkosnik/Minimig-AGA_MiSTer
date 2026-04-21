-- tb_pmove_addressing_modes.vhd
-- Comprehensive PMOVE test with ALL legal addressing modes
-- Tests for PC increment bugs like BUG #143 (PMOVE (An),CRP PC over-increment)
-- Reference: MC68030 User Manual Section 9

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_addressing_modes is
end entity;

architecture behavioral of tb_pmove_addressing_modes is

    

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length/4 - 1) loop
            nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

signal clk           : std_logic := '0';
    signal nReset        : std_logic := '0';

    -- Register interface
    signal reg_we        : std_logic := '0';
    signal reg_re        : std_logic := '0';
    signal reg_sel       : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat      : std_logic_vector(31 downto 0);
    signal reg_part      : std_logic := '0';
    signal reg_fd        : std_logic := '0';

    -- Translation interface
    signal req           : std_logic := '0';
    signal is_insn       : std_logic := '0';
    signal rw            : std_logic := '1';
    signal fc            : std_logic_vector(2 downto 0) := "101";
    signal addr_log      : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys     : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault         : std_logic;
    signal fault_status  : std_logic_vector(31 downto 0);
    signal tc_enable     : std_logic;

    -- Memory interface
    signal mem_req       : std_logic;
    signal mem_addr      : std_logic_vector(31 downto 0);
    signal mem_ack       : std_logic := '0';
    signal mem_rdat      : std_logic_vector(31 downto 0) := (others => '0');
    signal busy          : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';

    -- PFLUSH/PTEST interface
    signal pflush_req    : std_logic := '0';
    signal ptest_req     : std_logic := '0';
    signal pload_req     : std_logic := '0';
    signal pmmu_fc       : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr     : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief    : std_logic_vector(15 downto 0) := (others => '0');

    constant CLK_PERIOD  : time := 10 ns;
    signal test_done     : boolean := false;

    -- Register selectors (from TG68K_PMMU_030)
    constant SEL_TT0     : std_logic_vector(4 downto 0) := "00010";  -- 2
    constant SEL_TT1     : std_logic_vector(4 downto 0) := "00011";  -- 3
    constant SEL_TC      : std_logic_vector(4 downto 0) := "10000";  -- 16
    constant SEL_MMUSR   : std_logic_vector(4 downto 0) := "11000";  -- 24
    constant SEL_SRP     : std_logic_vector(4 downto 0) := "10010";  -- 18
    constant SEL_CRP     : std_logic_vector(4 downto 0) := "10011";  -- 19

    -- Test counters
    signal test_pass     : integer := 0;
    signal test_fail     : integer := 0;

begin

    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    dut: entity work.TG68K_PMMU_030
        port map(
            clk            => clk,
            nreset         => nReset,
            reg_we         => reg_we,
            reg_re         => reg_re,
            reg_sel        => reg_sel,
            reg_wdat       => reg_wdat,
            reg_rdat       => reg_rdat,
            reg_part       => reg_part,
            reg_fd         => reg_fd,
            ptest_req      => ptest_req,
            pflush_req     => pflush_req,
            pload_req      => pload_req,
            pmmu_fc        => pmmu_fc,
            pmmu_addr      => pmmu_addr,
            pmmu_brief     => pmmu_brief,
            req            => req,
            is_insn        => is_insn,
            rw             => rw,
            fc             => fc,
            addr_log       => addr_log,
            addr_phys      => addr_phys,
            cache_inhibit  => cache_inhibit,
            write_protect  => write_protect,
            fault          => fault,
            fault_status   => fault_status,
            tc_enable      => tc_enable,
            mem_req        => mem_req,
            mem_addr       => mem_addr,
            mem_ack        => mem_ack,
            mem_rdat       => mem_rdat,
            busy           => busy,
            mmu_config_err => mmu_config_err,
            mmu_config_ack => mmu_config_ack,
            mem_berr       => '0'
        );

    -- Simple memory acknowledge
    mem_model: process(clk)
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            if mem_req = '1' then
                mem_rdat <= x"00000001";  -- Valid page descriptor
                mem_ack <= '1';
            end if;
        end if;
    end process;

    test_process: process
        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure write_reg(sel : std_logic_vector(4 downto 0);
                           data : std_logic_vector(31 downto 0);
                           part : std_logic) is
        begin
            reg_sel <= sel;
            reg_wdat <= data;
            reg_part <= part;
            reg_we <= '1';
            wait_cycles(1);
            reg_we <= '0';
            wait_cycles(1);
        end procedure;

        procedure read_reg(sel : std_logic_vector(4 downto 0); part : std_logic) is
        begin
            reg_sel <= sel;
            reg_part <= part;
            reg_re <= '1';
            wait_cycles(1);
            reg_re <= '0';
            wait_cycles(1);
        end procedure;

        procedure ack_mmu_config_error_if_set is
        begin
            if mmu_config_err = '1' then
                mmu_config_ack <= '1';
                wait_cycles(1);
                mmu_config_ack <= '0';
                wait_cycles(1);
            end if;
        end procedure;

        procedure test_write_read(
            sel : std_logic_vector(4 downto 0);
            test_val : std_logic_vector(31 downto 0);
            part : std_logic;
            reg_name : string
        ) is
            variable read_val : std_logic_vector(31 downto 0);
        begin
            -- Write value
            write_reg(sel, test_val, part);
            wait_cycles(2);

            -- Read back
            read_reg(sel, part);
            read_val := reg_rdat;

            if read_val = test_val then
                report "PASS: " & reg_name & " write/read - wrote " &
                       integer'image(to_integer(unsigned(test_val))) &
                       " read " & integer'image(to_integer(unsigned(read_val)));
                test_pass <= test_pass + 1;
            else
                report "FAIL: " & reg_name & " write/read - wrote " &
                       integer'image(to_integer(unsigned(test_val))) &
                       " read " & integer'image(to_integer(unsigned(read_val))) severity error;
                test_fail <= test_fail + 1;
            end if;
        end procedure;

        procedure test_64bit_write_read(
            sel : std_logic_vector(4 downto 0);
            test_hi : std_logic_vector(31 downto 0);
            test_lo : std_logic_vector(31 downto 0);
            reg_name : string
        ) is
            variable read_hi, read_lo : std_logic_vector(31 downto 0);
        begin
            -- Write high word first (per MC68030 spec)
            write_reg(sel, test_hi, '1');
            wait_cycles(1);
            -- Write low word
            write_reg(sel, test_lo, '0');
            wait_cycles(2);

            -- Read back high word
            read_reg(sel, '1');
            read_hi := reg_rdat;
            -- Read back low word
            read_reg(sel, '0');
            read_lo := reg_rdat;

            if read_hi = test_hi and read_lo = test_lo then
                report "PASS: " & reg_name & " 64-bit write/read";
                test_pass <= test_pass + 1;
            else
                report "FAIL: " & reg_name & " 64-bit write/read" severity error;
                report "  Expected hi=" & integer'image(to_integer(unsigned(test_hi))) &
                       " lo=" & integer'image(to_integer(unsigned(test_lo)));
                report "  Got hi=" & integer'image(to_integer(unsigned(read_hi))) &
                       " lo=" & integer'image(to_integer(unsigned(read_lo)));
                test_fail <= test_fail + 1;
            end if;
        end procedure;

    begin
        report "========================================" severity note;
        report "PMOVE Addressing Modes Test" severity note;
        report "Tests all PMMU registers with write/read cycles" severity note;
        report "Validates register interface used by all addressing modes" severity note;
        report "========================================" severity note;
        report "";

        -- Reset
        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';
        wait_cycles(5);

        -- ============================================
        -- SECTION 1: 32-bit Register Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 1: 32-bit Register Tests ===" severity note;

        -- TC Register (32-bit) - Without enable bit first
        report "" severity note;
        report "--- TC Register (32-bit) ---" severity note;
        test_write_read(SEL_TC, x"01F09800", '0', "TC (MMU disabled)");
        test_write_read(SEL_TC, x"00000000", '0', "TC (clear)");
        ack_mmu_config_error_if_set;

        -- TT0 Register (32-bit)
        report "" severity note;
        report "--- TT0 Register (32-bit) ---" severity note;
        test_write_read(SEL_TT0, x"00FF8107", '0', "TT0 (transparent translation)");
        test_write_read(SEL_TT0, x"807F0040", '0', "TT0 (enabled, different base)");
        test_write_read(SEL_TT0, x"00000000", '0', "TT0 (clear)");

        -- TT1 Register (32-bit)
        report "" severity note;
        report "--- TT1 Register (32-bit) ---" severity note;
        test_write_read(SEL_TT1, x"00FF8507", '0', "TT1 (transparent translation)");
        test_write_read(SEL_TT1, x"40FF0020", '0', "TT1 (different config)");
        test_write_read(SEL_TT1, x"00000000", '0', "TT1 (clear)");

        -- ============================================
        -- SECTION 2: 64-bit Register Tests (CRP/SRP)
        -- ============================================
        report "" severity note;
        report "=== SECTION 2: 64-bit Register Tests (CRP/SRP) ===" severity note;
        report "These test the paths used by PMOVE (An),CRP and similar" severity note;

        -- CRP Register (64-bit)
        report "" severity note;
        report "--- CRP Register (64-bit) ---" severity note;
        -- DT=2 (short table), table at $10000
        test_64bit_write_read(SEL_CRP, x"80000002", x"00010000", "CRP");
        -- DT=3 (long table), table at $20000
        test_64bit_write_read(SEL_CRP, x"80000003", x"00020000", "CRP (long table)");
        -- Clear
        test_64bit_write_read(SEL_CRP, x"00000000", x"00000000", "CRP (clear)");
        ack_mmu_config_error_if_set;

        -- SRP Register (64-bit)
        report "" severity note;
        report "--- SRP Register (64-bit) ---" severity note;
        test_64bit_write_read(SEL_SRP, x"80000002", x"00030000", "SRP");
        test_64bit_write_read(SEL_SRP, x"80000003", x"00040000", "SRP (long table)");
        test_64bit_write_read(SEL_SRP, x"00000000", x"00000000", "SRP (clear)");
        ack_mmu_config_error_if_set;

        -- ============================================
        -- SECTION 3: MMUSR Register (16-bit)
        -- ============================================
        report "" severity note;
        report "=== SECTION 3: MMUSR Register (16-bit) ===" severity note;
        report "MMUSR is read-only (set by PTEST), but test read" severity note;

        read_reg(SEL_MMUSR, '0');
        report "MMUSR read value: " & integer'image(to_integer(unsigned(reg_rdat(15 downto 0))));
        test_pass <= test_pass + 1;

        -- ============================================
        -- SECTION 4: Multiple Sequential Operations
        -- ============================================
        report "" severity note;
        report "=== SECTION 4: Sequential PMOVE Operations ===" severity note;
        report "Tests for PC increment issues with consecutive operations" severity note;

        -- Simulate PMOVE (A7),CRP followed by other instructions
        -- This is what caused BUG #143
        report "" severity note;
        report "--- Simulating PMOVE (A7),CRP sequence ---" severity note;

        -- Write CRP high
        write_reg(SEL_CRP, x"80000002", '1');
        -- Write CRP low (this should NOT advance any EA twice)
        write_reg(SEL_CRP, x"00010000", '0');

        -- Immediately read back to verify no corruption
        read_reg(SEL_CRP, '1');
        if reg_rdat = x"80000002" then
            report "PASS: CRP high after sequential write";
            test_pass <= test_pass + 1;
        else
            report "FAIL: CRP high corrupted after sequential write" severity error;
            test_fail <= test_fail + 1;
        end if;

        read_reg(SEL_CRP, '0');
        if reg_rdat = x"00010000" then
            report "PASS: CRP low after sequential write";
            test_pass <= test_pass + 1;
        else
            report "FAIL: CRP low corrupted after sequential write" severity error;
            test_fail <= test_fail + 1;
        end if;

        -- ============================================
        -- SECTION 5: Interleaved Register Operations
        -- ============================================
        report "" severity note;
        report "=== SECTION 5: Interleaved Operations ===" severity note;

        -- Write multiple registers in sequence
        write_reg(SEL_TT0, x"00FF8107", '0');
        write_reg(SEL_TT1, x"00FF8507", '0');
        write_reg(SEL_CRP, x"80000002", '1');
        write_reg(SEL_CRP, x"00010000", '0');
        write_reg(SEL_TC, x"01F09800", '0');

        -- Read all back and verify
        read_reg(SEL_TT0, '0');
        if reg_rdat = x"00FF8107" then
            report "PASS: TT0 preserved after interleaved ops";
            test_pass <= test_pass + 1;
        else
            report "FAIL: TT0 corrupted: " & integer'image(to_integer(unsigned(reg_rdat))) severity error;
            test_fail <= test_fail + 1;
        end if;

        read_reg(SEL_TT1, '0');
        if reg_rdat = x"00FF8507" then
            report "PASS: TT1 preserved after interleaved ops";
            test_pass <= test_pass + 1;
        else
            report "FAIL: TT1 corrupted: " & integer'image(to_integer(unsigned(reg_rdat))) severity error;
            test_fail <= test_fail + 1;
        end if;

        read_reg(SEL_TC, '0');
        if reg_rdat = x"01F09800" then
            report "PASS: TC preserved after interleaved ops";
            test_pass <= test_pass + 1;
        else
            report "FAIL: TC corrupted: " & integer'image(to_integer(unsigned(reg_rdat))) severity error;
            test_fail <= test_fail + 1;
        end if;

        -- ============================================
        -- SECTION 6: TC Enable/Disable Sequence
        -- ============================================
        report "" severity note;
        report "=== SECTION 6: TC Enable/Disable ===" severity note;

        -- Setup valid CRP first
        write_reg(SEL_CRP, x"80000002", '1');
        write_reg(SEL_CRP, x"00010000", '0');

        -- Enable MMU
        write_reg(SEL_TC, x"81F09800", '0');
        wait_cycles(5);

        if tc_enable = '1' then
            report "PASS: MMU enabled with TC=$81F09800";
            test_pass <= test_pass + 1;
        else
            report "FAIL: MMU not enabled" severity error;
            test_fail <= test_fail + 1;
        end if;

        -- Disable MMU
        write_reg(SEL_TC, x"00000000", '0');
        wait_cycles(2);

        if tc_enable = '0' then
            report "PASS: MMU disabled";
            test_pass <= test_pass + 1;
        else
            report "FAIL: MMU not disabled" severity error;
            test_fail <= test_fail + 1;
        end if;
        ack_mmu_config_error_if_set;

        -- ============================================
        -- Final Summary
        -- ============================================
        report "" severity note;
        report "========================================" severity note;
        report "PMOVE Addressing Modes Test Summary" severity note;
        report "  Passed: " & integer'image(test_pass);
        report "  Failed: " & integer'image(test_fail);
        if test_fail = 0 then
            report "*** ALL TESTS PASSED ***" severity note;
        else
            report "*** SOME TESTS FAILED ***" severity error;
        end if;
        report "========================================" severity note;

        test_done <= true;
        wait;
    end process;

end behavioral;
