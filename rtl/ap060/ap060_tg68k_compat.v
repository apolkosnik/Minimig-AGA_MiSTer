//--------------------------------------------------------------------------//
// ap060_tg68k_compat.v - the AP68060 in TG68K's place in cpu_wrapper       //
//                                                                          //
// The processor runs on clk_cpu (pll_cpu, unrelated to cpu_wrapper's clk)  //
// with BCLK = CLK.  Its bus is answered in two halves:                     //
//                                                                          //
//   clk_cpu  the 68060 bus (MC68060UM section 7): a transfer is latched on //
//            the clock TS is sampled, its write data the clock after (the  //
//            processor drives D31-D0 from then until TA); acknowledge      //
//            transfers (TT = 3) end in TA with AVEC (Minimig's interrupts   //
//            are autovectored): an interrupt acknowledge (a read, TM = the  //
//            level) first runs TG68K's acknowledge read on the Minimig bus, //
//            $FFFFFFF0 + level * 2 -- the Action Replay/HRTmon cartridge    //
//            arms on level 7's and drops its NMI request with it; the       //
//            breakpoint acknowledge and LPSTOP are answered here.  The rest //
//            go to the other half with a request                           //
//            toggle, and TA ends them the clock after its answer toggle     //
//            arrives.  A line (SIZ = line: cache fills, pushes, MOVE16)    //
//            gets TBI with that TA, so the processor runs the rest of it as //
//            long-word transfers (7.7.2); reads outside Fast RAM and       //
//            Kickstart ROM get TCI: chip RAM, I/O and the RTG frame buffer //
//            are never cached, so chipset DMA cannot leave a stale line in  //
//            the 68060                                                      //
//   clk      cpu_wrapper's 16-bit accesses, as TG68KdotC_Kernel makes them: //
//            a byte or word is one, a long word two (A, then A + 2, with    //
//            longword high on the first, as TG68K does: Gayle's 32-bit IDE //
//            data port latches it there); an access completes on the clock //
//            clkena_in is high, the next one or the idle bus state is       //
//            presented from the next clock                                  //
//                                                                          //
// The halves cross with toggles through three-stage synchronisers; each    //
// side holds its fields (address, size, write data; read data) steady from  //
// its toggle until the other side answers it, so only the toggles need     //
// synchronising (Minimig.sdc: the clocks are asynchronous).  Reset, RSTO, //
// VBR and the Fast RAM windows cross through synchronisers of their own   //
// (VBR and the windows change only by MOVEC and autoconfiguration); IPL  //
// goes straight to the core, which synchronises and debounces it itself. //
//                                                                          //
// The 68060 bus is aligned: a long word never crosses a long-word         //
// boundary, a word never an odd address.  Read data goes back on both    //
// halves of D31-D0, so a byte or word reaches the lanes its address      //
// selects.  There is one bus master: the arbitration inputs grant the    //
// bus and the bus-busy inputs see the processor's own outputs.  No        //
// transfer ends in TEA; Minimig has no bus error.  During reset IPL2-IPL0 //
// and D15-D0 carry the reset modes (7.14): all negated / zero.             //
//--------------------------------------------------------------------------//

