//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core (2026-09-24)                   //
//                                                                          //
// tb_ap040_pipe_program.v - the sequential core's self-checking programs  //
//                                                                          //
// tests/ap040/asm/*.s were written for rtl/ap040/ap040_core.v and run by   //
// tests/ap040/tb_ap040_program.v. This is that bench around the pipelined  //
// core: the same 64 KB memory, the same three bus phases (back-to-back     //
// ready, varied wait states, and a level-held acknowledge that serves a    //
// request issued without an idle gap the PREVIOUS data), the same reset    //
// vectors at $0 (RESET_VECTORS=1), and the same protocol registers:        //
//   $F100 w  failing test number       $F102 w  $600D pass / $BAD0 fail   //
//   $F108 w  cycle stamp               $F110 w  interrupt level           //
//   $F120    writes must carry FC=1    $F130 w  DMA-style poke of $3500   //
//   $F148 w  level 2 after N cycles    $F14C w  level, withdrawn after N  //
//   $F150 w  two devices: level, then a lower one after N cycles          //
//   $F160 r  capability word (7: coarse and fine interrupts, bus errors)  //
//   $F140/$F142/$F154/$F146: bus errors on a data cycle, re-armed, on a   //
//            fetch at an address, and on the next table-walk descriptor   //
//                                                                          //
// The program image is +prog=<hex>, built by tests/ap040/build_tests.sh.  //
//                                                                          //
// Kept from the reference bench, on this core's own signals: the phantom- //
// interrupt invariant (nothing accepted well after the level went idle)   //
// and the mask invariant (a level 1-6 interrupt accepted at or below the  //
// mask only on a claim it made while it qualified). Not kept, because     //
// they name the sequential core's states: the exception-prefetch queue    //
// invariant, the locked read-modify-write fetch window (this core has no  //
// bus lock yet), the exception-cycle function-code checks (tb_ap040_pipe_ //
// excfc.v covers those), and the stacking-time interrupt arming at $F144. //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps
`include "ap040_pipe_defs.svh"

module tb_ap040_pipe_program;

reg clk = 0;
reg nreset = 0;
always #5 clk = ~clk;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds;
wire  [1:0] busstate;
wire        longword;
wire  [2:0] fc;

reg         mem_ready;
reg         berr_armed;
reg         fberr_armed = 0;
reg  [15:0] fberr_addr = 0;
wire        berr_d = berr_armed && nreset && (busstate != 2'b01) &&
                     (addr_out[15:0] == 16'hF140);
wire        fberr  = fberr_armed && nreset && (busstate == 2'b00) &&
                     (addr_out[15:0] == fberr_addr);
wire        berr   = berr_d | fberr;

wire        bus_clkena = (busstate == 2'b01) | mem_ready | berr;

reg   [2:0] ipl_lvl;
reg  [15:0] ipl_delay = 0;
reg   [7:0] ipl_pulse = 0;
reg   [7:0] ipl_step  = 0;
reg   [2:0] ipl_next  = 0;
integer     clkcount = 0, stamp_prev = 0;
always @(posedge clk) clkcount = clkcount + 1;

// The core's enable, pseudo-random under AP040_PIPE_CE_RANDOM as in every
// milestone bench; the bus keeps its own.
reg ce = 1;
`ifdef AP040_PIPE_CE_RANDOM
reg [15:0] ce_lfsr = 16'hACE1;
always @(negedge clk) if (nreset) begin
	ce_lfsr <= {ce_lfsr[14:0], ce_lfsr[15] ^ ce_lfsr[13] ^ ce_lfsr[12] ^ ce_lfsr[10]};
	ce      <= ce_lfsr[0];
