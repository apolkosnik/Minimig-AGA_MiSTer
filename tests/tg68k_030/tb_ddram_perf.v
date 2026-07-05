`timescale 1ns/1ps

// Standalone performance microbench for ddram_ctrl + cpu_cache_new.
// Output lines are machine-readable:
//   PERF <metric> <cycles>
//
// The bench intentionally instantiates ddram_ctrl without connecting optional
// newer ports, so the same source can run against older git revisions.
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

module tb_ddram_perf;
	localparam integer DDR_READ_LATENCY = 2;
	localparam integer MAX_WAIT = 2000;

	reg         clk = 1'b0;
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
	reg         ramshared = 1'b0;
	wire        ramready;
	wire        writebusy_unused;

	reg         read_pending = 1'b0;
	integer     read_countdown = 0;
	reg  [28:0] read_addr = 29'h0;
	integer     failures = 0;
	integer     total;
	integer     one;
	reg  [15:0] dummy;

	always #5 clk = ~clk;

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
		.ramshared(ramshared),
		.ramready(ramready)
`ifdef HAS_WRITEBUSY
		,
		.writebusy(writebusy_unused)
`endif
	);

	function [63:0] line_data;
		input [28:0] addr;
		reg [15:0] base;
		begin
			base = addr[15:0];
			line_data = {base ^ 16'h0003, base ^ 16'h0002,
			             base ^ 16'h0001, base ^ 16'h0000};
		end
	endfunction

	always @(posedge clk) begin
		DDRAM_DOUT_READY <= 1'b0;
		if (!reset_n) begin
			read_pending <= 1'b0;
			read_countdown <= 0;
			DDRAM_DOUT <= 64'h0;
		end else if (DDRAM_RD && !read_pending) begin
			read_pending <= 1'b1;
			read_countdown <= DDR_READ_LATENCY;
			read_addr <= DDRAM_ADDR;
		end else if (read_pending) begin
			if (read_countdown == 0) begin
				read_pending <= 1'b0;
				DDRAM_DOUT <= line_data(read_addr);
				DDRAM_DOUT_READY <= 1'b1;
			end else begin
				read_countdown <= read_countdown - 1;
			end
		end
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
		input  [28:1] addr;
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
		input  [28:1] addr;
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
		$display("==== tb_ddram_perf ====");
		repeat (4) @(posedge clk);
		reset_n = 1'b1;
		repeat (340) @(posedge clk);
		#1;

		// 1. Isolated posted write while DDR is unavailable. This catches the
		// regression where CPU ramready waited for physical DDR acceptance.
		DDRAM_BUSY = 1'b1;
		cpu_write_word(28'h000100, 16'h1111, one);
		print_perf("posted_write_busy_ack", one);
		repeat (12) @(posedge clk);
		DDRAM_BUSY = 1'b0;
		repeat (8) @(posedge clk);

		// 2. Sustained write issue cost with DDR ready.
		total = 0;
		cache_inhibit = 1'b1;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_write_word(28'h001000 + i[27:0], 16'h2000 + i[15:0], one);
			total = total + one + 1; // include the mandatory bus-idle release cycle
		end
		print_perf("write_stream_64", total);

		// 3. Uncached data reads. Measures read-miss transport overhead.
		total = 0;
		cache_inhibit = 1'b1;
		for (integer i = 0; i < 32; i = i + 1) begin
			cpu_read_word(28'h004000 + {i[26:0], 1'b0}, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("uncached_data_read_32", total);

		// 4. D-cache repeated hit after one fill.
		cache_inhibit = 1'b0;
		cpu_cache_ctrl = 4'b0011;
		repeat (8) @(posedge clk);
		cpu_read_word(28'h008000, 1'b0, dummy, one); // prime
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(28'h008000, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("dcache_hit_read_64", total);

		// 5. I-cache repeated hit after one fill.
		cpu_read_word(28'h00C000, 1'b1, dummy, one); // prime
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(28'h00C000, 1'b1, dummy, one);
			total = total + one + 1;
		end
		print_perf("icache_hit_read_64", total);

		// 6. Sequential cached data reads across several lines.
		total = 0;
		for (integer i = 0; i < 64; i = i + 1) begin
			cpu_read_word(28'h010000 + {i[26:0], 1'b0}, 1'b0, dummy, one);
			total = total + one + 1;
		end
		print_perf("cached_seq_data_read_64", total);

		if (failures != 0) begin
			$display("FAIL: %0d failure(s)", failures);
			$fatal(1, "ddram performance bench failed");
		end
		$finish;
	end
endmodule
