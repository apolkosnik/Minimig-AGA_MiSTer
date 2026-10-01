//--------------------------------------------------------------------------//
// tb_ap030_kick.sv - boots a real Kickstart ROM on the AP030 behind the    //
// Minimig compat layer (ap030_tg68k_compat), after tb_ap040_diagrom.v      //
//                                                                          //
// Minimal Amiga memory model on the 16-bit Minimig CPU bus:                //
//   $000000-$1FFFFF  2MB chip RAM (ROM mirrored at 0 while OVL is set)     //
//   $BFE001          CIA-A PRA: bit 0 is OVL                               //
//   $DFF000-$DFF1FF  custom chips: VPOSR/VHPOSR count, SERDAT is printed,  //
//                    the rest reads zero and ignores writes                //
//   $F80000-$FFFFFF  512K ROM (+rom=<16-bit word hex>)                     //
//                                                                          //
// Reports every exception, RESET instruction and restart at the ROM entry  //
// ($F800D2), the ExecBase writes, and the last instructions before a       //
// restart or a halt.  +cycles=<n> sets the run length in clk_cpu cycles.   //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ap030_kick;

reg clk = 0, clk_cpu = 0;
always #17.5 clk = ~clk;       // ~28.6 MHz Minimig bus
always #10   clk_cpu = ~clk_cpu;  // 50 MHz processor
reg nreset = 0;

