library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.std_logic_unsigned.all;

entity tb_pmove_minimal is
end tb_pmove_minimal;

architecture behavior of tb_pmove_minimal is
    component TG68KdotC_Kernel
        port(
            clk : in std_logic;
            nReset : in std_logic;
            clkena_in : in std_logic;
            data_in : in std_logic_vector(15 downto 0);
            IPL : in std_logic_vector(2 downto 0);
            IPL_autovector : in std_logic;
            berr : in std_logic;
            CPU : in std_logic_vector(1 downto 0);
            addr_out : out std_logic_vector(31 downto 0);
            data_write : out std_logic_vector(15 downto 0);
            nWr : out std_logic;
            nUDS : out std_logic;
            nLDS : out std_logic;
            busstate : out std_logic_vector(1 downto 0);
            longword : out std_logic;
            nResetOut : out std_logic;
            FC : out std_logic_vector(2 downto 0);
            clr_berr : out std_logic;
            skipFetch : out std_logic;
            regin_out : out std_logic_vector(31 downto 0);
            CACR_out : out std_logic_vector(31 downto 0);
            VBR_out : out std_logic_vector(31 downto 0);
            cache_cinv_req : out std_logic;
            cache_cpush_req : out std_logic;
            cache_op_scope : out std_logic_vector(1 downto 0);
            cache_op_cache : out std_logic_vector(1 downto 0);
            cacr_ie : out std_logic;
            cacr_de : out std_logic;
            cacr_ifreeze : out std_logic;
            cacr_dfreeze : out std_logic;
            cacr_ibe : out std_logic;
            cacr_dbe : out std_logic;
            cacr_wa : out std_logic;
            pmmu_reg_we : out std_logic;
            pmmu_reg_re : out std_logic;
            pmmu_reg_sel : out std_logic_vector(4 downto 0);
            pmmu_reg_wdat : out std_logic_vector(31 downto 0);
            pmmu_reg_part : out std_logic;
            pmmu_addr_log : out std_logic_vector(31 downto 0);
            pmmu_addr_phys : out std_logic_vector(31 downto 0);
            pmmu_cache_inhibit : out std_logic;
            cache_op_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_req : out std_logic;
            pmmu_walker_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_ack : in std_logic;
            pmmu_walker_data : in std_logic_vector(31 downto 0);
            debug_SVmode : out std_logic;
            debug_preSVmode : out std_logic;
            debug_FlagsSR_S : out std_logic;
            debug_changeMode : out std_logic;
            debug_setopcode : out std_logic;
            debug_exec_directSR : out std_logic;
            debug_exec_to_SR : out std_logic;
            debug_pmove_dn_mode : out std_logic;
            debug_pmove_dn_regnum : out std_logic_vector(2 downto 0)
        );
    end component;

    signal clk, nReset, clkena_in : std_logic := '0';
    signal data_in : std_logic_vector(15 downto 0) := X"4E71";
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal CPU : std_logic_vector(1 downto 0) := "00";  -- Start with 68000 to verify CPU works
    signal addr_out : std_logic_vector(31 downto 0);
    signal busstate : std_logic_vector(1 downto 0);
    signal FC : std_logic_vector(2 downto 0);
    signal skipFetch : std_logic;
    signal nResetOut : std_logic;

    -- PMMU walker interface
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');

    -- PMMU register interface
    signal pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal pmmu_reg_we : std_logic;
    signal pmmu_reg_re : std_logic;
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);

    -- Track MMU state
    signal tc_enable : std_logic := '0';  -- TC.E bit (MMU disabled at start)

    type mem_t is array(0 to 4095) of std_logic_vector(15 downto 0);

    signal test_done : boolean := false;

    -- Initialize memory with test program
    function init_mem return mem_t is
        variable result : mem_t := (others => X"4E71");
    begin
        -- Reset vectors at $0-$7
        result(0) := X"0000"; result(1) := X"1000";  -- Initial SSP = $00001000
        result(2) := X"0000"; result(3) := X"1000";  -- Initial PC = $00001000 (after all vectors)

        -- Exception vectors (all point to infinite loop at $100)
        for i in 4 to 255 loop
            result(i*2) := X"0000";
            result(i*2+1) := X"0100";  -- Exception handler at $100
        end loop;

        -- Exception handler at $100 (word address 128): infinite loop
        result(128) := X"60FE";  -- BRA.S -2 (infinite loop)

        -- Test program at $1000 (word address 2048) - MINIMAL 68000 TEST
        result(2048) := X"7001";  -- MOVEQ #1,D0
        result(2049) := X"7202";  -- MOVEQ #2,D1
        result(2050) := X"7403";  -- MOVEQ #3,D2
        result(2051) := X"7604";  -- MOVEQ #4,D3
        result(2052) := X"7805";  -- MOVEQ #5,D4
        result(2053) := X"4E71";  -- NOP
        result(2054) := X"4E71";  -- NOP
        result(2055) := X"4E71";  -- NOP
        result(2056) := X"4E71";  -- NOP at $1010 <- CPU should reach here
        result(2057) := X"4AFC";  -- ILLEGAL - test stops here
        return result;
    end function;

    signal mem : mem_t := init_mem;

    -- Debug: Print initial memory contents
    procedure print_mem_init is
    begin
        report "Memory initialized:";
        report "mem[0]=$" & integer'image(to_integer(unsigned(mem(0)))) & " SSP high";
        report "mem[1]=$" & integer'image(to_integer(unsigned(mem(1)))) & " SSP low";
        report "mem[2]=$" & integer'image(to_integer(unsigned(mem(2)))) & " PC high";
        report "mem[3]=$" & integer'image(to_integer(unsigned(mem(3)))) & " PC low=$1000";
        report "mem[8]=$" & integer'image(to_integer(unsigned(mem(8)))) & " exception vector[4]";
        report "mem[128]=$" & integer'image(to_integer(unsigned(mem(128)))) & " exception handler=$60FE";
        report "mem[2048]=$" & integer'image(to_integer(unsigned(mem(2048)))) & " program start=$203C";
    end procedure;

