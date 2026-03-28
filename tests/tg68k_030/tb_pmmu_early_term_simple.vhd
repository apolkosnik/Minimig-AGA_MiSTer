-- Simple test for PMMU early termination (large pages)
-- Tests if page descriptors at non-leaf levels work correctly

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_pmmu_early_term_simple is
end tb_pmmu_early_term_simple;

architecture tb of tb_pmmu_early_term_simple is

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

    -- PTEST Support
    signal ptest_desc_addr : std_logic_vector(31 downto 0);

    -- Page table memory simulation
    type mem_array_t is array (0 to 8191) of std_logic_vector(31 downto 0);
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
                    addr_idx := to_integer(unsigned(mem_addr(14 downto 2)));
                    if addr_idx < 8192 then
                        mem_rdat <= page_table_mem(addr_idx);
                        report "MEM_READ: addr=0x" & integer'image(to_integer(unsigned(mem_addr))) &
                               " idx=" & integer'image(addr_idx) &
                               " data=0x" & integer'image(to_integer(unsigned(page_table_mem(addr_idx))))
                               severity note;
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

    begin
        -- Reset
        nreset <= '0';
        wait for 100 ns;
        nreset <= '1';
        wait for 50 ns;

        report "=== PMMU Early Termination (Large Page) Test ===" severity note;

        -- Initialize TC: PS=12 (4KB), IS=0, TIA=10, TIB=10, TIC=0, TID=0
        -- TC = E=1, SRE=0, FCL=0, PS=C, IS=0, TIA=A, TIB=A, TIC=0, TID=0
        write_pmmu_reg("10000", x"80C0AA00", '0');

        -- Initialize CRP (points to address 0x1000)
        -- CRP_H: L/U=0 (upper limit), LIMIT=0x7FFF (all entries), DT=10 (short-format, 4-byte entries)
        write_pmmu_reg("10011", x"7FFFC002", '1'); -- CRP_H with max limit, DT=10
        write_pmmu_reg("10011", x"00001000", '0'); -- CRP_L

        -- Build page table: Root entry 2 is a PAGE descriptor (early termination)
        -- Short-format: Entry 2 at 0x1000 + (2*4) = 0x1008, array index = 0x1008/4 = 1026
        page_table_mem(1026) <= x"00800001"; -- DT=01 (page), phys=0x00800000

        report "SETUP: Set page_table_mem(1026) = 0x00800001" severity note;

        wait for 100 ns;

        -- Request translation for address in entry 2 range
        -- With TIA=10, entry 2 covers 0x00800000-0x00BFFFFF (4MB)
        report "TEST: Requesting translation for 0x00801234" severity note;
        addr_log <= x"00801234";
        fc <= "101"; -- Supervisor program
        is_insn <= '0';
        rw <= '1'; -- Read
        req <= '1';
        wait until busy = '0' or fault = '1';
        req <= '0';

        wait for 100 ns;

        if fault = '0' then
            report "TEST PASS: Early termination succeeded, phys=0x" &
                   integer'image(to_integer(unsigned(addr_phys))) severity note;
            -- Physical should be 0x00800000 + 0x1234 = 0x00801234 (identity for this case)
            assert addr_phys = x"00801234"
                report "TEST FAIL: Expected phys=0x00801234, got 0x" &
                       integer'image(to_integer(unsigned(addr_phys))) severity error;
        else
            report "TEST FAIL: Unexpected fault, status=0x" &
                   integer'image(to_integer(unsigned(fault_status))) severity error;
        end if;

        wait for 200 ns;
        report "=== Test Complete ===" severity note;
        test_running <= false;
        wait;

    end process;

end tb;
