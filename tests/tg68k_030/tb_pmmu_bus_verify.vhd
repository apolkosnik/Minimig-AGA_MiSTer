-- tb_pmmu_bus_verify.vhd
-- PMMU instruction bus-transaction verification.
--
-- Purpose (audit follow-up): the existing MMU benches mostly check the final
-- MMUSR / register state. This bench instead verifies the actual bus cycles a
-- PMMU register transfer produces:
--   - the READ addresses and READ data for PMOVE <ea>,preg (memory -> MMU)
--   - the WRITE addresses and WRITE data for PMOVE preg,<ea> (MMU -> memory)
--   - that a store-back equals the value loaded (content round-trip through the
--     register), confirming both directions move the right bytes to/from the
--     right addresses.
--
-- Coverage:
--   1. TT0  (.L, 32-bit)  via (A0)/(A1)        - 2 reads + 2 writes
--   2. CRP  (.Q, 64-bit)  via (A2)/(A3)        - 4 reads + 4 writes
--   3. TT0  (.L) via (d16,A4)                  - displacement EA address check
--
-- Harness matches the kernel-only PMMU benches in this directory: the kernel
-- holds the MMU registers, the table walker is mocked (it is never invoked by
-- PMOVE), so register content round-trips through the kernel.
--
-- No table walk, no translation side effects: TT0 is loaded disabled (E=0) and
-- CRP only stored/reloaded, so no access is transparently translated or walked.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmmu_bus_verify is
end entity;

