// WinUAE cputest corpus replay driver for the PIPELINED core.
//
// A companion to tb_dat_replay.v, which does the same job for rtl/ap040's
// sequential core. Everything about the corpus is shared with it verbatim --
// the APR2 record parsing, the low and test memory images, the patch and
// toggle streams, the value helpers -- because those describe the DATA, not
// the core. ap040_pipe_bus16.v drives the same sixteen-bit port the
// sequential core's compatibility top does, so the memory model is shared
// too.
//
// Three things differ, and two are absences. This core has no reset vector,
// so a round starts by writing the slice's address into the fetch stage
// rather than by letting the core fetch one; tb_ap040_pipe_inject.v
// established that it can be. It has no floating-point unit, no memory
// management unit, no caches and no interrupt path. And its register file is
// dreg/areg/usp/isp/msp rather than the sequential core's mirrored banks, so
// the injection and the readback are written against that.
//
// SCOPE, and the first measurement says it is too narrow to be useful yet:
// across the harness's six smoke slices, 0 of 323 rounds were judged. A
// cputest round ends in an exception by construction -- the generator closes
// every test with a terminal ILLEGAL -- so "no expected exception" excludes
// nearly everything. Following an exception to its frame is therefore not a
// later refinement but the thing that makes this driver worth running, and
// it is the next piece of work. A slice with nothing judged reports FAILED,
// not passed.
//
// SCOPE, narrow on purpose. A round is JUDGED only when its oracle is an
// instruction that completes normally: no expected exception, no trace, no
// interrupt level. Everything else is counted and skipped. FPU rounds are
// judged since 2026-09-24 (ap040_pipe_fpu.v), FP state as tb_dat_replay.v.
// Following an exception to its frame needs the equivalent of the sequential
// driver's state-machine watch and is the next piece of work; saying so in
// the summary is better than judging those rounds by accident.
//
// What a judged round checks is every integer register, the status register
// under the oracle's own mask, and every memory value the corpus recorded.
// A round that never reaches its expected PC is reported as that, separately
// from a value mismatch: for this core it usually means an opcode it does
// not implement, which is a real gap but a different one.
`timescale 1ns/1ns

module tb_dat_replay_pipe;

localparam [31:0] TMEM_MAX = 32'h0020_0000;
reg [31:0] TBASE;
reg [31:0] TSIZE;
localparam [31:0] CAPV  = 32'h4210_0000;
localparam [31:0] CAPH  = 32'h4211_0000;
localparam [31:0] RND2  = 32'h524E4432;
localparam [31:0] F_FPU        = 32'h0000_0001;
localparam [31:0] F_IGNORE_EXC = 32'h0000_0002;
localparam [31:0] F_CHECK_FPIAR = 32'h0000_0020;
localparam integer EXEC_TIMEOUT = 20000;

reg clk = 0;
reg nreset = 0;
reg ce = 0;
always #5 clk = ~clk;

wire [15:0] data_in;
wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds;
wire  [1:0] busstate;
wire        longword;
wire  [2:0] fc;
reg         mem_ready;
reg         boot_overlay;
reg  [31:0] odd_vector;
wire        clkena_in = (busstate == 2'b01) | mem_ready;

wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire [15:0] dbg_sr;
wire  [4:0] dbg_ccr;
wire [31:0] dbg_commits;
wire        dbg_if_valid, dbg_id_valid, dbg_eac_valid;
wire        dbg_eaf_valid, dbg_ex_valid, dbg_wb_valid;
wire [31:0] dbg_if_pc, dbg_id_pc, dbg_eac_pc, dbg_eaf_pc, dbg_ex_pc, dbg_wb_pc;

// PROG_WORDS is an instruction-issue budget for the short milestone
// programs and a corpus slice must never meet it. PC_RESET is irrelevant:
// every round writes its own start address into the fetch stage.
ap040_pipe_bus16 #(.PC_RESET(32'h0000_1000), .PROG_WORDS(32'h4000_0000)) dut
(
	.clk(clk), .nreset(nreset), .ce(ce), .clkena_in(clkena_in),
	.data_in(data_in),
	.addr_out(addr_out), .data_write(data_write),
	.nwr(nwr), .nuds(nuds), .nlds(nlds),
	.busstate(busstate), .longword(longword), .fc(fc),
	.dbg_if_valid (dbg_if_valid),  .dbg_if_pc (dbg_if_pc),
	.dbg_id_valid (dbg_id_valid),  .dbg_id_pc (dbg_id_pc),
	.dbg_eac_valid(dbg_eac_valid), .dbg_eac_pc(dbg_eac_pc),
	.dbg_eaf_valid(dbg_eaf_valid), .dbg_eaf_pc(dbg_eaf_pc),
	.dbg_ex_valid (dbg_ex_valid),  .dbg_ex_pc (dbg_ex_pc),
	.dbg_wb_valid (dbg_wb_valid),  .dbg_wb_pc (dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7),
	.dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr), .dbg_commits(dbg_commits)
);

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
			// Every vector from 4 up is odd, exactly as the native runner
			// builds its table (cputest/main.c: vbr[i] = exception_vectors
			// for i >= 4, and set_error_vectors() later touches only 2-3).
			// Vector 9 is therefore odd on hardware for the whole group.
			// Some rounds nevertheless record the trace as DELIVERED and
			// the terminal ILLEGAL's vector as the one that faults: that is
			// the generator storing a trace pending before the test's NOP
			// as a transparent handler (cputest.cpp "trace after NOP") and
			// running on -- an oracle no odd-vector-9 machine can produce.
			// Those rounds are classified below (trace_mode 2 under an odd
			// vector) and skipped with a count, not modelled.  Taking the
			// answer from the round's lmem vector table was tried and is
			// WRONG: the corpus does not plant those entries where this
			// would read them, and it drops ODD_EXC from 20/33 to 0/33.
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

assign data_in = {rd8({addr_out[31:1], 1'b0}),
	              rd8({addr_out[31:1], 1'b1})};

reg [31:0] patch_addr;
// rd8's synthetic reset/vector overlay reads these; this core fetches no
// reset vector, but the overlay is shared verbatim with the sequential
// driver so they are kept and set per round.
reg [31:0] boot_msp, boot_pc, cur_pc;
reg        hold_fetch, round_active;
// The post- and clean-patch streams, whose readers come over unchanged.
reg [31:0] post_a [0:255];
reg [15:0] post_n [0:255];
reg [15:0] post_off [0:255];
reg [7:0]  post_b [0:8191];
integer post_cnt, post_bytes;
reg [31:0] clean_a [0:255];
reg [15:0] clean_n [0:255];
reg [15:0] clean_off [0:255];
reg [7:0]  clean_b [0:8191];
integer clean_cnt, clean_bytes;
integer jf, jn, jr;
reg [31:0] flags, test_idx, round_idx;

// The corpus memory takes the core's writes, exactly as the sequential
// driver's does.
always @(posedge clk) begin
	if (nreset && round_active && trace_bus) begin
		if (dut.l1_wren_b)
			$display("  L1WR  addr=%08x data=%08x", dut.l1_addr_b, dut.l1_data_b);
		if (dut.mem_req)
			$display("  MEMRQ addr=%08x write=%b instr=%b ack=%b",
			         dut.mem_addr, dut.mem_write, dut.mem_instr, dut.mem_ack);
	end
	// +extrace: what EX computed, each cycle it holds a valid instruction.
	// A flag defect shows up here as the ALU's inputs, which the final-state
	// compare cannot show.
	if (nreset && round_active && trace_ex && ce && dut.u_cpu.u_ex.eaf_valid)
		$display("  EX    pc=%08x op=%0d sz=%0d a=%08x b=%08x ccr_in=%02x -> res=%08x flags=%02x wccr=%b sr=%04x",
		         dut.u_cpu.u_ex.eaf_pc, dut.u_cpu.u_ex.eaf_alu_op, dut.u_cpu.u_ex.eaf_size,
		         dut.u_cpu.u_ex.eaf_operand_a, dut.u_cpu.u_ex.eaf_operand_b,
		         dut.u_cpu.u_ex.ccr_in, dut.u_cpu.u_ex.alu_result, dut.u_cpu.u_ex.alu_flags,
		         dut.u_cpu.u_ex.eaf_writes_ccr, dut.u_cpu.sr);
	if (nreset && mem_ready && busstate == 2'b11 && trace_bus)
		$display("BUSWR addr=%08x data=%04x uds=%b lds=%b in_low=%b in_test=%b",
		         addr_out, data_write, !nuds, !nlds, in_low, in_test);
	if (nreset && mem_ready && busstate == 2'b11) begin
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

// One cycle per access. Nothing is held back: the pipelined core is held
// with ce while a round's state goes in, not by starving the bus -- except
// while a released FPU operation finishes (hold_bus, run_round), when the
// integer side must not move and the FPU needs no bus.
reg hold_bus = 1'b0;
always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && busstate != 2'b01 && !mem_ready && !hold_bus) mem_ready <= 1;
end

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
//--------------------------------------------------------------------------
// Record fields
//--------------------------------------------------------------------------
reg [31:0] i_regs [0:15];
reg [31:0] i_sr, i_pc, i_ssp, i_msp, i_fpcr, i_fpsr, i_fpiar;
reg [31:0] i_fe [0:7];
reg [63:0] i_fm [0:7];
reg [7:0]  i_level;
reg [31:0] e_regs [0:15];
reg [31:0] e_sr, e_srmask, e_pc, e_fpcr, e_fpsr, e_fpiar;
reg [31:0] e_fe [0:7];
reg [63:0] e_fm [0:7];
reg [7:0]  e_exc, e_trace, e_group2;
reg [15:0] e_trace_sr, e_trace_srmask;
reg [31:0] e_trace_pc;
reg [15:0] frame_len;
reg [7:0]  frame_b [0:63];
reg [7:0]  frame_m [0:63];
reg [15:0] em_cnt;
reg [31:0] em_a [0:63];
reg [7:0]  em_sz [0:63];
reg [31:0] em_v [0:63];
reg [31:0] em_old [0:63];
reg [31:0] pp_a [0:63];
reg [7:0]  pp_sz [0:63];
reg [31:0] pp_v [0:63];
integer    pp_cnt;
reg [31:0] cp_a [0:63];
reg [7:0]  cp_sz [0:63];
reg [31:0] cp_v [0:63];
integer    cp_cnt;
integer errors /* verilator public_flat_rw */;
integer ran    /* verilator public_flat_rw */;
integer mism   /* verilator public_flat_rw */;
integer skipped, unreached, report_lim, timeout;
integer fpwait;
// Why a round was skipped, the first reason that applies (milestone 117).
integer sk_fpu, sk_ign, sk_trace, sk_irq, sk_odd;
integer sk_tr [0:511];   // trace rounds by {mode 1/2, primary vector}
integer sk_i;
// An opcode census of the rounds that failed because the core never decoded
// the instruction at all.  The printed mismatch lines are capped, so counting
// them undercounts and biases towards whatever slice printed first; this is
// exact and one line per distinct opcode.  "Never decoded" is a round that
// took vector 4 with nothing committed: the illegal-instruction handler ran
// in place of the instruction under test.
integer undec_cnt [0:65535];
// and the other half of the worklist: rounds that DID decode and execute and
// still got the wrong answer.  Ranking those by opcode separates "the core
// cannot do this instruction at all" from "the core does it wrongly", which
// are different milestones and want different benches.
integer wrong_cnt [0:65535];
integer undec_rounds, wrong_rounds, mism_at_round, drain;
// "Never decoded" is the core's OWN verdict, sampled while the tested
// instruction is in the EA stage -- not "nothing committed", which stopped
// being true the moment the round ran long enough for the illegal-
// instruction ENTRY to commit like any other instruction.
reg saw_illegal;
// +buswr follows one store from the CPU port through the membus to the bus.
// Sampled once: $test$plusargs on every edge is not free.
reg trace_bus;
reg trace_ex;
reg trace_wb;   // +wbtrace: EA-fetch, trace arm and register commits, per cycle
reg        next_known;
reg [31:0] next_pc;
reg        seq_known;
reg [31:0] seq_next;    // the tested instruction's fall-through address
integer    multi_rounds;
// its own index: ci belongs to the capture block, which runs every cycle
reg [31:0] uo;
reg [31:0] commits_at_start;
integer k, n, fgot, lmfd, tmfd;
reg [2047:0] job_file, lmem_file, tmem_file;
reg [31:0] limit, start_record;
reg [31:0] job_version, job_tbase, job_tsize;
reg [31:0] toggle_a, toggle_v;
reg [7:0]  toggle_kind;
integer trace_round;

//--------------------------------------------------------------------------
// Exception-entry snapshot.
//
// exc_go is this core's equivalent of the sequential core's S_EXC0: the
// cycle the fault's verdict registers, before any frame beat is written.
// The frame's own fields -- its size, its vector, the stack it lands on --
// are latched on that same edge, so everything is sampled the cycle AFTER
// the rise, when those latches have settled and the faulting instruction's
// own commits have landed.
//--------------------------------------------------------------------------
reg        p_exc_go, cap_pend, cap_done;
// A traced program runs on through several trace entries to its terminal
// ILLEGAL; while this is set every entry is captured, so the last one --
// the ILLEGAL's -- is what the round is judged on (milestone 117).
reg        cap_latest;
// The first trace frame of a standalone-trace round, read as soon as its
// entry retires: a later trace pushes onto the same stack slot.
reg        t_done;
reg [7:0]  t_vec;
reg [15:0] t_sr;
reg [31:0] t_pc;
reg [7:0]  cap_vec;
reg [15:0] cap_sr;
reg [31:0] cap_sp;
reg [31:0] cap_pc;   // the faulting instruction's address, whose entry retires under it
reg [15:0] cap_sr_stk;   // the SR the latest frame stacked
integer    ci;

always @(posedge clk) begin
	if (!nreset || !round_active) begin
		p_exc_go <= 0; cap_pend <= 0; seq_known <= 0;
	end else if (ce) begin
		if (dbg_eac_valid && dbg_eac_pc == i_pc &&
		    dut.u_cpu.u_eaf.eac_is_illegal)
			saw_illegal <= 1'b1;
		if (dut.u_cpu.u_ex.eaf_valid && dut.u_cpu.u_ex.eaf_pc == i_pc && !seq_known) begin
			seq_known <= 1'b1;
			seq_next  <= dut.u_cpu.u_ex.eaf_next_pc;
		end
		p_exc_go <= dut.u_cpu.u_eaf.exc_go;
		if (dut.u_cpu.u_eaf.exc_go && !p_exc_go && (!cap_done || cap_latest))
			cap_pend <= 1;
		else if (cap_pend) begin
			cap_pend <= 0;
			cap_done <= 1;
			cap_vec  <= dut.u_cpu.u_eaf.exc_vec_r;
			cap_sr   <= dut.u_cpu.u_eaf.sr_faulted;
			cap_sp   <= dut.u_cpu.u_eaf.exc_new_sp;
			cap_pc   <= dut.u_cpu.u_eaf.eac_pc;
		end
		// The SR is the one the frame STACKS, taken from its first beat. The
		// verdict can come while an older instruction is still in EX -- an
		// ILLEGAL behind a 34-cycle divide, once instruction prefetch
		// brought it there in time -- and the status register it read then
		// had none of that instruction's flags; the beats wait for EX, and
		// carry them (2026-09-24).
		// Every first beat during a round; the last one before the round is
		// judged is the entry it is judged on.
		if (dut.u_cpu.u_eaf.exc_beat_ack && dut.u_cpu.u_eaf.exc_ph == 2'd0)
			cap_sr_stk <= dut.u_cpu.u_eaf.exc_sr_word;
	end
end

always @(posedge clk) if (trace_wb && round_active && ce)
	$display("  WB t%0t eac %0d %08x arm %0d hold %0d eaf %0d %08x | commit %0d r%0d=%08x c2 %0d r%0d | exc_go %0d",
	         $time, dut.u_cpu.u_eaf.eac_valid, dut.u_cpu.u_eaf.eac_pc, dut.u_cpu.u_eaf.trace_arm,
	         dut.u_cpu.u_eaf.trace_hold, dut.u_cpu.u_ex.eaf_valid, dut.u_cpu.u_ex.eaf_pc,
	         dut.u_cpu.commit_reg, dut.u_cpu.exe_dest_reg, dut.u_cpu.exe_result_data,
	         dut.u_cpu.commit_reg2, dut.u_cpu.exe_dest_reg2, dut.u_cpu.u_eaf.exc_go);

task mismatch;
	input [255:0] what;
	input [31:0] want, got;
	begin
		mism = mism + 1;
		if (mism <= report_lim)
			$display("MISMATCH j%0d t%0d r%0d %0s: expected %08x got %08x (pc=%08x op=%02x%02x vec=%0d/%0d commits=%0d)",
			         jr, test_idx, round_idx, what, want, got, i_pc,
			         rd8(i_pc), rd8(i_pc+1), cap_vec, e_exc,
			         dbg_commits - commits_at_start);
	end
endtask

//--------------------------------------------------------------------------
// Injection. The whole of a slice's architectural state, written straight
// into the pipelined register file while ce holds the core.
//--------------------------------------------------------------------------
task inject_state;
	integer ii;
	begin
		// The native runner enters every test through a format-$0 RTE and
		// copies the serialized A7 image to the ISP that entry makes
		// active. Direct injection has to reproduce that or the stack-EA
		// tests read the wrong frame -- the sequential driver does the
		// same, and for the same reason.
		if (i_sr[13]) begin
			for (ii = 0; ii < 32; ii = ii + 1)
				write_byte(i_ssp + ii, rd8(i_regs[15] + ii));
		end
		for (ii = 0; ii < 8; ii = ii + 1) dut.u_cpu.u_regfile.dreg[ii] = i_regs[ii];
		for (ii = 0; ii < 7; ii = ii + 1) dut.u_cpu.u_regfile.areg[ii] = i_regs[8+ii];
		dut.u_cpu.u_regfile.usp = i_regs[15];
		dut.u_cpu.u_regfile.isp = i_ssp;
		dut.u_cpu.u_regfile.msp = i_msp;
		dut.u_cpu.sr  = i_sr[15:0];
		dut.u_cpu.vbr = CAPV;
		dut.u_cpu.cacr = 0;
		dut.u_cpu.sfc = 0;
		dut.u_cpu.dfc = 0;
		// The start address, which this core has no reset vector to fetch.
		dut.u_cpu.u_if.pc     = i_pc;
		dut.u_cpu.u_if.issued = 32'd0;
		// The FPU (2026-09-24), exactly as tb_dat_replay.v injects it into the
		// same engine: FP0-FP7 live in the mirrored MLAB banks with fr_valid
		// saying which are written, and fr_s/fr_e/fr_m are simulation mirrors.
		for (ii = 0; ii < 8; ii = ii + 1) begin
			dut.u_cpu.u_eaf.u_fpu.fpu.fr_s[ii] = i_fe[ii][15];
			dut.u_cpu.u_eaf.u_fpu.fpu.fr_e[ii] = i_fe[ii][14:0];
			dut.u_cpu.u_eaf.u_fpu.fpu.fr_m[ii] = i_fm[ii];
			dut.u_cpu.u_eaf.u_fpu.fpu.fpregs.bank_a[ii] = {i_fe[ii][15], i_fe[ii][14:0], i_fm[ii]};
			dut.u_cpu.u_eaf.u_fpu.fpu.fpregs.bank_b[ii] = {i_fe[ii][15], i_fe[ii][14:0], i_fm[ii]};
			dut.u_cpu.u_eaf.u_fpu.fpu.fr_valid[ii] = 1'b1;
		end
		dut.u_cpu.u_eaf.u_fpu.fpu.fpcr  = i_fpcr;
		dut.u_cpu.u_eaf.u_fpu.fpu.fpsr  = i_fpsr;
		dut.u_cpu.u_eaf.u_fpu.fpu.fpiar = i_fpiar;
	end
endtask

// A7 is three registers, but the corpus' regs[15] slot is not "whichever one
// the final SR selects".  It is the serialized A7 image the native runner
// entered the test with, and inject_state puts it in the USP: a supervisor
// round runs on the ISP at i_ssp, which is a RELOCATED stack the runner's
// entry RTE made active and which holds a copy of the same 32 bytes.  So the
// bank a supervisor round modifies is the ISP, and the slot the oracle
// serializes back is still the USP.  Selecting on the final SR reads the
// relocated stack and reports every supervisor round as off by i_ssp -
// i_regs[15].  tb_dat_replay.v reads the USP unconditionally for the same
// reason; in user mode the USP is the active A7 anyway, so this is not a
// special case, it is the only reading that is right in both modes.
function [31:0] final_a7;
	begin
		final_a7 = dut.u_cpu.u_regfile.usp;
	end
endfunction

task check_final;
	integer fi;
	reg [31:0] got;
	reg [15:0] got_sr;
	begin
		mism_at_round = mism;
		// An exception round is judged on the entry snapshot, which is the
		// architectural state the corpus recorded; one that completed is
		// judged on the live register file.
		// A standalone-trace round's own entry is its trace (t_vec, below);
		// only a traced program's has a terminal entry to compare here.
		if (cap_done && (e_trace != 2 || cap_latest) && cap_vec !== e_exc)
			mismatch("exception vector", {24'd0, e_exc}, {24'd0, cap_vec});
		// The trace frame, where the oracle has one: its stacked SR under the
		// record's own mask, and its PC (tb_dat_replay.v's check_trace_frame).
		if (e_trace == 2) begin
			if (!t_done || t_vec !== 8'd9)
				mismatch("missing trace", 32'd9, {24'd0, t_vec});
			else begin
				if (((t_sr ^ e_trace_sr) & e_trace_srmask) != 0)
					mismatch("trace SR", {16'd0, e_trace_sr}, {16'd0, t_sr});
				if (t_pc !== e_trace_pc)
					mismatch("trace PC", e_trace_pc, t_pc);
			end
		end
		// ...and none where it does not. A trace still armed when a round is
		// judged is one the oracle says never happens: the sequential driver
		// calls it "unexpected trace", cputest "Got unexpected trace
		// exception". Every exception entry arming one (review 14) would have
		// shown here across the whole corpus.
		if (e_trace == 0 && e_exc != 9 && dut.u_cpu.u_eaf.trace_arm)
			mismatch("unexpected trace", 32'd0, 32'd1);
		// Live, for an exception round as much as a completed one: the
		// round now stops at the entry's retirement, so everything the
		// oracle names has committed and nothing younger has. A snapshot
		// taken at entry time is the thing this replaced.
		for (fi = 0; fi < 16; fi = fi + 1) begin
			got = (fi < 8)  ? dut.u_cpu.u_regfile.dreg[fi]
			    : (fi < 15) ? dut.u_cpu.u_regfile.areg[fi-8]
			                : final_a7();
			if (got !== e_regs[fi]) begin
				if (mism < report_lim)
					$display("  reg detail: %0s%0d",
					         fi < 8 ? "D" : "A", fi < 8 ? fi : fi - 8);
				mismatch(fi < 8 ? "D register" : "A register", e_regs[fi], got);
			end
		end
		// The stacked SR belongs to the round only when the entry does: the
		// tested instruction's own, a trace, or a traced program's terminal
		// ILLEGAL. A round judged at its own retirement uses the live SR --
		// a later instruction may already have its verdict, not its frame.
		got_sr = (cap_done && (cap_pc == i_pc || e_trace == 2 || e_exc == 9 || cap_latest))
		         ? cap_sr_stk : dbg_sr;
		if (((got_sr ^ e_sr[15:0]) & e_srmask[15:0]) != 0)
			mismatch("SR", e_sr, {16'd0, got_sr});
		// The FPU's registers, compared as tb_dat_replay.v compares them. They
		// are read live: run_round let a released operation finish first.
		if (flags & F_FPU) begin
			for (fi = 0; fi < 8; fi = fi + 1) begin
				got = {16'd0, dut.u_cpu.u_eaf.u_fpu.fpu.fr_valid[fi] ? dut.u_cpu.u_eaf.u_fpu.fpu.fpregs.bank_a[fi][79:64] : {1'b0, 15'h7FFF}};
				if (got[15:0] !== e_fe[fi][15:0]) mismatch("FP sign/exp", e_fe[fi], got);
				got = dut.u_cpu.u_eaf.u_fpu.fpu.fr_valid[fi] ? dut.u_cpu.u_eaf.u_fpu.fpu.fpregs.bank_a[fi][63:32] : 32'hFFFF_FFFF;
				if (got !== e_fm[fi][63:32]) mismatch("FP mantissa hi", e_fm[fi][63:32], got);
				got = dut.u_cpu.u_eaf.u_fpu.fpu.fr_valid[fi] ? dut.u_cpu.u_eaf.u_fpu.fpu.fpregs.bank_a[fi][31:0] : 32'hFFFF_FFFF;
				if (got !== e_fm[fi][31:0]) mismatch("FP mantissa lo", e_fm[fi][31:0], got);
			end
			if (dut.u_cpu.u_eaf.u_fpu.fpu.fpcr !== e_fpcr) mismatch("FPCR", e_fpcr, dut.u_cpu.u_eaf.u_fpu.fpu.fpcr);
			if (dut.u_cpu.u_eaf.u_fpu.fpu.fpsr !== e_fpsr) mismatch("FPSR", e_fpsr, dut.u_cpu.u_eaf.u_fpu.fpu.fpsr);
			// cputest validates FPIAR when the record names it, or when the
			// instruction changed it from the injected value.
			if ((flags & F_CHECK_FPIAR) || dut.u_cpu.u_eaf.u_fpu.fpu.fpiar !== i_fpiar)
				if (dut.u_cpu.u_eaf.u_fpu.fpu.fpiar !== e_fpiar) mismatch("FPIAR", e_fpiar, dut.u_cpu.u_eaf.u_fpu.fpu.fpiar);
		end
		for (fi = 0; fi < em_cnt; fi = fi + 1)
			if (read_value(em_a[fi], em_sz[fi]) !== em_v[fi]) begin
				// which address disagreed, and where the three stack pointers
				// stand, because a stack write landing at the relocated ISP
				// instead of the corpus A7 looks exactly like a value bug.
				if (mism < report_lim)
					$display("  mem detail: addr=%08x sz=%0d a7=%08x usp=%08x isp=%08x i_ssp=%08x i_a7=%08x",
					         em_a[fi], em_sz[fi], final_a7(),
					         dut.u_cpu.u_regfile.usp, dut.u_cpu.u_regfile.isp,
					         i_ssp, i_regs[15]);
				mismatch("memory", em_v[fi], read_value(em_a[fi], em_sz[fi]));
			end
		// ...and put back what the round changed, as tb_dat_replay.v does
		// after the same compare. The oracle starts every round from the
		// slice's memory, not from the previous round's result: without this
		// a NEGX that wrote $FF in one round read $FF as its operand in the
		// next, where the oracle read 0, and every round that changes memory
		// judged its successor against the wrong input (milestone 113).
		for (fi = 0; fi < em_cnt; fi = fi + 1)
			apply_value(em_a[fi], em_sz[fi], em_old[fi]);
		if (mism > mism_at_round) begin
			if (saw_illegal) begin
				undec_rounds = undec_rounds + 1;
				undec_cnt[{rd8(i_pc), rd8(i_pc + 1)}] =
					undec_cnt[{rd8(i_pc), rd8(i_pc + 1)}] + 1;
			end else begin
				wrong_rounds = wrong_rounds + 1;
				wrong_cnt[{rd8(i_pc), rd8(i_pc + 1)}] =
					wrong_cnt[{rd8(i_pc), rd8(i_pc + 1)}] + 1;
			end
		end
	end
endtask

//--------------------------------------------------------------------------
// A round: hold, inject, release, run to the expected PC, compare.
//--------------------------------------------------------------------------
task run_round;
	begin
		ran = ran + 1;
		cap_done = 0; cap_pend = 0; cap_vec = 8'hff; p_exc_go = 0;
		cap_latest = 0; t_done = 0; t_vec = 8'hff; t_sr = 16'h0; t_pc = 32'h0;
		saw_illegal = 0;
		boot_pc = i_pc; boot_msp = i_msp; cur_pc = i_pc;
		hold_fetch = 0; round_active = 1;
		ce = 0;
		nreset = 0;
		repeat (4) @(posedge clk);
		nreset = 1;
		@(posedge clk);
		inject_state;
		if (trace_ex)
			$display("ROUND j%0d t%0d r%0d pc=%08x op=%02x%02x %02x%02x end_pc=%08x exc=%0d",
			         jr, test_idx, round_idx, i_pc, rd8(i_pc), rd8(i_pc+1), rd8(i_pc+2), rd8(i_pc+3),
			         e_pc, e_exc);
		commits_at_start = dbg_commits;
		@(posedge clk);
		ce = 1;

		// The completion boundary, and it is NOT the one the sequential
		// driver uses. That driver waits for the core to ask memory for the
		// instruction the oracle says comes next, which on a machine that
		// executes one instruction at a time means the previous one has
		// finished. Here the fetch of the next address happens five stages
		// ahead of the tested instruction retiring: waiting for it stopped
		// every round with the instruction still in flight and nothing
		// committed, which is how the first run produced 143 mismatches
		// that were all the injected input state read back.
		//
		// What completes a round on this core is the tested instruction
		// RETIRING -- the writeback stage naming its address -- or an
		// exception entry being captured. A few cycles afterwards let its
		// commits land before anything is read.
		//
		// An EXCEPTION round ends at the same place, and this used to stop
		// it one cycle after exc_go instead. That is the cycle the fault's
		// VERDICT registers, not the cycle its consequences land: the frame
		// still has to be pushed over the bus, the vector read, A7 given the
		// new stack pointer and the faulting instruction's own (An)+ written
		// back. Measured on Basic/CHK.W/0002, that takes 35 more cycles, and
		// stopping at +1 read A7 before the postincrement and the frame push
		// had committed -- 5,668 rounds of CHK.W reporting a core that had
		// done exactly the right thing. The entry RETIRES under the faulting
		// instruction's own PC, so one condition covers both kinds of round.
		timeout = 0;
		while (timeout < EXEC_TIMEOUT &&
		       !(dbg_wb_valid && dbg_wb_pc == i_pc && ce)) begin
			@(posedge clk); timeout = timeout + 1;
		end
		// A round can be a PROGRAM (milestone 113): MOVEC2's reads a
		// control register and then runs 20 more bytes of code before the
		// ILLEGAL at the end PC. Stopping when the first instruction retired
		// judged every one of them against state the rest of the program had
		// not yet made. So when a round that completes normally retires its
		// first instruction, look at the next one in program order -- the
		// oldest valid stage, wrong-path work having been flushed by the time
		// anything older retires -- and if it is the tested instruction's own
		// SEQUENTIAL successor and that is not the end PC, run on until the
		// marker's own exception entry retires, which is where the sequential
		// driver stops too. Everything else is judged exactly where it always
		// was. The successor test is what keeps branches out: a Bcc round's
		// end PC is not a fall-through marker, and the first version of this
		// rule, which asked only "is the next instruction at the end PC",
		// sent 305,432 branch rounds on to a marker they never reach.
		if (timeout < EXEC_TIMEOUT && e_exc == 4 && e_trace == 0 && !cap_pend && !cap_done) begin
			next_known = 0;
			while (timeout < EXEC_TIMEOUT && !next_known && !cap_pend && !cap_done) begin
				if (dbg_ex_valid)       begin next_known = 1; next_pc = dbg_ex_pc;  end
				else if (dbg_eaf_valid) begin next_known = 1; next_pc = dbg_eaf_pc; end
				else if (dbg_eac_valid) begin next_known = 1; next_pc = dbg_eac_pc; end
				else if (dbg_id_valid)  begin next_known = 1; next_pc = dbg_id_pc;  end
				else begin @(posedge clk); timeout = timeout + 1; end
			end
			if (next_known && seq_known && next_pc == seq_next && next_pc != e_pc) begin
				multi_rounds = multi_rounds + 1;
				// Judged on the terminal entry, so on the SR it STACKED: the live one
				// is the handler's by then. MOVEC2's programs run in supervisor mode
				// and could not tell; the FPU's (the tested instruction, then
				// cputest's FNOP) run in either, and every user-mode one read $2000.
				cap_latest = 1;
				while (timeout < EXEC_TIMEOUT &&
				       !(dbg_wb_valid && dbg_wb_pc == e_pc && ce)) begin
					@(posedge clk); timeout = timeout + 1;
				end
			end
		end
		// A standalone-trace round (e_trace == 2; every trace round in Basic,
		// 4,509,254 of them, milestone 117): the tested instruction runs with
		// T set, and the oracle records the trace frame's stacked SR and PC
		// before its handler returns into the terminal ILLEGAL. The state to
		// judge is the one at the instruction's retirement, as for any other
		// round; the trace entry is followed as well, so its frame can be
		// read. The pipeline drains before it takes a trace, so the first WB
		// retirement after the entry is captured is the entry itself.
		// A round whose recorded result IS the trace (e_exc == 9, no separate
		// trace record: T1, and the tested instruction completed) is followed
		// to the same place and judged as the exception round it is. It used
		// to stop at the retirement with nothing captured, so whether the
		// trace happened at all was never looked at.
		if (timeout < EXEC_TIMEOUT && (e_trace == 2 || (e_exc == 9 && !cap_done))) begin
			while (timeout < EXEC_TIMEOUT && !cap_done) begin
				@(posedge clk); timeout = timeout + 1;
			end
			@(posedge clk); timeout = timeout + 1;
			while (timeout < EXEC_TIMEOUT && !(dbg_wb_valid && ce)) begin
				@(posedge clk); timeout = timeout + 1;
			end
			if (e_trace == 2) begin
				repeat (4) @(posedge clk);   // the frame's last beat out of the write buffer
				t_done = 1;
				t_vec  = cap_vec;
				t_sr   = read_value(cap_sp, 1);
				t_pc   = read_value(cap_sp + 32'd2, 2);
				// A traced PROGRAM (MOVEC2's) continues past its first trace
				// to the end marker, as the untraced one does above, and
				// cputest records its final state there: the trace handler,
				// an RTE at vector 9's slot, returns into the next
				// instruction. A single-instruction round's first trace is
				// already AT the end PC -- the marker, or a taken branch's
				// target -- so any other PC there means a program; under T0
				// the first trace can come several instructions in. Every
				// later entry is captured; the round ends when the
				// ILLEGAL's -- the one under e_exc -- retires at the end PC.
				// A trace entry retires under the instruction it held, so
				// the one before the ILLEGAL retires at the end PC too; and
				// the marker is cputest's NOP (MOVEA.L A0,A0) at the end PC
				// with the ILLEGAL after it. So the round ends when the
				// terminal entry is captured and has retired under the
				// address of the instruction that took it.
				if (t_pc != e_pc) begin
					multi_rounds = multi_rounds + 1;
					cap_latest = 1;
					while (timeout < EXEC_TIMEOUT &&
					       !(cap_done && !cap_pend && cap_vec == e_exc && ce &&
					         dbg_wb_valid && dbg_wb_pc == cap_pc)) begin
						@(posedge clk); timeout = timeout + 1;
					end
				end
			end
		end
		// Freeze the CPU first so no younger instruction runs, then drain the
		// store.  A store leaves the pipeline long before its bytes reach
		// memory: the CPU posts it to the membus, which may be in the middle
		// of an instruction fetch and only starts the write cycles afterwards.
		// Waiting for the 16-bit bus to be idle is NOT enough, because it is
		// already idle while the write sits queued -- that is exactly how BSR
		// and PEA came to read back as if they had never pushed.  What has to
		// go quiet is l1_wr_busy, the membus' own "a write is outstanding",
		// which is the same signal the core stalls on.  clkena_in is not
		// gated by ce, so this drains with the core held still.
		// A register-destination FPU operation is released to the background
		// (ap040_pipe_fpu.v's fpu_bg) and may still be computing when the
		// round's last instruction retires. The engine runs only with ce, so
		// ce stays up until it finishes -- and the bus stops answering, so the
		// integer side cannot move: the terminal ILLEGAL's entry, right behind,
		// stalls at its first frame beat having changed nothing. Letting it run
		// instead took the entry and judged the handler's supervisor SR. A
		// released operation has no stores of its own to be held up.
		fpwait = 0;
		if (dut.u_cpu.u_eaf.u_fpu.bg_busy) begin
			hold_bus = 1;
			while (fpwait < 4096 && dut.u_cpu.u_eaf.u_fpu.bg_busy) begin
				@(posedge clk); fpwait = fpwait + 1;
			end
		end
		ce = 0;
		hold_bus = 0;
		drain = 0;
		while (drain < 1024 && (dut.l1_wr_busy || busstate != 2'b01)) begin
			@(posedge clk); drain = drain + 1;
		end
		repeat (2) @(posedge clk);
		if (timeout >= EXEC_TIMEOUT) begin
			unreached = unreached + 1;
			if (unreached <= report_lim)
				$display("UNREACHED j%0d t%0d r%0d: pc=%08x never reached %08x (op=%02x%02x)",
				         jr, test_idx, round_idx, i_pc, e_pc, rd8(i_pc), rd8(i_pc+1));
		end else
			check_final;
	end
endtask

//--------------------------------------------------------------------------
// The record stream
//--------------------------------------------------------------------------
initial begin
	mem_ready = 0; boot_overlay = 0; ce = 0;
	hold_fetch = 0; round_active = 0; cur_pc = 0; boot_pc = 0; boot_msp = 0;
	nreset = 0; errors = 0; ran = 0; mism = 0;
	skipped = 0; unreached = 0; report_lim = 40; trace_round = -1;
	sk_fpu = 0; sk_ign = 0; sk_trace = 0; sk_irq = 0; sk_odd = 0;
	for (sk_i = 0; sk_i < 512; sk_i = sk_i + 1) sk_tr[sk_i] = 0;
	undec_rounds = 0; wrong_rounds = 0; multi_rounds = 0;
	trace_bus = $test$plusargs("buswr");
	trace_ex  = $test$plusargs("extrace");
	trace_wb  = $test$plusargs("wbtrace");
	for (uo = 0; uo < 65536; uo = uo + 1) begin
		undec_cnt[uo] = 0; wrong_cnt[uo] = 0;
	end
	patch_addr = 0;
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
	TBASE = job_tbase; TSIZE = job_tsize;
	$fclose(jf);

	lmfd = $fopen(lmem_file, "rb");
	tmfd = $fopen(tmem_file, "rb");
	if (!lmfd || !tmfd) begin $display("FAIL: cannot open corpus memory images"); $finish; end
	fgot = $fread(lmem, lmfd); $fclose(lmfd);
	fgot = $fread(tmem, tmfd); $fclose(tmfd);

	jf = $fopen(job_file, "rb");
	if (jread32(0) !== "APR2") begin $display("FAIL: bad job magic"); $finish; end
	job_version = jread32(0); jn = jread32(0);
	job_tbase = jread32(0); job_tsize = jread32(0); odd_vector = jread32(0);
	if (jn > limit) jn = limit;
	$display("tb_dat_replay_pipe: %0d APR2 records", jn);

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
			if (toggle_kind == 1)
				apply_value(toggle_a, 2, {toggle_v[15:0], toggle_v[31:16]});
			else if (toggle_kind == 2)
				apply_value(toggle_a, 1,
					toggle_v[31:16] == 16'h2048 ? 16'h4afc : 16'h2048);
		end
		for (k = 0; k < 16; k = k + 1) e_regs[k] = jread32(0);
		e_sr = jread32(0); e_srmask = jread32(0);
		for (k = 0; k < 8; k = k + 1) begin
			e_fe[k] = jread32(0); e_fm[k] = {jread32(0), jread32(0)};
		end
		e_fpcr = jread32(0); e_fpsr = jread32(0); e_fpiar = jread32(0);
		e_exc = jread8(0); e_pc = jread32(0);
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

		// Judged only if the oracle is an instruction that completes. The
		// rest are counted here rather than guessed at.
		if ((flags & F_IGNORE_EXC) ||
		    e_trace == 1 || i_level != 0 ||
		    odd_vector != 0 || jr < start_record) begin
			skipped = skipped + 1;
			if (flags & F_IGNORE_EXC)       sk_ign   = sk_ign + 1;
			else if (e_trace == 1) begin
				sk_trace = sk_trace + 1;
				sk_tr[{e_trace[1], e_exc}] = sk_tr[{e_trace[1], e_exc}] + 1;
			end
			else if (i_level != 0)          sk_irq   = sk_irq + 1;
			else if (odd_vector != 0)       sk_odd   = sk_odd + 1;
			apply_deferred;
		end else begin
			run_round;
			apply_deferred;
		end
	end

	$display("pipe replay: %0d judged, %0d mismatches, %0d unreached, %0d skipped (exception/trace/irq/fpu)",
	         ran, mism, unreached, skipped);
	$display("pipe skipped: fpu %0d ignore-exc %0d trace %0d irq %0d odd-vector %0d",
	         sk_fpu, sk_ign, sk_trace, sk_irq, sk_odd);
	for (sk_i = 0; sk_i < 512; sk_i = sk_i + 1)
		if (sk_tr[sk_i] != 0)
			$display("SKIPTRACE mode%0d vec%0d %0d", (sk_i >= 256) ? 2 : 1, sk_i % 256, sk_tr[sk_i]);
	if (multi_rounds != 0)
		$display("pipe multi: %0d rounds ran on to an end marker past their first instruction", multi_rounds);
	// A slice where NOTHING was judged is not a slice that passed. cputest
	// rounds end in an exception by construction -- the generator closes
	// every test with a terminal ILLEGAL -- so the scope this driver starts
	// with excludes almost all of them, and reporting that as a pass would
	// be the same vacuous green this campaign has had to correct twice
	// already.
	if (undec_rounds != 0) begin
		$display("pipe undecoded: %0d rounds the core never decoded", undec_rounds);
		for (uo = 0; uo < 65536; uo = uo + 1)
			if (undec_cnt[uo] != 0)
				$display("UNDECODED %04x %0d", uo[15:0], undec_cnt[uo]);
	end
	if (wrong_rounds != 0) begin
		$display("pipe wrong: %0d rounds executed and disagreed", wrong_rounds);
		for (uo = 0; uo < 65536; uo = uo + 1)
			if (wrong_cnt[uo] != 0)
				$display("WRONG %04x %0d", uo[15:0], wrong_cnt[uo]);
	end
	if (ran == 0)
		$display("TEST FAILED: nothing judged -- %0d rounds all fell outside this driver's scope", skipped);
	else if (mism == 0 && unreached == 0 && errors == 0) $display("ALL TESTS PASSED");
	else $display("TEST FAILED with %0d mismatches and %0d unreached", mism, unreached);
	$finish;
end

endmodule
