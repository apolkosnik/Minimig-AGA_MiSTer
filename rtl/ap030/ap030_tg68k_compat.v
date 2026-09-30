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
//            16-bit asynchronous port speaking cpu_wrapper's TG68K-style   //
//            contract; the processor's dynamic bus sizing splits the       //
//            operands                                                      //
//                                                                          //
// The asynchronous port crosses clocks with the 68030 handshake itself:    //
// AS and DS are synchronised into clk, and DSACK/BERR/AVEC/CIIN back into  //
// clk_cpu; address, data and attributes are stable while they are sampled. //
// After a cycle, terminations still asserted are ignored until they have   //
// been seen negated (a full four-phase handshake).                         //
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

// terminations of the asynchronous port, synchronised, masked until seen
// negated after the cycle they ended
reg  [1:0] dsack1_c, berr_c, avec_c, ciin_c;
reg        term_stale;
wire       term_any = !dsack1_c[1] || !berr_c[1] || !avec_c[1];
wire       dsack1_s, berr_s, avec_s, ciin_s;        // from the clk side
always @(posedge clk_cpu) begin
	dsack1_c <= {dsack1_c[0], dsack1_s};
	berr_c   <= {berr_c[0],   berr_s};
	avec_c   <= {avec_c[0],   avec_s};
	ciin_c   <= {ciin_c[0],   ciin_s};
	if (!term_any) term_stale <= 1'b0;
	else if (as_n) term_stale <= 1'b1;
end
wire mask = term_stale;

// the cycle presented to the clk side: AS only for the asynchronous port,
// and held negated until the previous cycle's termination is released --
// the processor may start its next cycle a single clock after AS negates,
// too short for the clk side to see, and the port must see every negation
reg slow_as_n;
always @(posedge clk_cpu) slow_as_n <= as_n | fast_sel | term_stale;

reg [31:0] d_slow;             // from the clk side, stable before its DSACK
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

ap030_top cpu (
	.clk(clk_cpu),
	.a(a), .fc(cfc), .siz(siz), .rw(rw), .rmc_n(), .as_n(as_n), .ds_n(ds_n), .dben_n(),
	.ecs_n(), .ocs_n(), .ciout_n(ciout_n), .cbreq_n(cbreq_n), .bus_oe(),
	.d_o(d_o), .d_oe(d_oe), .d_i(d_i),
	.dsack0_n(1'b1), .dsack1_n(dsack1_c[1] | mask), .sterm_n(fr_sterm_n),
	.berr_n(berr_c[1] | mask), .halt_n(1'b1),
	.avec_n(avec_c[1] | mask), .ciin_n(ciin_c[1] | mask), .cback_n(fr_cback_n),
	.br_n(1'b1), .bg_n(), .bgack_n(1'b1),
	.ipl_n(ipl), .ipend_n(), .reset_n_i(nreset_c[2]), .reset_n_oe(reset_n_oe),
	.cdis_n(1'b1), .mmudis_n(1'b1), .refill_n(), .status_n(),
	.dbg_pc(), .dbg_sr(), .dbg_state(), .dbg_inst(), .dbg_halted(cpu_halted),
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
reg [2:0] as_s, ds_s;              // synchronised AS (asynchronous port only) and DS
always @(posedge clk) begin
	as_s <= {as_s[1:0], slow_as_n};
	ds_s <= {ds_s[1:0], ds_n};
end
wire as_k = !as_s[2];
wire ds_k = !ds_s[2];

wire cpu_space = (cfc == 3'd7);
wire iack      = cpu_space && (a[19:16] == 4'hF);
wire prog_space = (cfc[1:0] == 2'b10);
// word lanes: UDS carries the even byte (D31-D24), LDS the odd one (D23-D16)
wire lane_u    = !a[0];
wire lane_l    = a[0] || (siz != 2'b01);
// ROM ($E00000-$E7FFFF, $F80000-$FFFFFF) is cachable; chip RAM, slow RAM
// windows and I/O are not
wire rom       = (a[31:24] == 8'h00) && ((a[23:19] == 5'b11111) || (a[23:19] == 5'b11100));

localparam A_IDLE = 2'd0, A_REQ = 2'd1, A_ACK = 2'd2, A_GAP = 2'd3;
reg [1:0] ast;
reg       dsack1_k, berr_k, avec_k, ciin_k;
assign dsack1_s = dsack1_k;
assign berr_s   = berr_k;
assign avec_s   = avec_k;
assign ciin_s   = ciin_k;

always @(posedge clk) begin
	if (!nreset) begin
		ast <= A_IDLE;
		busstate <= BUS_IDLE;
		nwr <= 1'b1; nuds <= 1'b1; nlds <= 1'b1; longword <= 1'b0;
		addr_out <= 32'd0; data_write <= 16'd0; fc <= 3'd0;
		dsack1_k <= 1'b1; berr_k <= 1'b1; avec_k <= 1'b1; ciin_k <= 1'b1;
		nmi_ack_toggle <= 1'b0;
	end else begin
		case (ast)
			A_IDLE: begin
				// a cycle is presented once AS and DS are asserted (for a
				// write DS follows the data, UM 7.3.2)
				if (as_k && ds_k) begin
					if (cpu_space) begin
						// answered here, no Minimig request
						if (iack) begin
							avec_k <= 1'b0;
							if (a[3:1] == 3'd7) nmi_ack_toggle <= ~nmi_ack_toggle;
						end else berr_k <= 1'b0;
						ast <= A_ACK;
					end else if (clkena_in) begin
						addr_out   <= a;
						fc         <= cfc;
						nwr        <= rw;
						nuds       <= !lane_u;
						nlds       <= !lane_l;
						longword   <= (siz == 2'b00);
						data_write <= d_o[31:16];
						busstate   <= prog_space ? BUS_FETCH : (rw ? BUS_READ : BUS_WRITE);
						ciin_k     <= rom;
						ast <= A_REQ;
					end
				end
			end
			A_REQ: begin
				// one qualified completion (or a bus error from the timeout);
				// the data is set up before the termination is visible
				if (clkena_in) begin
					busstate <= BUS_IDLE;
					nwr <= 1'b1; nuds <= 1'b1; nlds <= 1'b1; longword <= 1'b0;
					if (berr) berr_k <= 1'b0;
					else begin
						d_slow <= {data_in, data_in};
						dsack1_k <= 1'b0;
					end
					ast <= A_ACK;
				end
			end
			A_ACK: begin
				// hold the termination until the processor ends the cycle
				if (!as_k) begin
					dsack1_k <= 1'b1; berr_k <= 1'b1; avec_k <= 1'b1; ciin_k <= 1'b1;
					ast <= A_GAP;
				end
			end
			default: ast <= A_IDLE;   // the negation stays visible for a clock
		endcase
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
	dsack1_c = 2'b11; berr_c = 2'b11; avec_c = 2'b11; ciin_c = 2'b11; term_stale = 1'b0;
	slow_as_n = 1'b1; d_slow = 32'd0; as_s = 3'b111; ds_s = 3'b111;
	rsto_k = 2'b00; halt_k = 2'b00; ei_k = 2'b00; ed_k = 2'b00; vbr_k1 = 32'd0; vbr_k = 32'd0;
	clr_tgl = 1'b0; clr_k = 3'b000;
	snp_tgl_k = 1'b0; snp_addr_k = 32'd0; snp_tgl_c = 3'b000; snp_we_c = 1'b0; snp_addr_c = 32'd0;
end

endmodule
