//--------------------------------------------------------------------------//
// cpu_cache_new external-cache control regression                          //
//                                                                          //
// Verifies independent I/D enables, that a hit in the wrong bank cannot    //
// satisfy a read, disabled banks do not fill, and a maintenance toggle is   //
// retained long enough to clear both tag RAMs.                              //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_cpu_cache_new;
	reg clk = 0;
	reg rst = 1;
	always #5 clk = ~clk;

	reg  [3:0]  cpu_cache_ctrl = 0;
	reg         cache_inhibit = 0;
	reg         cpu_cs = 0;
	reg [28:1]  cpu_adr = 0;
	reg  [1:0]  cpu_bs = 2'b11;
	reg         cpu_we = 0;
	reg         cpu_ir = 0;
	reg         cpu_dr = 0;
	reg [15:0]  cpu_dat_w = 0;
	wire [15:0] cpu_dat_r;
	wire        cpu_ack;
	wire        wb_en;
	reg [15:0]  sdr_dat_r = 16'hA55A;
	wire        sdr_read_req;
	reg         sdr_read_ack = 0;
	reg         snoop_act = 0;
	reg [28:1]  snoop_adr = 0;
	reg [15:0]  snoop_dat_w = 0;
	reg  [1:0]  snoop_bs = 0;

	integer errors = 0;
	integer timeout;
	integer mem_index;
	reg [17:0] tag;
	reg  [7:0] index;
	reg  [1:0] block;
	reg        saw_req;

	cpu_cache_new dut (
		.clk(clk), .rst(rst), .cpu_cache_ctrl(cpu_cache_ctrl),
		.cache_inhibit(cache_inhibit), .cpu_cs(cpu_cs), .cpu_adr(cpu_adr),
		.cpu_bs(cpu_bs), .cpu_we(cpu_we), .cpu_ir(cpu_ir), .cpu_dr(cpu_dr),
		.cpu_dat_w(cpu_dat_w), .cpu_dat_r(cpu_dat_r), .cpu_ack(cpu_ack),
		.wb_en(wb_en), .sdr_dat_r(sdr_dat_r), .sdr_read_req(sdr_read_req),
		.sdr_read_ack(sdr_read_ack), .snoop_act(snoop_act),
		.snoop_adr(snoop_adr), .snoop_dat_w(snoop_dat_w), .snoop_bs(snoop_bs)
	);

	task wait_idle;
		begin
			timeout = 0;
			while ((dut.cpu_sm_state != 4'd1 || dut.sdr_sm_state != 4'd2) &&
			       timeout < 1000) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (timeout == 1000) begin
				$display("FAIL: cache did not become idle");
				errors = errors + 1;
			end
		end
	endtask

	task install_i_line;
		input [15:0] value;
		begin
			tag = cpu_adr[28:11];
			index = cpu_adr[10:3];
			block = cpu_adr[2:1];
			mem_index = {index, block};
			dut.itram.mem[index] = (40'h1 << 38) | tag;
			dut.idram0.ram_l.mem[mem_index] = value[7:0];
			dut.idram0.ram_u.mem[mem_index] = value[15:8];
		end
	endtask

	task install_d_line;
		input [15:0] value;
		begin
			tag = cpu_adr[28:11];
			index = cpu_adr[10:3];
			block = cpu_adr[2:1];
			mem_index = {index, block};
			dut.dtram.mem[index] = (40'h1 << 38) | tag;
			dut.ddram0.ram_l.mem[mem_index] = value[7:0];
			dut.ddram0.ram_u.mem[mem_index] = value[15:8];
		end
	endtask

	task cached_read;
		input instr;
		input [15:0] expected;
		begin
			cpu_ir = instr;
			cpu_dr = !instr;
			cpu_cs = 1;
			saw_req = 0;
			timeout = 0;
			while (!cpu_ack && timeout < 20) begin
				@(posedge clk);
				if (sdr_read_req) saw_req = 1;
				timeout = timeout + 1;
			end
			if (!cpu_ack || saw_req || cpu_dat_r !== expected) begin
				$display("FAIL: %s cache hit ack=%b req=%b data=%h expected=%h",
				         instr ? "instruction" : "data", cpu_ack, saw_req,
				         cpu_dat_r, expected);
				errors = errors + 1;
			end
			cpu_cs = 0;
			cpu_ir = 0;
			cpu_dr = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	task uncached_read;
		input instr;
		begin
			cpu_ir = instr;
			cpu_dr = !instr;
			cpu_cs = 1;
			timeout = 0;
			while (!sdr_read_req && timeout < 20) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (!sdr_read_req) begin
				$display("FAIL: %s read was incorrectly satisfied by other cache bank",
				         instr ? "instruction" : "data");
				errors = errors + 1;
			end
			// The selected bank is disabled, so one returned word must complete
			// without starting a four-word line fill.
			sdr_read_ack = 1;
			@(posedge clk);
			sdr_read_ack = 0;
			cpu_cs = 0;
			cpu_ir = 0;
			cpu_dr = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	initial begin
		repeat (5) @(posedge clk);
		rst = 0;
		wait_idle;

		cpu_adr = 28'h0012340;

		// I enabled, D disabled: only the instruction view may hit.
		cpu_cache_ctrl = 4'b0001;
		repeat (3) @(posedge clk);
		install_i_line(16'h1234);
		repeat (2) @(posedge clk);
		cached_read(1'b1, 16'h1234);
		uncached_read(1'b0);
		if (dut.dtram.mem[index][38]) begin
			$display("FAIL: disabled data cache filled a tag");
			errors = errors + 1;
		end

		// D enabled, I disabled: the mirror-image case.
		cpu_cache_ctrl = 4'b0010;
		repeat (3) @(posedge clk);
		install_d_line(16'h5678);
		repeat (2) @(posedge clk);
		cached_read(1'b0, 16'h5678);
		uncached_read(1'b1);

		// Reinstall a valid line, then toggle maintenance while idle.  Both
		// tag memories must be cleared and both state machines must finish.
		cpu_cache_ctrl[1:0] = 2'b11;
		repeat (3) @(posedge clk);
		install_i_line(16'h9ABC);
		install_d_line(16'hDEF0);
		cpu_cache_ctrl[3] = ~cpu_cache_ctrl[3];
		timeout = 0;
		while (!dut.cc_clear_pending && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!dut.cc_clear_pending) begin
			$display("FAIL: maintenance toggle was not captured");
			errors = errors + 1;
		end
		// Let the accepting edge move both machines out of idle before
		// waiting for the completed invalidation pass.
		repeat (2) @(posedge clk);
		wait_idle;
		index = cpu_adr[10:3];
		if (dut.itram.mem[index][38:37] != 0 ||
		    dut.dtram.mem[index][38:37] != 0) begin
			$display("FAIL: maintenance toggle did not invalidate both caches");
			errors = errors + 1;
		end

		// A maintenance clear whose background sweep passes the miss index
		// while a line fill is waiting for SDRAM must not be undone by the
		// fill's tag writeback: the fill may validate only its own way.
		// (The AmigaOS crash signature of the captured-at-miss tag
		// implementation: exec's CacheClearU sweep ran during the fill
		// wait and FILL1 restored the pre-sweep valid bits, resurrecting
		// flushed lines.)
		cpu_cache_ctrl[1:0] = 2'b11;
		repeat (3) @(posedge clk);
		cpu_adr = 28'h0012340;	// index/block as the earlier tests
		install_d_line(16'hD00D);	// stale victim line ("tag" holds its tag)
		cached_read(0, 16'hD00D);	// sanity: it hits before the clear

		cpu_adr = 28'h1012340;	// same index, different tag
		cpu_ir = 0;
		cpu_dr = 1;
		cpu_cs = 1;
		timeout = 0;
		while (!sdr_read_req && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!sdr_read_req) begin
			$display("FAIL: clear-during-fill test did not miss");
			errors = errors + 1;
		end
		// fill is now pending; run a full maintenance sweep before acking
		cpu_cache_ctrl[3] = ~cpu_cache_ctrl[3];
		timeout = 0;
		while (dut.cache_init_done && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		timeout = 0;
		while (!dut.cache_init_done && timeout < 2000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!dut.cache_init_done) begin
			$display("FAIL: maintenance sweep did not finish during fill wait");
			errors = errors + 1;
		end
		// complete the four-word fill
		sdr_dat_r = 16'hF111;
		sdr_read_ack = 1;
		timeout = 0;
		while (!cpu_ack && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		repeat (4) @(posedge clk);
		sdr_read_ack = 0;
		cpu_cs = 0;
		cpu_dr = 0;
		repeat (2) @(posedge clk);
		wait_idle;
		// the swept victim way must stay invalid: a read with the old tag
		// has to miss again instead of hitting resurrected stale data
		index = cpu_adr[10:3];
		if (dut.dtram.mem[index][17:0] == tag &&
		    dut.dtram.mem[index][38]) begin
			$display("FAIL: fill writeback resurrected the swept way0 line");
			errors = errors + 1;
		end
		cpu_adr = 28'h0012340;
		cpu_ir = 0;
		cpu_dr = 1;
		cpu_cs = 1;
		saw_req = 0;
		timeout = 0;
		while (!cpu_ack && timeout < 30) begin
			@(posedge clk);
			if (sdr_read_req) begin
				saw_req = 1;
				sdr_dat_r = 16'hF222;
				sdr_read_ack = 1;
			end
			timeout = timeout + 1;
		end
		sdr_read_ack = 0;
		cpu_cs = 0;
		cpu_dr = 0;
		if (!saw_req) begin
			$display("FAIL: stale tag survived the clear (read hit old line, data=%h)",
			         cpu_dat_r);
			errors = errors + 1;
		end
		repeat (3) @(posedge clk);

		if (errors == 0) $display("ALL TESTS PASSED");
		else             $display("TEST FAILED with %0d errors", errors);
		$finish;
	end
endmodule

// Simple synchronous dual-port RAM model for cpu_cache_new's generic dpram.
module dpram #(parameter AW = 8, parameter DW = 8) (
	input clock,
	input [AW-1:0] address_a,
	input [DW-1:0] data_a,
	input wren_a,
	output reg [DW-1:0] q_a,
	input [AW-1:0] address_b,
	input [DW-1:0] data_b,
	input wren_b,
	output reg [DW-1:0] q_b
);
	reg [DW-1:0] mem [0:(1<<AW)-1];
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
		q_a <= mem[address_a];
		q_b <= mem[address_b];
	end
endmodule
