// Full WinUAE cputest v20 corpus replay driver.
//
// replay_gen.py expands one compressed corpus slice into APR2 records.  Each
// record runs on the real AP040 core through its 16-bit compatibility port;
// no instruction behavior is modeled here.  The driver loads the corpus'
// lmem/tmem images, injects complete integer/FPU state at a stalled initial
// fetch, supplies Amiga IPL levels, captures exception entry before stacking
// mutates A7/SR, and checks registers, FP state, memory writes and exception
// frames.  Trace vector 9 executes a real RTE so trace-plus-primary cases can
// complete.  Odd-vector groups receive the header's deliberately odd vector.
`timescale 1ns/1ns

module tb_dat_replay;

// Corpus geometry is a property of the DATA, not of this bench: v20 data
// puts test memory at $4200_0000/640K, v24 at $4380_0000/2M.  Both are
// taken from the APR2 job header at startup; TMEM_MAX only has to bound
// the largest corpus we accept.
localparam [31:0] TMEM_MAX = 32'h0020_0000;
reg [31:0] TBASE;
reg [31:0] TSIZE;
localparam [31:0] CAPV  = 32'h4210_0000;
localparam [31:0] CAPH  = 32'h4211_0000;
localparam [31:0] RND2  = 32'h524E4432;
localparam [7:0]  S_EXC0 = 8'd34;
localparam [7:0]  S_EXC_JMP = 8'd42;

localparam [31:0] F_FPU          = 32'h0000_0001;
localparam [31:0] F_IGNORE_EXC   = 32'h0000_0002;
localparam [31:0] F_TRACE_STACK  = 32'h0000_0004;
localparam [31:0] F_TRACE_ALONE  = 32'h0000_0008;
localparam [31:0] F_CHECK_FPIAR  = 32'h0000_0020;
// One-cycle corpus memory makes 10,000 clocks extremely conservative even
// for the iterative divide/square-root paths, while avoiding minutes spent
// repeating an already proven core hang.
localparam integer EXEC_TIMEOUT = 10000;

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
wire [255:0] debug_status;

reg         mem_ready;
reg         hold_fetch;
reg         boot_overlay;
reg         round_active;
reg  [2:0]  ipl;
reg  [31:0] cur_pc;
reg  [31:0] boot_msp;
reg  [31:0] boot_pc;
reg  [31:0] odd_vector;
wire        clkena_in = (busstate == 2'b01) | mem_ready;

ap040_tg68k_compat dut
(
	.clk(clk), .nreset(nreset), .cache_allow_all(1'b1),
	.cache_snoop_stb(1'b0), .cache_snoop_addr(32'd0),
	.cache_z2_ena(1'b0),
	.cache_z3_base0(5'd0),
	.cache_z3_ena0(1'b0),
	.cache_z3_base1(4'd0),
	.cache_z3_ena1(1'b0),
	.clkena_in(clkena_in),
	.data_in(data_in), .ipl(ipl), .ipl_autovector(1'b1), .berr(1'b0),
	.addr_out(addr_out), .data_write(data_write),
	.nwr(nwr), .nuds(nuds), .nlds(nlds),
	.busstate(busstate), .longword(longword), .nresetout(nresetout),
	.fc(fc),
	.mmu_addr_log(), .mmu_addr_phys(), .mmu_cache_inhibit(),
	.walker_req(), .walker_we(), .walker_addr(), .walker_wdat(),
	.walker_ack(1'b0), .walker_data(32'd0), .walker_berr(1'b0),
	.cache_req(), .cache_addr(), .cache_data(16'd0), .cache_ack(1'b0),
	.cache_burst(), .cache_burst_len(), .cache_ramaddr(),
	.cacr_out(cacr_out), .vbr_out(vbr_out),
	.debug_busy(), .debug_fault(), .debug_halted(),
	.debug_status(debug_status)
);

wire [31:0] dbg_pc = debug_status[31:0];

//--------------------------------------------------------------------------
// Corpus memory and synthetic reset/vector/handler overlays
//--------------------------------------------------------------------------

reg [7:0] lmem [0:32767];
reg [7:0] tmem [0:TMEM_MAX-1];

wire in_low  = (addr_out[31:15] == 0);
wire in_test = (addr_out >= TBASE) && (addr_out < TBASE + TSIZE);
wire in_vec  = (addr_out >= CAPV) && (addr_out < CAPV + 32'h100);
wire in_hand = (addr_out >= CAPH) && (addr_out < CAPH + 32'h400);
wire [31:0] toff = addr_out - TBASE;

function [7:0] be_byte;
	input [31:0] value;
	input [1:0] lane;
	begin
		case (lane)
			2'd0: be_byte = value[31:24];
			2'd1: be_byte = value[23:16];
			2'd2: be_byte = value[15:8];
			default: be_byte = value[7:0];
		endcase
	end
endfunction

function [7:0] rd8;
	input [31:0] a;
	reg [7:0] vec;
	reg [31:0] vv, hoff;
	begin
		if (boot_overlay && a < 8)
			rd8 = be_byte(a < 4 ? boot_msp : boot_pc, a[1:0]);
		else if (a[31:15] == 0)
			rd8 = lmem[a[14:0]];
		else if (a >= TBASE && a < TBASE + TSIZE)
			rd8 = tmem[a - TBASE];
		else if (a >= CAPV && a < CAPV + 32'h100) begin
			vec = (a - CAPV) >> 2;
			vv = (odd_vector != 0 && vec >= 4) ? odd_vector
			     : CAPH + {21'd0, vec, 3'd0};
			rd8 = be_byte(vv, a[1:0]);
		end else if (a >= CAPH && a < CAPH + 32'h400) begin
			hoff = a - CAPH;
			// Vector 9's handler is RTE; all other slots are harmless NOPs.
			if (hoff[8:3] == 9 && hoff[2:0] == 0) rd8 = 8'h4e;
			else if (hoff[8:3] == 9 && hoff[2:0] == 1) rd8 = 8'h73;
			else if (!hoff[0]) rd8 = 8'h4e;
			else rd8 = 8'h71;
		end else
			rd8 = 8'h00;
	end
endfunction

// The native runner asserts INTREQ before its entry RTE.  On the recorded
// 68040, an unmasked interrupt can therefore win before a user-mode
// privileged opcode reaches execution.  Direct state injection omits that
// RTE boundary, so identify the privileged encodings used by the IRQ corpus
// and let the already-held first fetch behave as the post-RTE handler refill.
function initial_privileged;
	input [15:0] op;
	begin
		initial_privileged =
			(op == 16'h007c) ||                         // ORI to SR
			(op == 16'h027c) ||                         // ANDI to SR
			(op == 16'h0a7c) ||                         // EORI to SR
			((op & 16'hffc0) == 16'h40c0) ||            // MOVE from SR
			((op & 16'hffc0) == 16'h46c0) ||            // MOVE to SR
			((op & 16'hfff0) == 16'h4e60) ||            // MOVE USP
			(op == 16'h4e70) || (op == 16'h4e72) ||     // RESET, STOP
			(op == 16'h4e73) ||                         // RTE
			(op == 16'h4e7a) || (op == 16'h4e7b) ||     // MOVEC
			((op & 16'hff00) == 16'h0e00);              // MOVES
	end
endfunction

assign data_in = {rd8({addr_out[31:1], 1'b0}),
	              rd8({addr_out[31:1], 1'b1})};

// declared before first use: the write monitor below references them, the
// driver blocks assign them (iverilog requires declaration before use)
reg [31:0] patch_addr;
integer jf, jn, jr;
reg [31:0] flags, test_idx, round_idx;

always @(posedge clk) begin
	if (nreset && mem_ready && busstate == 2'b11) begin
		if ($test$plusargs("patchhistory") &&
		    addr_out < patch_addr + 4 && addr_out + 2 > patch_addr)
			$display("PATCHHIST j%0d t%0d r%0d cpuwrite addr=%08x data=%04x uds=%b lds=%b",
			         jr, test_idx, round_idx, addr_out, data_write, nuds, nlds);
		if (!nuds) begin
			if (in_low)  lmem[{addr_out[14:1], 1'b0}] <= data_write[15:8];
			if (in_test) tmem[{toff[20:1], 1'b0}] <= data_write[15:8];
		end
		if (!nlds) begin
			if (in_low)  lmem[{addr_out[14:1], 1'b1}] <= data_write[7:0];
			if (in_test) tmem[{toff[20:1], 1'b1}] <= data_write[7:0];
		end
	end
end

always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && busstate != 2'b01 && !mem_ready) begin
		if (!(hold_fetch && busstate == 2'b00 && addr_out == cur_pc))
			mem_ready <= 1;
	end
end

//--------------------------------------------------------------------------
// Exception-entry snapshot.  S_EXC0 is visible for one cycle before the
// core changes SR or decrements the active supervisor stack.  SR and the
// FPU state are sampled on that entry cycle; the integer register file is
// sampled one cycle later because a register write issued by the faulting
// state (rf_we set in the same cycle as the S_EXC0 transition) only lands
// in the regfile on the following edge -- sampling at entry reads the
// pre-write value and hides an architecturally committed update (the AE
// RTR odd-return-PC A7 corruption escaped exactly this way).
//--------------------------------------------------------------------------

reg exc_seen;
reg cap_pend;
reg cap_pend2;
reg [7:0] cap_vec;
reg [7:0] latest_exc_vec;
reg [31:0] cap_regs [0:15];
reg [15:0] cap_sr;
reg [31:0] cap_sp;
reg [15:0] cap_fe [0:7];
reg [63:0] cap_fm [0:7];
reg [31:0] cap_fpcr, cap_fpsr, cap_fpiar;
reg [7:0] expected_exc_live;
reg [7:0] e_trace;
integer ci;

always @(posedge clk) begin
	if (!round_active) begin
		exc_seen <= 0;
		cap_pend <= 0;
		cap_pend2 <= 0;
	end else begin
		// Deferred integer-register sample: TWO qualified cycles after
		// S_EXC0 entry.  A write issued by the faulting state has rf_we
		// high during the first of those cycles and only reaches the
		// register file on the edge that ENDS it, so sampling any earlier
		// reads the pre-write value and reports an architecturally
		// committed update as missing.  The wait must also be on
		// clkena_in rather than the raw clock, because the register file
		// only commits on qualified edges.
		if (cap_pend && clkena_in) begin
			cap_pend <= 0;
			cap_pend2 <= 1;
		end
		else if (cap_pend2 && clkena_in) begin
			cap_pend2 <= 0;
			for (ci = 0; ci < 8; ci = ci + 1) begin
				cap_regs[ci] <= dut.core.regfile.dreg[ci];
				cap_regs[8+ci] <= (ci == 7) ? dut.core.regfile.usp
				                                : dut.core.regfile.areg[ci];
			end
		end
		if (dut.core.state != S_EXC0)
			exc_seen <= 0;
		if (dut.core.state == S_EXC0 && !exc_seen) begin
			exc_seen <= 1;
			latest_exc_vec <= dut.core.exc_vec;
			// A trace handler executes RTE and is not the native runner's
			// final register snapshot.  Preserve an already captured primary
			// exception while vector 9 temporarily runs.
			// A standalone trace is itself the final architectural
			// completion point, so snapshot it.  A trace stacked on a
			// primary exception instead executes the synthetic RTE below and
			// must not replace the primary snapshot.
			if (dut.core.exc_vec != 9 || expected_exc_live == 9 || e_trace == 2) begin
				cap_vec <= dut.core.exc_vec;
				for (ci = 0; ci < 8; ci = ci + 1) begin
					cap_fe[ci] <= {dut.core.g_fpu.fpu.fr_s[ci],
					               dut.core.g_fpu.fpu.fr_e[ci]};
					cap_fm[ci] <= dut.core.g_fpu.fpu.fr_m[ci];
				end
				cap_sr <= dut.core.sr;
				cap_fpcr <= dut.core.g_fpu.fpu.fpcr;
				cap_fpsr <= dut.core.g_fpu.fpu.fpsr;
				cap_fpiar <= dut.core.g_fpu.fpu.fpiar;
				cap_pend <= 1;
			end
			// The v20 68020+ generator samples interrupts after the tested
			// instruction.  If that instruction first raises a synchronous
			// exception (privileged ANDSR/STOP are the common cases), the
			// pending IRQ preempts its handler.  Keep IPL asserted through those
			// intermediate entries and release it only after the core has
			// actually accepted the IRQ.  This also avoids retriggering after
			// the final handler's RTE.
			if (dut.core.exc_is_irq)
				ipl <= 3'b111;
		end
	end
end

//--------------------------------------------------------------------------
// APR2 input
//--------------------------------------------------------------------------

// The public annotations are not for an external API.  They prevent
// They stop constant folding of the final summary across run_round's timed
// coroutine; otherwise comparisons execute and print, but the final block
// can incorrectly report literal zeroes in a native-code simulation.
integer errors /* verilator public_flat_rw */;
integer ran    /* verilator public_flat_rw */;
integer mism   /* verilator public_flat_rw */;
integer report_lim, timeout;
integer trace_round;
reg [31:0] round_fpu_ea;
reg        round_fpu_ea_valid;
integer k, n, p, fgot;
integer lmfd, tmfd;
reg [2047:0] job_file, lmem_file, tmem_file;

function [7:0] jread8;
	input integer dummy;
	integer r;
	begin
		r = $fgetc(jf);
		if (r < 0) begin $display("FAIL: unexpected EOF"); $finish; end
		jread8 = r[7:0];
	end
endfunction
function [15:0] jread16;
	input integer dummy;
	begin jread16 = {jread8(0), jread8(0)}; end
endfunction
function [31:0] jread32;
	input integer dummy;
	begin jread32 = {jread16(0), jread16(0)}; end
endfunction

// Preserve the operand EA at FPU dispatch.  By the time check_final runs,
// t_a may already have been reused by the terminal ILLEGAL exception.
always @(posedge clk) begin
	if (!round_active) begin
		round_fpu_ea <= 32'hFFFF_FFFF;
		round_fpu_ea_valid <= 0;
	end
	else if (!round_fpu_ea_valid && dut.core.fp_ea_v) begin
		round_fpu_ea <= dut.core.t_a;
		round_fpu_ea_valid <= 1;
	end
	else if (!round_fpu_ea_valid && dut.core.fpu_req) begin
		// Register-direct FPU operations do not set fp_ea_v.  t_a is only
		// diagnostic in that case; first_mismatch_memory_ea marks it false.
		round_fpu_ea <= dut.core.t_a;
		round_fpu_ea_valid <= 1;
	end
end

reg [31:0] i_regs [0:15];
reg [15:0] i_fe [0:7];
reg [63:0] i_fm [0:7];
reg [31:0] i_sr, i_pc, i_ssp, i_msp, i_fpcr, i_fpsr, i_fpiar;
reg [31:0] e_regs [0:15];
reg [15:0] e_fe [0:7];
reg [63:0] e_fm [0:7];
reg [31:0] e_sr, e_srmask, e_fpcr, e_fpsr, e_fpiar, e_pc;
reg [7:0] e_exc, e_group2, i_level;
reg [15:0] e_trace_sr, e_trace_srmask;
reg [31:0] e_trace_pc;

reg [7:0] frame_b [0:255];
reg [7:0] frame_m [0:255];
integer frame_len;

reg [31:0] em_a [0:255];
reg [7:0] em_sz [0:255];
reg [31:0] em_v [0:255];
reg [31:0] em_old [0:255];
integer em_cnt;

reg [31:0] post_a [0:255];
reg [15:0] post_n [0:255];
reg [15:0] post_off [0:255];
reg [7:0] post_b [0:8191];
integer post_cnt, post_bytes;
reg [31:0] clean_a [0:255];
reg [15:0] clean_n [0:255];
reg [15:0] clean_off [0:255];
reg [7:0] clean_b [0:8191];
integer clean_cnt, clean_bytes;

task write_byte;
	input [31:0] a;
	input [7:0] v;
	begin
		if (a[31:15] == 0) lmem[a[14:0]] = v;
		else if (a >= TBASE && a < TBASE + TSIZE) tmem[a-TBASE] = v;
		else begin
			$display("HARNESS: patch outside corpus memory: %08x", a);
			errors = errors + 1;
		end
	end
endtask

task apply_value;
	input [31:0] a;
	input [7:0] sz;
	input [31:0] v;
	integer nb, bi;
	begin
		nb = (sz == 0) ? 1 : (sz == 1) ? 2 : 4;
		for (bi = 0; bi < nb; bi = bi + 1)
			write_byte(a + bi, v >> (8 * (nb - 1 - bi)));
	end
endtask

function [31:0] read_value;
	input [31:0] a;
	input [7:0] sz;
	begin
		if (sz == 0) read_value = {24'd0, rd8(a)};
		else if (sz == 1) read_value = {16'd0, rd8(a), rd8(a+1)};
		else read_value = {rd8(a), rd8(a+1), rd8(a+2), rd8(a+3)};
	end
endfunction

task read_apply_patches;
	integer pcnt, pi, pj, plen;
	reg [31:0] pa;
	begin
		pcnt = jread16(0);
		if (jr == trace_round) $display("PREPATCH count=%0d", pcnt);
		for (pi = 0; pi < pcnt; pi = pi + 1) begin
			pa = jread32(0); plen = jread16(0);
			if ($test$plusargs("patchhistory") &&
			    pa < patch_addr + 4 && pa + plen > patch_addr)
				$display("PATCHHIST j%0d t%0d pre addr=%08x len=%0d old0=%08x",
				         jr, test_idx, pa, plen, read_value(patch_addr, 2));
			if (jr == trace_round) $display("PREPATCH item=%0d addr=%08x len=%0d", pi, pa, plen);
			for (pj = 0; pj < plen; pj = pj + 1) begin
				write_byte(pa + pj, jread8(0));
				if (jr == trace_round)
					$display("PREPATCH byte addr=%08x data=%02x", pa + pj,
						         rd8(pa + pj));
			end
			if ($test$plusargs("patchhistory") &&
			    pa < patch_addr + 4 && pa + plen > patch_addr)
				$display("PATCHHIST j%0d t%0d pre new0=%08x",
				         jr, test_idx, read_value(patch_addr, 2));
		end
	end
endtask

task read_post_patches;
	integer pi, pj;
	begin
		post_cnt = jread16(0); post_bytes = 0;
		for (pi = 0; pi < post_cnt; pi = pi + 1) begin
			post_a[pi] = jread32(0); post_n[pi] = jread16(0);
			post_off[pi] = post_bytes;
			for (pj = 0; pj < post_n[pi]; pj = pj + 1) begin
				if (post_bytes >= 8192) begin $display("FAIL: post patch overflow"); $finish; end
				post_b[post_bytes] = jread8(0); post_bytes = post_bytes + 1;
			end
		end
	end
endtask

task read_clean_patches;
	integer pi, pj;
	begin
		clean_cnt = jread16(0); clean_bytes = 0;
		if (jr == trace_round) $display("CLEANPATCH count=%0d", clean_cnt);
		for (pi = 0; pi < clean_cnt; pi = pi + 1) begin
			clean_a[pi] = jread32(0); clean_n[pi] = jread16(0);
			if (jr == trace_round) $display("CLEANPATCH item=%0d addr=%08x len=%0d", pi, clean_a[pi], clean_n[pi]);
			clean_off[pi] = clean_bytes;
			for (pj = 0; pj < clean_n[pi]; pj = pj + 1) begin
				if (clean_bytes >= 8192) begin $display("FAIL: cleanup patch overflow"); $finish; end
				clean_b[clean_bytes] = jread8(0); clean_bytes = clean_bytes + 1;
			end
			if (jr == trace_round)
				$display("CLEANPATCH data=%02x%02x%02x%02x", clean_b[clean_off[pi]],
				         clean_b[clean_off[pi]+1], clean_b[clean_off[pi]+2],
				         clean_b[clean_off[pi]+3]);
		end
	end
endtask

task apply_deferred;
	integer pi, pj;
	begin
		for (pi = 0; pi < post_cnt; pi = pi + 1) begin
			if ($test$plusargs("patchhistory") && post_a[pi] < patch_addr + 4 &&
			    post_a[pi] + post_n[pi] > patch_addr)
				$display("PATCHHIST j%0d t%0d post addr=%08x len=%0d old0=%08x",
				         jr, test_idx, post_a[pi], post_n[pi],
				         read_value(patch_addr, 2));
			for (pj = 0; pj < post_n[pi]; pj = pj + 1)
				write_byte(post_a[pi] + pj, post_b[post_off[pi] + pj]);
			if ($test$plusargs("patchhistory") && post_a[pi] < patch_addr + 4 &&
			    post_a[pi] + post_n[pi] > patch_addr)
				$display("PATCHHIST j%0d t%0d post new0=%08x",
				         jr, test_idx, read_value(patch_addr, 2));
		end
			for (pi = 0; pi < clean_cnt; pi = pi + 1) begin
				if ($test$plusargs("patchhistory") && clean_a[pi] < patch_addr + 4 &&
				    clean_a[pi] + clean_n[pi] > patch_addr)
					$display("PATCHHIST j%0d t%0d clean addr=%08x len=%0d old0=%08x",
					         jr, test_idx, clean_a[pi], clean_n[pi],
					         read_value(patch_addr, 2));
				for (pj = 0; pj < clean_n[pi]; pj = pj + 1)
					write_byte(clean_a[pi] + pj, clean_b[clean_off[pi] + pj]);
				if ($test$plusargs("patchhistory") && clean_a[pi] < patch_addr + 4 &&
				    clean_a[pi] + clean_n[pi] > patch_addr)
					$display("PATCHHIST j%0d t%0d clean new0=%08x",
					         jr, test_idx, read_value(patch_addr, 2));
			end
	end
endtask

task mismatch;
	input [8*20:1] what;
	input [31:0] exp;
	input [31:0] got;
	begin
		mism = mism + 1;
		if (mism <= report_lim)
			// Keep the tested instruction and final EA beside every mismatch.
			// This is especially important for the v20 FPU corpus: a small
			// number of memory-source oracles depend on generator-side memory
			// writes which were never serialized.  The opcode/EA make those
			// cases distinguishable from register-source arithmetic defects
			// without rerunning the whole slice with +trace_round.
			$display("MISMATCH j%0d t%0d r%0d %0s: expected %08x got %08x (pc=%h op=%02x%02x%02x%02x%02x%02x ea=%08x)",
			         jr, test_idx, round_idx, what, exp, got, dbg_pc,
			         rd8(i_pc + 0), rd8(i_pc + 1), rd8(i_pc + 2),
			         rd8(i_pc + 3), rd8(i_pc + 4), rd8(i_pc + 5),
			         round_fpu_ea);
	end
endtask

task check_trace_frame;
	reg [31:0] sp, pcv;
	reg [15:0] srv;
	begin
		sp = dut.core.dbg_a7;
		srv = read_value(sp, 1);
		pcv = read_value(sp + 2, 2);
		if (e_trace == 2) begin
			// The corpus SR restore record carries its ignored-bit mask in the
			// upper word.  WinUAE applies the same mask when checking a
			// standalone trace frame, so do not reject unspecified CCR bits.
			if (((srv ^ e_trace_sr) & e_trace_srmask) != 0) begin
				if (mism < report_lim)
					$display("  trace SR mask=%04x final SR mask=%04x", e_trace_srmask,
					         e_srmask[15:0]);
				mismatch("trace SR", e_trace_sr, srv);
			end
			if (pcv !== e_trace_pc) mismatch("trace PC", e_trace_pc, pcv);
		end
	end
endtask

task check_final;
	integer fi;
	reg [31:0] sp;
	begin
		if (!(flags & F_IGNORE_EXC) && cap_vec !== e_exc)
			mismatch("exception", e_exc, cap_vec);
		for (fi = 0; fi < 16; fi = fi + 1)
			if (cap_regs[fi] !== e_regs[fi])
				mismatch(fi < 8 ? "D register" : "A register",
				         e_regs[fi], cap_regs[fi]);
		if (((cap_sr ^ e_sr[15:0]) & e_srmask[15:0]) != 0)
			mismatch("SR", e_sr, cap_sr);
		if (flags & F_FPU) begin
			for (fi = 0; fi < 8; fi = fi + 1) begin
				if (cap_fe[fi] !== e_fe[fi]) mismatch("FP sign/exp", e_fe[fi], cap_fe[fi]);
				if (cap_fm[fi][63:32] !== e_fm[fi][63:32])
					mismatch("FP mantissa hi", e_fm[fi][63:32], cap_fm[fi][63:32]);
				if (cap_fm[fi][31:0] !== e_fm[fi][31:0])
					mismatch("FP mantissa lo", e_fm[fi][31:0], cap_fm[fi][31:0]);
			end
			if (cap_fpcr !== e_fpcr) mismatch("FPCR", e_fpcr, cap_fpcr);
			if (cap_fpsr !== e_fpsr) mismatch("FPSR", e_fpsr, cap_fpsr);
			// Native cputest only validates FPIAR when the result stream names it,
			// or when execution changed it from the injected input value.
			if ((flags & F_CHECK_FPIAR) || cap_fpiar !== i_fpiar)
				if (cap_fpiar !== e_fpiar) mismatch("FPIAR", e_fpiar, cap_fpiar);
		end

		sp = cap_sp;
		if (frame_len != 0) begin
			if (jr == trace_round)
				$display("FRAME len=%0d exp=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x got=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
				         frame_len, frame_b[0], frame_b[1], frame_b[2], frame_b[3],
				         frame_b[4], frame_b[5], frame_b[6], frame_b[7], frame_b[8],
				         frame_b[9], frame_b[10], frame_b[11], rd8(sp+0), rd8(sp+1),
				         rd8(sp+2), rd8(sp+3), rd8(sp+4), rd8(sp+5), rd8(sp+6),
				         rd8(sp+7), rd8(sp+8), rd8(sp+9), rd8(sp+10), rd8(sp+11));
			for (fi = 0; fi < frame_len; fi = fi + 1)
				if (((rd8(sp + fi) ^ frame_b[fi]) & frame_m[fi]) != 0) begin
					if (mism < report_lim)
						$display("  frame byte %0d at %08x mask=%02x", fi, sp+fi, frame_m[fi]);
					mismatch("exception frame", frame_b[fi], rd8(sp + fi));
				end
		end else if (!(flags & F_IGNORE_EXC) && e_exc == 4) begin
			if (read_value(sp + 2, 2) !== e_pc)
				mismatch("end PC", e_pc, read_value(sp + 2, 2));
		end

		for (fi = 0; fi < em_cnt; fi = fi + 1) begin
			if (read_value(em_a[fi], em_sz[fi]) !== em_v[fi]) begin
				if (jr == trace_round)
					$display("MEMCHECK idx=%0d addr=%08x sz=%0d exp=%08x got=%08x old=%08x",
					         fi, em_a[fi], em_sz[fi], em_v[fi],
					         read_value(em_a[fi], em_sz[fi]), em_old[fi]);
				mismatch("memory write", em_v[fi], read_value(em_a[fi], em_sz[fi]));
			end
			if ($test$plusargs("patchhistory") && em_a[fi] < patch_addr + 4 &&
			    em_a[fi] + (1 << em_sz[fi]) > patch_addr)
				$display("PATCHHIST j%0d t%0d memrestore addr=%08x old0=%08x value=%08x",
				         jr, test_idx, em_a[fi], read_value(patch_addr, 2), em_old[fi]);
			apply_value(em_a[fi], em_sz[fi], em_old[fi]);
			if ($test$plusargs("patchhistory") && em_a[fi] < patch_addr + 4 &&
			    em_a[fi] + (1 << em_sz[fi]) > patch_addr)
				$display("PATCHHIST j%0d t%0d memrestore new0=%08x",
				         jr, test_idx, read_value(patch_addr, 2));
		end
	end
endtask

task inject_state;
	integer ii;
	begin
		// The native 68020+ runner enters every test through a format-$0 RTE.
		// Before supervisor-mode rounds it copies up to 32 bytes from the
		// serialized A7 image (the corpus' canonical test stack) to the ISP
		// that becomes active after that entry RTE.  Direct register injection
		// must reproduce that otherwise RTE/RTR and stack-EA tests read the
		// exception runner's scratch stack instead of the corpus input frame.
		if (i_sr[13]) begin
			for (ii = 0; ii < 32; ii = ii + 1)
				write_byte(i_ssp + ii, rd8(i_regs[15] + ii));
		end
		for (ii = 0; ii < 8; ii = ii + 1) begin
			dut.core.regfile.dreg[ii] = i_regs[ii];
			if (ii < 7) dut.core.regfile.areg[ii] = i_regs[8+ii];
			dut.core.g_fpu.fpu.fr_s[ii] = i_fe[ii][15];
			dut.core.g_fpu.fpu.fr_e[ii] = i_fe[ii][14:0];
			dut.core.g_fpu.fpu.fr_m[ii] = i_fm[ii];
		end
		dut.core.regfile.usp = i_regs[15];
		dut.core.regfile.isp = i_ssp;
		dut.core.regfile.msp = i_msp;
		dut.core.sr = i_sr[15:0];
		dut.core.tr_t1 = i_sr[15];
		dut.core.tr_t0 = i_sr[14];
		dut.core.t0_force = 0;
		dut.core.vbr = CAPV;
		dut.core.cacr = 0;
		dut.core.sfc = 0; dut.core.dfc = 0;
		dut.core.tc = 0; dut.core.itt0 = 0; dut.core.itt1 = 0;
		dut.core.dtt0 = 0; dut.core.dtt1 = 0;
			dut.core.mmusr = 0; dut.core.urp = 0; dut.core.srp = 0;
			dut.core.epf_count = 0; dut.core.epf_armed = 0;
			// Direct state injection replaces the native runner's completed entry
			// RTE.  Reset refill left this asserted, which made a pending corpus
			// IRQ preempt the held test opcode as though it were the first opcode
			// of an exception handler.  The tested instruction must reach its
			// normal boundary before that IRQ is sampled.
			dut.core.in_exc = 0;
			for (ii = 0; ii < 128; ii = ii + 1) dut.mmu.atc_v[ii] = 0;
		dut.core.g_fpu.fpu.fpcr = i_fpcr;
		dut.core.g_fpu.fpu.fpsr = i_fpsr;
		dut.core.g_fpu.fpu.fpiar = i_fpiar;
	end
endtask

task run_round;
	integer vec, saw_primary, saw_trace, trace_bits, primary_vec;
	integer primary_frame_done;
	reg [31:0] ha;
	begin
		boot_msp = i_msp; boot_pc = i_pc;
		cur_pc = i_pc;
		hold_fetch = 1; boot_overlay = 1; round_active = 0;
		cap_vec = 8'hff; latest_exc_vec = 8'hff;
		ipl = ~i_level[2:0];
		nreset = 0;
		repeat (6) @(posedge clk);
		nreset = 1;

		timeout = 0;
		while (!(busstate == 2'b00 && addr_out == i_pc) && timeout < 4000) begin
			@(posedge clk); timeout = timeout + 1;
		end
		if (timeout >= 4000) begin
			$display("FAIL j%0d t%0d r%0d: start-fetch timeout, pc=%h", jr, test_idx, round_idx, dbg_pc);
			errors = errors + 1;
			disable run_round;
		end
		inject_state;
		if (i_level != 0 && !i_sr[13] &&
		    expected_exc_live >= 25 && expected_exc_live <= 31 &&
		    initial_privileged({rd8(i_pc), rd8(i_pc + 1)}))
			dut.core.in_exc = 1;
		boot_overlay = 0;
		round_active = 1;
		if ($test$plusargs("traceevents"))
			$display("ENTRY t%0d r%0d pins=%x irq=%0d s1=%x s2=%x pend=%0d in_exc=%0d",
			         test_idx, round_idx, ipl, dut.core.irq_lvl,
			         dut.core.ipl_s1, dut.core.ipl_s2, dut.core.irq_pend,
			         dut.core.in_exc);
		@(posedge clk);
		hold_fetch = 0;

		saw_primary = 0; saw_trace = 0; primary_vec = -1;
		primary_frame_done = 0; timeout = 0;
		// A tested instruction can set T1/T0 even when its input SR had both
		// clear (EOR/OR/MOVE to SR are the common corpus cases).  The native
		// runner services the resulting trace after its filler instruction,
		// executes RTE, and only then reaches the terminal ILLEGAL.  Include
		// the oracle SR here so that replay follows that intermediate vector 9
		// instead of mistaking its handler entry for the final result.
		trace_bits = (i_sr[15:14] != 0) || (e_sr[15:14] != 0);
			while (timeout < EXEC_TIMEOUT) begin
				@(posedge clk); timeout = timeout + 1;
				// Corpus v20 does not serialize a surviving 68040 T0 trace
				// after a primary instruction exception (notably the complete
				// A-line opcode space).  Validate the recorded primary frame at
				// its completion boundary instead of following an unrepresented
				// second exception into the synthetic handler page.  Dedicated
				// trace tests retain the full stacked-trace oracle via e_trace.
				if (e_trace == 0 && trace_bits && e_exc != 0 && e_exc != 9 &&
				    latest_exc_vec == e_exc && dut.core.state == S_EXC_JMP) begin
					primary_frame_done = 1;
					timeout = EXEC_TIMEOUT;
				end
				// A zero-length vector-4 oracle is cputest's synthetic terminal
				// ILLEGAL, not an instruction exception under test.  T0 written by
				// the tested instruction can survive that ILLEGAL and redirect from
				// S_EXC_JMP into vector 9 before any handler fetch.  Stop once the
				// terminal frame itself is complete; cap_* already holds its S_EXC0
				// architectural snapshot and the following trace is out of scope.
				if (frame_len == 0 && e_exc == 4 && latest_exc_vec == 4 &&
				    dut.core.state == S_EXC_JMP) begin
					primary_frame_done = 1;
					timeout = EXEC_TIMEOUT;
				end
				// If a trace of the tested instruction returns directly into the
			// synthetic terminal ILLEGAL, the native runner records that primary
			// exception as soon as its frame exists.  Following a surviving T0
			// trace from ILLEGAL would merely re-enter our synthetic trace RTE
			// forever and is outside the tested instruction's result.
			if (saw_trace && e_exc != 9 && latest_exc_vec == e_exc &&
			    dut.core.state == S_EXC_JMP) begin
				primary_frame_done = 1;
				timeout = EXEC_TIMEOUT;
			end
			if (busstate == 2'b00 && in_hand && addr_out[2:0] == 3'b000) begin
				ha = addr_out - CAPH;
				vec = ha >> 3;
				// Sequential prefetch inside the synthetic handler page can
				// cross the next 8-byte slot before RTE executes.  It is not a
				// new exception entry; accept only the vector most recently
				// observed at S_EXC0, or the primary handler resumed after a
				// stacked trace RTE.
				if ((!saw_trace && vec == latest_exc_vec) ||
				    (saw_primary && saw_trace && vec == primary_vec) ||
				    (!saw_primary && saw_trace && latest_exc_vec != 9 &&
				     vec == latest_exc_vec)) begin
				if ($test$plusargs("traceevents"))
						$display("EVENT t%0d r%0d vec=%0d sp=%08x sr=%04x state=%0d ea=%08x mind=%08x idx=%08x ilvl=%0d irq=%0d s1=%x s2=%x pend=%0d",
						         test_idx, round_idx, vec, dut.core.dbg_a7,
						         dut.core.sr, dut.core.state, dut.core.t_a,
						         dut.core.ea_mind, dut.core.ea_idx_v, i_level,
						         dut.core.irq_lvl, dut.core.ipl_s1,
						         dut.core.ipl_s2, dut.core.irq_pend);
				if ($test$plusargs("traceevents") && dut.core.t_a < 32'h00008000)
					$display("EADATA %02x%02x%02x%02x %02x%02x%02x%02x %02x%02x%02x%02x",
					         rd8(dut.core.t_a + 0), rd8(dut.core.t_a + 1),
					         rd8(dut.core.t_a + 2), rd8(dut.core.t_a + 3),
					         rd8(dut.core.t_a + 4), rd8(dut.core.t_a + 5),
					         rd8(dut.core.t_a + 6), rd8(dut.core.t_a + 7),
					         rd8(dut.core.t_a + 8), rd8(dut.core.t_a + 9),
					         rd8(dut.core.t_a + 10), rd8(dut.core.t_a + 11));
				if (vec == 9 && (e_trace != 0 || trace_bits)) begin
					check_trace_frame;
					// T0 can redirect from the primary S_EXC_JMP directly into
					// trace without ever fetching the primary handler.  Its
					// S_EXC0 snapshot still identifies the handler resumed by RTE.
					if (!saw_primary && cap_vec != 8'hff && cap_vec != 9) begin
						saw_primary = 1;
						primary_vec = cap_vec;
					end
					saw_trace = 1;
					if (e_exc == 9) begin
						// The vector-9 entry IS the round's recorded result --
						// whenever the corpus says so, not only for the
						// standalone-trace encoding (e_trace == 2).  With T1
						// set the tested instruction traces and the corpus
						// records exception 9 with NO separate trace record
						// (e_trace == 0); treating that as a stacked trace let
						// the synthetic handler RTE on into the terminating
						// ILLEGAL, whose vector 4 then displaced the result --
						// "expected 9 got 4" across the whole Basic/Default
						// corpus.  Freeze here instead, so cap_sp still points
						// at the trace frame the comparison reads.
						timeout = EXEC_TIMEOUT;
					end else begin
						// Stacked trace: let RTE resume the primary handler.
						while (busstate == 2'b00 && addr_out == CAPH + vec*8) @(posedge clk);
					end
				end else if ((e_trace == 1 ||
				              (e_exc == 4 && trace_bits)) &&
				             !saw_primary && !saw_trace) begin
					// Primary handler entry is traced.  Allow the pending trace
					// to preempt its first instruction; the post-RTE entry is final.
					saw_primary = 1;
					primary_vec = vec;
					while (busstate == 2'b00 && addr_out == CAPH + vec*8) @(posedge clk);
				end else begin
					timeout = EXEC_TIMEOUT;
				end
				end
			end
		end
		if (!primary_frame_done && !(busstate == 2'b00 && in_hand)) begin
			$display("FAIL j%0d t%0d r%0d: execution timeout, pc=%h state=%0d",
			         jr, test_idx, round_idx, dbg_pc, dut.core.state);
			if (jr == trace_round)
				$display("BUSHANG creq=%b cack=%b miss=%b maddr=%h mwr=%b mst=%0d mreq=%b mack=%b cst=%0d breq=%b back=%b ast=%b abst=%0d",
				         dut.core.mem_req, dut.core.mem_ack, dut.core.m_issued,
				         dut.core.mem_addr, dut.core.mem_write,
				         dut.mmu.wst, dut.mmu.m_req, dut.mmu.m_ack,
				         dut.g_cache.cache.cst, dut.b_req, dut.b_ack,
				         dut.bus16.active, dut.bus16.busstate);
			errors = errors + 1;
			round_active = 0;
			disable run_round;
		end
		// Freeze the completed round before parsing/applying the next APR
		// record.  A trace-only result otherwise leaves the synthetic
		// vector-9 handler free to execute RTE and repeat the tested
		// instruction, leaking unrecorded writes into the next round.
		cap_sp = dut.core.dbg_a7;
		nreset = 0;
		if (e_trace != 0 && !saw_trace)
			mismatch("missing trace", 9, 0);
		#1;
		check_final;
		ran = ran + 1;
		round_active = 0;
		ipl = 3'b111;
	end
endtask

integer limit, start_record;
reg [31:0] job_version, job_tbase, job_tsize;
reg [31:0] toggle_a, toggle_v;
reg [7:0] toggle_kind;

initial begin
	mem_ready = 0; hold_fetch = 0; boot_overlay = 0; round_active = 0;
	ipl = 3'b111; nreset = 0; errors = 0; ran = 0; mism = 0;
	round_fpu_ea = 32'hFFFF_FFFF;
	round_fpu_ea_valid = 0;
	report_lim = 40;
	if (!$value$plusargs("trace_round=%d", trace_round)) trace_round = -1;
	if (!$value$plusargs("patchaddr=%h", patch_addr)) patch_addr = 0;
	for (k = 0; k < 32768; k = k + 1) lmem[k] = 0;
	for (k = 0; k < TMEM_MAX; k = k + 1) tmem[k] = 0;

	if (!$value$plusargs("job=%s", job_file) ||
	    !$value$plusargs("lmem=%s", lmem_file) ||
	    !$value$plusargs("tmem=%s", tmem_file)) begin
		$display("FAIL: require +job= +lmem= +tmem="); $finish;
	end
	if (!$value$plusargs("limit=%d", limit)) limit = 32'h7fffffff;
	if (!$value$plusargs("start=%d", start_record)) start_record = 0;
	jf = $fopen(job_file, "rb");
	if (!jf) begin $display("FAIL: cannot open APR2 job"); $finish; end
	if (jread32(0) !== "APR2") begin $display("FAIL: bad job magic"); $finish; end
	job_version = jread32(0); jn = jread32(0);
	job_tbase = jread32(0); job_tsize = jread32(0); odd_vector = jread32(0);
	if (job_version != 3 || job_tsize > TMEM_MAX) begin
		$display("FAIL: unsupported APR2 geometry/version"); $finish;
	end
	TBASE = job_tbase;
	TSIZE = job_tsize;
	$fclose(jf);

	lmfd = $fopen(lmem_file, "rb");
	tmfd = $fopen(tmem_file, "rb");
	if (!lmfd || !tmfd) begin $display("FAIL: cannot open corpus memory images"); $finish; end
	fgot = $fread(lmem, lmfd); $fclose(lmfd);
	fgot = $fread(tmem, tmfd); $fclose(tmfd);

	// re-open and re-read the header: the geometry was consumed above
	jf = $fopen(job_file, "rb");
	if (!jf) begin $display("FAIL: cannot open APR2 job"); $finish; end
	if (jread32(0) !== "APR2") begin $display("FAIL: bad job magic"); $finish; end
	job_version = jread32(0); jn = jread32(0);
	job_tbase = jread32(0); job_tsize = jread32(0); odd_vector = jread32(0);
	if (jn > limit) jn = limit;
	$display("tb_dat_replay: %0d APR2 records", jn);

	for (jr = 0; jr < jn; jr = jr + 1) begin
		if (jread32(0) !== RND2) begin $display("FAIL: record desync at %0d", jr); $finish; end
		test_idx = jread32(0); round_idx = jread32(0); flags = jread32(0);
		for (k = 0; k < 16; k = k + 1) i_regs[k] = jread32(0);
		i_sr = jread32(0); i_pc = jread32(0); i_ssp = jread32(0); i_msp = jread32(0);
		for (k = 0; k < 8; k = k + 1) begin
			i_fe[k] = jread32(0); i_fm[k] = {jread32(0), jread32(0)};
		end
		i_fpcr = jread32(0); i_fpsr = jread32(0); i_fpiar = jread32(0);
		i_level = jread8(0);
		read_apply_patches;
		n = jread16(0);
		for (k = 0; k < n; k = k + 1) begin
			toggle_a = jread32(0); toggle_kind = jread8(0);
			toggle_v = read_value(toggle_a, 2);
			if ($test$plusargs("patchhistory") && toggle_a < patch_addr + 4 &&
			    toggle_a + 4 > patch_addr)
				$display("PATCHHIST j%0d t%0d toggle addr=%08x kind=%0d old0=%08x",
				         jr, test_idx, toggle_a, toggle_kind,
				         read_value(patch_addr, 2));
			if (toggle_kind == 1)
				apply_value(toggle_a, 2, {toggle_v[15:0], toggle_v[31:16]});
			else if (toggle_kind == 2)
				apply_value(toggle_a, 1,
					toggle_v[31:16] == 16'h2048 ? 16'h4afc : 16'h2048);
			if ($test$plusargs("patchhistory") && toggle_a < patch_addr + 4 &&
			    toggle_a + 4 > patch_addr)
				$display("PATCHHIST j%0d t%0d toggle new0=%08x",
				         jr, test_idx, read_value(patch_addr, 2));
		end

		for (k = 0; k < 16; k = k + 1) e_regs[k] = jread32(0);
		e_sr = jread32(0); e_srmask = jread32(0);
		for (k = 0; k < 8; k = k + 1) begin
			e_fe[k] = jread32(0); e_fm[k] = {jread32(0), jread32(0)};
		end
		e_fpcr = jread32(0); e_fpsr = jread32(0); e_fpiar = jread32(0);
		e_exc = jread8(0); expected_exc_live = e_exc; e_pc = jread32(0);
		e_trace = jread8(0); e_group2 = jread8(0);
		e_trace_sr = jread16(0); e_trace_srmask = jread16(0);
		e_trace_pc = jread32(0);
		frame_len = jread16(0);
		for (k = 0; k < frame_len; k = k + 1) frame_b[k] = jread8(0);
		for (k = 0; k < frame_len; k = k + 1) frame_m[k] = jread8(0);
		em_cnt = jread16(0);
		for (k = 0; k < em_cnt; k = k + 1) begin
			em_a[k] = jread32(0); em_sz[k] = jread8(0);
			em_v[k] = jread32(0); em_old[k] = jread32(0);
		end
		read_post_patches;
		read_clean_patches;
		if (jr == trace_round)
				$display("ROUNDINFO t=%0d r=%0d flags=%08x isr=%04x ilvl=%0d iexc=%0d epc=%08x trace=%0d tracepc=%08x frame=%0d ifpcr=%08x ifpsr=%08x ifpiar=%08x efpcr=%08x efpsr=%08x efpiar=%08x op=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x end=%02x%02x%02x%02x d0=%08x d1=%08x d7=%08x a0=%08x a1=%08x a2=%08x a6=%08x a7=%08x zptr=%08x ifp3=%04x-%08x%08x efp3=%04x-%08x%08x",
				         test_idx, round_idx, flags, i_sr[15:0], i_level, e_exc, e_pc,
			         e_trace, e_trace_pc, frame_len, i_fpcr, i_fpsr, i_fpiar,
			         e_fpcr, e_fpsr, e_fpiar,
			         rd8(i_pc), rd8(i_pc + 1),
			         rd8(i_pc + 2), rd8(i_pc + 3), rd8(i_pc + 4), rd8(i_pc + 5),
			         rd8(i_pc + 6), rd8(i_pc + 7), rd8(i_pc + 8), rd8(i_pc + 9),
			         rd8(i_pc + 10), rd8(i_pc + 11), rd8(e_pc), rd8(e_pc + 1),
				         rd8(e_pc + 2), rd8(e_pc + 3), i_regs[0], i_regs[1],
				         i_regs[7], i_regs[8], i_regs[9], i_regs[10], i_regs[14],
					         i_regs[15], read_value(32'd0, 2), i_fe[3], i_fm[3][63:32],
				         i_fm[3][31:0], e_fe[3], e_fm[3][63:32], e_fm[3][31:0]);

		// CT_END exception marker 1 explicitly means that this round's
		// exception is not an architectural oracle.  replay_gen preserves it
		// in e_exc for diagnostics, so the flag -- not a synthetic $ff value --
		// is the authoritative skip indication.
		if ((flags & F_IGNORE_EXC) || jr < start_record) begin
			apply_deferred;
		end else begin
			run_round;
			apply_deferred;
		end
	end

	$display("dat replay: %0d rounds, %0d mismatches, %0d harness errors",
	         ran, mism, errors);
	if (mism == 0 && errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d errors", mism + errors);
	$finish;
end

// Focused request-handshake trace for a retained APR2 record.  Disabled in
// normal regressions; +trace_round=N prints the core/MMU/cache/adapter state
// only for that expanded record.
always @(posedge clk) begin
	if (round_active && jr == trace_round &&
	    (timeout < 200 || (timeout % 500) == 0))
		$display("BUSDBG n=%0d st=%0d pc=%h creq=%b cack=%b miss=%b mst=%0d mreq=%b mack=%b cst=%0d breq=%b back=%b ast=%b abst=%0d ba=%08x bsz=%0d bo=%08x di=%04x rs=%08x ca=%08x left=%0d",
		         timeout, dut.core.state, dbg_pc,
		         dut.core.mem_req, dut.core.mem_ack, dut.core.m_issued,
		         dut.mmu.wst, dut.mmu.m_req, dut.mmu.m_ack,
		         dut.g_cache.cache.cst, dut.b_req, dut.b_ack,
		         dut.bus16.active, dut.bus16.busstate, dut.b_addr, dut.b_size,
		         addr_out, data_in, dut.bus16.rshift, dut.bus16.cur_addr,
		         dut.bus16.bytes_left);
end

// Detect a genuinely wedged timed task, not merely a large corpus slice.
// Some slices legitimately exceed two simulated seconds because thousands
// of independently bounded instruction rounds take the execution-timeout
// path.  `jr` must nevertheless advance at least once per 200 ms.
integer watchdog_jr;
initial begin
	watchdog_jr = -1;
	forever begin
		#200_000_000;
		if (jr === watchdog_jr) begin
			$display("FAIL: no corpus progress watchdog at record %0d", jr);
			$finish;
		end
		watchdog_jr = jr;
	end
end

endmodule
