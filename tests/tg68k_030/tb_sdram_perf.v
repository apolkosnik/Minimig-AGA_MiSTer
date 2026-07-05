`timescale 1ns/1ps

// Standalone performance microbench for sdram_ctrl + cpu_cache_new.
// Output lines are machine-readable:
//   PERF <metric> <cycles>
//
// The bench intentionally instantiates sdram_ctrl with the optional writebusy
// port behind a define, so the same source can run against older git revisions.
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

module tb_sdram_perf;
	localparam integer MAX_WAIT = 4000;

	reg         clk = 1'b0;
	reg         c_7m = 1'b0;
	reg         reset_n = 1'b0;
	reg         cache_rst = 1'b1;
	reg         cache_inhibit = 1'b1;
	reg  [3:0]  cpu_cache_ctrl = 4'b0000;
	wire [12:0] sd_addr;
	wire [1:0]  sd_ba;
	wire        sd_cs;
	wire        sd_we;
	wire        sd_ras;
	wire        sd_cas;
	wire [1:0]  sd_dqm;
	wire [15:0] sd_data;
	wire        sd_clk;
	wire        sd_cke;
	reg  [24:1] chipAddr = 24'h0;
	reg         chipL = 1'b1;
	reg         chipU = 1'b1;
	reg         chipRW = 1'b1;
	reg         chipDMA = 1'b1;
	reg  [15:0] chipWR = 16'h0000;
	wire [15:0] chipRD;
	wire [47:0] chip48;
	wire        chip_snoop_we;
	wire [24:1] chip_snoop_addr;
	reg  [24:1] cpuAddr = 24'h0;
	reg         cpuCS = 1'b0;
	reg  [1:0]  cpustate = 2'b00;
	reg         cpuL = 1'b1;
	reg         cpuU = 1'b1;
	reg  [15:0] cpuWR = 16'h0000;
	wire [15:0] cpuRD;
	wire        ramready;
	wire        writebusy_unused;

	integer     failures = 0;
	integer     total;
	integer     one;
	reg  [15:0] dummy;

	always #5 clk = ~clk;

	// Keep the fixed SDRAM slot sequencer free-running in this bench. Real
	// hardware resynchronizes this from c_7m; a constant value lets the 4-bit
	// state counter wrap naturally every 16 sysclk cycles.
	initial c_7m = 1'b0;

	// Provide deterministic read data while the controller is not driving a
	// write. The performance bench checks acknowledgements and cycle counts;
	// data content only needs to be non-X for cache fills.
	assign sd_data = (sd_we && sd_cke) ? (16'h5000 ^ {sd_ba, sd_addr[12:0], 1'b0}) : 16'hZZZZ;

	sdram_ctrl dut (
		.sysclk(clk),
		.c_7m(c_7m),
		.reset_n(reset_n),
		.cache_rst(cache_rst),
		.cache_inhibit(cache_inhibit),
		.cpu_cache_ctrl(cpu_cache_ctrl),
		.sd_addr(sd_addr),
		.sd_ba(sd_ba),
		.sd_cs(sd_cs),
		.sd_we(sd_we),
		.sd_ras(sd_ras),
		.sd_cas(sd_cas),
		.sd_dqm(sd_dqm),
		.sd_data(sd_data),
		.sd_clk(sd_clk),
		.sd_cke(sd_cke),
		.chipAddr(chipAddr),
		.chipL(chipL),
		.chipU(chipU),
		.chipRW(chipRW),
		.chipDMA(chipDMA),
		.chipWR(chipWR),
		.chipRD(chipRD),
		.chip48(chip48),
		.chip_snoop_we(chip_snoop_we),
		.chip_snoop_addr(chip_snoop_addr),
		.cpuAddr(cpuAddr),
		.cpuCS(cpuCS),
		.cpustate(cpustate),
		.cpuL(cpuL),
		.cpuU(cpuU),
		.cpuWR(cpuWR),
		.cpuRD(cpuRD),
		.ramready(ramready)
`ifdef HAS_WRITEBUSY
		,
		.writebusy(writebusy_unused)
