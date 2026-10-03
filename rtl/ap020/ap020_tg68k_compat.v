//--------------------------------------------------------------------------//
// AP020 - MC68020 compatible CPU                                           //
//                                                                          //
// ap020_tg68k_compat.v - the AP020 (ap020_top, a pin-level MC68020) in the //
// Minimig system.  Three clock domains meet here, the way an accelerator   //
// card joins its own clock to a motherboard through the 68020 bus:         //
//                                                                          //
//   clk_cpu  the processor (50 MHz) and the Fast RAM front end:            //
//            Zorro II/III RAM is served through the processor's native     //
//            port (FAST_PORT) with line bursts, and as a 32-bit DSACK      //
//            port for the locked (RMC) cycles, ap020_fastram_fe            //
//   clk_mem  the DDR3 side of Fast RAM, ap020_fastram_be, an Avalon-MM     //
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
// the data and termination.  DSACK0/DSACK1 (32-bit), BERR and AVEC are     //
// generated in clk_cpu from the answer and held until AS negates.          //
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
// with BERR, as on a system without a coprocessor -- so the MC68851/68881  //
// instructions take the Line F exception.                                  //
//                                                                          //
// Caching: the MC68020 instruction cache has no inhibit input and caches   //
// every program fetch, as on an A1200; software clears it (CACR C) after   //
// loading code.  The processor's optional data cache (DATA_CACHE) holds    //
// only native-port (Fast RAM) data; nothing but the processor writes Fast  //
// RAM.  Chipset writes to chip RAM are still passed on as snoops.          //
//                                                                          //
// The NMI vector (VBR + $7C, the level 7 autovector) is always read on     //
// this port, never from Fast RAM or the data cache, so the cartridge       //
// (HRTmon) can overlay it as it does for the other CPUs.                   //
//--------------------------------------------------------------------------//

module ap020_tg68k_compat
#(
	parameter FAST_PORT = 1,
	parameter DATA_CACHE = 1
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
	output     [31:0] cacr_out,     // 68040 layout for cpu_wrapper: bit 31 D, bit 15 I (both CACR E)
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
wire        rw, as_n, ds_n, d_oe, reset_n_oe, cpu_halted;
wire [31:0] cacr, vbr;
wire        cache_clear;
wire        fr_dsack_n;
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

