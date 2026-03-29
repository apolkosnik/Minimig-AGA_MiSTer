-- tb_pmove_crp_mem_to_mmu_postinc.vhd
-- Test: PMOVE (A7)+,CRP must post-increment A7 by 8 bytes.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_crp_mem_to_mmu_postinc is
end entity;

architecture behavioral of tb_pmove_crp_mem_to_mmu_postinc is
	

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

signal clk       : std_logic := '0';
	signal nReset    : std_logic := '0';
	signal clkena_in : std_logic := '1';

	signal data_in    : std_logic_vector(15 downto 0) := x"4E71";
	signal data_write : std_logic_vector(15 downto 0);
	signal addr_out   : std_logic_vector(31 downto 0);
	signal busstate   : std_logic_vector(1 downto 0);
	signal nWr        : std_logic;

	constant CLK_PERIOD : time := 10 ns;
	signal test_done : boolean := false;

	type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
	signal mem : mem_array_t := (
		-- Reset vectors
		0 => x"0000",  1 => x"1000",  -- SSP = $00001000
		2 => x"0000",  3 => x"0500",  -- PC = $00000500

		-- Program at $500 (word address $280)
		16#280# => x"4FF9",  -- LEA $00002000,A7
		16#281# => x"0000",
		16#282# => x"2000",

		-- PMOVE (A7)+,CRP  (mem->MMU, should read from $2000-$2007, then A7:=$2008)
		16#283# => x"F01F",
		16#284# => x"4C00",  -- Extension: CRP, memory->MMU

		-- PMOVE (A7)+,TC  (should read from $2008-$200B, A7:=$200C)
		16#285# => x"F01F",
		16#286# => x"4800",  -- Extension: TC, memory->MMU

		-- STOP
		16#287# => x"4E72",
		16#288# => x"2700",

		-- Data at $2000 for CRP (64-bit)
		16#1000# => x"1234",
		16#1001# => x"5678",
		16#1002# => x"9ABC",
		16#1003# => x"DEF0",

		-- Data at $2008 for TC (32-bit)
		16#1004# => x"CAFE",
		16#1005# => x"BABE",

		others => x"4E71"
	);

	signal read_count : integer := 0;
	type read_addr_array is array(0 to 5) of std_logic_vector(31 downto 0);
	signal read_addrs : read_addr_array := (others => (others => '0'));

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
			CPU            => "10",  -- 68030
			addr_out       => addr_out,
			data_write     => data_write,
			nWr            => nWr,
			nUDS           => open,
			nLDS           => open,
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
			cache_op_addr  => open,
			pmmu_walker_req  => open,
			pmmu_walker_we   => open,
			pmmu_walker_addr => open,
			pmmu_walker_wdat => open,
			pmmu_walker_ack  => '0',
			pmmu_walker_data => (others => '0'),
			pmmu_walker_berr => '0',
			debug_SVmode     => open,
			debug_preSVmode  => open,
			debug_FlagsSR_S  => open,
			debug_changeMode => open,
			debug_setopcode  => open,
			debug_exec_directSR => open,
			debug_exec_to_SR    => open,
			debug_pmove_dn_mode => open,
			debug_pmove_dn_regnum => open
		);

	data_in <= mem(to_integer(unsigned(addr_out(14 downto 1))));

	-- Capture reads
	read_capture: process(clk)
		variable addr_str : string(1 to 8);
		variable nybble : integer;
	begin
		if rising_edge(clk) then
			if busstate = "10" and nWr = '1' and read_count < 6 and unsigned(addr_out) >= X"00001000" then
				read_addrs(read_count) <= addr_out;
				-- Convert to hex string manually for VHDL-93
				for i in 0 to 7 loop
					nybble := to_integer(unsigned(addr_out(31 - i*4 downto 31 - i*4 - 3)));
					if nybble < 10 then
						addr_str(i+1) := character'val(character'pos('0') + nybble);
					else
						addr_str(i+1) := character'val(character'pos('A') + nybble - 10);
					end if;
				end loop;
				report "Read[" & integer'image(read_count) & "] addr=0x" & addr_str severity note;
				read_count <= read_count + 1;
			end if;
		end if;
	end process;

	stim: process
	begin
		nReset <= '0';
		wait for 100 ns;
		nReset <= '1';

		for i in 0 to 20000 loop
			wait until rising_edge(clk);
			exit when read_count >= 6;
		end loop;

		assert read_count >= 6
			report "Timeout waiting for PMOVE reads" severity failure;

		-- Check CRP reads
		assert read_addrs(0) = x"00002000"
			report "PMOVE (A7)+,CRP read[0] addr mismatch" severity failure;
		assert read_addrs(1) = x"00002002"
			report "PMOVE (A7)+,CRP read[1] addr mismatch" severity failure;
		assert read_addrs(2) = x"00002004"
			report "PMOVE (A7)+,CRP read[2] addr mismatch" severity failure;
		assert read_addrs(3) = x"00002006"
			report "PMOVE (A7)+,CRP read[3] addr mismatch" severity failure;

		-- Check TC reads (should be at $2008 if CRP postinc worked)
		assert read_addrs(4) = x"00002008"
			report "PMOVE (A7)+,TC read[0] addr mismatch (A7 postinc should be +8)" severity failure;
		assert read_addrs(5) = x"0000200A"
			report "PMOVE (A7)+,TC read[1] addr mismatch (A7 postinc should be +8)" severity failure;

		report "PASS: PMOVE (A7)+,CRP increments A7 by 8 bytes" severity note;
		test_done <= true;
		wait;
	end process;

end architecture;