end
`endif

ap040_pipe_bus16 #(
	.PC_RESET     (32'h0000_0400),
	.PROG_WORDS   (32'h7FFF_FFFF),
	.RESET_VECTORS(1)
) dut
(
	.clk (clk), .nreset (nreset), .ce (ce), .clkena_in (bus_clkena),
	.irq_lvl (ipl_lvl), .berr (berr),
	.data_in (data_in), .addr_out(addr_out), .data_write(data_write),
	.nwr (nwr), .nuds(nuds), .nlds(nlds),
	.busstate(busstate), .longword(longword), .fc(fc),
	.dbg_if_valid (), .dbg_if_pc (), .dbg_id_valid (), .dbg_id_pc (),
	.dbg_eac_valid(), .dbg_eac_pc(), .dbg_eaf_valid(), .dbg_eaf_pc(),
	.dbg_ex_valid (), .dbg_ex_pc (), .dbg_wb_valid (), .dbg_wb_pc (),
	.dbg_d0(), .dbg_d1(), .dbg_d2(), .dbg_d3(),
	.dbg_d4(), .dbg_d5(), .dbg_d6(), .dbg_d7(),
	.dbg_ccr(), .dbg_sr(), .dbg_commits()
);

wire [31:0] dbg_pc = dut.u_cpu.u_eaf.eac_pc;

//---------------------------------------------------------------------------
// 64 KB memory, three phases
//---------------------------------------------------------------------------

reg [15:0] mem [0:32767];
reg        lvl_hold;
reg [15:0] lvl_data;
integer errors, phase, result;
assign data_in = (phase == 2 && lvl_hold) ? lvl_data : mem[addr_out[15:1]];
reg [1023:0] prog_file;
integer prog_fd;

function [2:0] latency;
	input integer ph;
	input integer n;
	begin
		if (ph == 0) latency = 0;
		else         latency = (n * 7 + 3) % 6;
	end
endfunction

reg [2:0] lat_cnt;
integer   lat_idx;

always @(posedge clk) begin
	if (phase != 2) mem_ready <= 0;
	if (!nreset) begin
		mem_ready <= 0; lvl_hold <= 0;
		lat_cnt <= latency(phase, 0); lat_idx <= 1;
		berr_armed <= 1;
	end
	else if (berr) begin
		// one physical bus error per arming; the restarted access succeeds
		if (berr_d) berr_armed  <= 0;
		if (fberr)  fberr_armed <= 0;
		mem_ready <= 0; lvl_hold <= 0;
	end
	else if (phase == 2) begin
		if (busstate == 2'b01) begin mem_ready <= 0; lvl_hold <= 0; end
		else if (!lvl_hold) begin
			if (lat_cnt == 0) begin
				mem_ready <= 1; lvl_hold <= 1; lvl_data <= mem[addr_out[15:1]];
				lat_cnt <= latency(phase, lat_idx); lat_idx <= lat_idx + 1;
			end
			else lat_cnt <= lat_cnt - 1'd1;
		end
	end
	else if (busstate != 2'b01 && !mem_ready) begin
		if (lat_cnt == 0) begin
			mem_ready <= 1;
			lat_cnt <= latency(phase, lat_idx); lat_idx <= lat_idx + 1;
		end
		else lat_cnt <= lat_cnt - 1'd1;
	end
	if (nreset && mem_ready && busstate == 2'b11 && addr_out[15:0] == 16'hF142)
		berr_armed <= 1;
	if (nreset && mem_ready && busstate == 2'b11 && addr_out[15:0] == 16'hF154) begin
		fberr_armed <= |data_write;
		fberr_addr  <= data_write;
	end
	if (nreset && mem_ready && busstate == 2'b11 && addr_out[15:0] == 16'hF148)
		ipl_delay <= data_write;
	else if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end
	if (nreset && mem_ready && busstate == 2'b11 && addr_out[15:0] == 16'hF14C) begin
		ipl_lvl   <= data_write[2:0];
		ipl_pulse <= data_write[15:8];
	end
	else if (ipl_pulse != 0) begin
		ipl_pulse <= ipl_pulse - 1'd1;
		if (ipl_pulse == 8'd1) ipl_lvl <= 3'd0;
	end
	if (nreset && mem_ready && busstate == 2'b11 && addr_out[15:0] == 16'hF150) begin
		ipl_lvl  <= data_write[2:0];
		ipl_next <= data_write[6:4];
		ipl_step <= data_write[15:8];
	end
	else if (ipl_step != 0) begin
		ipl_step <= ipl_step - 1'd1;
		if (ipl_step == 8'd1) ipl_lvl <= ipl_next;
	end
end

//---------------------------------------------------------------------------
// interrupt invariants, on this core's acceptance (u_eaf's irq_take)
//---------------------------------------------------------------------------

reg  [15:0] ipl_idle_for = 0;
reg   [6:1] tb_qual = 0;
integer     ql;
wire        acc     = dut.u_cpu.irq_ack;
wire  [2:0] acc_lvl = dut.u_cpu.irq_take_lvl;
always @(posedge clk) begin
	if (!nreset) tb_qual <= 0;
	else begin
		for (ql = 1; ql <= 6; ql = ql + 1) begin
			if (dut.u_cpu.u_irq.lvl < ql)
				tb_qual[ql] <= 0;
			else if (dut.u_cpu.u_irq.lvl == ql && ql > dut.u_cpu.sr[10:8])
				tb_qual[ql] <= 1;
		end
		if (acc && acc_lvl != 3'd7 && acc_lvl != 3'd0) tb_qual[acc_lvl] <= 0;
	end
	if (ipl_lvl == 3'd0) begin
		if (ipl_idle_for != 16'hffff) ipl_idle_for <= ipl_idle_for + 1'd1;
	end
	else ipl_idle_for <= 0;
	if (nreset && acc && ipl_idle_for > 16'd12) begin
		errors = errors + 1;
		$display("FAIL: interrupt accepted %0d cycles after the level went idle (phantom)", ipl_idle_for);
	end
	if (nreset && acc && acc_lvl != 3'd7 && acc_lvl <= dut.u_cpu.sr_resolved_ea[10:8] && !tb_qual[acc_lvl]) begin
		errors = errors + 1;
		$display("FAIL: level %0d interrupt accepted at or below mask %0d (pc=%h)",
		         acc_lvl, dut.u_cpu.sr_resolved_ea[10:8], dbg_pc);
	end
end

//---------------------------------------------------------------------------
// bus monitor and write commit
//---------------------------------------------------------------------------

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
			if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin
				if (data_write == 16'h600D) result = 1;
				else begin
					errors = errors + 1;
					$display("FAIL: program reports failure, test %0d (phase %0d, pc=%h)",
					         mem[15'h7880], phase, dbg_pc);
					result = 2;
				end
			end
			if (addr_out[15:0] == 16'hF108) begin
				$display("STAMP tag=%04x cycles=%0d", data_write, clkcount - stamp_prev);
				stamp_prev = clkcount;
			end
			if (addr_out[15:0] == 16'hF110) ipl_lvl <= data_write[2:0];
			if (addr_out[15:1] == (16'hF120 >> 1) && fc !== 3'd1) begin
				errors = errors + 1;
				$display("FAIL: write to F120 with FC=%0d, expected 1", fc);
			end
			if (addr_out[15:0] == 16'hF130) begin
				mem[15'h1A80] = data_write;
				mem[15'h1A81] = 16'h0000;
			end
		end
	end
end

// +exctrace: every exception entry, on the cycle its verdict registers.
reg exc_go_q = 0;
always @(posedge clk) begin
	exc_go_q <= dut.u_cpu.u_eaf.exc_go;
	if ($test$plusargs("exctrace") && nreset && dut.u_cpu.u_eaf.exc_go && !exc_go_q)
		$display("EXC %0t vec=%0d pc=%h sr=%h phase=%0d", $time, dut.u_cpu.u_eaf.exc_vec_r,
		         dut.u_cpu.u_eaf.eac_pc, dut.u_cpu.u_eaf.sr_in, phase);
end

// +storetrace: every store EA-fetch posts, with what the snoop compared.
always @(posedge clk)
	if ($test$plusargs("storetrace") && nreset && dut.u_cpu.eaf_l1_wren_b && !dut.u_cpu.l1_wr_busy)
		$display("ST %0t pc=%h a=%h departs=%b", $time, dut.u_cpu.u_eaf.eac_pc,
		         dut.u_cpu.eaf_l1_addr_b, dut.u_cpu.eaf_departs);
always @(posedge clk)
	if ($test$plusargs("storetrace") && nreset && dut.u_cpu.sq_v)
		$display("SQ %0t a=%h dep=%b eac=%b %h-%h id=%b %h-%h dec=%b %h if=%b %h hit=%b late=%b", $time,
		         dut.u_cpu.sq_a, dut.u_cpu.sq_dep, dut.u_cpu.eac_valid, dut.u_cpu.eac_pc, dut.u_cpu.eac_next_pc,
		         dut.u_cpu.id_valid, dut.u_cpu.id_pc, dut.u_cpu.id_next_pc,
		         dut.u_cpu.dec_holding, dut.u_cpu.dec_hold_pc, dut.u_cpu.if_valid_id, dut.u_cpu.if_pc,
		         dut.u_cpu.smc_hit, dut.u_cpu.st_smc_late);

always @(posedge clk)
	if ($test$plusargs("storetrace") && nreset && dut.u_cpu.ex_st_req && !dut.u_cpu.l1_wr_busy)
		$display("STX %0t a=%h eac=%b %h-%h id=%b %h-%h dec=%b %h if=%b %h smc=%b stall=%b", $time,
		         dut.u_cpu.snx_a, dut.u_cpu.eac_valid, dut.u_cpu.eac_pc, dut.u_cpu.eac_next_pc,
		         dut.u_cpu.id_valid, dut.u_cpu.id_pc, dut.u_cpu.id_next_pc,
		         dut.u_cpu.dec_holding, dut.u_cpu.dec_hold_pc, dut.u_cpu.if_valid_id, dut.u_cpu.if_pc,
		         dut.u_cpu.st_smc, dut.u_cpu.ex_stall);

// +trace: every retirement, for a first look at where a program went.
always @(posedge clk)
	if ($test$plusargs("trace") && nreset && dut.u_cpu.dbg_wb_valid)
		$display("TRACE %0t wb pc=%h sr=%h d0=%h d7=%h a7=%h", $time, dut.u_cpu.dbg_wb_pc,
		         dut.u_cpu.sr, dut.u_cpu.u_regfile.dreg[0], dut.u_cpu.u_regfile.dreg[7],
		         dut.u_cpu.u_regfile.isp);

//---------------------------------------------------------------------------
// phase driver
//---------------------------------------------------------------------------

integer timeout, i;

task run_phase;
	input integer ph;
	begin
		phase = ph; result = 0; ipl_lvl = 0; fberr_armed = 0;
		for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
		prog_fd = $fopen(prog_file, "r");
		if (prog_fd == 0) begin
			$display("FATAL: cannot open program image %0s -- nothing to test", prog_file);
			$fatal(1);
		end
		$fclose(prog_fd);
		$readmemh(prog_file, mem);
		mem[15'h78B0] = 16'h0007;
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
			$display("FAIL: phase %0d timeout, pc=%h, last test number %0d", ph, dbg_pc, mem[15'h7880]);
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
	$display("tb_ap040_pipe_program: running %0s", prog_file);
	run_phase(0);
	run_phase(1);
	run_phase(2);
	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
