-- tb_lockup_bus_conflict.vhd
-- Testbench for CRITICAL ISSUE #3: Graphical Memory/Walker Bus Conflict
-- Tests bus arbitration when DMA and walker try to access memory simultaneously
-- Reproduces deadlock when graphical bitplane writes collide with page table walks

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_lockup_bus_conflict is
end tb_lockup_bus_conflict;

architecture behavior of tb_lockup_bus_conflict is

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
          mmu_config_ack : in  std_logic
        );
    end component;

    constant clk_period : time := 10 ns;

    signal clk : std_logic := '0';
    signal nreset : std_logic := '0';
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
    signal pmmu_fc : std_logic_vector(2 downto 0) := (others => '0');
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
    signal test_running : boolean := true;

    -- DMA simulation signals
    signal dma_active : boolean := false;
    signal dma_addr : std_logic_vector(31 downto 0) := (others => '0');
    signal dma_write : boolean := false;
    signal dma_req : std_logic := '0';
    signal dma_ack : std_logic := '0';

    -- Bus conflict simulation
    signal bus_collision : boolean := false;
    signal walker_mem_req_prev : std_logic := '0';

    -- Memory arbiter signals
    signal mem_grant_walker : boolean := false;
    signal mem_grant_dma : boolean := false;
    signal mem_busy : boolean := false;

    type mem_array_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal page_table_mem : mem_array_t := (others => (others => '0'));