// The direct request uses the same physical mapping and NMI exclusion
// as the pin-bus route. Autoconfiguration is already synchronized above.
wire n_req, n_ready, n_valid, n_last, n_rw, n_ci, n_burst;
wire [31:0] n_addr, n_wdata, n_rdata;
wire [2:0] n_fc;
wire [3:0] n_be;
wire [1:0] n_word;
wire n_z30 = (n_addr[31:27] == z3b0_c) && z3e0_c[1];
wire n_z31 = (n_addr[31:28] == z3b1_c) && z3e1_c[1];
wire n_z2 = (n_addr[31:24] == 8'h00) && (n_addr[23] ^ |n_addr[22:21]) && z2e_c[1];
wire n_nmi = n_rw && n_fc[1:0] == 2'b01 && n_addr[31:2] == nmi_vec[31:2];
wire n_match = n_fc != 3'd7 && !n_nmi && (n_z30 || n_z31 || n_z2);
wire [28:1] n_ramaddr = {~n_z30, (~n_z31 | n_addr[27]),
                        ((n_z30 || n_z31) ? n_addr[26:23] : 4'd0), n_addr[22:1]};
wire [28:0] n_ddr_addr = {3'b001, n_ramaddr[28:3]};

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
reg        p_berr = 1'b0, p_avec = 1'b0;
reg [31:0] d_slow = 32'd0;
wire        k_tgl;                // clk side
wire [31:0] k_d;
wire        k_berr, k_avec;
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
			p_berr <= k_berr; p_avec <= k_avec;
			d_slow <= k_d;
		end
	end
end
wire p_dsack_n = !(p_term && !p_berr && !p_avec);
wire p_berr_n  = !(p_term && p_berr);
wire p_avec_n  = !(p_term && p_avec);
// Fast RAM answers on the pin bus only for locked cycles (the rest takes
// the native port); both are 32-bit ports
wire dsack_n   = fast_sel ? fr_dsack_n : p_dsack_n;

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

// cpu_wrapper's busstate treats program space as an instruction fetch (the
// turbo chip/kick paths and the controllers' instruction caches), so the
// PC-relative operand reads keep the data function code here
ap020_top #(.PCREL_PROGRAM_SPACE(0), .FAST_PORT(FAST_PORT), .DATA_CACHE(DATA_CACHE)) cpu (
	.clk(clk_cpu),
	.a(a), .fc(cfc), .siz(siz), .rw(rw), .rmc_n(), .as_n(as_n), .ds_n(ds_n), .dben_n(),
	.ecs_n(), .ocs_n(), .bus_oe(),
	.d_o(d_o), .d_oe(d_oe), .d_i(d_i),
	.dsack0_n(dsack_n), .dsack1_n(dsack_n),
	.berr_n(p_berr_n), .halt_n(1'b1), .avec_n(p_avec_n),
	.br_n(1'b1), .bg_n(), .bgack_n(1'b1),
	.ipl_n(ipl), .ipend_n(), .reset_n_i(nreset_c[2]), .reset_n_oe(reset_n_oe),
	.cdis_n(1'b1),
	.dbg_pc(), .dbg_sr(), .dbg_state(), .dbg_inst(), .dbg_halted(cpu_halted),
	.dbg_vbr(vbr), .dbg_cacr(cacr), .dbg_cache_clear(cache_clear),
	.snoop_we(snp_we_c), .snoop_addr(snp_addr_c), .nmi_vec_nocache(1'b1),
	.fast_req(n_req), .fast_addr(n_addr), .fast_fc(n_fc), .fast_rw(n_rw), .fast_ci(n_ci),
	.fast_burst(n_burst), .fast_be(n_be), .fast_wdata(n_wdata), .fast_match(n_match),
	.fast_ready(n_ready), .fast_valid(n_valid), .fast_last(n_last), .fast_word(n_word), .fast_rdata(n_rdata)
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

ap020_fastram_fe #(.NATIVE_PORT(FAST_PORT)) fe (
	.clk(clk_cpu), .rst(rst_c),
	.a(a), .fc(cfc), .siz(siz), .rw(rw), .as_n(as_n), .d_o(d_o), .d_oe(d_oe),
	.sel(fast_sel), .clear(cache_clear), .ddr_addr(ddr_addr),
	.dsack_n(fr_dsack_n), .d_i(fr_d),
	.cmd_we(cmd_we), .cmd_wdata(cmd_wdata), .cmd_wlevel(cmd_wlevel),
	.rsp_rdata(rsp_rdata), .rsp_rempty(rsp_rempty), .rsp_re(rsp_re),
	.n_req(n_req), .n_ready(n_ready), .n_addr(n_addr), .n_ddr_addr(n_ddr_addr),
	.n_fc(n_fc), .n_rw(n_rw), .n_ci(n_ci), .n_burst(n_burst), .n_be(n_be), .n_wdata(n_wdata),
	.n_valid(n_valid), .n_last(n_last), .n_word(n_word), .n_rdata(n_rdata)
);

ap020_async_fifo #(.W(102), .AW(3)) cmd_fifo (
	.wclk(clk_cpu), .we(cmd_we), .wdata(cmd_wdata), .wfull(), .wlevel(cmd_wlevel),
	.rclk(clk_mem), .re(cmd_re), .rdata(cmd_rdata), .rempty(cmd_rempty), .rlevel()
);

ap020_async_fifo #(.W(64), .AW(3)) rsp_fifo (
	.wclk(clk_mem), .we(rsp_we), .wdata(rsp_wdata), .wfull(), .wlevel(rsp_wlevel),
	.rclk(clk_cpu), .re(rsp_re), .rdata(rsp_rdata), .rempty(rsp_rempty), .rlevel()
);

ap020_fastram_be be (
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
// only the operand's bytes are touched, so I/O registers see exactly the
// accesses the program makes (instruction fetches are aligned longwords,
// which the instruction cache fills whole)
wire [3:0] k_be = k_op;
wire       k_w0 = k_be[3] | k_be[2];
wire       k_w1 = k_be[1] | k_be[0];

localparam K_IDLE = 2'd0, K_REQ = 2'd1, K_GAP = 2'd2;
reg [1:0] kst;
reg       k_tgl_r = 1'b0;
reg       k_wsel;                 // the word in progress: 0 = D31-D16, 1 = D15-D0
reg       k_more;                 // the second word follows
reg [31:0] k_d_r = 32'd0;
reg       k_berr_r = 1'b0, k_avec_r = 1'b0;
assign k_tgl  = k_tgl_r;
assign k_d    = k_d_r;
assign k_berr = k_berr_r;
assign k_avec = k_avec_r;

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
					k_berr_r <= 1'b0; k_avec_r <= 1'b0;
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


endmodule
