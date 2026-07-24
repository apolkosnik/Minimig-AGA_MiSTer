`timescale 1ns/1ps

// Minimal dual-port RAM model used by cpu_cache_new.
module dpram #(parameter AW = 8, parameter DW = 16)
(
	input                 clock,
	input      [AW-1:0]   address_a,
	input                 wren_a,
	input      [DW-1:0]   data_a,
	output     [DW-1:0]   q_a,
	input      [AW-1:0]   address_b,
	input                 wren_b,
	input      [DW-1:0]   data_b,
	output     [DW-1:0]   q_b
);
	reg [DW-1:0] mem [0:(1<<AW)-1];
	integer i;

	initial begin
		for (i = 0; i < (1<<AW); i = i + 1)
			mem[i] = {DW{1'b0}};
	end

	assign q_a = mem[address_a];
	assign q_b = mem[address_b];

	always @(posedge clock) begin
		if (wren_a)
			mem[address_a] <= data_a;
		if (wren_b)
			mem[address_b] <= data_b;
	end
endmodule

module tb_mmu_pte_coherency;
	// Physical $4FFF6074 through the live 256 MB Z3_1 RAM-address encoder.
	localparam [28:1] PTE_HIGH_ADDR = 28'hFFFB03A;
	localparam [28:1] PTE_LOW_ADDR  = PTE_HIGH_ADDR + 28'd1;
	localparam [31:0] PTE_VALUE     = 32'h4FAA8005;
	localparam [28:0] PTE_AVALON_ADDR = {3'b001, PTE_HIGH_ADDR[28:3]};

	reg         clk = 1'b0;
	reg         cpu_clk = 1'b0;
	reg         reset_n = 1'b0;
	reg         cache_rst = 1'b1;
	reg         cache_inhibit = 1'b1;
	reg  [3:0]  cpu_cache_ctrl = 4'b0000;
	wire        DDRAM_CLK;
	reg         DDRAM_BUSY = 1'b0;
	wire [7:0]  DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT = 64'h0;
	reg         DDRAM_DOUT_READY = 1'b0;
	wire        DDRAM_RD;
	wire [63:0] DDRAM_DIN;
	wire [7:0]  DDRAM_BE;
	wire        DDRAM_WE;
	reg  [28:1] cpuAddr = 28'h0;
	reg         cpuCS = 1'b0;
	reg  [1:0]  cpustate = 2'b00;
	reg         cpuL = 1'b1;
	reg         cpuU = 1'b1;
	reg  [15:0] cpuWR = 16'h0000;
	wire [15:0] cpuRD;
	wire        ramready;

	reg [63:0] avalon_mem [0:4095];
	reg        read_pending = 1'b0;
	reg [11:0] read_index = 12'd0;
	reg  [2:0] read_delay = 3'd0;
	reg  [2:0] wait_phase = 3'd0;
	reg  [2:0] wait_seed = 3'd0;
	integer    accepted_reads = 0;
	integer    accepted_writes = 0;
	reg [28:0] last_write_addr = 29'd0;
	reg [63:0] last_write_data = 64'd0;
	reg  [7:0] last_write_be = 8'd0;
	integer    failures = 0;
	integer    mem_index;
	integer    byte_lane;
	integer    case_seed;

	always #4.4 clk = ~clk;
	// Match the board clock ratio: ddram_ctrl runs at 113.5 MHz while TG68
	// consumes ramready at 28.6875 MHz. This catches sub-CPU-cycle ack pulses.
	always #17.43 cpu_clk = ~cpu_clk;

	ddram_ctrl dut (
		.sysclk(clk),
		.reset_n(reset_n),
		.cache_rst(cache_rst),
		.cache_inhibit(cache_inhibit),
		.cpu_cache_ctrl(cpu_cache_ctrl),
		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.cpuAddr(cpuAddr),
		.cpuCS(cpuCS),
		.cpustate(cpustate),
		.cpuL(cpuL),
		.cpuU(cpuU),
		.cpuWR(cpuWR),
		.cpuRD(cpuRD),
		.ramshared(1'b0),
		.ramready(ramready)
	);

	// Avalon-MM slave model. A write changes memory only on an accepted
	// DDRAM_WE && !DDRAM_BUSY transfer. Reads return that persistent storage,
	// so a controller-side acknowledgement without a physical command is caught.
	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 1'b0;
		if (!reset_n) begin
			DDRAM_BUSY <= 1'b0;
			DDRAM_DOUT <= 64'd0;
			read_pending <= 1'b0;
			read_index <= 12'd0;
			read_delay <= 3'd0;
			wait_phase <= wait_seed;
			accepted_reads <= 0;
			accepted_writes <= 0;
			last_write_addr <= 29'd0;
			last_write_data <= 64'd0;
			last_write_be <= 8'd0;
			for (mem_index = 0; mem_index < 4096; mem_index = mem_index + 1)
				avalon_mem[mem_index] <= 64'd0;
		end else begin
			wait_phase <= wait_phase + 3'd1;
			// Exercise held requests and read-data-valid coincident with waitrequest.
			DDRAM_BUSY <= (wait_phase == 3'd1) || (wait_phase == 3'd2) ||
			                (wait_phase == 3'd6);

			if (DDRAM_WE && !DDRAM_BUSY) begin
				accepted_writes <= accepted_writes + 1;
				last_write_addr <= DDRAM_ADDR;
				last_write_data <= DDRAM_DIN;
				last_write_be <= DDRAM_BE;
				for (byte_lane = 0; byte_lane < 8; byte_lane = byte_lane + 1)
					if (DDRAM_BE[byte_lane])
						avalon_mem[DDRAM_ADDR[11:0]][byte_lane*8 +: 8] <= DDRAM_DIN[byte_lane*8 +: 8];
			end

			if (DDRAM_RD && !DDRAM_BUSY && !read_pending) begin
				accepted_reads <= accepted_reads + 1;
				read_pending <= 1'b1;
				read_index <= DDRAM_ADDR[11:0];
				read_delay <= 3'd2 + wait_seed[0];
			end else if (read_pending) begin
				if (read_delay != 0) begin
					read_delay <= read_delay - 3'd1;
				end else begin
					DDRAM_DOUT <= avalon_mem[read_index];
					DDRAM_DOUT_READY <= 1'b1;
					read_pending <= 1'b0;
				end
			end
		end
	end

	task fail;
		input [511:0] msg;
		begin
			failures = failures + 1;
			$display("FAIL: %0s", msg);
		end
	endtask

	task wait_idle;
		integer timeout;
		begin
			timeout = 0;
			while ((dut.cacheReqActive || dut.write_req || dut.write_ack ||
			        dut.write_state != 0 || dut.state != 0 || read_pending || ramready) &&
			       timeout < 100) begin
				timeout = timeout + 1;
				@(posedge clk);
				#1;
			end
			if (timeout == 100)
				fail("controller did not return idle");
		end
	endtask

	task end_bus_cycle;
		begin
			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;
			@(posedge cpu_clk);
			#1;
			wait_idle;
		end
	endtask

	task read_word;
		input [28:1] addr;
		input [15:0] expected;
		input [511:0] label;
		integer timeout;
		begin
			cpuAddr = addr;
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = 2'b10;
			cpuCS = 1'b1;
			timeout = 0;
			while (ramready !== 1'b1 && timeout < 100) begin
				timeout = timeout + 1;
				@(posedge cpu_clk);
				#1;
			end
			if (timeout == 100)
				fail({label, ": read did not acknowledge"});
			else if (cpuRD !== expected) begin
				$display("FAIL: %0s expected=%04x got=%04x", label, expected, cpuRD);
				failures = failures + 1;
			end
			end_bus_cycle;
		end
	endtask

	task write_word;
		input [28:1] addr;
		input [15:0] data;
		input [511:0] label;
		integer timeout;
		integer writes_before;
		begin
			writes_before = accepted_writes;
			cpuAddr = addr;
			cpuWR = data;
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = 2'b11;
			cpuCS = 1'b1;
			timeout = 0;
			while (ramready !== 1'b1 && timeout < 100) begin
				timeout = timeout + 1;
				@(posedge cpu_clk);
				#1;
			end
			if (timeout == 100)
				fail({label, ": write did not acknowledge"});
			else if (accepted_writes <= writes_before)
				fail({label, ": acknowledged before Avalon accepted the write"});

			// The controller and CPU use 114 MHz and 28 MHz clocks respectively.
			// Completion is a four-phase level handshake: while the CPU keeps this
			// bus cycle unchanged, ready must remain high for every possible CPU
			// sampling phase instead of being a one-controller-cycle pulse.
			repeat (5) begin
				@(posedge clk);
				#1;
				if (ramready !== 1'b1)
					fail({label, ": write acknowledgement was not held"});
			end
			end_bus_cycle;
		end
	endtask

	task write_long_no_gap;
		integer timeout;
		integer writes_before;
		integer writes_after_high;
		begin
			writes_before = accepted_writes;
			cpuAddr = PTE_HIGH_ADDR;
			cpuWR = PTE_VALUE[31:16];
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = 2'b11;
			cpuCS = 1'b1;
			timeout = 0;
			while (ramready !== 1'b1 && timeout < 100) begin
				timeout = timeout + 1;
				@(posedge cpu_clk);
				#1;
			end
			if (timeout == 100) begin
				fail("PTE high word did not acknowledge");
				end_bus_cycle;
			end else begin
				writes_after_high = accepted_writes;
				if (writes_after_high <= writes_before)
					fail("PTE high word ack preceded its Avalon write");

				// Match TG68 longword stores: change directly to the low word while
				// the outer RAM select remains asserted.
				cpuAddr = PTE_LOW_ADDR;
				cpuWR = PTE_VALUE[15:0];
				timeout = 0;
				@(posedge clk);
				#1;
				while (ramready !== 1'b1 && timeout < 100) begin
					timeout = timeout + 1;
					@(posedge cpu_clk);
					#1;
				end
				if (timeout == 100)
					fail("PTE low word did not acknowledge");
				else if (accepted_writes <= writes_after_high)
					fail("PTE low word ack reused the high-word completion");
				end_bus_cycle;
			end
		end
	endtask

	task run_case;
		input integer seed;
		input integer no_gap;
		integer reads_before_walk;
		begin
			$display("CASE seed=%0d no_gap=%0d", seed, no_gap);
			wait_seed = seed[2:0];
			reset_n = 1'b0;
			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;
			cache_inhibit = 1'b1;
			cpu_cache_ctrl = 4'b0000;
			repeat (4) @(posedge clk);
			reset_n = 1'b1;
			repeat (320 + seed) @(posedge clk);

			// Seed a cached zero exactly as a failed descriptor read would.
			cache_inhibit = 1'b0;
			cpu_cache_ctrl = 4'b0010;
			repeat (2) @(posedge clk);
			read_word(PTE_HIGH_ADDR, 16'h0000, "initial cached PTE high");
			read_word(PTE_LOW_ADDR, 16'h0000, "initial cached PTE low");

			if (no_gap != 0) begin
				write_long_no_gap;
			end else begin
				write_word(PTE_HIGH_ADDR, PTE_VALUE[31:16], "PTE high");
				write_word(PTE_LOW_ADDR, PTE_VALUE[15:0], "PTE low");
			end

			// A normal read must observe the write-through cache update.
			read_word(PTE_HIGH_ADDR, PTE_VALUE[31:16], "cached PTE high after write");
			read_word(PTE_LOW_ADDR, PTE_VALUE[15:0], "cached PTE low after write");

			// PFLUSH only invalidates the PMMU ATC. The subsequent walker cycle
			// inhibits this external cache and must observe physical DDR storage.
			cache_inhibit = 1'b1;
			reads_before_walk = accepted_reads;
			read_word(PTE_HIGH_ADDR, PTE_VALUE[31:16], "walker PTE high");
			read_word(PTE_LOW_ADDR, PTE_VALUE[15:0], "walker PTE low");
			if (accepted_reads < reads_before_walk + 2)
				fail("walker PTE read was served without two physical Avalon reads");

			if (avalon_mem[PTE_AVALON_ADDR[11:0]] === 64'd0)
				fail("physical PTE line remained zero after acknowledged writes");
		end
	endtask

	// BUG #462 regression: an INHIBITED write (the walker's U/M descriptor
	// write-back runs with cache_inhibit set via walker_active) must not
	// leave a stale copy of the descriptor in the L2. Pre-fix, the write-hit
	// update was gated by !cache_inhibit and the line stayed valid with the
	// PRE-UPDATE value: the OS re-read the stale descriptor from L2 and could
	// write back U/M=0 (lost update). Post-fix the matching line is
	// invalidated, so the cacheable re-read fetches the fresh value.
	task run_um_snoop_case;
		begin
			$display("CASE walker U/M inhibited-write snoop (BUG #462)");
			wait_seed = 3'd0;
			reset_n = 1'b0;
			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;
			cache_inhibit = 1'b1;
			cpu_cache_ctrl = 4'b0000;
			repeat (4) @(posedge clk);
			reset_n = 1'b1;
			repeat (320) @(posedge clk);

			// OS reads the (zero) descriptor cacheably - allocates the L2 line.
			cache_inhibit = 1'b0;
			cpu_cache_ctrl = 4'b0010;
			repeat (2) @(posedge clk);
			read_word(PTE_HIGH_ADDR, 16'h0000, "UM: initial cached high");
			read_word(PTE_LOW_ADDR, 16'h0000, "UM: initial cached low");

			// Walker sets U in the descriptor: inhibited write-through.
			cache_inhibit = 1'b1;
			write_word(PTE_HIGH_ADDR, PTE_VALUE[31:16], "UM: walker high write");
			write_word(PTE_LOW_ADDR, PTE_VALUE[15:0] | 16'h0008, "UM: walker low write");

			// OS re-reads CACHEABLY and must observe the walker's update.
			cache_inhibit = 1'b0;
			read_word(PTE_HIGH_ADDR, PTE_VALUE[31:16],
			          "UM: cached re-read high sees walker update");
			read_word(PTE_LOW_ADDR, PTE_VALUE[15:0] | 16'h0008,
			          "UM: cached re-read low sees walker update");
		end
	endtask

	initial begin
		$display("==== NetBSD PTE write/PFLUSH/walk coherency ====");
		for (case_seed = 0; case_seed < 4; case_seed = case_seed + 1) begin
			run_case(case_seed, 0);
			run_case(case_seed, 1);
		end
		run_um_snoop_case;

		if (failures == 0)
			$display("PASS: all PTE coherency cases passed");
		else
			$display("FAIL: %0d PTE coherency failure(s)", failures);
		// Return control to the Make target, which examines failures and exits
		// nonzero. $finish would terminate ModelSim before that Tcl check runs.
		$stop;
	end
endmodule
