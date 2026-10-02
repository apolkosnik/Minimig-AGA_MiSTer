//--------------------------------------------------------------------------//
// AP030 - MC68030 compatible CPU                                           //
//                                                                          //
// ap030_tg68k_compat.v - the AP030 (ap030_top, a pin-level MC68030) in the //
// Minimig system.  Three clock domains meet here, the way an accelerator   //
// card joins its own clock to a motherboard through the 68030 bus:         //
//                                                                          //
//   clk_cpu  the processor (50 MHz) and the Fast RAM front end:            //
//            Zorro II/III RAM is a 32-bit synchronous port (STERM) with    //
//            burst fills (CBREQ/CBACK), ap030_fastram_fe                   //
//   clk_mem  the DDR3 side of Fast RAM, ap030_fastram_be, an Avalon-MM     //
//            master for the DDRAM interface (clk_114)                      //
//   clk      the Minimig CPU bus (clk_sys): every other cycle goes to a     //
//            16-bit Minimig port speaking cpu_wrapper's TG68K-style        //
//            contract, presented to the processor as a 32-bit              //
//            asynchronous port                                             //
//                                                                          //
// The asynchronous port crosses clocks once in each direction per cycle:   //
// the processor side captures the cycle and flips a request toggle; the    //
// clk side runs the one or two Minimig word cycles the transfer needs      //
// (both words of a longword back to back) and flips an answer toggle with  //
// the data and termination.  DSACK0/DSACK1 (32-bit), BERR, AVEC and CIIN   //
// are generated in clk_cpu from the answer and held until AS negates.      //
// Each side holds its fields stable from its toggle until the other side's //
// toggle comes back.                                                       //
//                                                                          //
// Contract with cpu_wrapper.v on the clk side:                             //
//  - the request outputs are registered and change only on clkena_in edges //
//  - busstate: 00 fetch, 01 idle, 10 data read, 11 data write              //
//  - one qualified completion (clkena_in while requesting) ends a cycle    //
//  - requests are separated by at least one sampled IDLE clock             //
//  - nwr is 1 for read, 0 for write; nuds/nlds are active low              //
// CPU space (FC = 7): interrupt acknowledge cycles are answered with AVEC  //
// (Minimig interrupts are autovectored); breakpoint and coprocessor cycles //
// with BERR, as on a system without a coprocessor.                         //
//                                                                          //
// Caching: CIIN is asserted for everything on this port except ROM, so     //
// chip RAM and I/O are never filled into the on-chip caches.  CIIN is      //
// ignored on writes (UM 6.1.2): with write allocation an aligned longword  //
// store still creates a data cache entry, so the chipset's DMA writes to   //
// chip RAM are snooped into the data cache (snoop_stb/snoop_addr) to       //
// invalidate such entries.  Fast RAM is cachable; nothing but the          //
// processor writes it.                                                     //
//                                                                          //
// The NMI vector (VBR + $7C, the level 7 autovector) is always read on     //
// this port, never from Fast RAM or the data cache, so the cartridge       //
// (HRTmon) can overlay it as it does for the other CPUs.                   //
//--------------------------------------------------------------------------//