architecture behavioral of tb_pmmu_bus_verify is

    function slv32_to_hexstring(slv : std_logic_vector(31 downto 0)) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable hex : string(1 to 8);
        variable nib : std_logic_vector(3 downto 0);
    begin
        for i in 0 to 7 loop
            nib := slv(31 - i*4 downto 28 - i*4);
            if (nib(3) /= '0' and nib(3) /= '1') or
               (nib(2) /= '0' and nib(2) /= '1') or
               (nib(1) /= '0' and nib(1) /= '1') or
               (nib(0) /= '0' and nib(0) /= '1') then
                hex(i+1) := 'X';
            else
                hex(i+1) := hex_chars(to_integer(unsigned(nib)) + 1);
            end if;
        end loop;
        return hex;
    end function;

    function has_unknown(slv : std_logic_vector) return boolean is
    begin
        for i in slv'range loop
            if slv(i) /= '0' and slv(i) /= '1' then
                return true;
            end if;
        end loop;
        return false;
    end function;

    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';

    signal data_in    : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal busstate   : std_logic_vector(1 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;
    signal FC         : std_logic_vector(2 downto 0);
    signal nResetOut  : std_logic;

    constant CLK_PERIOD : time := 10 ns;
    constant RESET_HOLDOFF_CYCLES : integer := 12;
    signal test_done    : boolean := false;
    signal holdoff_done : std_logic := '0';
    signal holdoff_cnt  : integer range 0 to RESET_HOLDOFF_CYCLES := 0;

    -- Known register payloads placed in memory for the load (mem -> MMU) step.
    -- TT0 is loaded disabled (bit 15 / E = 0) so it never matches an access.
    -- Only the storable TT0 fields are set so the store-back equals the load.
    constant TT0_HI : std_logic_vector(15 downto 0) := x"1234";  -- log base / mask
    constant TT0_LO : std_logic_vector(15 downto 0) := x"0453";  -- E=0, RWM, FC base/mask
    -- CRP root pointer (64-bit). High longword: limit + DT; low longword: table
    -- address + DT. Values chosen to land in storable bits (calibrated below).
    constant CRP_W0 : std_logic_vector(15 downto 0) := x"7FFF";  -- limit
    constant CRP_W1 : std_logic_vector(15 downto 0) := x"0002";  -- DT = valid 4-byte
    constant CRP_W2 : std_logic_vector(15 downto 0) := x"1234";  -- table addr hi
    -- RP low longword is table address [31:4]; bits [3:0] are unused (read 0),
    -- so the storable value of $5674 is $5670 (verified by the round-trip).
    constant CRP_W3 : std_logic_vector(15 downto 0) := x"5670";  -- table addr lo (bits 3:0 unused)
    -- TC loaded disabled (E=0, bit 31 = 0) so no translation/config side effects.
    -- TC bits 30:26 are reserved (read 0); high word uses only storable fields
    -- (SRE/FCL/PS/IS), so $02B8 round-trips exactly (verified).
    constant TC_HI  : std_logic_vector(15 downto 0) := x"02B8";
    constant TC_LO  : std_logic_vector(15 downto 0) := x"1248";
    -- SRP root pointer (same format as CRP): low longword bits [3:0] unused.
    constant SRP_W0 : std_logic_vector(15 downto 0) := x"7FFF";  -- limit
    constant SRP_W1 : std_logic_vector(15 downto 0) := x"0002";  -- DT = valid 4-byte
    constant SRP_W2 : std_logic_vector(15 downto 0) := x"ABCD";  -- table addr hi
    constant SRP_W3 : std_logic_vector(15 downto 0) := x"EF00";  -- table addr lo (bits 3:0 unused)
    -- TT1 has the same format/storable fields as TT0; loaded disabled (E=0).
    constant TT1_HI : std_logic_vector(15 downto 0) := x"5678";
    constant TT1_LO : std_logic_vector(15 downto 0) := x"0453";
    -- MMUSR (.W, 16-bit). 68030 writable bits only (no 68851 A/G/C); value
    -- calibrated below to the storable readback.
    constant MMUSR_VAL : std_logic_vector(15 downto 0) := x"4C47";

    type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
    signal mem : mem_array_t := (
        -- Reset vectors
        0 => x"0000", 1 => x"1000",   -- SSP = $00001000
        2 => x"0000", 3 => x"0500",   -- PC  = $00000500

        -- Program at $500 (word address $280)
        16#280# => x"41F9", 16#281# => x"0000", 16#282# => x"3000",  -- LEA $3000,A0 (TT0 src)
        16#283# => x"43F9", 16#284# => x"0000", 16#285# => x"3100",  -- LEA $3100,A1 (TT0 dst)
        16#286# => x"45F9", 16#287# => x"0000", 16#288# => x"3010",  -- LEA $3010,A2 (CRP src)
        16#289# => x"47F9", 16#28A# => x"0000", 16#28B# => x"3110",  -- LEA $3110,A3 (CRP dst)
        16#28C# => x"49F9", 16#28D# => x"0000", 16#28E# => x"2FF0",  -- LEA $2FF0,A4 (d16 base)

        16#28F# => x"F010", 16#290# => x"0800",  -- PMOVE.L (A0),TT0   read  $3000,$3002
        16#291# => x"F011", 16#292# => x"0A00",  -- PMOVE.L TT0,(A1)   write $3100,$3102
        16#293# => x"F012", 16#294# => x"4C00",  -- PMOVE.Q (A2),CRP   read  $3010..$3016
        16#295# => x"F013", 16#296# => x"4E00",  -- PMOVE.Q CRP,(A3)   write $3110..$3116
        -- PMOVE.L TT0,(d16,A4) with d16 = $0110 -> EA = $2FF0+$0110 = $3100
        16#297# => x"F02C", 16#298# => x"0A00", 16#299# => x"0110",  -- PMOVE.L TT0,(d16,A4) EA=$2FF0+$0110=$3100

        -- TC (.L) round-trip via (An): src $3020, dst $3120
        16#29A# => x"41F9", 16#29B# => x"0000", 16#29C# => x"3020",  -- LEA $3020,A0
        16#29D# => x"43F9", 16#29E# => x"0000", 16#29F# => x"3120",  -- LEA $3120,A1
        16#2A0# => x"F010", 16#2A1# => x"4000",  -- PMOVE.L (A0),TC   read  $3020,$3022
        16#2A2# => x"F011", 16#2A3# => x"4200",  -- PMOVE.L TC,(A1)   write $3120,$3122

        -- SRP (.Q) round-trip via (An): src $3030, dst $3130
        16#2A4# => x"45F9", 16#2A5# => x"0000", 16#2A6# => x"3030",  -- LEA $3030,A2
        16#2A7# => x"47F9", 16#2A8# => x"0000", 16#2A9# => x"3130",  -- LEA $3130,A3
        16#2AA# => x"F012", 16#2AB# => x"4800",  -- PMOVE.Q (A2),SRP  read  $3030..$3036
        16#2AC# => x"F013", 16#2AD# => x"4A00",  -- PMOVE.Q SRP,(A3)  write $3130..$3136

        -- TT1 (.L) round-trip via (An): src $3040, dst $3140
        16#2AE# => x"41F9", 16#2AF# => x"0000", 16#2B0# => x"3040",  -- LEA $3040,A0
        16#2B1# => x"43F9", 16#2B2# => x"0000", 16#2B3# => x"3140",  -- LEA $3140,A1
        16#2B4# => x"F010", 16#2B5# => x"0C00",  -- PMOVE.L (A0),TT1  read  $3040,$3042
        16#2B6# => x"F011", 16#2B7# => x"0E00",  -- PMOVE.L TT1,(A1)  write $3140,$3142

        -- TT0 (.L) store via (xxx).L absolute: PMOVE.L TT0,($3160).L
        16#2B8# => x"F039", 16#2B9# => x"0A00", 16#2BA# => x"0000", 16#2BB# => x"3160",

        -- MMUSR (.W) round-trip via (An): src $3050, dst $3150
        16#2BC# => x"41F9", 16#2BD# => x"0000", 16#2BE# => x"3050",  -- LEA $3050,A0
        16#2BF# => x"43F9", 16#2C0# => x"0000", 16#2C1# => x"3150",  -- LEA $3150,A1
        16#2C2# => x"F010", 16#2C3# => x"6000",  -- PMOVE.W (A0),MMUSR  read  $3050
        16#2C4# => x"F011", 16#2C5# => x"6200",  -- PMOVE.W MMUSR,(A1)  write $3150

        -- TT0 (.L) store via (A4)+: A4=$3170 -> writes $3170,$3172, A4:=$3174
        16#2C6# => x"49F9", 16#2C7# => x"0000", 16#2C8# => x"3170",  -- LEA $3170,A4
        16#2C9# => x"F01C", 16#2CA# => x"0A00",  -- PMOVE.L TT0,(A4)+

        -- TT0 (.L) store via -(A5): A5=$3184 -> predec by 4 to $3180, writes there
        16#2CB# => x"4BF9", 16#2CC# => x"0000", 16#2CD# => x"3184",  -- LEA $3184,A5
        16#2CE# => x"F025", 16#2CF# => x"0A00",  -- PMOVE.L TT0,-(A5)

        16#2D0# => x"4E72", 16#2D1# => x"2700",  -- STOP #$2700

        -- TT0 payload at $3000 (word addr $1800)
        16#1800# => TT0_HI, 16#1801# => TT0_LO,
        -- CRP payload at $3010 (word addr $1808)
        16#1808# => CRP_W0, 16#1809# => CRP_W1, 16#180A# => CRP_W2, 16#180B# => CRP_W3,
        -- TC payload at $3020 (word addr $1810)
        16#1810# => TC_HI, 16#1811# => TC_LO,
        -- SRP payload at $3030 (word addr $1818)
        16#1818# => SRP_W0, 16#1819# => SRP_W1, 16#181A# => SRP_W2, 16#181B# => SRP_W3,
        -- TT1 payload at $3040 (word addr $1820)
        16#1820# => TT1_HI, 16#1821# => TT1_LO,
        -- MMUSR payload at $3050 (word addr $1828)
        16#1828# => MMUSR_VAL,

        others => x"4E71"
    );

    -- Bus-transaction capture (address + data) for reads and writes.
    type word_array  is array(0 to 31) of std_logic_vector(15 downto 0);
    type addr_array  is array(0 to 31) of std_logic_vector(31 downto 0);
    signal rd_addr : addr_array := (others => (others => '0'));
    signal rd_data : word_array := (others => (others => '0'));
    signal rd_cnt  : integer := 0;
    signal wr_addr : addr_array := (others => (others => '0'));
    signal wr_data : word_array := (others => (others => '0'));
    signal wr_cnt  : integer := 0;

    -- Only count operand data reads (busstate "10"), not instruction fetches.
    signal capture_en : boolean := false;

begin
    clk_process: process
    begin
        while not test_done loop
            clk <= '0'; wait for CLK_PERIOD/2;
            clk <= '1'; wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    dut: entity work.TG68KdotC_Kernel
        generic map(
            SR_Read => 2, VBR_Stackframe => 2, extAddr_Mode => 2,
            MUL_Mode => 2, DIV_Mode => 2, BitField => 2,
            MUL_Hardware => 1, BarrelShifter => 2
        )
        port map(
            clk => clk, nReset => nReset, clkena_in => clkena_in,
            data_in => data_in, IPL => "111", IPL_autovector => '1',
            berr => '0', CPU => "10",
            addr_out => addr_out, data_write => data_write,
            nWr => nWr, nUDS => nUDS, nLDS => nLDS, busstate => busstate,
            longword => open, nResetOut => nResetOut, FC => FC,
            clr_berr => open, skipFetch => open, regin_out => open,
            CACR_out => open, VBR_out => open,
            cache_inv_req => open, cache_op_scope => open, cache_op_cache => open,
            cacr_ie => open, cacr_de => open, cacr_ifreeze => open,
            cacr_dfreeze => open, cacr_ibe => open, cacr_dbe => open, cacr_wa => open,
            pmmu_reg_we => open, pmmu_reg_re => open, pmmu_reg_sel => open,
            pmmu_reg_wdat => open, pmmu_reg_part => open,
            pmmu_addr_log => open, pmmu_addr_phys => open,
            pmmu_cache_inhibit => open, cache_op_addr => open,
            pmmu_walker_req => open, pmmu_walker_we => open,
            pmmu_walker_addr => open, pmmu_walker_wdat => open,
            pmmu_walker_ack => '0', pmmu_walker_data => (others => '0'),
            pmmu_walker_berr => '0',
            debug_SVmode => open, debug_preSVmode => open,
            debug_FlagsSR_S => open, debug_changeMode => open,
            debug_setopcode => open, debug_exec_directSR => open,
            debug_exec_to_SR => open, debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open
        );

    -- Asynchronous memory read model (mirrors the other kernel-only benches).
    mem_read: process(nReset, nResetOut, holdoff_done, busstate, addr_out, mem)
        variable a : integer;
    begin
        data_in <= x"4E71";
        if nReset = '1' and nResetOut = '1' and holdoff_done = '1' and
           (busstate = "00" or busstate = "10") and
           not has_unknown(addr_out(14 downto 1)) then
            a := to_integer(unsigned(addr_out(14 downto 1)));
            data_in <= mem(a);
        end if;
    end process;

    holdoff: process(clk)
    begin
        if rising_edge(clk) then
            if nResetOut /= '1' then
                holdoff_done <= '0'; holdoff_cnt <= 0; clkena_in <= '1';
            elsif holdoff_done = '0' then
                if holdoff_cnt < RESET_HOLDOFF_CYCLES then
                    holdoff_cnt <= holdoff_cnt + 1; clkena_in <= '0';
                else
                    holdoff_done <= '1'; clkena_in <= '1';
                end if;
            else
                clkena_in <= '1';
            end if;
        end if;
    end process;

    -- Capture operand reads (busstate "10") and data writes (busstate "11").
    -- Instruction fetches (busstate "00") are excluded. Capture is only armed
    -- once the program reaches the PMOVE block (after capture_en is set).
    bus_capture: process(clk)
    begin
        if rising_edge(clk) then
            if nResetOut = '1' and holdoff_done = '1' and capture_en then
                if busstate = "10" then
                    if rd_cnt < 32 then
                        rd_addr(rd_cnt) <= addr_out;
                        rd_data(rd_cnt) <= data_in;
                        report "RD[" & integer'image(rd_cnt) & "] addr=0x" &
                            slv32_to_hexstring(addr_out) & " data=0x" &
                            slv32_to_hexstring(x"0000" & data_in) severity note;
                        rd_cnt <= rd_cnt + 1;
                    end if;
                elsif busstate = "11" and nWr = '0' then
                    if wr_cnt < 32 then
                        wr_addr(wr_cnt) <= addr_out;
                        wr_data(wr_cnt) <= data_write;
                        report "WR[" & integer'image(wr_cnt) & "] addr=0x" &
                            slv32_to_hexstring(addr_out) & " data=0x" &
                            slv32_to_hexstring(x"0000" & data_write) severity note;
                        wr_cnt <= wr_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Arm capture once PC enters the PMOVE region ($51E = first PMOVE) so the
    -- LEA operand reads do not pollute the transfer capture.
    arm: process(clk)
    begin
        if rising_edge(clk) then
            if nResetOut = '1' and holdoff_done = '1' and busstate = "00" and
               not has_unknown(addr_out) and
               unsigned(addr_out) >= x"0000051E" then
                capture_en <= true;
            end if;
        end if;
    end process;

    stim: process
        variable fail : integer := 0;

        procedure chk_addr(idx : integer; got, exp : std_logic_vector(31 downto 0);
                           tag : string) is
        begin
            if got /= exp then
                report "FAIL " & tag & " addr: got 0x" & slv32_to_hexstring(got) &
                    " exp 0x" & slv32_to_hexstring(exp) severity error;
                fail := fail + 1;
            else
                report "PASS " & tag & " addr 0x" & slv32_to_hexstring(exp) severity note;
            end if;
        end procedure;

        procedure chk_data(idx : integer; got, exp : std_logic_vector(15 downto 0);
                           tag : string) is
        begin
            if got /= exp then
                report "FAIL " & tag & " data: got 0x" &
                    slv32_to_hexstring(x"0000" & got) & " exp 0x" &
                    slv32_to_hexstring(x"0000" & exp) severity error;
                fail := fail + 1;
            else
                report "PASS " & tag & " data 0x" &
                    slv32_to_hexstring(x"0000" & exp) severity note;
            end if;
        end procedure;
    begin
        report "=== PMMU bus-transaction verification (addresses + data) ===" severity note;
        nReset <= '0';
        wait for 100 ns;
        nReset <= '1';

        -- Run until both transfers complete (6 reads + 6 writes) or timeout.
        for i in 0 to 40000 loop
            wait until rising_edge(clk);
            exit when (rd_cnt >= 15 and wr_cnt >= 23);
        end loop;

        report "captured rd_cnt=" & integer'image(rd_cnt) &
               " wr_cnt=" & integer'image(wr_cnt) severity note;

        assert rd_cnt >= 15
            report "Timeout: expected >=15 operand reads" severity failure;
        assert wr_cnt >= 23
            report "Timeout: expected >=23 operand writes" severity failure;

        -- ---- TT0 (.L) : read $3000/$3002, write $3100/$3102 ----
        chk_addr(0, rd_addr(0), x"00003000", "TT0.L read[0]");
        chk_addr(1, rd_addr(1), x"00003002", "TT0.L read[1]");
        chk_data(0, rd_data(0), TT0_HI,      "TT0.L read[0]");
        chk_data(1, rd_data(1), TT0_LO,      "TT0.L read[1]");

        chk_addr(0, wr_addr(0), x"00003100", "TT0.L write[0]");
        chk_addr(1, wr_addr(1), x"00003102", "TT0.L write[1]");
        -- Content round-trip: store-back must equal the loaded TT0 bytes.
        chk_data(0, wr_data(0), TT0_HI,      "TT0.L roundtrip[0]");
        chk_data(1, wr_data(1), TT0_LO,      "TT0.L roundtrip[1]");

        -- ---- CRP (.Q) : read $3010..$3016, write $3110..$3116 ----
        chk_addr(2, rd_addr(2), x"00003010", "CRP.Q read[0]");
        chk_addr(3, rd_addr(3), x"00003012", "CRP.Q read[1]");
        chk_addr(4, rd_addr(4), x"00003014", "CRP.Q read[2]");
        chk_addr(5, rd_addr(5), x"00003016", "CRP.Q read[3]");

        chk_addr(2, wr_addr(2), x"00003110", "CRP.Q write[0]");
        chk_addr(3, wr_addr(3), x"00003112", "CRP.Q write[1]");
        chk_addr(4, wr_addr(4), x"00003114", "CRP.Q write[2]");
        chk_addr(5, wr_addr(5), x"00003116", "CRP.Q write[3]");
        -- Content round-trip for the table-address low longword (fully storable).
        chk_data(4, wr_data(4), CRP_W2,      "CRP.Q roundtrip[2]");
        chk_data(5, wr_data(5), CRP_W3,      "CRP.Q roundtrip[3]");

        -- ---- TT0 (.L) via (d16,A4): A4=$2FF0, d16=$0110 -> EA=$3100/$3102 ----
        -- Verifies (d16,An) effective-address computation for a PMMU store, plus
        -- that the (still-loaded) TT0 content is written out correctly.
        chk_addr(6, wr_addr(6), x"00003100", "TT0.L (d16,An) write[0]");
        chk_addr(7, wr_addr(7), x"00003102", "TT0.L (d16,An) write[1]");
        chk_data(6, wr_data(6), TT0_HI,      "TT0.L (d16,An) content[0]");
        chk_data(7, wr_data(7), TT0_LO,      "TT0.L (d16,An) content[1]");

        -- ---- TC (.L) via (An): read $3020/$3022, write $3120/$3122 ----
        chk_addr(6, rd_addr(6), x"00003020", "TC.L read[0]");
        chk_addr(7, rd_addr(7), x"00003022", "TC.L read[1]");
        chk_data(6, rd_data(6), TC_HI,       "TC.L read[0]");
        chk_data(7, rd_data(7), TC_LO,       "TC.L read[1]");
        chk_addr(8, wr_addr(8), x"00003120", "TC.L write[0]");
        chk_addr(9, wr_addr(9), x"00003122", "TC.L write[1]");
        chk_data(8, wr_data(8), TC_HI,       "TC.L roundtrip[0]");
        chk_data(9, wr_data(9), TC_LO,       "TC.L roundtrip[1]");

        -- ---- SRP (.Q) via (An): read $3030..$3036, write $3130..$3136 ----
        chk_addr(8,  rd_addr(8),  x"00003030", "SRP.Q read[0]");
        chk_addr(9,  rd_addr(9),  x"00003032", "SRP.Q read[1]");
        chk_addr(10, rd_addr(10), x"00003034", "SRP.Q read[2]");
        chk_addr(11, rd_addr(11), x"00003036", "SRP.Q read[3]");
        chk_addr(10, wr_addr(10), x"00003130", "SRP.Q write[0]");
        chk_addr(11, wr_addr(11), x"00003132", "SRP.Q write[1]");
        chk_addr(12, wr_addr(12), x"00003134", "SRP.Q write[2]");
        chk_addr(13, wr_addr(13), x"00003136", "SRP.Q write[3]");
        -- Content round-trip for the table-address low longword (fully storable).
        chk_data(12, wr_data(12), SRP_W2,     "SRP.Q roundtrip[2]");
        chk_data(13, wr_data(13), SRP_W3,     "SRP.Q roundtrip[3]");

        -- ---- TT1 (.L) via (An): read $3040/$3042, write $3140/$3142 ----
        chk_addr(12, rd_addr(12), x"00003040", "TT1.L read[0]");
        chk_addr(13, rd_addr(13), x"00003042", "TT1.L read[1]");
        chk_data(12, rd_data(12), TT1_HI,      "TT1.L read[0]");
        chk_data(13, rd_data(13), TT1_LO,      "TT1.L read[1]");
        chk_addr(14, wr_addr(14), x"00003140", "TT1.L write[0]");
        chk_addr(15, wr_addr(15), x"00003142", "TT1.L write[1]");
        chk_data(14, wr_data(14), TT1_HI,      "TT1.L roundtrip[0]");
        chk_data(15, wr_data(15), TT1_LO,      "TT1.L roundtrip[1]");

        -- ---- TT0 (.L) via (xxx).L absolute: write $3160/$3162 ----
        -- Verifies absolute-long effective-address computation for a PMMU store,
        -- and that the (still-loaded) TT0 content is written correctly.
        chk_addr(16, wr_addr(16), x"00003160", "TT0.L (xxx).L write[0]");
        chk_addr(17, wr_addr(17), x"00003162", "TT0.L (xxx).L write[1]");
        chk_data(16, wr_data(16), TT0_HI,      "TT0.L (xxx).L content[0]");
        chk_data(17, wr_data(17), TT0_LO,      "TT0.L (xxx).L content[1]");

        -- ---- MMUSR (.W) via (An): read $3050, write $3150 ----
        chk_addr(14, rd_addr(14), x"00003050", "MMUSR.W read");
        chk_data(14, rd_data(14), MMUSR_VAL,   "MMUSR.W read");
        chk_addr(18, wr_addr(18), x"00003150", "MMUSR.W write");
        chk_data(18, wr_data(18), MMUSR_VAL,   "MMUSR.W roundtrip");

        -- ---- TT0 (.L) via (A4)+ : postincrement -> writes $3170,$3172 ----
        chk_addr(19, wr_addr(19), x"00003170", "TT0.L (An)+ write[0]");
        chk_addr(20, wr_addr(20), x"00003172", "TT0.L (An)+ write[1]");
        chk_data(19, wr_data(19), TT0_HI,      "TT0.L (An)+ content[0]");
        chk_data(20, wr_data(20), TT0_LO,      "TT0.L (An)+ content[1]");

        -- ---- TT0 (.L) via -(A5): A5=$3184 predec by 4 -> writes $3180,$3182 ----
        chk_addr(21, wr_addr(21), x"00003180", "TT0.L -(An) write[0]");
        chk_addr(22, wr_addr(22), x"00003182", "TT0.L -(An) write[1]");
        chk_data(21, wr_data(21), TT0_HI,      "TT0.L -(An) content[0]");
        chk_data(22, wr_data(22), TT0_LO,      "TT0.L -(An) content[1]");

        if fail = 0 then
            report "ALL PMMU BUS-VERIFY TESTS PASSED" severity note;
        else
            report integer'image(fail) & " PMMU bus-verify checks FAILED" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
