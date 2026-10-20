// tb_fx68k: runs a 68000/68010 test program on the real fx68k core.
//
// Plusargs:
//   +hex=<file>     memory image ($readmemh, 16-bit words from address 0)
//   +cpu010=<0|1>   68010 mode (ignored with FX68K_ORIG, the original core)
//   +trace=<file>   bus cycle trace
//   +dump=<file>    result area dump at the end of the test
//   +wait=<n>       DTACK wait clocks (default 0)
//   +maxclk=<n>     timeout in clocks
//   +itime=<file>   instruction timing log: CPU clock, PC, opcode, exception, SR, D0-D7
//                   at the start of every instruction
//   +bkpt=<n>       end of the breakpoint acknowledge cycle (CPU space, A19-A16 = 0):
//                   0 VPA like the interrupt acknowledge (default), 1 DTACK, 2 BERR
//   +utrace=<file>  microcode trace: CPU clock and microaddress of every microcycle when it starts
//
// Memory map:
//   000000-0FFFFF  RAM
//   FD0000-FDFFFF  RAM mirror of 0D0000-0DFFFF, the function code and
//                  direction of the last access is readable at FF0010
//   FC0000-FCFFFF  RAM mirror of 0D0000-0DFFFF with a bus error on one access, see FF001C
//   FE0000-FEFFFF  bus error (BERR)
//   FF0000 (W)     end of test, data = status (0 = pass)
//   FF0002 (W)     IPL level (0-7)
//   FF0004 (W)     debug character
//   FF0010 (R)     probe: bit 3 = read, bits 2:0 = FC of the last FD access
//   FF0012 (R)     instruction fetch bus cycles (FC 2 or 6), 16 bits. (W) clears it
//   FF0014 (R)     CPU clock counter, high word. Reading it latches the low word
//   FF0016 (R)     CPU clock counter, latched low word
//   FF0018 (R)     breakpoint acknowledge cycles (CPU space, address 0)
//   FF001A (R)     CPU clock counter, low word (not latched)
//   FF001C (W)     bus error on the n-th access to FC0000-FCFFFF from now on (n = data,
//                  0 = none); a single fault, the next accesses work
//   Interrupt acknowledge cycles are autovectored (VPA), like Minimig.
//
// The test result area 008000-00FFFF is dumped as hex words.

`timescale 1ns/1ns

module tb_fx68k;

reg clk = 0;
always #5 clk = ~clk;

reg [1:0] div = 0;
always @(posedge clk) div <= div + 1'd1;
wire enPhi1 = (div == 2'd3);
wire enPhi2 = (div == 2'd1);

reg extReset = 1;

wire eRWn, ASn, LDSn, UDSn, E, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
wire [15:0] oEdb;
wire [23:1] eab;
wire [31:0] VBR;
reg cpu010 = 0;
reg DTACKn = 1, VPAn = 1, BERRn = 1;
reg [2:0] ipl = 0;
reg [15:0] iEdb;

fx68k dut
(
	.clk(clk),
	.HALTn(1'b1),
	.extReset(extReset),
	.pwrUp(extReset),
	.enPhi1(enPhi1),
	.enPhi2(enPhi2),
	.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
	.E(E), .VMAn(VMAn),
	.FC0(FC0), .FC1(FC1), .FC2(FC2),
	.BGn(BGn),
	.oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
	.DTACKn(DTACKn), .VPAn(VPAn),
	.BERRn(BERRn),
	.BRn(1'b1), .BGACKn(1'b1),
	.IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
	.iEdb(iEdb), .oEdb(oEdb),
	.eab(eab)
`ifndef FX68K_ORIG
	,
	.cpu010(cpu010),
	.VBR(VBR)
