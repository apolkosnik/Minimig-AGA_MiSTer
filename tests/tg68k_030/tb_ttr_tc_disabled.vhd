-- tb_ttr_tc_disabled.vhd
-- Verifies MC68030 transparent translation behavior when TC.E=0.
--
-- Per the MC68030 User's Manual, TT0/TT1 operate independently of the E bit
-- in the TC register. This is the exact behavior relied on by 68030.library
-- when it installs TT0/TT1=$00FF8707, then clears TC before low-level memory
-- probing and reset handoff.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ttr_tc_disabled is
end entity;

architecture behavior of tb_ttr_tc_disabled is
    function slv_to_hex(v : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to v'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (v'length / 4) - 1 loop
            nibble := v(v'length - 1 - i * 4 downto v'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    signal clk           : std_logic := '0';
    signal nreset        : std_logic := '0';

    signal reg_we        : std_logic := '0';
    signal reg_re        : std_logic := '0';
    signal reg_sel       : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat      : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat      : std_logic_vector(31 downto 0);
    signal reg_part      : std_logic := '0';
    signal reg_fd        : std_logic := '0';

    signal ptest_req     : std_logic := '0';
    signal pflush_req    : std_logic := '0';
    signal pload_req     : std_logic := '0';
    signal pmmu_fc       : std_logic_vector(2 downto 0) := (others => '0');
    signal pmmu_addr     : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief    : std_logic_vector(15 downto 0) := (others => '0');

    signal req           : std_logic := '0';
    signal is_insn       : std_logic := '0';
    signal rw            : std_logic := '1';
    signal rmw           : std_logic := '0';
    signal fc            : std_logic_vector(2 downto 0) := (others => '0');
    signal addr_log      : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys     : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault         : std_logic;
    signal fault_status  : std_logic_vector(31 downto 0);
    signal fault_addr    : std_logic_vector(31 downto 0);
    signal fault_fc      : std_logic_vector(2 downto 0);
    signal fault_rw      : std_logic;
    signal fault_is_insn : std_logic;
    signal tc_enable     : std_logic;

    signal mem_req       : std_logic;
    signal mem_we        : std_logic;
    signal mem_addr      : std_logic_vector(31 downto 0);
    signal mem_wdat      : std_logic_vector(31 downto 0);
    signal mem_ack       : std_logic := '0';
    signal mem_berr      : std_logic := '0';
    signal mem_rdat      : std_logic_vector(31 downto 0) := (others => '0');
    signal busy          : std_logic;

    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';
    signal ptest_desc_addr : std_logic_vector(31 downto 0);
    signal debug_mmusr   : std_logic_vector(15 downto 0);

    signal debug_tc         : std_logic_vector(31 downto 0);
    signal debug_tt0        : std_logic_vector(31 downto 0);
    signal debug_tt1        : std_logic_vector(31 downto 0);
    signal debug_crp_hi     : std_logic_vector(31 downto 0);
    signal debug_crp_lo     : std_logic_vector(31 downto 0);
    signal debug_srp_hi     : std_logic_vector(31 downto 0);
    signal debug_srp_lo     : std_logic_vector(31 downto 0);
    signal debug_wstate     : std_logic_vector(4 downto 0);
    signal debug_atc_buserr : std_logic_vector(21 downto 0);
    signal debug_atc_valid  : std_logic_vector(21 downto 0);
    signal debug_fault_status : std_logic_vector(15 downto 0);
    signal debug_saved_addr   : std_logic_vector(31 downto 0);
    signal debug_walk_desc_addr : std_logic_vector(31 downto 0);
    signal debug_walk_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr1_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr1_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr2_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr2_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr3_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr3_desc_data : std_logic_vector(31 downto 0);
    signal debug_saved_fc       : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    constant REG_TT0          : std_logic_vector(4 downto 0) := "00010";
    constant REG_TT1          : std_logic_vector(4 downto 0) := "00011";
    constant REG_TC           : std_logic_vector(4 downto 0) := "10000";
    constant TTR_ALL_ANY      : std_logic_vector(31 downto 0) := x"00FF8307";
    constant TTR_ALL_CI       : std_logic_vector(31 downto 0) := x"00FF8707";
    constant TTR_ALL_READ_CI  : std_logic_vector(31 downto 0) := x"00FF8607";
    constant TTR_LOW16M_DATA  : std_logic_vector(31 downto 0) := x"00008514";
    constant TEST_ADDR        : std_logic_vector(31 downto 0) := x"01000000";
    constant CHIP_BF_ADDR     : std_logic_vector(31 downto 0) := x"00BFD000";
    constant CHIP_DC_ADDR     : std_logic_vector(31 downto 0) := x"00DC0000";
    constant CHIP_DF_ADDR     : std_logic_vector(31 downto 0) := x"00DF0000";
    constant CHIP_DA_ADDR     : std_logic_vector(31 downto 0) := x"00DA0000";
    constant CHIP_DE_ADDR     : std_logic_vector(31 downto 0) := x"00DE1000";
    constant CHIP_E8_ADDR     : std_logic_vector(31 downto 0) := x"00E80000";
    constant CHIP_F8_ADDR     : std_logic_vector(31 downto 0) := x"00F80000";

    procedure wait_cycles(count : positive) is
    begin
        for i in 1 to count loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

    procedure write_reg(
        signal sel_sig  : out std_logic_vector(4 downto 0);
        signal data_sig : out std_logic_vector(31 downto 0);
        signal part_sig : out std_logic;
        signal we_sig   : out std_logic;
        constant sel : in std_logic_vector(4 downto 0);
        constant val : in std_logic_vector(31 downto 0)
    ) is
    begin
        sel_sig  <= sel;
        data_sig <= val;
        part_sig <= '0';
        we_sig   <= '1';
        wait until rising_edge(clk);
        we_sig   <= '0';
        wait until rising_edge(clk);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut: entity work.TG68K_PMMU_030
        port map(
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
            rmw => rmw,
            fc => fc,
            addr_log => addr_log,
            addr_phys => addr_phys,
            cache_inhibit => cache_inhibit,
            write_protect => write_protect,
            fault => fault,
            fault_status => fault_status,
            fault_addr => fault_addr,
            fault_fc => fault_fc,
            fault_rw => fault_rw,
            fault_is_insn => fault_is_insn,
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
            debug_mmusr => debug_mmusr,
            debug_tc => debug_tc,
            debug_tt0 => debug_tt0,
            debug_tt1 => debug_tt1,
            debug_crp_hi => debug_crp_hi,
            debug_crp_lo => debug_crp_lo,
            debug_srp_hi => debug_srp_hi,
            debug_srp_lo => debug_srp_lo,
            debug_wstate => debug_wstate,
            debug_atc_buserr => debug_atc_buserr,
            debug_atc_valid => debug_atc_valid,
            debug_fault_status => debug_fault_status,
            debug_saved_addr => debug_saved_addr,
            debug_walk_desc_addr => debug_walk_desc_addr,
            debug_walk_desc_data => debug_walk_desc_data,
            debug_ptr1_desc_addr => debug_ptr1_desc_addr,
            debug_ptr1_desc_data => debug_ptr1_desc_data,
            debug_ptr2_desc_addr => debug_ptr2_desc_addr,
            debug_ptr2_desc_data => debug_ptr2_desc_data,
            debug_ptr3_desc_addr => debug_ptr3_desc_addr,
            debug_ptr3_desc_data => debug_ptr3_desc_data,
            debug_saved_fc => debug_saved_fc
        );

  test: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
        procedure check_access(
            constant name_v      : in string;
            constant addr_v      : in std_logic_vector(31 downto 0);
            constant fc_v        : in std_logic_vector(2 downto 0);
            constant is_insn_v   : in std_logic;
            constant expect_ci_v : in std_logic
        ) is
        begin
            addr_log <= addr_v;
            fc <= fc_v;
            rw <= '1';
            rmw <= '0';
            is_insn <= is_insn_v;
            req <= '1';
            wait for 1 ns;

            if addr_phys = addr_v and cache_inhibit = expect_ci_v and fault = '0' then
                report "PASS: " & name_v severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name_v
                       & " addr_phys=$" & slv_to_hex(addr_phys)
                       & " ci=" & std_logic'image(cache_inhibit)
                       & " fault=" & std_logic'image(fault) severity error;
                fail_count := fail_count + 1;
            end if;

            req <= '0';
            wait until rising_edge(clk);
        end procedure;
    begin
        nreset <= '0';
        wait_cycles(4);
        nreset <= '1';
        wait_cycles(4);

        -- Baseline: TC=0 with no TTR should behave as plain identity, cacheable.
        addr_log <= TEST_ADDR;
        fc <= "101";
        rw <= '1';
        rmw <= '0';
        is_insn <= '0';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '0' and fault = '0' and tc_enable = '0' then
            report "PASS: TC=0 baseline access stays identity and cacheable" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: TC=0 baseline access mismatch" severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';

        -- 68030.library uses TT0/TT1=$00FF8707 before clearing TC.
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT0, TTR_ALL_CI);
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TC, x"00000000");
        wait_cycles(2);

        if debug_tt0 = TTR_ALL_CI and tc_enable = '0' then
            report "PASS: TT0 programmed while TC remains disabled" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: TT0/TC programming mismatch" severity error;
            fail_count := fail_count + 1;
        end if;

        -- Data access must still match TTR and come out cache-inhibited.
        addr_log <= TEST_ADDR;
        fc <= "101";
        rw <= '1';
        rmw <= '0';
        is_insn <= '0';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '1' and write_protect = '0' and fault = '0' then
            report "PASS: TTR match remains active for data access with TC=0" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: TTR data access lost when TC=0"
                   & " addr_phys=$" & slv_to_hex(addr_phys)
                   & " ci=" & std_logic'image(cache_inhibit)
                   & " wp=" & std_logic'image(write_protect)
                   & " fault=" & std_logic'image(fault) severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';

        -- Instruction fetch must also remain transparent and cache-inhibited.
        addr_log <= TEST_ADDR;
        fc <= "110";
        rw <= '1';
        rmw <= '0';
        is_insn <= '1';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '1' and fault = '0' then
            report "PASS: TTR match remains active for instruction fetch with TC=0" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: TTR instruction fetch lost when TC=0"
                   & " addr_phys=$" & slv_to_hex(addr_phys)
                   & " ci=" & std_logic'image(cache_inhibit)
                   & " fault=" & std_logic'image(fault) severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';

        -- PTEST must report transparent translation even when TC=0.
        pmmu_addr <= TEST_ADDR;
        pmmu_fc <= "101";
        pmmu_brief <= x"0200"; -- PTESTR, level 0
        ptest_req <= '1';
        wait until rising_edge(clk);
        ptest_req <= '0';
        wait_cycles(6);
        if debug_mmusr(6) = '1' and debug_mmusr(7 downto 0) = x"40" then
            report "PASS: PTEST reports TTR hit while TC=0" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: PTEST lost transparent MMUSR.T with TC=0" severity error;
            fail_count := fail_count + 1;
        end if;

        -- When both TTRs match, CI must be ORed across both registers.
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT0, TTR_ALL_ANY);
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT1, TTR_ALL_CI);
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TC, x"00000000");
        wait_cycles(2);

        addr_log <= TEST_ADDR;
        fc <= "101";
        rw <= '1';
        rmw <= '0';
        is_insn <= '0';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '1' and write_protect = '0' and fault = '0' then
            report "PASS: dual TT0/TT1 match ORs cache inhibit" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: dual TT0/TT1 match did not OR cache inhibit"
                   & " addr_phys=$" & slv_to_hex(addr_phys)
                   & " ci=" & std_logic'image(cache_inhibit)
                   & " wp=" & std_logic'image(write_protect)
                   & " fault=" & std_logic'image(fault) severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';

        pmmu_addr <= TEST_ADDR;
        pmmu_fc <= "101";
        pmmu_brief <= x"0200"; -- PTESTR, level 0
        ptest_req <= '1';
        wait until rising_edge(clk);
        ptest_req <= '0';
        wait_cycles(6);
        if debug_mmusr(11) = '0' and debug_mmusr(6) = '1' and debug_mmusr(7 downto 0) = x"40" then
            report "PASS: dual TT0/TT1 match keeps transparent MMUSR state coherent" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: dual TT0/TT1 PTEST MMUSR mismatch"
                   & " mmusr=$" & slv_to_hex(debug_mmusr) severity error;
            fail_count := fail_count + 1;
        end if;

        -- RMW cycles are transparent only when the TTR RWM bit is set.  With
        -- RWM=0 this read-only TTR should match a plain read, but not a TAS/CAS
        -- read-modify-write sequence.
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT0, TTR_ALL_READ_CI);
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT1, x"00000000");
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TC, x"00000000");
        wait_cycles(2);

        addr_log <= TEST_ADDR;
        fc <= "101";
        rw <= '1';
        rmw <= '0';
        is_insn <= '0';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '1' and fault = '0' then
            report "PASS: RWM=0 read-only TTR matches plain read" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RWM=0 read-only TTR missed plain read"
                   & " addr_phys=$" & slv_to_hex(addr_phys)
                   & " ci=" & std_logic'image(cache_inhibit)
                   & " fault=" & std_logic'image(fault) severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';
        wait until rising_edge(clk);

        addr_log <= TEST_ADDR;
        fc <= "101";
        rw <= '1';
        rmw <= '1';
        is_insn <= '0';
        req <= '1';
        wait for 1 ns;
        if addr_phys = TEST_ADDR and cache_inhibit = '0' and fault = '0' then
            report "PASS: RMW bypasses RWM=0 TTR" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: RMW incorrectly matched RWM=0 TTR"
                   & " addr_phys=$" & slv_to_hex(addr_phys)
                   & " ci=" & std_logic'image(cache_inhibit)
                   & " fault=" & std_logic'image(fault) severity error;
            fail_count := fail_count + 1;
        end if;
        req <= '0';
        rmw <= '0';
        wait until rising_edge(clk);

        -- Restore the single-TTR setup expected by the remaining low-16MB checks.
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT1, x"00000000");

        -- 68030.library also programs TT0=$00008514 for low-16MB data accesses.
        -- This should cover the classic Amiga low-memory I/O space ($00xxxxxx)
        -- for both user-data (FC=1) and supervisor-data (FC=5), but not program
        -- fetches (FC=2/6) and not addresses outside the low 16MB.
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TT0, TTR_LOW16M_DATA);
        write_reg(reg_sel, reg_wdat, reg_part, reg_we, REG_TC, x"00000000");
        wait_cycles(2);

        if debug_tt0 = TTR_LOW16M_DATA and tc_enable = '0' then
            report "PASS: low-16MB TT0 value loaded with TC still disabled" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: low-16MB TT0 value did not load as expected" severity error;
            fail_count := fail_count + 1;
        end if;

        check_access("TT0=$00008514 matches BFxxxx user-data", CHIP_BF_ADDR, "001", '0', '1');
        check_access("TT0=$00008514 matches DCxxxx supervisor-data", CHIP_DC_ADDR, "101", '0', '1');
        check_access("TT0=$00008514 matches DFxxxx user-data", CHIP_DF_ADDR, "001", '0', '1');
        check_access("TT0=$00008514 matches DAxxxx supervisor-data", CHIP_DA_ADDR, "101", '0', '1');
        check_access("TT0=$00008514 matches DExxxx user-data", CHIP_DE_ADDR, "001", '0', '1');
        check_access("TT0=$00008514 matches E8xxxx supervisor-data", CHIP_E8_ADDR, "101", '0', '1');
        check_access("TT0=$00008514 matches F8xxxx supervisor-data", CHIP_F8_ADDR, "101", '0', '1');
        check_access("TT0=$00008514 does not match low-16MB supervisor program fetch", CHIP_DC_ADDR, "110", '1', '0');
        check_access("TT0=$00008514 does not match addresses above low 16MB", TEST_ADDR, "101", '0', '0');

        pmmu_addr <= CHIP_DF_ADDR;
        pmmu_fc <= "101";
        pmmu_brief <= x"0200"; -- PTESTR, level 0
        ptest_req <= '1';
        wait until rising_edge(clk);
        ptest_req <= '0';
        wait_cycles(6);
        if debug_mmusr(6) = '1' and debug_mmusr(7 downto 0) = x"40" then
            report "PASS: PTEST reports transparent hit for low-16MB TT0 data range" severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL: PTEST missed transparent hit for low-16MB TT0 data range" severity error;
            fail_count := fail_count + 1;
        end if;

        if fail_count = 0 then
            report "RESULT: " & integer'image(pass_count) & " passed, 0 failed" severity note;
        else
            assert false report "RESULT: " & integer'image(pass_count) & " passed, " &
                                 integer'image(fail_count) & " failed" severity failure;
        end if;
        wait;
    end process;
end architecture;
