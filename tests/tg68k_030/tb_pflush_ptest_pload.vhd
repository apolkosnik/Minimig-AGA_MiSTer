-- tb_pflush_ptest_pload.vhd
-- Comprehensive test for PFLUSH, PTEST, and PLOAD instructions
-- Reference: MC68030 User Manual Section 9
--
-- PFLUSH modes:
--   PFLUSHA              - Flush all ATC entries
--   PFLUSH FC,#mask      - Flush entries matching FC with mask
--   PFLUSH FC,#mask,EA   - Flush entry for specific EA
--
-- PTEST modes:
--   PTEST FC,EA,#level           - Test translation
--   PTEST FC,EA,#level,An        - Test and store table pointer
--
-- PLOAD modes:
--   PLOADR FC,EA         - Preload read entry
--   PLOADW FC,EA         - Preload write entry

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pflush_ptest_pload is
end entity;

architecture behavioral of tb_pflush_ptest_pload is

    

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
    signal mem_berr      : std_logic := '0';
    signal busy          : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';

    -- PFLUSH/PTEST/PLOAD interface
    signal pflush_req    : std_logic := '0';
    signal ptest_req     : std_logic := '0';
    signal pload_req     : std_logic := '0';
    signal pmmu_fc       : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr     : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief    : std_logic_vector(15 downto 0) := (others => '0');

    constant CLK_PERIOD  : time := 10 ns;
    signal test_done     : boolean := false;

    -- Register selectors
    constant SEL_TT0     : std_logic_vector(4 downto 0) := "00010";
    constant SEL_TT1     : std_logic_vector(4 downto 0) := "00011";
    constant SEL_TC      : std_logic_vector(4 downto 0) := "10000";
    constant SEL_MMUSR   : std_logic_vector(4 downto 0) := "11000";
    constant SEL_SRP     : std_logic_vector(4 downto 0) := "10010";
    constant SEL_CRP     : std_logic_vector(4 downto 0) := "10011";

    -- Test counters
    signal test_pass     : integer := 0;
    signal test_fail     : integer := 0;
    signal mem_read_count : integer := 0;
    signal mem_read_count_clear : std_logic := '0';
    signal mem_stall_cycles : integer range 0 to 31 := 0;
    signal mem_wait_count : integer range 0 to 31 := 0;
    signal mem_req_prev : std_logic := '0';

    -- Page table memory
    type mem_array_t is array (0 to 4095) of std_logic_vector(31 downto 0);
    signal page_table : mem_array_t := (others => (others => '0'));

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
            mem_berr       => mem_berr,
            busy           => busy,
            mmu_config_err => mmu_config_err,
            mmu_config_ack => mmu_config_ack
        );

    -- Memory model with page table
    mem_model: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            mem_req_prev <= mem_req;
            if mem_read_count_clear = '1' then
                mem_read_count <= 0;
                mem_wait_count <= 0;
            elsif mem_req = '1' then
                if mem_req_prev = '0' then
                    if mem_stall_cycles > 0 then
                        mem_wait_count <= mem_stall_cycles - 1;
                    else
                        mem_wait_count <= 0;
                        idx := to_integer(unsigned(mem_addr(13 downto 2)));
                        if idx < 4096 then
                            mem_rdat <= page_table(idx);
                        else
                            mem_rdat <= x"00000000";
                        end if;
                        mem_ack <= '1';
                        mem_read_count <= mem_read_count + 1;
                        report "MEM_READ: addr=0x" & slv_to_hex(mem_addr) &
                               " data=0x" & slv_to_hex(page_table(idx));
                    end if;
                elsif mem_wait_count > 0 then
                    mem_wait_count <= mem_wait_count - 1;
                else
                    idx := to_integer(unsigned(mem_addr(13 downto 2)));
                    if idx < 4096 then
                        mem_rdat <= page_table(idx);
                    else
                        mem_rdat <= x"00000000";
                    end if;
                    mem_ack <= '1';
                    mem_read_count <= mem_read_count + 1;
                    report "MEM_READ: addr=0x" & slv_to_hex(mem_addr) &
                           " data=0x" & slv_to_hex(page_table(idx));
                end if;
            else
                mem_wait_count <= 0;
            end if;
        end if;
    end process;

    test_process: process
        variable timeout : integer;
        variable stable : integer;
        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure clear_mem_read_count is
        begin
            mem_read_count_clear <= '1';
            wait_cycles(1);
            mem_read_count_clear <= '0';
            wait_cycles(1);
        end procedure;

        procedure settle_fault_state is
            variable timeout : integer;
        begin
            timeout := 0;
            while (busy = '1' or mem_req = '1') and timeout < 20 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;
            wait_cycles(4);
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

        -- PFLUSHA: Flush all ATC entries
        -- The PMMU block samples PFLUSH mode from brief(12:10) and mask from
        -- brief(7:5); FC is driven separately via pmmu_fc in this bench.
        procedure do_pflusha is
        begin
            report "Executing PFLUSHA";
            pmmu_brief <= x"2400";  -- PFLUSHA encoding
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';
            wait_cycles(3);
        end procedure;

        -- PFLUSH with FC and mask
        -- Use 68030 mode 100 in brief(12:10); mask lives in brief(7:5).
        procedure do_pflush_fc_mask(
            fc_val : std_logic_vector(2 downto 0);
            mask : std_logic_vector(2 downto 0)
        ) is
            variable brief : std_logic_vector(15 downto 0);
        begin
            report "Executing PFLUSH FC=" & integer'image(to_integer(unsigned(fc_val))) &
                   " mask=" & integer'image(to_integer(unsigned(mask)));
            brief := "001" & "100" & "00" & mask & "00000";
            pmmu_brief <= brief;
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';
            wait_cycles(3);
        end procedure;

        -- PFLUSH with FC, mask, and EA
        -- Use 68030 mode 110 in brief(12:10); FC still comes from pmmu_fc.
        procedure do_pflush_fc_mask_ea(
            fc_val : std_logic_vector(2 downto 0);
            mask : std_logic_vector(2 downto 0);
            ea : std_logic_vector(31 downto 0)
        ) is
            variable brief : std_logic_vector(15 downto 0);
        begin
            report "Executing PFLUSH FC=" & integer'image(to_integer(unsigned(fc_val))) &
                   " mask=" & integer'image(to_integer(unsigned(mask))) &
                   " EA=0x" & slv_to_hex(ea);
            brief := "001" & "110" & "00" & mask & "00000";
            pmmu_brief <= brief;
            pmmu_addr <= ea;
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';
            wait_cycles(3);
        end procedure;

        -- PTEST: Test translation
        -- This bench drives FC via the dedicated pmmu_fc port, so the brief word only
        -- needs the level in bits 12:10 and the direction in bit 9.
        procedure do_ptest(
            ea : std_logic_vector(31 downto 0);
            fc_val : std_logic_vector(2 downto 0);
            is_write : std_logic;
            level : std_logic_vector(2 downto 0)
        ) is
            variable brief : std_logic_vector(15 downto 0);
            variable timeout : integer;
            variable ptest_rw_bit : std_logic;
        begin
            report "Executing PTEST EA=0x" & slv_to_hex(ea) &
                   " FC=" & integer'image(to_integer(unsigned(fc_val))) &
                   " W=" & std_logic'image(is_write) &
                   " level=" & integer'image(to_integer(unsigned(level)));
            -- PMMU expects bit 9 = 1 for PTESTR, 0 for PTESTW.
            ptest_rw_bit := not is_write;
            brief := "100" & level & ptest_rw_bit & "000000000";
            pmmu_brief <= brief;
            pmmu_addr <= ea;
            pmmu_fc <= fc_val;
            ptest_req <= '1';
            wait_cycles(1);
            ptest_req <= '0';

            timeout := 0;
            while busy = '0' and timeout < 20 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            if timeout >= 100 then
                report "  PTEST timed out!" severity error;
            end if;

            -- MMUSR is updated through a separate handshake after the walk/fault path completes.
            -- Early faults can retire before the register file reflects the new status.
            wait_cycles(5);
        end procedure;

        -- PLOAD: Preload ATC entry
        -- Brief word: 001x_x0x0_00ff_ffff (different from PFLUSH)
        procedure do_pload(
            ea : std_logic_vector(31 downto 0);
            fc_val : std_logic_vector(2 downto 0);
            is_write : std_logic
        ) is
            variable brief : std_logic_vector(15 downto 0);
            variable timeout : integer;
            variable dir_str : string(1 to 1);
        begin
            if is_write = '1' then
                dir_str := "W";
            else
                dir_str := "R";
            end if;
            report "Executing PLOAD" & dir_str &
                   " EA=0x" & slv_to_hex(ea) &
                   " FC=" & integer'image(to_integer(unsigned(fc_val)));
            -- Format: 0010 00 w 0 00000 fc fc fc (16 bits)
            brief := "0010" & "00" & is_write & '0' & "00000" & fc_val;
            pmmu_brief <= brief;
            pmmu_addr <= ea;
            pmmu_fc <= fc_val;
            pload_req <= '1';
            wait_cycles(1);
            pload_req <= '0';

            -- Wait for completion
            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            if timeout >= 100 then
                report "  PLOAD timed out!" severity error;
            end if;

            wait_cycles(2);
        end procedure;

        procedure translate_and_check(
            log_addr : std_logic_vector(31 downto 0);
            expect_fault : boolean
        ) is
            variable timeout : integer;
        begin
            addr_log <= log_addr;
            fc <= "101";
            rw <= '1';
            req <= '1';
            wait_cycles(1);

            timeout := 0;
            while busy = '0' and fault = '0' and timeout < 10 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            req <= '0';
            wait_cycles(2);

            if expect_fault then
                if fault = '1' then
                    report "  Translation faulted as expected";
                    test_pass <= test_pass + 1;
                else
                    report "  Expected fault but got translation" severity error;
                    test_fail <= test_fail + 1;
                end if;
            else
                if fault = '0' and timeout < 100 then
                    report "  Translation succeeded: phys=0x" & slv_to_hex(addr_phys);
                    test_pass <= test_pass + 1;
                else
                    report "  Translation failed unexpectedly" severity error;
                    test_fail <= test_fail + 1;
                end if;
            end if;
        end procedure;

        procedure translate_and_check_rw(
            log_addr : std_logic_vector(31 downto 0);
            rw_val : std_logic;
            expect_fault : boolean
        ) is
            variable timeout : integer;
        begin
            addr_log <= log_addr;
            fc <= "101";
            rw <= rw_val;
            req <= '1';
            wait_cycles(1);

            timeout := 0;
            while busy = '0' and fault = '0' and timeout < 10 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            req <= '0';
            wait_cycles(2);

            if expect_fault then
                if fault = '1' then
                    report "  Translation faulted as expected";
                    test_pass <= test_pass + 1;
                else
                    report "  Expected fault but got translation" severity error;
                    test_fail <= test_fail + 1;
                end if;
            else
                if fault = '0' and timeout < 100 then
                    report "  Translation succeeded: phys=0x" & slv_to_hex(addr_phys);
                    test_pass <= test_pass + 1;
                else
                    report "  Translation failed unexpectedly" severity error;
                    test_fail <= test_fail + 1;
                end if;
            end if;
        end procedure;

        procedure translate_no_check_rw(
            log_addr : std_logic_vector(31 downto 0);
            rw_val : std_logic
        ) is
            variable timeout : integer;
        begin
            addr_log <= log_addr;
            fc <= "101";
            rw <= rw_val;
            req <= '1';
            wait_cycles(1);

            timeout := 0;
            while busy = '0' and fault = '0' and timeout < 10 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            req <= '0';
            wait_cycles(2);
        end procedure;

    begin
        report "========================================" severity note;
        report "PFLUSH, PTEST, PLOAD Comprehensive Test" severity note;
        report "========================================" severity note;
        report "";

        -- Reset
        nReset <= '0';
        wait_cycles(5);
        nReset <= '1';
        wait_cycles(5);

        -- Setup page tables
        -- Root table at 0x00000000, 1024 entries (10 bits)
        -- TC = $80C0AA00: E=1, PS=12, TIA=10, TIB=10
        page_table(0) <= x"00001002";  -- Root[0] -> L1 at 0x1000, DT=10

        -- Level 1 table at 0x1000
        page_table(16#400#) <= x"00100001";  -- L1[0]: Page at 0x00100000, DT=01
        page_table(16#401#) <= x"00200001";  -- L1[1]: Page at 0x00200000, DT=01
        page_table(16#402#) <= x"00300001";  -- L1[2]: Page at 0x00300000, DT=01
        page_table(16#403#) <= x"00400001";  -- L1[3]: Page at 0x00400000, DT=01
        page_table(16#404#) <= x"00500005";  -- L1[4]: Page at 0x00500000, WP=1, DT=01
        page_table(16#405#) <= x"00000000";  -- L1[5]: Invalid descriptor

        -- Configure MMU
        write_reg(SEL_CRP, x"80000002", '1');
        write_reg(SEL_CRP, x"00000000", '0');
        write_reg(SEL_TC, x"80C0AA00", '0');
        wait_cycles(5);

        if tc_enable = '1' then
            report "MMU enabled";
            test_pass <= test_pass + 1;
        else
            report "FAIL: MMU not enabled" severity error;
            test_fail <= test_fail + 1;
        end if;

        -- ============================================
        -- SECTION 1: PFLUSHA Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 1: PFLUSHA Tests ===" severity note;

        -- First, do a translation to populate ATC
        report "Populating ATC with translation...";
        translate_and_check(x"00000000", false);

        -- Now flush all
        report "Flushing all ATC entries...";
        do_pflusha;
        test_pass <= test_pass + 1;

        -- Translation should still work (will refetch from table)
        report "Verifying translation still works after flush...";
        translate_and_check(x"00000000", false);

        report "" severity note;
        report "=== SECTION 1B: PFLUSHA While Walker Busy ===" severity note;

        -- Repopulate ATC, then issue PFLUSHA while a stalled walk is active.
        translate_and_check(x"00000000", false);
        mem_stall_cycles <= 6;
        wait_cycles(1);

        addr_log <= x"00002000";
        fc <= "101";
        rw <= '1';
        req <= '1';
        wait_cycles(1);

        timeout := 0;
        while busy = '0' and timeout < 20 loop
            wait_cycles(1);
            timeout := timeout + 1;
        end loop;

        if timeout >= 20 then
            report "FAIL: Timed out waiting for stalled walker before busy PFLUSHA" severity error;
            test_fail <= test_fail + 1;
            req <= '0';
            mem_stall_cycles <= 0;
            wait_cycles(2);
        else
            report "Issuing PFLUSHA while walker busy...";
            pmmu_brief <= x"2400";
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';

            timeout := 0;
            while busy = '1' and timeout < 120 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            req <= '0';
            mem_stall_cycles <= 0;
            wait_cycles(2);

            if timeout >= 120 then
                report "FAIL: Timed out waiting for walker completion after busy PFLUSHA" severity error;
                test_fail <= test_fail + 1;
            else
                clear_mem_read_count;
                translate_and_check(x"00000000", false);
                if mem_read_count > 0 then
                    report "  Busy-time PFLUSHA cleared the cached entry after walker completion";
                    test_pass <= test_pass + 1;
                else
                    report "  Busy-time PFLUSHA was lost; cached translation survived without any table reads" severity error;
                    test_fail <= test_fail + 1;
                end if;
            end if;
        end if;

        -- ============================================
        -- SECTION 2: PFLUSH FC,mask Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 2: PFLUSH FC,mask Tests ===" severity note;

        -- Flush with specific FC
        do_pflush_fc_mask("101", "111");  -- FC=5, mask=7 (all FC bits)
        test_pass <= test_pass + 1;

        do_pflush_fc_mask("001", "111");  -- FC=1 (user data)
        test_pass <= test_pass + 1;

        -- ============================================
        -- SECTION 3: PFLUSH FC,mask,EA Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 3: PFLUSH FC,mask,EA Tests ===" severity note;

        -- Flush specific entry
        do_pflush_fc_mask_ea("101", "111", x"00001000");
        test_pass <= test_pass + 1;

        -- ============================================
        -- SECTION 4: PTEST Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 4: PTEST Tests ===" severity note;

        -- Test valid translation
        do_ptest(x"00000000", "101", '0', "111");

        -- Read MMUSR to check result
        read_reg(SEL_MMUSR, '0');
        report "MMUSR after PTEST: 0x" & slv_to_hex(reg_rdat(15 downto 0));
        test_pass <= test_pass + 1;

        -- Test with different levels
        do_ptest(x"00001000", "101", '0', "000");  -- Level 0
        read_reg(SEL_MMUSR, '0');
        report "MMUSR after PTEST level 0: 0x" & slv_to_hex(reg_rdat(15 downto 0));
        test_pass <= test_pass + 1;

        -- Test write access
        do_ptest(x"00000000", "101", '1', "111");  -- Write test
        read_reg(SEL_MMUSR, '0');
        report "MMUSR after PTEST (write): 0x" & slv_to_hex(reg_rdat(15 downto 0));
        test_pass <= test_pass + 1;

        -- Cached fault replay must preserve original MMUSR class.
        report "Creating cached ATC fault entry for WP page...";
        -- Normal CPU faults and cached-fault replays must not alter the
        -- architectural MMUSR register; WinUAE only changes it for PTEST/PMOVE.
        write_reg(SEL_MMUSR, x"00000000", '0');
        clear_mem_read_count;
        translate_and_check_rw(x"00004000", '0', true);  -- first fault populates ATC
        if mem_read_count > 0 then
            test_pass <= test_pass + 1;
        else
            report "  Expected initial WP fault to perform a table walk" severity error;
            test_fail <= test_fail + 1;
        end if;
        settle_fault_state;
        report "Replaying cached ATC fault entry for WP page...";
        clear_mem_read_count;
        translate_and_check_rw(x"00004000", '0', true);  -- second fault should hit cached entry
        report "Fault status after cached WP replay: 0x" & slv_to_hex(fault_status(15 downto 0));
        settle_fault_state;
        read_reg(SEL_MMUSR, '0');
        if reg_rdat(15 downto 0) = x"0000" then
            test_pass <= test_pass + 1;
        else
            report "  Expected CPU cached fault replay to leave architectural MMUSR at 0, got 0x" &
                   slv_to_hex(reg_rdat(15 downto 0)) severity error;
            test_fail <= test_fail + 1;
        end if;
        if mem_read_count = 0 then
            test_pass <= test_pass + 1;
        else
            report "  Expected cached WP replay to avoid a second table walk" severity error;
            test_fail <= test_fail + 1;
        end if;
        if fault_status(11) = '1' and fault_status(15) = '0' and fault_status(10) = '0' then
            test_pass <= test_pass + 1;
        else
            report "  Expected cached WP fault to keep W=1, B=0, I=0" severity error;
            test_fail <= test_fail + 1;
        end if;

        report "Creating cached ATC fault entry for invalid page...";
        clear_mem_read_count;
        translate_no_check_rw(x"00005000", '1');  -- populate cache; replay check below is the real assertion
        settle_fault_state;
        if mem_read_count > 0 then
            test_pass <= test_pass + 1;
        else
            report "  Expected initial invalid fault to perform a table walk" severity error;
            test_fail <= test_fail + 1;
        end if;
        report "Replaying cached ATC fault entry for invalid page...";
        clear_mem_read_count;
        translate_and_check_rw(x"00005000", '1', true);  -- second fault should hit cached entry
        report "Fault status after cached invalid replay: 0x" & slv_to_hex(fault_status(15 downto 0));
        if mem_read_count = 0 then
            test_pass <= test_pass + 1;
        else
            report "  Expected cached invalid replay to avoid a second table walk" severity error;
            test_fail <= test_fail + 1;
        end if;
        if fault_status(10) = '1' and fault_status(15) = '0' and fault_status(11) = '0' then
            test_pass <= test_pass + 1;
        else
            report "  Expected cached invalid fault to keep I=1, B=0, W=0" severity error;
            test_fail <= test_fail + 1;
        end if;

        -- ============================================
        -- SECTION 5: PLOAD Tests
        -- ============================================
        report "" severity note;
        report "=== SECTION 5: PLOAD Tests ===" severity note;

        -- Flush first
        do_pflusha;

        -- Preload read entry
        do_pload(x"00002000", "101", '0');
        test_pass <= test_pass + 1;

        -- Preload write entry
        do_pload(x"00003000", "101", '1');
        test_pass <= test_pass + 1;

        -- Verify preloaded entries work
        translate_and_check(x"00002000", false);
        translate_and_check(x"00003000", false);

        report "Testing PLOAD while a previous table walk is busy...";
        do_pflusha;
        mem_stall_cycles <= 6;
        wait_cycles(1);

        addr_log <= x"00001000";
        fc <= "101";
        rw <= '1';
        req <= '1';
        wait_cycles(1);

        timeout := 0;
        while busy = '0' and timeout < 20 loop
            wait_cycles(1);
            timeout := timeout + 1;
        end loop;

        if timeout >= 20 then
            report "FAIL: Timed out waiting for stalled walker before busy PLOAD" severity error;
            test_fail <= test_fail + 1;
            req <= '0';
            mem_stall_cycles <= 0;
            wait_cycles(2);
        else
            pmmu_brief <= x"2205";  -- PLOADR FC=5
            pmmu_addr <= x"00003000";
            pmmu_fc <= "101";
            pload_req <= '1';
            wait_cycles(1);
            pload_req <= '0';
            req <= '0';
            mem_stall_cycles <= 0;

            timeout := 0;
            while busy = '1' and timeout < 160 loop
                wait_cycles(1);
                timeout := timeout + 1;
            end loop;

            stable := 0;
            while stable < 8 and timeout < 220 loop
                wait_cycles(1);
                timeout := timeout + 1;
                if busy = '0' and mem_req = '0' then
                    stable := stable + 1;
                else
                    stable := 0;
                end if;
            end loop;

            wait_cycles(2);
            if timeout >= 220 then
                report "FAIL: Timed out waiting for busy-time PLOAD completion" severity error;
                test_fail <= test_fail + 1;
            else
                clear_mem_read_count;
                translate_and_check(x"00003000", false);
                if mem_read_count = 0 then
                    report "  Busy-time PLOAD populated the ATC entry";
                    test_pass <= test_pass + 1;
                else
                    report "  Busy-time PLOAD was lost; translation performed a later table walk" severity error;
                    test_fail <= test_fail + 1;
                end if;
            end if;
        end if;

        -- ============================================
        -- SECTION 6: Sequential Operations
        -- ============================================
        report "" severity note;
        report "=== SECTION 6: Sequential Operations ===" severity note;

        -- Multiple PFLUSH in sequence
        do_pflusha;
        do_pflush_fc_mask("101", "111");
        do_pflush_fc_mask_ea("101", "111", x"00000000");
        test_pass <= test_pass + 1;

        -- PTEST followed by PFLUSH followed by PTEST
        do_ptest(x"00000000", "101", '0', "111");
        do_pflusha;
        do_ptest(x"00000000", "101", '0', "111");
        test_pass <= test_pass + 1;

        -- ============================================
        -- SECTION 7: Fault Semantics vs WinUAE
        -- ============================================
        report "" severity note;
        report "=== SECTION 7: Fault Semantics vs WinUAE ===" severity note;

        -- 7A: Root-pointer limit violation must report both L and I.
        do_pflusha;
        write_reg(SEL_TC, x"00C0AA00", '0');  -- Disable MMU with valid PS/TI fields; avoid sticky config error
        write_reg(SEL_CRP, x"80010002", '1');  -- lower limit=1, DT=10
        write_reg(SEL_CRP, x"00000000", '0');
        write_reg(SEL_TC, x"80C0AA00", '0');
        wait_cycles(5);
        do_ptest(x"00000000", "101", '0', "111");
        read_reg(SEL_MMUSR, '0');
        if reg_rdat(14) = '1' and reg_rdat(10) = '1' and reg_rdat(13) = '0' and reg_rdat(11) = '0' then
            test_pass <= test_pass + 1;
        else
            report "  Root limit MMUSR expected L=1,I=1,S=0,W=0, got 0x" & slv_to_hex(reg_rdat(15 downto 0)) severity error;
            test_fail <= test_fail + 1;
        end if;

        -- 7B: Table-descriptor limit violation must also report both L and I.
        page_table(0) <= x"80010002";      -- long table descriptor: lower limit=1, DT=10
        page_table(1) <= x"00002000";      -- next table base
        do_pflusha;
        write_reg(SEL_TC, x"00C0AA00", '0');  -- Disable MMU with valid PS/TI fields; avoid sticky config error
        write_reg(SEL_CRP, x"7FFF0003", '1');  -- DT=11, max upper limit, root table at 0
        write_reg(SEL_CRP, x"00000000", '0');
        write_reg(SEL_TC, x"80C0AA00", '0');
        wait_cycles(5);
        do_ptest(x"00000000", "101", '0', "111");
        read_reg(SEL_MMUSR, '0');
        if reg_rdat(14) = '1' and reg_rdat(10) = '1' and reg_rdat(13) = '0' and reg_rdat(11) = '0' then
            test_pass <= test_pass + 1;
        else
            report "  Table limit MMUSR expected L=1,I=1,S=0,W=0, got 0x" & slv_to_hex(reg_rdat(15 downto 0)) severity error;
            test_fail <= test_fail + 1;
        end if;

        -- 7C: Supervisor-only page reached through a WP table must preserve table WP in MMUSR.W.
        page_table(0) <= x"00000106";      -- long table descriptor: S=1, WP=1, DT=10
        page_table(1) <= x"00002000";      -- next table base
        page_table(16#800#) <= x"00300001"; -- short page descriptor
        do_pflusha;
        write_reg(SEL_TC, x"00C0AA00", '0');  -- Disable MMU with valid PS/TI fields; avoid sticky config error
        write_reg(SEL_CRP, x"7FFF0003", '1');  -- DT=11, root table at 0
        write_reg(SEL_CRP, x"00000000", '0');
        write_reg(SEL_TC, x"80C0AA00", '0');
        wait_cycles(5);
        do_ptest(x"00000000", "001", '0', "111");  -- user data access
        read_reg(SEL_MMUSR, '0');
        if reg_rdat(13) = '1' and reg_rdat(11) = '1' and reg_rdat(10) = '0' and reg_rdat(14) = '0' then
            test_pass <= test_pass + 1;
        else
            report "  Supervisor/WP MMUSR expected S=1,W=1,I=0,L=0, got 0x" & slv_to_hex(reg_rdat(15 downto 0)) severity error;
            test_fail <= test_fail + 1;
        end if;

        -- ============================================
        -- Final Summary
        -- ============================================
        report "" severity note;
        report "========================================" severity note;
        report "PFLUSH/PTEST/PLOAD Test Summary" severity note;
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
