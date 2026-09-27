// tb_ap040_pipe_compat.v -- upstream's bench for the pipelined core behind
// its reference-compatible wrapper, from ranzbak/AP68040-pipelined at
// 9efe490d (tb/tb_ap040_pipe_compat.v), for the vendored core in
// rtl/ap040_ranzbak.  One change: the wrapper here has the split enable
// (clkena_in / bus_clkena_in, rtl/ap040_ranzbak/README.md), and this bench
// drives both from its one clkena_in.
//
// It is the bench that SEES interrupt timing on this core: a cycle-exact IPL
// injector ($F110 / $F148 / $F160) and the boundary-latency rule below
// ("qualified level-N request not taken at the next boundary").  The
// production bridge bench (tb_cpu_wrapper_chip_bridge.v) samples IPL on the
// wrapper's stage grid and cannot reach the single-clock alignments that
// t_fpu.s's IRQ sweep found (a request lost as a released FDIV left P_START;
// a `done` dropped on an exception entry's redirect clock); this one does,
// deterministically.  Run it with tests/ap040/run_ranzbak.py --bench compat.
// tb_ap040_pipe_compat.v - lib/AP68040's tb/tb_ap040_program.v (e2-fixes
// 530fc72) on ap040_pipe_tg68k_compat: the 16-bit adapter, three wait
// profiles (phase 2: the cpu_cache_new level acknowledge), programs report
// $600D at $F102.  Made by substitution (the core-internal probes read as
// idle: see the shim block); rebuild it the same way if the original changes.
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

