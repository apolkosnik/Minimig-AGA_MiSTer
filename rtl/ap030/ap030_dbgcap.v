//--------------------------------------------------------------------------//
// ap030_dbgcap.v - on-board debug capture for the AP030 (JTAG readout)     //
//                                                                          //
// Records, in the processor clock domain:                                  //
//   - the last 256 instruction addresses (dbg_inst), frozen at the first   //
//     bus error, address error, illegal, line A, format error, the second  //
//     line F, execution below $400, a RESET instruction or a halt         //
//   - the last 32 exceptions other than interrupts: vector, stacked SR,    //
//     stacked PC, the instruction address and opcode; frozen at a RESET    //
//     instruction or a halt (Kickstart's reboot after a failure)           //
// Neither is cleared by a processor or system reset; a JTAG write of the   //
// clear toggle rearms them.                                                //
//                                                                          //
// Readout through In-System Sources and Probes (instance id "A030"):       //
//   source[15:0] = {clear toggle, 5'd0, select exceptions, select bus,     //
//                   addr[7:0]}; the bus ring (frozen with the pc ring)     //
//   entry (bus ring) = {48'd0, bus_wp, 1'b0, fast, fc, rw, siz, a, d}     //
//     (processor writes only); select both bits for the posted-write ring: //
//   entry (fe ring)  = {fe_wp, 19'd0, ddr address[28:0], be[7:0], d[63:0]}//
//   probe[167:0] = {tr_wp[7:0], pc_frozen, exc_frozen, cause[5:0],        //
//                   resets[7:0], pc_wp[7:0], exc_wp[4:0], tr_frozen,      //
//                   tr_trig, 1'b0, entry[127:0]}; source bit 10 selects   //
//                   the clock ring (entry = core dbg_trace)               //
//   entry (pc ring)  = {16'd0, isp, ea (both before this instruction), sr, pc} //
//   entry (exc ring) = {24'd0, vec, esr, epc, pc, ir}                     //
//--------------------------------------------------------------------------//
module ap030_dbgcap
(
	input         clk,
	input         cpu_rst,        // the processor is held in reset
	input         dbg_inst,
	input  [31:0] dbg_pc,
	input  [15:0] dbg_sr,
	input   [7:0] dbg_state,
	input   [7:0] dbg_vec,
	input  [31:0] dbg_epc,
	input  [15:0] dbg_esr,
	input  [15:0] dbg_ir,
	input  [31:0] dbg_ea,
	input  [31:0] dbg_isp,
	input [127:0] dbg_trace,      // per-clock sequencer view (ap030_core dbg_trace)
	input         reset_n_oe,     // low: the RESET instruction drives the pin
	input         halted,
	// processor bus transfers as terminated at the pins
	input         bus_stb,
	input  [31:0] bus_a,
	input  [31:0] bus_d,
	input         bus_rw,
	input   [1:0] bus_siz,
	input   [2:0] bus_fc,
	input         bus_fast,
	// writes posted by the Fast RAM front end: {ddr address, byte enables, data}
	input         fe_stb,
	input [100:0] fe_cmd
);

localparam [7:0] S_EXC0 = 8'd74;

wire [15:0] src;
reg  [15:0] src_s1, src_s2;
always @(posedge clk) begin src_s1 <= src; src_s2 <= src_s1; end
wire       sel_tr  = src_s2[10];
wire       sel_exc = src_s2[9] && !sel_tr;
wire       sel_bus = src_s2[8] && !src_s2[9] && !sel_tr;
wire       sel_fe  = src_s2[8] && src_s2[9] && !sel_tr;
wire [7:0] raddr   = src_s2[7:0];

reg        clr_seen = 0;
wire       clr     = (src_s2[15] != clr_seen);