module ap030_tg68k_compat
#(
	// on-board debug capture read over JTAG (ap030_dbgcap.v,
	// tests/ap030/ap030_dbgread.tcl): about 600 ALMs and 15 M10Ks, so it
	// is built only when a board problem needs it
	parameter DEBUG_CAPTURE = 0
)
(
	input         clk,           // Minimig CPU bus (clk_sys)
	input         clk_cpu,       // processor
	input         clk_mem,       // DDR3 (DDRAM_CLK)
	input         nreset,        // clk domain
	input         clkena_in,
	input  [15:0] data_in,
	input   [2:0] ipl,           // active low
	input         berr,
	// chipset writes to chip RAM (clk domain): a pulse and the word address
	input         snoop_stb,
	input  [31:0] snoop_addr,

	// Fast RAM configuration (autoconfig, clk domain, quasi-static)
	input         z2ram_ena,
	input   [4:0] z3ram_base0,
	input         z3ram_ena0,
	input   [3:0] z3ram_base1,
	input         z3ram_ena1,

	output reg [31:0] addr_out,
	output reg [15:0] data_write,
	output reg        nwr,
	output reg        nuds,
	output reg        nlds,
	output reg  [1:0] busstate,
	output reg        longword,
	output reg  [2:0] fc,
	output            nresetout,
	output reg        nmi_ack_toggle,

	output            cache_maint_req,
	output            mmu_cache_inhibit,
	output     [31:0] cacr_out,     // 68040 layout for cpu_wrapper: bit 31 D, bit 15 I
	output     [31:0] vbr_out,
	output            debug_halted,

	// Fast RAM: Avalon-MM master on the DDRAM interface (clk_mem)
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

localparam BUS_FETCH = 2'b00, BUS_IDLE = 2'b01, BUS_READ = 2'b10, BUS_WRITE = 2'b11;

//===========================================================================
// processor domain (clk_cpu)
//===========================================================================
wire [31:0] a, d_o;
wire  [2:0] cfc;
wire  [1:0] siz;
wire        rw, as_n, ds_n, d_oe, ciout_n, cbreq_n, reset_n_oe, cpu_halted;
wire [31:0] cacr, vbr;
wire        cache_clear;
wire        fr_sterm_n, fr_cback_n;
wire [31:0] fr_d;

// resets and configuration into clk_cpu
reg  [2:0] nreset_c;
reg  [1:0] z2e_c, z3e0_c, z3e1_c;
reg  [4:0] z3b0_c1, z3b0_c;
reg  [3:0] z3b1_c1, z3b1_c;
always @(posedge clk_cpu) begin
	nreset_c <= {nreset_c[1:0], nreset};
	z2e_c  <= {z2e_c[0],  z2ram_ena};
	z3e0_c <= {z3e0_c[0], z3ram_ena0};
	z3e1_c <= {z3e1_c[0], z3ram_ena1};
	z3b0_c1 <= z3ram_base0; z3b0_c <= z3b0_c1;
	z3b1_c1 <= z3ram_base1; z3b1_c <= z3b1_c1;
end
wire rst_c = !nreset_c[2];

// Fast RAM decode and its DDR3 address (as cpu_wrapper maps ramaddr for
// Zorro RAM and ddram_ctrl adds its $20000000 base)
wire sel_z3_0 = (a[31:27] == z3b0_c) && z3e0_c[1];
wire sel_z3_1 = (a[31:28] == z3b1_c) && z3e1_c[1];
wire sel_z2   = (a[31:24] == 8'h00) && (a[23] ^ |a[22:21]) && z2e_c[1];
// the NMI vector read (supervisor or user data read of VBR + $7C, as
// cpu_wrapper's sel_nmi_vector) stays on the Minimig bus for the cartridge
wire [31:0] nmi_vec  = vbr + 32'h7C;
wire sel_nmi  = rw && (cfc[1:0] == 2'b01) && (a[31:2] == nmi_vec[31:2]);
wire fast_sel = (cfc != 3'd7) && !sel_nmi && (sel_z3_0 || sel_z3_1 || sel_z2);
wire [28:1] ramaddr;
assign ramaddr[28]    = ~sel_z3_0;
assign ramaddr[27]    = ~sel_z3_1 | a[27];
assign ramaddr[26:23] = (sel_z3_0 | sel_z3_1) ? a[26:23] : 4'd0;
assign ramaddr[22:1]  = a[22:1];
wire [28:0] ddr_addr  = {3'b001, ramaddr[28:3]};

// the Minimig port, processor side: a cycle is handed over with p_tgl and
// answered with k_tgl (clk side, below)
reg        p_tgl = 1'b0;          // request toggle
reg [31:0] p_a = 32'd0, p_d = 32'd0;
reg  [1:0] p_siz = 2'd0;
reg  [2:0] p_fc = 3'd0;
reg        p_rw = 1'b1;
reg  [2:0] k_tgl_c = 3'b000;      // the answer toggle, synchronised
reg        p_own = 1'b0;          // this AS cycle has been handed over
reg        p_term = 1'b0;         // its answer arrived: terminate until AS negates
reg        p_berr = 1'b0, p_avec = 1'b0, p_ciin = 1'b0;
reg [31:0] d_slow = 32'd0;
wire        k_tgl;                // clk side
wire [31:0] k_d;
wire        k_berr, k_avec, k_ciin;
wire       p_busy   = p_tgl != k_tgl_c[1];
wire       p_answer = k_tgl_c[2] != k_tgl_c[1];
// a cycle is presented once AS is asserted, and DS for a write (it follows
// the data, UM 7.3.2)
wire       slow_cyc = !as_n && !fast_sel && (rw || !ds_n);
always @(posedge clk_cpu) begin
	k_tgl_c <= {k_tgl_c[1:0], k_tgl};
	if (as_n) begin
		p_own <= 1'b0; p_term <= 1'b0;
	end else begin
		// one request per AS cycle; an answer still owed to a cycle that a
		// processor reset abandoned is waited for and dropped (p_own is clear)
		if (slow_cyc && !p_own && !p_busy) begin
			p_a <= a; p_d <= d_o; p_siz <= siz; p_fc <= cfc; p_rw <= rw;
			p_tgl <= ~p_tgl;
			p_own <= 1'b1;
		end
		if (p_own && p_answer) begin
			p_term <= 1'b1;
			p_berr <= k_berr; p_avec <= k_avec; p_ciin <= k_ciin;
			d_slow <= k_d;
		end
	end
end
wire p_dsack_n = !(p_term && !p_berr && !p_avec);
wire p_berr_n  = !(p_term && p_berr);
wire p_avec_n  = !(p_term && p_avec);
wire p_ciin_n  = !(p_term && p_ciin);

wire [31:0] d_i = fast_sel ? fr_d : d_slow;

// chipset writes into the processor domain: a toggle with the address held
// in the clk domain (a chipset write happens at most once per CCK, four clk
// periods, which outlasts the synchroniser)
reg        snp_tgl_k;
reg [31:0] snp_addr_k;
always @(posedge clk) if (snoop_stb) begin snp_tgl_k <= ~snp_tgl_k; snp_addr_k <= snoop_addr; end
reg  [2:0] snp_tgl_c;
reg        snp_we_c;
reg [31:0] snp_addr_c;
always @(posedge clk_cpu) begin
	snp_tgl_c <= {snp_tgl_c[1:0], snp_tgl_k};
	snp_we_c  <= snp_tgl_c[2] ^ snp_tgl_c[1];
	if (snp_tgl_c[2] ^ snp_tgl_c[1]) snp_addr_c <= snp_addr_k;
end

// on-board debug capture, read over JTAG (ap030_dbgcap.v)
wire [31:0] dbg_pc, dbg_epc, dbg_ea, dbg_isp;
wire  [7:0] dbg_state, dbg_vec;
wire [15:0] dbg_esr, dbg_ir, dbg_sr;
wire        dbg_inst;
wire [127:0] dbg_trace;


// cpu_wrapper's busstate treats program space as an instruction fetch (the
// turbo chip/kick paths and the controllers' instruction caches), so the
// PC-relative operand reads keep the data function code here
ap030_top #(.PCREL_PROGRAM_SPACE(0)) cpu (
	.clk(clk_cpu),
	.a(a), .fc(cfc), .siz(siz), .rw(rw), .rmc_n(), .as_n(as_n), .ds_n(ds_n), .dben_n(),
	.ecs_n(), .ocs_n(), .ciout_n(ciout_n), .cbreq_n(cbreq_n), .bus_oe(),
	.d_o(d_o), .d_oe(d_oe), .d_i(d_i),
	.dsack0_n(p_dsack_n), .dsack1_n(p_dsack_n), .sterm_n(fr_sterm_n),
	.berr_n(p_berr_n), .halt_n(1'b1),
	.avec_n(p_avec_n), .ciin_n(p_ciin_n), .cback_n(fr_cback_n),
	.br_n(1'b1), .bg_n(), .bgack_n(1'b1),
	.ipl_n(ipl), .ipend_n(), .reset_n_i(nreset_c[2]), .reset_n_oe(reset_n_oe),
	.cdis_n(1'b1), .mmudis_n(1'b1), .refill_n(), .status_n(),
	.dbg_pc(dbg_pc), .dbg_sr(dbg_sr), .dbg_state(dbg_state), .dbg_inst(dbg_inst), .dbg_halted(cpu_halted),
	.dbg_vec(dbg_vec), .dbg_epc(dbg_epc), .dbg_esr(dbg_esr), .dbg_ir(dbg_ir), .dbg_ea(dbg_ea), .dbg_isp(dbg_isp), .dbg_trace(dbg_trace),
	.dbg_vbr(vbr), .dbg_cacr(cacr), .dbg_cache_clear(cache_clear),
	.snoop_we(snp_we_c), .snoop_addr(snp_addr_c), .nmi_vec_nocache(1'b1)
);

//---------------------------------------------------------------------------
// Fast RAM
//---------------------------------------------------------------------------
wire         cmd_we, cmd_re, cmd_rempty;
wire [101:0] cmd_wdata, cmd_rdata;
wire   [3:0] cmd_wlevel;
wire         rsp_we, rsp_re, rsp_rempty;
wire  [63:0] rsp_wdata, rsp_rdata;
wire   [3:0] rsp_wlevel;

ap030_fastram_fe fe (
	.clk(clk_cpu), .rst(rst_c),
	.a(a), .fc(cfc), .siz(siz), .rw(rw), .as_n(as_n), .d_o(d_o), .d_oe(d_oe), .cbreq_n(cbreq_n),
	.sel(fast_sel), .ci(!ciout_n), .clear(cache_clear), .ddr_addr(ddr_addr),
	.sterm_n(fr_sterm_n), .cback_n(fr_cback_n), .d_i(fr_d),
	.cmd_we(cmd_we), .cmd_wdata(cmd_wdata), .cmd_wlevel(cmd_wlevel),
	.rsp_rdata(rsp_rdata), .rsp_rempty(rsp_rempty), .rsp_re(rsp_re)
);

ap030_async_fifo #(.W(102), .AW(3)) cmd_fifo (
	.wclk(clk_cpu), .we(cmd_we), .wdata(cmd_wdata), .wfull(), .wlevel(cmd_wlevel),
	.rclk(clk_mem), .re(cmd_re), .rdata(cmd_rdata), .rempty(cmd_rempty), .rlevel()
);

ap030_async_fifo #(.W(64), .AW(3)) rsp_fifo (
	.wclk(clk_mem), .we(rsp_we), .wdata(rsp_wdata), .wfull(), .wlevel(rsp_wlevel),
	.rclk(clk_cpu), .re(rsp_re), .rdata(rsp_rdata), .rempty(rsp_rempty), .rlevel()
);

ap030_fastram_be be (
	.clk(clk_mem), .rst(1'b0),
	.cmd_rdata(cmd_rdata), .cmd_rempty(cmd_rempty), .cmd_re(cmd_re),
	.rsp_we(rsp_we), .rsp_wdata(rsp_wdata), .rsp_wlevel(rsp_wlevel),
	.avm_address(fr_address), .avm_burstcount(fr_burstcount), .avm_read(fr_read), .avm_write(fr_write),
	.avm_writedata(fr_writedata), .avm_byteenable(fr_byteenable), .avm_waitrequest(fr_waitrequest),
	.avm_readdata(fr_readdata), .avm_readdatavalid(fr_readdatavalid)
);

//===========================================================================
// Minimig bus domain (clk): the 16-bit asynchronous port
//===========================================================================
// the request toggle and the processor's fields (stable while it differs
// from k_tgl)
reg  [2:0] p_tgl_k = 3'b000;
always @(posedge clk) p_tgl_k <= {p_tgl_k[1:0], p_tgl};

wire cpu_space  = (p_fc == 3'd7);
wire iack       = cpu_space && (p_a[19:16] == 4'hF);
wire prog_space = (p_fc[1:0] == 2'b10);
// ROM ($E00000-$E7FFFF, $F80000-$FFFFFF) is cachable; chip RAM, slow RAM
// windows and I/O are not
wire rom        = (p_a[31:24] == 8'h00) && ((p_a[23:19] == 5'b11111) || (p_a[23:19] == 5'b11100));
// the bytes of the longword this transfer moves on a 32-bit port: from
// A1-A0 up to the operand size or the longword boundary (UM 7.2.1)
wire [2:0] k_n    = (p_siz == 2'b00) ? 3'd4 : {1'b0, p_siz};
wire [2:0] k_room = 3'd4 - {1'b0, p_a[1:0]};
wire [2:0] k_m    = (k_n < k_room) ? k_n : k_room;
wire [2:0] k_last = {1'b0, p_a[1:0]} + k_m - 3'd1;
wire [3:0] k_op;                  // bit 3 = byte 0 (D31-D24)
assign k_op[3] = (p_a[1:0] == 2'd0);
assign k_op[2] = (p_a[1:0] <= 2'd1) && (k_last >= 3'd1);
assign k_op[1] = (p_a[1:0] <= 2'd2) && (k_last >= 3'd2);
assign k_op[0] = (k_last >= 3'd3);
// a read of cachable space (ROM: CIIN negated) fills the whole longword
// into a cache entry whatever its size (UM 6.1.3.1), so a 32-bit port must
// drive all four bytes; elsewhere only the operand's bytes are touched, so
// I/O registers see exactly the accesses the program makes
wire [3:0] k_be = (p_rw && rom) ? 4'b1111 : k_op;
wire       k_w0 = k_be[3] | k_be[2];
wire       k_w1 = k_be[1] | k_be[0];

localparam K_IDLE = 2'd0, K_REQ = 2'd1, K_GAP = 2'd2;
reg [1:0] kst;
reg       k_tgl_r = 1'b0;
reg       k_wsel;                 // the word in progress: 0 = D31-D16, 1 = D15-D0
reg       k_more;                 // the second word follows
reg [31:0] k_d_r = 32'd0;
reg       k_berr_r = 1'b0, k_avec_r = 1'b0, k_ciin_r = 1'b0;
assign k_tgl  = k_tgl_r;
assign k_d    = k_d_r;
assign k_berr = k_berr_r;
assign k_avec = k_avec_r;
assign k_ciin = k_ciin_r;

wire       k_work = p_tgl_k[1] != k_tgl_r;

// one Minimig word cycle of the transfer: the first word the transfer
// moves from idle, the second (D15-D0) after the gap.  Its byte strobes,
// its address (odd when only its odd byte moves), the lanes' write data.
wire        k_go    = clkena_in && (((kst == K_IDLE) && k_work && !cpu_space) || (kst == K_GAP));
wire        k_iw    = (kst == K_GAP) || !k_w0;
wire        k_iuds  = k_iw ? k_be[1] : k_be[3];
wire        k_ilds  = k_iw ? k_be[0] : k_be[2];

always @(posedge clk) begin
	if (!nreset) begin
		kst <= K_IDLE;
		busstate <= BUS_IDLE;
		nwr <= 1'b1; nuds <= 1'b1; nlds <= 1'b1; longword <= 1'b0;
		addr_out <= 32'd0; data_write <= 16'd0; fc <= 3'd0;
		k_more <= 1'b0; k_wsel <= 1'b0;
		// a request outstanding at reset is answered (the processor drops it)
		k_tgl_r <= p_tgl_k[1];
		nmi_ack_toggle <= 1'b0;
	end else begin
		case (kst)
			K_IDLE: begin
				if (k_work) begin
					k_berr_r <= 1'b0; k_avec_r <= 1'b0; k_ciin_r <= !rom;
					if (cpu_space) begin
						// answered here, no Minimig request
						if (iack) begin
							k_avec_r <= 1'b1;
							if (p_a[3:1] == 3'd7) nmi_ack_toggle <= ~nmi_ack_toggle;
						end else k_berr_r <= 1'b1;
						k_tgl_r <= p_tgl_k[1];
					end else if (k_go) begin
						k_more <= k_w0 && k_w1;
					end
				end
			end
			K_REQ: begin
				// one qualified completion (or a bus error from the timeout);
				// the data is set up before the answer toggles
				if (clkena_in) begin
					busstate <= BUS_IDLE;
					nwr <= 1'b1; nuds <= 1'b1; nlds <= 1'b1; longword <= 1'b0;
					if (k_wsel) k_d_r[15:0] <= data_in;
					else        k_d_r <= {data_in, data_in};
					if (berr) begin
						k_berr_r <= 1'b1;
						k_tgl_r  <= p_tgl_k[1];
						kst      <= K_IDLE;
					end else if (k_more) begin
						kst <= K_GAP;
					end else begin
						k_tgl_r <= p_tgl_k[1];
						kst     <= K_IDLE;
					end
				end
			end
			K_GAP: begin
				// cpu_wrapper sampled the idle clock: the second word
				if (k_go) k_more <= 1'b0;
			end
			default: kst <= K_IDLE;
		endcase
		if (k_go) begin
			addr_out   <= {p_a[31:2], k_iw, !k_iuds};
			fc         <= p_fc;
			nwr        <= p_rw;
			nuds       <= !k_iuds;
			nlds       <= !k_ilds;
			// longword stays low: its only consumer is Gayle's 32-bit IDE
			// data-port shortcut, which pops two words on the first half of
			// a long and is not kept across the second word cycle, so a
			// MOVE.L from the data port lost words.  Two plain word reads
			// are exact.
			longword   <= 1'b0;
			data_write <= k_iw ? p_d[15:0] : p_d[31:16];
			busstate   <= prog_space ? BUS_FETCH : (p_rw ? BUS_READ : BUS_WRITE);
			k_wsel     <= k_iw;
			kst        <= K_REQ;
		end
	end
end

//---------------------------------------------------------------------------
// processor status into clk
//---------------------------------------------------------------------------
reg  [1:0] rsto_k, halt_k, ei_k, ed_k;
reg [31:0] vbr_k1, vbr_k;
reg        clr_tgl;                 // clk_cpu: cache clear pulses as a toggle
reg  [2:0] clr_k;
always @(posedge clk_cpu) if (cache_clear) clr_tgl <= ~clr_tgl;
always @(posedge clk) begin
	rsto_k <= {rsto_k[0], reset_n_oe};
	halt_k <= {halt_k[0], cpu_halted};
	ei_k   <= {ei_k[0], cacr[0]};
	ed_k   <= {ed_k[0], cacr[8]};
	vbr_k1 <= vbr; vbr_k <= vbr_k1;
	clr_k  <= {clr_k[1:0], clr_tgl};
end
assign nresetout         = ~rsto_k[1];
assign debug_halted      = halt_k[1];
assign cacr_out          = {ed_k[1], 15'd0, ei_k[1], 15'd0};
assign vbr_out           = vbr_k;
assign cache_maint_req   = clr_k[2] ^ clr_k[1];
assign mmu_cache_inhibit = 1'b0;    // Fast RAM is not behind the Minimig caches

initial begin
	nreset_c = 3'b000; z2e_c = 2'b00; z3e0_c = 2'b00; z3e1_c = 2'b00;
	z3b0_c1 = 5'd0; z3b0_c = 5'd0; z3b1_c1 = 4'd0; z3b1_c = 4'd0;
	rsto_k = 2'b00; halt_k = 2'b00; ei_k = 2'b00; ed_k = 2'b00; vbr_k1 = 32'd0; vbr_k = 32'd0;
	clr_tgl = 1'b0; clr_k = 3'b000;
	snp_tgl_k = 1'b0; snp_addr_k = 32'd0; snp_tgl_c = 3'b000; snp_we_c = 1'b0; snp_addr_c = 32'd0;
end

generate if (DEBUG_CAPTURE) begin : g_dbgcap
// a transfer as the processor terminates it: every STERM beat on the Fast
// RAM port, the first DSACK/BERR/AVEC edge on the Minimig port
reg dbg_term_q = 1'b0;
always @(posedge clk_cpu) dbg_term_q <= p_term;
wire dbg_bus_stb = !as_n && (fast_sel ? !fr_sterm_n : (p_term && !dbg_term_q));
ap030_dbgcap dbgcap (
	.clk(clk_cpu), .cpu_rst(rst_c),
	.dbg_inst(dbg_inst), .dbg_pc(dbg_pc), .dbg_sr(dbg_sr), .dbg_state(dbg_state), .dbg_vec(dbg_vec),
	.dbg_epc(dbg_epc), .dbg_esr(dbg_esr), .dbg_ir(dbg_ir), .dbg_ea(dbg_ea), .dbg_isp(dbg_isp), .dbg_trace(dbg_trace),
	.reset_n_oe(reset_n_oe), .halted(cpu_halted),
	.bus_stb(dbg_bus_stb), .bus_a(a), .bus_d(rw ? d_i : d_o), .bus_rw(rw), .bus_siz(siz), .bus_fc(cfc),
	.bus_fast(fast_sel),
	.fe_stb(cmd_we && cmd_wdata[101]), .fe_cmd(cmd_wdata[100:0])
);
end endgenerate

endmodule
