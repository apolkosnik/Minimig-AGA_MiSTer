//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// tb_ap040_program.v - runs an assembled self-checking program image       //
//                                                                          //
// The program image (built by build_tests.sh) is loaded with $readmemh     //
// from the file given with +prog=<file>. The program reports through       //
// memory-mapped registers:                                                 //
//   $F100 word: failing test number                                        //
//   $F102 word: $BAD0 = failed, $600D = all passed                         //
//   $F110 word: interrupt request level (0 releases the lines)             //
//   $F120 byte: writes must carry FC=1 (MOVES/DFC check)                   //
//                                                                          //
// The image runs twice: once with back-to-back bus ready and once with     //
// varied wait states.                                                      //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_ap040_program;

reg clk = 0;
reg nreset = 0;

always #5 clk = ~clk;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds;
wire  [1:0] busstate;
wire        longword;
wire        nresetout;
wire  [2:0] fc;
wire [31:0] cacr_out, vbr_out;
wire        debug_busy, debug_fault, debug_halted;
wire [255:0] debug_status;

reg         mem_ready;
wire        clkena_in = (busstate == 2'b01) | mem_ready;

reg   [2:0] ipl_lvl;

ap040_tg68k_compat dut
(
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),
	.data_in(data_in),
	.ipl(~ipl_lvl),
	.ipl_autovector(1'b1),
	.berr(1'b0),

	.addr_out(addr_out),
	.data_write(data_write),
	.nwr(nwr),
	.nuds(nuds),
	.nlds(nlds),
	.busstate(busstate),
	.longword(longword),
	.nresetout(nresetout),
	.fc(fc),

	.mmu_addr_log(),
	.mmu_addr_phys(),
	.mmu_cache_inhibit(),
	.walker_req(),
	.walker_we(),
	.walker_addr(),
	.walker_wdat(),
	.walker_ack(1'b0),
	.walker_data(32'd0),
	.walker_berr(1'b0),
	.cache_req(),
	.cache_addr(),
	.cache_data(16'd0),
	.cache_ack(1'b0),
	.cache_burst(),
	.cache_burst_len(),
	.cache_ramaddr(),

	.cacr_out(cacr_out),
	.vbr_out(vbr_out),
	.debug_busy(debug_busy),
	.debug_fault(debug_fault),
	.debug_halted(debug_halted),
	.debug_status(debug_status)
);

wire [31:0] dbg_pc = debug_status[31:0];
wire [15:0] dbg_ir = debug_status[63:48];

//---------------------------------------------------------------------------
// 64 KB memory model
//---------------------------------------------------------------------------

reg [15:0] mem [0:32767];

assign data_in = mem[addr_out[15:1]];

integer errors;
integer phase;
integer result;          // 0 running, 1 pass, 2 fail
reg [1023:0] prog_file;
reg [1023:0] dump_file;

function [2:0] latency;
	input integer ph;
	input integer n;
	begin
		if (ph == 0) latency = 0;
		else         latency = (n * 7 + 3) % 6;
	end
endfunction

reg [2:0] lat_cnt;
integer lat_idx;

always @(posedge clk) begin
	mem_ready <= 0;
	if (!nreset) begin
		lat_cnt <= latency(phase, 0);
		lat_idx <= 1;
	end
	else if (busstate != 2'b01 && !mem_ready) begin
		if (lat_cnt == 0) begin
			mem_ready <= 1;
			lat_cnt   <= latency(phase, lat_idx);
			lat_idx   <= lat_idx + 1;
		end
		else lat_cnt <= lat_cnt - 1'd1;
	end
end

// bus monitor and write commit
always @(posedge clk) begin
	if (nreset && mem_ready) begin
		if (addr_out[31:16] != 0) begin
			errors = errors + 1;
			$display("FAIL: access outside memory model at %h (pc=%h)", addr_out, dbg_pc);
			result = 2;
		end

		if (busstate == 2'b11) begin
			if (!nuds) mem[addr_out[15:1]][15:8] = data_write[15:8];
			if (!nlds) mem[addr_out[15:1]][7:0]  = data_write[7:0];

			// test control registers
			if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin
				if (data_write == 16'h600D) result = 1;
				else begin
					errors = errors + 1;
					$display("FAIL: program reports failure, test %0d (phase %0d)",
					         mem[16'hF100 >> 1], phase);
					result = 2;
				end
			end
			if (addr_out[15:0] == 16'hF110) begin
				ipl_lvl <= data_write[2:0];
			end
			if (addr_out[15:1] == (16'hF120 >> 1) && fc !== 3'd1) begin
				errors = errors + 1;
				$display("FAIL: write to F120 with FC=%0d, expected 1", fc);
			end
			// DMA-style poke behind the CPU's back for the cache tests
			if (addr_out[15:0] == 16'hF130) begin
				mem[16'h3500 >> 1] = data_write;
				mem[16'h3502 >> 1] = 16'h0000;
			end
		end
	end
end

// unexpected halt detection
always @(posedge clk) begin
	if (nreset && (debug_fault || debug_halted) && result == 0) begin
		errors = errors + 1;
		$display("FAIL: core halted, fault=%b pc=%h ir=%h", debug_fault, dbg_pc, dbg_ir);
		result = 2;
	end
end

`ifdef AP040_TRACE
always @(posedge clk) if (nreset && dut.core.ce) begin
	if (dut.core.state == 7'd4)
		$display("TRACE decode pc=%h ir=%h sr=%h", dut.core.pc, dut.core.ir, dut.core.sr);
	if (dut.core.state == 7'd34)
		$display("TRACE exc vec=%0d fmt=%0d spc=%h", dut.core.exc_vec, dut.core.exc_fmt, dut.core.exc_spc);
end
always @(posedge clk) if (nreset && mem_ready && busstate == 2'b11 &&
                          addr_out >= 32'h3600 && addr_out < 32'h3640)
	$display("TRACE cntwr addr=%h data=%h uds=%b lds=%b", addr_out, data_write, nuds, nlds);
`endif

//---------------------------------------------------------------------------
// phase driver
//---------------------------------------------------------------------------

integer timeout;
integer i;

task run_phase;
	input integer ph;
	begin
		phase   = ph;
		result  = 0;
		ipl_lvl = 0;

		for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
		$readmemh(prog_file, mem);

		nreset = 0;
		repeat (10) @(posedge clk);
		nreset = 1;

		timeout = 0;
		while (result == 0 && timeout < 20000000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (result == 0) begin
			errors = errors + 1;
			$display("FAIL: phase %0d timeout, pc=%h ir=%h fault=%b halted=%b",
			         ph, dbg_pc, dbg_ir, debug_fault, debug_halted);
		end
		else if (result == 1)
			$display("phase %0d passed (%0d cycles)", ph, timeout);
	end
endtask

initial begin
	errors = 0;
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_ap040_program: running %0s", prog_file);

	run_phase(0);
	run_phase(1);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	// differential testing: dump the data window for comparison
	if (errors == 0 && $value$plusargs("dump=%s", dump_file))
		$writememh(dump_file, mem, 'h3000 >> 1, ('h4000 >> 1) - 1);
	$finish;
end

endmodule