reg [111:0] pc_ring  [0:255];   // {isp, ea, sr, pc}
reg [71:0] bus_ring [0:255];   // {fast, fc, rw, siz, a, d}
reg  [7:0] bus_wp = 0;
reg [100:0] fe_ring [0:255];
reg  [7:0] fe_wp = 0;
reg [103:0] exc_ring [0:31];
reg  [7:0] pc_wp = 0;
reg  [4:0] exc_wp = 0;
reg        pc_frozen = 0, exc_frozen = 0;
reg  [5:0] cause = 0;
reg  [7:0] resets = 0;
reg  [1:0] fline_seen = 0;
reg        exc_prev = 0, rst_prev = 0;
// clock ring: dbg_trace every clock, frozen 8 clocks after the instruction
// following Supervisor()'s MOVE.W SR,(A7) ($F80C9C) starts with the EA that
// MOVE left behind different from the stack pointer
reg [127:0] tr_ring [0:255];
reg  [7:0] tr_wp = 0;
reg        tr_trig = 0, tr_frozen = 0;
reg  [3:0] tr_cnt = 0;
reg  [4:0] low_arm = 0;        // instructions since the last processor reset (saturating)
always @(posedge clk)
	if (cpu_rst) low_arm <= 5'd0;
	else if (dbg_inst && low_arm != 5'd31) low_arm <= low_arm + 1'd1;

wire exc_entry = (dbg_state == S_EXC0) && !exc_prev;
wire is_irq    = (dbg_vec >= 8'd24) && (dbg_vec <= 8'd31);
wire fatal     = (dbg_vec == 8'd2) || (dbg_vec == 8'd3) || (dbg_vec == 8'd4) ||
                 (dbg_vec == 8'd10) || (dbg_vec == 8'd14) ||
                 (dbg_vec == 8'd11 && fline_seen != 2'd0);
wire rst_insn  = !reset_n_oe && !rst_prev && !cpu_rst;

always @(posedge clk) begin
	exc_prev <= (dbg_state == S_EXC0);
	rst_prev <= !reset_n_oe;
	if (clr) begin
		clr_seen <= src_s2[15];
		pc_frozen <= 1'b0; exc_frozen <= 1'b0; cause <= 6'd0; fline_seen <= 2'd0;
		tr_trig <= 1'b0; tr_frozen <= 1'b0; tr_cnt <= 4'd0;
	end else begin
		if (!tr_frozen) begin
			tr_ring[tr_wp] <= dbg_trace;
			tr_wp <= tr_wp + 1'd1;
		end
		if (!tr_trig && dbg_inst && dbg_pc == 32'h00F80C9C && dbg_ea != dbg_isp) tr_trig <= 1'b1;
		if (tr_trig && !tr_frozen) begin
			tr_cnt <= tr_cnt + 1'd1;
			if (tr_cnt == 4'd7) tr_frozen <= 1'b1;
		end
		if (!cpu_rst && dbg_inst && !pc_frozen) begin
			pc_ring[pc_wp] <= {dbg_isp, dbg_ea, dbg_sr, dbg_pc};
			pc_wp <= pc_wp + 1'd1;
		end
		if (!cpu_rst && fe_stb && !pc_frozen) begin
			fe_ring[fe_wp] <= fe_cmd;
			fe_wp <= fe_wp + 1'd1;
		end
		if (!cpu_rst && bus_stb && !bus_rw && !pc_frozen) begin   // writes only
			bus_ring[bus_wp] <= {1'b0, bus_fast, bus_fc, bus_rw, bus_siz, bus_a, bus_d};
			bus_wp <= bus_wp + 1'd1;
		end
		if (!cpu_rst && exc_entry && !is_irq && !exc_frozen) begin
			exc_ring[exc_wp] <= {dbg_vec, dbg_esr, dbg_epc, dbg_pc, dbg_ir};
			exc_wp <= exc_wp + 1'd1;
		end
		if (!cpu_rst && exc_entry && dbg_vec == 8'd11 && fline_seen != 2'd3) fline_seen <= fline_seen + 1'd1;
		if (!cpu_rst && exc_entry && fatal && !pc_frozen) begin
			pc_frozen <= 1'b1;
			cause <= dbg_vec[5:0];
		end
		// execution in the first 1K (the vector table): the ring then ends
		// with the instruction that transferred control there
		if (!cpu_rst && dbg_inst && !pc_frozen && dbg_pc < 32'h400 && !dbg_sr[13] && low_arm == 5'd31) begin   // user mode
			pc_frozen <= 1'b1;
			cause <= 6'h3D;
		end
		if (rst_insn || (halted && !cpu_rst)) begin
			if (!pc_frozen) begin pc_frozen <= 1'b1; cause <= halted ? 6'h3F : 6'h3E; end
			exc_frozen <= 1'b1;
		end
		if (rst_insn && resets != 8'hFF) resets <= resets + 1'd1;
	end
end

reg [127:0] entry;
always @(posedge clk) entry <= sel_tr  ? tr_ring[raddr] :
                               sel_fe  ? {fe_wp, 19'd0, fe_ring[raddr]} :
                               sel_exc ? {24'd0, exc_ring[raddr[4:0]]} :
                               sel_bus ? {48'd0, bus_wp, bus_ring[raddr]} : {16'd0, pc_ring[raddr]};

wire [167:0] probe = {tr_wp, pc_frozen, exc_frozen, cause, resets, pc_wp, exc_wp, tr_frozen, tr_trig, 1'b0, entry};

`ifndef VERILATOR
altsource_probe #(
	.sld_auto_instance_index("YES"),
	.sld_instance_index(0),
	.instance_id("A030"),
	.probe_width(168),
	.source_width(16),
	.source_initial_value("0"),
	.enable_metastability("NO"),
	.lpm_type("altsource_probe"),
	.lpm_hint("UNUSED")
) issp (
	.probe(probe),
	.source(src),
	.source_ena(1'b1),
	.source_clk(clk)
);
`else
assign src = 16'd0;
`endif

endmodule
