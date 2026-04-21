-- Amiga ROM MMU Test Sequence - Direct PMMU Register Test
-- Tests the exact sequence used by real Amiga ROMs for MMU detection/setup
-- Based on disassembly at $C002DFE

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_amiga_mmu_sequence is
end entity;

architecture testbench of tb_amiga_mmu_sequence is
    

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

signal clk          : std_logic := '0';
    signal nreset       : std_logic := '0';

    -- Register interface
    signal reg_we       : std_logic := '0';
    signal reg_re       : std_logic := '0';
    signal reg_sel      : std_logic_vector(4 downto 0) := (others => '0');
    signal reg_wdat     : std_logic_vector(31 downto 0) := (others => '0');
    signal reg_rdat     : std_logic_vector(31 downto 0);
    signal reg_part     : std_logic := '0';
    signal reg_fd       : std_logic := '0';

    -- Translation interface
    signal req          : std_logic := '0';
    signal is_insn      : std_logic := '0';
    signal rw           : std_logic := '1';
    signal fc           : std_logic_vector(2 downto 0) := "101";
    signal addr_log     : std_logic_vector(31 downto 0) := (others => '0');
    signal addr_phys    : std_logic_vector(31 downto 0);
    signal cache_inhibit: std_logic;
    signal write_protect: std_logic;
    signal fault        : std_logic;
    signal fault_status : std_logic_vector(31 downto 0);
    signal tc_enable    : std_logic;

    -- Memory interface
    signal mem_req      : std_logic;
    signal mem_we       : std_logic;
    signal mem_addr     : std_logic_vector(31 downto 0);
    signal mem_wdat     : std_logic_vector(31 downto 0);
    signal mem_ack      : std_logic := '0';
    signal mem_berr     : std_logic := '0';
    signal mem_rdat     : std_logic_vector(31 downto 0) := (others => '0');
    signal busy         : std_logic;
    signal mmu_config_err : std_logic;
    signal mmu_config_ack : std_logic := '0';

    -- PFLUSH interface
    signal pflush_req   : std_logic := '0';
    signal ptest_req    : std_logic := '0';
    signal pload_req    : std_logic := '0';
    signal pmmu_fc      : std_logic_vector(2 downto 0) := "101";
    signal pmmu_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_brief   : std_logic_vector(15 downto 0) := (others => '0');

    constant CLK_PERIOD : time := 20 ns;
    signal test_done    : boolean := false;

    -- Register selectors (from TG68K_PMMU_030.vhd)
    constant SEL_TT0    : std_logic_vector(4 downto 0) := "00010";  -- 2
    constant SEL_TT1    : std_logic_vector(4 downto 0) := "00011";  -- 3
    constant SEL_TC     : std_logic_vector(4 downto 0) := "10000";  -- 16
    constant SEL_SRP    : std_logic_vector(4 downto 0) := "10010";  -- 18
    constant SEL_CRP    : std_logic_vector(4 downto 0) := "10011";  -- 19
    constant SEL_MMUSR  : std_logic_vector(4 downto 0) := "11000";  -- 24

    -- Test tracking
    signal tc_saved     : std_logic_vector(31 downto 0) := (others => '0');
    signal tt0_saved    : std_logic_vector(31 downto 0) := (others => '0');
    signal tt1_saved    : std_logic_vector(31 downto 0) := (others => '0');
    signal crp_hi_saved : std_logic_vector(31 downto 0) := (others => '0');
    signal crp_lo_saved : std_logic_vector(31 downto 0) := (others => '0');

    signal test_pass_count : integer := 0;
    signal test_fail_count : integer := 0;

