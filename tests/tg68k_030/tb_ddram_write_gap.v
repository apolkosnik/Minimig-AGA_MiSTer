`timescale 1ns/1ps

// Minimal simulation RAM used by cpu_cache_new in this standalone DDR bench.
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

module tb_ddram_write_gap;
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
	wire        writebusy = dut.write_req || dut.write_ack || (dut.write_state != 2'd0);
	integer    cycles;
	integer    failures = 0;

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
	);

	task fail;
		input [255:0] msg;
		begin
			failures = failures + 1;
			$display("FAIL: %0s", msg);
		end
	endtask

	task cpu_read_word_ready_while_busy;
		input [28:1] addr;
		input [63:0] line;
		input [15:0] expected;
		integer wait_cycles;
		begin
			cpuAddr = addr;
			cpuU = 1'b0;
			cpuL = 1'b0;
			cpustate = 2'b10;
			cpuCS = 1'b1;

			wait_cycles = 0;
			while (DDRAM_RD !== 1'b1 && wait_cycles < 20) begin
				wait_cycles = wait_cycles + 1;
				@(posedge clk);
				#1;
			end
			if (DDRAM_RD !== 1'b1) begin
				fail("read request did not reach DDR");
			end else begin
				@(posedge clk);
				#1;
				DDRAM_DOUT = line;
				DDRAM_BUSY = 1'b1;
				DDRAM_DOUT_READY = 1'b1;
				@(posedge clk);
				#1;
				DDRAM_DOUT_READY = 1'b0;
				DDRAM_BUSY = 1'b0;
			end

			wait_cycles = 0;
			while (ramready !== 1'b1 && wait_cycles < 20) begin
				wait_cycles = wait_cycles + 1;
				@(posedge clk);
				#1;
			end
			if (ramready !== 1'b1) begin
				fail("read with DOUT_READY while BUSY did not acknowledge");
			end else if (cpuRD !== expected) begin
				fail("read with DOUT_READY while BUSY returned wrong data");
			end else begin
				$display("PASS: DOUT_READY while BUSY was captured, cpuRD=%04x", cpuRD);
			end

			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		$display("==== tb_ddram_write_gap: posted write acknowledgement ====");
		repeat (4) @(posedge clk);
		reset_n = 1'b1;
		repeat (320) @(posedge clk);

		// Keep DDR busy so the physical write cannot be accepted immediately.
		DDRAM_BUSY = 1'b1;
		cpuAddr = 28'h000012;
		cpuWR = 16'hA55A;
		cpuU = 1'b0;
		cpuL = 1'b0;
		cpustate = 2'b11;
		cpuCS = 1'b1;

			repeat (6) begin
				@(posedge clk);
				#1;
				if (ramready === 1'b1)
					fail("CPU write acknowledged while DDRAM_BUSY was asserted");
				if (DDRAM_WE === 1'b1)
					fail("physical DDR write happened while DDRAM_BUSY was asserted");
				if (writebusy !== 1'b1)
					fail("write request was not held while DDRAM_BUSY was asserted");
			end
			$display("PASS: CPU write held while DDR busy");

			if (DDRAM_WE === 1'b1)
				fail("physical DDR write happened while DDRAM_BUSY was asserted");

			DDRAM_BUSY = 1'b0;
			cycles = 0;
			while (DDRAM_WE !== 1'b1 && cycles < 20) begin
				cycles = cycles + 1;
				@(posedge clk);
				#1;
			end
			if (DDRAM_WE !== 1'b1) begin
				fail("posted write did not drain to DDR after DDRAM_BUSY cleared");
			end else begin
				$display("PASS: held write drained to DDR in %0d cycles", cycles);
				if (DDRAM_ADDR !== {3'b001, cpuAddr[28:3]})
					fail("DDRAM_ADDR mismatch for drained write");
				if (DDRAM_DIN !== {4{cpuWR}})
					fail("DDRAM_DIN mismatch for drained write");
			end

			cycles = 0;
			while (ramready !== 1'b1 && cycles < 20) begin
				cycles = cycles + 1;
				@(posedge clk);
				#1;
			end
			if (ramready !== 1'b1)
				fail("CPU write did not acknowledge after DDR accepted the write");

			cpuCS = 1'b0;
			cpuU = 1'b1;
			cpuL = 1'b1;
			cpustate = 2'b00;

			cycles = 0;
		while (writebusy === 1'b1 && cycles < 10) begin
			cycles = cycles + 1;
			@(posedge clk);
			#1;
		end
			if (writebusy === 1'b1)
				fail("writebusy did not clear after posted write drained");

			cpu_read_word_ready_while_busy(28'h000021, 64'h4444_3333_2222_1111, 16'h2222);

			if (failures == 0) begin
				$display("PASS: DDR posted write behavior verified");
		end else begin
			$display("FAIL: %0d failure(s)", failures);
			$fatal(1, "DDR posted write behavior failed");
		end
		$finish;
	end
endmodule
