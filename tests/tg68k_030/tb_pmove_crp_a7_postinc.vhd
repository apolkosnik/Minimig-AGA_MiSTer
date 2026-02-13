-- tb_pmove_crp_a7_postinc.vhd
-- Regression test: PMOVE.Q CRP,(A7)+ must post-increment A7 by 8 bytes.
--
-- Program:
--   LEA    $2000,A7
--   PMOVE  CRP,(A7)+  ; should write at $2000/$2002/$2004/$2006 and then A7 := $2008
--   PMOVE  CRP,(A7)   ; should write at $2008/$200A/$200C/$200E
--   STOP

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pmove_crp_a7_postinc is
end entity;

architecture behavioral of tb_pmove_crp_a7_postinc is
	

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
	signal nUDS       : std_logic;
	signal nLDS       : std_logic;
	signal FC         : std_logic_vector(2 downto 0);
	signal pmmu_reg_part : std_logic;
	signal nResetOut  : std_logic;

	constant CLK_PERIOD : time := 10 ns;
	constant RESET_HOLDOFF_CYCLES : integer := 12;
	signal test_done : boolean := false;
	signal holdoff_done : std_logic := '0';
	signal holdoff_cnt : integer range 0 to RESET_HOLDOFF_CYCLES := 0;

	type mem_array_t is array(0 to 16383) of std_logic_vector(15 downto 0);
	signal mem : mem_array_t := (
		-- Reset vectors
		0 => x"0000",  -- SSP high
		1 => x"1000",  -- SSP low = $00001000
		2 => x"0000",  -- PC high
		3 => x"0500",  -- PC low = $00000500

		-- Program at $500 (word address $280)
		16#280# => x"4FF9",  -- LEA $00002000,A7
		16#281# => x"0000",
		16#282# => x"2000",

		16#283# => x"4E71",  -- NOP

		-- PMOVE CRP,(A7)+
		-- EA = (An)+ : mode=011 reg=111 => opcode word = F01F
		16#284# => x"F01F",
		16#285# => x"4E00",  -- Extension: CRP, MMU->memory

		-- PMOVE TC,(A7)  (uses A7 after CRP postinc; should start at $2008)
		16#286# => x"F017",
		16#287# => x"4200",  -- Extension: TC, MMU->memory

		-- STOP
		16#288# => x"4E72",
		16#289# => x"2700",

		others => x"4E71"
	);

	type write_addr_array is array(0 to 5) of std_logic_vector(31 downto 0);
	signal write_addrs : write_addr_array := (others => (others => '0'));
	signal write_count : integer := 0;

	-- VHDL-93 compatible hex conversion function
	function slv32_to_hexstring(slv : std_logic_vector(31 downto 0)) return string is
		variable hex : string(1 to 8);
		variable nibble : std_logic_vector(3 downto 0);
	begin
		for i in 0 to 7 loop
			nibble := slv(31 - i*4 downto 28 - i*4);
			case nibble is
				when "0000" => hex(i+1) := '0';
				when "0001" => hex(i+1) := '1';
				when "0010" => hex(i+1) := '2';
				when "0011" => hex(i+1) := '3';
				when "0100" => hex(i+1) := '4';
				when "0101" => hex(i+1) := '5';
				when "0110" => hex(i+1) := '6';
				when "0111" => hex(i+1) := '7';
				when "1000" => hex(i+1) := '8';
				when "1001" => hex(i+1) := '9';
				when "1010" => hex(i+1) := 'A';
				when "1011" => hex(i+1) := 'B';
				when "1100" => hex(i+1) := 'C';
				when "1101" => hex(i+1) := 'D';
				when "1110" => hex(i+1) := 'E';
				when "1111" => hex(i+1) := 'F';
				when others => hex(i+1) := 'X';
			end case;
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
			nUDS           => nUDS,
			nLDS           => nLDS,
			busstate       => busstate,
			longword       => open,
			nResetOut      => nResetOut,
			FC             => FC,
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
				pmmu_reg_part  => pmmu_reg_part,
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

	-- Memory read (simple asynchronous model)
	-- Guard against unknown addresses during reset/early cycles.
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

	-- Hold off clkena after reset release to avoid early X propagation.
	holdoff: process(clk)
	begin
		if rising_edge(clk) then
			if nResetOut /= '1' then
				holdoff_done <= '0';
				holdoff_cnt <= 0;
				clkena_in <= '1';
			elsif holdoff_done = '0' then
				if holdoff_cnt < RESET_HOLDOFF_CYCLES then
					holdoff_cnt <= holdoff_cnt + 1;
					clkena_in <= '0';
				else
					holdoff_done <= '1';
					clkena_in <= '1';
				end if;
			else
				clkena_in <= '1';
			end if;
		end if;
	end process;

	-- Capture writes (first 6 writes: PMOVE.Q CRP store + PMOVE.L TC store)
	write_capture: process(clk)
	begin
		if rising_edge(clk) then
			if nResetOut = '1' and holdoff_done = '1' and busstate = "11" and nWr = '0' then
					if write_count < 16 then
						report "WRITE[" & integer'image(write_count) &
							"] t=" & time'image(now) &
							"] addr=0x" & slv32_to_hexstring(addr_out) &
							" data16=0x" & slv32_to_hexstring(x"0000" & data_write) &
							" part=" & std_logic'image(pmmu_reg_part) severity note;
					end if;
				if write_count < 6 then
					write_addrs(write_count) <= addr_out;
				end if;
				write_count <= write_count + 1;
			end if;
		end if;
	end process;

	stim: process
	begin
		report "=== PMOVE.Q CRP,(A7)+ postincrement test ===" severity note;
		nReset <= '0';
		wait for 100 ns;
		nReset <= '1';

		-- Run until PMOVE.Q CRP (4 writes) + PMOVE TC (2 writes) completed (6 writes) or timeout
		for i in 0 to 20000 loop
			wait until rising_edge(clk);
			exit when write_count >= 6;
		end loop;

		assert write_count >= 6
			report "Timeout waiting for PMOVE.Q CRP + PMOVE TC writes" severity failure;

		assert write_addrs(0) = x"00002000"
			report "PMOVE CRP,(A7)+ write[0] addr mismatch" severity failure;
		assert write_addrs(1) = x"00002002"
			report "PMOVE CRP,(A7)+ write[1] addr mismatch" severity failure;
		assert write_addrs(2) = x"00002004"
			report "PMOVE CRP,(A7)+ write[2] addr mismatch" severity failure;
		assert write_addrs(3) = x"00002006"
			report "PMOVE CRP,(A7)+ write[3] addr mismatch" severity failure;

		assert write_addrs(4) = x"00002008"
			report "PMOVE TC,(A7) write[0] addr mismatch (A7 postinc should be +8)" severity failure;
		assert write_addrs(5) = x"0000200A"
			report "PMOVE TC,(A7) write[1] addr mismatch (A7 postinc should be +8)" severity failure;

		report "PASS: PMOVE.Q CRP,(A7)+ increments A7 by 8 bytes" severity note;
		test_done <= true;
		wait;
	end process;

end architecture;
