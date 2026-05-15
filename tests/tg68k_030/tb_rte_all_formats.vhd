-- tb_rte_all_formats.vhd
-- Comprehensive RTE stack frame format validation test
-- Tests all 6 valid MC68030 formats plus invalid formats
-- Validates correct handling per MC68030 User's Manual specification

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rte_all_formats is
end entity;

architecture behavior of tb_rte_all_formats is
    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal data_in   : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out  : std_logic_vector(31 downto 0);
    signal nWr       : std_logic;
    signal nUDS      : std_logic;
    signal nLDS      : std_logic;
    signal busstate  : std_logic_vector(1 downto 0);
    signal FC        : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;

    signal test_done : boolean := false;
    signal test_passed : integer := 0;
    signal test_failed : integer := 0;
    signal current_test : string(1 to 40) := (others => ' ');

begin
    clk <= not clk after CLK_PERIOD/2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read        => 2,
            VBR_Stackframe => 1,
            extAddr_Mode   => 1,
            MUL_Hardware   => 1,
            BarrelShifter  => 2
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",  -- 68030
            addr_out => addr_out,
            data_write => data_write,
            nWr => nWr,
            nUDS => nUDS,
            nLDS => nLDS,
            busstate => busstate,
            FC => FC,
            longword => open,
            nResetOut => open,
            clr_berr => open,
            skipFetch => open,
            regin_out => open,
            CACR_out => open,
            VBR_out => open,
            cache_inv_req => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr => open,
            pmmu_reg_we => open,
            pmmu_reg_re => open,
            pmmu_reg_sel => open,
            pmmu_reg_wdat => open,
            pmmu_reg_part => open,
            pmmu_addr_log => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req => open,
            pmmu_walker_we => open,
            pmmu_walker_addr => open,
            pmmu_walker_wdat => open,
            pmmu_walker_ack => '0',
            pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 8191 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 8191 then
                    -- Debug: monitor writes to stack area $07C0-$07C8
                    if addr_out(15 downto 0) >= x"07C0" and addr_out(15 downto 0) <= x"07C8" then
                        report "DBG_WRITE addr=$" & integer'image(to_integer(unsigned(addr_out(15 downto 0)))) &
                               " data=$" & integer'image(to_integer(unsigned(data_write))) &
                               " UDS=" & std_logic'image(nUDS) & " LDS=" & std_logic'image(nLDS) severity note;
                    end if;
                    if nUDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(15 downto 8) := data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        mem(to_integer(unsigned(addr_out(15 downto 1))))(7 downto 0) := data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    test: process
        variable exception_vector : std_logic_vector(7 downto 0);
        variable cycles : integer;

        procedure setup_memory is
        begin
            -- Initialize memory with NOPs
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=0x2000, PC=0x1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error handler at 0x38: STOP #$2700
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1100";
            mem(16#1100#/2) := x"4E72";
            mem(16#1100#/2 + 1) := x"2700";
        end procedure;

        procedure test_rte_format(
            format_code : std_logic_vector(3 downto 0);
            test_name : string;
            should_pass : boolean
        ) is
            variable return_pc : std_logic_vector(31 downto 0);
            variable format_vector : std_logic_vector(15 downto 0);
            variable frame_size : integer;
            variable stack_base : integer;
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');

            -- Build format/vector word: format(15:12), zeros(11:10), vector_offset(9:0)
            -- Using vector 0 (reset) for simplicity - it doesn't matter for this test
            format_vector := format_code & "00" & "0000000000";

            return_pc := x"00001200";  -- Return address

            -- Calculate frame size based on format
            case format_code is
                when "0000" | "0001" => frame_size := 8;   -- 4-word frame
                when "0010"          => frame_size := 12;  -- 6-word frame
                when "1001"          => frame_size := 20;  -- 10-word frame
                when "1010"          => frame_size := 32;  -- 16-word frame
                when "1011"          => frame_size := 92;  -- 46-word frame
                when others          => frame_size := 8;   -- Invalid formats use minimal frame
            end case;

            -- Stack starts at 0x2000, frame will be below that
            -- We need to set A7 to point to the beginning of the frame
            stack_base := 16#2000# - frame_size;

            -- Setup test program at 0x1000
            -- Load A7 with stack pointer pointing to our pre-built frame, then RTE
            -- MOVEA.L #imm,A7: opcode 2E7C, then 32-bit immediate (high word, low word)
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L #imm,A7
            mem(16#1002#/2) := x"0000";  -- High word (stack_base < 64K)
            mem(16#1004#/2) := std_logic_vector(to_unsigned(stack_base, 16));

            mem(16#1006#/2) := x"4E73";  -- RTE

            -- Build the exception frame in memory at stack_base
            -- MC68030 exception frame layout (from SP upward):
            --   SP+0: SR (16 bits)
            --   SP+2: PC high (16 bits)
            --   SP+4: PC low (16 bits)
            --   SP+6: format/vector word (16 bits)
            --   SP+8+: additional words depending on format

            mem(stack_base/2)     := x"2700";  -- SR: supervisor mode, interrupts disabled
            mem(stack_base/2 + 1) := return_pc(31 downto 16);  -- PC high
            mem(stack_base/2 + 2) := return_pc(15 downto 0);   -- PC low
            mem(stack_base/2 + 3) := format_vector;            -- format/vector word

            -- Fill additional frame words with dummy data for larger formats
            for i in 4 to (frame_size/2 - 1) loop
                mem(stack_base/2 + i) := x"DEAD";
            end loop;
            if format_code = "1011" then
                mem(stack_base/2 + 16#36#/2) := x"0EAD";  -- Format $B internal state word used by MMU RTE replay
            end if;

            -- MC68030 Format $1 (throwaway): place a second Format $0 frame after it
            -- RTE chains from Format $1 to a second frame on the same stack (M=0 in SR)
            if format_code = "0001" then
                mem(stack_base/2 + 4) := x"2700";  -- Second frame SR
                mem(stack_base/2 + 5) := return_pc(31 downto 16);  -- Second frame PC high
                mem(stack_base/2 + 6) := return_pc(15 downto 0);   -- Second frame PC low
                mem(stack_base/2 + 7) := x"0000";  -- Second frame format/vector (Format $0)
            end if;

            -- Success marker at return address
            mem(16#1200#/2) := x"4E72";  -- STOP #$2700
            mem(16#1202#/2) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            -- Wait for test completion or timeout
            exception_vector := x"00";
            for i in 0 to 10000 loop
                wait until rising_edge(clk);

                -- Check for vector table read (exception taken)
                if busstate = "10" and addr_out(31 downto 10) = (31 downto 10 => '0') then
                    exception_vector := addr_out(9 downto 2);
                end if;

                -- Check for success (reached return address)
                if addr_out = return_pc then
                    if should_pass then
                        report "PASS: " & test_name severity note;
                        test_passed <= test_passed + 1;
                    else
                        report "FAIL: " & test_name & " (should have triggered Format Error)" severity error;
                        test_failed <= test_failed + 1;
                    end if;
                    exit;
                end if;

                -- Check for format error (exception vector 14 = 0x0E)
                if exception_vector = X"0E" then
                    if not should_pass then
                        report "PASS: " & test_name & " (Format Error correctly triggered)" severity note;
                        test_passed <= test_passed + 1;
                    else
                        report "FAIL: " & test_name & " (unexpected Format Error)" severity error;
                        test_failed <= test_failed + 1;
                    end if;
                    exit;
                end if;
            end loop;

            if exception_vector = x"00" and addr_out /= return_pc then
                report "FAIL: " & test_name & " (timeout)" severity error;
                test_failed <= test_failed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Test with exact format word value (for specific hardware test cases)
        procedure test_rte_format_word(
            format_word : std_logic_vector(15 downto 0);
            test_name : string;
            should_pass : boolean
        ) is
            variable return_pc : std_logic_vector(31 downto 0);
            variable frame_size : integer;
            variable stack_base : integer;
            variable format_code : std_logic_vector(3 downto 0);
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');
            format_code := format_word(15 downto 12);

            return_pc := x"00001200";  -- Return address

            -- Calculate frame size based on format
            case format_code is
                when "0000" | "0001" => frame_size := 8;   -- 4-word frame
                when "0010"          => frame_size := 12;  -- 6-word frame
                when "1001"          => frame_size := 20;  -- 10-word frame
                when "1010"          => frame_size := 32;  -- 16-word frame
                when "1011"          => frame_size := 92;  -- 46-word frame
                when others          => frame_size := 8;   -- Invalid formats use minimal frame
            end case;

            stack_base := 16#2000# - frame_size;

            -- Setup test program at 0x1000
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L #imm,A7
            mem(16#1002#/2) := x"0000";  -- High word
            mem(16#1004#/2) := std_logic_vector(to_unsigned(stack_base, 16));
            mem(16#1006#/2) := x"4E73";  -- RTE

            -- Build the exception frame
            mem(stack_base/2)     := x"2700";  -- SR
            mem(stack_base/2 + 1) := return_pc(31 downto 16);  -- PC high
            mem(stack_base/2 + 2) := return_pc(15 downto 0);   -- PC low
            mem(stack_base/2 + 3) := format_word;              -- Exact format/vector word

            -- Fill additional frame words
            for i in 4 to (frame_size/2 - 1) loop
                mem(stack_base/2 + i) := x"DEAD";
            end loop;

            -- Success marker at return address
            mem(16#1200#/2) := x"4E72";  -- STOP #$2700
            mem(16#1202#/2) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            -- Wait for test completion or timeout
            exception_vector := x"00";
            for i in 0 to 10000 loop
                wait until rising_edge(clk);

                if busstate = "10" and addr_out(31 downto 10) = (31 downto 10 => '0') then
                    exception_vector := addr_out(9 downto 2);
                end if;

                if addr_out = return_pc then
                    if should_pass then
                        report "PASS: " & test_name severity note;
                        test_passed <= test_passed + 1;
                    else
                        report "FAIL: " & test_name & " (should have triggered Format Error)" severity error;
                        test_failed <= test_failed + 1;
                    end if;
                    exit;
                end if;

                if exception_vector = X"0E" then
                    if not should_pass then
                        report "PASS: " & test_name & " (Format Error correctly triggered)" severity note;
                        test_passed <= test_passed + 1;
                    else
                        report "FAIL: " & test_name & " (unexpected Format Error)" severity error;
                        test_failed <= test_failed + 1;
                    end if;
                    exit;
                end if;
            end loop;

            if exception_vector = x"00" and addr_out /= return_pc then
                report "FAIL: " & test_name & " (timeout)" severity error;
                test_failed <= test_failed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Regression: invalid format word $4205 with frame SR=$0000 must
        -- trigger Format Error without dropping to user mode or clobbering MSP.
        procedure test_rte_format4205_s_to_u_msp_preserve is
            constant test_name : string := "Fmt4 $4205 S->U SR/MSP preserve";
            variable reached_stop : boolean;
            variable saw_format_error : boolean;
            variable saw_illegal : boolean;
            variable local_fail : boolean;
            variable exception_vector : std_logic_vector(7 downto 0);
            variable sr_val : std_logic_vector(15 downto 0);
            variable msp_hi : std_logic_vector(15 downto 0);
            variable msp_lo : std_logic_vector(15 downto 0);
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');
            report "Testing invalid RTE frame $4205 with SR=$0000 (must keep S=1 and preserve MSP)..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error vector (14, offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";

            -- Illegal instruction vector (4, offset $10) -> $1400 (failure marker)
            mem(16#10#/2) := x"0000";
            mem(16#10#/2 + 1) := x"1400";
            mem(16#1400#/2) := x"4E72";
            mem(16#1400#/2 + 1) := x"2700";

            -- Clear verification area
            for i in 16#3000#/2 to 16#3008#/2 loop
                mem(i) := x"DEAD";
            end loop;

            -- ===== Code at $1000 =====
            -- Set MSP shadow = $0840
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"0840";  -- MOVE.L #$00000840,D0
            mem(16#1006#/2) := x"4E7B"; mem(16#1008#/2) := x"0803";                               -- MOVEC D0,MSP
            -- Set ISP shadow = $07C0 and make A7 point there (supervisor M=0 => A7=ISP)
            mem(16#100A#/2) := x"203C"; mem(16#100C#/2) := x"0000"; mem(16#100E#/2) := x"07C0";  -- MOVE.L #$000007C0,D0
            mem(16#1010#/2) := x"4E7B"; mem(16#1012#/2) := x"0804";                               -- MOVEC D0,ISP
            mem(16#1014#/2) := x"2E7C"; mem(16#1016#/2) := x"0000"; mem(16#1018#/2) := x"07C0";  -- MOVEA.L #$000007C0,A7
            -- Force known supervisor SR (S=1, M=0)
            mem(16#101A#/2) := x"46FC"; mem(16#101C#/2) := x"2000";                               -- MOVE.W #$2000,SR
            -- Execute RTE with invalid format frame at ISP
            mem(16#101E#/2) := x"4E73";                                                            -- RTE

            -- If RTE incorrectly returns to frame PC, this executes (failure marker)
            mem(16#1580#/2) := x"4E72"; mem(16#1582#/2) := x"2700";                               -- STOP #$2700

            -- ===== Frame at ISP ($07C0) =====
            mem(16#07C0#/2) := x"0000";  -- SR from frame (user mode request)
            mem(16#07C2#/2) := x"0000";  -- PC high
            mem(16#07C4#/2) := x"1580";  -- PC low (must not be reached)
            mem(16#07C6#/2) := x"4205";  -- Invalid format word (Format $4)

            -- ===== Format Error handler at $1300 =====
            mem(16#1300#/2) := x"4280";                                                            -- CLR.L D0
            mem(16#1302#/2) := x"40C0";                                                            -- MOVE.W SR,D0
            mem(16#1304#/2) := x"33C0"; mem(16#1306#/2) := x"0000"; mem(16#1308#/2) := x"3000";  -- MOVE.W D0,($3000).L
            mem(16#130A#/2) := x"4E7A"; mem(16#130C#/2) := x"4803";                               -- MOVEC MSP,D4
            mem(16#130E#/2) := x"23C4"; mem(16#1310#/2) := x"0000"; mem(16#1312#/2) := x"3002";  -- MOVE.L D4,($3002).L
            mem(16#1314#/2) := x"4E72"; mem(16#1316#/2) := x"2700";                               -- STOP #$2700

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            saw_format_error := false;
            saw_illegal := false;
            exception_vector := x"00";
            for i in 0 to 30000 loop
                wait until rising_edge(clk);

                -- Track exception vectors from vector table reads
                if busstate = "10" and addr_out(31 downto 10) = (31 downto 10 => '0') then
                    exception_vector := addr_out(9 downto 2);
                    if exception_vector = x"0E" then
                        saw_format_error := true;
                    elsif exception_vector = x"04" then
                        saw_illegal := true;
                    end if;
                end if;

                -- Failure: RTE treated frame as valid and jumped to frame PC
                if addr_out(15 downto 0) = x"1580" then
                    report "FAIL: $4205 regression - RTE returned to frame PC instead of taking Format Error" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;

                -- Failure: got Illegal Instruction vector (expected Format Error)
                if saw_illegal then
                    report "FAIL: $4205 regression - got exception vector 4 (Illegal), expected vector 14 (Format Error)" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;

                -- Success path: reached STOP in Format Error handler
                if addr_out(15 downto 0) = x"1314" then
                    reached_stop := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
            end loop;

            if not reached_stop then
                if saw_format_error then
                    report "FAIL: $4205 regression - saw Format Error vector but handler did not complete" severity error;
                else
                    report "FAIL: $4205 regression - timeout waiting for Format Error vector/handler" severity error;
                end if;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            -- ===== Verify post-exception state =====
            local_fail := false;

            -- Active SR should still indicate supervisor mode with M=0
            sr_val := mem(16#3000#/2);
            if sr_val(15 downto 8) /= x"20" then
                report "  FAIL: SR high byte in Format Error handler = $" &
                       integer'image(to_integer(unsigned(sr_val(15 downto 8)))) &
                       ", expected $20 (S=1, M=0)" severity error;
                local_fail := true;
            end if;

            -- MSP shadow must remain at initialized value ($0840)
            msp_hi := mem(16#3002#/2);
            msp_lo := mem(16#3002#/2 + 1);
            if msp_hi /= x"0000" or msp_lo /= x"0840" then
                report "  FAIL: MSP = $" & integer'image(to_integer(unsigned(msp_hi))) &
                       ":" & integer'image(to_integer(unsigned(msp_lo))) &
                       ", expected $0000:$0840" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: $4205 regression - SR/MSP state mismatch on Format Error" severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: $4205 regression - Format Error taken, SR stayed supervisor, MSP preserved" severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Format Error: SR should NOT be restored from the invalid frame.
        -- When RTE detects an invalid format, it triggers Format Error (vector 14).
        -- The exception frame must contain the ORIGINAL pre-RTE SR, because the
        -- frame format was invalid and thus the SR from it is suspect.
        --
        -- Test: Pre-RTE SR=$2700 (S=1, IPL=7), frame SR=$2100 (S=1, IPL=1).
        -- Format error frame must show SR=$2700 (original), not $2100 (from bad frame).
        -- Uses different IPL fields to distinguish pre-RTE from frame SR.
        procedure test_format_error_preserves_frame_sr is
            constant test_name : string := "FmtErr restores original pre-RTE SR";
            variable reached_stop : boolean;
            variable local_fail : boolean;
            variable frame_sr : std_logic_vector(15 downto 0);
            variable frame_pc : std_logic_vector(31 downto 0);
            variable sp_val_hi : std_logic_vector(15 downto 0);
            variable sp_val_lo : std_logic_vector(15 downto 0);
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');
            report "Testing: Format Error exception frame must contain original pre-RTE SR..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error vector (14, offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";

            -- Trace vector (9, offset $24) -> $1200 (safety: STOP if trace fires)
            mem(16#24#/2) := x"0000";
            mem(16#24#/2 + 1) := x"1200";
            mem(16#1200#/2) := x"4E72"; mem(16#1202#/2) := x"2700";  -- STOP #$2700

            -- ===== Code at $1000 =====
            -- Set ISP = $07C0, make A7 point there
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"07C0";  -- MOVE.L #$000007C0,D0
            mem(16#1006#/2) := x"4E7B"; mem(16#1008#/2) := x"0804";                               -- MOVEC D0,ISP
            mem(16#100A#/2) := x"2E7C"; mem(16#100C#/2) := x"0000"; mem(16#100E#/2) := x"07C0";  -- MOVEA.L #$000007C0,A7
            -- Set SR=$2700 (S=1, IPL=7, no trace) - this is the pre-RTE SR
            mem(16#1010#/2) := x"46FC"; mem(16#1012#/2) := x"2700";                               -- MOVE.W #$2700,SR
            -- Execute RTE - should load SR=$2100 from frame, detect invalid format
            mem(16#1014#/2) := x"4E73";                                                            -- RTE

            -- ===== RTE Frame at ISP ($07C0) =====
            -- SR=$2100 (S=1, IPL=1) - differs from pre-RTE by IPL field
            mem(16#07C0#/2) := x"2100";  -- Frame SR: S=1, IPL=1
            mem(16#07C2#/2) := x"0000";  -- PC high
            mem(16#07C4#/2) := x"1580";  -- PC low (should not be reached)
            mem(16#07C6#/2) := x"4205";  -- Invalid format word (Format $4)

            -- ===== Format Error handler at $1300 =====
            -- Read the exception frame from the stack to verify SR value
            -- Format $0 frame layout at (A7): SR(16) | PC(32) | FmtVec(16)
            -- Also save A7 for debug (stack pointer check) and the stacked PC.
            mem(16#1300#/2) := x"3017";                                                            -- MOVE.W (A7),D0  -- read frame SR
            mem(16#1302#/2) := x"33C0"; mem(16#1304#/2) := x"0000"; mem(16#1306#/2) := x"3000";  -- MOVE.W D0,($3000).L
            mem(16#1308#/2) := x"222F"; mem(16#130A#/2) := x"0002";                               -- MOVE.L 2(A7),D1 -- read frame PC
            mem(16#130C#/2) := x"23C1"; mem(16#130E#/2) := x"0000"; mem(16#1310#/2) := x"3006";  -- MOVE.L D1,($3006).L
            mem(16#1312#/2) := x"23CF"; mem(16#1314#/2) := x"0000"; mem(16#1316#/2) := x"3002";  -- MOVE.L A7,($3002).L
            mem(16#1318#/2) := x"4E72"; mem(16#131A#/2) := x"2700";                               -- STOP #$2700

            -- Clear verification area
            mem(16#3000#/2) := x"DEAD";
            mem(16#3002#/2) := x"DEAD";
            mem(16#3004#/2) := x"DEAD";
            mem(16#3006#/2) := x"DEAD";
            mem(16#3008#/2) := x"DEAD";

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);
                -- Detect STOP at $1318
                if addr_out(15 downto 0) = x"1318" then
                    reached_stop := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
                -- Safety: detect trace handler STOP at $1200
                if addr_out(15 downto 0) = x"1200" then
                    report "FAIL: " & test_name & " - T0/T1 trace fired unexpectedly!" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;
            end loop;

            if not reached_stop then
                report "FAIL: " & test_name & " - timeout, format error handler not reached" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            -- ===== Verify: Format Error frame must contain RTE-loaded SR ($2100) =====
            local_fail := false;
            frame_sr := mem(16#3000#/2);
            sp_val_hi := mem(16#3002#/2);
            sp_val_lo := mem(16#3004#/2);
            frame_pc := mem(16#3006#/2) & mem(16#3008#/2);

            report "  DEBUG: frame_sr=$" & integer'image(to_integer(unsigned(frame_sr))) &
                   " A7=$" & integer'image(to_integer(unsigned(sp_val_hi))) &
                   ":" & integer'image(to_integer(unsigned(sp_val_lo))) &
                   " PC=$" & integer'image(to_integer(unsigned(frame_pc))) severity note;
            -- Raw memory dump of stack area for debug
            report "  RAW MEM: $07C0=" & integer'image(to_integer(unsigned(mem(16#07C0#/2)))) &
                   " $07C2=" & integer'image(to_integer(unsigned(mem(16#07C2#/2)))) &
                   " $07C4=" & integer'image(to_integer(unsigned(mem(16#07C4#/2)))) &
                   " $07C6=" & integer'image(to_integer(unsigned(mem(16#07C6#/2)))) severity note;

            -- The critical check: frame SR must be $2700 (original pre-RTE SR),
            -- NOT $2100 (from the invalid RTE frame). The IPL field is the key difference.
            if frame_sr /= x"2700" then
                report "  FAIL: Format Error frame SR = $" &
                       integer'image(to_integer(unsigned(frame_sr))) &
                       ", expected $2700 (original pre-RTE SR)" severity error;
                if frame_sr = x"2100" then
                    report "  (Got $2100 = SR from invalid frame -- should not be used)" severity error;
                end if;
                local_fail := true;
            end if;
            if frame_pc /= x"00001014" then
                report "  FAIL: Format Error frame PC = $" &
                       integer'image(to_integer(unsigned(frame_pc))) &
                       ", expected $00001014 (faulting RTE instruction)" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: " & test_name severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: " & test_name severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- WinUAE-compatible invalid RTE handling:
        -- RTE may read the candidate frame words to validate the format, but if the
        -- format is invalid it must not commit the stacked SR/PC or advance A7.
        -- Vector 14 is then stacked below the original RTE frame, leaving the bad
        -- frame intact. This reproduces the live SysSpeed capture shape:
        --   SR=$4032, PC=$64DE2004, format=$4042.
        procedure test_format_error_restores_a7_before_stack is
            constant test_name : string := "FmtErr restores pre-RTE A7";
            variable reached_stop : boolean;
            variable local_fail : boolean;
            variable a7_val : std_logic_vector(31 downto 0);
            variable frame_pc : std_logic_vector(31 downto 0);
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');
            report "Testing: invalid RTE must stack vector 14 below original A7..." severity note;

            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error vector (14, offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";

            -- Clear verification area
            for i in 16#3000#/2 to 16#3008#/2 loop
                mem(i) := x"DEAD";
            end loop;

            -- ===== Code at $1000 =====
            -- MSP deliberately zeroed; invalid RTE must not switch to it.
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"0000";  -- MOVE.L #$00000000,D0
            mem(16#1006#/2) := x"4E7B"; mem(16#1008#/2) := x"0803";                               -- MOVEC D0,MSP
            -- Active supervisor stack is ISP at $07C0.
            mem(16#100A#/2) := x"203C"; mem(16#100C#/2) := x"0000"; mem(16#100E#/2) := x"07C0";  -- MOVE.L #$000007C0,D0
            mem(16#1010#/2) := x"4E7B"; mem(16#1012#/2) := x"0804";                               -- MOVEC D0,ISP
            mem(16#1014#/2) := x"2E7C"; mem(16#1016#/2) := x"0000"; mem(16#1018#/2) := x"07C0";  -- MOVEA.L #$000007C0,A7
            mem(16#101A#/2) := x"46FC"; mem(16#101C#/2) := x"2700";                               -- MOVE.W #$2700,SR
            mem(16#101E#/2) := x"4E73";                                                            -- RTE

            -- ===== Invalid RTE frame at original A7 ($07C0) =====
            mem(16#07C0#/2) := x"4032";  -- Stacked SR from live capture shape
            mem(16#07C2#/2) := x"64DE";  -- PC high
            mem(16#07C4#/2) := x"2004";  -- PC low
            mem(16#07C6#/2) := x"4042";  -- Invalid format word

            -- ===== Format Error handler at $1300 =====
            mem(16#1300#/2) := x"23CF"; mem(16#1302#/2) := x"0000"; mem(16#1304#/2) := x"3000";  -- MOVE.L A7,($3000).L
            mem(16#1306#/2) := x"4E72"; mem(16#1308#/2) := x"2700";                               -- STOP #$2700

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1306" then
                    reached_stop := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
            end loop;

            if not reached_stop then
                report "FAIL: " & test_name & " - timeout, format error handler not reached" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            local_fail := false;
            a7_val := mem(16#3000#/2) & mem(16#3002#/2);
            frame_pc := mem(16#07BA#/2) & mem(16#07BC#/2);

            if a7_val /= x"000007B8" then
                report "  FAIL: format-error handler A7 = $" &
                       integer'image(to_integer(unsigned(a7_val))) &
                       ", expected $000007B8 (original A7 - 8)" severity error;
                local_fail := true;
            end if;
            if mem(16#07B8#/2) /= x"2700" or frame_pc /= x"0000101E" or mem(16#07BE#/2) /= x"0038" then
                report "  FAIL: vector-14 frame at $07B8 is not SR=$2700 PC=$0000101E FMT=$0038" severity error;
                local_fail := true;
            end if;
            if mem(16#07C0#/2) /= x"4032" or mem(16#07C2#/2) /= x"64DE" or
               mem(16#07C4#/2) /= x"2004" or mem(16#07C6#/2) /= x"4042" then
                report "  FAIL: invalid RTE frame at original A7 was modified" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: " & test_name severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: " & test_name severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Test: Format error with T0=1 must clear T0 in exception handler SR.
        -- MC68030 UM 8.1: exception processing sets S=1 and clears T1,T0.
        -- Pre-RTE SR=$6000 (T0=1, S=1), frame SR=$2000 (S=1), invalid format.
        -- Handler must see SR=$2000 (T0 cleared by exception entry), not $6000.
        -- Also checks saved SR in frame = $6000 (pre-RTE value).
        procedure test_format_error_clears_t0 is
            constant test_name : string := "FmtErr clears T0 on exception entry";
            variable reached_stop : boolean;
            variable local_fail : boolean;
            variable frame_sr : std_logic_vector(15 downto 0);
            variable handler_sr : std_logic_vector(15 downto 0);
        begin
            current_test <= test_name & (test_name'length + 1 to 40 => ' ');
            report "Testing: Format Error with T0=1 must clear T0 in handler..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error vector (14, offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";

            -- Trace vector (9, offset $24) -> $1200 (safety: STOP if trace fires)
            mem(16#24#/2) := x"0000";
            mem(16#24#/2 + 1) := x"1200";
            mem(16#1200#/2) := x"4E72"; mem(16#1202#/2) := x"2700";  -- STOP #$2700

            -- ===== Code at $1000 =====
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"07C0";  -- MOVE.L #$000007C0,D0
            mem(16#1006#/2) := x"4E7B"; mem(16#1008#/2) := x"0804";                               -- MOVEC D0,ISP
            mem(16#100A#/2) := x"2E7C"; mem(16#100C#/2) := x"0000"; mem(16#100E#/2) := x"07C0";  -- MOVEA.L #$000007C0,A7
            -- Set SR=$6000 (T0=1, S=1, M=0) - this is the pre-RTE SR
            mem(16#1010#/2) := x"46FC"; mem(16#1012#/2) := x"6000";                               -- MOVE.W #$6000,SR
            -- Execute RTE - loads SR=$2000 from frame, detects invalid format
            mem(16#1014#/2) := x"4E73";                                                            -- RTE

            -- ===== RTE Frame at ISP ($07C0) =====
            mem(16#07C0#/2) := x"2000";  -- Frame SR: S=1 (no trace, no IPL)
            mem(16#07C2#/2) := x"0000";  -- PC high
            mem(16#07C4#/2) := x"1580";  -- PC low (should not be reached)
            mem(16#07C6#/2) := x"4205";  -- Invalid format word (Format $4)

            -- ===== Format Error handler at $1300 =====
            -- Read current SR (should have T0=0) and saved SR from frame
            mem(16#1300#/2) := x"40C0";                                                            -- MOVE SR,D0 (read current SR)
            mem(16#1302#/2) := x"33C0"; mem(16#1304#/2) := x"0000"; mem(16#1306#/2) := x"3006";  -- MOVE.W D0,($3006).L (handler SR)
            mem(16#1308#/2) := x"3017";                                                            -- MOVE.W (A7),D0 (read frame SR)
            mem(16#130A#/2) := x"33C0"; mem(16#130C#/2) := x"0000"; mem(16#130E#/2) := x"3000";  -- MOVE.W D0,($3000).L (frame SR)
            mem(16#1310#/2) := x"4E72"; mem(16#1312#/2) := x"2700";                               -- STOP #$2700

            -- Clear verification area
            mem(16#3000#/2) := x"DEAD";
            mem(16#3006#/2) := x"DEAD";

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);
                if addr_out(15 downto 0) = x"1310" then
                    reached_stop := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
                if addr_out(15 downto 0) = x"1200" then
                    report "FAIL: " & test_name & " - trace exception fired (T0 not cleared!)" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;
            end loop;

            if not reached_stop then
                report "FAIL: " & test_name & " - timeout" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            local_fail := false;
            frame_sr := mem(16#3000#/2);
            handler_sr := mem(16#3006#/2);

            report "  DEBUG: frame_sr=$" & integer'image(to_integer(unsigned(frame_sr))) &
                   " handler_sr=$" & integer'image(to_integer(unsigned(handler_sr))) severity note;

            -- Check 1: Saved SR in frame must be $6000 (pre-RTE value with T0=1)
            if frame_sr /= x"6000" then
                report "  FAIL: Frame saved SR = $" &
                       integer'image(to_integer(unsigned(frame_sr))) &
                       ", expected $6000 (pre-RTE SR with T0=1)" severity error;
                local_fail := true;
            end if;

            -- Check 2: Handler current SR must be $2000 (T0 cleared by exception entry)
            -- T0 must be 0, T1 must be 0, S must be 1. IPL may vary.
            if handler_sr(14) /= '0' then  -- T1 bit
                report "  FAIL: Handler SR has T1=1 (should be cleared)" severity error;
                local_fail := true;
            end if;
            if handler_sr(13) /= '1' then  -- S bit
                report "  FAIL: Handler SR has S=0 (should be supervisor)" severity error;
                local_fail := true;
            end if;
            if handler_sr(15) /= '0' then  -- T0 bit (bit 15 of SR word = bit 6 of FlagsSR)
                report "  FAIL: Handler SR has T0=1 (should be cleared by exception entry)" severity error;
                report "  handler_sr=$" & integer'image(to_integer(unsigned(handler_sr))) &
                       " -- T0 not cleared!" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: " & test_name severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: " & test_name severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Test SVmode tracking: RTE to user mode, TRAP, RTE back
        -- This tests whether preSVmode properly syncs when SR is restored
        procedure test_svmode_tracking is
            variable stack_base : integer;
            variable trap_handler_addr : integer;
            variable user_code_addr : integer;
            variable final_return_addr : integer;
            variable exception_vector : std_logic_vector(7 downto 0);
            variable saw_privilege_error : boolean;
            variable saw_user_mode_exec : boolean;
        begin
            current_test <= "SVmode tracking: SV->User->SV->User     ";
            report "Testing SVmode tracking through mode transitions..." severity note;

            -- Memory layout:
            -- 0x1000: Supervisor code - sets up user mode RTE
            -- 0x1400: User mode code - executes TRAP #0
            -- 0x1500: TRAP #0 handler - RTEs back to user
            -- 0x1600: Final success marker

            stack_base := 16#1F00#;
            user_code_addr := 16#1400#;
            trap_handler_addr := 16#1500#;
            final_return_addr := 16#1600#;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- TRAP #0 vector (vector 32 = offset 0x80)
            mem(16#80#/2) := x"0000";
            mem(16#80#/2 + 1) := std_logic_vector(to_unsigned(trap_handler_addr, 16));

            -- Privilege violation vector (vector 8 = offset 0x20)
            mem(16#20#/2) := x"0000";
            mem(16#20#/2 + 1) := x"1700";  -- Handler at 0x1700

            -- Privilege violation handler - just STOP (indicates failure)
            mem(16#1700#/2) := x"4E72";
            mem(16#1700#/2 + 1) := x"2700";

            -- Supervisor startup code at 0x1000:
            -- Setup stack frame for RTE to user mode, then RTE
            -- Frame: SR=0x0000 (user mode), PC=0x1400 (user code), Format 0
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L #stack_base,A7
            mem(16#1002#/2) := x"0000";
            mem(16#1004#/2) := std_logic_vector(to_unsigned(stack_base, 16));
            -- Push format word (Format 0)
            mem(16#1006#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1008#/2) := x"0000";  -- Format 0, vector 0
            -- Push PC low
            mem(16#100A#/2) := x"3F3C";  -- MOVE.W #$1400,-(A7)
            mem(16#100C#/2) := std_logic_vector(to_unsigned(user_code_addr, 16));
            -- Push PC high
            mem(16#100E#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1010#/2) := x"0000";
            -- Push SR (user mode: S=0)
            mem(16#1012#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1014#/2) := x"0000";  -- User mode SR
            -- RTE to user mode
            mem(16#1016#/2) := x"4E73";  -- RTE

            -- User mode code at 0x1400:
            -- Execute TRAP #0 to re-enter supervisor
            mem(user_code_addr/2) := x"4E40";  -- TRAP #0

            -- After TRAP returns, should be back in user mode
            -- Execute NOP then STOP (but STOP is privileged, will trap if in user mode)
            mem(user_code_addr/2 + 1) := x"4E71";  -- NOP
            mem(user_code_addr/2 + 2) := x"4E71";  -- NOP
            -- Jump to success marker
            mem(user_code_addr/2 + 3) := x"4EF9";  -- JMP $1600
            mem(user_code_addr/2 + 4) := x"0000";
            mem(user_code_addr/2 + 5) := std_logic_vector(to_unsigned(final_return_addr, 16));

            -- TRAP #0 handler at 0x1500 (in supervisor mode):
            -- This handler RTEs back to user mode
            -- The frame on stack was created by TRAP, with user mode SR
            mem(trap_handler_addr/2) := x"4E73";  -- RTE back to user

            -- Success marker at 0x1600
            mem(final_return_addr/2) := x"4E72";  -- STOP #$2700
            mem(final_return_addr/2 + 1) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            -- Monitor execution
            saw_privilege_error := false;
            saw_user_mode_exec := false;

            for i in 0 to 20000 loop
                wait until rising_edge(clk);

                -- Check for privilege violation
                if busstate = "10" and addr_out(9 downto 0) = "0000100000" then  -- Vector 8
                    saw_privilege_error := true;
                    report "SVmode test: Privilege violation detected (vector 8 read)" severity note;
                end if;

                -- Check if we executed user code
                if addr_out(15 downto 0) = std_logic_vector(to_unsigned(user_code_addr, 16)) then
                    saw_user_mode_exec := true;
                end if;

                -- Check for success
                if addr_out = std_logic_vector(to_unsigned(final_return_addr, 32)) then
                    if not saw_privilege_error then
                        report "PASS: SVmode tracking test - completed without spurious privilege errors" severity note;
                        test_passed <= test_passed + 1;
                    else
                        report "FAIL: SVmode tracking test - got privilege error during valid execution" severity error;
                        test_failed <= test_failed + 1;
                    end if;
                    exit;
                end if;

                -- Check for handler at 0x1700 (privilege error handler)
                if addr_out(15 downto 0) = x"1700" then
                    report "FAIL: SVmode tracking test - ended up in privilege violation handler" severity error;
                    test_failed <= test_failed + 1;
                    exit;
                end if;
            end loop;

            wait for 1 us;
        end procedure;

        -- Test MOVE to SR clearing S bit, followed by instruction execution
        -- This tests preSVmode sync on exec(to_SR) path
        procedure test_move_to_sr_mode_change is
            variable exception_vector : std_logic_vector(7 downto 0);
        begin
            current_test <= "MOVE to SR mode change test             ";
            report "Testing MOVE to SR supervisor->user transition..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Privilege violation handler
            mem(16#20#/2) := x"0000";
            mem(16#20#/2 + 1) := x"1800";
            mem(16#1800#/2) := x"4E72";  -- STOP (we reached privilege handler = success)
            mem(16#1800#/2 + 1) := x"2700";

            -- Test code at 0x1000:
            -- In supervisor mode, do MOVE.W #$0000,SR to drop to user mode
            -- Then try to execute a privileged instruction (STOP)
            -- Should get privilege violation

            mem(16#1000#/2) := x"46FC";  -- MOVE.W #imm,SR
            mem(16#1002#/2) := x"0000";  -- SR = $0000 (user mode, no interrupts masked)
            -- Now in user mode, try STOP (privileged)
            mem(16#1004#/2) := x"4E72";  -- STOP #$2700 (privileged - should trap)
            mem(16#1006#/2) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 10000 loop
                wait until rising_edge(clk);

                -- Success: reached privilege handler (STOP in user mode caused trap)
                if addr_out(15 downto 0) = x"1800" then
                    report "PASS: MOVE to SR test - privilege violation correctly triggered after mode change" severity note;
                    test_passed <= test_passed + 1;
                    exit;
                end if;

                -- Failure: if we somehow executed past the STOP without trapping
                if addr_out(15 downto 0) = x"1008" then
                    report "FAIL: MOVE to SR test - STOP executed in user mode without privilege trap" severity error;
                    test_failed <= test_failed + 1;
                    exit;
                end if;
            end loop;

            wait for 1 us;
        end procedure;

        -- Test consecutive RTEs with different modes
        -- First RTE: supervisor -> user (SR in frame has S=0)
        -- User code takes TRAP
        -- Second RTE: supervisor -> user (trap handler RTEs)
        -- Tests that preSVmode is correctly maintained across multiple RTEs
        procedure test_consecutive_rte is
            variable stack_base : integer;
            variable user_addr : integer;
            variable trap_handler : integer;
            variable success_addr : integer;
        begin
            current_test <= "Consecutive RTE mode transitions        ";
            report "Testing consecutive RTEs with mode transitions..." severity note;

            stack_base := 16#1F00#;
            user_addr := 16#1400#;
            trap_handler := 16#1500#;
            success_addr := 16#1600#;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- TRAP #1 vector (vector 33 = offset 0x84)
            mem(16#84#/2) := x"0000";
            mem(16#84#/2 + 1) := std_logic_vector(to_unsigned(trap_handler, 16));

            -- Privilege violation handler - failure indicator
            mem(16#20#/2) := x"0000";
            mem(16#20#/2 + 1) := x"1700";
            mem(16#1700#/2) := x"4E72";
            mem(16#1700#/2 + 1) := x"2700";

            -- Supervisor code at 0x1000: build frame and RTE to user
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L #stack,A7
            mem(16#1002#/2) := x"0000";
            mem(16#1004#/2) := std_logic_vector(to_unsigned(stack_base, 16));
            -- Build exception frame manually on stack
            -- Format word
            mem(16#1006#/2) := x"3F3C";
            mem(16#1008#/2) := x"0000";
            -- PC low
            mem(16#100A#/2) := x"3F3C";
            mem(16#100C#/2) := std_logic_vector(to_unsigned(user_addr, 16));
            -- PC high
            mem(16#100E#/2) := x"3F3C";
            mem(16#1010#/2) := x"0000";
            -- SR (user mode)
            mem(16#1012#/2) := x"3F3C";
            mem(16#1014#/2) := x"0000";
            -- First RTE
            mem(16#1016#/2) := x"4E73";

            -- User code at 0x1400: TRAP #1, then more TRAPs
            mem(user_addr/2) := x"4E41";      -- TRAP #1
            mem(user_addr/2 + 1) := x"4E41";  -- TRAP #1 again
            mem(user_addr/2 + 2) := x"4E41";  -- TRAP #1 third time
            -- Jump to success
            mem(user_addr/2 + 3) := x"4EF9";
            mem(user_addr/2 + 4) := x"0000";
            mem(user_addr/2 + 5) := std_logic_vector(to_unsigned(success_addr, 16));

            -- TRAP handler: just RTE back
            mem(trap_handler/2) := x"4E73";

            -- Success
            mem(success_addr/2) := x"4E72";
            mem(success_addr/2 + 1) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 30000 loop
                wait until rising_edge(clk);

                if addr_out = std_logic_vector(to_unsigned(success_addr, 32)) then
                    report "PASS: Consecutive RTE test - all mode transitions handled correctly" severity note;
                    test_passed <= test_passed + 1;
                    exit;
                end if;

                if addr_out(15 downto 0) = x"1700" then
                    report "FAIL: Consecutive RTE test - spurious privilege violation" severity error;
                    test_failed <= test_failed + 1;
                    exit;
                end if;
            end loop;

            wait for 1 us;
        end procedure;

        -- Test RTE immediately after another RTE (back-to-back)
        -- This stresses the format word capture timing
        procedure test_back_to_back_rte is
            variable stack1 : integer;
            variable stack2 : integer;
            variable mid_addr : integer;
            variable success_addr : integer;
        begin
            current_test <= "Back-to-back RTE timing test            ";
            report "Testing back-to-back RTE execution..." severity note;

            stack1 := 16#1F00#;
            stack2 := 16#1E00#;
            mid_addr := 16#1400#;
            success_addr := 16#1600#;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format error handler
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1900";
            mem(16#1900#/2) := x"4E72";
            mem(16#1900#/2 + 1) := x"2700";

            -- Startup at 0x1000: setup first RTE frame
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L
            mem(16#1002#/2) := x"0000";
            mem(16#1004#/2) := std_logic_vector(to_unsigned(stack1, 16));
            -- Frame 1: goes to mid_addr which immediately does another RTE
            mem(16#1006#/2) := x"3F3C";  -- format
            mem(16#1008#/2) := x"0000";
            mem(16#100A#/2) := x"3F3C";  -- PC low
            mem(16#100C#/2) := std_logic_vector(to_unsigned(mid_addr, 16));
            mem(16#100E#/2) := x"3F3C";  -- PC high
            mem(16#1010#/2) := x"0000";
            mem(16#1012#/2) := x"3F3C";  -- SR
            mem(16#1014#/2) := x"2700";
            mem(16#1016#/2) := x"4E73";  -- First RTE

            -- Mid code at 0x1400: setup second RTE frame immediately and RTE again
            mem(mid_addr/2) := x"2E7C";  -- MOVEA.L
            mem(mid_addr/2 + 1) := x"0000";
            mem(mid_addr/2 + 2) := std_logic_vector(to_unsigned(stack2, 16));
            -- Frame 2: goes to success
            mem(mid_addr/2 + 3) := x"3F3C";  -- format
            mem(mid_addr/2 + 4) := x"0000";
            mem(mid_addr/2 + 5) := x"3F3C";  -- PC low
            mem(mid_addr/2 + 6) := std_logic_vector(to_unsigned(success_addr, 16));
            mem(mid_addr/2 + 7) := x"3F3C";  -- PC high
            mem(mid_addr/2 + 8) := x"0000";
            mem(mid_addr/2 + 9) := x"3F3C";  -- SR
            mem(mid_addr/2 + 10) := x"2700";
            mem(mid_addr/2 + 11) := x"4E73";  -- Second RTE

            -- Success
            mem(success_addr/2) := x"4E72";
            mem(success_addr/2 + 1) := x"2700";

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            for i in 0 to 15000 loop
                wait until rising_edge(clk);

                if addr_out = std_logic_vector(to_unsigned(success_addr, 32)) then
                    report "PASS: Back-to-back RTE test - both RTEs executed correctly" severity note;
                    test_passed <= test_passed + 1;
                    exit;
                end if;

                if addr_out(15 downto 0) = x"1900" then
                    report "FAIL: Back-to-back RTE test - format error (stale format word?)" severity error;
                    test_failed <= test_failed + 1;
                    exit;
                end if;
            end loop;

            wait for 1 us;
        end procedure;

        -- Test that RTE in user mode triggers vector 8 (privilege) BEFORE format check
        -- This verifies that privilege check at decode beats format error at rte4
        -- Even with an invalid format word, user-mode RTE should get vector 8, not 14
        procedure test_rte_user_mode_privilege is
            variable user_code_addr : integer;
            variable priv_handler_addr : integer;
            variable format_handler_addr : integer;
            variable saw_priv_vector : boolean;
            variable saw_format_vector : boolean;
        begin
            current_test <= "RTE user-mode privilege beats format    ";
            report "Testing RTE privilege check beats format check..." severity note;

            -- Memory layout:
            -- 0x1000: Supervisor code - drops to user mode
            -- 0x1400: User code - tries RTE (with invalid format on stack)
            -- 0x1700: Privilege violation handler (expected path)
            -- 0x1900: Format error handler (should NOT be reached)

            user_code_addr := 16#1400#;
            priv_handler_addr := 16#1700#;
            format_handler_addr := 16#1900#;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Privilege violation vector (vector 8 = offset 0x20)
            mem(16#20#/2) := x"0000";
            mem(16#20#/2 + 1) := std_logic_vector(to_unsigned(priv_handler_addr, 16));

            -- Format error vector (vector 14 = offset 0x38)
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := std_logic_vector(to_unsigned(format_handler_addr, 16));

            -- Privilege handler - success marker (we expect to get here)
            mem(priv_handler_addr/2) := x"4E72";      -- STOP #$2700
            mem(priv_handler_addr/2 + 1) := x"2700";

            -- Format error handler - failure marker (should NOT reach)
            mem(format_handler_addr/2) := x"4E72";    -- STOP #$2700
            mem(format_handler_addr/2 + 1) := x"2700";

            -- Supervisor startup code at 0x1000:
            -- Build a frame to drop to user mode, then RTE to user code
            mem(16#1000#/2) := x"2E7C";  -- MOVEA.L #$1F00,A7
            mem(16#1002#/2) := x"0000";
            mem(16#1004#/2) := x"1F00";
            -- Push format word (Format 0)
            mem(16#1006#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1008#/2) := x"0000";
            -- Push PC (user code)
            mem(16#100A#/2) := x"3F3C";  -- MOVE.W #$1400,-(A7)
            mem(16#100C#/2) := std_logic_vector(to_unsigned(user_code_addr, 16));
            mem(16#100E#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1010#/2) := x"0000";
            -- Push SR (user mode: S=0)
            mem(16#1012#/2) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(16#1014#/2) := x"0000";
            -- RTE to user mode
            mem(16#1016#/2) := x"4E73";  -- RTE

            -- User mode code at 0x1400:
            -- First, set up a stack with an INVALID format word
            -- Then try RTE - should get privilege violation, NOT format error
            mem(user_code_addr/2) := x"2E7C";      -- MOVEA.L #$1E00,A7
            mem(user_code_addr/2 + 1) := x"0000";
            mem(user_code_addr/2 + 2) := x"1E00";
            -- Push INVALID format word (Format 4 = invalid)
            mem(user_code_addr/2 + 3) := x"3F3C";  -- MOVE.W #$4000,-(A7)
            mem(user_code_addr/2 + 4) := x"4000";  -- Format 4 (invalid)
            -- Push fake PC
            mem(user_code_addr/2 + 5) := x"3F3C";  -- MOVE.W #$1600,-(A7)
            mem(user_code_addr/2 + 6) := x"1600";
            mem(user_code_addr/2 + 7) := x"3F3C";  -- MOVE.W #$0000,-(A7)
            mem(user_code_addr/2 + 8) := x"0000";
            -- Push fake SR (doesn't matter, we won't reach it)
            mem(user_code_addr/2 + 9) := x"3F3C";  -- MOVE.W #$2700,-(A7)
            mem(user_code_addr/2 + 10) := x"2700";
            -- Try RTE in user mode - should trigger PRIVILEGE, not FORMAT ERROR
            mem(user_code_addr/2 + 11) := x"4E73"; -- RTE (privileged!)

            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            saw_priv_vector := false;
            saw_format_vector := false;

            for i in 0 to 15000 loop
                wait until rising_edge(clk);

                -- Check for privilege violation vector read (vector 8 = 0x20)
                if busstate = "10" and addr_out(9 downto 0) = "0000100000" then
                    saw_priv_vector := true;
                end if;

                -- Check for format error vector read (vector 14 = 0x38)
                if busstate = "10" and addr_out(9 downto 0) = "0000111000" then
                    saw_format_vector := true;
                end if;

                -- Success: reached privilege handler
                if addr_out(15 downto 0) = std_logic_vector(to_unsigned(priv_handler_addr, 16)) then
                    if saw_priv_vector and not saw_format_vector then
                        report "PASS: RTE user-mode privilege test - vector 8 before format check" severity note;
                        test_passed <= test_passed + 1;
                    elsif saw_format_vector then
                        report "FAIL: RTE user-mode privilege test - format error reached before privilege" severity error;
                        test_failed <= test_failed + 1;
                    else
                        report "PASS: RTE user-mode privilege test - reached privilege handler" severity note;
                        test_passed <= test_passed + 1;
                    end if;
                    exit;
                end if;

                -- Failure: reached format error handler
                if addr_out(15 downto 0) = std_logic_vector(to_unsigned(format_handler_addr, 16)) then
                    report "FAIL: RTE user-mode privilege test - got format error instead of privilege violation" severity error;
                    report "  This means RTE reached rte4 without triggering privilege check at decode" severity note;
                    test_failed <= test_failed + 1;
                    exit;
                end if;
            end loop;

            wait for 1 us;
        end procedure;

        -- Test RTE Format $0 with exact register state from hardware trace
        -- Verifies SR restoration ($2700 -> $241F), ISP adjustment (+8),
        -- and preservation of all D0-D7 and A0-A6 registers
        -- Hardware trace data (addresses adapted to testbench 16-bit range):
        --   Before: SR=$2700, D0=$D0..D7=$D7, A0=$A0..A6=$A6, ISP=$1FF8
        --   Frame at ISP: SR=$241F, PC=$1200, Format/Vector=$0000
        --   After: SR=$241F, ISP=$2000 (+8), all D/A regs preserved
        procedure test_hardware_trace_rte_format0 is
            variable reached_stop : boolean;
            variable local_fail : boolean;
            variable reg_hi : std_logic_vector(15 downto 0);
            variable reg_lo : std_logic_vector(15 downto 0);
            variable expected_lo : std_logic_vector(15 downto 0);
            variable sr_val : std_logic_vector(15 downto 0);
        begin
            current_test <= "HW trace: RTE Fmt0 SR $2700->$241F      ";
            report "Testing hardware-traced RTE Format 0 with SR/register verification..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error handler (vector 14 = offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";
            mem(16#1300#/2) := x"4E72";      -- STOP #$2700
            mem(16#1300#/2 + 1) := x"2700";

            -- Clear register dump area ($3000-$3042) with known pattern
            for i in 16#3000#/2 to 16#3042#/2 loop
                mem(i) := x"DEAD";
            end loop;

            -- ===== Setup code at $1000: load D0-D7, A0-A6, set ISP, RTE =====
            -- MOVE.L #$000000D0,D0
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"00D0";
            -- MOVE.L #$000000D1,D1
            mem(16#1006#/2) := x"223C"; mem(16#1008#/2) := x"0000"; mem(16#100A#/2) := x"00D1";
            -- MOVE.L #$000000D2,D2
            mem(16#100C#/2) := x"243C"; mem(16#100E#/2) := x"0000"; mem(16#1010#/2) := x"00D2";
            -- MOVE.L #$000000D3,D3
            mem(16#1012#/2) := x"263C"; mem(16#1014#/2) := x"0000"; mem(16#1016#/2) := x"00D3";
            -- MOVE.L #$000000D4,D4
            mem(16#1018#/2) := x"283C"; mem(16#101A#/2) := x"0000"; mem(16#101C#/2) := x"00D4";
            -- MOVE.L #$000000D5,D5
            mem(16#101E#/2) := x"2A3C"; mem(16#1020#/2) := x"0000"; mem(16#1022#/2) := x"00D5";
            -- MOVE.L #$000000D6,D6
            mem(16#1024#/2) := x"2C3C"; mem(16#1026#/2) := x"0000"; mem(16#1028#/2) := x"00D6";
            -- MOVE.L #$000000D7,D7
            mem(16#102A#/2) := x"2E3C"; mem(16#102C#/2) := x"0000"; mem(16#102E#/2) := x"00D7";
            -- MOVEA.L #$000000A0,A0
            mem(16#1030#/2) := x"207C"; mem(16#1032#/2) := x"0000"; mem(16#1034#/2) := x"00A0";
            -- MOVEA.L #$000000A1,A1
            mem(16#1036#/2) := x"227C"; mem(16#1038#/2) := x"0000"; mem(16#103A#/2) := x"00A1";
            -- MOVEA.L #$000000A2,A2
            mem(16#103C#/2) := x"247C"; mem(16#103E#/2) := x"0000"; mem(16#1040#/2) := x"00A2";
            -- MOVEA.L #$000000A3,A3
            mem(16#1042#/2) := x"267C"; mem(16#1044#/2) := x"0000"; mem(16#1046#/2) := x"00A3";
            -- MOVEA.L #$000000A4,A4
            mem(16#1048#/2) := x"287C"; mem(16#104A#/2) := x"0000"; mem(16#104C#/2) := x"00A4";
            -- MOVEA.L #$000000A5,A5
            mem(16#104E#/2) := x"2A7C"; mem(16#1050#/2) := x"0000"; mem(16#1052#/2) := x"00A5";
            -- MOVEA.L #$000000A6,A6
            mem(16#1054#/2) := x"2C7C"; mem(16#1056#/2) := x"0000"; mem(16#1058#/2) := x"00A6";
            -- MOVEA.L #$1FF8,A7 (set ISP to point to exception frame)
            mem(16#105A#/2) := x"2E7C"; mem(16#105C#/2) := x"0000"; mem(16#105E#/2) := x"1FF8";
            -- RTE
            mem(16#1060#/2) := x"4E73";

            -- ===== Exception frame at $1FF8 (Format $0, 8 bytes) =====
            -- SP+0: SR = $241F (supervisor, IPL=4, XNZVC all set)
            mem(16#1FF8#/2) := x"241F";
            -- SP+2: PC high
            mem(16#1FFA#/2) := x"0000";
            -- SP+4: PC low = $1200 (return address for verification code)
            mem(16#1FFC#/2) := x"1200";
            -- SP+6: Format/Vector = $0000 (Format $0, vector 0)
            mem(16#1FFE#/2) := x"0000";

            -- ===== Verification code at $1200: dump regs to memory =====
            -- MOVEM.L D0-D7/A0-A6,($3000).L  -- save 15 registers (60 bytes)
            mem(16#1200#/2) := x"48F9";  -- MOVEM.L reglist,xxx.L
            mem(16#1202#/2) := x"7FFF";  -- register mask: D0-D7, A0-A6
            mem(16#1204#/2) := x"0000";  -- address high
            mem(16#1206#/2) := x"3000";  -- address low
            -- MOVE.W SR,($3040).L  -- save SR FIRST (before any CC-changing instructions)
            mem(16#1208#/2) := x"40F9";  -- MOVE SR,xxx.L
            mem(16#120A#/2) := x"0000";  -- address high
            mem(16#120C#/2) := x"3040";  -- address low
            -- MOVE.L A7,($303C).L  -- save ISP (should be $2000 = $1FF8+8)
            -- Note: MOVE.L changes CC, so this must come AFTER saving SR
            mem(16#120E#/2) := x"23CF";  -- MOVE.L A7,xxx.L
            mem(16#1210#/2) := x"0000";  -- address high
            mem(16#1212#/2) := x"303C";  -- address low
            -- STOP #$2700
            mem(16#1214#/2) := x"4E72";
            mem(16#1216#/2) := x"2700";

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);

                -- Check for format error handler (failure)
                if addr_out(15 downto 0) = x"1300" then
                    report "FAIL: HW trace RTE Format 0 - format error exception triggered" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;

                -- Check for STOP instruction fetch (success path)
                if addr_out(15 downto 0) = x"1214" then
                    reached_stop := true;
                    -- Wait for STOP to complete and all writes to settle
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
            end loop;

            if not reached_stop then
                report "FAIL: HW trace RTE Format 0 - timeout, never reached verification code" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            -- ===== Verify register dump from memory =====
            local_fail := false;

            -- Check D0-D7: each Dn should be $000000Dn
            -- MOVEM.L stores at $3000: D0(4 bytes), D1(4 bytes), ..., D7(4 bytes)
            for i in 0 to 7 loop
                reg_hi := mem(16#3000#/2 + i*2);
                reg_lo := mem(16#3000#/2 + i*2 + 1);
                expected_lo := std_logic_vector(to_unsigned(16#00D0# + i, 16));
                if reg_hi /= x"0000" or reg_lo /= expected_lo then
                    report "  FAIL: D" & integer'image(i) &
                           " = " & integer'image(to_integer(unsigned(reg_hi))) &
                           ":" & integer'image(to_integer(unsigned(reg_lo))) &
                           " expected 0:" & integer'image(16#00D0# + i) severity error;
                    local_fail := true;
                end if;
            end loop;

            -- Check A0-A6: each An should be $000000An
            -- MOVEM.L stores at $3020: A0(4 bytes), A1(4 bytes), ..., A6(4 bytes)
            for i in 0 to 6 loop
                reg_hi := mem(16#3020#/2 + i*2);
                reg_lo := mem(16#3020#/2 + i*2 + 1);
                expected_lo := std_logic_vector(to_unsigned(16#00A0# + i, 16));
                if reg_hi /= x"0000" or reg_lo /= expected_lo then
                    report "  FAIL: A" & integer'image(i) &
                           " = " & integer'image(to_integer(unsigned(reg_hi))) &
                           ":" & integer'image(to_integer(unsigned(reg_lo))) &
                           " expected 0:" & integer'image(16#00A0# + i) severity error;
                    local_fail := true;
                end if;
            end loop;

            -- Check ISP (A7) = $00002000 (frame at $1FF8 + 8 bytes for Format $0)
            reg_hi := mem(16#303C#/2);
            reg_lo := mem(16#303C#/2 + 1);
            if reg_hi /= x"0000" or reg_lo /= x"2000" then
                report "  FAIL: ISP(A7) = " & integer'image(to_integer(unsigned(reg_hi))) &
                       ":" & integer'image(to_integer(unsigned(reg_lo))) &
                       " expected 0:8192 ($00002000)" severity error;
                local_fail := true;
            end if;

            -- Check SR = $241F (supervisor, IPL=4, XNZVC)
            sr_val := mem(16#3040#/2);
            if sr_val /= x"241F" then
                report "  FAIL: SR = " & integer'image(to_integer(unsigned(sr_val))) &
                       " expected 9247 ($241F)" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: HW trace RTE Format 0 - register state mismatch after RTE" severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: HW trace RTE Format 0 - SR=$241F, ISP+8, all 15 registers preserved" severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- Test RTE Format $3 with exact register state from hardware trace
        -- Real hardware accepts Format $3 as a 4-word frame (like Format $0)
        -- Hardware trace data (addresses adapted to testbench 16-bit range):
        --   Before: SR=$2700, D0=$D0..D7=$D7, A0=$A0..A6=$A6, ISP=$1FF8
        --   Frame at ISP: SR=$0000, PC=$1200, Format/Vector=$3672
        --   After: SR=$0000 (user mode), ISP=$2000 (+8), all D/A regs preserved
        procedure test_hardware_trace_rte_format3 is
            variable reached_trap : boolean;
            variable reached_fmterr : boolean;
            variable local_fail : boolean;
            variable reg_hi : std_logic_vector(15 downto 0);
            variable reg_lo : std_logic_vector(15 downto 0);
            variable expected_lo : std_logic_vector(15 downto 0);
            variable ccr_val : std_logic_vector(15 downto 0);
        begin
            current_test <= "HW trace: RTE Fmt3 $3672 SR->$0000      ";
            report "Testing hardware-traced RTE Format 3 ($3672) acceptance..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error handler (vector 14 = offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";
            mem(16#1300#/2) := x"4E72";      -- STOP #$2700
            mem(16#1300#/2 + 1) := x"2700";

            -- TRAP #0 handler (vector 32 = offset $80) -> $1500
            -- Used to return to supervisor mode after RTE to user mode
            mem(16#80#/2) := x"0000";
            mem(16#80#/2 + 1) := x"1500";
            mem(16#1500#/2) := x"4E72";      -- STOP #$2700
            mem(16#1500#/2 + 1) := x"2700";

            -- Privilege violation handler (vector 8 = offset $20) -> $1700
            mem(16#20#/2) := x"0000";
            mem(16#20#/2 + 1) := x"1700";
            mem(16#1700#/2) := x"4E72";      -- STOP #$2700
            mem(16#1700#/2 + 1) := x"2700";

            -- Clear register dump area ($3000-$3042) with known pattern
            for i in 16#3000#/2 to 16#3042#/2 loop
                mem(i) := x"DEAD";
            end loop;

            -- ===== Setup code at $1000: load D0-D7, A0-A6, set ISP, RTE =====
            -- MOVE.L #$000000D0,D0
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"00D0";
            -- MOVE.L #$000000D1,D1
            mem(16#1006#/2) := x"223C"; mem(16#1008#/2) := x"0000"; mem(16#100A#/2) := x"00D1";
            -- MOVE.L #$000000D2,D2
            mem(16#100C#/2) := x"243C"; mem(16#100E#/2) := x"0000"; mem(16#1010#/2) := x"00D2";
            -- MOVE.L #$000000D3,D3
            mem(16#1012#/2) := x"263C"; mem(16#1014#/2) := x"0000"; mem(16#1016#/2) := x"00D3";
            -- MOVE.L #$000000D4,D4
            mem(16#1018#/2) := x"283C"; mem(16#101A#/2) := x"0000"; mem(16#101C#/2) := x"00D4";
            -- MOVE.L #$000000D5,D5
            mem(16#101E#/2) := x"2A3C"; mem(16#1020#/2) := x"0000"; mem(16#1022#/2) := x"00D5";
            -- MOVE.L #$000000D6,D6
            mem(16#1024#/2) := x"2C3C"; mem(16#1026#/2) := x"0000"; mem(16#1028#/2) := x"00D6";
            -- MOVE.L #$000000D7,D7
            mem(16#102A#/2) := x"2E3C"; mem(16#102C#/2) := x"0000"; mem(16#102E#/2) := x"00D7";
            -- MOVEA.L #$000000A0,A0
            mem(16#1030#/2) := x"207C"; mem(16#1032#/2) := x"0000"; mem(16#1034#/2) := x"00A0";
            -- MOVEA.L #$000000A1,A1
            mem(16#1036#/2) := x"227C"; mem(16#1038#/2) := x"0000"; mem(16#103A#/2) := x"00A1";
            -- MOVEA.L #$000000A2,A2
            mem(16#103C#/2) := x"247C"; mem(16#103E#/2) := x"0000"; mem(16#1040#/2) := x"00A2";
            -- MOVEA.L #$000000A3,A3
            mem(16#1042#/2) := x"267C"; mem(16#1044#/2) := x"0000"; mem(16#1046#/2) := x"00A3";
            -- MOVEA.L #$000000A4,A4
            mem(16#1048#/2) := x"287C"; mem(16#104A#/2) := x"0000"; mem(16#104C#/2) := x"00A4";
            -- MOVEA.L #$000000A5,A5
            mem(16#104E#/2) := x"2A7C"; mem(16#1050#/2) := x"0000"; mem(16#1052#/2) := x"00A5";
            -- MOVEA.L #$000000A6,A6
            mem(16#1054#/2) := x"2C7C"; mem(16#1056#/2) := x"0000"; mem(16#1058#/2) := x"00A6";
            -- MOVEA.L #$1FF8,A7 (set ISP to point to exception frame)
            mem(16#105A#/2) := x"2E7C"; mem(16#105C#/2) := x"0000"; mem(16#105E#/2) := x"1FF8";
            -- RTE
            mem(16#1060#/2) := x"4E73";

            -- ===== Exception frame at $1FF8 (Format $3, 8 bytes) =====
            -- SP+0: SR = $0000 (user mode, no flags)
            mem(16#1FF8#/2) := x"0000";
            -- SP+2: PC high
            mem(16#1FFA#/2) := x"0000";
            -- SP+4: PC low = $1200 (return address for verification code)
            mem(16#1FFC#/2) := x"1200";
            -- SP+6: Format/Vector = $3672 (Format $3, vector offset $672)
            mem(16#1FFE#/2) := x"3672";

            -- ===== Verification code at $1200 (user mode): dump regs =====
            -- MOVEM.L D0-D7/A0-A6,($3000).L  -- save 15 registers (works in user mode)
            mem(16#1200#/2) := x"48F9";  -- MOVEM.L reglist,xxx.L
            mem(16#1202#/2) := x"7FFF";  -- register mask: D0-D7, A0-A6
            mem(16#1204#/2) := x"0000";  -- address high
            mem(16#1206#/2) := x"3000";  -- address low
            -- MOVE.W CCR,D0  -- read CCR (not privileged on 68010+)
            mem(16#1208#/2) := x"42C0";  -- MOVE CCR,D0
            -- MOVE.W D0,($3040).L  -- save CCR value
            mem(16#120A#/2) := x"33C0";  -- MOVE.W D0,xxx.L
            mem(16#120C#/2) := x"0000";  -- address high
            mem(16#120E#/2) := x"3040";  -- address low
            -- TRAP #0  -- return to supervisor mode for completion
            mem(16#1210#/2) := x"4E40";  -- TRAP #0

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_trap := false;
            reached_fmterr := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);

                -- Check for TRAP #0 handler (success: Format $3 was accepted)
                if addr_out(15 downto 0) = x"1500" then
                    reached_trap := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;

                -- Check for Format Error handler (Format $3 was rejected)
                if addr_out(15 downto 0) = x"1300" then
                    reached_fmterr := true;
                    exit;
                end if;

                -- Check for privilege violation handler
                if addr_out(15 downto 0) = x"1700" then
                    report "FAIL: HW trace RTE Format 3 - unexpected privilege violation" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;
            end loop;

            -- MC68030 UM: Format $3 is NOT valid - should trigger Format Error
            if not reached_fmterr then
                report "FAIL: HW trace RTE Format 3 - Format Error NOT triggered (should reject Format $3)" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            report "PASS: HW trace RTE Format 3 ($3672) - Format Error correctly triggered" severity note;
            test_passed <= test_passed + 1;
            wait for 1 us;
            return;

            -- ===== Verify register dump from memory =====
            local_fail := false;

            -- Check D0-D7: each Dn should be $000000Dn
            for i in 0 to 7 loop
                reg_hi := mem(16#3000#/2 + i*2);
                reg_lo := mem(16#3000#/2 + i*2 + 1);
                expected_lo := std_logic_vector(to_unsigned(16#00D0# + i, 16));
                if reg_hi /= x"0000" or reg_lo /= expected_lo then
                    report "  FAIL: D" & integer'image(i) &
                           " = " & integer'image(to_integer(unsigned(reg_hi))) &
                           ":" & integer'image(to_integer(unsigned(reg_lo))) &
                           " expected 0:" & integer'image(16#00D0# + i) severity error;
                    local_fail := true;
                end if;
            end loop;

            -- Check A0-A6: each An should be $000000An
            for i in 0 to 6 loop
                reg_hi := mem(16#3020#/2 + i*2);
                reg_lo := mem(16#3020#/2 + i*2 + 1);
                expected_lo := std_logic_vector(to_unsigned(16#00A0# + i, 16));
                if reg_hi /= x"0000" or reg_lo /= expected_lo then
                    report "  FAIL: A" & integer'image(i) &
                           " = " & integer'image(to_integer(unsigned(reg_hi))) &
                           ":" & integer'image(to_integer(unsigned(reg_lo))) &
                           " expected 0:" & integer'image(16#00A0# + i) severity error;
                    local_fail := true;
                end if;
            end loop;

            -- Check CCR = $00 (lower 8 bits of SR=$0000: no flags set)
            ccr_val := mem(16#3040#/2);
            if ccr_val /= x"0000" then
                report "  FAIL: CCR = " & integer'image(to_integer(unsigned(ccr_val))) &
                       " expected 0 ($00)" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: HW trace RTE Format 3 - register state mismatch after RTE" severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: HW trace RTE Format 3 ($3672) - accepted as 4-word frame, all regs preserved" severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

        -- MC68030 Format $1 dual-frame test with M=1 (stack swap)
        -- Tests the full dual-frame mechanism:
        -- 1. Throwaway frame (Format $1) on ISP with M=1 in SR
        -- 2. Normal frame (Format $0) on MSP
        -- 3. RTE consumes throwaway, swaps ISP->MSP, consumes normal, swaps back
        procedure test_format1_dual_frame is
            variable reached_stop : boolean;
            variable local_fail : boolean;
            variable sr_val : std_logic_vector(15 downto 0);
            variable a7_hi : std_logic_vector(15 downto 0);
            variable a7_lo : std_logic_vector(15 downto 0);
        begin
            current_test <= "Fmt1 dual-frame M=1 stack swap          ";
            report "Testing Format $1 dual-frame with M=1 (ISP->MSP swap)..." severity note;

            -- Reset memory
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;

            -- Reset vectors: SSP=$2000, PC=$1000
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";

            -- Format Error handler (vector 14 = offset $38) -> $1300
            mem(16#38#/2) := x"0000";
            mem(16#38#/2 + 1) := x"1300";
            mem(16#1300#/2) := x"4E72";      -- STOP #$2700
            mem(16#1300#/2 + 1) := x"2700";

            -- Clear verification area
            for i in 16#3000#/2 to 16#3050#/2 loop
                mem(i) := x"DEAD";
            end loop;

            -- ===== Setup code at $1000 =====
            -- Set MSP shadow to $1FE8 (where the normal frame will be)
            -- MOVE.L #$1FE8,D0
            mem(16#1000#/2) := x"203C"; mem(16#1002#/2) := x"0000"; mem(16#1004#/2) := x"1FE8";
            -- MOVEC D0,MSP  (4E7B $0803)
            mem(16#1006#/2) := x"4E7B"; mem(16#1008#/2) := x"0803";
            -- Set A7 (=ISP) to $1FF8 (where the throwaway frame will be)
            -- MOVEA.L #$1FF8,A7
            mem(16#100A#/2) := x"2E7C"; mem(16#100C#/2) := x"0000"; mem(16#100E#/2) := x"1FF8";
            -- RTE (execute dual-frame return)
            mem(16#1010#/2) := x"4E73";

            -- ===== ISP throwaway frame at $1FF8 (Format $1, 8 bytes) =====
            -- SR = $3700 (S=1, M=1, IPL=7) - M=1 tells RTE to swap to MSP for second frame
            mem(16#1FF8#/2) := x"3700";
            -- PC = $1200 (copy, will be discarded when second frame provides real PC)
            mem(16#1FFA#/2) := x"0000";
            mem(16#1FFC#/2) := x"1200";
            -- Format/Vector = $1000 (Format $1, vector $000)
            mem(16#1FFE#/2) := x"1000";

            -- ===== MSP normal frame at $1FE8 (Format $0, 8 bytes) =====
            -- SR = $2700 (S=1, M=0, IPL=7) - actual SR for the handler
            mem(16#1FE8#/2) := x"2700";
            -- PC = $1200 (real return address)
            mem(16#1FEA#/2) := x"0000";
            mem(16#1FEC#/2) := x"1200";
            -- Format/Vector = $0000 (Format $0, vector $000)
            mem(16#1FEE#/2) := x"0000";

            -- ===== Verification code at $1200 =====
            -- MOVE.W SR,($3040).L  -- save SR
            mem(16#1200#/2) := x"40F9";
            mem(16#1202#/2) := x"0000";
            mem(16#1204#/2) := x"3040";
            -- MOVE.L A7,($303C).L  -- save A7 (should be ISP=$2000)
            mem(16#1206#/2) := x"23CF";
            mem(16#1208#/2) := x"0000";
            mem(16#120A#/2) := x"303C";
            -- STOP #$2700
            mem(16#120C#/2) := x"4E72";
            mem(16#120E#/2) := x"2700";

            -- ===== Execute =====
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';

            reached_stop := false;
            for i in 0 to 30000 loop
                wait until rising_edge(clk);

                -- Check for format error (failure)
                if addr_out(15 downto 0) = x"1300" then
                    report "FAIL: Format1 dual-frame - format error exception" severity error;
                    test_failed <= test_failed + 1;
                    wait for 1 us;
                    return;
                end if;

                -- Check for STOP at $120C
                if addr_out(15 downto 0) = x"120C" then
                    reached_stop := true;
                    for j in 0 to 100 loop
                        wait until rising_edge(clk);
                    end loop;
                    exit;
                end if;
            end loop;

            if not reached_stop then
                report "FAIL: Format1 dual-frame - timeout" severity error;
                test_failed <= test_failed + 1;
                wait for 1 us;
                return;
            end if;

            -- ===== Verify =====
            local_fail := false;

            -- Check SR = $2700 (from second frame, M=0, S=1, IPL=7)
            sr_val := mem(16#3040#/2);
            if sr_val /= x"2700" then
                report "  FAIL: SR = $" & integer'image(to_integer(unsigned(sr_val))) &
                       " expected $2700 (from second frame)" severity error;
                local_fail := true;
            end if;

            -- Check A7 = $2000 (ISP: original $1FF8 + 8 bytes throwaway consumed)
            a7_hi := mem(16#303C#/2);
            a7_lo := mem(16#303C#/2 + 1);
            if a7_hi /= x"0000" or a7_lo /= x"2000" then
                report "  FAIL: A7 = $" & integer'image(to_integer(unsigned(a7_hi))) &
                       ":" & integer'image(to_integer(unsigned(a7_lo))) &
                       " expected $00002000 (ISP after throwaway consumed)" severity error;
                local_fail := true;
            end if;

            if local_fail then
                report "FAIL: Format1 dual-frame M=1 - state mismatch after dual-frame RTE" severity error;
                test_failed <= test_failed + 1;
            else
                report "PASS: Format1 dual-frame M=1 - SR=$2700, A7=$2000 (dual-frame consumed)" severity note;
                test_passed <= test_passed + 1;
            end if;

            wait for 1 us;
        end procedure;

    begin
        setup_memory;

        report "=========================================================" severity note;
        report "MC68030 RTE Stack Frame Format Validation Test Suite" severity note;
        report "=========================================================" severity note;

        -- Test all valid MC68030 formats
        test_rte_format("0000", "Format 0: Normal 4-word frame", true);
        test_rte_format("0001", "Format 1: Throwaway 4-word frame", true);
        test_rte_format("0010", "Format 2: 6-word instruction frame", true);
        test_rte_format("1001", "Format 9: Coprocessor mid-instr frame", true);
        test_rte_format("1010", "Format A: Short bus fault frame", true);
        test_rte_format("1011", "Format B: Long bus fault frame", true);

        -- Test invalid formats (should all trigger format error)
        -- MC68030 UM: only $0,$1,$2,$9,$A,$B are valid
        test_rte_format("0011", "Format 3: Invalid (reserved)", false);
        test_rte_format("0100", "Format 4: Invalid (reserved)", false);
        test_rte_format("0101", "Format 5: Invalid (reserved)", false);
        test_rte_format("0110", "Format 6: Invalid (reserved)", false);
        test_rte_format("0111", "Format 7: Invalid (reserved)", false);
        test_rte_format("1000", "Format 8: Invalid (68010 only)", false);
        test_rte_format("1100", "Format C: Invalid (reserved)", false);
        test_rte_format("1101", "Format D: Invalid (reserved)", false);
        test_rte_format("1110", "Format E: Invalid (reserved)", false);
        test_rte_format("1111", "Format F: Invalid (reserved)", false);

        -- Test specific format word values (hardware regression tests)
        report "---------------------------------------------------------" severity note;
        report "Testing specific format word values:" severity note;
        -- $3E00 = Format 3 (bits 15:12 = 0011), vector offset $E00
        -- Format 3 is invalid for MC68030, should trigger Format Error
        test_rte_format_word(x"3E00", "Format word $3E00 (Format 3)", false);
        -- $4205 = Format 4 (bits 15:12 = 0100), vector offset $205
        -- Format 4 is invalid for MC68030, should trigger Format Error
        test_rte_format_word(x"4205", "Format word $4205 (Format 4)", false);
        -- $3672 = Format 3 (bits 15:12 = 0011), vector offset $672
        -- Format 3 is invalid for MC68030, should trigger Format Error
        test_rte_format_word(x"3672", "Format word $3672 (Format 3)", false);
        -- $A605 = Format A (bits 15:12 = 1010), vector offset $605
        -- Format A is VALID for MC68030 (short bus fault frame, 16-word)
        test_rte_format_word(x"A605", "Format word $A605 (Format A)", true);
        -- $B605 = Format B (long bus fault frame). WinUAE restores SP+$36 as
        -- MMU internal state, so compatibility requires accepting this frame.
        test_rte_format_word(x"B605", "Format word $B605 (Format B)", true);
        -- Targeted regression: invalid $4205 frame with SR=$0000 must not drop S or corrupt MSP
        test_rte_format4205_s_to_u_msp_preserve;
        -- Format Error frame must contain pre-RTE SR, not frame SR
        test_format_error_preserves_frame_sr;
        -- Invalid RTE must leave A7 unadvanced before stacking Format Error
        test_format_error_restores_a7_before_stack;

        -- Edge case tests for SVmode tracking and timing
        report "---------------------------------------------------------" severity note;
        report "Testing SVmode tracking and RTE timing edge cases:" severity note;

        test_svmode_tracking;
        test_move_to_sr_mode_change;
        test_consecutive_rte;
        test_back_to_back_rte;
        test_rte_user_mode_privilege;

        -- Hardware regression test from real CPU trace
        report "---------------------------------------------------------" severity note;
        report "Testing hardware-traced RTE scenarios:" severity note;

        test_hardware_trace_rte_format0;
        test_hardware_trace_rte_format3;

        -- MC68030 Format $1 dual-frame mechanism test
        report "---------------------------------------------------------" severity note;
        report "Testing MC68030 Format $1 dual-frame mechanism:" severity note;

        test_format1_dual_frame;

        wait for 1 us;

        report "=========================================================" severity note;
        report "Test Results:" severity note;
        report "  Passed: " & integer'image(test_passed) severity note;
        report "  Failed: " & integer'image(test_failed) severity note;
        if test_failed = 0 then
            report "ALL RTE FORMAT TESTS PASSED!" severity note;
        else
            report "SOME RTE FORMAT TESTS FAILED!" severity error;
        end if;
        report "=========================================================" severity note;

        test_done <= true;
        wait;
    end process;

end architecture;
