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
wire        walker_req, walker_we;
wire [31:0] walker_addr, walker_wdat;
reg         walker_ack;
reg  [31:0] walker_data;
reg         walker_berr_r;    // one-shot walker bus error, armed via $F146
reg         wberr_arm;

reg         mem_ready;
reg         berr_armed;
reg   [1:0] irq_exc_armed;
reg   [2:0] irq_fetch_stall;
wire        berr = berr_armed && nreset && (busstate != 2'b01) &&
                   (addr_out[15:0] == 16'hF140);

wire        clkena_in = (busstate == 2'b01) | mem_ready | berr;

reg   [2:0] ipl_lvl;
reg  [15:0] ipl_delay = 0;   // $F148: delayed level-2 IPL countdown
// +exctrace: print every exception entry (vector, pc) for A/B diffing
reg [7:0] et_prev = 0;
always @(posedge clk) begin
	et_prev <= dut.core.state;
	if ($test$plusargs("exctrace") &&
	    dut.core.state == 8'd34 && et_prev != 8'd34)
		$display("EXC vec=%0d pc=%08x spc=%08x sr=%04x",
		         dut.core.exc_vec, dut.core.pc,
		         dut.core.exc_spc, dut.core.sr);
end

ap040_tg68k_compat dut
(
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),
	.data_in(data_in),
	.ipl(~ipl_lvl),
	.ipl_autovector(1'b1),
	.berr(berr),

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
	.walker_req(walker_req),
	.walker_we(walker_we),
	.walker_addr(walker_addr),
	.walker_wdat(walker_wdat),
	.walker_ack(walker_ack),
	.walker_data(walker_data),
	.walker_berr(walker_berr_r),
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
reg  [7:0]  prev_core_state;
always @(posedge clk) if (dut.core.ce) prev_core_state <= dut.core.state;

//---------------------------------------------------------------------------
// 64 KB memory model
//---------------------------------------------------------------------------

reg [15:0] mem [0:32767];

// Phase 2 models the cpu_cache_new handshake: the acknowledge is a LEVEL
// that stays high -- with the data captured when it rose -- until the bus
// is sampled idle (cpu_ack clears only on !cpu_cs).  A request issued
// with no sampled idle gap is therefore served the PREVIOUS data, which
// is the hardware failure mode behind the cputest FADD.P ([]) stale
// pointer word and the FABS.X ([0]) shifted operand window.
reg        lvl_hold;
reg [15:0] lvl_data;

integer errors;
integer phase;
integer result;          // 0 running, 1 pass, 2 fail

assign data_in = (phase == 2 && lvl_hold) ? lvl_data : mem[addr_out[15:1]];
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
reg       walker_pending;
reg       walker_armed;
reg       walker_we_latch;
reg [31:0] walker_addr_latch;
reg [31:0] walker_wdat_latch;
reg  [2:0] walker_lat_cnt;
integer   walker_lat_idx;
integer   walker_cycles;

always @(posedge clk) begin
	if (phase != 2) mem_ready <= 0;
	if (!nreset) begin
		mem_ready <= 0;
		lvl_hold <= 0;
		lat_cnt <= latency(phase, 0);
		lat_idx <= 1;
		berr_armed <= 1;
		irq_exc_armed <= 0;
		irq_fetch_stall <= 0;
	end
	else if (berr) begin
		// One physical bus error per phase.  The restarted access succeeds,
		// proving that the adapter released the failed sub-cycle.
		berr_armed <= 0;
		mem_ready <= 0;
		lvl_hold <= 0;
	end
	else if (phase == 2) begin
		// level acknowledge: drops only when the bus is sampled idle
		if (busstate == 2'b01) begin
			mem_ready <= 0;
			lvl_hold <= 0;
		end
		else if (!lvl_hold) begin
			if (lat_cnt == 0) begin
				mem_ready <= 1;
				lvl_hold <= 1;
				lvl_data <= mem[addr_out[15:1]];
				lat_cnt <= latency(phase, lat_idx);
				lat_idx <= lat_idx + 1;
			end
			else lat_cnt <= lat_cnt - 1'd1;
		end
		// else: hold acknowledge and captured data (stale if the CPU
		// started a new access without an idle gap)
	end
	else if (irq_fetch_stall != 0 && busstate != 2'b01 && !mem_ready) begin
		// Keep the first handler refill outstanding while IPL synchronizes.
		irq_fetch_stall <= irq_fetch_stall - 1'd1;
	end
	else if (busstate != 2'b01 && !mem_ready) begin
		if (lat_cnt == 0) begin
			mem_ready <= 1;
			lat_cnt   <= latency(phase, lat_idx);
			lat_idx   <= lat_idx + 1;
		end
		else lat_cnt <= lat_cnt - 1'd1;
	end
	// The exception program uses this write-only test register to arm a
	// second physical bus error for its faulting-MOVES case.
	if (nreset && mem_ready && busstate == 2'b11 &&
	    addr_out[15:0] == 16'hF142)
		berr_armed <= 1;

	// $F146 arms a one-shot bus error on the NEXT table-walker descriptor
	// access, for the PTEST MMUSR B-bit test.
	if (nreset && mem_ready && busstate == 2'b11 &&
	    addr_out[15:0] == 16'hF146)
		wberr_arm <= 1;

	// Mode 1 raises IPL during stacking. Mode 2 raises it after the vector
	// has been read and stalls the first handler refill for synchronization.
	if (nreset && mem_ready && busstate == 2'b11 &&
	    addr_out[15:0] == 16'hF144) begin
		irq_exc_armed <= data_write[1:0];
			`ifdef AP040_TRACE
			$display("TRACE armed exception-time IRQ mode=%0d pc=%h",
			         data_write[1:0], dbg_pc);
			`endif
	end
	else if (irq_exc_armed == 1 && dut.core.state == 8'd34 &&
	         dut.core.exc_vec == 8'd32) begin
		ipl_lvl <= 3'd2;
		irq_exc_armed <= 0;
			`ifdef AP040_TRACE
			$display("TRACE raised stacking-time IPL2 pc=%h", dbg_pc);
			`endif
	end
	else if (irq_exc_armed == 2 && dut.core.state == 8'd42 &&
	         dut.core.exc_vec == 8'd32) begin
		ipl_lvl <= 3'd2;
		irq_exc_armed <= 0;
		irq_fetch_stall <= 3'd5;
		`ifdef AP040_TRACE
		$display("TRACE raised handler-refill IPL2 pc=%h", dbg_pc);
		`endif
	end

	// $F148 arms a delayed level-2 interrupt: the IPL lines rise the
	// written number of clk cycles later.  The FPU soak in t_fpu sweeps
	// this against background (released) FPU execution.
	if (nreset && mem_ready && busstate == 2'b11 &&
	    addr_out[15:0] == 16'hF148)
		ipl_delay <= data_write;
	else if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end
end

// Dedicated 32-bit physical table-walker memory port.  It deliberately has
// an independent latency profile and never asserts mem_ready on the 16-bit
// CPU bus, so all MMU tests fail if descriptor traffic leaks onto that bus.
always @(posedge clk) begin
	walker_ack <= 0;
	walker_berr_r <= 0;
	if (!nreset) begin
		wberr_arm        <= 0;
		walker_pending   <= 0;
		walker_armed     <= 1;
		walker_we_latch  <= 0;
		walker_addr_latch <= 0;
		walker_wdat_latch <= 0;
		walker_data      <= 0;
		walker_lat_cnt   <= latency(phase, 0);
		walker_lat_idx   <= 1;
		walker_cycles    <= 0;
	end
	else begin
		if (!walker_req) walker_armed <= 1;
		if (walker_req && (busstate != 2'b01)) begin
			errors = errors + 1;
			$display("FAIL: walker and 16-bit CPU bus active together (pc=%h)", dbg_pc);
			result = 2;
		end

		if (walker_req && walker_armed && !walker_pending) begin
			walker_pending    <= 1;
			walker_armed      <= 0;
			walker_we_latch   <= walker_we;
			walker_addr_latch <= walker_addr;
			walker_wdat_latch <= walker_wdat;
			walker_lat_cnt    <= latency(phase, walker_lat_idx);
			walker_lat_idx    <= walker_lat_idx + 1;
			walker_cycles     <= walker_cycles + 1;
		end
		else if (walker_pending) begin
			if (walker_lat_cnt != 0)
				walker_lat_cnt <= walker_lat_cnt - 1'd1;
			else if (wberr_arm) begin
				// injected physical bus error on this descriptor access
				wberr_arm      <= 0;
				walker_pending <= 0;
				walker_berr_r  <= 1;
			end
			else begin
				if (walker_addr_latch[31:16] != 0 ||
				    walker_addr_latch[1:0] != 0) begin
					errors = errors + 1;
					$display("FAIL: invalid walker address %h", walker_addr_latch);
					result = 2;
				end
				else if (walker_we_latch) begin
					mem[walker_addr_latch[15:1]] = walker_wdat_latch[31:16];
					mem[walker_addr_latch[15:1] + 1'b1] = walker_wdat_latch[15:0];
				end
				else begin
					walker_data <= {mem[walker_addr_latch[15:1]],
					                mem[walker_addr_latch[15:1] + 1'b1]};
				end
				walker_pending <= 0;
				walker_ack     <= 1;
			end
		end
	end
end

// bus monitor and write commit
always @(posedge clk) begin
	if (nreset && mem_ready) begin
		// Reset vectors, exception frames and exception vectors are
		// supervisor-data cycles; the first handler opcode is supervisor
		// program.  This also catches a leaked MOVES SFC/DFC override.
		if (dut.core.in_exc) begin
			if (busstate == 2'b00 && fc !== 3'd6) begin
				errors = errors + 1;
				$display("FAIL: exception handler fetch used FC=%0d, expected 6", fc);
				result = 2;
			end
			else if ((busstate == 2'b10 || busstate == 2'b11) && fc !== 3'd5) begin
				errors = errors + 1;
				$display("FAIL: exception/reset data cycle used FC=%0d, expected 5", fc);
				result = 2;
			end
		end

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
					$display("FAIL: program reports failure, test %0d (phase %0d, pc=%h, ill=%0d, addr=%0d)",
					         mem[16'hF100 >> 1], phase, dbg_pc,
					         mem[16'h3602 >> 1], mem[16'h361E >> 1]);
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
		$display("FAIL: core halted, fault=%b pc=%h ir=%h prev_state=%0d in_exc=%b mem_flt=%b",
		         debug_fault, dbg_pc, dbg_ir, prev_core_state, dut.core.in_exc,
		         dut.core.mem_flt);
		result = 2;
	end
end

`ifdef AP040_TRACE
always @(posedge clk) if (nreset && dut.core.ce) begin
	if (dut.core.state == 7'd4)
		$display("TRACE decode pc=%h ir=%h sr=%h in_exc=%b", dut.core.pc,
		         dut.core.ir, dut.core.sr, dut.core.in_exc);
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
		irq_exc_armed = 0;
		irq_fetch_stall = 0;

		for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
		$readmemh(prog_file, mem);
		// interrupt-injection capability word: t_fpu's IRQ soak runs
		// only where the bench can deliver IPL
		mem[16'hF14A >> 1] = 16'h0001;

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
	run_phase(2);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	// differential testing: dump the data window for comparison
	if (errors == 0 && $value$plusargs("dump=%s", dump_file))
		$writememh(dump_file, mem, 'h3000 >> 1, ('h4000 >> 1) - 1);
	$finish;
end

endmodule
