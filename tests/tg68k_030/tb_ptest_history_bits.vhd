-- tb_ptest_history_bits.vhd
-- Focused regression for MC68030 leveled PTEST table-search behavior.
-- Verifies that leveled PTEST:
--   * returns the last descriptor address
--   * reports cumulative S/W status like WinUAE
--   * leaves descriptor history bits and the ATC unchanged

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ptest_history_bits is
end tb_ptest_history_bits;

architecture behavior of tb_ptest_history_bits is

    component TG68K_PMMU_030
        port(
            clk             : in  std_logic;
            nreset          : in  std_logic;
            reg_we          : in  std_logic;
            reg_re          : in  std_logic;
            reg_sel         : in  std_logic_vector(4 downto 0);
            reg_wdat        : in  std_logic_vector(31 downto 0);
            reg_rdat        : out std_logic_vector(31 downto 0);
            reg_part        : in  std_logic;
            reg_fd          : in  std_logic;
            ptest_req       : in  std_logic;
            pflush_req      : in  std_logic;
            pload_req       : in  std_logic;
            pmmu_fc         : in  std_logic_vector(2 downto 0);
            pmmu_addr       : in  std_logic_vector(31 downto 0);
            pmmu_brief      : in  std_logic_vector(15 downto 0);
            req             : in  std_logic;
            is_insn         : in  std_logic;
            rw              : in  std_logic;
            fc              : in  std_logic_vector(2 downto 0);
            addr_log        : in  std_logic_vector(31 downto 0);
            addr_phys       : out std_logic_vector(31 downto 0);
            cache_inhibit   : out std_logic;
            write_protect   : out std_logic;
            fault           : out std_logic;
            fault_status    : out std_logic_vector(31 downto 0);
            tc_enable       : out std_logic;
            mem_req         : buffer std_logic;
            mem_we          : out std_logic;
            mem_addr        : out std_logic_vector(31 downto 0);
            mem_wdat        : out std_logic_vector(31 downto 0);
            mem_ack         : in  std_logic;
            mem_berr        : in  std_logic;
            mem_rdat        : in  std_logic_vector(31 downto 0);
            busy            : out std_logic;
            mmu_config_err  : out std_logic;
            mmu_config_ack  : in  std_logic;
            ptest_desc_addr : out std_logic_vector(31 downto 0)
        );
    end component;

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
        alias value_norm : std_logic_vector(value'length - 1 downto 0) is value;
    begin
        for i in 0 to (value'length / 4 - 1) loop
            nibble := value_norm(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    signal clk : std_logic := '0';
    signal nreset : std_logic := '0';
    constant clk_period : time := 10 ns;
    signal test_done : boolean := false;

    signal reg_we : std_logic := '0';
    signal reg_re : std_logic := '0';
    signal reg_sel : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat : std_logic_vector(31 downto 0);
    signal reg_part : std_logic := '0';
    signal reg_fd : std_logic := '0';

    signal ptest_req : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req : std_logic := '0';
    signal pmmu_fc : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

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

    signal mem_req : std_logic;
    signal mem_we : std_logic;
    signal mem_addr : std_logic_vector(31 downto 0);
    signal mem_wdat : std_logic_vector(31 downto 0);
    signal mem_ack : std_logic := '0';
    signal mem_berr : std_logic := '0';
    signal mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
    signal busy : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';
    signal ptest_desc_addr : std_logic_vector(31 downto 0);

    constant SEL_TC    : std_logic_vector(4 downto 0) := "10000";
    constant SEL_MMUSR : std_logic_vector(4 downto 0) := "11000";
    constant SEL_CRP   : std_logic_vector(4 downto 0) := "10011";

    type mem_array_t is array (0 to 4095) of std_logic_vector(31 downto 0);
    shared variable page_table_mem : mem_array_t := (others => (others => '0'));

begin

    uut: TG68K_PMMU_030
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
            ptest_desc_addr => ptest_desc_addr
        );

    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for clk_period / 2;
            clk <= '1';
            wait for clk_period / 2;
        end loop;
        wait;
    end process;

    mem_model: process(clk)
        variable idx : integer;
    begin
        if rising_edge(clk) then
            if nreset = '0' then
                mem_ack <= '0';
                mem_rdat <= (others => '0');
            else
                if mem_req = '1' and mem_ack = '0' then
                    idx := to_integer(unsigned(mem_addr(13 downto 2)));
                    if idx < 4096 then
                        if mem_we = '1' then
                            page_table_mem(idx) := mem_wdat;
                            mem_rdat <= mem_wdat;
                        else
                            mem_rdat <= page_table_mem(idx);
                        end if;
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

    test_process: process
        variable passed : integer := 0;
        variable failed : integer := 0;

        procedure wait_cycles(constant n : in integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure check_equal(
            constant label_txt : in string;
            constant actual : in std_logic_vector;
            constant expected : in std_logic_vector
        ) is
        begin
            if actual /= expected then
                report label_txt & ": expected $" & slv_to_hex(expected) &
                       ", got $" & slv_to_hex(actual) severity error;
                failed := failed + 1;
            else
                passed := passed + 1;
            end if;
        end procedure;

        procedure write_reg(
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

        procedure read_reg(
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

        procedure run_pflusha is
        begin
            pmmu_brief <= x"2400";
            pflush_req <= '1';
            wait until rising_edge(clk);
            pflush_req <= '0';
            wait_cycles(2);
        end procedure;

        procedure run_ptest(
            constant label_txt : in string;
            constant brief_val : in std_logic_vector(15 downto 0);
            constant logical_addr : in std_logic_vector(31 downto 0);
            constant fc_val : in std_logic_vector(2 downto 0);
            constant expect_walk : in boolean
        ) is
            variable timeout : integer;
        begin
            pmmu_brief <= brief_val;
            pmmu_addr <= logical_addr;
            pmmu_fc <= fc_val;
            ptest_req <= '1';
            wait until rising_edge(clk);
            ptest_req <= '0';

            if expect_walk then
                timeout := 0;
                while busy = '0' and timeout < 20 loop
                    wait until rising_edge(clk);
                    timeout := timeout + 1;
                end loop;
                if busy = '0' then
                    report label_txt & ": busy never asserted for table walk" severity error;
                    failed := failed + 1;
                end if;
            else
                wait_cycles(2);
            end if;

            timeout := 0;
            while busy = '1' and timeout < 100 loop
                wait until rising_edge(clk);
                timeout := timeout + 1;
            end loop;
            if busy = '1' then
                report label_txt & ": busy did not deassert" severity error;
                failed := failed + 1;
            end if;

            wait_cycles(2);
        end procedure;

    begin
        nreset <= '0';
        wait for 100 ns;
        nreset <= '1';
        wait_cycles(3);

        report "=== PTEST Leveled Status Regression ===" severity note;

        write_reg(SEL_TC, x"80C0AA00", '0');
        write_reg(SEL_CRP, x"7FFFC002", '1');
        write_reg(SEL_CRP, x"00001000", '0');

        page_table_mem := (others => (others => '0'));
        page_table_mem(16#400#) := x"00002002";  -- Root table entry at $1000, U=0
        page_table_mem(16#800#) := x"00100001";  -- Page descriptor at $2000, U=0, M=0
        wait_cycles(2);

        run_ptest("PTEST level 1", x"8600", x"00000500", "101", true);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 1 MMUSR", reg_rdat(15 downto 0), x"0001");
        check_equal("PTEST level 1 descriptor address", ptest_desc_addr, x"00001000");
        check_equal("PTEST level 1 root unchanged", page_table_mem(16#400#), x"00002002");
        check_equal("PTEST level 1 page unchanged", page_table_mem(16#800#), x"00100001");

        run_ptest("PTEST level 0 after leveled PTEST", x"8200", x"00000500", "101", false);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 0 keeps ATC empty", reg_rdat(15 downto 0), x"0400");

        run_pflusha;
        page_table_mem(16#400#) := x"00002002";
        page_table_mem(16#800#) := x"00100001";
        wait_cycles(2);

        run_ptest("PTEST level 2", x"8A00", x"00000500", "101", true);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 2 MMUSR", reg_rdat(15 downto 0), x"0002");
        check_equal("PTEST level 2 descriptor address", ptest_desc_addr, x"00002000");
        check_equal("PTEST level 2 root unchanged", page_table_mem(16#400#), x"00002002");
        check_equal("PTEST level 2 page unchanged", page_table_mem(16#800#), x"00100001");

        run_ptest("PTEST level 0 after full-walk PTEST", x"8200", x"00000500", "101", false);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 0 after full walk keeps ATC empty", reg_rdat(15 downto 0), x"0400");

        run_pflusha;
        write_reg(SEL_TC, x"80808880", '0');
        write_reg(SEL_CRP, x"7FFF0003", '1');
        write_reg(SEL_CRP, x"00001000", '0');

        page_table_mem := (others => (others => '0'));
        page_table_mem(16#400#) := x"7FFF0007";  -- Root entry high: WP=1, DT=11, U=0
        page_table_mem(16#401#) := x"00002000";  -- Root entry low: table base $2000
        page_table_mem(16#802#) := x"7FFF0102";  -- Level-2 entry high: S=1, DT=10, U=0
        page_table_mem(16#803#) := x"00003000";  -- Level-2 entry low: table base $3000
        page_table_mem(16#C02#) := x"00A50001";  -- Final page descriptor
        wait_cycles(2);

        run_ptest("PTEST level 1 WP accumulation", x"8600", x"00010234", "001", true);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 1 WP MMUSR", reg_rdat(15 downto 0), x"0801");
        check_equal("PTEST level 1 WP descriptor address", ptest_desc_addr, x"00001000");
        check_equal("PTEST level 1 root long unchanged", page_table_mem(16#400#), x"7FFF0007");
        check_equal("PTEST level 1 level-2 unchanged", page_table_mem(16#802#), x"7FFF0102");
        check_equal("PTEST level 1 page unchanged", page_table_mem(16#C02#), x"00A50001");

        run_ptest("PTEST level 0 after WP stop", x"8200", x"00010234", "001", false);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 0 after WP stop keeps ATC empty", reg_rdat(15 downto 0), x"0400");

        run_pflusha;
        page_table_mem(16#400#) := x"7FFF0007";
        page_table_mem(16#401#) := x"00002000";
        page_table_mem(16#802#) := x"7FFF0102";
        page_table_mem(16#803#) := x"00003000";
        page_table_mem(16#C02#) := x"00A50001";
        wait_cycles(2);

        run_ptest("PTEST level 2 S/W accumulation", x"8A00", x"00010234", "001", true);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 2 S/W MMUSR", reg_rdat(15 downto 0), x"2802");
        check_equal("PTEST level 2 S/W descriptor address", ptest_desc_addr, x"00002008");
        check_equal("PTEST level 2 root long unchanged", page_table_mem(16#400#), x"7FFF0007");
        check_equal("PTEST level 2 level-2 unchanged", page_table_mem(16#802#), x"7FFF0102");
        check_equal("PTEST level 2 page unchanged", page_table_mem(16#C02#), x"00A50001");

        run_ptest("PTEST level 0 after S/W stop", x"8200", x"00010234", "001", false);
        read_reg(SEL_MMUSR, '0');
        check_equal("PTEST level 0 after S/W stop keeps ATC empty", reg_rdat(15 downto 0), x"0400");

        report "PTEST leveled status summary: passed=" & integer'image(passed) &
               " failed=" & integer'image(failed) severity note;

        test_done <= true;
        assert failed = 0
            report "PTEST leveled status regression failed" severity failure;
        wait;
    end process;

end behavior;