module tb_ap040_pipe_compat;

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
// the DMA agent's registers (see "A chipset DMA agent" below)
reg        dma_snp = 1'b0;
reg [15:0] dma_a = 16'd0, dma_d = 16'd0, dma_n = 16'd0;
reg        dma_nosnp = 1'b0, dma_arm = 1'b0;
reg         berr_armed;
reg   [1:0] irq_exc_armed;
reg   [2:0] irq_fetch_stall;
wire        berr_d = berr_armed && nreset && (busstate != 2'b01) &&
                     (addr_out[15:0] == 16'hF140);

// $F154 arms a one-shot bus error on an instruction FETCH at the written
// address (0 disarms).  This is the only way to reach the queue's
// speculative-fault paths: the page guard rules out translation
// differences, so only a physical berr can fault a fetch ahead of demand.
reg         fberr_armed = 0;
reg  [15:0] fberr_addr = 0;
wire        fberr = fberr_armed && nreset && (busstate == 2'b00) &&
                    (addr_out[15:0] == fberr_addr);

wire        berr = berr_d | fberr;

wire        clkena_in = (busstate == 2'b01) | mem_ready | berr;

reg   [2:0] ipl_lvl;
reg  [15:0] ipl_delay = 0;   // $F148: delayed level-2 IPL countdown
integer   clkcount = 0;      // free-running clk counter for $F108 stamps
integer   stamp_prev = 0;
reg   [7:0] ipl_pulse = 0;   // $F14C: withdraw the request after N cycles
reg   [7:0] ipl_step  = 0;   // $F150: downgrade the request after N cycles
reg   [2:0] ipl_next  = 0;   // $F150: level the encoder falls back to
// A device that has let go of IPL must never produce an interrupt.  Rather
// than time a program against it, watch the invariant directly: count how
// long the pins have been idle and fail if an autovectored interrupt is
// accepted well after that.  The 12-cycle margin is comfortably past the
// core's two-stage IPL synchronizer and the hold tracking it (~5 cycles),
// while a core that retains a withdrawn level indefinitely is caught.
reg  [15:0] ipl_idle_for = 0;
reg         irq_seen_q = 0;
// Shadow IPEND claims over the core's own synchronized level: bit L is set
// while a level-L request is visibly asserted AND has qualified against the
// live mask; it is cleared when the synchronized level falls below L (the
// device let go, taking any claim with it) or when an acceptance consumes
// it.  A level hidden behind a higher request holds no claim of its own:
// when the encoder falls back to it, it must requalify like a fresh
// request.  This is the reference model for the mask invariant below.
reg   [6:1] tb_qual = 0;
// Previous core state, for the exception-prefetch invariant below.
reg   [7:0] epf_state_q = 0;
integer ql;
always @(posedge clk) begin
	if (!nreset) tb_qual <= 0;
	else begin
		for (ql = 1; ql <= 6; ql = ql + 1) begin
			if (shim_irq_lvl < ql)
				tb_qual[ql] <= 0;
			else if (shim_irq_lvl == ql && ql > shim_sr[10:8])
				tb_qual[ql] <= 1;
		end
		if (exc_accept && shim_exc_is_irq && shim_irq_lvl_l != 3'd7 &&
		    shim_irq_lvl_l != 3'd0)
			tb_qual[shim_irq_lvl_l] <= 0;
	end
end
// The other direction of the IPEND rule, asserted directly instead of by
// aiming a delay at an instruction (X2.3a): a request that has QUALIFIED
// -- level above the live mask while visibly asserted -- must be taken
// at the next instruction boundary, whatever the mask does in between.
// A MOVE to SR that raises the mask after the request qualified does not
// cancel it; that is what the 68040's IPEND bit means.  tb_must[L] holds
// such a claim; it is dropped only when the device lets go (the level
// falls below L) or when an interrupt of level >= L is accepted (a
// higher level masks it, and it must requalify when the encoder falls
// back -- the same rule tb_qual encodes above).  A claim may see ONE
// instruction start, because it can qualify in the cycle after the
// boundary sampled it; a second start with the claim still held is the
// lost-hold signature.  Before this rule, test 136 timed a request to
// land inside the MOVE with a fixed delay, which stopped landing there
// the moment the core stopped freezing during bus waits (plan A2b-0).
reg   [6:1] tb_must = 0;
reg   [7:0] must_age [1:6];
reg   [7:0] must_prev = 0;
integer ml;
initial for (ml = 1; ml <= 6; ml = ml + 1) must_age[ml] = 0;
always @(posedge clk) begin
	if (!nreset) begin
		tb_must <= 0;
		for (ml = 1; ml <= 6; ml = ml + 1) must_age[ml] <= 0;
	end
	else begin
		for (ml = 1; ml <= 6; ml = ml + 1) begin
			if (shim_irq_lvl < ml) begin
				tb_must[ml] <= 0;
				must_age[ml] <= 0;
			end
			else if (exc_accept && shim_exc_is_irq && shim_irq_lvl_l >= ml) begin
				tb_must[ml] <= 0;
				must_age[ml] <= 0;
			end
			// A claim arms only outside exception processing: between
			// the acceptance edge and the cycle the new mask reaches
			// SR the level is still above the OLD mask (states
			// S_EXC0..S_EXC_JMP, 34..42, precede in_exc by a cycle),
			// and a request raised during stacking is taken at the
			// handler's entry fetch without ever starting an
			// instruction.
			else if (!tb_must[ml] && !exc_window &&
			         shim_irq_lvl == ml && ml > shim_sr[10:8]) begin
				tb_must[ml] <= 1;
				must_age[ml] <= 0;
			end
			else if (tb_must[ml] && insn_start) begin
				// An instruction started with the claim still held.  The
				// reference allowed ONE such start; this pipeline needs a
				// wider bound and the number is CALIBRATED, not copied:
				// `irq_take` does not arm while a data read is outstanding
				// (the M9 operand-read rule, 0bbab45 -- an interrupt must not
				// land between an instruction's operand read and its
				// execution), so a run of back-to-back reads legitimately
				// defers a qualified request.  Measured across the interrupt
				// programs, the worst case is SIX, in t_irq_pipe's own
				// read-to-clear test (case 32/33).  Sixteen is therefore well
				// above anything the design does and far below a LOST hold,
				// which survives until the program changes the mask or the
				// device lets go -- dozens of instructions in every one of
				// these loops.  To re-derive it: widen `must_age`, print the
				// running maximum here, and run the interrupt programs.
				must_age[ml] <= must_age[ml] + 1'd1;
				if (must_age[ml] == 8'd16) begin
					errors = errors + 1;
					$display("FAIL: qualified level-%0d request not taken at the next boundary (pc=%h sr=%h)",
					         ml, dbg_pc, shim_sr);
					result = 2;
				end
			end
		end
	end
end
// +exctrace: print every exception entry (vector, pc) for A/B diffing
reg [7:0] et_prev = 0;
always @(posedge clk) clkcount = clkcount + 1;
always @(posedge clk) begin
	et_prev <= shim_state;
	if ($test$plusargs("exctrace") &&
	    shim_state == 8'd34 && et_prev != 8'd34) begin
		$display("EXC vec=%0d pc=%08x spc=%08x sr=%04x",
		         shim_exc_vec, shim_pc,
		         shim_exc_spc, shim_sr);
		// vector 55 means an unsupported FP data type reached the FPU:
		// dump the register file so the offending operand is visible
		// without a rebuild (a denormal/unnormal register value here is
		// itself a defect -- no AP040 path may create one).
		if (shim_exc_vec == 8'd55) begin : et_fpdump
			integer efr;
			for (efr = 0; efr < 8; efr = efr + 1)
				$display("  FP%0d = %x %04x %x", efr,
				         32'd0,
				         32'd0,
				         32'd0);
		end
	end
end

// The internal caches are ON by default here, as in the shipping build.
// -DAP040_TB_CACHE=0 builds the g_nocache configuration instead, for
// cache-vs-no-cache cycle comparisons (t_cache's architected
// stale-until-CINVA expectations only hold with them on).
`ifndef AP040_TB_CACHE
`define AP040_TB_CACHE 1
`endif

// POST=0 keeps every store synchronous: the A/B reference for the posted
// store (plan X3.3), whose logs must match the tree before it.
parameter POST = 1;
// FILLCH=0 keeps every line fill on the 16-bit adapter: the A/B
// reference for the fill channel (plan X3.4, A1).  With FILLCH=1 the
// bench serves the channel itself: a request is answered FILL_LAT
// cycles later with the line from mem, ack held until the request
// drops -- the shape the wrapper's CDC will present.  FILL_LAT models
// DDR3 latency plus two crossings in core cycles.
parameter FILLCH = 1;
parameter FILL_LAT = 8;
wire        fill_req;
wire [31:4] fill_addr;
reg [127:0] fill_data = 0;
reg         fill_ack = 0;
integer     fill_lat_cnt = 0;
always @(posedge clk) begin
	if (!fill_req) begin
		fill_ack <= 0;
		fill_lat_cnt <= 0;
	end
	else if (!fill_ack) begin
		if (fill_lat_cnt != FILL_LAT) fill_lat_cnt <= fill_lat_cnt + 1;
		else begin
			fill_data <= {mem[{fill_addr[15:4], 3'd0}], mem[{fill_addr[15:4], 3'd1}],
			              mem[{fill_addr[15:4], 3'd2}], mem[{fill_addr[15:4], 3'd3}],
			              mem[{fill_addr[15:4], 3'd4}], mem[{fill_addr[15:4], 3'd5}],
			              mem[{fill_addr[15:4], 3'd6}], mem[{fill_addr[15:4], 3'd7}]};
			fill_ack <= 1;
		end
	end
end
ap040_pipe_tg68k_compat #(.AP040_ENABLE_CACHE(`AP040_TB_CACHE),
                     .AP040_POST_STORES(POST),
                     .AP040_FILL_CHANNEL(FILLCH)) dut
(
	.clk(clk),
	.nreset(nreset),
	.cache_allow_all(1'b1),
	.fill_ena_zorro(FILLCH != 0),
	.fill_ena_chip(FILLCH != 0),
	.fill_req(fill_req),
	.fill_addr(fill_addr),
	.fill_data(fill_data),
	.fill_ack(fill_ack),
	.fill_err(1'b0),
	.cache_snoop_stb(dma_snp), .cache_snoop_addr({16'd0, dma_a}),
	.cache_z2_ena(1'b0),
	.cache_z3_base0(5'd0),
	.cache_z3_ena0(1'b0),
	.cache_z3_base1(4'd0),
	.cache_z3_ena1(1'b0),
	.clkena_in(clkena_in), .bus_clkena_in(clkena_in),   // (the wrapper's split enable: README)
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


// The reference core's internals this bench probes.  Most of them were
// TIED OFF when the bench was ported to the pipelined core, and that is a
// trap in itself: three interrupt assertions and the IPEND shadow below
// went on compiling while shadowing NOTHING, and `IPLCAP` kept advertising
// a cycle-fine injector that could not fire (plan M9.T step 4 (a)).  Every
// probe this pipeline HAS an equivalent for is now wired to it; the ones it
// genuinely does not have are named, with the reason, in the plan's bench
// list rather than left looking alive.
wire  [7:0] shim_state = 8'd0;           // (no microcoded state machine here:
                                         //  the assertions below use the named
                                         //  pipeline events instead)
wire [15:0] shim_sr = debug_status[47:32];
wire        shim_ce = 1'b1;
// the synchronized level on the pins, and the level an entry accepted
wire  [2:0] shim_irq_lvl   = dut.core.g_irq.irq_lvl_live;
wire  [2:0] shim_irq_lvl_l = dut.core.u_eaf.x_lvl;
wire        shim_exc_is_irq = dut.core.u_eaf.x_irq;
wire        shim_in_exc     = (dut.core.u_eaf.ph == 4'd2);   // P_EXC
wire        shim_lk_cyc = 1'b0, shim_epf_pend = 1'b0;
wire  [7:0] shim_exc_vec = dut.core.u_eaf.x_vec;
// The three events the reference bench spelled as state numbers:
//   exc_accept  an exception ENTRY begins           (was state 34, edge)
//   shim_in_exc it is still being processed         (was 34..42 / in_exc)
//   insn_start  an instruction leaves EA-fetch      (was state 4, edge)
reg         in_exc_q = 0;
always @(posedge clk) in_exc_q <= shim_in_exc;
wire        exc_accept = shim_in_exc && !in_exc_q;
// (2026-09-23) only on an ENABLED edge: `fin` is a level that stays up
// across the clocks clkena_in holds low, and an instruction leaves EA-fetch
// once, on the edge the core is enabled.  Counted per clock, a NOP waiting
// out a bus wait counted five or six times, and t_irqwedge_pipe.s's shape D
// -- an interrupt taken after four real instructions -- read as a lost hold.
wire        insn_start = dut.core.u_eaf.st.fin && dut.core.ce;
// ... and the tail of an entry.  The reference bench excluded "states 34..42"
// because between the acceptance and the cycle the new mask reaches SR the
// level is still above the OLD mask, and a claim armed there is a phantom.
// In THIS core that window outlives the phase: EA-fetch leaves P_EXC when it
// dispatches the entry's final micro-op, and that micro-op's SR write commits
// one or two clocks later in WB.  So the exclusion runs from entering P_EXC
// until the entry's SR write has actually landed -- which is the reference's
// rule stated as what it means rather than as a state range.
reg         exc_sr_pend = 0;
reg  [15:0] shim_sr_q = 0;
always @(posedge clk) shim_sr_q <= shim_sr;
always @(posedge clk)
	if (!nreset) exc_sr_pend <= 0;
	else if (shim_in_exc) exc_sr_pend <= 1;
	else if (shim_sr != shim_sr_q) exc_sr_pend <= 0;   // the new mask has landed
wire        exc_window = shim_in_exc || exc_sr_pend;
// The exception's OWN accesses must be supervisor data (FC=5): its frame
// stores and its vector read.  Asserted at the source, where they can be told
// apart from an older instruction's posted store draining through the same
// port.
always @(posedge clk) if (nreset) begin
	if (dut.core.exe_valid && dut.core.exe_o.exc && dut.core.exe_o.st_v &&
	    dut.core.exe_o.st_fc !== 3'd5) begin
		errors = errors + 1;
		$display("FAIL: exception frame store used FC=%0d, expected 5",
		         dut.core.exe_o.st_fc);
		result = 2;
	end
	if (shim_in_exc && dut.core.u_eaf.rd_req && dut.core.u_eaf.rd_fc !== 3'd5) begin
		errors = errors + 1;
		$display("FAIL: exception vector read used FC=%0d, expected 5",
		         dut.core.u_eaf.rd_fc);
		result = 2;
	end
end

// the handler address this entry read from the vector table, held until the
// fetch of its first opcode is seen (the FC check in the bus monitor)
reg  [31:0] exc_target = 0;
reg         exc_target_v = 0;
always @(posedge clk)
	if (!nreset) exc_target_v <= 1'b0;
	else if (shim_in_exc && dut.core.u_eaf.x_step == 3'd4) begin
		exc_target   <= dut.core.u_eaf.x_target;
		exc_target_v <= 1'b1;
	end
wire  [3:0] shim_exc_fmt = 4'd0;
wire [31:0] shim_pc = debug_status[31:0], shim_exc_spc = 32'd0;
wire [15:0] shim_ir = 16'd0;
wire        shim_m_issued = 1'b0;
wire        shim_mem_req = dut.mem_req, shim_mem_instr = dut.mem_instr, shim_mem_write = dut.mem_write;
wire        shim_mem_ack = dut.mem_ack, shim_mem_flt = dut.mem_flt;

// (plan M9.T step 4) The two points the cycle-fine IRQ injector ($F144) needs,
// named on THIS pipeline instead of the reference's state numbers 34 and 42:
//   exc_stacking  the exception is writing its frame            (was state 34)
//   exc_vecdone   its vector has been read and the handler's
//                 first fetch is about to go out                (was state 42)
// The reference bench watched a microcoded state machine; EA-fetch's P_EXC
// walk is the same sequence -- x_step 0 writes the frame longwords, 3 reads
// the vector, 4 dispatches the final micro-op that redirects to the handler.
wire        exc_stacking = (dut.core.u_eaf.ph == 4'd2) && (dut.core.u_eaf.x_step == 3'd0);
wire        exc_vecdone  = (dut.core.u_eaf.ph == 4'd2) && (dut.core.u_eaf.x_step == 3'd4);
wire  [7:0] exc_vec_now  = dut.core.u_eaf.x_vec;

wire [31:0] dbg_pc = debug_status[31:0];

wire [15:0] dbg_ir = debug_status[63:48];
reg  [7:0]  prev_core_state;
always @(posedge clk) if (shim_ce) prev_core_state <= shim_state;

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

// $F158: a SLOW INTERRUPT-ENABLE register, modelled on the board's
// Enable() -- `move.w #$C000,$DFF09A`, an uncached chip-bus write that holds
// the core's WB for a whole 7 MHz cycle while Paula, which latches INTENA
// part way through that cycle, raises IPL before the CPU has its
// acknowledge.  A word write here takes SLOW_LAT clocks to acknowledge, and
// the IPL lines rise to data[2:0] data[15:8] clocks into it (at the
// acknowledge if that is later).  (2026-09-23 black-screen hunt,
// t_irqwedge_pipe.s shape D.)
localparam SLOW_LAT = 24;
reg  [5:0] slow_cnt  = 0;
reg        slow_done = 0;
reg  [7:0] slow_rise = 0;
reg  [2:0] slow_lvl  = 0;
wire       slow_acc  = nreset && (busstate == 2'b11) && (addr_out[15:0] == 16'hF158);
wire       slow_wait = slow_acc && !slow_done;
always @(posedge clk) begin
	if (!nreset) begin slow_cnt <= 0; slow_done <= 0; end
	else if (slow_acc && !slow_done && slow_cnt == 0 && !mem_ready) begin
		slow_cnt  <= SLOW_LAT;
		slow_rise <= data_write[15:8];
		slow_lvl  <= data_write[2:0];
		if (data_write[15:8] == 0) ipl_lvl <= data_write[2:0];
	end
	else if (slow_cnt != 0) begin
		if (SLOW_LAT - slow_cnt + 1 == slow_rise || slow_cnt == 1 && slow_rise >= SLOW_LAT)
			ipl_lvl <= slow_lvl;
		slow_cnt <= slow_cnt - 1'd1;
		if (slow_cnt == 1) slow_done <= 1;
	end
	else if (!slow_acc) slow_done <= 0;
end

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
		// One physical bus error per arming.  The restarted access
		// succeeds, proving that the adapter released the failed
		// sub-cycle.  Each one-shot clears only itself: a fetch berr
		// must not eat the armed data berr or vice versa.
		if (berr_d) berr_armed  <= 0;
		if (fberr)  fberr_armed <= 0;
		mem_ready <= 0;
		lvl_hold <= 0;
	end
	else if (phase == 2) begin
		// level acknowledge: drops only when the bus is sampled idle
		if (busstate == 2'b01) begin
			mem_ready <= 0;
			lvl_hold <= 0;
		end
		else if (!lvl_hold && !slow_wait) begin
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
	else if (busstate != 2'b01 && !mem_ready && !slow_wait) begin
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

	// $F154: one-shot fetch bus error (see the fberr wire above; the
	// fire-cycle bookkeeping lives in the main berr branch)
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF154) begin
		fberr_armed <= |dut.mem_wdata[15:0];
		fberr_addr  <= dut.mem_wdata[15:0];
	end

	// $F146 arms a one-shot bus error on the NEXT table-walker descriptor
	// access, for the PTEST MMUSR B-bit test.
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF146)
		wberr_arm <= 1;

	// Mode 1 raises IPL during stacking. Mode 2 raises it after the vector
	// has been read and stalls the first handler refill for synchronization.
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF144) begin
		irq_exc_armed <= dut.mem_wdata[1:0];
			`ifdef AP040_TRACE
			$display("TRACE armed exception-time IRQ mode=%0d pc=%h",
			         dut.mem_wdata[1:0], dbg_pc);
			`endif
	end
	else if (irq_exc_armed == 1 && exc_stacking && exc_vec_now == 8'd32) begin
		ipl_lvl <= 3'd2;
		irq_exc_armed <= 0;
			`ifdef AP040_TRACE
			$display("TRACE raised stacking-time IPL2 pc=%h", dbg_pc);
			`endif
	end
	else if (irq_exc_armed == 2 && exc_vecdone && exc_vec_now == 8'd32) begin
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
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF148)
		ipl_delay <= dut.mem_wdata[15:0];
	else if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end

	// phantom-interrupt invariant
	if (ipl_lvl == 3'd0) begin
		if (ipl_idle_for != 16'hffff) ipl_idle_for <= ipl_idle_for + 1'd1;
	end
	else
		ipl_idle_for <= 0;
	irq_seen_q <= exc_accept && shim_exc_is_irq;
	if (exc_accept && shim_exc_is_irq &&
	    ipl_idle_for > 16'd12) begin
		errors = errors + 1;
		$display("FAIL: interrupt accepted %0d cycles after IPL went idle (phantom)",
		         ipl_idle_for);
	end

	// mask invariant: a level 1-6 interrupt is accepted strictly above the
	// SR mask, with exactly one exception: a request that QUALIFIED
	// against the mask while asserted keeps its claim across a later mask
	// raise (IPEND; test 136).  tb_qual below models those claims from
	// the pins alone, so an acceptance at or below the mask without a
	// claim -- e.g. a hold retargeted to a level that never qualified --
	// is a phantom.  State 34 is S_EXC0; sr still holds the pre-exception
	// mask on its first cycle (the throwaway second pass re-enters at
	// S_EXC1, so it cannot trip this).
	if (exc_accept && shim_exc_is_irq &&
	    shim_irq_lvl_l != 3'd7 &&
	    shim_irq_lvl_l <= shim_sr[10:8] &&
	    !tb_qual[shim_irq_lvl_l]) begin
		errors = errors + 1;
		$display("FAIL: level %0d interrupt accepted at or below mask %0d (pc=%h)",
		         shim_irq_lvl_l, shim_sr[10:8], dbg_pc);
	end

	// X2.2 queue invariant (audit 3.5): exception_prefetch issues the
	// first vector-stream word unconditionally, so it must never run
	// while a queue fetch is still outstanding -- the second request
	// would collide with the in-flight one at the bus adapter.  The core
	// enforces this remotely, in S_EXC0's epf_pend wait, so check it
	// here at the point that DEPENDS on it: a future resequencing of the
	// exception path then fails the suite instead of the hardware.
	// State 178 is S_EPF_FILL, reachable only from exception_prefetch
	// and from state 179 (S_EPF_GAP, the word-to-word handshake gap).
	// (M9.T step 4) This one has NO equivalent here and is left inert on
	// purpose: it guards the reference core's `exception_prefetch` queue
	// states (178/179), and this pipeline has no such stage -- IF's
	// prefetch buffer is flushed by the redirect and re-armed by the
	// handler's own fetch.  Named in the plan's bench list so that it is
	// not mistaken for a live check.
	epf_state_q <= shim_state;
	if (nreset && shim_state == 8'd178 && epf_state_q != 8'd178 &&
	    epf_state_q != 8'd179 && shim_epf_pend) begin
		errors = errors + 1;
		$display("FAIL: exception_prefetch entered with a queue fetch outstanding (pc=%h)",
		         dbg_pc);
	end

	// $F14C models a device that WITHDRAWS its request: IPL rises to the
	// written level and drops again after the written number of cycles,
	// without waiting to be acknowledged.  A 68040 requires the request
	// to be held until acknowledged, so nothing may be taken from it.
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF14C) begin
		ipl_lvl   <= dut.mem_wdata[2:0];
		ipl_pulse <= dut.mem_wdata[15:8];
	end
	else if (ipl_pulse != 0) begin
		ipl_pulse <= ipl_pulse - 1'd1;
		if (ipl_pulse == 8'd1) ipl_lvl <= 3'd0;
	end

	// $F150 models TWO devices sharing the IPL encoder: the higher one
	// (bits [2:0]) withdraws after the written number of cycles while a
	// lower one (bits [6:4]) keeps requesting, so the lines DOWNGRADE
	// instead of going idle.  The lower level is a fresh request that is
	// only ever taken if it qualifies against the mask on its own.
	if (nreset && dut.mem_ack && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF150) begin
		ipl_lvl  <= dut.mem_wdata[2:0];
		ipl_next <= dut.mem_wdata[6:4];
		ipl_step <= dut.mem_wdata[15:8];
	end
	else if (ipl_step != 0) begin
		ipl_step <= ipl_step - 1'd1;
		if (ipl_step == 8'd1) ipl_lvl <= ipl_next;
	end
end

// $F170 (read): the length, in clocks, of the last RSTO pulse (the RESET
// instruction's nresetout low time); $F172: how many pulses so far.
// Pipelined bench only (plan M9 subset).
reg [15:0] rsto_len = 0, rsto_cnt = 0, rsto_n = 0;
always @(posedge clk) begin
	if (!nreset) begin rsto_len <= 0; rsto_n <= 0; end
	else if (!nresetout) rsto_len <= rsto_len + 1'd1;
	else if (rsto_len != 0) begin
		mem[16'hF170 >> 1] = rsto_len;
		mem[16'hF172 >> 1] = rsto_n + 1'd1;
		rsto_n <= rsto_n + 1'd1;
		rsto_len <= 0;
	end
end

// A chipset DMA agent (plan M14 step 3: the data read path's snoop rule).
// Word writes: $F1E4 = the target address (low 16 bits), $F1E6 = the data
// word, $F1EA = 1 to suppress the snoop (memory changed behind the caches'
// backs, as uncached I/O or a disabled cache sees it), and $F1E8 = N arms
// it: N clocks later the agent writes mem[] directly and, unless
// suppressed, pulses cache_snoop_stb with the address for one clock -- the
// shape sdram_ctrl gives the wrapper on hardware.
// (dma_* are declared ahead of the wrapper instance, which uses them)
always @(posedge clk) begin
	dma_snp <= 1'b0;
	if (!nreset) dma_arm <= 1'b0;
	else begin
		if (dut.mem_ack && dut.mem_write && dut.mem_addr[15:0] == 16'hF1E4) dma_a <= dut.mem_wdata[15:0];
		if (dut.mem_ack && dut.mem_write && dut.mem_addr[15:0] == 16'hF1E6) dma_d <= dut.mem_wdata[15:0];
		if (dut.mem_ack && dut.mem_write && dut.mem_addr[15:0] == 16'hF1EA) dma_nosnp <= dut.mem_wdata[0];
		if (dut.mem_ack && dut.mem_write && dut.mem_addr[15:0] == 16'hF1E8) begin
			dma_arm <= 1'b1; dma_n <= dut.mem_wdata[15:0];
		end else if (dma_arm) begin
			if (dma_n == 16'd0) begin
				dma_arm <= 1'b0;
				mem[dma_a[15:1]] = dma_d;
				dma_snp <= !dma_nosnp;
			end else dma_n <= dma_n - 16'd1;
		end
	end
end

// $F1F4 (write): a counting register for stores -- every store to it that
// the core completes adds one to the word at $F1F6 (a strobe register, like
// COPJMP: a store issued twice fires twice).  Pipelined bench only.
reg wrcnt_ack_q = 0;
always @(posedge clk) begin
	wrcnt_ack_q <= dut.mem_ack;
	if (nreset && dut.mem_ack && !wrcnt_ack_q && dut.mem_write &&
	    dut.mem_addr[15:0] == 16'hF1F4)
		mem[16'hF1F6 >> 1] = mem[16'hF1F6 >> 1] + 1'd1;
end

// $F180 (read): a counting register -- every data read of it that the
// memory port completes adds one to the word at $F182 (a read with a side
// effect, like a CIA's ICR; t_irq_pipe.s checks that an interrupt never
// makes the core read an operand twice).  Pipelined bench only.
reg rdcnt_ack_q = 0;
always @(posedge clk) begin
	rdcnt_ack_q <= dut.mem_ack;
	if (nreset && dut.mem_ack && !rdcnt_ack_q && !dut.mem_write && !dut.mem_instr &&
	    dut.mem_addr[15:0] == 16'hF180)
		mem[16'hF182 >> 1] = mem[16'hF182 >> 1] + 1'd1;
	// (M14 step 3) a read the data read path answers completes the same
	// read without a mem_ack: count it too
	if (nreset && dut.ce_core && dut.core.g_bus.d_rd_fast &&
	    dut.core.g_bus.u_bcu.dq_a[15:0] == 16'hF180)
		mem[16'hF182 >> 1] = mem[16'hF182 >> 1] + 1'd1;
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
		// (M9.T step 4) The FETCH half of this rule had to be restated for a
		// pipelined core.  The reference asserted that ANY fetch during its
		// exception states is the handler's first opcode, which is true of a
		// microcoded core that stops fetching while it stacks.  Here IF keeps
		// prefetching the INTERRUPTED stream until the entry's redirect goes
		// out, and if that stream was user code its FC is 2, correctly.  So
		// the check is aimed at the fetch it was always about: the one at the
		// handler's entry address, which `exc_target` captures from the
		// vector read.
		// The DATA half had to move off the bus for the same reason: a
		// posted store from the interrupted (user-mode) instruction can
		// still be draining while the entry stacks, and FC=1 is right for
		// it.  The rule is about the EXCEPTION's own cycles, so it is
		// asserted where they are issued -- see `exc_fc_*` below.

		if (exc_target_v && busstate == 2'b00 && addr_out[31:2] == exc_target[31:2]) begin
			exc_target_v <= 1'b0;
			if (fc !== 3'd6) begin
				errors = errors + 1;
				$display("FAIL: exception handler fetch at %h used FC=%0d, expected 6",
				         addr_out, fc);
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
					errors = errors + 1;					$display("FAIL: program reports failure, test %0d (phase %0d, pc=%h, ill=%0d, addr=%0d)",
					         mem[16'hF100 >> 1], phase, dbg_pc,
					         mem[16'h3602 >> 1], mem[16'h361E >> 1]);
					// t_exceptions stamps $3670 with the handler that
					// rejected a frame, so a shared hfail is still
					// attributable (X2.3a).
					if (mem[16'hF100 >> 1] == 98) begin
						$display("     hfail from handler id %0d",
						         mem[16'h3670 >> 1]);
						$display("     berr fault addr=%04x%04x stacked pc=%04x%04x armed=%04x%04x",
						         mem[16'h3674 >> 1], mem[16'h3676 >> 1],
						         mem[16'h3678 >> 1], mem[16'h367A >> 1],
						         mem[16'h3654 >> 1], mem[16'h3656 >> 1]);
					end
					result = 2;
				end
			end
			// $F108: cycle-stamp marker.  Writing a tag prints the clk
			// count since the previous stamp, so a program can bracket a
			// block of instructions and get its cost without a waveform.
			// Used by the FPU latency probe (hw/fptime.s).
			if (addr_out[15:0] == 16'hF108) begin
				$display("STAMP tag=%04x cycles=%0d", data_write,
				         clkcount - stamp_prev);
				stamp_prev = clkcount;
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

// Locked-RMW indivisibility (plan section 8): once a data read has
// completed inside a TAS/CAS/CAS2 (lk_cyc), no instruction fetch may
// appear on the bus until the locked write completes.  Further reads are
// legal (misaligned splits, CAS2's second operand, a memory-indirect
// pointer), and a fault path disarms at its first frame write.  This
// catches a background queue fetch issued between the locked read and
// the locked write.
reg lk_window = 0;
always @(posedge clk) begin
	if (!nreset) lk_window <= 0;
	else begin
		if (mem_ready && busstate == 2'b10 && shim_lk_cyc)
			lk_window <= 1;
		else if (mem_ready && busstate == 2'b11)
			lk_window <= 0;
		// A locked sequence can also end WITHOUT a write: CAS/CAS2 whose
		// comparison fails performs no memory write, and a faulted one is
		// abandoned.  lk_cyc is held from decode to fetch_next across the
		// whole indivisible sequence, so once it drops the sequence is over
		// and the next fetch is legal.  Closing only on the write reported
		// every failed CAS as a violation.
		else if (!shim_lk_cyc)
			lk_window <= 0;
		if (lk_window && busstate == 2'b00) begin
			errors = errors + 1;
			$display("FAIL: instruction fetch inside a locked RMW (pc=%h addr=%h state=%0d lk=%b epf_pend=%b ir=%04x)",
			         dbg_pc, addr_out, shim_state, shim_lk_cyc,
			         shim_epf_pend, dbg_ir);
			lk_window <= 0;
		end
	end
end

// unexpected halt detection
always @(posedge clk) begin
	if (nreset && (debug_fault || debug_halted) && result == 0) begin
		errors = errors + 1;
		$display("FAIL: core halted, fault=%b pc=%h ir=%h prev_state=%0d in_exc=%b mem_flt=%b",
		         debug_fault, dbg_pc, dbg_ir, prev_core_state, shim_in_exc,
		         shim_mem_flt);
		// the last failure code the program managed to report, if any --
		// a halt after a failed report leaves the real code visible here
		$display("  failcode=%04x", mem[16'hF100 >> 1]);
		result = 2;
	end
end

`ifdef AP040_TRACE
always @(posedge clk) if (nreset && shim_ce) begin
	if (shim_state == 7'd4)
		$display("TRACE decode pc=%h ir=%h sr=%h in_exc=%b", shim_pc,
		         shim_ir, shim_sr, shim_in_exc);
	if (shim_state == 7'd34)
		$display("TRACE exc vec=%0d fmt=%0d spc=%h", shim_exc_vec, shim_exc_fmt, shim_exc_spc);
end
always @(posedge clk) if (nreset && mem_ready && busstate == 2'b11 &&
                          addr_out >= 32'h3600 && addr_out < 32'h3640)
	$display("TRACE cntwr addr=%h data=%h uds=%b lds=%b", addr_out, data_write, nuds, nlds);
`endif

//---------------------------------------------------------------------------
// phase driver
//---------------------------------------------------------------------------

// +prof: per-state cycle histogram -- the tb_prof the plan's cycle
// claims come from (X2.8).  Counts every clk cycle by core state; the
// stall column is the subset spent with clkena_in low (bus wait).
// Printed and cleared at the end of each phase.
integer prof_cnt [0:255];
integer prof_stall [0:255];
integer prof_on = 0;

// +memlat: request-to-acknowledge latency for the core's memory port,
// split by operation class.  S_MRD costs ~7.6 cycles on a CACHED load
// while stalling on the bus for only 12% of them, so the round trip
// through the MMU and cache -- not the wait for memory -- is what the
// core is paying.  This measures that path directly, per class, which
// is the prerequisite the plan sets before touching the handshake.
integer memlat_on = 0;
integer memlat_run;            // cycles since the current request went out
integer memlat_n    [0:2];     // 0 = ifetch, 1 = data read, 2 = data write
integer memlat_sum  [0:2];
integer memlat_max  [0:2];
integer memlat_hist [0:2][0:31];
integer memlat_cls;
integer mli, mlj;
// How much of S_MRD/S_MWR is spent waiting for the fetch queue to give
// the shared memory port back, rather than waiting for memory itself.
// (These two are the reference core's shape and have no equivalent here;
//  the pipelined port-conflict counters below replace them -- plan M11.)
integer memlat_portwait;
integer memlat_mrd;
// (plan M11 / the M14 gate) THE PORT CONFLICT, measured the other way round:
// in this core IF is the LOWEST priority user of the shared memory port
// (ap040_pipe_bcu.v: split byte > store > data read > instruction fetch), so
// what matters is how often IF wants the port and a DATA access has it.
//   if_want   cycles with a fetch request asserted
//   if_denied ... of which the port was not granted to it
//   prof_total cycles the profile covers
// The plan's gate: if the denial is more than 15 % of all cycles, the split
// I/D caches of M14 are justified.
integer if_want, if_denied, prof_total;
integer pi;
initial begin
	prof_on = $test$plusargs("prof");
	memlat_on = $test$plusargs("memlat");
	memlat_run = -1;
	memlat_portwait = 0;
	memlat_mrd = 0;
	if_want = 0; if_denied = 0; prof_total = 0;
	for (mli = 0; mli < 3; mli = mli + 1) begin
		memlat_n[mli] = 0; memlat_sum[mli] = 0; memlat_max[mli] = 0;
		for (mlj = 0; mlj < 32; mlj = mlj + 1) memlat_hist[mli][mlj] = 0;
	end
	for (pi = 0; pi < 256; pi = pi + 1) begin
		prof_cnt[pi] = 0;
		prof_stall[pi] = 0;
	end
end
always @(posedge clk) if (memlat_on && nreset) begin
	// state 9 = S_MRD, 10 = S_MWR
	if (shim_state == 8'd9 || shim_state == 8'd10) begin
		memlat_mrd = memlat_mrd + 1;
		if (!shim_m_issued && shim_epf_pend)
			memlat_portwait = memlat_portwait + 1;
	end
	if (shim_mem_req && memlat_run < 0) begin
		// request just went out: classify it and start counting
		memlat_run <= 0;
		memlat_cls <= shim_mem_instr ? 0 : (shim_mem_write ? 2 : 1);
	end
	else if (memlat_run >= 0) begin
		if (shim_mem_ack) begin
			memlat_n[memlat_cls]   = memlat_n[memlat_cls] + 1;
			memlat_sum[memlat_cls] = memlat_sum[memlat_cls] + memlat_run + 1;
			if (memlat_run + 1 > memlat_max[memlat_cls])
				memlat_max[memlat_cls] = memlat_run + 1;
			memlat_hist[memlat_cls][(memlat_run + 1) > 31 ? 31 : memlat_run + 1] =
				memlat_hist[memlat_cls][(memlat_run + 1) > 31 ? 31 : memlat_run + 1] + 1;
			memlat_run <= -1;
		end
		else memlat_run <= memlat_run + 1;
	end
end

always @(posedge clk) if ((prof_on || memlat_on) && nreset) begin
	prof_total = prof_total + 1;
	if (dut.core.g_bus.u_bcu.f_req) begin
		if_want = if_want + 1;
		// "denied" means DATA has the port, not that IF's own previous
		// fetch is still in flight -- the gate is about the conflict
		// between the two users, so the port being busy with an
		// instruction fetch does not count against it.
		if (!dut.core.g_bus.u_bcu.go_if &&
		    !(dut.core.mem_req && dut.core.mem_instr)) if_denied = if_denied + 1;
	end
end
always @(posedge clk) if (prof_on && nreset) begin
	prof_cnt[shim_state] = prof_cnt[shim_state] + 1;
	if (!clkena_in)
		prof_stall[shim_state] = prof_stall[shim_state] + 1;
end

task memlat_dump;
	input integer ph;
	integer c, b;
	begin
		// (M11) the pipelined port-conflict profile, which is the M14 gate
		$display("PORTCONF phase %0d: %0d cycles, IF wanted the port %0d (%0d%%), denied %0d (%0d%% of all cycles, %0d%% of its own requests)",
		         ph, prof_total, if_want,
		         (prof_total == 0) ? 0 : (if_want * 100) / prof_total,
		         if_denied,
		         (prof_total == 0) ? 0 : (if_denied * 100) / prof_total,
		         (if_want == 0) ? 0 : (if_denied * 100) / if_want);
		if_want = 0; if_denied = 0; prof_total = 0;
		memlat_mrd = 0; memlat_portwait = 0;
		for (c = 0; c < 3; c = c + 1) begin
			if (memlat_n[c] != 0) begin
				$display("MEMLAT phase %0d %0s: n=%0d avg=%0d.%0d max=%0d",
				         ph,
				         (c == 0) ? "ifetch " : (c == 1) ? "dataread" : "datawrite",
				         memlat_n[c],
				         memlat_sum[c] / memlat_n[c],
				         (memlat_sum[c] * 10 / memlat_n[c]) % 10,
				         memlat_max[c]);
				for (b = 0; b < 32; b = b + 1)
					if (memlat_hist[c][b] != 0)
						$display("MEMLAT     %0d cyc: %0d", b, memlat_hist[c][b]);
			end
			memlat_n[c] = 0; memlat_sum[c] = 0; memlat_max[c] = 0;
			for (b = 0; b < 32; b = b + 1) memlat_hist[c][b] = 0;
		end
	end
endtask

task prof_dump;
	input integer ph;
	integer total, fetch_immf;
	begin
		total = 0;
		for (pi = 0; pi < 256; pi = pi + 1) total = total + prof_cnt[pi];
		$display("PROF phase %0d: %0d cycles total", ph, total);
		for (pi = 0; pi < 256; pi = pi + 1)
			if (prof_cnt[pi] != 0)
				$display("PROF   state %0d: %0d (%0d stalled)",
				         pi, prof_cnt[pi], prof_stall[pi]);
		fetch_immf = prof_cnt[8'd3] + prof_cnt[8'd8];
		$display("PROF   S_FETCH+S_IMMF occupancy: %0d / %0d = %0d%%",
		         fetch_immf, total, (fetch_immf * 100) / total);
		for (pi = 0; pi < 256; pi = pi + 1) begin
			prof_cnt[pi] = 0;
			prof_stall[pi] = 0;
		end
	end
endtask

integer timeout;
integer timeout_lim;   // +timeout=<clocks> per phase (default 20M): a wedged core fails fast
integer i;

task run_phase;
	input integer ph;
	begin
		phase   = ph;
		result  = 0;
		ipl_lvl = 0;
		irq_exc_armed = 0;
		irq_fetch_stall = 0;
		fberr_armed = 0;

		for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
		$readmemh(prog_file, mem);
		// interrupt-injection capability word: t_fpu's IRQ soak runs
		// only where the bench can deliver IPL
		mem[16'hF160 >> 1] = 16'h0007;	// coarse + fine IPL + berr injection

		nreset = 0;
		repeat (10) @(posedge clk);
		nreset = 1;

		timeout = 0;
		while (result == 0 && timeout < timeout_lim) begin
			@(posedge clk);
			timeout = timeout + 1;
		end

		if (result == 0) begin
			errors = errors + 1;
			$display("FAIL: phase %0d timeout, pc=%h ir=%h fault=%b halted=%b",
			         ph, dbg_pc, dbg_ir, debug_fault, debug_halted);
			// where the pipeline stands: a wedge with no request pending
			// is an internal hand-off, not a bus hang (2026-09-23)
			$display("      EA-fetch ph=%0d pc=%08h valid=%b irq_req=%b irq_take=%b mem_req=%b older_busy=%b",
			         dut.core.u_eaf.ph, dut.core.dbg_eac_pc, dut.core.eac_valid,
			         dut.core.irq_req, dut.core.u_eaf.irq_take, dut.core.mem_req, dut.core.older_busy);
		end
		else if (result == 1)
			$display("phase %0d passed (%0d cycles)", ph, timeout);
		if (prof_on) prof_dump(ph);
		if (memlat_on) memlat_dump(ph);
	end
endtask

initial begin
	errors = 0;
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_ap040_program: running %0s", prog_file);
	if (!$value$plusargs("timeout=%d", timeout_lim)) timeout_lim = 20000000;

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
