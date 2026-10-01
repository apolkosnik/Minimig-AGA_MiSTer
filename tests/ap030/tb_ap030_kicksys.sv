//--------------------------------------------------------------------------//
// tb_ap030_kicksys.sv - boots a real Kickstart ROM through the Minimig CPU  //
// path as Minimig.sv builds it: cpu_wrapper (AP030 + compat layer),        //
// ram_cs_guard and sdram_ctrl with its cpu_cache_new, on a behavioural     //
// SDR SDRAM.  Chip-bus RAM and ROM cycles use the controller's chip port   //
// (so chip writes snoop cpu_cache_new and the AP030 data cache as on the   //
// board); turbo chip/kick accesses use its CPU port.                       //
//                                                                          //
// Minimal chipset: custom registers with a PAL beam counter, VERTB, INTENA //
// /INTREQ/DMACON, blitter and disk completion interrupts, SERDAT; CIA-A/B  //
// with ports, timers A/B, TOD and ICR (OVL is CIA-A PRA bit 0).  COLOR00   //
// changes, exceptions, the RESET instruction and restarts at the ROM entry //
// are reported.                                                            //
//                                                                          //
//   +rom=<16-bit word hex of a 512K ROM>  +cycles=<clk_114 cycles>         //
//   +dcache  sets the OSD data cache option (cachecfg[2])                  //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ap030_kicksys;

parameter CPU_PHASE = 3;
parameter CYC_PHASE = 1;

reg clk_114 = 0;
always #4.4 clk_114 = ~clk_114;
reg clk_cpu = 0;
always #10 clk_cpu = ~clk_cpu;

