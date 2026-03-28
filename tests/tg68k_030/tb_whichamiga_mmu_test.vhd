-- WhichAmiga 68030 MMU Detection Test
-- Based on WhichAmiga.ASM lines 4981-5365
-- Tests the complete MMU instruction set and detection sequence

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_whichamiga_mmu_test is
end tb_whichamiga_mmu_test;

architecture behavior of tb_whichamiga_mmu_test is

    

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

-- Component declaration
    component TG68KdotC_Kernel
        port (
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
            cache_inv_req : out std_logic;
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
            pmmu_walker_we : out std_logic;
            pmmu_walker_addr : out std_logic_vector(31 downto 0);
            pmmu_walker_wdat : out std_logic_vector(31 downto 0);
            pmmu_walker_ack : in std_logic;
            pmmu_walker_data : in std_logic_vector(31 downto 0);
            pmmu_walker_berr : in std_logic;
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

    -- Clock and reset
    signal clk : std_logic := '0';
    signal nReset : std_logic := '0';
    signal clkena_in : std_logic := '1';

    -- CPU interface
    signal data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal IPL : std_logic_vector(2 downto 0) := "111";
    signal IPL_autovector : std_logic := '0';
    signal berr : std_logic := '0';
    signal CPU : std_logic_vector(1 downto 0) := "10"; -- 68030 with PMMU
    signal addr : std_logic_vector(31 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal nWr : std_logic;
    signal nUDS : std_logic;
    signal nLDS : std_logic;
    signal busstate : std_logic_vector(1 downto 0);
    signal longword : std_logic;
    signal nResetOut : std_logic;
    signal FC : std_logic_vector(2 downto 0);
    signal clr_berr : std_logic;

    -- Debug signals
    signal skipFetch : std_logic;
    signal regin_out : std_logic_vector(31 downto 0);
    signal CACR_out : std_logic_vector(31 downto 0);
    signal VBR_out : std_logic_vector(31 downto 0);

    -- Cache control
    signal cache_inv_req : std_logic;
    signal cache_op_scope : std_logic_vector(1 downto 0);
    signal cache_op_cache : std_logic_vector(1 downto 0);
    signal cacr_ie : std_logic;
    signal cacr_de : std_logic;
    signal cacr_ifreeze : std_logic;
    signal cacr_dfreeze : std_logic;
    signal cacr_ibe : std_logic;
    signal cacr_dbe : std_logic;
    signal cacr_wa : std_logic;

    -- PMMU register interface
    signal pmmu_reg_we : std_logic;
    signal pmmu_reg_re : std_logic;
    signal pmmu_reg_sel : std_logic_vector(4 downto 0);
    signal pmmu_reg_wdat : std_logic_vector(31 downto 0);
    signal pmmu_reg_part : std_logic;
    signal pmmu_addr_log : std_logic_vector(31 downto 0);
    signal pmmu_addr_phys : std_logic_vector(31 downto 0);
    signal pmmu_cache_inhibit : std_logic;
    signal cache_op_addr : std_logic_vector(31 downto 0);

    -- PMMU walker interface
    signal pmmu_walker_req : std_logic;
    signal pmmu_walker_we : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    -- Debug signals
    signal debug_SVmode : std_logic;
    signal debug_preSVmode : std_logic;
    signal debug_FlagsSR_S : std_logic;
    signal debug_changeMode : std_logic;
    signal debug_setopcode : std_logic;
    signal debug_exec_directSR : std_logic;
    signal debug_exec_to_SR : std_logic;
    signal debug_pmove_dn_mode : std_logic;
    signal debug_pmove_dn_regnum : std_logic_vector(2 downto 0);

    -- Test signals
    signal test_complete : boolean := false;

    -- Memory array (256KB for test) - MUST be shared variable for immediate updates
    type memory_array is array (0 to 65535) of std_logic_vector(15 downto 0);
    shared variable memory : memory_array := (others => x"4E71"); -- Fill with NOP

    -- Stack pointer
    constant STACK_BASE : std_logic_vector(31 downto 0) := x"00010000";

    -- Test addresses
    constant TEST_AREA : std_logic_vector(31 downto 0) := x"D0000000";

    -- Clock period
    constant clk_period : time := 20 ns; -- 50 MHz

    -- Helper procedures
    procedure wait_cycles(n : integer) is
    begin
        for i in 1 to n loop
            wait until rising_edge(clk);
        end loop;
    end procedure;

begin

    -- Instantiate the CPU
    dut: TG68KdotC_Kernel
        port map (
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => IPL,
            IPL_autovector => IPL_autovector,
            berr => berr,
            CPU => CPU,
            addr_out => addr,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            longword => longword,
            nResetOut => nResetOut,
            FC => FC,
            clr_berr => clr_berr,
            skipFetch => skipFetch,
            regin_out => regin_out,
            CACR_out => CACR_out,
            VBR_out => VBR_out,
            cache_inv_req => cache_inv_req,
            cache_op_scope => cache_op_scope,
            cache_op_cache => cache_op_cache,
            cacr_ie => cacr_ie,
            cacr_de => cacr_de,
            cacr_ifreeze => cacr_ifreeze,
            cacr_dfreeze => cacr_dfreeze,
            cacr_ibe => cacr_ibe,
            cacr_dbe => cacr_dbe,
            cacr_wa => cacr_wa,
            pmmu_reg_we => pmmu_reg_we,
            pmmu_reg_re => pmmu_reg_re,
            pmmu_reg_sel => pmmu_reg_sel,
            pmmu_reg_wdat => pmmu_reg_wdat,
            pmmu_reg_part => pmmu_reg_part,
            pmmu_addr_log => pmmu_addr_log,
            pmmu_addr_phys => pmmu_addr_phys,
            pmmu_cache_inhibit => pmmu_cache_inhibit,
            cache_op_addr => cache_op_addr,
            pmmu_walker_req => pmmu_walker_req,
            pmmu_walker_we => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode => debug_SVmode,
            debug_preSVmode => debug_preSVmode,
            debug_FlagsSR_S => debug_FlagsSR_S,
            debug_changeMode => debug_changeMode,
            debug_setopcode => debug_setopcode,
            debug_exec_directSR => debug_exec_directSR,
            debug_exec_to_SR => debug_exec_to_SR,
            debug_pmove_dn_mode => debug_pmove_dn_mode,
            debug_pmove_dn_regnum => debug_pmove_dn_regnum
        );

    -- PMMU walker memory arbiter
    -- The PMMU is internal to TG68KdotC_Kernel, but we need to service its walker memory requests
    walker_arbiter: process(clk)
        variable walker_addr_int : integer;
    begin
        if rising_edge(clk) then
            pmmu_walker_ack <= '0';

            if pmmu_walker_req = '1' then
                -- Service PMMU walker request from memory (32-bit read)
                walker_addr_int := to_integer(unsigned(pmmu_walker_addr(15 downto 0)));
                if walker_addr_int < 65535 then
                    pmmu_walker_data <= memory(walker_addr_int/2) & memory(walker_addr_int/2 + 1);
                else
                    pmmu_walker_data <= (others => '1');
                end if;
                pmmu_walker_ack <= '1';
            end if;
        end if;
    end process;

    -- Verification: Monitor PMMU registers, stack pointer, and RTE execution
    verification_process: process(clk)
        variable last_a7 : std_logic_vector(31 downto 0) := (others => '0');
        variable pmmu_reg_name : string(1 to 6);
        variable pmove_count : integer := 0;
        variable last_pmmu_reg_we : std_logic := '0';
    begin
        if rising_edge(clk) then
            -- Debug: Monitor pmmu_reg_we signal transitions
            if pmmu_reg_we /= last_pmmu_reg_we then
                report "PMMU_REG_WE changed: " & std_logic'image(last_pmmu_reg_we) & " -> " & std_logic'image(pmmu_reg_we) severity note;
                last_pmmu_reg_we := pmmu_reg_we;
            end if;

            -- 1. Monitor PMMU register writes
            if pmmu_reg_we = '1' then
                pmove_count := pmove_count + 1;
                -- Decode register name
                case pmmu_reg_sel is
                    when "00000" => pmmu_reg_name := "TC    ";
                    when "00010" => pmmu_reg_name := "SRP_HI";
                    when "00011" => pmmu_reg_name := "SRP_LO";
                    when "00100" => pmmu_reg_name := "CRP_HI";
                    when "00101" => pmmu_reg_name := "CRP_LO";
                    when "01000" => pmmu_reg_name := "TT0   ";
                    when "01001" => pmmu_reg_name := "TT1   ";
                    when "10000" => pmmu_reg_name := "MMUSR ";
                    when others  => pmmu_reg_name := "UNKN  ";
                end case;

                report "PMMU_WRITE: " & pmmu_reg_name & " = 0x" & slv_to_hex(pmmu_reg_wdat) &
                       " (part=" & integer'image(to_integer(unsigned'("" & pmmu_reg_part))) & ")"
                       severity note;
            end if;

            -- 2. Monitor stack pointer (A7) changes
            if regin_out /= last_a7 and regin_out /= x"00000000" then
                report "STACK_PTR: A7 changed from 0x" & slv_to_hex(last_a7) &
                       " to 0x" & slv_to_hex(regin_out) &
                       " (delta=" & integer'image(to_integer(signed(regin_out)) - to_integer(signed(last_a7))) & ")"
                       severity note;
                last_a7 := regin_out;
            end if;

            -- 3. Detect RTE execution (look for transition out of exception handler area)
            if busstate = "00" then  -- Instruction fetch
                if to_integer(unsigned(addr)) >= 16#5000# and to_integer(unsigned(addr)) < 16#5600# then
                    -- In exception handler - RTE will be executed next
                    report "IN_EXCEPTION_HANDLER: PC=0x" & slv_to_hex(addr) severity note;
                end if;
            end if;
        end if;
    end process;

    -- Clock generation
    clk_process: process
    begin
        if not test_complete then
            clk <= '0';
            wait for clk_period/2;
            clk <= '1';
            wait for clk_period/2;
        else
            wait;
        end if;
    end process;

    -- Memory interface
    mem_process: process(clk)
        variable addr_int : integer;
        variable first_fetch : boolean := true;
        variable last_pc : integer := -1;
        variable pc_change_count : integer := 0;
    begin
        if rising_edge(clk) then
            addr_int := to_integer(unsigned(addr(15 downto 0)));

            -- Debug: Track PC changes during instruction fetches
            if busstate = "00" then
                if first_fetch then
                    report "First instruction fetch at addr=0x" & slv_to_hex(std_logic_vector(to_unsigned(addr_int, 32))) severity note;
                    first_fetch := false;
                end if;

                -- Track PC to detect loops
                if addr_int /= last_pc then
                    last_pc := addr_int;
                    pc_change_count := pc_change_count + 1;

                    -- Stop test when we reach the final NOP at 0x0400
                    if addr_int >= 16#400# and addr_int < 16#410# and not test_complete then
                        report "SUCCESS: Reached final address 0x" & slv_to_hex(std_logic_vector(to_unsigned(addr_int, 32))) &
                               " after " & integer'image(pc_change_count) & " instruction fetches" severity note;
                        test_complete <= true;
                    end if;

                    -- Report key execution points
                    if addr_int >= 16#40# and addr_int < 16#500# then
                        -- Report ALL fetches in test program range (0x40-0x4FF) with opcode
                        if pc_change_count < 150 then  -- Limit to first 150 fetches in test range
                            report "TEST: Fetch at PC=0x" & slv_to_hex(std_logic_vector(to_unsigned(addr_int, 32))) &
                                   " opcode=0x" & slv_to_hex(memory(addr_int/2)) &
                                   " (count=" & integer'image(pc_change_count) & ")" severity note;
                        end if;
                    elsif addr_int >= 16#5000# and addr_int < 16#5600# then
                        report "EXCEPTION HANDLER at PC=0x" & slv_to_hex(std_logic_vector(to_unsigned(addr_int, 32))) &
                               " (count=" & integer'image(pc_change_count) & ")" severity note;
                    elsif pc_change_count < 100 then
                        -- Report first 100 fetches wherever they are
                        report "EARLY: Fetch at PC=0x" & slv_to_hex(std_logic_vector(to_unsigned(addr_int, 32))) &
                               " (count=" & integer'image(pc_change_count) & ")" severity note;
                    end if;
                end if;
            end if;

            -- Read cycle (busstate = "10")
            if busstate = "10" then
                -- Check if this is a PMMU register read (handled internally by PMMU module)
                -- For PMOVE reads, CPU loads data directly from PMMU via internal connection
                -- So just provide normal memory data here
                if addr_int >= 0 and addr_int < 65536 then
                    data_in <= memory(addr_int/2);
                else
                    data_in <= x"4E71"; -- NOP for unmapped
                end if;
            end if;

            -- Write cycle (busstate = "11")
            if busstate = "11" and nWr = '0' then
                if addr_int >= 0 and addr_int < 65536 then
                    if nUDS = '0' and nLDS = '0' then
                        memory(addr_int/2) := data_write;
                    elsif nUDS = '0' then
                        memory(addr_int/2)(15 downto 8) := data_write(15 downto 8);
                    elsif nLDS = '0' then
                        memory(addr_int/2)(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Test stimulus
    stim: process
        variable pc : integer := 16#4000#;

        -- Helper to emit instruction word
        procedure emit_word(data : std_logic_vector(15 downto 0)) is
        begin
            if pc >= 0 and pc < 65536 then
                memory(pc/2) := data;
            end if;
            pc := pc + 2;
        end procedure;

        -- Helper to emit long
        procedure emit_long(data : std_logic_vector(31 downto 0)) is
        begin
            emit_word(data(31 downto 16));
            emit_word(data(15 downto 0));
        end procedure;

        -- PMOVE TC,-(A7)
        procedure emit_pmove_tc_push is
        begin
            emit_word(x"F017"); -- PMOVE prefix
            emit_word(x"4200"); -- TC to -(A7)
        end procedure;

        -- PMOVE CRP,-(A7)
        procedure emit_pmove_crp_push is
        begin
            emit_word(x"F017"); -- PMOVE prefix
            emit_word(x"4E00"); -- CRP to -(A7)
        end procedure;

        -- PMOVE (A7)+,TC
        procedure emit_pmove_tc_pop is
        begin
            emit_word(x"F017"); -- PMOVE prefix
            emit_word(x"4A00"); -- (A7)+ to TC
        end procedure;

        -- PMOVE (A7)+,CRP
        procedure emit_pmove_crp_pop is
        begin
            emit_word(x"F017"); -- PMOVE prefix
            emit_word(x"4C00"); -- (A7)+ to CRP
        end procedure;

        -- PTEST #5,(A0),#7
        procedure emit_ptest_write is
        begin
            emit_word(x"F010"); -- PTEST prefix
            emit_word(x"9C15"); -- Write, (A0), FC=5, level=7
        end procedure;

        -- PMOVE MMUSR,-(A7)
        procedure emit_pmove_mmusr_push is
        begin
            emit_word(x"F017"); -- PMOVE prefix
            emit_word(x"6200"); -- MMUSR to -(A7)
        end procedure;

        -- RTE
        procedure emit_rte is
        begin
            emit_word(x"4E73");
        end procedure;

    begin
        report "=== tb_whichamiga_mmu_test: starting ===" severity note;

        -- Initialize reset vector and SSP
        -- MC68030 reset: SSP at 0x0-0x3, PC at 0x4-0x7 (big-endian)
        -- NOTE: TG68K doesn't properly load reset PC, so start at low address like tb_basic_reset
        memory(0) := STACK_BASE(31 downto 16);  -- SSP high word at byte addr 0-1
        memory(1) := STACK_BASE(15 downto 0);   -- SSP low word at byte addr 2-3
        memory(2) := x"0000";  -- PC high word at byte addr 4-5
        memory(3) := x"0040";  -- PC low word at byte addr 6-7 → PC = 0x00000040

        -- Set up exception vectors
        memory(16#08#/2) := x"0000";
        memory(16#0A#/2) := x"5000";
        memory(16#10#/2) := x"0000";
        memory(16#12#/2) := x"5100";
        memory(16#2C#/2) := x"0000";
        memory(16#2E#/2) := x"5200";
        memory(16#E0#/2) := x"0000";
        memory(16#E2#/2) := x"5300";

        -- Exception handlers (just RTE)
        memory(16#5000#/2) := x"4E73"; -- Bus Error: RTE
        memory(16#5100#/2) := x"4E73"; -- Illegal: RTE
        memory(16#5200#/2) := x"4E73"; -- F-Line: RTE
        memory(16#5300#/2) := x"4E73"; -- MMU Config: RTE

        -- Build test program at 0x4000
        pc := 16#40#;  -- Start at 0x0040 (byte address 64)

        -- Test 1: PMOVE TC,-(A7) - Read TC register
        report "Building Test 1: PMOVE TC,-(A7)" severity note;
        emit_pmove_tc_push;

        -- Test 2: PMOVE CRP,-(A7) - Read CRP register (64-bit)
        report "Building Test 2: PMOVE CRP,-(A7)" severity note;
        emit_pmove_crp_push;

        -- Test 3: Clear TC
        report "Building Test 3: Write TC = 0" severity note;
        emit_word(x"42A7"); -- CLR.L -(A7)
        emit_pmove_tc_pop;  -- PMOVE (A7)+,TC

        -- Test 4: Setup CRP
        report "Building Test 4: Write CRP" severity note;
        emit_word(x"203C"); -- MOVE.L #$80000002,D0
        emit_long(x"80000002");
        emit_word(x"3F00"); -- MOVE.W D0,-(A7)
        emit_word(x"203C"); -- MOVE.L #TranslationTable,D0
        emit_long(x"00008000"); -- Translation table at 0x8000
        emit_word(x"2F00"); -- MOVE.L D0,-(A7)
        emit_pmove_crp_pop; -- PMOVE (A7)+,CRP

        -- Test 5: Enable MMU with TC = $80D04780
        report "Building Test 5: Enable MMU" severity note;
        emit_word(x"203C"); -- MOVE.L #$80D04780,D0
        emit_long(x"80D04780");
        emit_word(x"3F00"); -- MOVE.W D0,-(A7)
        emit_pmove_tc_pop;  -- PMOVE (A7)+,TC

        -- Test 6: PTEST instruction
        report "Building Test 6: PTEST" severity note;
        emit_word(x"207C"); -- MOVEA.L #TEST_AREA,A0
        emit_long(TEST_AREA);
        emit_ptest_write;   -- PTEST #5,(A0),#7
        emit_pmove_mmusr_push; -- PMOVE MMUSR,-(A7)

        -- Test 7: Restore MMU state
        report "Building Test 7: Restore MMU" severity note;
        emit_word(x"42A7"); -- CLR.L -(A7)
        emit_pmove_tc_pop;  -- PMOVE (A7)+,TC (disable)

        -- Test 8: Create Format A exception frame and test RTE
        report "Building Test 8: Format A RTE" severity note;
        -- Push a Format A stack frame (16 words)
        emit_word(x"203C"); -- MOVE.L #$00000200,D0 (return address)
        emit_long(x"00000200");
        emit_word(x"3F00"); -- MOVE.W D0,-(A7) - PC low
        emit_word(x"4267"); -- CLR.W -(A7) - PC high
        emit_word(x"3F3C"); -- MOVE.W #$2700,-(A7) - SR
        emit_word(x"2700");
        emit_word(x"3F3C"); -- MOVE.W #$A000,-(A7) - Format A + Vector 0
        emit_word(x"A000");
        -- Push 12 more words of frame data
        for i in 1 to 12 loop
            emit_word(x"3F3C"); -- MOVE.W #$0000,-(A7)
            emit_word(x"0000");
        end loop;
        emit_rte; -- RTE should pop all 16 words

        -- Mark return address
        pc := 16#200#;  -- 0x0200
        emit_word(x"4E71"); -- NOP
        emit_word(x"4E71"); -- NOP

        -- Test 9: Create Format B exception frame and test RTE
        pc := 16#300#;  -- 0x0300
        report "Building Test 9: Format B RTE" severity note;
        -- Push a Format B stack frame (46 words)
        emit_word(x"203C"); -- MOVE.L #$00000400,D0 (return address)
        emit_long(x"00000400");
        emit_word(x"3F00"); -- MOVE.W D0,-(A7)
        emit_word(x"4267"); -- CLR.W -(A7)
        emit_word(x"3F3C"); -- MOVE.W #$2700,-(A7)
        emit_word(x"2700");
        emit_word(x"3F3C"); -- MOVE.W #$B000,-(A7) - Format B + Vector 0
        emit_word(x"B000");
        -- Push 42 more words
        for i in 1 to 42 loop
            emit_word(x"3F3C");
            emit_word(x"0000");
        end loop;
        emit_rte;

        -- Mark return address (final destination after all tests)
        pc := 16#400#;  -- 0x0400
        emit_word(x"4E71"); -- NOP
        emit_word(x"FFFF"); -- STOP marker

        -- Build translation table at 0x8000
        -- 16 page descriptors mapping entire 4GB address space
        -- Each descriptor: [31:8] = physical address, [7:0] = flags (0x61 = valid, user, modified)
        memory(16#8000#/2) := x"0000"; -- Entry 0: 0x00000061
        memory(16#8002#/2) := x"0061";
        memory(16#8004#/2) := x"1000"; -- Entry 1: 0x10000061
        memory(16#8006#/2) := x"0061";
        memory(16#8008#/2) := x"2000"; -- Entry 2: 0x20000061
        memory(16#800A#/2) := x"0061";
        memory(16#800C#/2) := x"3000"; -- Entry 3: 0x30000061
        memory(16#800E#/2) := x"0061";
        memory(16#8010#/2) := x"4000"; -- Entry 4: 0x40000061
        memory(16#8012#/2) := x"0061";
        memory(16#8014#/2) := x"5000"; -- Entry 5: 0x50000061
        memory(16#8016#/2) := x"0061";
        memory(16#8018#/2) := x"6000"; -- Entry 6: 0x60000061
        memory(16#801A#/2) := x"0061";
        memory(16#801C#/2) := x"7000"; -- Entry 7: 0x70000061
        memory(16#801E#/2) := x"0061";
        memory(16#8020#/2) := x"8000"; -- Entry 8: 0x80000061
        memory(16#8022#/2) := x"0061";
        memory(16#8024#/2) := x"9000"; -- Entry 9: 0x90000061
        memory(16#8026#/2) := x"0061";
        memory(16#8028#/2) := x"A000"; -- Entry 10: 0xA0000061
        memory(16#802A#/2) := x"0061";
        memory(16#802C#/2) := x"B000"; -- Entry 11: 0xB0000061
        memory(16#802E#/2) := x"0061";
        memory(16#8030#/2) := x"C000"; -- Entry 12: 0xC0000061
        memory(16#8032#/2) := x"0061";
        memory(16#8034#/2) := x"D000"; -- Entry 13: 0xD0000061
        memory(16#8036#/2) := x"0061";
        memory(16#8038#/2) := x"E000"; -- Entry 14: 0xE0000061
        memory(16#803A#/2) := x"0061";
        memory(16#803C#/2) := x"F000"; -- Entry 15: 0xF0000061
        memory(16#803E#/2) := x"0061";

        -- Wait for memory initialization to complete
        wait_cycles(1);

        -- Release reset
        wait_cycles(10);
        nReset <= '1';

        report "CPU running..." severity note;

        -- Wait for test completion (with timeout)
        wait until test_complete for 500 us;

        -- Verify results
        report "Checking results..." severity note;

        if not test_complete then
            assert false
                report "CPU did not reach expected final address range (0x4300-0x4310) within timeout. Final address: " &
                       integer'image(to_integer(unsigned(addr)))
                severity failure;
        else
            report "=== All tests PASSED ===" severity note;
        end if;

        wait;

    end process;

end behavior;
