-- tb_ptest_srp_crp_invariance.vhd
--
-- Directed NetBSD demand-paging probe:
--   A supervisor-data translation of the kernel page-table install KVA
--   0x0094A074 must use SRP and must not move when CRP changes.  User-data
--   translations of the same VA are the negative control and should follow CRP.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ptest_srp_crp_invariance is
end tb_ptest_srp_crp_invariance;

architecture sim of tb_ptest_srp_crp_invariance is
    constant CLK_PERIOD : time := 10 ns;

    constant VA_PROBE   : std_logic_vector(31 downto 0) := x"0094A074";
    constant TC_LIVE    : std_logic_vector(31 downto 0) := x"82D08B00";
    constant RP_HIGH    : std_logic_vector(31 downto 0) := x"80000202";
    constant SRP_BASE   : std_logic_vector(31 downto 0) := x"4052C000";
    constant CRP_A_BASE : std_logic_vector(31 downto 0) := x"4FFF6000";
    constant CRP_B_BASE : std_logic_vector(31 downto 0) := x"4FC1C000";

    constant SRP_L2     : std_logic_vector(31 downto 0) := x"40530000";
    constant CRP_A_L2   : std_logic_vector(31 downto 0) := x"4FFF7000";
    constant CRP_B_L2   : std_logic_vector(31 downto 0) := x"4FC1D000";

    constant L2_INDEX_OFF : std_logic_vector(31 downto 0) := x"00001294"; -- VA[23:13]=0x4A5 * 4

    constant SRP_PHYS   : std_logic_vector(31 downto 0) := x"4FC62074";
    constant CRP_A_PHYS : std_logic_vector(31 downto 0) := x"11112074";
    constant CRP_B_PHYS : std_logic_vector(31 downto 0) := x"22222074";

    constant SEL_TT0   : std_logic_vector(4 downto 0) := "00010";
    constant SEL_TT1   : std_logic_vector(4 downto 0) := "00011";
    constant SEL_TC    : std_logic_vector(4 downto 0) := "10000";
    constant SEL_SRP   : std_logic_vector(4 downto 0) := "10010";
    constant SEL_CRP   : std_logic_vector(4 downto 0) := "10011";

    signal clk    : std_logic := '0';
    signal nreset : std_logic := '0';

    signal reg_we   : std_logic := '0';
    signal reg_re   : std_logic := '0';
    signal reg_sel  : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat : std_logic_vector(31 downto 0);
    signal reg_part : std_logic := '0';
    signal reg_fd   : std_logic := '0';

    signal ptest_req  : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req  : std_logic := '0';
    signal pmmu_fc    : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr  : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

    signal req       : std_logic := '0';
    signal is_insn   : std_logic := '0';
    signal rw        : std_logic := '1';
    signal rmw       : std_logic := '0';
    signal fc        : std_logic_vector(2 downto 0) := "101";
    signal addr_log  : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault         : std_logic;
    signal fault_status  : std_logic_vector(31 downto 0);
    signal fault_addr    : std_logic_vector(31 downto 0);
    signal fault_fc      : std_logic_vector(2 downto 0);
    signal fault_rw      : std_logic;
    signal fault_is_insn : std_logic;
    signal tc_enable     : std_logic;

    signal mem_req  : std_logic;
    signal mem_we   : std_logic;
    signal mem_addr : std_logic_vector(31 downto 0);
    signal mem_wdat : std_logic_vector(31 downto 0);
    signal mem_ack  : std_logic := '0';
    signal mem_berr : std_logic := '0';
    signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
    signal busy     : std_logic;

    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';
    signal ptest_desc_addr : std_logic_vector(31 downto 0);

    signal debug_mmusr : std_logic_vector(15 downto 0);
    signal debug_tc    : std_logic_vector(31 downto 0);
    signal debug_tt0   : std_logic_vector(31 downto 0);
    signal debug_tt1   : std_logic_vector(31 downto 0);
    signal debug_crp_hi : std_logic_vector(31 downto 0);
    signal debug_crp_lo : std_logic_vector(31 downto 0);
    signal debug_srp_hi : std_logic_vector(31 downto 0);
    signal debug_srp_lo : std_logic_vector(31 downto 0);
    signal debug_wstate : std_logic_vector(4 downto 0);
    signal debug_atc_buserr : std_logic_vector(21 downto 0);
    signal debug_atc_valid  : std_logic_vector(21 downto 0);
    signal debug_fault_status : std_logic_vector(15 downto 0);
    signal debug_saved_addr : std_logic_vector(31 downto 0);
    signal debug_walk_desc_addr : std_logic_vector(31 downto 0);
    signal debug_walk_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr1_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr1_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr2_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr2_desc_data : std_logic_vector(31 downto 0);
    signal debug_ptr3_desc_addr : std_logic_vector(31 downto 0);
    signal debug_ptr3_desc_data : std_logic_vector(31 downto 0);
    signal debug_saved_fc : std_logic_vector(2 downto 0);
    signal debug_pending_flags : std_logic_vector(15 downto 0);
    signal debug_illegal_reg_sel : std_logic;

    signal read_count : integer := 0;
    signal clear_read_count : std_logic := '0';

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length / 4 - 1) loop
            nibble := value(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    function desc_for_addr(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
        variable a : std_logic_vector(31 downto 0) := addr;
    begin
        if a = SRP_BASE then
            return SRP_L2 or x"0000000A";
        elsif a = std_logic_vector(unsigned(SRP_L2) + unsigned(L2_INDEX_OFF)) then
            return x"4FC62009";
        elsif a = CRP_A_BASE then
            return CRP_A_L2 or x"0000000A";
        elsif a = std_logic_vector(unsigned(CRP_A_L2) + unsigned(L2_INDEX_OFF)) then
            return x"11112009";
        elsif a = CRP_B_BASE then
            return CRP_B_L2 or x"0000000A";
        elsif a = std_logic_vector(unsigned(CRP_B_L2) + unsigned(L2_INDEX_OFF)) then
            return x"22222009";
        else
            return x"00000000";
        end if;
    end function;
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
            debug_saved_fc => debug_saved_fc,
            debug_pending_flags => debug_pending_flags,
            debug_illegal_reg_sel => debug_illegal_reg_sel,
            mmudis => '0',
            cpu_reset => '0'
        );

    mem_model: process(clk)
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            if clear_read_count = '1' then
                read_count <= 0;
            elsif mem_req = '1' and mem_ack = '0' then
                mem_ack <= '1';
                if mem_we = '1' then
                    report "Unexpected descriptor write addr=$" & slv_to_hex(mem_addr) &
                           " data=$" & slv_to_hex(mem_wdat) severity error;
                else
                    mem_rdat <= desc_for_addr(mem_addr);
                    read_count <= read_count + 1;
                end if;
            end if;
        end if;
    end process;

    stim: process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        procedure wait_cycles(constant n : in natural) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure check_equal(
            constant name_v : in string;
            constant got_v  : in std_logic_vector(31 downto 0);
            constant exp_v  : in std_logic_vector(31 downto 0)
        ) is
        begin
            if got_v = exp_v then
                report "PASS: " & name_v & " = $" & slv_to_hex(got_v) severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name_v & " expected $" & slv_to_hex(exp_v) &
                       " got $" & slv_to_hex(got_v) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_equal16(
            constant name_v : in string;
            constant got_v  : in std_logic_vector(15 downto 0);
            constant exp_v  : in std_logic_vector(15 downto 0)
        ) is
        begin
            if got_v = exp_v then
                report "PASS: " & name_v & " = $" & slv_to_hex(got_v) severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name_v & " expected $" & slv_to_hex(exp_v) &
                       " got $" & slv_to_hex(got_v) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure check_no_fault(constant name_v : in string) is
        begin
            if fault = '0' then
                report "PASS: " & name_v & " no fault" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL: " & name_v & " faulted status=$" &
                       slv_to_hex(fault_status) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

        procedure reset_reads is
        begin
            clear_read_count <= '1';
            wait_cycles(1);
            clear_read_count <= '0';
            wait_cycles(1);
        end procedure;

        procedure write_reg(
            constant sel_v  : in std_logic_vector(4 downto 0);
            constant part_v : in std_logic;
            constant val_v  : in std_logic_vector(31 downto 0)
        ) is
        begin
            reg_sel <= sel_v;
            reg_part <= part_v;
            reg_wdat <= val_v;
            reg_we <= '1';
            wait_cycles(1);
            reg_we <= '0';
            wait_cycles(2);
        end procedure;

        procedure install_roots(constant crp_l_v : in std_logic_vector(31 downto 0)) is
        begin
            write_reg(SEL_TT0, '0', x"00000000");
            write_reg(SEL_TT1, '0', x"00000000");
            write_reg(SEL_SRP, '1', RP_HIGH);
            write_reg(SEL_SRP, '0', SRP_BASE);
            write_reg(SEL_CRP, '1', RP_HIGH);
            write_reg(SEL_CRP, '0', crp_l_v);
            write_reg(SEL_TC, '0', TC_LIVE);
            wait_cycles(8);
        end procedure;

        procedure set_crp(constant crp_l_v : in std_logic_vector(31 downto 0)) is
        begin
            write_reg(SEL_CRP, '1', RP_HIGH);
            write_reg(SEL_CRP, '0', crp_l_v);
            wait_cycles(8);
        end procedure;

        procedure do_pflusha is
        begin
            pmmu_brief <= x"2400";
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';
            wait_cycles(8);
        end procedure;

        procedure do_ptest(
            constant name_v  : in string;
            constant fc_v    : in std_logic_vector(2 downto 0);
            constant rw_v    : in std_logic
        ) is
            variable brief_v : std_logic_vector(15 downto 0);
        begin
            reset_reads;
            pmmu_addr <= VA_PROBE;
            pmmu_fc <= fc_v;
            brief_v := "100" & "111" & rw_v & "000000000"; -- PTEST, level 7
            pmmu_brief <= brief_v;
            ptest_req <= '1';
            wait_cycles(1);
            ptest_req <= '0';
            wait_cycles(100);
            report name_v & ": PTEST reads=" & integer'image(read_count) &
                   " MMUSR=$" & slv_to_hex(debug_mmusr) &
                   " ptr1=$" & slv_to_hex(debug_ptr1_desc_addr) &
                   " ptr2=$" & slv_to_hex(debug_ptr2_desc_addr) severity note;
        end procedure;

        procedure do_translate(
            constant name_v  : in string;
            constant fc_v    : in std_logic_vector(2 downto 0);
            constant expect_v : in std_logic_vector(31 downto 0);
            constant expect_walk : in boolean
        ) is
        begin
            reset_reads;
            addr_log <= VA_PROBE;
            fc <= fc_v;
            rw <= '1';
            is_insn <= '0';
            rmw <= '0';
            req <= '1';
            wait_cycles(80);
            req <= '0';
            wait_cycles(3);
            report name_v & ": translate reads=" & integer'image(read_count) &
                   " phys=$" & slv_to_hex(addr_phys) &
                   " fault=" & std_logic'image(fault) severity note;
            check_no_fault(name_v);
            check_equal(name_v & " physical", addr_phys, expect_v);
            if expect_walk and read_count = 0 then
                report "FAIL: " & name_v & " expected a table walk but got ATC/direct" severity error;
                fail_count := fail_count + 1;
            elsif (not expect_walk) and read_count /= 0 then
                report "FAIL: " & name_v & " expected ATC/no-walk but read " &
                       integer'image(read_count) & " descriptors" severity error;
                fail_count := fail_count + 1;
            else
                report "PASS: " & name_v & " walk expectation" severity note;
                pass_count := pass_count + 1;
            end if;
        end procedure;
    begin
        wait_cycles(4);
        nreset <= '1';
        wait_cycles(8);

        install_roots(CRP_A_BASE);
        if tc_enable /= '1' or mmu_config_err /= '0' then
            report "FAIL: PMMU did not enable cleanly tc_enable=" & std_logic'image(tc_enable) &
                   " config_err=" & std_logic'image(mmu_config_err) severity error;
            fail_count := fail_count + 1;
        else
            report "PASS: PMMU enabled with live TC/SRP/CRP_A values" severity note;
            pass_count := pass_count + 1;
        end if;

        do_pflusha;
        do_ptest("supervisor PTEST under CRP_A", "101", '1');
        check_equal("supervisor PTEST root read under CRP_A", debug_ptr1_desc_addr, SRP_BASE);
        check_equal("supervisor PTEST leaf read under CRP_A",
                    debug_ptr2_desc_addr,
                    std_logic_vector(unsigned(SRP_L2) + unsigned(L2_INDEX_OFF)));
        check_equal16("supervisor PTEST under CRP_A MMUSR invalid clear",
                      debug_mmusr and x"0400", x"0000");

        do_translate("supervisor fresh translation under CRP_A", "101", SRP_PHYS, true);
        do_translate("supervisor ATC repeat under CRP_A", "101", SRP_PHYS, false);

        set_crp(CRP_B_BASE);
        do_ptest("supervisor PTEST under CRP_B", "101", '1');
        check_equal("supervisor PTEST root read under CRP_B", debug_ptr1_desc_addr, SRP_BASE);
        check_equal("supervisor PTEST leaf read under CRP_B",
                    debug_ptr2_desc_addr,
                    std_logic_vector(unsigned(SRP_L2) + unsigned(L2_INDEX_OFF)));
        check_equal16("supervisor PTEST under CRP_B MMUSR invalid clear",
                      debug_mmusr and x"0400", x"0000");
        do_translate("supervisor fresh translation under CRP_B", "101", SRP_PHYS, true);
        do_translate("supervisor ATC repeat under CRP_B", "101", SRP_PHYS, false);

        do_pflusha;
        set_crp(CRP_A_BASE);
        do_ptest("user PTEST under CRP_A", "001", '1');
        check_equal("user PTEST root read under CRP_A", debug_ptr1_desc_addr, CRP_A_BASE);
        do_translate("user fresh translation under CRP_A", "001", CRP_A_PHYS, true);

        do_pflusha;
        set_crp(CRP_B_BASE);
        do_ptest("user PTEST under CRP_B", "001", '1');
        check_equal("user PTEST root read under CRP_B", debug_ptr1_desc_addr, CRP_B_BASE);
        do_translate("user fresh translation under CRP_B", "001", CRP_B_PHYS, true);

        if fail_count = 0 then
            report "RESULT: " & integer'image(pass_count) & " passed, 0 failed" severity note;
        else
            assert false report "RESULT: " & integer'image(pass_count) &
                                " passed, " & integer'image(fail_count) & " failed" severity failure;
        end if;
        wait;
    end process;
end architecture;