`endif
	);

	initial begin
		force dut.sdram_state = 4'd0;
		repeat (2) @(posedge clk);
		release dut.sdram_state;
	end

	task fail;
		input [255:0] msg;
		begin
			failures = failures + 1;
			$display("FAIL: %0s", msg);
		end
	endtask

	task idle_cycle;
		begin
			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;
			@(posedge clk);
			#1;
		end
	endtask

	task cpu_write_word;
		input  [24:1] addr;
		input  [15:0] data;
		output integer cycles;
		begin
			cpuAddr = addr;
			cpuWR = data;
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = 2'b11;
			cpuCS = 1'b1;
			cycles = 0;
			@(posedge clk);
			#1;
			while (ramready !== 1'b1 && cycles < MAX_WAIT) begin
				cycles = cycles + 1;
				@(posedge clk);
				#1;
			end
			if (ramready !== 1'b1)
				fail("write timed out waiting for ramready");
			idle_cycle();
		end
	endtask

	task cpu_read_word;
		input  [24:1] addr;
		input         insn;
		output [15:0] data;
		output integer cycles;
		begin
			cpuAddr = addr;
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = insn ? 2'b00 : 2'b10;
			cpuCS = 1'b1;
			cycles = 0;
			@(posedge clk);
			#1;
			while (ramready !== 1'b1 && cycles < MAX_WAIT) begin
				cycles = cycles + 1;
				@(posedge clk);
				#1;
			end
			if (ramready !== 1'b1)
				fail("read timed out waiting for ramready");
			data = cpuRD;
			idle_cycle();
		end
	endtask

	task print_perf;
		input [255:0] name;
		input integer cycles;
		begin
			$display("PERF %0s %0d", name, cycles);
		end
	endtask

	initial begin
		$display("==== tb_sdram_perf ====");
		repeat (4) @(posedge clk);
		reset_n = 1'b1;
		repeat (520) @(posedge clk);
		#1;

		// 1. Posted write acknowledgement through the CPU-facing write buffer.
		cpu_write_word(24'h000100, 16'h1111, one);
		print_perf("posted_write_ack", one);
		repeat (32) @(posedge clk);

		// 2. Sustained write issue cost with SDRAM slots available.
		total = 0;
		cache_inhibit = 1'b1;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_write_word(24'h001000 + i[23:0], 16'h2000 + i[15:0], one);
			total = total + one + 1; // include the mandatory bus-idle release cycle
		end
		print_perf("write_stream_64", total);

		// 3. Uncached data reads. Measures read-miss transport overhead.
		total = 0;
		cache_inhibit = 1'b1;
		for (integer i = 0; i < 32; i = i + 1) begin
			cpu_read_word(24'h004000 + {i[22:0], 1'b0}, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("uncached_data_read_32", total);

		// 4. D-cache repeated hit after one fill.
		cache_inhibit = 1'b0;
		cpu_cache_ctrl = 4'b0011;
		repeat (8) @(posedge clk);
		cpu_read_word(24'h008000, 1'b0, dummy, one); // prime
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(24'h008000, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("dcache_hit_read_64", total);

		// 5. I-cache repeated hit after one fill.
		cpu_read_word(24'h00C000, 1'b1, dummy, one); // prime
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(24'h00C000, 1'b1, dummy, one);
			total = total + one + 1;
		end
		print_perf("icache_hit_read_64", total);

		// 6. Sequential cached data reads across several lines.
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(24'h010000 + {i[22:0], 1'b0}, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("cached_seq_data_read_64", total);

		if (failures != 0) begin
			$display("FAIL: %0d failure(s)", failures);
			$fatal(1, "sdram performance bench failed");
		end
		$finish;
	end
endmodule