wire [31:0] addr_out;
wire [15:0] data_write;
wire        nwr, nuds, nlds, longword, nresetout, halted;
wire  [1:0] busstate;
wire  [2:0] fc;
reg         mem_ready = 0;
wire        clkena_in = (busstate == 2'b01) | mem_ready;
reg  [15:0] rd_val;

ap030_tg68k_compat dut (
	.clk(clk), .clk_cpu(clk_cpu), .clk_mem(clk_cpu), .nreset(nreset),
	.clkena_in(clkena_in), .data_in(rd_val), .ipl(3'b111), .berr(1'b0),
	.snoop_stb(1'b0), .snoop_addr(32'd0),
	.z2ram_ena(1'b0), .z3ram_base0(5'd0), .z3ram_ena0(1'b0), .z3ram_base1(4'd0), .z3ram_ena1(1'b0),
	.addr_out(addr_out), .data_write(data_write), .nwr(nwr), .nuds(nuds), .nlds(nlds),
	.busstate(busstate), .longword(longword), .fc(fc), .nresetout(nresetout), .nmi_ack_toggle(),
	.cache_maint_req(), .mmu_cache_inhibit(), .cacr_out(), .vbr_out(), .debug_halted(halted),
	.fr_address(), .fr_burstcount(), .fr_read(), .fr_write(), .fr_writedata(), .fr_byteenable(),
	.fr_waitrequest(1'b1), .fr_readdata(64'd0), .fr_readdatavalid(1'b0)
);

//---------------------------------------------------------------------------
// memory model
//---------------------------------------------------------------------------
reg [15:0] rom [0:262143];
reg [15:0] chipram [0:1048575];
reg        ovl;
reg [15:0] vposr;

wire [23:0] a24 = addr_out[23:0];
wire sel_rom    = (a24 >= 24'hF80000);
wire sel_chip   = (a24 < 24'h200000);
wire sel_custom = (a24 >= 24'hDFF000) && (a24 < 24'hDFF200);
wire sel_ciaa   = (a24 >= 24'hBFE000) && (a24 < 24'hBFF000);

always @* begin
	if (sel_rom)              rd_val = rom[a24[18:1]];
	else if (ovl && sel_chip) rd_val = rom[a24[18:1]];
	else if (sel_chip)        rd_val = chipram[a24[20:1]];
	else if (sel_custom) begin
		case (a24[8:0] & 9'h1FE)
			9'h004: rd_val = {vposr[15:8], 8'd1};
			9'h006: rd_val = vposr;
			9'h018: rd_val = 16'h3000;
			default: rd_val = 16'h0000;
		endcase
	end else rd_val = 16'h0000;
end

always @(posedge clk) begin
	mem_ready <= 0;
	if (nreset && busstate != 2'b01 && !mem_ready) mem_ready <= 1;
	vposr <= vposr + 16'd1;
end

integer cycles, max_cycles, restarts, resets, errors, exc_count, i;
reg [8*80-1:0] line;
integer line_len;

always @(posedge clk) begin
	if (nreset && mem_ready && busstate == 2'b11) begin
		if (!ovl && sel_chip) begin
			if (!nuds) chipram[a24[20:1]][15:8] = data_write[15:8];
			if (!nlds) chipram[a24[20:1]][7:0]  = data_write[7:0];
		end
		if (sel_ciaa && a24[11:0] == 12'h001 && !nlds) ovl <= data_write[0];
		if (!ovl && a24 == 24'h000004 && !nuds) $display("EXECBASE hi %h (cycle %0d)", data_write, cycles);
		if (!ovl && a24 == 24'h000006 && !nlds) $display("EXECBASE lo %h (cycle %0d)", data_write, cycles);
		if (sel_custom && (a24[8:0] & 9'h1FE) == 9'h030) begin
			if (data_write[7:0] == 8'h0A || line_len >= 79) begin
				$display("SERIAL: %0s", line); line = 0; line_len = 0;
			end else if (data_write[7:0] >= 8'h20) begin
				line = {line[8*79-1:0], data_write[7:0]}; line_len = line_len + 1;
			end
		end
	end
end

//---------------------------------------------------------------------------
// monitors (processor domain)
//---------------------------------------------------------------------------
localparam [7:0] S_EXC0 = 8'd74;
reg [95:0] ring [0:127];   // {pc, ir, sr, d0 low}
integer ring_i = 0;
reg exc_seen = 0;
reg rst_seen = 0;
reg [31:0] cacr_last = 0;
reg force_dc = 0;

task dump_ring; input integer n;
	begin
		for (i = n - 1; i >= 0; i = i - 1)
			$display("  pc=%h ir=%h sr=%h a7=%h", ring[(ring_i - 1 - i) & 127][95:64],
			         ring[(ring_i - 1 - i) & 127][63:48], ring[(ring_i - 1 - i) & 127][47:32],
			         ring[(ring_i - 1 - i) & 127][31:0]);
	end
endtask

always @(posedge clk_cpu) if (nreset) begin
	if (dut.cpu.core.dbg_inst) begin
		ring[ring_i & 127] = {dut.cpu.core.pc_i, dut.cpu.core.ir, dut.cpu.core.sr,
		                      dut.cpu.core.sr[13] ? (dut.cpu.core.sr[12] ? dut.cpu.core.rf.msp : dut.cpu.core.rf.isp)
		                                          : dut.cpu.core.rf.usp};
		ring_i = ring_i + 1;
		if (dut.cpu.core.pc_i == 32'h00F800D2 && cycles > 1000) begin
			restarts = restarts + 1;
			$display("RESTART %0d at cycle %0d, last instructions:", restarts, cycles);
			dump_ring(48);
			if (restarts >= 2) finish_run;
		end
	end
	if (dut.cpu.core.state == S_EXC0 && !exc_seen) begin
		exc_count = exc_count + 1;
		if (exc_count <= 200)
			$display("EXC vec=%0d pc_i=%h ir=%h sr=%h (cycle %0d)", dut.cpu.core.exc_vec,
			         dut.cpu.core.pc_i, dut.cpu.core.ir, dut.cpu.core.sr, cycles);
	end
	exc_seen <= (dut.cpu.core.state == S_EXC0);
	if (dut.cpu.core.cacr !== cacr_last) begin
		$display("CACR %h -> %h at pc=%h (cycle %0d)", cacr_last, dut.cpu.core.cacr, dut.cpu.core.pc_i, cycles);
		cacr_last <= dut.cpu.core.cacr;
		// +force_dc: turn the data cache, data burst and write allocate on
		// (and keep the instruction cache and its burst) whenever the
		// processor writes CACR
		if (force_dc && dut.cpu.core.cacr != 32'h3111 && dut.cpu.core.cacr[0]) begin
			dut.cpu.core.cacr = 32'h3111;
			$display("CACR forced to 3111");
		end
	end
	if (!nresetout && !rst_seen) begin
		resets = resets + 1;
		$display("RESET instruction at pc=%h (cycle %0d), last instructions:", dut.cpu.core.pc_i, cycles);
		dump_ring(48);
	end
	rst_seen <= !nresetout;
	if (halted) begin
		$display("HALTED at cycle %0d, last instructions:", cycles);
		dump_ring(48);
		errors = errors + 1;
		finish_run;
	end
end

task finish_run;
	begin
		$display("cycles %0d, restarts %0d, RESET instructions %0d, exceptions %0d, pc=%h",
		         cycles, restarts, resets, exc_count, dut.cpu.core.pc_i);
		$finish;
	end
endtask

reg [1023:0] rom_file;
initial begin
	errors = 0; restarts = 0; resets = 0; exc_count = 0; ovl = 1; vposr = 0; line = 0; line_len = 0;
	force_dc = $test$plusargs("force_dc");
	if (!$value$plusargs("rom=%s", rom_file)) rom_file = "build/kick.hex";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 20000000;
	$readmemh(rom_file, rom);
	for (i = 0; i < 1048576; i = i + 1) chipram[i] = 16'h0000;
	$display("tb_ap030_kick: %0s for %0d cycles", rom_file, max_cycles);
	repeat (20) @(posedge clk);
	nreset = 1;
	for (cycles = 0; cycles < max_cycles; cycles = cycles + 1) begin
		@(posedge clk_cpu);
		if (cycles % 1000000 == 0) $display("... cycle %0d pc=%h d0=%h", cycles, dut.cpu.core.pc_i, dut.cpu.core.rf.r[0]);
	end
	finish_run;
end

endmodule
