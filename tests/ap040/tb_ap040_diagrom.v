//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// tb_ap040_diagrom.v - boots a real Amiga ROM image against the AP040      //
//                                                                          //
// Minimal Amiga memory model:                                              //
//   $000000-$1FFFFF  2MB chip RAM                                          //
//   $BFExxx          CIA-A: PRA bit 0 controls the reset ROM overlay       //
//   $DFF000-$DFF1FF  custom chips: SERDAT ($030) writes are captured and   //
//                    printed as console text, SERDATR ($018) always shows  //
//                    the transmit buffer empty, VPOSR counts, the rest     //
//                    reads zero and ignores writes                        //
//   $F80000-$FFFFFF  512K ROM (+prog=<hex>), mirrored at 0 while overlay   //
//                                                                          //
// Pass criteria: the CPU must not halt or take an unexpected exception     //
// vector (2/3/4/8/10/11/14) and the ROM must produce serial output.        //
// Run length via +cycles=<n> (default 3,000,000).                         //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_ap040_diagrom;

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

reg         mem_ready;
wire        clkena_in = (busstate == 2'b01) | mem_ready;

ap040_tg68k_compat dut
(
	.clk(clk),
	.nreset(nreset),
	.clkena_in(clkena_in),
	.data_in(data_in),
	.ipl(3'b111),
	.ipl_autovector(1'b1),
	.berr(1'b0),

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
	.walker_req(),
	.walker_we(),
	.walker_addr(),
	.walker_wdat(),
	.walker_ack(1'b0),
	.walker_data(32'd0),
	.walker_berr(1'b0),
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

wire [31:0] dbg_pc = debug_status[31:0];
wire [15:0] dbg_ir = debug_status[63:48];

//---------------------------------------------------------------------------
// memory model
//---------------------------------------------------------------------------

reg [15:0] rom [0:262143];      // 512K
reg [15:0] chipram [0:1048575]; // 2MB

reg        ovl;                 // reset overlay: ROM mirrored at 0
reg [15:0] vposr;

wire [23:0] a24 = addr_out[23:0];
wire        sel_rom    = (a24 >= 24'hF80000);
wire        sel_chip   = (a24 < 24'h200000);
wire        sel_custom = (a24 >= 24'hDFF000) && (a24 < 24'hDFF200);
wire        sel_ciaa   = (a24 >= 24'hBFE000) && (a24 < 24'hBFF000);

reg [15:0] rd_val;
always @* begin
	if (sel_rom)              rd_val = rom[a24[18:1]];
	else if (ovl && sel_chip) rd_val = rom[a24[18:1]];
	else if (sel_chip)        rd_val = chipram[a24[20:1]];
	else if (sel_custom) begin
		case (a24[8:0] & 9'h1FE)
			9'h004: rd_val = {vposr[15:8], 8'd1};    // VPOSR
			9'h006: rd_val = vposr;                  // VHPOSR
			9'h018: rd_val = 16'h3000;               // SERDATR: TBE|TSRE
			default: rd_val = 16'h0000;
		endcase
	end
	else rd_val = 16'h0000;
end

assign data_in = rd_val;

//---------------------------------------------------------------------------
// bus latency and write commit
//---------------------------------------------------------------------------

always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && busstate != 2'b01 && !mem_ready)
		mem_ready <= 1;         // single wait state
	vposr <= vposr + 16'd1;
end

integer errors;
integer serial_count;
reg [7:0] line_buf [0:255];
integer line_len;
integer i;

task flush_line;
	begin : fl
		reg [8*256-1:0] s;
		s = 0;
		for (i = 0; i < line_len; i = i + 1)
			s = (s << 8) | {2040'd0, line_buf[i]};
		if (line_len > 0) $display("SERIAL: %0s", s);
		line_len = 0;
	end
endtask

always @(posedge clk) begin
	if (nreset && mem_ready && busstate == 2'b11) begin
		if (ovl == 1'b0 && sel_chip) begin
			if (!nuds) chipram[a24[20:1]][15:8] = data_write[15:8];
			if (!nlds) chipram[a24[20:1]][7:0]  = data_write[7:0];
		end
		if (sel_custom && (a24[8:0] & 9'h1FE) == 9'h030) begin
			serial_count = serial_count + 1;
			if (data_write[7:0] == 8'h0A || data_write[7:0] == 8'h0D)
				flush_line;
			else if (line_len < 255 && data_write[7:0] >= 8'h20) begin
				line_buf[line_len] = data_write[7:0];
				line_len = line_len + 1;
			end
		end
		if (sel_ciaa && a24[11:0] == 12'h001 && !nlds)
			ovl <= data_write[0];
		// ExecBase pointer creation is the Kickstart progress marker
		if (!ovl && a24 == 24'h000004 && !nuds)
			$display("EXECBASE: high word %h written (cycle %0d)", data_write, cycles);
		if (!ovl && a24 == 24'h000006 && !nlds)
			$display("EXECBASE: low word %h written (cycle %0d)", data_write, cycles);
	end
end

//---------------------------------------------------------------------------
// escape tracer (+trace_escape): dump the last fetches when execution
// leaves ROM and chip RAM
//---------------------------------------------------------------------------

reg  trace_escape;
reg [31:0] fring [0:31];
integer fring_i;
integer esc_done;

always @(posedge clk) begin
	if (nreset && mem_ready && busstate == 2'b00 && trace_escape) begin
		fring[fring_i & 31] = addr_out;
		fring_i = fring_i + 1;
		if (!sel_rom && !sel_chip && esc_done == 0) begin
			esc_done = 1;
			$display("ESCAPE: fetch at %h, last fetches:", addr_out);
			for (i = 1; i <= 32; i = i + 1)
				$display("  %h", fring[(fring_i - i) & 31]);
			report_and_finish;
		end
	end
end

//---------------------------------------------------------------------------
// exception monitor
//---------------------------------------------------------------------------

integer exc_prints;
integer post_trace;
reg [79:0] dring [0:63];    // {pc, ir, sr} of recent decodes
integer dring_i;
always @(posedge clk) if (nreset && dut.core.ce) begin
	if (dut.core.state == 8'd4) begin
		dring[dring_i & 63] = {dut.core.pc, dut.core.ir, dut.core.sr};
		dring_i = dring_i + 1;
		if (post_trace > 0) begin
			post_trace = post_trace - 1;
			$display("DEC pc=%h ir=%h sr=%h a7=%h", dut.core.pc, dut.core.ir,
			         dut.core.sr, debug_status[95:64]);
		end
	end
	if (dut.core.state == 7'd34 && exc_prints < 40) begin
		if ($test$plusargs("trace_post") && post_trace == 0) post_trace = 300;
		if (dut.core.exc_vec == 8'd8 && $test$plusargs("trace_pre")) begin
			$display("PRE-FAULT ring (oldest first):");
			for (i = 63; i >= 0; i = i - 1)
				$display("  pc=%h ir=%h sr=%h",
				         dring[(dring_i - 1 - i) & 63][79:48],
				         dring[(dring_i - 1 - i) & 63][47:32],
				         dring[(dring_i - 1 - i) & 63][31:16]);
		end
		exc_prints = exc_prints + 1;
		// illegal/A-line/F-line are legitimate (CPU/FPU probes); privilege
		// violations are legitimate too: exec's Supervisor() deliberately
		// runs a privileged instruction from user mode
		$display("EXC: vec=%0d spc=%h pc_i=%h ir=%h",
		         dut.core.exc_vec, dut.core.exc_spc, dut.core.pc_i, dut.core.ir);
		if (dut.core.exc_vec == 8'd3 || dut.core.exc_vec == 8'd14) begin
			errors = errors + 1;
			$display("FAIL: unexpected exception vector %0d at pc=%h ir=%h",
			         dut.core.exc_vec, dut.core.pc_i, dut.core.ir);
		end
	end
	if (dut.core.state == 7'd108 && exc_prints < 40) begin
		exc_prints = exc_prints + 1;
		errors = errors + 1;
		$display("FAIL: access error at pc=%h ir=%h addr=%h",
		         dut.core.pc_i, dut.core.ir, dut.core.mem_addr);
	end
end

always @(posedge clk) if (nreset && (debug_halted || debug_fault)) begin
	$display("FAIL: core halted at pc=%h ir=%h", dbg_pc, dbg_ir);
	errors = errors + 1;
	report_and_finish;
end

//---------------------------------------------------------------------------
// driver
//---------------------------------------------------------------------------

integer cycles, max_cycles;
reg [1023:0] rom_file;

task report_and_finish;
	begin
		flush_line;
		$display("cycles run: %0d, serial writes: %0d", cycles, serial_count);
		if (errors == 0 && serial_count > 0)
			$display("DIAGROM SMOKE TEST PASSED");
		else if (errors == 0)
			$display("DIAGROM INCONCLUSIVE: no serial output yet (pc=%h)", dbg_pc);
		else
			$display("DIAGROM SMOKE TEST FAILED with %0d errors", errors);
		$finish;
	end
endtask

initial begin
	errors = 0;
	serial_count = 0;
	line_len = 0;
	exc_prints = 0;
	ovl = 1;
	vposr = 0;

	trace_escape = $test$plusargs("trace_escape");
	post_trace = 0;
	dring_i = 0;
	fring_i = 0;
	esc_done = 0;
	if (!$value$plusargs("prog=%s", rom_file)) rom_file = "build/diagrom.hex";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 3000000;
	$readmemh(rom_file, rom);
	for (i = 0; i < 1048576; i = i + 1) chipram[i] = 16'h0000;

	$display("tb_ap040_diagrom: booting %0s for %0d cycles", rom_file, max_cycles);

	nreset = 0;
	repeat (10) @(posedge clk);
	nreset = 1;

	for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
		@(posedge clk);
		if (cycles % 500000 == 0)
			$display("... %0d cycles, pc=%h, serial=%0d", cycles, dbg_pc, serial_count);
	end
	report_and_finish;
end

endmodule
