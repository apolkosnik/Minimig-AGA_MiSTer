-- tb_pmmu_walker_comprehensive.vhd
-- Comprehensive testbench for MC68030 PMMU page table walker
-- Tests all walker paths, edge cases, and fault conditions

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmmu_walker_comprehensive is
end tb_pmmu_walker_comprehensive;

architecture behavior of tb_pmmu_walker_comprehensive is

    -- Component Declaration
    component TG68K_PMMU_030
        port(
            clk            : in  std_logic;
            nreset         : in  std_logic;
            reg_we         : in  std_logic;
            reg_re         : in  std_logic;
            reg_sel        : in  std_logic_vector(4 downto 0);
            reg_wdat       : in  std_logic_vector(31 downto 0);
            reg_rdat       : out std_logic_vector(31 downto 0);
            reg_part       : in  std_logic;
            reg_fd         : in  std_logic;
            ptest_req      : in  std_logic;
            pflush_req     : in  std_logic;
            pload_req      : in  std_logic;
            pmmu_fc        : in  std_logic_vector(2 downto 0);
            pmmu_addr      : in  std_logic_vector(31 downto 0);
            pmmu_brief     : in  std_logic_vector(15 downto 0);
            req            : in  std_logic;
            is_insn        : in  std_logic;
            rw             : in  std_logic;
            fc             : in  std_logic_vector(2 downto 0);
            addr_log       : in  std_logic_vector(31 downto 0);
            addr_phys      : out std_logic_vector(31 downto 0);
            cache_inhibit  : out std_logic;
            write_protect  : out std_logic;
            fault          : out std_logic;
            fault_status   : out std_logic_vector(31 downto 0);
            tc_enable      : out std_logic;
            mem_req        : buffer std_logic;
            mem_we         : out std_logic;
            mem_addr       : out std_logic_vector(31 downto 0);
            mem_wdat       : out std_logic_vector(31 downto 0);
            mem_ack        : in  std_logic;
            mem_berr       : in  std_logic;
            mem_rdat       : in  std_logic_vector(31 downto 0);
            busy           : out std_logic;
            mmu_config_err : out std_logic;
            mmu_config_ack : in  std_logic;
            ptest_desc_addr : out std_logic_vector(31 downto 0)
        );
    end component;

    -- Clock and Reset
    signal clk : std_logic := '0';
    signal nreset : std_logic := '0';
    constant clk_period : time := 10 ns;

    -- Register Interface
    signal reg_we : std_logic := '0';
    signal reg_re : std_logic := '0';
    signal reg_sel : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat : std_logic_vector(31 downto 0);
    signal reg_part : std_logic := '0';
    signal reg_fd : std_logic := '0';

    -- PMMU Instructions
    signal ptest_req : std_logic := '0';
    signal pflush_req : std_logic := '0';
    signal pload_req : std_logic := '0';
    signal pmmu_fc : std_logic_vector(2 downto 0) := (others => '0');
    signal pmmu_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief : std_logic_vector(15 downto 0) := (others => '0');

    -- Translation Request
    signal req : std_logic := '0';
    signal is_insn : std_logic := '0';
    signal rw : std_logic := '1';
    signal fc : std_logic_vector(2 downto 0) := "010"; -- User program
    signal addr_log : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys : std_logic_vector(31 downto 0);
    signal cache_inhibit : std_logic;
    signal write_protect : std_logic;
    signal fault : std_logic;
    signal fault_status : std_logic_vector(31 downto 0);
    signal tc_enable : std_logic;

    -- Walker Memory Interface
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

    -- Simulated Page Table Memory (covers up to 0x6000 addresses)
    type mem_array_t is array(0 to 8191) of std_logic_vector(31 downto 0);
    signal page_table_mem : mem_array_t := (others => (others => '0'));

    -- Test Control
    signal test_running : boolean := true;
    signal test_number : integer := 0;

