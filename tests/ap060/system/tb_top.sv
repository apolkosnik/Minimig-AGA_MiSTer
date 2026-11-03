// The full-system simulation of Minimig: the core's emu (Minimig.sv) as
// Quartus builds it, with an SDRAM chip and the DDR3 port modelled.  The
// bench (sim_main.cpp) drives the clocks (pll_sim.sv), the HPS bus as Main
// does (hps_io and hps_ext take it), and watches the CPU's chip bus writes
// for the test programs' mailbox at $F00000.

module tb_top
(
	input         clk_50,
	input         reset,

	// the HPS side of hps_io (Main): HPS_BUS[35:33] {fpga, uio, strobe},
	// HPS_BUS[31:16] the word
	input         hps_fpga,
	input         hps_uio,
	input         hps_strobe,
	input  [15:0] hps_din,
	output [15:0] hps_dout,

	// the CPU's chip bus writes, one pulse each at the end of the cycle
	output reg        mon_wr = 1'b0,
	output reg [23:1] mon_addr,
	output reg [15:0] mon_data,
	output reg  [1:0] mon_ds,           // {UDS, LDS} asserted
	output reg        mon_rd = 1'b0,    // a read cycle: its data (and the second word of a 32-bit one)
	output reg [15:0] mon_rdata,
	output reg [15:0] mon_rdata2,
	output reg        mon_long,

	output        led_power,

	// observation
	output        dbg_cpu_rst,
	output        dbg_chip_as,
	output [23:1] dbg_chip_addr,
	output  [1:0] dbg_cpu_state,
	output        dbg_reset_d,
	output        dbg_cpuhlt,
	output  [1:0] dbg_turbo,
	output  [2:0] dbg_cachecfg
);
assign dbg_turbo     = {emu.cpu_wrapper.turbokick_d, emu.cpu_wrapper.turbochip_d};
assign dbg_cachecfg  = emu.cachecfg;
assign dbg_cpu_rst   = emu.cpu_rst;
assign dbg_chip_as   = emu.chip_as;
assign dbg_chip_addr = emu.chip_addr;
assign dbg_cpu_state = emu.cpu_state;
assign dbg_reset_d   = emu.reset_d;
assign dbg_cpuhlt    = emu.minimig.cpuhlt;

wire [45:0] HPS_BUS;
assign HPS_BUS[45:38] = 8'd0;
assign HPS_BUS[35:33] = {hps_fpga, hps_uio, hps_strobe};
assign HPS_BUS[31:16] = hps_din;
assign hps_dout = HPS_BUS[15:0];

wire        sd_clk, sd_cke, sd_dqml, sd_dqmh, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n;
wire [12:0] sd_a;
wire  [1:0] sd_ba;
wire [15:0] sd_dq;

wire        dd_clk, dd_busy, dd_rd, dd_we, dd_dout_ready;
wire  [7:0] dd_burstcnt, dd_be;
wire [28:0] dd_addr;
wire [63:0] dd_dout, dd_din;
wire  [1:0] led_pwr;
assign led_power = led_pwr[0];

