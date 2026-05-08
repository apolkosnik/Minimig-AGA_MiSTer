-- tb_pflush_illegal_pc_relative.vhd
-- Verify that MC68030-illegal PC-relative PFLUSH EA modes trap as F-line.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.TG68K_Pack.all;

entity tb_pflush_illegal_pc_relative is
end entity;

architecture behavioral of tb_pflush_illegal_pc_relative is

    function slv_to_hex(value : std_logic_vector) return string is
        constant hex_chars : string := "0123456789ABCDEF";
        variable result : string(1 to value'length / 4);
        variable nibble : std_logic_vector(3 downto 0);
    begin
        for i in 0 to (value'length / 4 - 1) loop
            nibble := value(value'length - 1 - i * 4 downto value'length - 4 - i * 4);
            result(i + 1) := hex_chars(to_integer(unsigned(nibble)) + 1);
        end loop;
        return result;
    end function;

    constant CLK_PERIOD : time := 10 ns;

    signal clk       : std_logic := '0';
    signal nReset    : std_logic := '0';
    signal clkena_in : std_logic := '1';
    signal test_done : boolean := false;

    signal data_in    : std_logic_vector(15 downto 0) := x"4E71";
    signal data_write : std_logic_vector(15 downto 0);
    signal addr_out   : std_logic_vector(31 downto 0);
    signal busstate   : std_logic_vector(1 downto 0);
    signal nWr        : std_logic;
    signal nUDS       : std_logic;
    signal nLDS       : std_logic;

    signal pmmu_walker_req  : std_logic;
    signal pmmu_walker_we   : std_logic;
    signal pmmu_walker_addr : std_logic_vector(31 downto 0);
    signal pmmu_walker_wdat : std_logic_vector(31 downto 0);
    signal pmmu_walker_ack  : std_logic := '0';
    signal pmmu_walker_data : std_logic_vector(31 downto 0) := (others => '0');
    signal pmmu_walker_berr : std_logic := '0';

    signal debug_TG68_PC     : std_logic_vector(31 downto 0);
    signal debug_trap_1111    : std_logic;
    signal debug_trap_vector : std_logic_vector(31 downto 0);
    signal debug_regfile_d0  : std_logic_vector(31 downto 0);
    signal debug_cpu_halted  : std_logic;
    signal debug_stop        : std_logic;

    type rom_type is array (0 to 255) of std_logic_vector(15 downto 0);
    constant rom : rom_type := (
        0 => x"0000", 1 => x"2000",  -- SSP = $00002000
        2 => x"0000", 3 => x"0040",  -- PC  = $00000040

        22 => x"0000", 23 => x"0080",  -- F-line vector -> $80

        -- Program at $40:
        --   PFLUSH <fc>,#mask,(d16,PC) ; invalid F-line form on MC68030
        --   MOVEQ #1,D0                ; fail marker if execution falls through
        --   STOP   #$2700
        32 => x"F07A",
        33 => x"38F5",
        34 => x"0000",
        35 => x"7001",
        36 => x"4E72",
        37 => x"2700",

        -- F-line handler at $80:
        --   MOVEQ #2,D0
        --   STOP   #$2702
        64 => x"7002",
        65 => x"4E72",
        66 => x"2702",

        others => x"4E71"
    );

    type ram_type is array (0 to 255) of std_logic_vector(15 downto 0);
    signal ram : ram_type := (others => x"0000");

    signal saw_handler_fetch : boolean := false;
    signal saw_fail_path     : boolean := false;
    signal saw_stop          : boolean := false;
    signal saw_fline_trap    : boolean := false;

begin

    clk_gen : process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    dut : entity work.TG68KdotC_Kernel
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
            berr           => '0',
            CPU            => "10",
            addr_out       => addr_out,
            data_write     => data_write,
            nWr            => nWr,
            nUDS           => nUDS,
            nLDS           => nLDS,
            busstate       => busstate,
            longword       => open,
            nResetOut      => open,
            FC             => open,
            clr_berr       => open,
            skipFetch      => open,
            regin_out      => open,
            CACR_out       => open,
            VBR_out        => open,
            cache_inv_req  => open,
            cache_op_scope => open,
            cache_op_cache => open,
            cache_op_addr  => open,
            cacr_ie        => open,
            cacr_de        => open,
            cacr_ifreeze   => open,
            cacr_dfreeze   => open,
            cacr_ibe       => open,
            cacr_dbe       => open,
            cacr_wa        => open,
            pmmu_reg_we    => open,
            pmmu_reg_re    => open,
            pmmu_reg_sel   => open,
            pmmu_reg_wdat  => open,
            pmmu_reg_part  => open,
            pmmu_addr_log  => open,
            pmmu_addr_phys => open,
            pmmu_cache_inhibit => open,
            pmmu_walker_req  => pmmu_walker_req,
            pmmu_walker_we   => pmmu_walker_we,
            pmmu_walker_addr => pmmu_walker_addr,
            pmmu_walker_wdat => pmmu_walker_wdat,
            pmmu_walker_ack  => pmmu_walker_ack,
            pmmu_walker_data => pmmu_walker_data,
            pmmu_walker_berr => pmmu_walker_berr,
            debug_SVmode => open,
            debug_preSVmode => open,
            debug_FlagsSR_S => open,
            debug_changeMode => open,
            debug_setopcode => open,
            debug_exec_directSR => open,
            debug_exec_to_SR => open,
            debug_pmove_dn_mode => open,
            debug_pmove_dn_regnum => open,
            debug_opcode => open,
            debug_state => open,
            debug_setstate => open,
            debug_last_opc_read => open,
            debug_data_read => open,
            debug_direct_data => open,
            debug_setnextpass => open,
            debug_TG68_PC => debug_TG68_PC,
            debug_memaddr_reg => open,
            debug_memaddr_delta => open,
            debug_oddout => open,
            debug_decodeOPC => open,
            debug_brief => open,
            debug_moves_bus_pending => open,
            debug_moves_writeback_pending => open,
            debug_clkena_lw => open,
            debug_regfile_d0 => debug_regfile_d0,
            debug_regfile_a0 => open,
            debug_fline_context_valid => open,
            debug_trap_1111 => debug_trap_1111,
            debug_trapmake => open,
            debug_pmmu_brief => open,
            debug_use_base => open,
            debug_rf_source_addr => open,
            debug_pmove_ea_latched => open,
            debug_reg_QA => open,
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
            debug_trap_addr_error => open,
            debug_trap_berr => open,
            debug_trap_mmu_berr => open,
            debug_trap_vector => debug_trap_vector,
            debug_pc_add => open,
            debug_pc_dataa => open,
            debug_pc_datab => open,
            debug_pmmu_busy => open,
            debug_cpu_halted => debug_cpu_halted,
            debug_stop => debug_stop,
            debug_interrupt => open,
            debug_setendOPC => open,
            debug_IPL_nr => open,
            debug_micro_state => open,
            debug_next_micro_state => open,
            debug_memmask => open,
            debug_sndOPC => open,
            debug_pmmu_reg_we => open,
            debug_pmmu_reg_re => open,
            debug_pmmu_reg_sel => open,
            debug_pmmu_reg_wdat => open,
            debug_pmmu_reg_part => open,
            debug_pmmu_reg_rdat => open,
            debug_make_berr => open,
            debug_pmmu_fault => open,
            debug_trap_format_error => open,
            debug_format_error_rte_word => open,
            debug_format_error_pc => open,
            debug_format_error_addr => open,
            debug_format_error_sr => open,
            debug_pmmu_tc => open,
            debug_pmmu_tt0 => open,
            debug_pmmu_tt1 => open,
            debug_pmmu_crp_hi => open,
            debug_pmmu_crp_lo => open,
            debug_pmmu_srp_hi => open,
            debug_pmmu_srp_lo => open,
            debug_pmmu_wstate => open,
            debug_pmmu_atc_buserr => open,
            debug_pmmu_atc_valid => open,
            debug_pmmu_fault_status => open,
            debug_pmmu_saved_addr => open,
            debug_pmmu_walk_desc_addr => open,
            debug_pmmu_walk_desc_data => open,
            debug_pmmu_ptr1_desc_addr => open,
            debug_pmmu_ptr1_desc_data => open,
            debug_pmmu_ptr2_desc_addr => open,
            debug_pmmu_ptr2_desc_data => open,
            debug_pmmu_ptr3_desc_addr => open,
            debug_pmmu_ptr3_desc_data => open,
            debug_pmmu_saved_fc => open
        );

    mem_read : process(addr_out, ram)
        variable word_addr : integer;
        variable ram_addr  : integer;
        variable addr_int  : integer;
    begin
        data_in <= x"4E71";
        addr_int := to_integer(unsigned(addr_out));

        if addr_int < 16#200# then
            word_addr := to_integer(unsigned(addr_out(8 downto 1)));
            if word_addr <= 255 then
                data_in <= rom(word_addr);
            end if;
        elsif addr_int >= 16#1F00# and addr_int < 16#2100# then
            ram_addr := to_integer(unsigned(addr_out(8 downto 1)));
            data_in <= ram(ram_addr);
        end if;
    end process;

    mem_write : process(clk)
        variable addr_int : integer;
        variable ram_addr : integer;
    begin
        if rising_edge(clk) then
            if busstate = "11" and nWr = '0' then
                addr_int := to_integer(unsigned(addr_out));
                if addr_int >= 16#1F00# and addr_int < 16#2100# then
                    ram_addr := to_integer(unsigned(addr_out(8 downto 1)));
                    if nUDS = '0' then
                        ram(ram_addr)(15 downto 8) <= data_write(15 downto 8);
                    end if;
                    if nLDS = '0' then
                        ram(ram_addr)(7 downto 0) <= data_write(7 downto 0);
                    end if;
                end if;
            end if;
        end if;
    end process;

    monitor : process(clk)
    begin
        if rising_edge(clk) then
            if nReset = '1' then
                if debug_trap_1111 = '1' then
                    saw_fline_trap <= true;
                end if;

                if debug_regfile_d0 = x"00000001" then
                    saw_fail_path <= true;
                end if;

                if debug_stop = '1' then
                    saw_stop <= true;
                end if;

                if busstate = "00" then
                    if addr_out = x"00000080" then
                        saw_handler_fetch <= true;
                        report "Reached F-line handler at $80";
                    elsif addr_out = x"00000046" then
                        report "Observed fall-through fetch at $46";
                    end if;
                end if;
            end if;
        end if;
    end process;

    test_control : process
    begin
        report "=== PFLUSH ILLEGAL PC-RELATIVE TEST ===";
        report "Testing: PFLUSH <fc>,#mask,(d16,PC)";
        report "Expected: F-line trap -> handler at $80 -> D0=$00000002";

        wait for 100 ns;
        nReset <= '1';

        for i in 0 to 1000 loop
            wait until rising_edge(clk);
            if saw_stop or debug_cpu_halted = '1' then
                exit;
            end if;
        end loop;

        report "=======================================";
        report "Handler fetched:  " & boolean'image(saw_handler_fetch);
        report "F-line trap seen:  " & boolean'image(saw_fline_trap);
        report "Fail path seen:    " & boolean'image(saw_fail_path);
        report "STOP seen:         " & boolean'image(saw_stop);
        report "Final PC:          $" & slv_to_hex(debug_TG68_PC);
        report "Final D0:          $" & slv_to_hex(debug_regfile_d0);
        report "Trap vector:       $" & slv_to_hex(debug_trap_vector);
        report "=======================================";

        if debug_cpu_halted = '1' then
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST FAILED ***" severity error;
            report "CPU halted unexpectedly at PC=$" & slv_to_hex(debug_TG68_PC) severity error;
        elsif debug_regfile_d0 /= x"00000002" then
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST FAILED ***" severity error;
            report "Expected handler to set D0=$00000002, got D0=$" & slv_to_hex(debug_regfile_d0) severity error;
        elsif not saw_handler_fetch then
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST FAILED ***" severity error;
            report "F-line handler was never fetched" severity error;
        elsif saw_fail_path then
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST FAILED ***" severity error;
            report "Execution fell through to the post-PFLUSH failure marker" severity error;
        elsif not saw_stop then
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST FAILED ***" severity error;
            report "STOP was not observed after trap handling" severity error;
        else
            report "*** PFLUSH ILLEGAL PC-RELATIVE TEST PASSED ***";
        end if;

        test_done <= true;
        wait;
    end process;

end architecture;
