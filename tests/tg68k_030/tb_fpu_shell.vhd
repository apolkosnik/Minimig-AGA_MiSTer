-- tb_fpu_shell.vhd
-- Focused 68882 shell regression: null FSAVE writes the WinUAE-compatible
-- frame id, FRESTORE postincrements by the WinUAE frame size, and
-- FMOVE.L control-register transfers follow WinUAE selector behavior.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_fpu_shell is
    generic (
        FPU_ENABLE_G : integer := 0
    );
end entity;

architecture behavioral of tb_fpu_shell is
    function slv_to_hex(v : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to v'length / 4);
        variable nibble : integer;
    begin
        for i in 0 to v'length / 4 - 1 loop
            nibble := to_integer(unsigned(v(v'length - 1 - i * 4 downto v'length - 4 - i * 4)));
            result(i + 1) := hex_chars(nibble + 1);
        end loop;
        return result;
    end function;

    signal clk        : std_logic := '0';
    signal nReset     : std_logic := '0';
    signal clkena_in  : std_logic := '1';
    signal data_in    : std_logic_vector(15 downto 0);
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal busstate   : std_logic_vector(1 downto 0);
    signal FC         : std_logic_vector(2 downto 0);
    signal debug_opcode    : std_logic_vector(15 downto 0);
    signal debug_state     : std_logic_vector(1 downto 0);
    signal debug_pc        : std_logic_vector(31 downto 0);
    signal debug_a0        : std_logic_vector(31 downto 0);
    signal debug_a7        : std_logic_vector(31 downto 0);
    signal debug_d2        : std_logic_vector(31 downto 0);
    signal debug_last_data_read : std_logic_vector(31 downto 0);
    signal debug_fline_opcode_latch : std_logic_vector(15 downto 0);
    signal debug_pc_brw    : std_logic;
    signal debug_pc_word   : std_logic;
    signal debug_regfile_we : std_logic;
    signal debug_regfile_waddr : std_logic_vector(3 downto 0);
    signal debug_regfile_wdata : std_logic_vector(31 downto 0);
    signal debug_trap_1111 : std_logic;
    signal debug_trapmake  : std_logic;
    signal debug_trap_vector : std_logic_vector(31 downto 0);
    signal debug_svmode    : std_logic;

    constant CLK_PERIOD : time := 10 ns;
    type mem_array_t is array(0 to 8191) of std_logic_vector(15 downto 0);
    shared variable mem : mem_array_t;
    signal test_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2 when not test_done;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            FPU_Enable => FPU_ENABLE_G,
            FPU_Transcendental_Enable => 0,
            FPU_Packed_Decimal_Enable => 0
        )
        port map(
            clk => clk,
            nReset => nReset,
            clkena_in => clkena_in,
            data_in => data_in,
            IPL => "111",
            IPL_autovector => '1',
            berr => '0',
            CPU => "10",
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
            cacr_ie => open,
            cacr_de => open,
            cacr_ifreeze => open,
            cacr_dfreeze => open,
            cacr_ibe => open,
            cacr_dbe => open,
            cacr_wa => open,
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
            debug_SVmode => debug_svmode,
            debug_opcode => debug_opcode,
            debug_state => debug_state,
            debug_TG68_PC => debug_pc,
            debug_regfile_a0 => debug_a0,
            debug_regfile_a7 => debug_a7,
            debug_regfile_d2 => debug_d2,
            debug_last_data_read => debug_last_data_read,
            debug_fline_opcode_latch => debug_fline_opcode_latch,
            debug_pc_brw => debug_pc_brw,
            debug_pc_word => debug_pc_word,
            debug_regfile_we => debug_regfile_we,
            debug_regfile_waddr => debug_regfile_waddr,
            debug_regfile_wdata => debug_regfile_wdata,
            debug_trap_1111 => debug_trap_1111,
            debug_trapmake => debug_trapmake,
            debug_trap_vector => debug_trap_vector
        );

    data_in <= mem(to_integer(unsigned(addr_out(15 downto 1))))
               when to_integer(unsigned(addr_out(15 downto 1))) <= 8191 else x"4E71";

    mem_write: process(clk)
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                if to_integer(unsigned(addr_out(15 downto 1))) <= 8191 then
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
        procedure clear_mem is
        begin
            nReset <= '0';
            wait for 2 * CLK_PERIOD;
            for i in 0 to 8191 loop
                mem(i) := x"4E71";
            end loop;
            mem(0) := x"0000";
            mem(1) := x"2000";
            mem(2) := x"0000";
            mem(3) := x"1000";
        end procedure;

        procedure reset_and_run(constant cycles : in natural) is
        begin
            nReset <= '0';
            wait for 100 ns;
            nReset <= '1';
            for i in 0 to cycles loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        variable marker   : std_logic_vector(15 downto 0);
        variable frame_id : std_logic_vector(31 downto 0);
        variable cr_value : std_logic_vector(31 downto 0);
        variable stacked_pc : std_logic_vector(31 downto 0);
        variable format_vector : std_logic_vector(15 downto 0);
    begin
        clear_mem;
        -- DiagROM FPU probe: FTST.B D1; FSAVE -(A7). WinUAE marks 6888x FPU
        -- state idle after FTST, so a 68882 FSAVE predecrements by $3C bytes.
        mem(16#1000# / 2) := x"2E7C"; -- MOVEA.L #$00002000,A7
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"2000";
        mem(16#1006# / 2) := x"223C"; -- MOVE.L #$00000001,D1
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"0001";
        mem(16#100C# / 2) := x"F201"; -- FTST.B D1
        mem(16#100E# / 2) := x"583A";
        mem(16#1010# / 2) := x"F327"; -- FSAVE -(A7)
        mem(16#1012# / 2) := x"707E";
        mem(16#1014# / 2) := x"33C0";
        mem(16#1016# / 2) := x"0000";
        mem(16#1018# / 2) := x"1308";
        mem(16#101A# / 2) := x"4E72";
        mem(16#101C# / 2) := x"2700";
        reset_and_run(12000);

        marker := mem(16#1308# / 2);
        frame_id := mem(16#1FC4# / 2) & mem(16#1FC6# / 2);
        if debug_a7 /= x"00001FC4" then
            report "FAIL: DiagROM FTST/FSAVE left A7 $" & slv_to_hex(debug_a7) &
                   ", expected $00001FC4; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) &
                   " fline=" & std_logic'image(debug_trap_1111) &
                   " trapmake=" & std_logic'image(debug_trapmake) severity failure;
        elsif frame_id /= x"1F380000" then
            report "FAIL: DiagROM FTST/FSAVE frame id $" & slv_to_hex(frame_id) &
                   ", expected WinUAE 68882 idle frame $1F380000" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: DiagROM FTST/FSAVE continuation marker $" & slv_to_hex(marker) &
                   ", expected $007E" severity failure;
        else
            report "PASS: DiagROM FTST/FSAVE emits WinUAE 68882 idle frame size" severity note;
        end if;

        clear_mem;
        -- MOVEA.L #$1400,A0; FSAVE -(A0); marker; STOP.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1400";
        mem(16#1006# / 2) := x"F320";
        mem(16#1008# / 2) := x"707E";
        mem(16#100A# / 2) := x"33C0";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"1308";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(6000);

        marker := mem(16#1308# / 2);
        frame_id := mem(16#13FC# / 2) & mem(16#13FE# / 2);
        if debug_a0 /= x"000013FC" then
            report "FAIL: FSAVE -(A0) left A0 $" & slv_to_hex(debug_a0) &
                   ", expected $000013FC; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) & " a0=$" & slv_to_hex(debug_a0) &
                   " state=" & std_logic'image(debug_state(1)) & std_logic'image(debug_state(0)) &
                   " sv=" & std_logic'image(debug_svmode) &
                   " fline=" & std_logic'image(debug_trap_1111) &
                   " trapmake=" & std_logic'image(debug_trapmake) severity failure;
        elsif frame_id /= x"00380000" then
            report "FAIL: FSAVE null frame $" & slv_to_hex(frame_id) & ", expected $00380000" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FSAVE continuation marker $" & slv_to_hex(marker) & ", expected $007E" severity failure;
        else
            report "PASS: FSAVE -(A0) emitted 68882 null frame" severity note;
        end if;

        clear_mem;
        mem(16#1400# / 2) := x"0038";
        mem(16#1402# / 2) := x"0000";
        -- MOVEA.L #$1400,A0; FRESTORE (A0)+; marker; STOP.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1400";
        mem(16#1006# / 2) := x"F358";
        mem(16#1008# / 2) := x"707E";
        mem(16#100A# / 2) := x"33C0";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"1308";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(6000);

        marker := mem(16#1308# / 2);
        if debug_a0 /= x"00001404" then
            report "FAIL: FRESTORE (A0)+ left A0 $" & slv_to_hex(debug_a0) & ", expected $00001404" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FRESTORE continuation marker $" & slv_to_hex(marker) & ", expected $007E" severity failure;
        else
            report "PASS: FRESTORE (A0)+ consumed null frame" severity note;
        end if;

        clear_mem;
        mem(16#1400# / 2) := x"1F38";
        mem(16#1402# / 2) := x"0000";
        -- MOVEA.L #$1400,A0; FRESTORE (A0)+; marker; STOP.
        -- WinUAE fpp.cpp consumes the complete 68882 idle frame:
        -- first longword + frame-size field $38 = $3C bytes total.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1400";
        mem(16#1006# / 2) := x"F358";
        mem(16#1008# / 2) := x"707E";
        mem(16#100A# / 2) := x"33C0";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"1308";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(6000);

        marker := mem(16#1308# / 2);
        if debug_a0 /= x"0000143C" then
            report "FAIL: FRESTORE (A0)+ idle frame left A0 $" & slv_to_hex(debug_a0) &
                   ", expected $0000143C" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FRESTORE idle-frame continuation marker $" & slv_to_hex(marker) &
                   ", expected $007E" severity failure;
        else
            report "PASS: FRESTORE (A0)+ consumed WinUAE 68882 idle frame" severity note;
        end if;

        clear_mem;
        -- MOVE.L #$000000F0,D0; FMOVE.L D0,FPCR; MOVEA.L #$1500,A0;
        -- FMOVE.L FPCR,(A0); marker; STOP.
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"00F0";
        mem(16#1006# / 2) := x"F200";
        mem(16#1008# / 2) := x"9000";
        mem(16#100A# / 2) := x"207C";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"1500";
        mem(16#1010# / 2) := x"F210";
        mem(16#1012# / 2) := x"B000";
        mem(16#1014# / 2) := x"707E";
        mem(16#1016# / 2) := x"33C0";
        mem(16#1018# / 2) := x"0000";
        mem(16#101A# / 2) := x"1308";
        mem(16#101C# / 2) := x"4E72";
        mem(16#101E# / 2) := x"2700";
        reset_and_run(12000);

        marker := mem(16#1308# / 2);
        cr_value := mem(16#1500# / 2) & mem(16#1502# / 2);
        if cr_value /= x"000000F0" then
            report "FAIL: FMOVE.L FPCR,(A0) wrote $" & slv_to_hex(cr_value) & ", expected $000000F0" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FPCR memory-transfer continuation marker $" & slv_to_hex(marker) & ", expected $007E" severity failure;
	        else
	            report "PASS: FMOVE.L D0,FPCR and FPCR,(A0) transferred control data" severity note;
	        end if;

	        clear_mem;
	        -- FMOVE.L #$00000123,FPCR; MOVEA.L #$1500,A0; FMOVE.L FPCR,(A0);
	        -- marker; STOP.
	        mem(16#1000# / 2) := x"F23C";
	        mem(16#1002# / 2) := x"9000";
	        mem(16#1004# / 2) := x"0000";
	        mem(16#1006# / 2) := x"0123";
	        mem(16#1008# / 2) := x"207C";
	        mem(16#100A# / 2) := x"0000";
	        mem(16#100C# / 2) := x"1500";
	        mem(16#100E# / 2) := x"F210";
	        mem(16#1010# / 2) := x"B000";
	        mem(16#1012# / 2) := x"707E";
	        mem(16#1014# / 2) := x"33C0";
	        mem(16#1016# / 2) := x"0000";
	        mem(16#1018# / 2) := x"1308";
	        mem(16#101A# / 2) := x"4E72";
	        mem(16#101C# / 2) := x"2700";
	        reset_and_run(12000);

	        marker := mem(16#1308# / 2);
	        cr_value := mem(16#1500# / 2) & mem(16#1502# / 2);
	        if cr_value /= x"00000123" then
	            report "FAIL: FMOVE.L #imm,FPCR wrote $" & slv_to_hex(cr_value) & ", expected $00000123" severity failure;
	        elsif marker /= x"007E" then
	            report "FAIL: FPCR immediate continuation marker $" & slv_to_hex(marker) & ", expected $007E" severity failure;
        else
            report "PASS: FMOVE.L #imm,FPCR follows WinUAE immediate control flow" severity note;
        end if;

        clear_mem;
        -- Vector 11 Line-F handler captures the stacked PC and format/vector word.
        mem(16#002C# / 2) := x"0000";
        mem(16#002E# / 2) := x"1180";
        mem(16#1180# / 2) := x"202F"; -- MOVE.L (2,SP),D0
        mem(16#1182# / 2) := x"0002";
        mem(16#1184# / 2) := x"23C0"; -- MOVE.L D0,$1300
        mem(16#1186# / 2) := x"0000";
        mem(16#1188# / 2) := x"1300";
        mem(16#118A# / 2) := x"302F"; -- MOVE.W (6,SP),D0
        mem(16#118C# / 2) := x"0006";
        mem(16#118E# / 2) := x"33C0"; -- MOVE.W D0,$1304
        mem(16#1190# / 2) := x"0000";
        mem(16#1192# / 2) := x"1304";
        mem(16#1194# / 2) := x"700B"; -- MOVEQ #$0B,D0
        mem(16#1196# / 2) := x"33C0"; -- MOVE.W D0,$1308
        mem(16#1198# / 2) := x"0000";
        mem(16#119A# / 2) := x"1308";
        mem(16#119C# / 2) := x"4E72";
        mem(16#119E# / 2) := x"2700";
        -- FMOVE.W #1,FP1; LEA (-$18,A4),A0; marker; STOP.
        -- Shell-only mode still raises Line-F and the frame must point to
        -- the FPU extension word. With the imported core enabled, the CPU
        -- shell must consume the immediate word before handing the op to the
        -- core, so the OS emulator handler must not run.
        mem(16#1000# / 2) := x"F23C";
        mem(16#1002# / 2) := x"5080";
        mem(16#1004# / 2) := x"0001";
        mem(16#1006# / 2) := x"41EC";
        mem(16#1008# / 2) := x"FFE8";
        mem(16#100A# / 2) := x"33FC";
        mem(16#100C# / 2) := x"00F1";
        mem(16#100E# / 2) := x"0000";
        mem(16#1010# / 2) := x"1308";
        mem(16#1012# / 2) := x"4E72";
        mem(16#1014# / 2) := x"2700";
        reset_and_run(12000);

        marker := mem(16#1308# / 2);
        stacked_pc := mem(16#1300# / 2) & mem(16#1302# / 2);
        format_vector := mem(16#1304# / 2);
        if FPU_ENABLE_G = 0 then
            if marker /= x"000B" then
                report "FAIL: FMOVE.W #imm,FP1 did not reach Line-F handler; marker=$" &
                       slv_to_hex(marker) & " dbg pc=$" & slv_to_hex(debug_pc) &
                       " opcode=$" & slv_to_hex(debug_opcode) severity failure;
            elsif stacked_pc /= x"00001002" then
                report "FAIL: FMOVE.W #imm,FP1 Line-F stacked PC=$" & slv_to_hex(stacked_pc) &
                       ", expected $00001002" severity failure;
            elsif format_vector /= x"002C" then
                report "FAIL: FMOVE.W #imm,FP1 format/vector=$" & slv_to_hex(format_vector) &
                       ", expected $002C" severity failure;
            else
                report "PASS: FMOVE.W #imm,FP1 Line-F frame points at extension word" severity note;
            end if;
        else
            if marker /= x"00F1" then
                report "FAIL: enabled FPU path leaked FMOVE.W #imm,FP1 or missed continuation; marker=$" &
                       slv_to_hex(marker) & " dbg pc=$" & slv_to_hex(debug_pc) &
                       " opcode=$" & slv_to_hex(debug_opcode) severity failure;
            else
                report "PASS: enabled FPU path consumes FMOVE.W #imm,FP1 without Line-F" severity note;
            end if;
        end if;

        if FPU_ENABLE_G = 1 then
            clear_mem;
            mem(16#002C# / 2) := x"0000";
            mem(16#002E# / 2) := x"1180";
            mem(16#1180# / 2) := x"700B"; -- MOVEQ #$0B,D0
            mem(16#1182# / 2) := x"33C0"; -- MOVE.W D0,$1308
            mem(16#1184# / 2) := x"0000";
            mem(16#1186# / 2) := x"1308";
            mem(16#1188# / 2) := x"4E72";
            mem(16#118A# / 2) := x"2700";
            -- FMOVE.W #1,FP1; FSQRT.X FP1; FADD.X FP1,FP1; marker; STOP.
            mem(16#1000# / 2) := x"F23C";
            mem(16#1002# / 2) := x"5080";
            mem(16#1004# / 2) := x"0001";
            mem(16#1006# / 2) := x"F200";
            mem(16#1008# / 2) := x"0484";
            mem(16#100A# / 2) := x"F200";
            mem(16#100C# / 2) := x"04A2";
            mem(16#100E# / 2) := x"33FC";
            mem(16#1010# / 2) := x"00F3";
            mem(16#1012# / 2) := x"0000";
            mem(16#1014# / 2) := x"1308";
            mem(16#1016# / 2) := x"4E72";
            mem(16#1018# / 2) := x"2700";
            reset_and_run(16000);

            marker := mem(16#1308# / 2);
            if marker /= x"00F3" then
                report "FAIL: enabled FPU path leaked FMOVE.W/FSQRT.X/FADD.X sequence; marker=$" &
                       slv_to_hex(marker) & " dbg pc=$" & slv_to_hex(debug_pc) &
                       " opcode=$" & slv_to_hex(debug_opcode) severity failure;
            else
                report "PASS: enabled FPU path keeps FMOVE.W/FSQRT.X/FADD.X out of Line-F" severity note;
            end if;
        end if;

	        clear_mem;
	        mem(16#1400# / 2) := x"CAFE";
        mem(16#1402# / 2) := x"BABE";
        -- MOVEA.L #$1400,A0; MOVEA.L #$1500,A1; FMOVE.L (A0)+,FPIAR;
        -- FMOVE.L FPIAR,(A1); marker; STOP.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1400";
        mem(16#1006# / 2) := x"227C";
        mem(16#1008# / 2) := x"0000";
        mem(16#100A# / 2) := x"1500";
        mem(16#100C# / 2) := x"F218";
        mem(16#100E# / 2) := x"8400";
        mem(16#1010# / 2) := x"F211";
        mem(16#1012# / 2) := x"A400";
        mem(16#1014# / 2) := x"707E";
        mem(16#1016# / 2) := x"33C0";
        mem(16#1018# / 2) := x"0000";
        mem(16#101A# / 2) := x"1308";
        mem(16#101C# / 2) := x"4E72";
        mem(16#101E# / 2) := x"2700";
        reset_and_run(12000);

        marker := mem(16#1308# / 2);
        cr_value := mem(16#1500# / 2) & mem(16#1502# / 2);
        if debug_a0 /= x"00001404" then
            report "FAIL: FMOVE.L (A0)+,FPIAR left A0 $" & slv_to_hex(debug_a0) & ", expected $00001404" severity failure;
        elsif cr_value /= x"CAFEBABE" then
            report "FAIL: FMOVE.L FPIAR,(A1) wrote $" & slv_to_hex(cr_value) & ", expected $CAFEBABE" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FPIAR memory-transfer continuation marker $" & slv_to_hex(marker) &
                   ", expected $007E; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) severity failure;
        else
            report "PASS: FMOVE.L (A0)+,FPIAR and FPIAR,(A1) matched WinUAE control flow" severity note;
        end if;

        clear_mem;
        -- MOVE.L #$12345678,D0; FMOVE.L D0,FPIAR; MOVEA.L #$1504,A0;
        -- FMOVE.L FPIAR,-(A0); marker; STOP.
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"1234";
        mem(16#1004# / 2) := x"5678";
        mem(16#1006# / 2) := x"F200";
        mem(16#1008# / 2) := x"8400";
        mem(16#100A# / 2) := x"207C";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"1504";
        mem(16#1010# / 2) := x"F220";
        mem(16#1012# / 2) := x"A400";
        mem(16#1014# / 2) := x"707E";
        mem(16#1016# / 2) := x"33C0";
        mem(16#1018# / 2) := x"0000";
        mem(16#101A# / 2) := x"1308";
        mem(16#101C# / 2) := x"4E72";
        mem(16#101E# / 2) := x"2700";
        reset_and_run(12000);

        marker := mem(16#1308# / 2);
        cr_value := mem(16#1500# / 2) & mem(16#1502# / 2);
        if debug_a0 /= x"00001500" then
            report "FAIL: FMOVE.L FPIAR,-(A0) left A0 $" & slv_to_hex(debug_a0) & ", expected $00001500" severity failure;
        elsif cr_value /= x"12345678" then
            report "FAIL: FMOVE.L FPIAR,-(A0) wrote $" & slv_to_hex(cr_value) & ", expected $12345678" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FPIAR predecrement continuation marker $" & slv_to_hex(marker) & ", expected $007E" severity failure;
        else
            report "PASS: FMOVE.L FPIAR,-(A0) predecremented and stored control data" severity note;
        end if;

        clear_mem;
        -- OS-style context path: set FPCR/FPSR/FPIAR, save all three with
        -- FMOVEM.L FPCR/FPSR/FPIAR,-(A0), restore with (A0)+, then store them
        -- back with FMOVEM.L FPCR/FPSR/FPIAR,(A0). WinUAE orders memory as
        -- FPCR, FPSR, FPIAR and moves A0 by 12 bytes.
        mem(16#1000# / 2) := x"203C";
        mem(16#1002# / 2) := x"1111";
        mem(16#1004# / 2) := x"1111";
        mem(16#1006# / 2) := x"F200";
        mem(16#1008# / 2) := x"9000";
        mem(16#100A# / 2) := x"203C";
        mem(16#100C# / 2) := x"2222";
        mem(16#100E# / 2) := x"2222";
        mem(16#1010# / 2) := x"F200";
        mem(16#1012# / 2) := x"8800";
        mem(16#1014# / 2) := x"203C";
        mem(16#1016# / 2) := x"3333";
        mem(16#1018# / 2) := x"3333";
        mem(16#101A# / 2) := x"F200";
        mem(16#101C# / 2) := x"8400";
        mem(16#101E# / 2) := x"207C";
        mem(16#1020# / 2) := x"0000";
        mem(16#1022# / 2) := x"1510";
        mem(16#1024# / 2) := x"F220";
        mem(16#1026# / 2) := x"BC00";
        mem(16#1028# / 2) := x"F218";
        mem(16#102A# / 2) := x"9C00";
        mem(16#102C# / 2) := x"F210";
        mem(16#102E# / 2) := x"BC00";
        mem(16#1030# / 2) := x"707E";
        mem(16#1032# / 2) := x"33C0";
        mem(16#1034# / 2) := x"0000";
        mem(16#1036# / 2) := x"1308";
        mem(16#1038# / 2) := x"4E72";
        mem(16#103A# / 2) := x"2700";
        reset_and_run(50000);

        marker := mem(16#1308# / 2);
        if debug_a0 /= x"00001510" then
            report "FAIL: FMOVEM CR context left A0 $" & slv_to_hex(debug_a0) &
                   ", expected $00001510" severity failure;
        elsif (mem(16#1504# / 2) & mem(16#1506# / 2)) /= x"11111111" then
            report "FAIL: FMOVEM CR save FPCR $" &
                   slv_to_hex(mem(16#1504# / 2) & mem(16#1506# / 2)) &
                   ", expected $11111111" severity failure;
        elsif (mem(16#1508# / 2) & mem(16#150A# / 2)) /= x"22222222" then
            report "FAIL: FMOVEM CR save FPSR $" &
                   slv_to_hex(mem(16#1508# / 2) & mem(16#150A# / 2)) &
                   ", expected $22222222" severity failure;
        elsif (mem(16#150C# / 2) & mem(16#150E# / 2)) /= x"33333333" then
            report "FAIL: FMOVEM CR save FPIAR $" &
                   slv_to_hex(mem(16#150C# / 2) & mem(16#150E# / 2)) &
                   ", expected $33333333" severity failure;
        elsif (mem(16#1510# / 2) & mem(16#1512# / 2)) /= x"11111111" then
            report "FAIL: FMOVEM CR restore/store FPCR $" &
                   slv_to_hex(mem(16#1510# / 2) & mem(16#1512# / 2)) &
                   ", expected $11111111" severity failure;
        elsif (mem(16#1514# / 2) & mem(16#1516# / 2)) /= x"22222222" then
            report "FAIL: FMOVEM CR restore/store FPSR $" &
                   slv_to_hex(mem(16#1514# / 2) & mem(16#1516# / 2)) &
                   ", expected $22222222" severity failure;
        elsif (mem(16#1518# / 2) & mem(16#151A# / 2)) /= x"33333333" then
            report "FAIL: FMOVEM CR restore/store FPIAR $" &
                   slv_to_hex(mem(16#1518# / 2) & mem(16#151A# / 2)) &
                   ", expected $33333333" severity failure;
        elsif marker /= x"007E" then
            report "FAIL: FMOVEM CR context continuation marker $" & slv_to_hex(marker) &
                   ", expected $007E; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) &
                   " fline=" & std_logic'image(debug_trap_1111) severity failure;
        else
            report "PASS: FMOVEM.L FPCR/FPSR/FPIAR context path matches WinUAE order" severity note;
        end if;

        clear_mem;
        -- MOVEQ #0,D1; FTST.L D1; FMOVE.L FPSR,D3; MOVE.L D3,$130C;
        -- MOVEQ #0,D2; FSEQ D2; MOVE.W D2,$1308; STOP.
        -- WinUAE fpp_cond(1) maps to Z set.
        mem(16#1000# / 2) := x"7200";
        mem(16#1002# / 2) := x"F201";
        mem(16#1004# / 2) := x"003A";
        mem(16#1006# / 2) := x"F203";
        mem(16#1008# / 2) := x"A800";
        mem(16#100A# / 2) := x"23C3";
        mem(16#100C# / 2) := x"0000";
        mem(16#100E# / 2) := x"130C";
        mem(16#1010# / 2) := x"7400";
        mem(16#1012# / 2) := x"F242";
        mem(16#1014# / 2) := x"0001";
        mem(16#1016# / 2) := x"33C2";
        mem(16#1018# / 2) := x"0000";
        mem(16#101A# / 2) := x"1308";
        mem(16#101C# / 2) := x"4E72";
        mem(16#101E# / 2) := x"2700";
        reset_and_run(16000);

        marker := mem(16#1308# / 2);
        cr_value := mem(16#130C# / 2) & mem(16#130E# / 2);
        if cr_value /= x"04000000" then
            report "FAIL: FTST.L zero FPSR readback $" & slv_to_hex(cr_value) &
                   ", expected $04000000; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) severity failure;
        elsif marker /= x"00FF" then
            report "FAIL: FSEQ D2 wrote $" & slv_to_hex(marker) &
                   ", expected $00FF; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) &
                   " fline=" & std_logic'image(debug_trap_1111) severity failure;
        else
            report "PASS: FScc Dn uses WinUAE FPSR condition mapping" severity note;
        end if;

        clear_mem;
        -- MOVEA.L #$1400,A0; MOVEQ #0,D1; FTST.L D1; FSEQ (A0)+; STOP.
        -- WinUAE FScc writes one byte and postincrements non-A7 byte destinations by 1.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1400";
        mem(16#1006# / 2) := x"7200";
        mem(16#1008# / 2) := x"F201";
        mem(16#100A# / 2) := x"003A";
        mem(16#100C# / 2) := x"F258";
        mem(16#100E# / 2) := x"0001";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(10000);

        if mem(16#1400# / 2) /= x"FF71" then
            report "FAIL: FSEQ (A0)+ wrote word $" & slv_to_hex(mem(16#1400# / 2)) &
                   ", expected $FF71" severity failure;
        elsif debug_a0 /= x"00001401" then
            report "FAIL: FSEQ (A0)+ left A0 $" & slv_to_hex(debug_a0) &
                   ", expected $00001401" severity failure;
        else
            report "PASS: FScc (An)+ writes byte and postincrements like WinUAE" severity note;
        end if;

        clear_mem;
        -- MOVEA.L #$1402,A0; MOVEQ #1,D1; FTST.L D1; FSEQ -(A0); STOP.
        -- False condition writes $00 at the predecremented odd byte address.
        mem(16#1000# / 2) := x"207C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1402";
        mem(16#1006# / 2) := x"7201";
        mem(16#1008# / 2) := x"F201";
        mem(16#100A# / 2) := x"003A";
        mem(16#100C# / 2) := x"F260";
        mem(16#100E# / 2) := x"0001";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(10000);

        if mem(16#1400# / 2) /= x"4E00" then
            report "FAIL: FSEQ -(A0) wrote word $" & slv_to_hex(mem(16#1400# / 2)) &
                   ", expected $4E00" severity failure;
        elsif debug_a0 /= x"00001401" then
            report "FAIL: FSEQ -(A0) left A0 $" & slv_to_hex(debug_a0) &
                   ", expected $00001401" severity failure;
        else
            report "PASS: FScc -(An) predecrements and writes false byte like WinUAE" severity note;
        end if;

        clear_mem;
        -- MOVEA.L #$1404,A7; MOVEQ #0,D1; FTST.L D1; FSEQ -(A7); STOP.
        -- WinUAE uses stack byte adjustment of 2 for A7.
        mem(16#1000# / 2) := x"2E7C";
        mem(16#1002# / 2) := x"0000";
        mem(16#1004# / 2) := x"1404";
        mem(16#1006# / 2) := x"7200";
        mem(16#1008# / 2) := x"F201";
        mem(16#100A# / 2) := x"003A";
        mem(16#100C# / 2) := x"F267";
        mem(16#100E# / 2) := x"0001";
        mem(16#1010# / 2) := x"4E72";
        mem(16#1012# / 2) := x"2700";
        reset_and_run(10000);

        if mem(16#1402# / 2) /= x"FF71" then
            report "FAIL: FSEQ -(A7) wrote word $" & slv_to_hex(mem(16#1402# / 2)) &
                   ", expected $FF71" severity failure;
        elsif debug_a7 /= x"00001402" then
            report "FAIL: FSEQ -(A7) left A7 $" & slv_to_hex(debug_a7) &
                   ", expected $00001402" severity failure;
        else
            report "PASS: FScc -(A7) uses WinUAE stack byte adjustment" severity note;
        end if;

        clear_mem;
        -- MOVEQ #0,D1; FTST.L D1; MOVEQ #0,D2; FDBNE D2,*+2;
        -- MOVE.W D2,$1308; STOP.
        -- WinUAE fpuop_dbcc decrements the low word when the FP condition is false
        -- and does not branch once the counter reaches $FFFF.
        mem(16#1000# / 2) := x"7200";
        mem(16#1002# / 2) := x"F201";
        mem(16#1004# / 2) := x"003A";
        mem(16#1006# / 2) := x"7400";
        mem(16#1008# / 2) := x"F24A";
        mem(16#100A# / 2) := x"000E";
        mem(16#100C# / 2) := x"0002";
        mem(16#100E# / 2) := x"33C2";
        mem(16#1010# / 2) := x"0000";
        mem(16#1012# / 2) := x"1308";
        mem(16#1014# / 2) := x"4E72";
        mem(16#1016# / 2) := x"2700";
        reset_and_run(14000);

        marker := mem(16#1308# / 2);
        if marker /= x"FFFF" then
            report "FAIL: FDBNE expired counter wrote $" & slv_to_hex(marker) &
                   ", expected $FFFF; dbg opcode=$" & slv_to_hex(debug_opcode) &
                   " pc=$" & slv_to_hex(debug_pc) &
                   " d2=$" & slv_to_hex(debug_d2) &
                   " ldr=$" & slv_to_hex(debug_last_data_read) &
                   " fline=$" & slv_to_hex(debug_fline_opcode_latch) &
                   " pc_brw=" & std_logic'image(debug_pc_brw) &
                   " pc_word=" & std_logic'image(debug_pc_word) &
                   " rwe=" & std_logic'image(debug_regfile_we) &
                   " rwa=$" & slv_to_hex(debug_regfile_waddr) &
                   " rwd=$" & slv_to_hex(debug_regfile_wdata) severity failure;
	        else
	            report "PASS: FDBcc false condition decrements Dn like WinUAE" severity note;
	        end if;

	        clear_mem;
	        -- FBT.W branches from the extension-word PC, matching WinUAE fpuop_bcc().
	        mem(16#1000# / 2) := x"F28F";
	        mem(16#1002# / 2) := x"000E";
	        mem(16#1004# / 2) := x"33FC";
	        mem(16#1006# / 2) := x"1111";
	        mem(16#1008# / 2) := x"0000";
	        mem(16#100A# / 2) := x"1308";
	        mem(16#100C# / 2) := x"4E72";
	        mem(16#100E# / 2) := x"2700";
	        mem(16#1010# / 2) := x"33FC";
	        mem(16#1012# / 2) := x"2222";
	        mem(16#1014# / 2) := x"0000";
	        mem(16#1016# / 2) := x"1308";
	        mem(16#1018# / 2) := x"4E72";
	        mem(16#101A# / 2) := x"2700";
	        reset_and_run(12000);

	        marker := mem(16#1308# / 2);
	        if marker /= x"2222" then
	            report "FAIL: FBT.W marker $" & slv_to_hex(marker) &
	                   ", expected branch target marker $2222; pc=$" & slv_to_hex(debug_pc) &
	                   " fline=$" & slv_to_hex(debug_fline_opcode_latch) severity failure;
	        else
	            report "PASS: FBcc.W true branches from WinUAE base PC" severity note;
	        end if;

	        clear_mem;
	        -- FBF.W consumes the displacement and falls through without F-line trapping.
	        mem(16#1000# / 2) := x"F280";
	        mem(16#1002# / 2) := x"000E";
	        mem(16#1004# / 2) := x"33FC";
	        mem(16#1006# / 2) := x"1111";
	        mem(16#1008# / 2) := x"0000";
	        mem(16#100A# / 2) := x"1308";
	        mem(16#100C# / 2) := x"4E72";
	        mem(16#100E# / 2) := x"2700";
	        mem(16#1010# / 2) := x"33FC";
	        mem(16#1012# / 2) := x"2222";
	        mem(16#1014# / 2) := x"0000";
	        mem(16#1016# / 2) := x"1308";
	        mem(16#1018# / 2) := x"4E72";
	        mem(16#101A# / 2) := x"2700";
	        reset_and_run(12000);

	        marker := mem(16#1308# / 2);
	        if marker /= x"1111" then
	            report "FAIL: FBF.W marker $" & slv_to_hex(marker) &
	                   ", expected fallthrough marker $1111; pc=$" & slv_to_hex(debug_pc) severity failure;
	        else
	            report "PASS: FBcc.W false consumes displacement and falls through" severity note;
	        end if;

	        clear_mem;
	        -- FBT.L combines the high/low displacement words and uses the same WinUAE base.
	        mem(16#1000# / 2) := x"F2CF";
	        mem(16#1002# / 2) := x"0000";
	        mem(16#1004# / 2) := x"0010";
	        mem(16#1006# / 2) := x"33FC";
	        mem(16#1008# / 2) := x"1111";
	        mem(16#100A# / 2) := x"0000";
	        mem(16#100C# / 2) := x"1308";
	        mem(16#100E# / 2) := x"4E72";
	        mem(16#1010# / 2) := x"2700";
	        mem(16#1012# / 2) := x"33FC";
	        mem(16#1014# / 2) := x"3333";
	        mem(16#1016# / 2) := x"0000";
	        mem(16#1018# / 2) := x"1308";
	        mem(16#101A# / 2) := x"4E72";
	        mem(16#101C# / 2) := x"2700";
	        reset_and_run(14000);

	        marker := mem(16#1308# / 2);
	        if marker /= x"3333" then
	            report "FAIL: FBT.L marker $" & slv_to_hex(marker) &
	                   ", expected branch target marker $3333; pc=$" & slv_to_hex(debug_pc) severity failure;
	        else
	            report "PASS: FBcc.L true branches with WinUAE long displacement" severity note;
	        end if;

	        clear_mem;
	        -- FTRAPcc.L false must consume condition + long dummy operand and continue.
	        mem(16#1000# / 2) := x"F27B";
	        mem(16#1002# / 2) := x"0000";
	        mem(16#1004# / 2) := x"AAAA";
	        mem(16#1006# / 2) := x"BBBB";
	        mem(16#1008# / 2) := x"33FC";
	        mem(16#100A# / 2) := x"4444";
	        mem(16#100C# / 2) := x"0000";
	        mem(16#100E# / 2) := x"1308";
	        mem(16#1010# / 2) := x"4E72";
	        mem(16#1012# / 2) := x"2700";
	        reset_and_run(14000);

	        marker := mem(16#1308# / 2);
	        if marker /= x"4444" then
	            report "FAIL: FTRAPF.L marker $" & slv_to_hex(marker) &
	                   ", expected fallthrough marker $4444; pc=$" & slv_to_hex(debug_pc) severity failure;
	        else
	            report "PASS: FTRAPcc.L false consumes WinUAE dummy operand" severity note;
	        end if;

	        clear_mem;
	        -- FTRAPT with no dummy operand dispatches vector 7.
	        mem(16#001C# / 2) := x"0000";
	        mem(16#001E# / 2) := x"1200";
	        mem(16#1000# / 2) := x"F27C";
	        mem(16#1002# / 2) := x"000F";
	        mem(16#1004# / 2) := x"33FC";
	        mem(16#1006# / 2) := x"1111";
	        mem(16#1008# / 2) := x"0000";
	        mem(16#100A# / 2) := x"1308";
	        mem(16#100C# / 2) := x"4E72";
	        mem(16#100E# / 2) := x"2700";
	        mem(16#1200# / 2) := x"33FC";
	        mem(16#1202# / 2) := x"5555";
	        mem(16#1204# / 2) := x"0000";
	        mem(16#1206# / 2) := x"1308";
	        mem(16#1208# / 2) := x"4E72";
	        mem(16#120A# / 2) := x"2700";
	        reset_and_run(22000);

	        marker := mem(16#1308# / 2);
	        if marker /= x"5555" then
	            report "FAIL: FTRAPT marker $" & slv_to_hex(marker) &
	                   ", expected vector-7 handler marker $5555; pc=$" & slv_to_hex(debug_pc) &
	                   " a7=$" & slv_to_hex(debug_a7) &
	                   " trapvec=$" & slv_to_hex(debug_trap_vector) severity failure;
	        else
	            report "PASS: FTRAPcc true dispatches vector 7 like WinUAE" severity note;
	        end if;

	        test_done <= true;
	        wait;
    end process;
end architecture;