emu emu
(
	.CLK_50M          (clk_50),
	.RESET            (reset),
	.HPS_BUS          (HPS_BUS),

	.CLK_VIDEO        (),
	.CE_PIXEL         (),
	.VIDEO_ARX        (),
	.VIDEO_ARY        (),
	.VGA_R            (),
	.VGA_G            (),
	.VGA_B            (),
	.VGA_HS           (),
	.VGA_VS           (),
	.VGA_DE           (),
	.VGA_F1           (),
	.VGA_SL           (),
	.VGA_SCALER       (),
	.VGA_DISABLE      (),
	.HDMI_WIDTH       (12'd1920),
	.HDMI_HEIGHT      (12'd1080),
	.HDMI_FREEZE      (),
	.HDMI_BLACKOUT    (),
	.HDMI_BOB_DEINT   (),

	.FB_EN            (),
	.FB_FORMAT        (),
	.FB_WIDTH         (),
	.FB_HEIGHT        (),
	.FB_BASE          (),
	.FB_STRIDE        (),
	.FB_VBL           (1'b0),
	.FB_LL            (1'b0),
	.FB_FORCE_BLANK   (),
	.FB_PAL_CLK       (),
	.FB_PAL_ADDR      (),
	.FB_PAL_DOUT      (),
	.FB_PAL_DIN       (24'd0),
	.FB_PAL_WR        (),

	.LED_USER         (),
	.LED_POWER        (led_pwr),
	.LED_DISK         (),
	.BUTTONS          (),

	.CLK_AUDIO        (1'b0),
	.AUDIO_L          (),
	.AUDIO_R          (),
	.AUDIO_S          (),
	.AUDIO_MIX        (),

	.ADC_BUS          (),
	.SD_SCK           (),
	.SD_MOSI          (),
	.SD_MISO          (1'b1),
	.SD_CS            (),
	.SD_CD            (1'b1),

	.DDRAM_CLK        (dd_clk),
	.DDRAM_BUSY       (dd_busy),
	.DDRAM_BURSTCNT   (dd_burstcnt),
	.DDRAM_ADDR       (dd_addr),
	.DDRAM_DOUT       (dd_dout),
	.DDRAM_DOUT_READY (dd_dout_ready),
	.DDRAM_RD         (dd_rd),
	.DDRAM_DIN        (dd_din),
	.DDRAM_BE         (dd_be),
	.DDRAM_WE         (dd_we),

	.SDRAM_CLK        (sd_clk),
	.SDRAM_CKE        (sd_cke),
	.SDRAM_A          (sd_a),
	.SDRAM_BA         (sd_ba),
	.SDRAM_DQ         (sd_dq),
	.SDRAM_DQML       (sd_dqml),
	.SDRAM_DQMH       (sd_dqmh),
	.SDRAM_nCS        (sd_cs_n),
	.SDRAM_nCAS       (sd_cas_n),
	.SDRAM_nRAS       (sd_ras_n),
	.SDRAM_nWE        (sd_we_n),

	.UART_CTS         (1'b0),
	.UART_RTS         (),
	.UART_RXD         (1'b1),
	.UART_TXD         (),
	.UART_DTR         (),
	.UART_DSR         (1'b0),

	.USER_IN          (7'h7F),
	.USER_OUT         (),

	.OSD_STATUS       (1'b0)
);

sdram_model sdram
(
	.clk   (sd_clk),
	.a     (sd_a),
	.ba    (sd_ba),
	.dq    (sd_dq),
	.dqml  (sd_dqml),
	.dqmh  (sd_dqmh),
	.cs_n  (sd_cs_n),
	.ras_n (sd_ras_n),
	.cas_n (sd_cas_n),
	.we_n  (sd_we_n)
);

ddr3_model ddr3
(
	.clk        (dd_clk),
	.busy       (dd_busy),
	.burstcnt   (dd_burstcnt),
	.addr       (dd_addr),
	.dout       (dd_dout),
	.dout_ready (dd_dout_ready),
	.rd         (dd_rd),
	.din        (dd_din),
	.be         (dd_be),
	.we         (dd_we)
);

// the CPU's chip bus (cpu_wrapper's outputs): a write cycle, reported when
// AS goes away
reg        as_d = 1'b1;
reg        wcyc = 1'b0;
reg        rcyc = 1'b0;
always @(posedge emu.clk_sys) begin
	mon_wr <= 1'b0;
	mon_rd <= 1'b0;
	if (!emu.chip_as && emu.chip_rw && !emu.chip_dtack) begin
		rcyc       <= 1'b1;
		mon_addr   <= emu.chip_addr;
		mon_rdata  <= emu.chip_dout;
		mon_rdata2 <= emu.chip_rd2;
		mon_long   <= emu.chip_long;
	end
	if (emu.chip_as && !as_d && rcyc) begin
		mon_rd <= 1'b1;
		rcyc   <= 1'b0;
	end
	as_d   <= emu.chip_as;
	if (!emu.chip_as && !emu.chip_rw && (!emu.chip_uds || !emu.chip_lds)) begin
		wcyc     <= 1'b1;
		mon_addr <= emu.chip_addr;
		mon_data <= emu.chip_din;
		mon_ds   <= {!emu.chip_uds, !emu.chip_lds};
	end
	if (emu.chip_as && !as_d && wcyc) begin
		mon_wr <= 1'b1;
		wcyc   <= 1'b0;
	end
end


// ---- AP068060 probe (clk_cpu): the last 64 retired PCs, dumped when the
// processor is reset again (the reset loop), RSTO and halts; +ptrace=N
// prints the first N 68060 bus transfers (TS)
`define AP emu.cpu_wrapper.cpu_inst_p
reg  [31:0] pc_ring [0:63];
reg   [5:0] pc_w = 6'd0;
integer     pc_n = 0, ptr = 0, resets = 0, vecs = 0, after = 0, wlog = 0, alerted = 0;
reg  [63:0] jt_ring [0:255];
reg   [7:0] jt_w = 8'd0;
reg  [31:0] last_pc = 32'd0;
reg  [31:0] tr_a [0:127], tr_d [0:127];
reg         tr_r [0:127];
reg   [1:0] tr_s [0:127];
reg   [6:0] tr_w = 7'd0;
reg  [31:0] watch = 32'd0;
integer     wcnt = 0, wdump = 0, mk = 0, mkn = 0;
initial if (!$value$plusargs("watch=%h", watch)) watch = 32'd0;
reg         nrst_d = 1'b0, rsto_d = 1'b1, halt_d = 1'b0;
initial if (!$value$plusargs("ptrace=%d", ptr)) ptr = 0;
integer ccount = 0;
always @(posedge `AP.clk_cpu) begin
	ccount <= ccount + 1;
	if (ccount == 1000 || ccount == 100000 || ccount == 1000000)
		$display("[cpu] %0d clk_cpu edges: nrst_c %b nreset(in) %b rsto_n %b halted %b ts_n %b", ccount,
		         `AP.nrst_c, `AP.nreset, `AP.rsto_n, `AP.dbg_halted, `AP.ts_n);
	nrst_d <= `AP.nrst_c;
	rsto_d <= `AP.rsto_n;
	halt_d <= `AP.dbg_halted;
	// branch targets (a retired PC not just after the previous one), 256 deep;
	// dumped when Alert's dead end is entered ($F83F60), then the 68060's
	// next 12 writes (Alert pushes d0-d1/d7/a0-a1/a5-a6: d7, the alert number)
	if (`AP.nrst_c && `AP.dbg_retire) begin
		if (`AP.dbg_pc - last_pc > 32'd10) begin
			jt_ring[jt_w] <= {last_pc, `AP.dbg_pc};
			jt_w <= jt_w + 8'd1;
		end
		last_pc <= `AP.dbg_pc;
		if (`AP.dbg_pc >= 32'h00F84814 && `AP.dbg_pc < 32'h00F84826 && !alerted) begin
			alerted = 1;
			wlog = 12;
			$display("[alert] the last 128 chip-path transfers (oldest first):");
			for (int k = 0; k < 128; k++)
				$display("  %s %08h %08h siz %0d", tr_r[(tr_w + k) % 128] ? "RD" : "WR",
				         tr_a[(tr_w + k) % 128], tr_d[(tr_w + k) % 128], tr_s[(tr_w + k) % 128]);
			$display("[alert] Alert entered at %06h after %0d retired; the last branches (from -> to), oldest first:", `AP.dbg_pc[23:0], pc_n);
			for (int k = 0; k < 256; k++) begin
				$write(" %06h>%06h", jt_ring[(jt_w + k) % 256][55:32], jt_ring[(jt_w + k) % 256][23:0]);
				if (k % 8 == 7) $display("");
			end
		end
	end
	// +watch=<hex>: every chip-path transfer that covers that long word (a
	// line transfer: its 16-byte line), with the last retired PC
	if (!`AP.ta_n && watch != 0 &&
	    ((`AP.xsiz == 2'b11) ? (`AP.xa[31:4] == watch[31:4]) : (`AP.xa[31:2] == watch[31:2])) && wcnt < 200) begin
		wcnt = wcnt + 1;
		$display("[watch] %s %08h %08h siz %0d tt %0d tm %0d  pc %06h  (%0d retired)", `AP.xrd ? "RD" : "WR", `AP.xa,
		         `AP.xrd ? `AP.d_i : `AP.d_o, `AP.xsiz, `AP.tt, `AP.tm, last_pc[23:0], pc_n);
		// the first non-zero write there: what led to it
		if (!`AP.xrd && `AP.d_o != 32'd0 && !wdump) begin
			wdump = 1;
			$display("[watch] the last 128 chip-path transfers (oldest first):");
			for (int k = 0; k < 128; k++)
				$display("  %s %08h %08h siz %0d", tr_r[(tr_w + k) % 128] ? "RD" : "WR",
				         tr_a[(tr_w + k) % 128], tr_d[(tr_w + k) % 128], tr_s[(tr_w + k) % 128]);
			$display("[watch] the last branches (from -> to), oldest first:");
			for (int k = 0; k < 256; k++) begin
				$write(" %06h>%06h", jt_ring[(jt_w + k) % 256][55:32], jt_ring[(jt_w + k) % 256][23:0]);
				if (k % 8 == 7) $display("");
			end
		end
	end
	// the end-marker read of the init table ($F841C8): the next 30 retired PCs
	if (!`AP.ta_n && `AP.xrd && `AP.xa == 32'h00F841C8 && `AP.xsiz == 2'b01 && !mk) begin
		mk = 1; mkn = 30;
		$display("[mark] read $F841C8 = %08h at %0d retired; last PCs:", `AP.d_i, pc_n);
		for (int k = 52; k < 64; k++) $write(" %06h", pc_ring[(pc_w + k) % 64][23:0]);
		$display("");
	end
	if (`AP.nrst_c && `AP.dbg_retire && mkn > 0) begin
		mkn = mkn - 1;
		$display("[mark] retired %06h", `AP.dbg_pc[23:0]);
	end
	if (!`AP.ta_n) begin
		tr_a[tr_w] <= `AP.xa;
		tr_r[tr_w] <= `AP.xrd;
		tr_d[tr_w] <= `AP.xrd ? `AP.d_i : `AP.d_o;
		tr_s[tr_w] <= `AP.xsiz;
		tr_w <= tr_w + 7'd1;
	end
	if (wlog > 0 && !`AP.ta_n && !`AP.xrd) begin
		wlog = wlog - 1;
		$display("[alert] write %08h = %08h siz %0d", `AP.xa, `AP.d_o, `AP.xsiz);
	end
	if (`AP.nrst_c && `AP.dbg_retire) begin
		pc_ring[pc_w] <= `AP.dbg_pc;
		pc_w <= pc_w + 6'd1;
		pc_n <= pc_n + 1;
	end
	if (!`AP.ts_n && ptr > 0) begin
		ptr = ptr - 1;
		$display("[ts] %0t a=%08h %s siz=%0d tt=%0d tm=%0d", $time, `AP.a_o, `AP.rw_n ? "RD" : "WR",
		         `AP.siz, `AP.tt, `AP.tm);
	end
	// an exception the core takes (the backend's entry): vector, frame PC,
	// fault address and FSLW, and the instructions before it
	if (`AP.cpu.be.x_go && vecs < 60) begin
		vecs = vecs + 1;
		after = 80;
		$write("[exc] vec %0d pc %08h addr %08h fslw %08h kind %0d after %0d retired; last PCs:",
		       `AP.cpu.be.x_vec, `AP.cpu.be.x_pc, `AP.cpu.be.x_addr, `AP.cpu.be.x_fslw,
		       `AP.cpu.be.x_kind, pc_n);
		for (int k = 52; k < 64; k++) $write(" %06h", pc_ring[(pc_w + k) % 64][23:0]);
		$display("");
	end
	if (rsto_d && !`AP.rsto_n) $display("[cpu] RESET instruction (RSTO) after %0d retired", pc_n);
	if (!halt_d && `AP.dbg_halted) $display("[cpu] HALTED (double fault) after %0d retired, pc %08h", pc_n, `AP.dbg_pc);
	if (nrst_d && !`AP.nrst_c) begin
		resets = resets + 1;
		$display("[cpu] reset #%0d after %0d retired; the last PCs (oldest first):", resets, pc_n);
		for (int k = 0; k < 64; k++)
			if (pc_n >= 64 - k) $write(" %08h%s", pc_ring[(pc_w + k) % 64], (k % 8 == 7) ? "\n" : "");
		$display("");
		pc_n = 0;
	end
end
endmodule