module ap060_tg68k_compat #(
	parameter NO_FPU = 1,              // the MC68LC060
	// on-board debug capture, read over JTAG (In-System Sources and Probes,
	// instance "A060"; tests/ap060/ap060_dbgread.tcl): a live view of the
	// processor and of both halves of the bus crossing, and the last 64
	// transfers.  A few hundred ALMs and one M10K.
	parameter DEBUG_CAPTURE = 0
)(
	input             clk,
	input             clk_cpu,         // the processor's clock, unrelated to clk
	input             nreset,          // active low, cpu_wrapper's reset (clk)
	input             clkena_in,       // the current access completes this clock
	input      [15:0] data_in,
	input       [2:0] ipl,             // active low
	output reg [31:0] addr_out,
	output reg [15:0] data_write,
	output reg        nwr,
	output reg        nuds,
	output reg        nlds,
	output            nresetout,
	output reg        longword,
	output reg  [1:0] busstate,        // 0: fetch code, 1: no memaccess, 2: read data, 3: write data
	output      [3:0] cacr_out,
	output            d_cache_out,
	output     [31:0] vbr_out,

	// the Fast RAM windows as autoconfiguration placed them (cachable)
	input             z2ram_ena,
	input       [4:0] z3ram_base0,
	input             z3ram_ena0,
	input       [3:0] z3ram_base1,
	input             z3ram_ena1,

	// Fast RAM: the processor's own port into DDR3 (ap030_fastram_fe/_be,
	// as the AP68030's Minimig integration): an Avalon-MM master on clk_mem
	input             clk_mem,
	input             fr_dma_wr,       // (clk_mem) a DMA write reached Fast RAM's DDR3
	output     [28:0] fr_address,
	output      [7:0] fr_burstcount,
	output            fr_read,
	output            fr_write,
	output     [63:0] fr_writedata,
	output      [7:0] fr_byteenable,
	input             fr_waitrequest,
	input      [63:0] fr_readdata,
	input             fr_readdatavalid
);

localparam BS_FETCH = 2'b00, BS_IDLE = 2'b01, BS_READ = 2'b10, BS_WRITE = 2'b11;
localparam SIZ_L = 2'b00, SIZ_B = 2'b01, SIZ_W = 2'b10, SIZ_LINE = 2'b11;

//--------------------------------------------------------------------------
// synchronisers into clk_cpu
//--------------------------------------------------------------------------
reg  [2:0] nreset_c = 3'b000;          // reset, asserted at once, released synchronised
always @(posedge clk_cpu or negedge nreset)
	if (!nreset) nreset_c <= 3'b000;
	else         nreset_c <= {nreset_c[1:0], 1'b1};
wire nrst_c = nreset_c[2];

reg  [1:0] z2e_c = 0, z3e0_c = 0, z3e1_c = 0;
reg  [4:0] z3b0_c1 = 0, z3b0_c = 0;
reg  [3:0] z3b1_c1 = 0, z3b1_c = 0;
// IPL goes to the processor as it is: the core synchronises IPL2-IPL0 on
// its clock and takes a level only once two consecutive samples agree
// (MC68060UM 7.8.1), so the bits settling in different clocks cannot show
// it a level nobody raised.  (Simulation: AP060_SIM_IPL_SKEW delays IPL0,
// as a bit that resolves a clock late on the FPGA would; tests/ap060
// t_iplglitch.)
`ifdef AP060_SIM_IPL_SKEW
wire       ipl0_late;
assign #(`AP060_SIM_IPL_SKEW) ipl0_late = ipl[0];
wire [2:0] ipl_in = {ipl[2:1], ipl0_late};
`else
wire [2:0] ipl_in = ipl;
`endif
always @(posedge clk_cpu) begin
	z2e_c   <= {z2e_c[0], z2ram_ena};
	z3e0_c  <= {z3e0_c[0], z3ram_ena0};
	z3e1_c  <= {z3e1_c[0], z3ram_ena1};
	z3b0_c1 <= z3ram_base0;  z3b0_c <= z3b0_c1;
	z3b1_c1 <= z3ram_base1;  z3b1_c <= z3b1_c1;
end

//--------------------------------------------------------------------------
// the processor
//--------------------------------------------------------------------------
wire [31:0] a_o, d_o, cacr, vbr, dbg_pc;
wire        dbg_retire, dbg_halted;
wire        d_oe, rw_n, ts_n, rsto_n, ciout_n;
wire  [1:0] siz, tt;
wire  [2:0] tm;
wire  [3:0] bs_n;
wire        bb_n_o, bb_oe, btt_n_o, btt_oe;
reg  [31:0] d_i;
reg         ta_n, tbi_n, tci_n, avec_n;