reg [3:0] div = 0;
wire clk = (div[1:0] == CPU_PHASE[1:0]) | (div[1:0] == ((CPU_PHASE[1:0] + 2'd1) & 2'd3));
wire c_7m = div[3];
reg ph1 = 0, ph2 = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	if (div[1] & ~div[0]) begin
		ph1 <= 0; ph2 <= 0;
		case (div[3:2])
			2'd0: ph2 <= 1;
			2'd2: ph1 <= 1;
			default: ;
		endcase
	end
end

reg reset = 0;
reg dcache_opt = 0;
reg ovl = 1;

//---------------------------------------------------------------------------
// CPU side
//---------------------------------------------------------------------------
wire [23:1] chip_addr;
wire [15:0] chip_din;
wire        chip_as, chip_uds, chip_lds, chip_rw;
reg  [15:0] chip_dout;
wire        chip_wait;
reg   [2:0] ipl_lvl;
wire        ramsel, ramlds, ramuds, ramconsumed, ram_cs, ramready;
wire [28:1] ramaddr;
wire [15:0] ramdin, ramdout;
wire  [1:0] cpustate;
wire  [3:0] cpu_cacr;
wire        cache_inhibit, cpu_nrst_out;
wire        snp_tgl;
wire [24:1] snp_adr;

cpu_wrapper dut (
	.snoop_tgl(snp_tgl), .snoop_adr(snp_adr),
	.reset(reset), .reset_out(cpu_nrst_out),
	.clk(clk), .clk_cpu(clk_cpu), .clk_mem(clk_114),
	.fr_address(), .fr_burstcount(), .fr_read(), .fr_write(), .fr_writedata(), .fr_byteenable(),
	.fr_waitrequest(1'b1), .fr_readdata(64'd0), .fr_readdatavalid(1'b0),
	.ph1(ph1), .ph2(ph2),
	.cpucfg(2'b10), .fastramcfg(3'd0), .cachecfg({dcache_opt, ~ovl, ~ovl}), .bootrom(1'b0),
	.chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(chip_din), .chip_as(chip_as),
	.chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw), .chip_dtack(chip_wait),
	.chip_ipl(~ipl_lvl),
	.fastchip_dout(16'd0), .fastchip_sel(), .fastchip_lds(), .fastchip_uds(), .fastchip_rnw(),
	.fastchip_lw(), .fastchip_selack(1'b0), .fastchip_ready(1'b0),
	.ramsel(ramsel), .ramaddr(ramaddr), .ramdin(ramdin), .ramdout(ramdout), .ramready(ramready),
	.ramconsumed(ramconsumed), .ramlds(ramlds), .ramuds(ramuds), .ramshared(),
	.walker_mem_req(), .walker_mem_we(), .walker_mem_addr(), .walker_mem_wdat(), .walker_mem_ddr(),
	.walker_mem_bad(), .walker_mem_ack(1'b0), .walker_mem_rdata(32'd0), .walker_mem_berr(1'b0),
	.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),
	.cpustate(cpustate), .cacr(cpu_cacr), .cache_inhibit(cache_inhibit),
	.nmi_ack_toggle(), .nmi_addr()
);

ram_cs_guard ram_guard (
	.clk(clk_114), .nreset(reset), .cpu_type(1'b1),
	.ram_consumed(ramconsumed), .ram_sel(ramsel), .ram_ready(ramready), .ram_cs(ram_cs)
);

//---------------------------------------------------------------------------
// SDRAM controller and its chip port (driven by the chip-bus model)
//---------------------------------------------------------------------------
wire [12:0] sd_addr;
wire  [1:0] sd_ba, sd_dqm;
wire        sd_we, sd_ras, sd_cas, sd_clk;
wire [15:0] sd_data;
reg  [24:1] cp_addr = 0;
reg         cp_u = 1, cp_l = 1, cp_rw = 1, cp_dma = 1;
reg  [15:0] cp_wr = 0;
wire [15:0] cp_rd;

sdram_ctrl #(.CPU_CACHE(1)) ram (
	.sysclk(clk_114), .c_7m(c_7m), .reset_n(reset), .cache_rst(reset), .cache_inhibit(cache_inhibit),
	.cpu_cache_ctrl(cpu_cacr),
	.sd_addr(sd_addr), .sd_ba(sd_ba), .sd_cs(), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
	.sd_dqm(sd_dqm), .sd_data(sd_data), .sd_clk(sd_clk), .sd_cke(),
	.chipAddr(cp_addr), .chipL(cp_l), .chipU(cp_u), .chipRW(cp_rw), .chipDMA(cp_dma), .chipWR(cp_wr),
	.chipRD(cp_rd), .snoop_tgl(snp_tgl), .snoop_addr(snp_adr), .chip48(),
	.cpuAddr({2'b00, ramaddr[22:1]}), .cpuCS(ram_cs), .cpustate(cpustate), .cpuL(ramlds), .cpuU(ramuds),
	.cpuWR(ramdin), .cpuRD(ramdout), .ramready(ramready),
	.walker_req(1'b0), .walker_we(1'b0), .walker_addr(23'd0), .walker_wdata(32'd0),
	.walker_ack(), .walker_rdata()
);

//---------------------------------------------------------------------------
// behavioural SDR SDRAM, 8MB: CL2, read burst 4 (wrapping), single writes
//---------------------------------------------------------------------------
reg [15:0] mem [0:4194303];
reg [12:0] row [0:3];
reg [15:0] rd_pipe_dat [0:15];
reg        rd_pipe_en  [0:15];
reg [15:0] sd_q = 0;
reg        sd_q_en = 0;
assign sd_data = sd_q_en ? sd_q : 16'hZZZZ;
wire [24:1] lin_base = {sd_ba, row[sd_ba], sd_addr[8:0]};
reg sdclk_q = 0;
integer k;
always @(posedge clk_114) begin
	sdclk_q <= sd_clk;
	if (sd_clk && !sdclk_q) begin
		sd_q <= rd_pipe_dat[0]; sd_q_en <= rd_pipe_en[0];
		for (k = 0; k < 15; k = k + 1) begin rd_pipe_dat[k] <= rd_pipe_dat[k+1]; rd_pipe_en[k] <= rd_pipe_en[k+1]; end
		rd_pipe_dat[15] <= 0; rd_pipe_en[15] <= 0;
		if (!sd_ras && sd_cas && sd_we) row[sd_ba] <= sd_addr;
		else if (sd_ras && !sd_cas && sd_we) begin : rd
			reg [24:1] lin;
			lin = lin_base;
			for (k = 0; k < 4; k = k + 1) begin
				rd_pipe_dat[k] <= mem[{lin[22:3], lin[2:1] + k[1:0]}];
				rd_pipe_en[k] <= 1'b1;
			end
		end else if (sd_ras && !sd_cas && !sd_we) begin : wr
			reg [24:1] lin;
			lin = lin_base;
			if (!sd_dqm[1]) mem[lin[22:1]][15:8] <= sd_data[15:8];
			if (!sd_dqm[0]) mem[lin[22:1]][7:0]  <= sd_data[7:0];
		end
	end
end

//---------------------------------------------------------------------------
// chip bus: RAM/ROM through the chip port, registers answered directly
//---------------------------------------------------------------------------
wire [23:0] ca = {chip_addr, 1'b0};
wire in_chip   = (ca < 24'h200000);
wire in_rom    = (ca >= 24'hF80000);
wire in_custom = (ca[23:12] == 12'hDFF);
wire in_ciaa   = (ca[23:12] == 12'hBFE) || (ca[23:12] == 12'hBFC);
wire in_ciab   = (ca[23:12] == 12'hBFD) || (ca[23:12] == 12'hBFC);
// RAM-backed: chip RAM (ROM while OVL for reads), the ROM itself; ROM
// writes are ignored
wire ram_rd    = chip_rw && (in_chip || in_rom);
wire ram_wr    = !chip_rw && in_chip;
wire [24:1] ram_word = (in_rom || (ovl && in_chip && chip_rw)) ? (24'h3C0000 | {6'd0, ca[18:1]})   // $780000 + offset
                                                             : {3'd0, ca[21:1]};
localparam CB_IDLE = 2'd0, CB_PORT = 2'd1, CB_DONE = 2'd2;
reg [1:0]  cb_state = CB_IDLE;
reg [15:0] cb_data = 0;
reg        ph2_d = 0;
wire ph2_rise = ph2 && !ph2_d;
assign chip_wait = reset && !chip_as && (ram_rd || ram_wr) && (cb_state != CB_DONE);

reg [15:0] reg_rd;
always @* chip_dout = (cb_state == CB_DONE) ? cb_data : reg_rd;

integer cycles = 0, max_cycles;
integer color_prints = 0;
reg [15:0] color0 = 16'hFFFF;

always @(posedge clk_114) begin
	ph2_d <= ph2;
	case (cb_state)
		CB_IDLE: if (reset && !chip_as && (ram_rd || (ram_wr && ph2_rise))) begin
			cp_addr <= ram_word;
			cp_u <= chip_uds; cp_l <= chip_lds;
			cp_wr <= chip_din;
			if (ram_rd) cp_dma <= 1'b0; else cp_rw <= 1'b0;
			cb_state <= CB_PORT;
			if (ram_wr && ca == 24'h000004) $display("EXECBASE hi %h (cycle %0d)", chip_din, cycles);
			if (ram_wr && ca == 24'h000006) $display("EXECBASE lo %h (cycle %0d)", chip_din, cycles);
		end
		CB_PORT: if (ram.slot_type == 3'd1 && ram.sdram_state == 4'd12) begin
			cp_dma <= 1'b1; cp_rw <= 1'b1;
			cb_data <= cp_rd;
			cb_state <= CB_DONE;
		end
		CB_DONE: if (chip_as) cb_state <= CB_IDLE;
		default: cb_state <= CB_IDLE;
	endcase
end

//---------------------------------------------------------------------------
// custom chips
//---------------------------------------------------------------------------
reg [15:0] intena = 0, intreq = 0, dmacon = 0, adkcon = 0;
reg  [8:0] hpos = 0, vpos = 0;
reg  [4:0] cck_div = 0;
reg        vsync_pulse = 0, hsync_pulse = 0;
always @(posedge clk_114) begin
	vsync_pulse <= 0; hsync_pulse <= 0;
	cck_div <= cck_div + 1'd1;
	if (cck_div == 5'd31) begin
		if (hpos == 9'd226) begin
			hpos <= 0; hsync_pulse <= 1;
			if (vpos == 9'd311) begin vpos <= 0; vsync_pulse <= 1; end
			else vpos <= vpos + 1'd1;
		end else hpos <= hpos + 1'd1;
	end
end

//---------------------------------------------------------------------------
// CIAs
//---------------------------------------------------------------------------
reg [7:0] a_pra = 8'h03, a_ddra = 0, a_prb = 0, a_ddrb = 0, a_icrm = 0, a_icr = 0, a_cra = 0, a_crb = 0, a_sdr = 0;
reg [7:0] b_pra = 0, b_ddra = 0, b_prb = 0, b_ddrb = 0, b_icrm = 0, b_icr = 0, b_cra = 0, b_crb = 0, b_sdr = 0;
reg [15:0] a_ta = 16'hFFFF, a_tal = 16'hFFFF, a_tb = 16'hFFFF, a_tbl = 16'hFFFF;
reg [15:0] b_ta = 16'hFFFF, b_tal = 16'hFFFF, b_tb = 16'hFFFF, b_tbl = 16'hFFFF;
reg [23:0] a_tod = 0, b_tod = 0;
reg  [7:0] e_div = 0;
wire e_tick = (e_div == 8'd159);
wire a_irq = |(a_icr & a_icrm);
wire b_irq = |(b_icr & b_icrm);
wire [15:0] intreq_eff = intreq | {2'b00, b_irq, 9'd0, a_irq, 3'd0};
wire [15:0] act = intena[14] ? (intena & intreq_eff) : 16'd0;
always @* begin
	if (act[14:13] != 0) ipl_lvl = 3'd6;
	else if (act[12:11] != 0) ipl_lvl = 3'd5;
	else if (act[10:7] != 0) ipl_lvl = 3'd4;
	else if (act[6:4] != 0) ipl_lvl = 3'd3;
	else if (act[3]) ipl_lvl = 3'd2;
	else if (act[2:0] != 0) ipl_lvl = 3'd1;
	else ipl_lvl = 3'd0;
end

function [7:0] cia_rd; input sel_b; input [3:0] r;
	begin
		if (!sel_b) case (r)
			4'h0: cia_rd = (a_pra & a_ddra) | (8'hFC & ~a_ddra);
			4'h1: cia_rd = (a_prb & a_ddrb) | (8'hFF & ~a_ddrb);
			4'h2: cia_rd = a_ddra; 4'h3: cia_rd = a_ddrb;
			4'h4: cia_rd = a_ta[7:0]; 4'h5: cia_rd = a_ta[15:8];
			4'h6: cia_rd = a_tb[7:0]; 4'h7: cia_rd = a_tb[15:8];
			4'h8: cia_rd = a_tod[7:0]; 4'h9: cia_rd = a_tod[15:8]; 4'hA: cia_rd = a_tod[23:16];
			4'hC: cia_rd = a_sdr;
			4'hD: cia_rd = {a_irq, 2'b00, a_icr[4:0]};
			4'hE: cia_rd = a_cra; 4'hF: cia_rd = a_crb;
			default: cia_rd = 8'h00;
		endcase else case (r)
			4'h0: cia_rd = (b_pra & b_ddra) | (8'hFF & ~b_ddra);
			4'h1: cia_rd = (b_prb & b_ddrb) | (8'hFF & ~b_ddrb);
			4'h2: cia_rd = b_ddra; 4'h3: cia_rd = b_ddrb;
			4'h4: cia_rd = b_ta[7:0]; 4'h5: cia_rd = b_ta[15:8];
			4'h6: cia_rd = b_tb[7:0]; 4'h7: cia_rd = b_tb[15:8];
			4'h8: cia_rd = b_tod[7:0]; 4'h9: cia_rd = b_tod[15:8]; 4'hA: cia_rd = b_tod[23:16];
			4'hC: cia_rd = b_sdr;
			4'hD: cia_rd = {b_irq, 2'b00, b_icr[4:0]};
			4'hE: cia_rd = b_cra; 4'hF: cia_rd = b_crb;
			default: cia_rd = 8'h00;
		endcase
	end
endfunction

always @* begin
	reg_rd = 16'h0000;
	if (in_custom) case ({ca[8:1], 1'b0})
		9'h002: reg_rd = dmacon & 16'h07FF;
		9'h004: reg_rd = {1'b1, 7'h23, 7'd0, vpos[8]};
		9'h006: reg_rd = {vpos[7:0], hpos[8:1]};
		9'h010: reg_rd = adkcon;
		9'h016: reg_rd = 16'hFF00;
		9'h018: reg_rd = 16'h3000;
		9'h01C: reg_rd = intena;
		9'h01E: reg_rd = intreq_eff;
		9'h07C: reg_rd = 16'h00F8;
		default: reg_rd = 16'h0000;
	endcase
	else if (in_ciaa || in_ciab)
		reg_rd = {in_ciab ? cia_rd(1'b1, ca[11:8]) : 8'hFF, in_ciaa ? cia_rd(1'b0, ca[11:8]) : 8'hFF};
end

// register writes and the chipset clocks
wire reg_wr = reset && !chip_as && !chip_rw && ph2_rise && !in_chip && !in_rom;
reg [8:0] line;
integer ln;
reg [8*100-1:0] sline;
integer slen = 0;
reg a_ta_uf, a_tb_uf, b_ta_uf, b_tb_uf;
always @(posedge clk_114) begin
	e_div <= e_tick ? 8'd0 : e_div + 1'd1;
	if (vsync_pulse) begin intreq[5] <= 1'b1; a_tod <= a_tod + 1'd1; end
	if (hsync_pulse) b_tod <= b_tod + 1'd1;
	// timers (continuous or one-shot; timer B counts E or timer A underflows)
	if (e_tick) begin
		a_ta_uf = 0; a_tb_uf = 0; b_ta_uf = 0; b_tb_uf = 0;
		if (a_cra[0]) begin
			if (a_ta == 0) begin a_ta <= a_tal; a_icr[0] <= 1'b1; a_ta_uf = 1; if (a_cra[3]) a_cra[0] <= 1'b0; end
			else a_ta <= a_ta - 1'd1;
		end
		if (a_crb[0] && (a_crb[6:5] == 2'b00 || a_ta_uf)) begin
			if (a_tb == 0) begin a_tb <= a_tbl; a_icr[1] <= 1'b1; if (a_crb[3]) a_crb[0] <= 1'b0; end
			else a_tb <= a_tb - 1'd1;
		end
		if (b_cra[0]) begin
			if (b_ta == 0) begin b_ta <= b_tal; b_icr[0] <= 1'b1; b_ta_uf = 1; if (b_cra[3]) b_cra[0] <= 1'b0; end
			else b_ta <= b_ta - 1'd1;
		end
		if (b_crb[0] && (b_crb[6:5] == 2'b00 || b_ta_uf)) begin
			if (b_tb == 0) begin b_tb <= b_tbl; b_icr[1] <= 1'b1; if (b_crb[3]) b_crb[0] <= 1'b0; end
			else b_tb <= b_tb - 1'd1;
		end
	end
	// ICR reads clear the flags
	if (reset && !chip_as && chip_rw && ph2_rise && ca[11:8] == 4'hD) begin
		if (in_ciaa) a_icr <= 0;
		if (in_ciab) b_icr <= 0;
	end
	if (reg_wr) begin
		if (in_custom) case ({ca[8:1], 1'b0})
			9'h030: begin
				if (chip_din[7:0] == 8'h0A || slen >= 99) begin $display("SERIAL: %0s", sline); sline = 0; slen = 0; end
				else if (chip_din[7:0] >= 8'h20) begin sline = {sline[8*99-1:0], chip_din[7:0]}; slen = slen + 1; end
			end
			9'h058, 9'h05E: intreq[6] <= 1'b1;             // blit done at once
			9'h024: if (chip_din[15]) intreq[1] <= 1'b1;    // disk DMA done at once
			9'h096: dmacon <= chip_din[15] ? (dmacon | (chip_din & 16'h7FFF)) : (dmacon & ~chip_din);
			9'h09A: intena <= chip_din[15] ? (intena | (chip_din & 16'h7FFF)) : (intena & ~chip_din);
			9'h09C: intreq <= chip_din[15] ? (intreq | (chip_din & 16'h7FFF)) : (intreq & ~chip_din);
			9'h09E: adkcon <= chip_din[15] ? (adkcon | (chip_din & 16'h7FFF)) : (adkcon & ~chip_din);
			9'h180: if (chip_din != color0) begin
				color0 <= chip_din;
				if (color_prints < 60) begin
					color_prints = color_prints + 1;
					$display("COLOR00 %h (cycle %0d, pc=%h)", chip_din, cycles, dut.cpu_inst_p.cpu.core.pc_i);
				end
			end
			default: ;
		endcase
		if (in_ciaa && !chip_lds) case (ca[11:8])
			4'h0: begin a_pra <= chip_din[7:0]; ovl <= (chip_din[0] | ~a_ddra[0]); end
			4'h1: a_prb <= chip_din[7:0];
			4'h2: begin a_ddra <= chip_din[7:0]; ovl <= (a_pra[0] | ~chip_din[0]); end
			4'h3: a_ddrb <= chip_din[7:0];
			4'h4: a_tal[7:0] <= chip_din[7:0];
			4'h5: begin a_tal[15:8] <= chip_din[7:0]; if (!a_cra[0]) a_ta <= {chip_din[7:0], a_tal[7:0]};
			            if (a_cra[3]) begin a_ta <= {chip_din[7:0], a_tal[7:0]}; a_cra[0] <= 1'b1; end end
			4'h6: a_tbl[7:0] <= chip_din[7:0];
			4'h7: begin a_tbl[15:8] <= chip_din[7:0]; if (!a_crb[0]) a_tb <= {chip_din[7:0], a_tbl[7:0]};
			            if (a_crb[3]) begin a_tb <= {chip_din[7:0], a_tbl[7:0]}; a_crb[0] <= 1'b1; end end
			4'h8: a_tod[7:0] <= chip_din[7:0]; 4'h9: a_tod[15:8] <= chip_din[7:0]; 4'hA: a_tod[23:16] <= chip_din[7:0];
			4'hC: a_sdr <= chip_din[7:0];
			4'hD: a_icrm <= chip_din[7] ? (a_icrm | chip_din[4:0]) : (a_icrm & ~chip_din[4:0]);
			4'hE: begin a_cra <= chip_din[7:0] & 8'hEF; if (chip_din[4]) a_ta <= a_tal; end
			4'hF: begin a_crb <= chip_din[7:0] & 8'hEF; if (chip_din[4]) a_tb <= a_tbl; end
			default: ;
		endcase
		if (in_ciab && !chip_uds) case (ca[11:8])
			4'h0: b_pra <= chip_din[15:8];
			4'h1: b_prb <= chip_din[15:8];
			4'h2: b_ddra <= chip_din[15:8];
			4'h3: b_ddrb <= chip_din[15:8];
			4'h4: b_tal[7:0] <= chip_din[15:8];
			4'h5: begin b_tal[15:8] <= chip_din[15:8]; if (!b_cra[0]) b_ta <= {chip_din[15:8], b_tal[7:0]};
			            if (b_cra[3]) begin b_ta <= {chip_din[15:8], b_tal[7:0]}; b_cra[0] <= 1'b1; end end
			4'h6: b_tbl[7:0] <= chip_din[15:8];
			4'h7: begin b_tbl[15:8] <= chip_din[15:8]; if (!b_crb[0]) b_tb <= {chip_din[15:8], b_tbl[7:0]};
			            if (b_crb[3]) begin b_tb <= {chip_din[15:8], b_tbl[7:0]}; b_crb[0] <= 1'b1; end end
			4'h8: b_tod[7:0] <= chip_din[15:8]; 4'h9: b_tod[15:8] <= chip_din[15:8]; 4'hA: b_tod[23:16] <= chip_din[15:8];
			4'hC: b_sdr <= chip_din[15:8];
			4'hD: b_icrm <= chip_din[15] ? (b_icrm | chip_din[12:8]) : (b_icrm & ~chip_din[12:8]);
			4'hE: begin b_cra <= chip_din[15:8] & 8'hEF; if (chip_din[12]) b_ta <= b_tal; end
			4'hF: begin b_crb <= chip_din[15:8] & 8'hEF; if (chip_din[12]) b_tb <= b_tbl; end
			default: ;
		endcase
	end
	if (!cpu_nrst_out) begin ovl <= 1'b1; a_ddra <= 0; end   // RESET instruction
end

//---------------------------------------------------------------------------
// monitors (processor domain)
//---------------------------------------------------------------------------
localparam [7:0] S_EXC0 = 8'd74;
reg [95:0] ring [0:127];
integer ring_i = 0, i;
reg exc_seen = 0, rst_seen = 0;
integer exc_count = 0, restarts = 0, resets = 0;
reg [31:0] cacr_last = 0;

task dump_ring; input integer n;
	begin
		for (i = n - 1; i >= 0; i = i - 1)
			$display("  pc=%h ir=%h sr=%h a7=%h", ring[(ring_i - 1 - i) & 127][95:64],
			         ring[(ring_i - 1 - i) & 127][63:48], ring[(ring_i - 1 - i) & 127][47:32],
			         ring[(ring_i - 1 - i) & 127][31:0]);
	end
endtask

`define CORE dut.cpu_inst_p.cpu.core
always @(posedge clk_cpu) if (reset) begin
	if (`CORE.dbg_inst) begin
		ring[ring_i & 127] = {`CORE.pc_i, `CORE.ir, `CORE.sr,
		                      `CORE.sr[13] ? (`CORE.sr[12] ? `CORE.rf.msp : `CORE.rf.isp) : `CORE.rf.usp};
		ring_i = ring_i + 1;
		if (`CORE.pc_i == 32'h00F800D2 && cycles > 5000) begin
			restarts = restarts + 1;
			$display("RESTART %0d at cycle %0d, last instructions:", restarts, cycles);
			dump_ring(64);
			if (restarts >= 2) finish_run;
		end
	end
	if (`CORE.state == S_EXC0 && !exc_seen) begin
		exc_count = exc_count + 1;
		if (exc_count <= 300 && !(`CORE.exc_vec >= 8'd25 && `CORE.exc_vec <= 8'd30 && exc_count > 60))
			$display("EXC vec=%0d pc_i=%h ir=%h sr=%h (cycle %0d)", `CORE.exc_vec, `CORE.pc_i, `CORE.ir, `CORE.sr, cycles);
		if (`CORE.exc_vec != 8'd8 && `CORE.exc_vec != 8'd11 && !(`CORE.exc_vec >= 8'd24 && `CORE.exc_vec <= 8'd31) &&
		    !(`CORE.exc_vec >= 8'd32 && `CORE.exc_vec <= 8'd47)) begin
			$display("  unexpected vector %0d, last instructions:", `CORE.exc_vec);
			dump_ring(40);
		end
	end
	exc_seen <= (`CORE.state == S_EXC0);
	if (`CORE.cacr !== cacr_last) begin
		$display("CACR %h -> %h at pc=%h (cycle %0d)", cacr_last, `CORE.cacr, `CORE.pc_i, cycles);
		cacr_last <= `CORE.cacr;
	end
	if (!dut.cpu_inst_p.reset_n_oe && !rst_seen) begin
		resets = resets + 1;
		$display("RESET instruction at pc=%h (cycle %0d), last instructions:", `CORE.pc_i, cycles);
		dump_ring(64);
	end
	rst_seen <= !dut.cpu_inst_p.reset_n_oe;
end

task finish_run;
	begin
		$display("cycles %0d, restarts %0d, RESET instructions %0d, exceptions %0d, pc=%h ovl=%b",
		         cycles, restarts, resets, exc_count, `CORE.pc_i, ovl);
		$finish;
	end
endtask

reg [1023:0] rom_file;
reg [15:0] rom_img [0:262143];
initial begin
	dcache_opt = $test$plusargs("dcache");
	if (!$value$plusargs("rom=%s", rom_file)) rom_file = "build/kick/k31.hex";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 200000000;
	for (i = 0; i < 4194304; i = i + 1) mem[i] = 16'h0000;
	$readmemh(rom_file, rom_img);
	for (i = 0; i < 262144; i = i + 1) mem[22'h3C0000 + i] = rom_img[i];   // $780000
	for (i = 0; i < 16; i = i + 1) begin rd_pipe_dat[i] = 0; rd_pipe_en[i] = 0; end
	row[0] = 0; row[1] = 0; row[2] = 0; row[3] = 0;
	sline = 0;
	$display("tb_ap030_kicksys: %0s, dcache option %0d, %0d clk_114 cycles", rom_file, dcache_opt, max_cycles);
	repeat (400) @(posedge clk_114);
	reset = 1;
	for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
		@(posedge clk_114);
		if (cycles % 5000000 == 0)
			$display("... cycle %0d pc=%h sr=%h ovl=%b v=%0d", cycles, `CORE.pc_i, `CORE.sr, ovl, vpos);
	end
	finish_run;
end

endmodule