begin
    -- Clock generation
    clk_process: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    -- Instantiate PMMU
    dut: entity work.TG68K_PMMU_030
        port map(
            clk            => clk,
            nreset         => nreset,
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
            mem_we         => mem_we,
            mem_addr       => mem_addr,
            mem_wdat       => mem_wdat,
            mem_ack        => mem_ack,
            mem_berr       => mem_berr,
            mem_rdat       => mem_rdat,
            busy           => busy,
            mmu_config_err => mmu_config_err,
            mmu_config_ack => mmu_config_ack
        );

    -- Simple memory model for page table walks
    mem_model: process(clk)
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            if mem_req = '1' then
                -- Return valid page descriptor for any address
                -- DT=01 (page), page frame = requested address aligned
                mem_rdat <= mem_addr(31 downto 8) & x"01";
                mem_ack <= '1';
            end if;
        end if;
    end process;

    -- Main test process - Amiga ROM MMU sequence
    test_process: process
        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
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

        procedure ack_mmu_config_error_if_set is
        begin
            if mmu_config_err = '1' then
                mmu_config_ack <= '1';
                wait_cycles(1);
                mmu_config_ack <= '0';
                wait_cycles(1);
            end if;
        end procedure;

        procedure do_pflush is
        begin
            pmmu_brief <= x"2400";  -- PFLUSHA encoding
            pflush_req <= '1';
            wait_cycles(1);
            pflush_req <= '0';
            wait_cycles(2);
        end procedure;

        procedure check_pass(name : string; expected, actual : std_logic_vector(31 downto 0)) is
        begin
            if actual = expected then
                report "PASS: " & name & " = " &
                       integer'image(to_integer(unsigned(actual)));
                test_pass_count <= test_pass_count + 1;
            else
                report "FAIL: " & name & " expected " &
                       integer'image(to_integer(unsigned(expected))) & " got " &
                       integer'image(to_integer(unsigned(actual))) severity error;
                test_fail_count <= test_fail_count + 1;
            end if;
        end procedure;

    begin
        report "=== Amiga ROM MMU Test Sequence ===" severity note;
        report "Replicating real Amiga ROM MMU initialization" severity note;
        report "";

        -- Reset
        nreset <= '0';
        wait_cycles(5);
        nreset <= '1';
        wait_cycles(5);

        -- Step 1: PFLUSHA (flush all ATC entries)
        report "Step 1: PFLUSHA - Flush all ATC entries" severity note;
        do_pflush;

        -- Step 2: PMOVE.L TC,(SP) - Read TC (MMU detection!)
        report "Step 2: PMOVE.L TC,(SP) - Read TC register (MMU detection)" severity note;
        read_reg(SEL_TC, '0');
        tc_saved <= reg_rdat;
        report "  TC = 0x" & slv_to_hex(reg_rdat) severity note;
        -- After reset, TC should be 0 (MMU disabled)
        if reg_rdat(31) = '0' then
            report "  -> TC.E=0, MMU disabled (correct after reset)" severity note;
            test_pass_count <= test_pass_count + 1;
        else
            report "  -> ERROR: TC.E=1 after reset!" severity error;
            test_fail_count <= test_fail_count + 1;
        end if;

        -- Step 3: PMOVE.L 0,TC - Disable MMU (write 0 to TC)
        report "Step 3: PMOVE.L (SP),TC - Write 0 to TC (ensure disabled)" severity note;
        write_reg(SEL_TC, x"00000000", '0');
        wait_cycles(2);

        -- Verify TC disabled
        read_reg(SEL_TC, '0');
        if tc_enable = '0' then
            report "  -> tc_enable=0 PASS" severity note;
            test_pass_count <= test_pass_count + 1;
        else
            report "  -> tc_enable should be 0!" severity error;
            test_fail_count <= test_fail_count + 1;
        end if;
        ack_mmu_config_error_if_set;

        -- Step 4: PFLUSHA again
        report "Step 4: PFLUSHA - Flush ATC again" severity note;
        do_pflush;

        -- Step 5: PMOVE.L TT0,(SP) - Read TT0
        report "Step 5: PMOVE.L TT0,(SP) - Read TT0 register" severity note;
        read_reg(SEL_TT0, '0');
        tt0_saved <= reg_rdat;
        report "  TT0 = 0x" & slv_to_hex(reg_rdat) severity note;

        -- Step 6: PMOVE.L TT1,(SP) - Read TT1
        report "Step 6: PMOVE.L TT1,(SP) - Read TT1 register" severity note;
        read_reg(SEL_TT1, '0');
        tt1_saved <= reg_rdat;
        report "  TT1 = 0x" & slv_to_hex(reg_rdat) severity note;

        -- Step 7: PMOVE.Q CRP,(SP) - Read CRP (64-bit)
        report "Step 7: PMOVE.Q CRP,(SP) - Read CRP register (64-bit)" severity note;
        read_reg(SEL_CRP, '1');  -- High word first
        crp_hi_saved <= reg_rdat;
        report "  CRP.high = 0x" & slv_to_hex(reg_rdat) severity note;
        read_reg(SEL_CRP, '0');  -- Low word
        crp_lo_saved <= reg_rdat;
        report "  CRP.low = 0x" & slv_to_hex(reg_rdat) severity note;

        -- Step 8: PMOVE.L 0,TT0 - Clear TT0
        report "Step 8: PMOVE.L (SP),TT0 - Write 0 to TT0" severity note;
        write_reg(SEL_TT0, x"00000000", '0');

        -- Step 9: PMOVE.L 0,TT1 - Clear TT1
        report "Step 9: PMOVE.L (SP),TT1 - Write 0 to TT1" severity note;
        write_reg(SEL_TT1, x"00000000", '0');

        -- Step 10: Setup page tables and enable MMU
        -- From disassembly: CRP = $80000002:$rootptr, TC = $81F09800
        report "Step 10: Setup page tables - Write CRP" severity note;
        -- CRP high: $80000002 (DT=2, table descriptor)
        write_reg(SEL_CRP, x"80000002", '1');
        -- CRP low: $00010000 (root table at $10000)
        write_reg(SEL_CRP, x"00010000", '0');

        -- Verify CRP write
        read_reg(SEL_CRP, '1');
        report "  CRP.high readback = 0x" & slv_to_hex(reg_rdat) severity note;
        read_reg(SEL_CRP, '0');
        report "  CRP.low readback = 0x" & slv_to_hex(reg_rdat) severity note;

        -- Step 11: Enable MMU with valid TC
        -- TC=$81F09800: E=1, FCL=1, PS=15(32KB), IS=0, TIA=9, TIB=8, TIC=0, TID=0
        -- MC68030 validation: sum until first zero TIx = PS + IS + TIA + TIB = 15 + 0 + 9 + 8 = 32 (VALID!)
        -- TIC=0 terminates the tree, TID is not counted
        report "Step 11: PMOVE.L (SP),TC - Enable MMU with TC=$81F09800" severity note;
        write_reg(SEL_TC, x"81F09800", '0');
        wait_cycles(5);

        -- Check if MMU enabled
        if tc_enable = '1' then
            report "  -> tc_enable=1 PASS - MMU enabled!" severity note;
            test_pass_count <= test_pass_count + 1;
        else
            report "  -> tc_enable should be 1!" severity error;
            test_fail_count <= test_fail_count + 1;
        end if;

        -- Step 12: PFLUSHA
        report "Step 12: PFLUSHA - Flush after enable" severity note;
        do_pflush;

        -- Step 13: Test translation (simulating MOVES.L)
        report "Step 13: Test translation request" severity note;
        addr_log <= x"00F80004";  -- Test address
        fc <= "101";  -- Supervisor data
        rw <= '1';    -- Read
        req <= '1';
        wait_cycles(1);
        req <= '0';

        -- Wait for translation
        wait_cycles(20);

        report "  Logical: 0x" & slv_to_hex(addr_log) severity note;
        report "  Physical: 0x" & slv_to_hex(addr_phys) severity note;
        report "  Fault: " & std_logic'image(fault) severity note;

        -- Step 14: Disable MMU (restore)
        report "Step 14: PMOVE.L (SP),TC - Disable MMU (write 0)" severity note;
        write_reg(SEL_TC, x"00000000", '0');
        wait_cycles(2);

        if tc_enable = '0' then
            report "  -> tc_enable=0 PASS - MMU disabled" severity note;
            test_pass_count <= test_pass_count + 1;
        else
            report "  -> tc_enable should be 0!" severity error;
            test_fail_count <= test_fail_count + 1;
        end if;
        ack_mmu_config_error_if_set;

        -- Step 14B: MC68030 TT registers operate independently of TC.E, so a
        -- matching transparent window must remain active even after table
        -- translation is disabled.
        report "Step 14B: TT remains active when TC.E=0" severity note;
        write_reg(SEL_TT0, x"00008514", '0');  -- enabled low-16MB transparent window, CI=1
        wait_cycles(2);
        addr_log <= x"00DC0000";
        fc <= "101";  -- supervisor data
        rw <= '1';
        req <= '1';
        wait_cycles(1);
        req <= '0';
        wait_cycles(4);
        if addr_phys = x"00DC0000" and cache_inhibit = '1' and write_protect = '0' and fault = '0' then
            report "  -> TC disabled kept TT active for $00DC0000" severity note;
            test_pass_count <= test_pass_count + 1;
        else
            report "  -> TC disabled lost TT behavior: phys=0x" & slv_to_hex(addr_phys) &
                   " CI=" & std_logic'image(cache_inhibit) &
                   " WP=" & std_logic'image(write_protect) &
                   " fault=" & std_logic'image(fault) severity error;
            test_fail_count <= test_fail_count + 1;
        end if;
        write_reg(SEL_TT0, x"00000000", '0');
        wait_cycles(2);

        -- Step 15: PFLUSHA final
        report "Step 15: PFLUSHA - Final flush" severity note;
        do_pflush;

        -- Step 16: Restore TT0/TT1 if they were enabled
        report "Step 16: Restore TT0/TT1 (if needed)" severity note;
        if tt0_saved(15) = '1' then
            write_reg(SEL_TT0, tt0_saved, '0');
            report "  TT0 restored" severity note;
        end if;
        if tt1_saved(15) = '1' then
            write_reg(SEL_TT1, tt1_saved, '0');
            report "  TT1 restored" severity note;
        end if;

        -- Final report
        report "" severity note;
        report "=== Amiga ROM MMU Test Complete ===" severity note;
        report "Passed: " & integer'image(test_pass_count) severity note;
        report "Failed: " & integer'image(test_fail_count) severity note;

        if test_fail_count = 0 then
            report "*** ALL TESTS PASSED ***" severity note;
        else
            report "*** SOME TESTS FAILED ***" severity error;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