begin

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
        mmu_config_ack => mmu_config_ack
    );

    clk_process :process
    begin
        while test_running loop
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        end loop;
        wait;
    end process;

    -- Bus arbiter - simulates cpu_wrapper bus arbitration
    -- Detects collisions when walker and DMA both try to access memory
    bus_arbiter_proc: process(clk)
    begin
        if rising_edge(clk) then
            walker_mem_req_prev <= mem_req;

            -- Detect collision when both walker and DMA request bus simultaneously
            if mem_req = '1' and dma_req = '1' and not mem_busy then
                bus_collision <= true;
                -- In real hardware, this causes a deadlock or corrupted access
                -- Priority resolution is missing/broken
                mem_grant_walker <= false;
                mem_grant_dma <= false;
                mem_busy <= true;
            elsif mem_req = '1' and not dma_active then
                -- Walker gets bus
                mem_grant_walker <= true;
                mem_grant_dma <= false;
                mem_busy <= true;
                bus_collision <= false;
            elsif dma_req = '1' and mem_req = '0' then
                -- DMA gets bus
                mem_grant_dma <= true;
                mem_grant_walker <= false;
                mem_busy <= true;
                bus_collision <= false;
            else
                mem_grant_walker <= false;
                mem_grant_dma <= false;
                mem_busy <= false;
            end if;
        end if;
    end process;

    -- Memory controller simulation
    mem_controller_proc: process(clk)
        variable access_delay : integer := 0;
    begin
        if rising_edge(clk) then
            mem_ack <= '0';
            dma_ack <= '0';

            if bus_collision then
                -- Collision state - neither gets ack
                -- This simulates the deadlock condition
                mem_ack <= '0';
                dma_ack <= '0';
            elsif mem_grant_walker then
                -- Walker access
                if access_delay < 2 then
                    access_delay := access_delay + 1;
                else
                    mem_ack <= '1';
                    mem_rdat <= page_table_mem(to_integer(unsigned(mem_addr(9 downto 0))));
                    access_delay := 0;
                end if;
            elsif mem_grant_dma then
                -- DMA access
                if access_delay < 2 then
                    access_delay := access_delay + 1;
                else
                    dma_ack <= '1';
                    if dma_write then
                        -- DMA write to bitplane memory
                        page_table_mem(to_integer(unsigned(dma_addr(9 downto 0)))) <= x"DEADBEEF";
                    end if;
                    access_delay := 0;
                end if;
            else
                access_delay := 0;
            end if;
        end if;
    end process;

    -- DMA simulator - generates competing memory accesses
    dma_sim_proc: process
    begin
        wait until nreset = '1';
        wait for clk_period * 10;

        while test_running loop
            if dma_active then
                -- Simulate bitplane DMA write
                dma_req <= '1';
                wait until dma_ack = '1' or bus_collision;
                wait for clk_period;
                dma_req <= '0';

                if bus_collision then
                    -- DMA stuck in collision
                    wait for clk_period * 100;  -- Wait to see if it recovers
                end if;

                wait for clk_period * 5;  -- Gap between DMA cycles
            else
                dma_req <= '0';
                wait for clk_period;
            end if;
        end loop;
        wait;
    end process;

    -- Main stimulus
    stim_proc: process
        variable l : line;
        variable cycle_count : integer := 0;
        variable collision_detected : boolean := false;
    begin
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Bus Conflict Deadlock Test"));
        writeline(output, l);
        write(l, string'("Tests CRITICAL ISSUE #3"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        wait for clk_period;
        nreset <= '1';
        wait for clk_period * 2;

        -- Setup page table
        for i in 0 to 15 loop
            page_table_mem(i) <= x"80000000" or std_logic_vector(to_unsigned(i * 4096, 32));
        end loop;

        -- Enable MMU
        reg_sel <= "10000";  -- TC
        reg_wdat <= x"80800000";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- Setup CRP
        reg_sel <= "10011";
        reg_part <= '0';
        reg_wdat <= x"00000000";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        reg_part <= '1';
        reg_wdat <= x"00000001";
        reg_we <= '1';
        wait for clk_period;
        reg_we <= '0';
        wait for clk_period;

        -- TEST 1: Normal walker operation without DMA
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 1: Walker Without DMA Interference"));
        writeline(output, l);

        dma_active <= false;
        addr_log <= x"00012340";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        while busy = '1' and cycle_count < 100 loop
            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        if busy = '0' and fault = '0' then
            write(l, string'("  PASS: Translation completed in " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Translation failed"));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 2: Walker with DMA interference (same address region)
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 2: CRITICAL - Walker + DMA Same Region"));
        writeline(output, l);
        write(l, string'("Simulating bitplane DMA write during page table walk..."));
        writeline(output, l);

        -- Start DMA to chip RAM (same region as page tables)
        dma_active <= true;
        dma_addr <= x"00000100";  -- Chip RAM address
        dma_write <= true;

        -- Small delay to let DMA start
        wait for clk_period * 3;

        -- Request translation while DMA is active
        addr_log <= x"00023450";
        fc <= "101";
        req <= '1';
        wait for clk_period;
        req <= '0';

        cycle_count := 0;
        collision_detected := false;

        while cycle_count < 300 loop
            if bus_collision then
                collision_detected := true;
                write(l, string'("  BUS COLLISION DETECTED at cycle " & integer'image(cycle_count)));
                writeline(output, l);
                write(l, string'("  Walker mem_req=" & std_logic'image(mem_req) & ", DMA dma_req=" & std_logic'image(dma_req)));
                writeline(output, l);
            end if;

            if busy = '0' then
                exit;
            end if;

            wait for clk_period;
            cycle_count := cycle_count + 1;
        end loop;

        dma_active <= false;

        if collision_detected and busy = '1' then
            write(l, string'("  FAIL: DEADLOCK - Bus collision caused permanent hang"));
            writeline(output, l);
            write(l, string'("  Walker busy=" & std_logic'image(busy) & " after " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
            write(l, string'("  This confirms CRITICAL ISSUE #3!"));
            writeline(output, l);
        elsif collision_detected and busy = '0' then
            write(l, string'("  WARNING: Collision detected but system recovered"));
            writeline(output, l);
            write(l, string'("  Recovery time: " & integer'image(cycle_count) & " cycles"));
            writeline(output, l);
        elsif not collision_detected and busy = '0' then
            write(l, string'("  PASS: No collision, arbiter working correctly"));
            writeline(output, l);
        else
            write(l, string'("  FAIL: Unknown state, busy=" & std_logic'image(busy)));
            writeline(output, l);
        end if;

        wait for clk_period * 10;

        -- TEST 3: Rapid alternating access pattern
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("TEST 3: Rapid Alternating Access"));
        writeline(output, l);
        write(l, string'("Testing bus arbiter under stress..."));
        writeline(output, l);

        for i in 0 to 4 loop
            dma_active <= true;
            dma_addr <= std_logic_vector(to_unsigned(16#00000200# + i * 256, 32));
            wait for clk_period * 2;

            addr_log <= std_logic_vector(to_unsigned(16#00030000# + i * 8192, 32));
            fc <= "101";
            req <= '1';
            wait for clk_period;
            req <= '0';

            cycle_count := 0;
            while busy = '1' and cycle_count < 50 loop
                if bus_collision then
                    write(l, string'("  Collision in iteration " & integer'image(i)));
                    writeline(output, l);
                end if;
                wait for clk_period;
                cycle_count := cycle_count + 1;
            end loop;

            dma_active <= false;
            wait for clk_period * 5;
        end loop;

        write(l, string'("  Rapid access test completed"));
        writeline(output, l);

        wait for clk_period * 10;

        write(l, string'(""));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);
        write(l, string'("Bus Conflict Test Complete"));
        writeline(output, l);
        write(l, string'("========================================"));
        writeline(output, l);

        test_running <= false;
        wait;
    end process;

end behavior;