begin
    clk <= not clk after 10 ns when not test_done else '0';
    clkena_in <= '1';

    -- Combinational memory - must be async for CPU
    process(addr_out)
        variable addr_idx : integer;
    begin
        if unsigned(addr_out(12 downto 1)) < 4096 then
            addr_idx := to_integer(unsigned(addr_out(12 downto 1)));
            data_in <= mem(addr_idx);
        else
            data_in <= X"4E71";
        end if;
    end process;

    process(clk)
        variable last_addr : std_logic_vector(15 downto 0) := X"FFFF";
        variable fetch_num : integer := 0;
        variable cycle_count : integer := 0;
    begin
        if rising_edge(clk) then
            cycle_count := cycle_count + 1;

            -- Debug key signals every 100 cycles
            if cycle_count mod 100 = 0 then
                report "Cycle " & integer'image(cycle_count) &
                       ": busstate=" & integer'image(to_integer(unsigned(busstate))) &
                       " skipFetch=" & std_logic'image(skipFetch) &
                       " nResetOut=" & std_logic'image(nResetOut) &
                       " addr=$" & integer'image(to_integer(unsigned(addr_out(15 downto 0))));
            end if;

            -- Track all bus accesses
            if busstate = "01" and addr_out(15 downto 0) /= last_addr then
                fetch_num := fetch_num + 1;
                report "FETCH#" & integer'image(fetch_num) &
                       " @$" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
                       " FC=" & integer'image(to_integer(unsigned(FC))) &
                       " DATA=$" & integer'image(to_integer(unsigned(data_in)));
                last_addr := addr_out(15 downto 0);

                -- Detect exception vector reads (addresses $0-$3FF)
                if unsigned(addr_out(15 downto 0)) < 1024 and unsigned(addr_out(15 downto 0)) > 7 then
                    report "  -> Reading EXCEPTION VECTOR at offset $" &
                           integer'image(to_integer(unsigned(addr_out(15 downto 0))));
                end if;

                if addr_out(15 downto 0) = X"1010" then
                    report "========================================";
                    report "SUCCESS: CPU executing correctly - reached $1010";
                    report "========================================";
                elsif addr_out(15 downto 0) = X"1012" then
                    report "========================================";
                    report "STOP: CPU reached ILLEGAL at $1012 - test complete";
                    report "========================================";
                elsif addr_out(15 downto 0) = X"0100" then
                    report "========================================";
                    report "EXCEPTION: CPU took exception, PC=$100 (exception handler)";
                    report "Test program crashed before reaching PMOVE test!";
                    report "========================================";
                end if;
            end if;
        end if;
    end process;

    uut: TG68KdotC_Kernel port map(
        clk => clk, nReset => nReset, clkena_in => clkena_in,
        data_in => data_in, IPL => IPL, IPL_autovector => '0',
        berr => '0', CPU => CPU, addr_out => addr_out,
        data_write => open, nWr => open, nUDS => open, nLDS => open,
        busstate => busstate, longword => open, nResetOut => nResetOut,
        FC => FC, clr_berr => open, skipFetch => skipFetch,
        regin_out => open, CACR_out => open, VBR_out => open,
        cache_cinv_req => open, cache_cpush_req => open,
        cache_op_scope => open, cache_op_cache => open,
        cacr_ie => open, cacr_de => open, cacr_ifreeze => open,
        cacr_dfreeze => open, cacr_ibe => open, cacr_dbe => open,
        cacr_wa => open, pmmu_reg_we => pmmu_reg_we, pmmu_reg_re => pmmu_reg_re,
        pmmu_reg_sel => pmmu_reg_sel, pmmu_reg_wdat => pmmu_reg_wdat, pmmu_reg_part => open,
        pmmu_addr_log => open, pmmu_addr_phys => open,
        pmmu_cache_inhibit => open, cache_op_addr => open,
        pmmu_walker_req => pmmu_walker_req, pmmu_walker_addr => pmmu_walker_addr,
        pmmu_walker_ack => pmmu_walker_ack, pmmu_walker_data => pmmu_walker_data,
        debug_SVmode => open, debug_preSVmode => open,
        debug_FlagsSR_S => open, debug_changeMode => open,
        debug_setopcode => open, debug_exec_directSR => open,
        debug_exec_to_SR => open, debug_pmove_dn_mode => open,
        debug_pmove_dn_regnum => open
    );

    -- PMMU walker simulator - immediately ack all requests
    process(clk) begin
        if rising_edge(clk) then
            if pmmu_walker_req = '1' then
                pmmu_walker_ack <= '1';
                pmmu_walker_data <= X"00000000";  -- Invalid descriptor
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -- Monitor PMOVE operations and track TC.E bit
    process(clk) begin
        if rising_edge(clk) then
            if pmmu_reg_we = '1' then
                report "PMOVE WRITE to register " & integer'image(to_integer(unsigned(pmmu_reg_sel))) &
                       " data=$" & integer'image(to_integer(unsigned(pmmu_reg_wdat)));
                -- Track TC register writes (sel=0)
                if pmmu_reg_sel = "00000" then
                    tc_enable <= pmmu_reg_wdat(31);  -- TC.E is bit 31
                    report "  TC.E (MMU enable) = " & std_logic'image(pmmu_reg_wdat(31));
                end if;
            end if;
            if pmmu_reg_re = '1' then
                report "PMOVE READ from register " & integer'image(to_integer(unsigned(pmmu_reg_sel)));
            end if;
        end if;
    end process;

    process begin
        print_mem_init;  -- Debug memory contents
        nReset <= '0'; wait for 100 ns;
        nReset <= '1';
        wait for 50 us;
        if not test_done then
            report "========================================";
            report "TIMEOUT - Test did not complete";
            report "Last fetch address: $" & integer'image(to_integer(unsigned(addr_out(15 downto 0))));
            report "========================================";
        end if;
        test_done <= true;
        wait;
    end process;
end behavior;