begin

    -- Instantiate PMMU
    uut: TG68K_PMMU_030 port map (
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

    -- Memory simulator (responds to walker requests)
    mem_sim_process: process(clk)
        variable addr_idx : integer;
    begin
        if rising_edge(clk) then
            if nreset = '0' then
                mem_ack <= '0';
                mem_rdat <= (others => '0');
            else
                if mem_req = '1' and mem_ack = '0' then
                    -- Convert address to array index (divide by 4)
                    addr_idx := to_integer(unsigned(mem_addr(14 downto 2)));
                    if addr_idx < 8192 then
                        mem_rdat <= page_table_mem(addr_idx);
                    else
                        mem_rdat <= x"00000000"; -- Out of bounds
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
        variable addr_idx : integer;

        -- Helper procedure: Write PMMU register
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
        
        -- Helper procedure: Read PMMU register and optionally assert expected value
        procedure read_pmmu_reg(
            constant sel : in std_logic_vector(4 downto 0);
            constant part : in std_logic;
            constant expected : in std_logic_vector(31 downto 0);
            constant label_txt : in string
        ) is
        begin
            wait until rising_edge(clk);
            reg_sel <= sel;
            reg_part <= part;
            reg_re <= '1';
            wait until rising_edge(clk);
            reg_re <= '0';
            wait for 1 ns;
            if reg_rdat /= expected then
                report label_txt & " readback mismatch: got=0x" &
                       integer'image(to_integer(unsigned(reg_rdat(31 downto 16)))) & "_" &
                       integer'image(to_integer(unsigned(reg_rdat(15 downto 0)))) &
                       " expected=0x" &
                       integer'image(to_integer(unsigned(expected(31 downto 16)))) & "_" &
                       integer'image(to_integer(unsigned(expected(15 downto 0)))) severity error;
            end if;
        end procedure;

    begin
        -- Reset
        nreset <= '0';
        wait for 100 ns;
        nreset <= '1';
        wait for 50 ns;

        report "=== MC68030 PMMU Walker Comprehensive Test ===" severity note;

        -- ================================================================
        -- TEST 1: Basic 2-level walk (short format descriptors)
        -- ================================================================
        test_number <= 1;
        report "TEST 1: Basic 2-level walk (short format)" severity note;

        -- Initialize TC: PS=12 (4KB), IS=0, TIA=10, TIB=10, TIC=0, TID=0
        -- Field sum: 12 + 0 + 10 + 10 + 0 + 0 = 32 (valid)
        -- TC = E=1, SRE=0, FCL=0, PS=C, IS=0, TIA=A, TIB=A, TIC=0, TID=0
        write_pmmu_reg("10000", x"80C0AA00", '0');

        -- Initialize CRP (points to address 0x1000)
        -- CRP_H: L/U=0 (upper limit), LIMIT=0x7FFF (allow all entries), DT=10 (4-byte entries)
        write_pmmu_reg("10011", x"7FFFC002", '1'); -- CRP_H with max limit, DT=10
        write_pmmu_reg("10011", x"00001000", '0'); -- CRP_L

        -- Build page tables in simulated memory
        -- Root table at 0x1000: Entry 0 points to level1 table at 0x2000
        page_table_mem(1024) <= x"00002002"; -- 0x1000/4 = 1024, DT=10 (table pointer)

        -- Level1 table at 0x2000: Entry 0 is page at physical 0x00100000
        page_table_mem(2048) <= x"00100001"; -- 0x2000/4 = 2048, DT=01 (page), phys=0x00100000

        -- Request translation for address 0x00000500
        wait for 100 ns;
        addr_log <= x"00000500";
        fc <= "010"; -- User program
        is_insn <= '0';
        rw <= '1'; -- Read
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 100 ns;
        if fault = '0' then
            assert addr_phys = x"00100500"
                report "TEST 1 FAIL: Expected phys=0x00100500, got " &
                       integer'image(to_integer(unsigned(addr_phys))) severity error;
            report "TEST 1 PASS: 2-level walk successful" severity note;
        else
            report "TEST 1 FAIL: Unexpected fault, status=" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test (ensure walker is done first)
        wait until rising_edge(clk);
        wait for 20 ns; -- Ensure previous translation fully completed
        pmmu_brief <= x"2400"; -- PFLUSHA encoding
        pflush_req <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk); -- Hold pflush_req for 2 cycles
        pflush_req <= '0';
        wait for 100 ns; -- Give time for flush to complete

        -- ================================================================
        -- TEST 2: Invalid descriptor (DT=00) at root level
        -- ================================================================
        test_number <= 2;
        report "TEST 2: Invalid descriptor at root" severity note;

        -- Set root table entry 1 to invalid (DT=00)
        page_table_mem(1025) <= x"00000000"; -- Entry 1 at 0x1000+4, DT=00

        -- Request translation for address that uses entry 1
        -- With TIA=10 bits, entry 1 covers addresses 0x00400000-0x007FFFFF
        addr_log <= x"00400000";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '1' and fault_status(10) = '1' then
            report "TEST 2 PASS: Invalid descriptor fault detected" severity note;
        else
            report "TEST 2 FAIL: Expected invalid descriptor fault, fault=" &
                   std_logic'image(fault) & " fault_status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 3: Early termination (large page at root level)
        -- ================================================================
        test_number <= 3;
        report "TEST 3: Early termination / large page" severity note;

        -- Set root table entry 2 to page descriptor (DT=01) instead of table
        -- This creates a "super page" with size = PS + TIB = 12 + 10 = 22 bits (4MB)
        page_table_mem(1026) <= x"00800001"; -- Entry 2 at 0x1000+8, DT=01 (page), phys=0x00800000

        -- Request translation for address in entry 2 range
        -- Entry 2 with TIA=10: starts at (2 << (12+10)) = 0x00800000
        addr_log <= x"00801234";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '0' then
            -- Physical should be 0x00800000 + (0x00801234 & 0x3FFFFF) = 0x00801234
            assert addr_phys = x"00801234"
                report "TEST 3 FAIL: Expected phys=0x00801234 (identity large page)" severity error;
            report "TEST 3 PASS: Early termination / large page works" severity note;
        else
            report "TEST 3 FAIL: Unexpected fault for large page" severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 4: Write protection violation
        -- ================================================================
        test_number <= 4;
        report "TEST 4: Write protection violation" severity note;

        -- Set page descriptor with WP bit (bit 2)
        page_table_mem(2048) <= x"00100005"; -- 0x2000/4 = 2048, DT=01, WP=1 (bit 2 set)
        wait for 10 ns; -- Allow memory update to settle

        -- Request write to protected page
        addr_log <= x"00000600";
        rw <= '0'; -- Write
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '1' and fault_status(11) = '1' then
            report "TEST 4 PASS: Write protection fault detected" severity note;
        else
            report "TEST 4 FAIL: Expected write protection fault, fault=" &
                   std_logic'image(fault) & " fault_status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        -- Clear WP for next tests
        page_table_mem(2048) <= x"00100001"; -- 0x2000/4 = 2048
        rw <= '1'; -- Reset to read

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 5: Mixed format walk (short parent, long child entries)
        -- ================================================================
        test_number <= 5;
        report "TEST 5: Mixed format walk (short parent, long child entries)" severity note;

        -- CRP_H remains DT=10, so root-table entries are 4 bytes.
        -- Entry 3 itself is therefore a single 32-bit descriptor. Its DT=11 selects
        -- LONG (8-byte) descriptors in the child table at 0x3000.
        page_table_mem(1027) <= x"00003003"; -- Entry 3 at 0x1000+12, child table at 0x3000, DT=11
        page_table_mem(1028) <= x"00000000"; -- Entry 4 (unused); must not be consumed as descriptor LOW word

        -- Child table at 0x3000 uses 8-byte entries because parent DT=11.
        -- Entry 0 is a long-format page descriptor mapping to physical 0x00200000.
        page_table_mem(3072) <= x"00000001"; -- 0x3000 HIGH word: DT=01 page descriptor
        page_table_mem(3073) <= x"00200000"; -- 0x3004 LOW word: physical page base
        -- Entry 1 is another long-format page descriptor. It must be 8 bytes later
        -- at 0x3008/0x300C, not 0x3004.
        page_table_mem(3074) <= x"00000001"; -- 0x3008 HIGH word
        page_table_mem(3075) <= x"00210000"; -- 0x300C LOW word

        -- Request translation using entry 3
        -- Entry 3 starts at (3 << (12+10)) = 0x00C00000
        addr_log <= x"00C00100";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '0' then
            assert addr_phys = x"00200100"
                report "TEST 5 FAIL: Mixed format walk produced wrong physical address" severity error;
            report "TEST 5 PASS: Mixed format walk successful" severity note;
        else
            report "TEST 5 FAIL: Fault during mixed format walk" severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 6: Long child-table stride (entry 1 at +8 bytes)
        -- ================================================================
        test_number <= 6;
        report "TEST 6: Long child-table stride (entry 1 at +8 bytes)" severity note;

        -- Same mixed-format setup as TEST 5. Address 0x00C01100 selects child entry 1,
        -- which must come from 0x3008/0x300C because the child table entries are 8 bytes.
        fc <= "010"; -- User program
        addr_log <= x"00C01100";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '0' then
            assert addr_phys = x"00210100"
                report "TEST 6 FAIL: Long child-table stride used wrong entry spacing" severity error;
            report "TEST 6 PASS: Long child-table stride handled correctly" severity note;
        else
            report "TEST 6 FAIL: Unexpected fault, fault=" &
                   std_logic'image(fault) & " fault_status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 7: Supervisor violation
        -- ================================================================
        test_number <= 7;
        report "TEST 7: Supervisor violation" severity note;

        -- Set S=1 in the long-format child page descriptor HIGH word.
        page_table_mem(3072) <= x"00000101"; -- 0x3000 HIGH word: long page descriptor, S=1

        -- User mode access (FC=010)
        fc <= "010"; -- User program
        addr_log <= x"00C00200";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '1' and fault_status(13) = '1' then
            report "TEST 7 PASS: Supervisor violation detected" severity note;
        else
            report "TEST 7 FAIL: Expected supervisor violation, fault=" &
                   std_logic'image(fault) & " fault_status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        -- Clear S bit for next tests
        page_table_mem(3072) <= x"00000001"; -- 0x3000 HIGH word: long page descriptor, S=0
        fc <= "101"; -- Supervisor program

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 8: FCL (Function Code Lookup) mode
        -- ================================================================
        test_number <= 8;
        report "TEST 8: FCL mode" severity note;

        -- Initialize TC with FCL=1: PS=12, IS=0, TIA=8, TIB=12, TIC=0, TID=0
        -- Field sum: 12 + 0 + 8 + 12 + 0 + 0 = 32 (valid)
        -- FCL=1 means level 0 uses FC[2:0] (8 entries max)
        -- TC = E=1, FCL=1, PS=C, IS=0, TIA=8, TIB=C, TIC=0, TID=0
        write_pmmu_reg("10000", x"81C08C00", '0');

        -- Build FCL root table: 8 entries at 0x4000
        -- CRP_H: L/U=0 (upper limit), LIMIT=7 (allow FC 0-7), DT=10 (4-byte entries)
        write_pmmu_reg("10011", x"00070002", '1'); -- CRP_H with limit=7, DT=10
        read_pmmu_reg("10011", '1', x"00070002", "TEST 7 CRP_H");
        write_pmmu_reg("10011", x"00004000", '0');

        -- FC=2 (user program) entry points to table at 0x5000
        page_table_mem(4098) <= x"00005002"; -- 0x4000/4 + 2 = 4096 + 2 = 4098

        -- Level1 table at 0x5000: Entry 0 is page at 0x00300000
        page_table_mem(5120) <= x"00300001"; -- 0x5000/4 = 5120

        -- Request translation with FC=2
        fc <= "010"; -- User program (FC=2)
        addr_log <= x"00000800";
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '0' then
            assert addr_phys = x"00300800"
                report "TEST 8 FAIL: FCL mode walk failed" severity error;
            report "TEST 8 PASS: FCL mode successful" severity note;
        else
            report "TEST 8 FAIL: Fault during FCL walk" severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 9: Invalid root pointer (CRP_H DT=00) - walker must fault
        --         immediately without issuing any memory read
        -- ================================================================
        test_number <= 9;
        report "TEST 9: Invalid root pointer (CRP_H DT=00)" severity note;

        -- Write CRP with DT=00 (invalid root pointer)
        -- CRP_H: L/U=0, Limit=0, DT=00
        write_pmmu_reg("10011", x"00000000", '1');
        -- CRP_L: table address = 0x1000 (should never be accessed)
        write_pmmu_reg("10011", x"00001000", '0');
        -- Acknowledge config exception from CRP_H DT=00 write
        mmu_config_ack <= '1';
        wait until rising_edge(clk);
        mmu_config_ack <= '0';
        wait for 50 ns;

        -- Flush ATC after CRP change
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- Request translation - should fault immediately at root pointer
        addr_log <= x"00000500";
        fc <= "101"; -- supervisor data
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 50 ns;
        if fault = '1' and fault_status(10) = '1' then
            report "TEST 9 PASS: Invalid root pointer (DT=00) fault detected" severity note;
        else
            report "TEST 9 FAIL: Expected invalid root pointer fault, fault=" &
                   std_logic'image(fault) & " fault_status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        wait for 200 ns;

        -- Flush ATC before next test
        pmmu_brief <= x"2400";
        pflush_req <= '1';
        wait until rising_edge(clk);
        pflush_req <= '0';
        wait for 50 ns;

        -- ================================================================
        -- TEST 10: CRP_H DT=00 write fires mmu_config_err (Exception 56)
        -- ================================================================
        test_number <= 10;
        report "TEST 10: CRP_H DT=00 triggers MMU config exception" severity note;

        -- First restore valid CRP so we start from a known state
        write_pmmu_reg("10011", x"7FFFC002", '1'); -- CRP_H: valid DT=10
        write_pmmu_reg("10011", x"00001000", '0'); -- CRP_L
        wait for 50 ns;

        -- Now write CRP_H with DT=00 and check mmu_config_err fires
        write_pmmu_reg("10011", x"00000000", '1'); -- CRP_H: DT=00
        wait for 20 ns;

        if mmu_config_err = '1' then
            report "TEST 10 PASS: mmu_config_err asserted on CRP_H DT=00 write" severity note;
            -- Acknowledge the config exception
            mmu_config_ack <= '1';
            wait until rising_edge(clk);
            mmu_config_ack <= '0';
            wait for 50 ns;
        else
            report "TEST 10 FAIL: mmu_config_err NOT asserted on CRP_H DT=00 write" severity error;
        end if;

        wait for 200 ns;

        -- Restore valid CRP for any future tests
        write_pmmu_reg("10011", x"7FFFC002", '1');
        write_pmmu_reg("10011", x"00001000", '0');
        wait for 50 ns;

        -- ================================================================
        -- All tests complete
        -- ================================================================
        report "=== All Walker Tests Complete ===" severity note;
        test_running <= false;
        wait;

    end process;

end behavior;
