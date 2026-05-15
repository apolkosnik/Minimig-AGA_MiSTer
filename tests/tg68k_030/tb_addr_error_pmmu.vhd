-- tb_addr_error_pmmu.vhd
-- Tests address error (odd PC) with PMMU enabled and cpu_wrapper-like clkena_in gating.
--
-- BUG: When PMMU is enabled (TC.E=1), an instruction fetch at an odd PC address
-- still asserts pmmu_req='1' (because state="00", only busstate is overridden to "01").
-- If the odd address is in an unmapped page, the walker faults, pmmu_fault='1',
-- make_berr='1', and at setinterrupt time make_berr has HIGHER priority than
-- TG68_PC(0)='1'. Result: bus error fires instead of address error
-- (vector 3).
--
-- Test A: JMP to odd address in MAPPED page   -> expect vector 3 (address error)
-- Test B: JMP to odd address in UNMAPPED page -> expect vector 3, BUG gives vector 2
-- or, on older stale MC68851-style paths, vector 61.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_unsigned.all;

entity tb_addr_error_pmmu is
end entity;

architecture behavioral of tb_addr_error_pmmu is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length/4);
        variable nibble : std_logic_vector(3 downto 0);
        variable v : std_logic_vector(value'length - 1 downto 0);
    begin
        v := value;
        for i in 0 to (v'length/4 - 1) loop
            nibble := v(v'length - 1 - i*4 downto v'length - 4 - i*4);
            result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    constant CLK_PERIOD : time := 10 ns;
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal test_done : boolean := false;

    -- CPU interface
    signal clkena_in   : std_logic := '1';
    signal data_in     : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write  : std_logic_vector(15 downto 0);
    signal addr_out    : std_logic_vector(31 downto 0);
    signal busstate    : std_logic_vector(1 downto 0);
    signal nWr         : std_logic;
    signal nUDS        : std_logic;
    signal nLDS        : std_logic;
    signal FC          : std_logic_vector(2 downto 0);

    -- Walker interface
    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    -- PMMU outputs
    signal pmmu_addr_phys    : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal pmmu_addr_log     : std_logic_vector(31 downto 0);

    -- Debug signals
    signal debug_TG68_PC     : std_logic_vector(31 downto 0);
    signal debug_state       : std_logic_vector(1 downto 0);
    signal debug_micro_state : integer range 0 to 255;
    signal debug_clkena_lw   : std_logic;
    signal debug_trap_berr   : std_logic;
    signal debug_trap_mmu_berr : std_logic;
    signal debug_trap_addr_error : std_logic;
    signal debug_make_berr   : std_logic;
    signal debug_pmmu_fault  : std_logic;
    signal debug_trap_vector : std_logic_vector(31 downto 0);
    signal pmmu_busy         : std_logic;

    -- Memory wait state
    signal mem_wait : std_logic := '0';
    signal stall_cooldown : integer range 0 to 3 := 0;
    signal walker_req_prev : std_logic := '0';

    -- Memory: 16K x 16-bit words = 32KB ($0000-$7FFF)
    type mem_type is array(0 to 16383) of std_logic_vector(15 downto 0);

    -- TC=$80C07760: E=1, PS=12(4KB), IS=0, TIA=7, TIB=7, TIC=6, TID=0
    -- CRP: $00000002 $00006000 (DT=10, root table at $6000)
    --
    -- Page table:
    --   Root at $6000: entry 0 -> L1 at $6200 (DT=10)
    --   L1 at $6200:   entry 0 -> L2 at $6400 (DT=10)
    --   L2 at $6400:
    --     [0] $0000 identity (vectors/stack)   $0000-$0FFF
    --     [1] $1000 identity (test code)       $1000-$1FFF
    --     [2] $2000 identity (mapped target)   $2000-$2FFF
    --     [3] $3000 identity (addr err handler)$3000-$3FFF
    --     [4] INVALID (DT=00)                  $4000-$4FFF (unmapped!)
    --     [5] $5000 identity                   $5000-$5FFF
    --     [6] $6000 identity (page tables)     $6000-$6FFF

    function init_mem return mem_type is
        variable m : mem_type := (others => x"4E71");
        variable idx : integer;
    begin
        -----------------------------------------------------------
        -- VECTOR TABLE ($0000-$00FF)
        -----------------------------------------------------------
        -- Vector 0: Initial SSP = $00000800
        m(0) := x"0000"; m(1) := x"0800";
        -- Vector 1: Reset PC = $00001000
        m(2) := x"0000"; m(3) := x"1000";
        -- Vector 2: Bus Error ($08) -> handler at $3100
        m(4) := x"0000"; m(5) := x"3100";
        -- Vector 3: Address Error ($0C) -> handler at $3000
        m(6) := x"0000"; m(7) := x"3000";
        -- Vector 61: stale MC68851-only MMU Bus Error ($F4) -> explicit failure handler
        m(16#F4#/2)     := x"0000";
        m(16#F4#/2 + 1) := x"3200";

        -----------------------------------------------------------
        -- ADDRESS ERROR HANDLER at $3000
        -- Writes $0003 to $1F00 (vector 3 marker), then STOP
        -----------------------------------------------------------
        idx := 16#3000#/2;
        -- MOVE.W #$0003,$1F00.L
        m(idx) := x"33FC"; m(idx+1) := x"0003";
        m(idx+2) := x"0000"; m(idx+3) := x"1F00";
        idx := idx + 4;
        -- STOP #$2700
        m(idx) := x"4E72"; m(idx+1) := x"2700";

        -----------------------------------------------------------
        -- STALE VECTOR-61 HANDLER at $3200
        -- Writes $0061 to $1F00 (unexpected vector 61 marker), then STOP
        -----------------------------------------------------------
        idx := 16#3200#/2;
        -- MOVE.W #$0061,$1F00.L
        m(idx) := x"33FC"; m(idx+1) := x"0061";
        m(idx+2) := x"0000"; m(idx+3) := x"1F00";
        idx := idx + 4;
        -- STOP #$2700
        m(idx) := x"4E72"; m(idx+1) := x"2700";

        -----------------------------------------------------------
        -- BUS ERROR HANDLER at $3100
        -- Writes $0002 to $1F00 (vector 2 marker), then STOP
        -----------------------------------------------------------
        idx := 16#3100#/2;
        -- MOVE.W #$0002,$1F00.L
        m(idx) := x"33FC"; m(idx+1) := x"0002";
        m(idx+2) := x"0000"; m(idx+3) := x"1F00";
        idx := idx + 4;
        -- STOP #$2700
        m(idx) := x"4E72"; m(idx+1) := x"2700";

        -----------------------------------------------------------
        -- MAIN PROGRAM at $1000
        -----------------------------------------------------------
        idx := 16#1000#/2;

        -- Phase 1: Configure PMMU
        -- PMOVE ($1080).W,CRP   ; Load CRP from data at $1080
        -- F038=EA abs.W, 4C00=CRP write
        m(idx) := x"F038"; m(idx+1) := x"4C00"; m(idx+2) := x"1080";
        idx := idx + 3;

        -- PFLUSHA               ; Clear ATC before enabling
        m(idx) := x"F000"; m(idx+1) := x"2400";
        idx := idx + 2;

        -- PMOVE ($1088).W,TC    ; Enable MMU from memory
        m(idx) := x"F038"; m(idx+1) := x"4000"; m(idx+2) := x"1088";
        idx := idx + 3;

        -- NOP padding keeps the odd JMP at the original PC.
        m(idx) := x"4E71"; m(idx+1) := x"4E71";
        idx := idx + 2;

        -- Phase 2: JMP to odd address in MAPPED page ($2001)
        -- This page IS in the page table (L2 entry 2), so walker succeeds.
        -- Then TG68_PC(0)='1' triggers address error (vector 3).
        -- JMP $00002001
        m(idx) := x"4EF9"; m(idx+1) := x"0000"; m(idx+2) := x"2001";
        idx := idx + 3;

        -----------------------------------------------------------
        -- CRP DATA at $1080; TC data at $1088.
        -----------------------------------------------------------
        -- CRP_H = $00000002 (DT=10: valid short table)
        m(2112) := x"0000"; m(2113) := x"0002";
        -- CRP_L = $00006000 (root table at $6000)
        m(2114) := x"0000"; m(2115) := x"6000";
        m(2116) := x"80C0"; m(2117) := x"7760";

        -----------------------------------------------------------
        -- PAGE TABLES
        -----------------------------------------------------------
        -- Root table at $6000 (word addr $3000)
        -- Entry 0: -> L1 at $6200
        m(16#6000#/2)     := x"0000";
        m(16#6000#/2 + 1) := x"6202";  -- DT=10

        -- L1 table at $6200 (word addr $3100)
        -- Entry 0: -> L2 at $6400
        m(16#6200#/2)     := x"0000";
        m(16#6200#/2 + 1) := x"6402";  -- DT=10

        -- L2 table at $6400 (word addr $3200)
        -- Entry 0: page $0000 (vectors/stack)
        m(16#6400#/2)     := x"0000";
        m(16#6400#/2 + 1) := x"0001";  -- DT=01
        -- Entry 1: page $1000 (code)
        m(16#6404#/2)     := x"0000";
        m(16#6404#/2 + 1) := x"1001";  -- DT=01
        -- Entry 2: page $2000 (mapped odd target)
        m(16#6408#/2)     := x"0000";
        m(16#6408#/2 + 1) := x"2001";  -- DT=01
        -- Entry 3: page $3000 (exception handlers)
        m(16#640C#/2)     := x"0000";
        m(16#640C#/2 + 1) := x"3001";  -- DT=01
        -- Entry 4: INVALID (unmapped!)
        m(16#6410#/2)     := x"0000";
        m(16#6410#/2 + 1) := x"0000";  -- DT=00
        -- Entry 5: page $5000
        m(16#6414#/2)     := x"0000";
        m(16#6414#/2 + 1) := x"5001";  -- DT=01
        -- Entry 6: page $6000 (page tables)
        m(16#6418#/2)     := x"0000";
        m(16#6418#/2 + 1) := x"6001";  -- DT=01

        return m;
    end function;

    signal mem : mem_type := init_mem;

    -- Test tracking
    signal test_passed : integer := 0;
    signal test_failed : integer := 0;

    -- Test phase: 0=Test A (JMP $2001, mapped), 1=Test B (JMP $4001, unmapped)
    signal test_phase : integer range 0 to 1 := 0;

begin

    -----------------------------------------------------------
    -- CLOCK
    -----------------------------------------------------------
    clk_gen: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    -----------------------------------------------------------
    -- UUT
    -----------------------------------------------------------
    uut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 2,
            extAddr_Mode   => 2,
            MUL_Mode       => 2,
            DIV_Mode       => 2,
            BitField       => 2,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk              => clk,
            nReset           => nReset,
            clkena_in        => clkena_in,
            data_in          => data_in,
            IPL              => "111",
            IPL_autovector   => '1',
            berr             => '0',
            CPU              => "10",
            addr_out         => addr_out,
            data_write       => data_write,
            nWr              => nWr,
            nUDS             => nUDS,
            nLDS             => nLDS,
            busstate         => busstate,
            longword         => open,
            nResetOut        => open,
            FC               => FC,
            clr_berr         => open,
            skipFetch        => open,
            regin_out        => open,
            CACR_out         => open,
            VBR_out          => open,
            cache_inv_req    => open,
            cache_op_scope   => open,
            cache_op_cache   => open,
            cache_op_addr    => open,
            cacr_ie          => open,
            cacr_de          => open,
            cacr_ifreeze     => open,
            cacr_dfreeze     => open,
            cacr_ibe         => open,
            cacr_dbe         => open,
            cacr_wa          => open,
            pmmu_reg_we      => open,
            pmmu_reg_re      => open,
            pmmu_reg_sel     => open,
            pmmu_reg_wdat    => open,
            pmmu_reg_part    => open,
            pmmu_addr_log    => pmmu_addr_log,
            pmmu_addr_phys   => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode     => open,
            debug_preSVmode  => open,
            debug_FlagsSR_S  => open,
            debug_changeMode => open,
            debug_setopcode  => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_state      => debug_state,
            debug_setstate   => open,
            debug_last_opc_read => open,
            debug_data_read  => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC    => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout     => open,
            debug_decodeOPC  => open,
            debug_brief      => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw  => debug_clkena_lw,
            debug_regfile_d0 => open,
            debug_regfile_a0 => open,
            debug_opcode     => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_fline_context_valid => open,
            debug_trap_1111  => open,
            debug_trapmake   => open,
            debug_pmmu_brief => open,
            debug_use_base   => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA     => open,
            debug_last_data_read => open,
            debug_last_opc_pc => open,
            debug_getbrief => open,
            debug_get_2ndopc => open,
            debug_fline_brief_pending => open,
            debug_fline_opcode_pc => open,
            debug_exe_PC => open,
            debug_memaddr_delta_rega => open,
            debug_memaddr_delta_regb => open,
            debug_addsub_q => open,
            debug_memmaskmux => open,
            debug_fline_opcode_latch => open,
            debug_pmmu_ea_mode_latched => open,
            debug_exec_direct_delta => open,
            debug_exec_directPC => open,
            debug_exec_mem_addsub => open,
            debug_set_addrlong => open,
            debug_mdelta_src => open,
            debug_pc_brw => open,
            debug_pc_word => open,
            debug_regfile_d1 => open,
            debug_regfile_d2 => open,
            debug_regfile_d3 => open,
            debug_regfile_d4 => open,
            debug_regfile_d5 => open,
            debug_regfile_d6 => open,
            debug_regfile_d7 => open,
            debug_regfile_a1 => open,
            debug_regfile_a2 => open,
            debug_regfile_a3 => open,
            debug_regfile_a4 => open,
            debug_regfile_a5 => open,
            debug_regfile_a6 => open,
            debug_regfile_a7 => open,
            debug_regfile_we => open,
            debug_regfile_waddr => open,
            debug_regfile_wdata => open,
            debug_trap_illegal => open,
            debug_trap_priv => open,
            debug_trap_addr_error => debug_trap_addr_error,
            debug_trap_berr => debug_trap_berr,
            debug_trap_mmu_berr => debug_trap_mmu_berr,
            debug_trap_vector => debug_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy  => pmmu_busy,
            debug_micro_state => debug_micro_state,
            debug_next_micro_state => open,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => debug_make_berr,
            debug_pmmu_fault => debug_pmmu_fault
        );

    -----------------------------------------------------------
    -- MEMORY READ (uses physical address from PMMU)
    -----------------------------------------------------------
    mem_read: process(pmmu_addr_phys, mem, test_phase)
        variable word_idx : integer;
    begin
        if is_x(pmmu_addr_phys) then
            data_in <= x"4E71";
        elsif unsigned(pmmu_addr_phys) < x"00008000" then
            word_idx := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
            data_in <= mem(word_idx);
            -- Test B overlay: change JMP target low word from $2001 to $4001
            -- JMP instruction at byte $1014 (word $80A): $4EF9 $0000 $2001
            -- Low word of address is at word index $80C (byte $1018)
            if test_phase = 1 and word_idx = 16#80C# then
                data_in <= x"4001";
            end if;
        else
            data_in <= x"4E71";
        end if;
    end process;

    -----------------------------------------------------------
    -- MEMORY WRITE + WALKER RESPONSE
    -----------------------------------------------------------
    mem_and_walker: process(clk)
        variable phys_word   : integer;
        variable walker_word : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' and clkena_in = '1' then
                if not is_x(pmmu_addr_phys) and
                   unsigned(pmmu_addr_phys) < x"00008000" then
                    phys_word := to_integer(unsigned(pmmu_addr_phys(14 downto 1)));
                    mem(phys_word) <= data_write;
                end if;
            end if;

            if pmmu_walker_req = '1' then
                if not is_x(pmmu_walker_addr) and
                   unsigned(pmmu_walker_addr) < x"00008000" then
                    walker_word := to_integer(unsigned(pmmu_walker_addr(14 downto 1)));
                    if pmmu_walker_we = '1' then
                        mem(walker_word)     <= pmmu_walker_wdat(31 downto 16);
                        mem(walker_word + 1) <= pmmu_walker_wdat(15 downto 0);
                    else
                        pmmu_walker_data <= mem(walker_word) & mem(walker_word + 1);
                    end if;
                else
                    pmmu_walker_data <= x"00000000";
                end if;
                pmmu_walker_ack <= '1';
            else
                pmmu_walker_ack <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------
    -- MEMORY WAIT STATE (simulates real hardware latency)
    -----------------------------------------------------------
    mem_wait_gen: process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '0' then
                mem_wait <= '0';
            elsif clkena_in = '1' then
                mem_wait <= '1';
            else
                mem_wait <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------
    -- WALKER STALL COOLDOWN
    -----------------------------------------------------------
    stall_control: process(clk)
    begin
        if rising_edge(clk) then
            walker_req_prev <= pmmu_walker_req;
            if walker_req_prev = '1' and pmmu_walker_req = '0' then
                stall_cooldown <= 2;
            elsif stall_cooldown > 0 then
                stall_cooldown <= stall_cooldown - 1;
            end if;
        end if;
    end process;

    -----------------------------------------------------------
    -- CLKENA_IN GATING (matches cpu_wrapper behavior)
    -----------------------------------------------------------
    clkena_in <= '0' when (pmmu_walker_req = '1'
                           or (pmmu_busy = '1' and debug_pmmu_fault = '0')
                           or stall_cooldown > 0 or mem_wait = '1') else '1';

    -----------------------------------------------------------
    -- TEST PROCESS
    -----------------------------------------------------------
    test_proc: process
        variable saw_vec3_read  : boolean;
        variable saw_vec2_read  : boolean;
        variable saw_vec61_read : boolean;
        variable saw_handler_3000 : boolean;
        variable saw_handler_3100 : boolean;
        variable saw_handler_3200 : boolean;
    begin
        report "==========================================================";
        report "Address Error with PMMU Enabled - cpu_wrapper clkena_in gating";
        report "==========================================================";
        report "";

        -- ==========================================================
        -- TEST A: JMP to odd address in MAPPED page ($2001)
        -- Page $2000 is valid in page table (L2 entry 2, DT=01).
        -- Walker should succeed. Then TG68_PC(0)='1' triggers addr error.
        -- Expected: vector 3 (address error)
        -- ==========================================================
        report "--- Test A: JMP to odd addr in MAPPED page ($2001) ---";

        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        saw_vec3_read  := false;
        saw_vec2_read  := false;
        saw_vec61_read := false;
        saw_handler_3000 := false;
        saw_handler_3100 := false;
        saw_handler_3200 := false;

        for i in 1 to 20000 loop
            wait until rising_edge(clk);

            -- Watch for vector table reads
            if busstate = "10" then
                if to_integer(unsigned(addr_out)) = 16#0C# then
                    saw_vec3_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 3 read (address error) at $0C";
                end if;
                if to_integer(unsigned(addr_out)) = 16#08# then
                    saw_vec2_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 2 read (bus error) at $08";
                end if;
                if to_integer(unsigned(addr_out)) = 16#F4# then
                    saw_vec61_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 61 read (MMU bus error) at $F4";
                end if;
            end if;

            -- Watch for handler execution
            if busstate = "00" then
                if to_integer(unsigned(addr_out)) = 16#3000# then
                    saw_handler_3000 := true;
                    report "  [cycle " & integer'image(i) & "] Address error handler at $3000 reached";
                    exit;
                end if;
                if to_integer(unsigned(addr_out)) = 16#3100# then
                    saw_handler_3100 := true;
                    report "  [cycle " & integer'image(i) & "] Bus error handler at $3100 reached";
                    exit;
                end if;
                if to_integer(unsigned(addr_out)) = 16#3200# then
                    saw_handler_3200 := true;
                    report "  [cycle " & integer'image(i) & "] Stale vector-61 handler at $3200 reached";
                    exit;
                end if;
            end if;
        end loop;

        if saw_vec3_read and saw_handler_3000 then
            report "PASS: Test A - address error (vector 3) for odd addr in mapped page" severity note;
            test_passed <= test_passed + 1;
        elsif saw_vec2_read or saw_vec61_read or saw_handler_3100 or saw_handler_3200 then
            report "FAIL: Test A - got BUS ERROR instead of address error for mapped page" severity error;
            report "  saw_vec2=" & boolean'image(saw_vec2_read) &
                   " saw_vec61=" & boolean'image(saw_vec61_read) &
                   " saw_vec3=" & boolean'image(saw_vec3_read) &
                   " handler3100=" & boolean'image(saw_handler_3100) &
                   " handler3200=" & boolean'image(saw_handler_3200);
            test_failed <= test_failed + 1;
        else
            report "FAIL: Test A - timeout, no exception detected" severity error;
            test_failed <= test_failed + 1;
        end if;

        wait for CLK_PERIOD * 20;

        -- ==========================================================
        -- TEST B: JMP to odd address in UNMAPPED page ($4001)
        -- Page $4000 is INVALID in page table (L2 entry 4, DT=00).
        -- Walker will fault. BUG: make_berr overrides trap_addr_error.
        -- Expected: vector 3 (address error)
        -- Actual (BUG): vector 2 bus error, or on older stale MMU-vector paths vector 61
        -- ==========================================================
        report "";
        report "--- Test B: JMP to odd addr in UNMAPPED page ($4001) ---";

        -- Switch to Test B: overlay changes JMP target from $2001 to $4001
        test_phase <= 1;
        wait for CLK_PERIOD;

        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        saw_vec3_read  := false;
        saw_vec2_read  := false;
        saw_vec61_read := false;
        saw_handler_3000 := false;
        saw_handler_3100 := false;
        saw_handler_3200 := false;

        for i in 1 to 20000 loop
            wait until rising_edge(clk);

            if busstate = "10" then
                if to_integer(unsigned(addr_out)) = 16#0C# then
                    saw_vec3_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 3 read (address error) at $0C";
                end if;
                if to_integer(unsigned(addr_out)) = 16#08# then
                    saw_vec2_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 2 read (bus error) at $08";
                end if;
                if to_integer(unsigned(addr_out)) = 16#F4# then
                    saw_vec61_read := true;
                    report "  [cycle " & integer'image(i) & "] Vector 61 read (MMU bus error) at $F4";
                end if;
            end if;

            if busstate = "00" then
                if to_integer(unsigned(addr_out)) = 16#3000# then
                    saw_handler_3000 := true;
                    report "  [cycle " & integer'image(i) & "] Address error handler at $3000 reached";
                    exit;
                end if;
                if to_integer(unsigned(addr_out)) = 16#3100# then
                    saw_handler_3100 := true;
                    report "  [cycle " & integer'image(i) & "] Bus error handler at $3100 reached";
                    exit;
                end if;
                if to_integer(unsigned(addr_out)) = 16#3200# then
                    saw_handler_3200 := true;
                    report "  [cycle " & integer'image(i) & "] Stale vector-61 handler at $3200 reached";
                    exit;
                end if;
            end if;

            -- Also detect CPU halt (double fault)
            if debug_TG68_PC = x"FFFFFFFF" or debug_TG68_PC = x"00000000" then
                -- Might be halted
                null;
            end if;
        end loop;

        if saw_vec3_read and saw_handler_3000 then
            report "PASS: Test B - address error (vector 3) for odd addr in unmapped page" severity note;
            test_passed <= test_passed + 1;
        elsif saw_vec2_read or saw_vec61_read or saw_handler_3100 or saw_handler_3200 then
            report "FAIL: Test B - got BUS ERROR instead of address error for unmapped page" severity error;
            report "  saw_vec2=" & boolean'image(saw_vec2_read) &
                   " saw_vec61=" & boolean'image(saw_vec61_read) &
                   " saw_vec3=" & boolean'image(saw_vec3_read) &
                   " handler3100=" & boolean'image(saw_handler_3100) &
                   " handler3200=" & boolean'image(saw_handler_3200);
            report "  ROOT CAUSE: pmmu_req='1' when state='00' with odd PC causes";
            report "  unnecessary PMMU translation. Walker faults on unmapped page,";
            report "  make_berr overrides trap_addr_error at setinterrupt priority chain.";
            test_failed <= test_failed + 1;
        else
            report "FAIL: Test B - timeout (CPU may be halted from double fault)" severity error;
            test_failed <= test_failed + 1;
        end if;

        -- ==========================================================
        -- SUMMARY
        -- ==========================================================
        report "";
        report "==========================================================";
        report "TEST SUMMARY";
        report "==========================================================";
        wait for CLK_PERIOD * 5;
        report "  PASSED: " & integer'image(test_passed);
        report "  FAILED: " & integer'image(test_failed);
        if test_failed = 0 then
            report "  *** ALL TESTS PASSED ***" severity note;
        else
            report "  *** SOME TESTS FAILED ***" severity error;
        end if;
        report "==========================================================";

        test_done <= true;
        wait;
    end process;

end architecture;
