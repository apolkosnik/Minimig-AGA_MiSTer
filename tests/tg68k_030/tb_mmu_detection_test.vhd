-- tb_mmu_detection_test.vhd
-- Tests the exact PMOVE sequence from DiagROM MMU detection code:
--   pmove.l tc,(sp)        -> $F017 $4200
--   dc.w $F017,$4E00       -> pmove.q crp,(sp) (MMU to memory)
--   dc.w $F017,$4C00       -> pmove.q (sp),crp (memory to MMU)
-- This sequence tests PC increment for (SP) addressing mode

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_mmu_detection_test is
end entity;

architecture behavioral of tb_mmu_detection_test is

    

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
    signal nReset       : std_logic := '0';
    signal clkena_in    : std_logic := '1';

    signal data_in      : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write   : std_logic_vector(15 downto 0);
    signal addr_out     : std_logic_vector(31 downto 0);
    signal busstate     : std_logic_vector(1 downto 0);
    signal nWr          : std_logic;
    signal nUDS         : std_logic;
    signal nLDS         : std_logic;
    signal FC           : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    signal test_done    : boolean := false;

    -- Instruction tracking
    signal instruction_count : integer := 0;
    signal last_insn_fetch_pc : std_logic_vector(31 downto 0) := (others => '0');

    -- Test checkpoints
    signal reached_500 : boolean := false;
    signal reached_506 : boolean := false;
    signal reached_50A : boolean := false;
    signal reached_50E : boolean := false;
    signal reached_512 : boolean := false;
    signal reached_516 : boolean := false;
    signal reached_STOP : boolean := false;

    -- Error tracking
    signal pc_error_detected : boolean := false;
    signal error_pc : std_logic_vector(31 downto 0) := (others => '0');

    -- Memory model - 64K words
    type mem_array_t is array(0 to 32767) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        -- Reset vectors
        0 => x"0000",  -- SSP high
        1 => x"2000",  -- SSP low = $00002000 (stack space)
        2 => x"0000",  -- PC high
        3 => x"0500",  -- PC low = $00000500

        -- Exception vectors (to catch crashes)
        4 => x"0000", 5 => x"0600",   -- Bus Error -> $600
        6 => x"0000", 7 => x"0600",   -- Address Error -> $600
        8 => x"0000", 9 => x"0600",   -- Illegal instruction -> $600
        10 => x"0000", 11 => x"0600", -- Divide by Zero -> $600

        -- Test program at $500 (word address $280)
        -- This matches the MMU detection sequence from DiagROM

        -- $500: First set up supervisor mode flags (already in supervisor)
        -- LEA $2000,A7 to initialize stack
        16#280# => x"4FF9",  -- LEA $00002000,A7
        16#281# => x"0000",
        16#282# => x"2000",

        -- $506: pmove.l tc,(sp) - Read TC to stack
        -- Encoding: F0|mode3=010|reg=111 = $F017
        --           Extension: TC=$10 (bits 14-10), MMU->mem (bit 9=1) = $4200
        16#283# => x"F017",
        16#284# => x"4200",

        -- $50A: pmove.q crp,(sp) - Read CRP (64-bit) to stack
        -- Encoding: $F017 (same opcode)
        -- Extension: CRP=$13 (bits 14-10), MMU->mem (bit 9=1) = $4E00
        16#285# => x"F017",
        16#286# => x"4E00",

        -- $50E: pmove.q (sp),crp - Write CRP (64-bit) from stack
        -- Encoding: $F017 (same opcode)
        -- Extension: CRP=$13 (bits 14-10), mem->MMU (bit 9=0) = $4C00
        16#287# => x"F017",
        16#288# => x"4C00",

        -- $512: pmove.l (sp),tc - Write TC from stack
        -- Extension: TC=$10 (bits 14-10), mem->MMU (bit 9=0) = $4000
        16#289# => x"F017",
        16#28A# => x"4000",

        -- $516: STOP instruction to end test
        16#28B# => x"4E72",
        16#28C# => x"2700",

        -- Stack area at $2000 (word address $1000)
        -- Pre-populate with CRP value for read test
        16#1000# => x"8000",  -- CRP high[31:16]
        16#1001# => x"0002",  -- CRP high[15:0]
        16#1002# => x"0001",  -- CRP low[31:16]
        16#1003# => x"0000",  -- CRP low[15:0]

        others => x"4E71"  -- NOP
    );

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

    -- CPU instance
    dut: entity work.TG68KdotC_Kernel
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
            clk            => clk,
            nReset         => nReset,
            clkena_in      => clkena_in,
            data_in        => data_in,
            IPL            => "111",
            IPL_autovector => '1',
            CPU            => "10",  -- 68030 mode
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            FC             => FC,
            pmmu_reg_we    => open,
            pmmu_reg_re    => open,
            pmmu_reg_sel   => open,
            pmmu_reg_wdat  => open,
            pmmu_reg_part  => open,
            pmmu_addr_log  => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            cache_op_addr  => open,
            pmmu_walker_req  => open,
            pmmu_walker_addr => open,
            pmmu_walker_ack  => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode   => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open
        );

    -- Memory read
    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))));

    -- Track instruction fetches
    fetch_tracker: process(clk)
        variable pc_value : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if busstate = "00" and FC(1) = '1' then  -- Instruction fetch
                pc_value := unsigned(addr_out(15 downto 0));

                -- Report fetches in our test range
                if pc_value >= x"0500" and pc_value < x"0600" then
                    report "INSN FETCH at PC=$" &
                           slv_to_hex(addr_out) &
                           " (data=" & slv_to_hex(data_in) & ")"
                        severity note;

                    -- Track checkpoints
                    case to_integer(pc_value) is
                        when 16#500# =>
                            reached_500 <= true;
                            report "  -> LEA $2000,A7 (setup stack)" severity note;
                        when 16#506# =>
                            reached_506 <= true;
                            report "  -> pmove.l tc,(sp) - TC to memory" severity note;
                        when 16#50A# =>
                            reached_50A <= true;
                            report "  -> pmove.q crp,(sp) - CRP to memory (64-bit)" severity note;
                        when 16#50E# =>
                            reached_50E <= true;
                            report "  -> pmove.q (sp),crp - memory to CRP (64-bit)" severity note;
                        when 16#512# =>
                            reached_512 <= true;
                            report "  -> pmove.l (sp),tc - memory to TC" severity note;
                        when 16#516# =>
                            reached_516 <= true;
                            report "  -> STOP instruction" severity note;
                            reached_STOP <= true;
                        when others =>
                            null;
                    end case;

                    -- Check for PC gaps (should increment by 2 or 4, never more)
                    if last_insn_fetch_pc /= x"00000000" then
                        if (pc_value - unsigned(last_insn_fetch_pc(15 downto 0))) > 6 then
                            report "*** PC GAP DETECTED! ***" severity error;
                            report "  Previous PC: $" & slv_to_hex(last_insn_fetch_pc) severity error;
                            report "  Current PC:  $" & slv_to_hex(addr_out) severity error;
                            report "  Gap: " & integer'image(to_integer(pc_value - unsigned(last_insn_fetch_pc(15 downto 0)))) & " bytes" severity error;
                            pc_error_detected <= true;
                            error_pc <= addr_out;
                        end if;
                    end if;

                    last_insn_fetch_pc <= addr_out;
                    instruction_count <= instruction_count + 1;
                end if;
            end if;
        end if;
    end process;

    -- Test monitor
    test_monitor: process
    begin
        report "=====================================================" severity note;
        report "MMU Detection Test - DiagROM Sequence" severity note;
        report "Tests: pmove.l tc,(sp), pmove.q crp,(sp), pmove.q (sp),crp" severity note;
        report "=====================================================" severity note;

        -- Reset
        nReset <= '0';
        wait for CLK_PERIOD * 5;
        nReset <= '1';

        -- Wait for execution or timeout
        for i in 0 to 10000 loop
            wait for CLK_PERIOD;
            if reached_STOP then
                exit;
            end if;
        end loop;

        -- Results
        report "" severity note;
        report "=====================================================" severity note;
        report "Test Results:" severity note;
        report "=====================================================" severity note;

        if reached_500 then
            report "  $500 LEA $2000,A7 - PASS" severity note;
        else
            report "  $500 LEA - FAIL (not reached)" severity error;
        end if;

        if reached_506 then
            report "  $506 pmove.l tc,(sp) - PASS" severity note;
        else
            report "  $506 pmove.l tc,(sp) - FAIL (not reached)" severity error;
        end if;

        if reached_50A then
            report "  $50A pmove.q crp,(sp) - PASS" severity note;
        else
            report "  $50A pmove.q crp,(sp) - FAIL (not reached or skipped)" severity error;
        end if;

        if reached_50E then
            report "  $50E pmove.q (sp),crp - PASS" severity note;
        else
            report "  $50E pmove.q (sp),crp - FAIL (not reached or skipped)" severity error;
        end if;

        if reached_512 then
            report "  $512 pmove.l (sp),tc - PASS" severity note;
        else
            report "  $512 pmove.l (sp),tc - FAIL (not reached or skipped)" severity error;
        end if;

        if reached_STOP then
            report "  $516 STOP instruction - PASS" severity note;
        else
            report "  $516 STOP - FAIL (timeout)" severity error;
        end if;

        report "" severity note;
        if pc_error_detected then
            report "*** FAIL: PC gap/overincrement detected at $" & slv_to_hex(error_pc) severity error;
        elsif reached_500 and reached_506 and reached_50A and reached_50E and reached_512 and reached_STOP then
            report "*** ALL TESTS PASSED - MMU detection sequence works ***" severity note;
        else
            report "*** FAIL: Did not reach all checkpoints ***" severity error;
        end if;

        report "Total instruction fetches: " & integer'image(instruction_count) severity note;
        report "=====================================================" severity note;

        test_done <= true;
        wait;
    end process;

end behavioral;