`endif
);

wire [2:0] fc = {FC2, FC1, FC0};
wire [23:0] addr = {eab, 1'b0};

reg [15:0] mem[0:524287];

wire is_ram    = (addr[23:20] == 4'h0);
integer bkptmode = 0;
wire is_bkptc  = (fc == 3'b111) & (addr[19:16] == 4'h0);
wire is_fmirror = (addr[23:16] == 8'hFC);
wire is_mirror = (addr[23:16] == 8'hFD) | is_fmirror;
reg c_fault = 0;							// this FC0000 cycle gets a bus error
reg [15:0] nfault = 0;					// FF001C
reg in_cycle = 0;
wire is_berr   = (is_bkptc & (bkptmode == 2)) | (addr[23:16] == 8'hFE) | (is_fmirror & (in_cycle ? c_fault : (nfault == 16'd1)));
wire is_io     = (addr[23:16] == 8'hFF);
wire is_iack   = (fc == 3'b111) & ~(is_bkptc & (bkptmode != 0));
wire [18:0] widx = is_mirror ? {4'hD, addr[15:1]} : addr[19:1];

reg [3:0] probe = 0;
reg [15:0] nfetch = 0;
reg [15:0] nbkpt = 0;
reg [31:0] cpuclk = 0;
reg [15:0] clklo = 0;
always @(posedge clk) if (enPhi1) cpuclk <= cpuclk + 1;

// Reads
always @* begin
	iEdb = 16'hFFFF;
	if (is_ram | is_mirror)
		iEdb = mem[widx];
	else if (is_io && addr[15:0] == 16'h0010)
		iEdb = {12'h000, probe};
	else if (is_io && addr[15:0] == 16'h0012)
		iEdb = nfetch;
	else if (is_io && addr[15:0] == 16'h0014)
		iEdb = cpuclk[31:16];
	else if (is_io && addr[15:0] == 16'h0016)
		iEdb = clklo;
	else if (is_io && addr[15:0] == 16'h0018)
		iEdb = nbkpt;
	else if (is_io && addr[15:0] == 16'h001A)
		iEdb = cpuclk[15:0];
	else if (is_io)
		iEdb = 16'h0000;
end

integer waitclk = 0;
integer maxclk = 4000000;
integer clkcnt = 0;
integer cnt = 0;
integer ftrace = 0;
integer fitime = 0;
integer futrace = 0;
integer status = -1;
integer dcnt = 0;
reg in_data = 0;
wire ds = !UDSn || !LDSn;
reg [23:0] c_addr;
reg [2:0]  c_fc;
reg        c_rw, c_uds, c_lds;
reg [15:0] c_wdata;
integer    c_start, c_dstart;
reg        c_berr, c_data;
string     hexfile, tracefile, dumpfile;

// CRC32 of the bus cycles (start clock, direction, FC, address, strobes, data)
reg [31:0] crc = 32'hFFFFFFFF;
integer ncycles = 0;
function [31:0] crc32(input [31:0] c, input [95:0] d);
	crc32 = c;
	for (int i = 95; i >= 0; i--)
		crc32 = {crc32[30:0], 1'b0} ^ ((crc32[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
endfunction

initial begin
	int v;
	if (!$value$plusargs("hex=%s", hexfile)) begin
		$display("tb_fx68k: +hex=<file> required");
		$finish;
	end
	for (int i = 0; i < 524288; i++) mem[i] = 16'h0000;
	$readmemh(hexfile, mem);
	if ($value$plusargs("cpu010=%d", v)) cpu010 = v[0];
	if ($value$plusargs("bkpt=%d", v)) bkptmode = v;
	if ($value$plusargs("wait=%d", v)) waitclk = v;
	if ($value$plusargs("maxclk=%d", v)) maxclk = v;
	if ($value$plusargs("trace=%s", tracefile)) ftrace = $fopen(tracefile, "w");
	if ($value$plusargs("itime=%s", tracefile)) fitime = $fopen(tracefile, "w");
	if ($value$plusargs("utrace=%s", tracefile)) futrace = $fopen(tracefile, "w");
	if (!$value$plusargs("dump=%s", dumpfile)) dumpfile = "";
	repeat (40) @(posedge clk);
	extReset = 0;
end

// Bus cycles
always @(posedge clk) begin
	clkcnt <= clkcnt + 1;
	if (clkcnt > maxclk) begin
		$display("tb_fx68k: TIMEOUT after %0d clocks", clkcnt);
		status = -2;
		finish_test();
	end

	if (!oHALTEDn && !extReset) begin
		$display("tb_fx68k: CPU HALTED (double fault) at clock %0d", clkcnt);
		status = -3;
		finish_test();
	end

	// Address strobe: cycle start, interrupt acknowledge, bus error
	if (!ASn && !in_cycle) begin
		in_cycle <= 1;
		cnt <= 0;
		c_addr <= addr;
		c_fc <= fc;
		c_start <= clkcnt;
		c_berr <= 0;
		c_data <= 0;
		// FC0000: count the accesses down to the faulted one
		c_fault <= is_fmirror & (nfault == 16'd1);
		if (is_fmirror && nfault != 0)
			nfault <= nfault - 1'd1;
	end

	if (!ASn && in_cycle) begin
		cnt <= cnt + 1;
		if (cnt >= waitclk) begin
			if (is_iack)
				VPAn <= 0;
			else if (is_berr) begin
				BERRn <= 0;
				c_berr <= 1;
			end
		end
	end

	// Data strobes: one transfer each, two for a read-modify-write cycle
	if (ds && !in_data) begin
		in_data <= 1;
		dcnt <= 0;
		c_rw <= eRWn;
		c_dstart <= clkcnt;
		// no wait states: DTACK before the end of S4, also for writes (DS in S4)
		if (waitclk == 0 && !is_iack && !is_berr)
			DTACKn <= 0;
	end

	if (ds && in_data) begin
		dcnt <= dcnt + 1;
		c_uds <= UDSn;
		c_lds <= LDSn;
		c_wdata <= oEdb;
		if (dcnt >= waitclk && !is_iack && !is_berr)
			DTACKn <= 0;
	end

	if (!ds && in_data) begin
		in_data <= 0;
		c_data <= 1;
		DTACKn <= 1;
		if (!c_rw && !c_berr) do_write(c_addr, c_uds, c_lds, c_wdata);
		if (c_addr[23:16] == 8'hFD) probe <= {c_rw, c_fc};
		if (c_rw && c_fc[1:0] == 2'b10) nfetch <= nfetch + 1'd1;
		if (c_fc == 3'b111 && c_addr == 24'h000000) nbkpt <= nbkpt + 1'd1;
		if (c_rw && c_addr == 24'hFF0014) clklo <= cpuclk[15:0];
		crc = crc32(crc, {c_dstart[31:0], 4'(c_rw), 4'(c_fc), 8'(c_addr[23:16]), c_addr[15:0],
			6'd0, !c_uds, !c_lds, 7'd0, c_berr, c_rw ? mem_read(c_addr) : c_wdata});
		ncycles = ncycles + 1;
		if (ftrace)
			$fwrite(ftrace, "%0d %s fc=%0d a=%06h ds=%0d%0d d=%04h%s\n", c_dstart,
				c_rw ? "R" : "W", c_fc, c_addr, !c_uds, !c_lds,
				c_rw ? mem_read(c_addr) : c_wdata, c_berr ? " BERR" : "");
	end

	if (ASn && in_cycle) begin
		in_cycle <= 0;
		VPAn <= 1;
		BERRn <= 1;
		// cycle without data strobes: address error
		if (!c_data && !in_data) begin
			crc = crc32(crc, {c_start[31:0], 4'(eRWn), 4'(c_fc), 8'(c_addr[23:16]), c_addr[15:0], 32'hFFFFFFFF});
			ncycles = ncycles + 1;
			if (ftrace)
				$fwrite(ftrace, "%0d %s fc=%0d a=%06h no data strobe\n", c_start,
					eRWn ? "R" : "W", c_fc, c_addr);
		end
	end
end


function [15:0] mem_read(input [23:0] a);
	if (a[23:20] == 4'h0) mem_read = mem[a[19:1]];
	else if (a[23:16] == 8'hFD || a[23:16] == 8'hFC) mem_read = mem[{4'hD, a[15:1]}];
	else mem_read = 16'hFFFF;
endfunction

task do_write(input [23:0] a, input uds_n, input lds_n, input [15:0] d);
	reg [18:0] i;
	if (a[23:20] == 4'h0 || a[23:16] == 8'hFD || a[23:16] == 8'hFC) begin
		i = (a[23:16] == 8'hFD || a[23:16] == 8'hFC) ? {4'hD, a[15:1]} : a[19:1];
		if (!uds_n) mem[i][15:8] = d[15:8];
		if (!lds_n) mem[i][7:0] = d[7:0];
	end
	else if (a[23:16] == 8'hFF) begin
		case (a[15:0])
			16'h0000: begin status = d; finish_test(); end
			16'h0002: ipl <= d[2:0];
			16'h0004: $write("%c", d[7:0]);
			16'h0012: nfetch <= 0;
			16'h001C: nfault <= d;
			default: ;
		endcase
	end
endtask

// Instruction start: A1 dispatch of the instruction in IR
always @(posedge clk) begin
	if (fitime && dut.enT1 && (dut.microLatch[3:1] == 3'b010)) begin
		$fwrite(fitime, "%0d %06h %04h %0d %04h", cpuclk, {dut.excUnit.PcH[7:0], dut.excUnit.PcL} - 24'd2,
			dut.Ir, dut.sequencer.A0Sel, dut.psw);
		for (int r = 0; r < 8; r++)
			$fwrite(fitime, " %04h%04h", dut.excUnit.regs68H[r], dut.excUnit.regs68L[r]);
		$fwrite(fitime, "\n");
	end
end

// Microcode trace: the microinstruction that starts at T1 (microAddr still holds its address)
always @(posedge clk) begin
	if (futrace && dut.enT1)
		$fwrite(futrace, "%0d %03h\n", cpuclk, dut.microAddr);
end

task finish_test;
	if (dumpfile != "") $writememh(dumpfile, mem, 19'h04000, 19'h07FFF);
	if (ftrace) $fclose(ftrace);
	if (fitime) $fclose(fitime);
	if (futrace) $fclose(futrace);
	$display("tb_fx68k: END status=%0d clocks=%0d cycles=%0d crc=%08h", status, clkcnt, ncycles, crc);
	$finish;
endtask

endmodule
