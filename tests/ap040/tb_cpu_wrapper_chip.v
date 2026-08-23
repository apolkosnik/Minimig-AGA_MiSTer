// Co-simulation of cpu_wrapper's 7MHz chip-bus stage machine with the
// AP040 core and bus16 adapter.  The program TB drives the compat wrapper
// directly and so never exercises the ph1/ph2 chip handshake that real
// chip-RAM accesses use; the hardware cputest FADD.P ([]d0.w*8) failure
// (stale first word of the memory-indirect pointer read at address 0)
// lives in exactly that gap.  Here the ENTIRE test program runs over the
// chip bus: turbo chipram off, no Zorro RAM, so every fetch and data
// access takes the cpu_wrapper chip path with its mixed posedge/negedge
// stage machine, one CCK per 16-bit transfer, dtack always granted.
`timescale 1ns/1ns

module tb_cpu_wrapper_chip #(
	parameter CPU_PHASE = 0,
	parameter DTACK_MODE = 0
);

reg reset = 0;

// Reproduce the actual two-clock topology in Minimig.sv. cpu_ph1/cpu_ph2
// are generated on clk_114, then sampled by cpu_wrapper on the phase-locked
// clk_sys output.  CPU_PHASE sweeps the four possible PLL edge alignments;
// the old bench generated both from clk_sys and therefore exercised only one
// artificially safe relationship.
reg clk_114 = 0;
always #5 clk_114 = ~clk_114;

reg [3:0] div = 0;
wire clk = (div[1:0] == CPU_PHASE[1:0]) |
	       (div[1:0] == ((CPU_PHASE[1:0] + 2'd1) & 2'd3));
reg ph1 = 0, ph2 = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	if (div[1] & ~div[0]) begin
		ph1 <= 0;
		ph2 <= 0;
		case (div[3:2])
			2'd0: ph2 <= 1;
			2'd2: ph1 <= 1;
			default: ;
		endcase
	end
end

wire [23:1] chip_addr;
wire [15:0] chip_din;
wire        chip_as, chip_uds, chip_lds, chip_rw;
wire        cpu_nrst_out;
wire [15:0] chip_dout;

// chip_dtack is active high for wait.  Mode 0 is an uncontended bus; mode 1
// holds alternate CCK slots to cover the normal DMA/arbitration completion
// path without changing any CPU-side timing.
reg [7:0] cck_count = 0;
always @(posedge clk_114) if (div == 4'hf) cck_count <= cck_count + 1'd1;
wire chip_wait = (DTACK_MODE != 0) && !cck_count[0];

reg  [2:0] ipl_lvl = 0;
reg [15:0] ipl_delay = 0;   // $F148: delayed level-2 IPL countdown
reg        wberr_arm = 0;   // $F146: one-shot walker bus error

wire        walker_req, walker_we, walker_ddr, walker_bad;
wire [28:2] walker_addr;
wire [31:0] walker_wdat;
reg         walker_ack   = 0;
reg         walker_berr  = 0;
reg  [31:0] walker_rdata = 0;

cpu_wrapper dut
(
	.snoop_tgl(1'b0),
	.snoop_adr(24'd0),
	.reset(reset),
	.reset_out(cpu_nrst_out),

	.clk(clk),
	.ph1(ph1),
	.ph2(ph2),

	.cpucfg(2'b10),          // 68040 class, no fastchip acceleration
	.fastramcfg(3'd0),       // no Zorro RAM: nothing selects the RAM port
	.cachecfg(3'd0),         // turbo chipram OFF: chip goes to the chip bus
	.bootrom(1'b0),

	.chip_addr(chip_addr),
	.chip_dout(chip_dout),
	.chip_din(chip_din),
	.chip_as(chip_as),
	.chip_uds(chip_uds),
	.chip_lds(chip_lds),
	.chip_rw(chip_rw),
	.chip_dtack(chip_wait),
	.chip_ipl(~ipl_lvl),

	.fastchip_dout(16'd0),
	.fastchip_sel(),
	.fastchip_lds(),
	.fastchip_uds(),
	.fastchip_rnw(),
	.fastchip_lw(),
	.fastchip_selack(1'b0),
	.fastchip_ready(1'b0),

	.ramsel(),
	.ramaddr(),
	.ramdin(),
	.ramdout(16'd0),
	.ramready(1'b0),
	.ramlds(),
	.ramuds(),
	.ramshared(),

	.walker_mem_req(walker_req),
	.walker_mem_we(walker_we),
	.walker_mem_addr(walker_addr),
	.walker_mem_wdat(walker_wdat),
	.walker_mem_ddr(walker_ddr),
	.walker_mem_bad(walker_bad),
	.walker_mem_ack(walker_ack),
	.walker_mem_rdata(walker_rdata),
	.walker_mem_berr(walker_berr),

	.toccata_ena(),
	.toccata_base(),
	.a2065_ena(),
	.a2065_base(),

	.cpustate(),
	.cacr(),
	.cache_inhibit(),
	.nmi_ack_toggle(),
	.nmi_addr()
);

//---------------------------------------------------------------------------
// 64 KB chip RAM model (word addressed), data valid combinationally like
// real chip RAM by the dtack phase; writes latch during the data phase.
//---------------------------------------------------------------------------

reg [15:0] mem [0:32767];
assign chip_dout = mem[chip_addr[15:1]];

//---------------------------------------------------------------------------
// MMU walker physical port.  On hardware the table walker bypasses the
// chip bus and reads descriptors over the SDRAM/DDR3 port; here the
// tables live in the same 64 KB model.  Handshake mirrors the flat TB:
// a held request is accepted once, re-armed when it drops, acked for one
// cycle after a short latency.  walker_mem_bad (corrupt table address)
// answers with a bus error, as Minimig does.
//---------------------------------------------------------------------------

reg       walker_armed   = 1;
reg       walker_pending = 0;
reg [1:0] walker_lat     = 0;
reg       walker_we_l    = 0;
reg [13:0] walker_word_l = 0;
reg       walker_bad_l   = 0;
reg [31:0] walker_wdat_l = 0;

always @(posedge clk) begin
	walker_ack  <= 0;
	walker_berr <= 0;
	if (!reset) begin
		walker_armed   <= 1;
		walker_pending <= 0;
	end
	else begin
		if (!walker_req) walker_armed <= 1;
		if (walker_req && walker_armed && !walker_pending) begin
			walker_pending <= 1;
			walker_armed   <= 0;
			walker_we_l    <= walker_we;
			walker_word_l  <= walker_addr[15:2];
			walker_bad_l   <= walker_bad | walker_ddr | (|walker_addr[28:16]);
			walker_wdat_l  <= walker_wdat;
			walker_lat     <= 2'd2;
		end
		else if (walker_pending) begin
			if (walker_lat != 0)
				walker_lat <= walker_lat - 1'd1;
			else begin
				walker_pending <= 0;
				if (walker_bad_l || wberr_arm) begin
					wberr_arm   <= 0;
					walker_berr <= 1;
				end
				else if (walker_we_l) begin
					mem[{walker_word_l, 1'b0}] <= walker_wdat_l[31:16];
					mem[{walker_word_l, 1'b1}] <= walker_wdat_l[15:0];
					walker_ack <= 1;
				end
				else begin
					walker_rdata <= {mem[{walker_word_l, 1'b0}],
					                 mem[{walker_word_l, 1'b1}]};
					walker_ack <= 1;
				end
			end
		end
	end
end

integer errors = 0;
integer result = 0;      // 0 running, 1 pass, 2 fail
reg [15:0] failcode = 0;

always @(posedge clk) begin
	if (ph2 && !chip_as && !chip_rw && reset) begin
		if (!chip_uds) mem[chip_addr[15:1]][15:8] <= chip_din[15:8];
		if (!chip_lds) mem[chip_addr[15:1]][7:0]  <= chip_din[7:0];

		if (chip_addr[15:1] == (16'hF100 >> 1))
			failcode <= chip_din;
		if (chip_addr[15:1] == (16'hF102 >> 1) && !chip_uds && !chip_lds) begin
			if (chip_din == 16'h600D) result <= 1;
			else begin
				errors <= errors + 1;
				result <= 2;
			end
		end
	end

	// interrupt injection, mirroring tb_ap040_program: $F110 sets the
	// level directly (0 releases), $F148 arms a delayed level-2 rise
	if (ph2 && !chip_as && !chip_rw && reset &&
	    chip_addr[15:1] == (16'hF110 >> 1))
		ipl_lvl <= chip_din[2:0];
	// the 7 MHz bus stretches every instruction ~16x, so scale the armed
	// delay to sweep the same fraction of the FPU op's window as the
	// fast-bus testbench does with raw clk counts
	if (ph2 && !chip_as && !chip_rw && reset &&
	    chip_addr[15:1] == (16'hF146 >> 1))
		wberr_arm <= 1;   // next walker transaction bus-errors
	if (ph2 && !chip_as && !chip_rw && reset &&
	    chip_addr[15:1] == (16'hF148 >> 1))
		ipl_delay <= chip_din << 8;
	else if (ipl_delay != 0) begin
		ipl_delay <= ipl_delay - 1'd1;
		if (ipl_delay == 16'd1) ipl_lvl <= 3'd2;
	end
end

//---------------------------------------------------------------------------
// driver
//---------------------------------------------------------------------------

reg [1023:0] prog_file;
integer i;
integer timeout;

initial begin
	if (!$value$plusargs("prog=%s", prog_file)) begin
		$display("FAIL: missing +prog=<hexfile>");
		$finish;
	end
	$display("tb_cpu_wrapper_chip: running %0s over the 7MHz chip bus", prog_file);

	for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h0000;
	$readmemh(prog_file, mem);
	// capability word: bit 0 coarse IPL; bit 3 = the cache_allow window
	// models production (cache_allow_all=0), so the chip-window I-fetch
	// bypass is active and t_exceptions 157/158 can assert it
	mem[16'hF160 >> 1] = 16'h0009;

	reset = 0;
	repeat (50) @(posedge clk);
	reset = 1;

	timeout = 0;
	while (result == 0 && timeout < 60000000) begin
		@(posedge clk);
		timeout = timeout + 1;
	end

	if (result == 0) begin
		errors = errors + 1;
		$display("FAIL: timeout after %0d cycles", timeout);
		$display("  pc=%08x ir=%04x sr=%04x state=%02x",
		         dut.cpu_inst_p.core.pc, dut.cpu_inst_p.core.ir,
		         dut.cpu_inst_p.core.sr, dut.cpu_inst_p.core.state);
	end
	else if (result == 2)
		$display("FAIL: program reports failure, test %0d", failcode);
	else
		$display("chip-bus run passed (%0d cycles)", timeout);

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("TEST FAILED with %0d errors", errors);
	$finish;
end

endmodule