ap68060 #(.NO_FPU(NO_FPU)) cpu (
	.clk(clk_cpu), .bclk_en(1'b1), .rsti_n(nrst_c),
	.a_o(a_o), .a_oe(), .a_i(a_o), .ts_n_i(1'b1), .tt_i(tt), .snoop_n(1'b1),
	.d_i(nrst_c ? (f_doe ? f_d : d_i) : 32'd0), .d_o(d_o), .d_oe(d_oe),
	.rw_n(rw_n), .siz(siz), .bs_n(bs_n), .tt(tt), .tm(tm), .tln(), .upa(),
	.ciout_n(ciout_n), .lock_n(), .locke_n(), .lock_oe(),
	.ts_n(ts_n), .tip_n(), .tip_oe(), .sas_n(), .sas_oe(),
	.ta_n(ta_n & f_ta_n), .tea_n(1'b1), .tra_n(1'b1), .tci_n(tci_n), .tbi_n(tbi_n), .cla_n(1'b1),
	.ipl_n(nrst_c ? ipl_in : 3'b111), .avec_n(avec_n),
	.br_n(), .bg_n(1'b0), .bgr_n(1'b1),
	.bb_n_i(bb_oe ? bb_n_o : 1'b1), .bb_n_o(bb_n_o), .bb_oe(bb_oe),
	.btt_n_i(btt_oe ? btt_n_o : 1'b1), .btt_n_o(btt_n_o), .btt_oe(btt_oe),
	.rsto_n(rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(),
	.dbg_pc(dbg_pc), .dbg_retire(dbg_retire), .dbg_halted(dbg_halted), .dbg_vbr(vbr), .dbg_cacr(cacr)
);

// RSTO and VBR into clk (VBR: MOVEC only; nmi_addr in cpu_wrapper)
reg  [1:0] rsto_k = 2'b11;
reg [31:0] vbr_k1 = 0, vbr_k = 0;
always @(posedge clk) begin
	rsto_k <= {rsto_k[0], rsto_n};
	vbr_k1 <= vbr;  vbr_k <= vbr_k1;
end
assign nresetout = rsto_k[1];
assign vbr_out   = vbr_k;

// cpu_wrapper's cache controls (TG68K's CACR) drive the memory controllers'
// own caches (cpu_cache_new in sdram_ctrl and ddram_ctrl).  Those are always
// on here, not tied to the 68060's CACR: a controller cache with its data
// side off neither fills nor updates its lines on stores, so turning it off
// and on again (exec and 68060.library switch EDC) would bring back lines
// older than memory -- and on a 68060 nothing can clear it (TG68K's CACR
// clear bit, cacr_out[3], has no 68060 counterpart).  They snoop chipset
// DMA and see every processor store, so they need no management.
assign cacr_out    = 4'b0001;
assign d_cache_out = 1'b1;

//--------------------------------------------------------------------------
// the crossing: two request slots, used in turn.  The clk_cpu half fills a
// slot (address, size, direction, write data: a whole line for a push) and
// flips its request toggle; the clk half runs the slots' 16-bit accesses
// in the same order and flips the slot's answer toggle when it is done.
// A slot's fields stay put from its request until its answer, so only the
// toggles cross (two-stage synchronisers).  A write is acknowledged once
// its data is in the slot (posted): the processor goes on while the clk
// half writes it, and a second transfer can be queued behind it.  A read
// waits for its own answer, which comes after every write queued before it.
//--------------------------------------------------------------------------
reg  [31:0] sa   [0:1];            // address as driven with TS
reg   [1:0] ssiz [0:1];
reg         srd  [0:1];
reg         scode[0:1];            // TM: user / supervisor code
reg         siack[0:1];            // an interrupt acknowledge
reg [127:0] swd  [0:1];            // write data, by long word address A3-A2
reg   [1:0] p_tgl = 2'b00;         // request toggles (clk_cpu)
reg   [1:0] k_tgl = 2'b00;         // answer toggles (clk)
reg [127:0] k_rd;                  // read data, by long word address (clk)

//--------------------------------------------------------------------------
// clk_cpu: the 68060 bus
//--------------------------------------------------------------------------
localparam C_IDLE = 4'd0, C_ALLOC = 4'd1, C_WBEAT = 4'd2, C_WAIT = 4'd3,
           C_RBEAT = 4'd4, C_ACK = 4'd5;
reg   [3:0] cst;
reg         xfast;                 // the transfer is ap060_fastram's (debug capture)
reg  [31:0] xa;                    // the transfer on the bus (TS to its last TA)
reg   [1:0] xsiz;
reg         xrd, xcode, xiack;
reg         ws = 1'b0;             // the slot the next transfer takes
reg         rs;                    // the slot a read waits for
reg   [1:0] beat;                  // line beats done
reg  [31:0] wd;                    // (debug capture: the write beat's data)
reg   [1:0] k_tgl_c1 = 2'b00, k_tgl_c = 2'b00;
always @(posedge clk_cpu) begin k_tgl_c1 <= k_tgl; k_tgl_c <= k_tgl_c1; end
wire  [1:0] busy = p_tgl ^ k_tgl_c;

// cachable: Fast RAM (Zorro II $200000-$9FFFFF, the Zorro III windows) and
// Kickstart ROM ($F80000-$FFFFFF, $E00000-$E7FFFF)
wire c_z2   = z2e_c[1] && (xa[31:24] == 8'h00) && (xa[23] ^ |xa[22:21]);
wire c_z30  = z3e0_c[1] && (xa[31:27] == z3b0_c);
wire c_z31  = z3e1_c[1] && (xa[31:28] == z3b1_c);
wire c_rom  = (xa[31:19] == 13'h001F) || (xa[31:19] == 13'h001C);
wire x_cach = c_z2 | c_z30 | c_z31 | c_rom;

// a line's beats go A3-A2 first, then on modulo four (MC68060UM 7.7.2)
wire  [1:0] lw   = xa[3:2] + beat;
wire [31:0] rd_l = k_rd[127 - 32 * lw -: 32];

//--------------------------------------------------------------------------
// Fast RAM: the processor's own port (ap030_fastram_fe's native port, on
// clk_cpu), never through cpu_wrapper.  Not CPU space (TT = 3), and not
// the NMI vector read (VBR + $7C, a data read): that stays on the Minimig
// bus, where the cartridge (HRTmon) overlays it, as for every other CPU.
//--------------------------------------------------------------------------
wire [31:0] nmi_vec = vbr + 32'h7C;
wire ts_z30  = (a_o[31:27] == z3b0_c) && z3e0_c[1];
wire ts_z31  = (a_o[31:28] == z3b1_c) && z3e1_c[1];
wire ts_z2   = (a_o[31:24] == 8'h00) && (a_o[23] ^ |a_o[22:21]) && z2e_c[1];
wire ts_nmi  = rw_n && (tm == 3'd1 || tm == 3'd5) && (a_o[31:2] == nmi_vec[31:2]);
wire ts_fast = (tt != 2'd3) && !ts_nmi && (ts_z30 || ts_z31 || ts_z2);

// the processor's DDR3 word address, as memory_router maps Zorro RAM for
// ddram_ctrl (ramaddr; ddram_ctrl's 64-bit word is {3'b001, ramaddr[28:3]})
wire [28:1] ts_ramaddr = {ts_z2 | ts_z31, ts_z30 | (ts_z31 & a_o[27]),
                          (ts_z30 | ts_z31) ? a_o[26:23] : 4'd0, a_o[22:1]};
wire        f_ta_n, f_doe, f_busy;
wire [31:0] f_d;

// DMA into Fast RAM (Akiko, CDTV through chipdma_arb and ddram_ctrl): the
// Fast RAM port's own cache is below the 68060's and invisible to its cache
// instructions, so each DMA write clears it.  A write keeps a level up for
// eight clk_mem cycles (two processor clocks at least, so none is missed and
// writes in a row merge); held high, the clear restarts the sweep and lets
// no fill allocate, so the cache refills only from DDR3 that holds them all.
reg   [3:0] dma_hold = 4'd0;
always @(posedge clk_mem) dma_hold <= fr_dma_wr ? 4'd8 : (dma_hold != 4'd0) ? dma_hold - 4'd1 : 4'd0;
reg   [1:0] dma_clr_c = 2'b00;
always @(posedge clk_cpu) dma_clr_c <= {dma_clr_c[0], dma_hold != 4'd0};

ap060_fastram fastram (
	.clk(clk_cpu), .clk_mem(clk_mem), .rst(!nrst_c), .bclk_en(1'b1), .clear(dma_clr_c[1]),
	// (reset modes: no ignore states, no extra write hold -- as the core
	// is reset here, IPL and D15-D0 all negated / zero)
	.m_ign(1'b0), .m_cnt(16'd0), .m_hold(1'b0),
	.a(a_o), .rw_n(rw_n), .siz(siz), .tt(tt), .tm(tm), .bs_n(bs_n), .ts_n(ts_n), .ciout_n(ciout_n),
	.d_cpu(d_o), .sel(ts_fast), .ddr_addr({3'b001, ts_ramaddr[28:3]}),
	.ta_n(f_ta_n), .d_o(f_d), .d_oe(f_doe), .busy(f_busy),
	.avm_address(fr_address), .avm_burstcount(fr_burstcount), .avm_read(fr_read), .avm_write(fr_write),
	.avm_writedata(fr_writedata), .avm_byteenable(fr_byteenable), .avm_waitrequest(fr_waitrequest),
	.avm_readdata(fr_readdata), .avm_readdatavalid(fr_readdatavalid)
);

// a transfer driven with TS this clock
task take_ts;
	begin
		xa    <= a_o;
		xsiz  <= siz;
		xrd   <= rw_n;
		xcode <= (tm == 3'd2) || (tm == 3'd6);
		xiack <= 1'b0;
		xfast <= ts_fast;
		beat  <= 2'd0;
		if (tt == 2'd3 && rw_n && tm != 3'd0) begin
			// interrupt acknowledge: TG68K's acknowledge read, a word at
			// $FFFFFFF0 + level * 2, then TA with AVEC
			xa    <= {28'hFFFFFFF, tm, 1'b0};
			xsiz  <= SIZ_W;
			xcode <= 1'b0;
			xiack <= 1'b1;
			cst   <= C_ALLOC;
		end
		else if (tt == 2'd3) begin
			// breakpoint acknowledge, LPSTOP: answered here
			ta_n   <= 1'b0;
			avec_n <= 1'b0;
			d_i    <= 32'd0;
			cst    <= C_ACK;
		end
		else cst <= ts_fast ? C_IDLE : C_ALLOC;      // Fast RAM: ap060_fastram answers
	end
endtask

always @(posedge clk_cpu or negedge nrst_c) begin
	if (!nrst_c) begin
		cst    <= C_IDLE;
		ta_n   <= 1'b1;
		tbi_n  <= 1'b1;
		tci_n  <= 1'b1;
		avec_n <= 1'b1;
		d_i    <= 32'd0;
		p_tgl  <= 2'b00;           // (and k_tgl is 0 in reset: nothing owed)
		ws     <= 1'b0;
	end
	else begin
		ta_n   <= 1'b1;
		tbi_n  <= 1'b1;
		tci_n  <= 1'b1;
		avec_n <= 1'b1;
		// a Fast RAM line's beats (ap060_fastram's TA): lw follows them too
		if (!f_ta_n) beat <= beat + 2'd1;
		case (cst)
			C_IDLE:
				if (!ts_n) take_ts;
			C_ALLOC:
				// the address, attributes and write data stay driven until
				// TA (MC68060UM 7.6): wait here for the slot as long as needed
				if (!busy[ws]) begin
					sa[ws]    <= xa;
					ssiz[ws]  <= xsiz;
					srd[ws]   <= xrd;
					scode[ws] <= xcode;
					siack[ws] <= xiack;
					if (xrd) begin
						p_tgl[ws] <= ~p_tgl[ws];
						rs  <= ws;
						ws  <= ~ws;
						cst <= C_WAIT;
					end
					else begin
						ta_n <= 1'b0;      // the first beat is taken next clock
						cst  <= C_WBEAT;
					end
				end
			C_WBEAT: begin
				// TA is out this clock: the beat's data is on D31-D0 now (the
				// processor drives the next beat's after it samples TA)
				swd[ws][127 - 32 * lw -: 32] <= d_o;
				wd <= d_o;
				if (xsiz == SIZ_LINE && beat != 2'd3) begin
					beat <= beat + 2'd1;
					ta_n <= 1'b0;
				end
				else begin
					p_tgl[ws] <= ~p_tgl[ws];   // posted: the clk half writes it
					ws <= ~ws;
					if (!ts_n) take_ts;
					else cst <= C_IDLE;
				end
			end
			C_WAIT:
				if (!busy[rs]) begin
					d_i    <= xiack ? 32'd0 : rd_l;
					ta_n   <= 1'b0;
					avec_n <= !xiack;
					tci_n  <= !(xrd && !x_cach);
					beat   <= beat + 2'd1;
					cst    <= (xsiz == SIZ_LINE) ? C_RBEAT : C_ACK;
				end
			C_RBEAT: begin
				// the line's next beat (one a clock: no TBI)
				d_i   <= rd_l;
				ta_n  <= 1'b0;
				tci_n <= x_cach;
				beat  <= beat + 2'd1;
				if (beat == 2'd3) cst <= C_ACK;
			end
			C_ACK:
				// TA is out this clock; a transfer may start with it
				if (!ts_n) take_ts;
				else cst <= C_IDLE;
			default: cst <= C_IDLE;
		endcase
	end
end

//--------------------------------------------------------------------------
// clk: cpu_wrapper's 16-bit accesses
//--------------------------------------------------------------------------
reg   [1:0] p_tgl_k1 = 2'b00, p_tgl_k = 2'b00;
always @(posedge clk) begin p_tgl_k1 <= p_tgl; p_tgl_k <= p_tgl_k1; end
wire  [1:0] req = p_tgl_k ^ k_tgl;

localparam K_IDLE = 2'd0, K_ACC = 2'd1, K_GAP = 2'd2;
reg   [1:0] kst;
reg         rp = 1'b0;             // the slot being served (in turn)
reg   [2:0] kw;                    // its word being accessed
reg         word1;                 // (debug capture: a long word's second word)

function [2:0] nwords;             // the slot's last word
	input [1:0] s;
	nwords = (s == SIZ_LINE) ? 3'd7 : (s == SIZ_L) ? 3'd1 : 3'd0;
endfunction

// the 16-bit access for word w of slot s: a line's long words in the
// processor's order, each high half first; longword high on the first
// word of a long word, as TG68K does (Gayle's 32-bit IDE data port)
task present;
	input       s;
	input [2:0] w;
	reg   [1:0] li;
	reg         hi;
	begin
		li = (ssiz[s] == SIZ_LINE) ? sa[s][3:2] + w[2:1] : sa[s][3:2];
		hi = (ssiz[s] == SIZ_LINE || ssiz[s] == SIZ_L) ? !w[0] : !sa[s][1];
		addr_out   <= (ssiz[s] == SIZ_B) ? sa[s] : {sa[s][31:4], li, !hi, 1'b0};
		busstate   <= !srd[s] ? BS_WRITE : scode[s] ? BS_FETCH : BS_READ;
		nwr        <= srd[s];
		nuds       <= (ssiz[s] == SIZ_B) && sa[s][0];
		nlds       <= (ssiz[s] == SIZ_B) && !sa[s][0];
		longword   <= (ssiz[s] == SIZ_LINE || ssiz[s] == SIZ_L) && !w[0];
		data_write <= hi ? swd[s][127 - 32 * li -: 16] : swd[s][111 - 32 * li -: 16];
		word1      <= w[0];
	end
endtask

// where the word just read goes
wire  [1:0] k_li = addr_out[3:2];
wire        k_hi = !addr_out[1];

always @(posedge clk or negedge nreset) begin
	if (!nreset) begin
		kst        <= K_IDLE;
		busstate   <= BS_IDLE;
		nwr        <= 1'b1;
		nuds       <= 1'b1;
		nlds       <= 1'b1;
		longword   <= 1'b0;
		addr_out   <= 32'd0;
		data_write <= 16'd0;
		word1      <= 1'b0;
		k_tgl      <= 2'b00;
		rp         <= 1'b0;
		kw         <= 3'd0;
	end
	else case (kst)
		K_IDLE:
			if (req[rp]) begin
				present(rp, 3'd0);
				kw  <= 3'd0;
				kst <= K_ACC;
			end
		K_ACC:
			if (clkena_in) begin
				if (ssiz[rp] == SIZ_W || ssiz[rp] == SIZ_B)
					k_rd[127 - 32 * k_li -: 32] <= {data_in, data_in};
				else if (k_hi) k_rd[127 - 32 * k_li -: 16] <= data_in;
				else           k_rd[111 - 32 * k_li -: 16] <= data_in;
				if (kw != nwords(ssiz[rp]) && !kw[0])
					// a long word's second word follows at once
					present(rp, kw + 3'd1);
				else begin
					// cpu_wrapper wants a sampled idle clock between its
					// requests: between a line's long words, and before the
					// next transfer
					busstate <= BS_IDLE;
					nwr      <= 1'b1;
					nuds     <= 1'b1;
					nlds     <= 1'b1;
					longword <= 1'b0;
					if (kw == nwords(ssiz[rp])) begin
						// done: answer (the read data is registered on this
						// edge too, and the answer takes two clk_cpu clocks
						// to arrive)
						k_tgl[rp] <= ~k_tgl[rp];
						rp  <= ~rp;
						kst <= K_IDLE;
					end
					else kst <= K_GAP;
				end
				kw <= kw + 3'd1;
			end
		K_GAP: begin
			present(rp, kw);           // the line's next long word
			kst <= K_ACC;
		end
		default: kst <= K_IDLE;
	endcase
end

//--------------------------------------------------------------------------
// debug capture
//--------------------------------------------------------------------------
generate if (DEBUG_CAPTURE) begin : g_dbg
	// clk_cpu: instructions retired, and the transfer ring (one entry at
	// each TA, every beat of a line: tt=3 acknowledges included)
	reg  [15:0] retired = 0;
	reg  [15:0] transfers = 0;
	reg   [5:0] wp = 0;
	reg  [79:0] ring [0:63];
	reg  [79:0] ring_q;
	reg   [5:0] rd_addr = 0;
	always @(posedge clk_cpu) begin
		if (dbg_retire) retired <= retired + 16'd1;
		if (!ta_n || !f_ta_n) begin
			ring[wp] <= {7'd0, xfast, xiack, ~avec_n, ~tbi_n, ~tci_n, xrd, xcode, xsiz,
			             {xa[31:4], xsiz == SIZ_LINE ? lw : xa[3:2], xa[1:0]},
			             xrd ? (f_doe ? f_d : d_i) : d_o};
			wp <= wp + 6'd1;
			transfers <= transfers + 16'd1;
		end
		ring_q <= ring[rd_addr];
	end
	wire [15:0] src;
	always @(posedge clk_cpu) rd_addr <= src[5:0];
	// the live view: the processor, the clk_cpu half, the clk half
	wire [255:0] probe = {
		ring_q,                                          // 80  ring[src[5:0]]
		dbg_pc,                                          // 32
		retired, transfers,                              // 32
		xa,                                              // 32  the transfer on the bus
		addr_out,                                        // 32  the 16-bit access presented
		wp,                                              // 6
		dbg_halted, nrst_c, ts_n, ta_n & f_ta_n,         // 4   [41:38]
		cst, kst,                                        // 6   [37:32]
		p_tgl, k_tgl_c, p_tgl_k, k_tgl,                  // 8   [31:24]
		ws, rp, kw,                                      // 5   [23:19]
		xsiz, xrd, xiack, clkena_in,                     // 5   [18:14]
		busstate, ipl_in,                                // 5   [13:9]
		7'd0, nresetout, 1'b0                            // 9   [8:0] (nresetout [1])
	};
`ifndef VERILATOR
	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.sld_instance_index(0),
		.instance_id("A060"),
		.probe_width(256),
		.source_width(16),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe"),
		.lpm_hint("UNUSED")
	) issp (
		.probe(probe),
		.source(src),
		.source_ena(1'b1),
		.source_clk(clk_cpu)
	);
`else
	assign src = 16'd0;
`endif
end endgenerate

endmodule
