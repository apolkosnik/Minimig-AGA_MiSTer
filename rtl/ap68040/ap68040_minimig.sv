//--------------------------------------------------------------------------//
// ap68040_minimig.sv - the AP68040 on the Minimig's 16-bit bus              //
//                                                                          //
// The core presents the real 68040 bus (rtl/ap68040/ap68040.sv); this     //
// module is its only slave.  Every transfer becomes one request to         //
// ap040_bus16_adapter, which lives in the system clock domain and runs    //
// the request as 16-bit sub-cycles on the Minimig's chip, fast-chip and   //
// RAM ports under the contract those ports were built around.  The two    //
// clocks come from one PLL with aligned edges (clk is twice the system    //
// clock), so the request and the acknowledge cross as plain registered    //
// signals that the fitter times like any other path.                      //
//                                                                          //
//  * TBI is held asserted: a line transfer runs as four long-word          //
//    transfers (MC68040UM 7.4.4), each a request here.                    //
//  * TCI (MC68040UM 4.3.2) is asserted for every transfer outside the     //
//    configured Zorro II/III fast RAM: only fast RAM enters the caches,  //
//    whatever the MMU and the TTRs say (with translation off a 68040     //
//    caches everything).  Chip RAM changes under chipset DMA that nothing //
//    snoops, and old programs modify code there without flushing; device  //
//    registers, the ROM and the RTG space stay out too.  A TCI line is   //
//    never allocated, in either cache, so nothing of them is ever hit.   //
//  * An interrupt acknowledge (TT = 3) is answered with AVEC, as the       //
//    Amiga autovectors every level; a level-7 acknowledge flips           //
//    nmi_ack_toggle for the cartridge monitor.  A breakpoint acknowledge  //
//    is answered with TA, which makes BKPT an illegal instruction.        //
//  * The bus watchdog's berr ends the transfer in progress with TEA, a    //
//    bus error; a transfer that starts while berr is still being          //
//    withdrawn waits for it to clear.                                     //
//  * Byte and word write data come from the 68040's byte lanes (table     //
//    7-1); read data is replicated on every lane of its size, so the      //
//    core's own lane select finds it wherever it looks.                   //
//  * BG is held asserted and there is no other master: no snooping and no //
//    arbitration.  A locked sequence needs nothing: this slave runs one   //
//    transfer at a time.                                                  //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap68040_minimig
#(
	parameter logic [7:0] FPU_REVISION = 8'h41,
	parameter bit         FPU_PIPE     = 0,
	parameter bit         LOOP_PRED    = 0,
	parameter bit         EARLY_RES    = 0,
	parameter bit         DC1_ATC      = 1,      // DC1's own ATC port: the engine's stolen lookup off DC1's critical path (+200 ALMs)
	parameter bit         SKID         = 0,
	parameter int         DIV_STEPS    = 2
)
(
	input  logic        clk,            // the processor clock
	input  logic        nreset,

	// the cacheable window: the configured Zorro II/III fast RAM (from the
	// wrapper's autoconfig; changes only while the machine configures)
	input  logic        z2ram_ena,
	input  logic  [4:0] z3ram_base0,    // 128 MB block
	input  logic        z3ram_ena0,
	input  logic  [3:0] z3ram_base1,    // 256 MB block
	input  logic        z3ram_ena1,

	// the 16-bit bus adapter (system clock domain, see above)
	output logic        mem_req,        // level, until mem_ack or mem_berr
	output logic        mem_write,
	output logic        mem_instr,
	output logic  [1:0] mem_size,       // AP040_SZ_B/W/L
	output logic [31:0] mem_addr,
	output logic [31:0] mem_wdata,      // right-aligned by size
	output logic  [2:0] mem_tm,         // the transfer's TM2-TM0
	output logic        mem_ci,         // cache inhibited (CIOUT)
	input  logic        mem_ack,        // one system clock: mem_rdata valid
	input  logic [31:0] mem_rdata,      // right-aligned by size
	input  logic        mem_berr,       // level: the bus watchdog

	input  logic  [2:0] ipl_n,          // IPL2-IPL0, active low as the pins are
	output logic        nmi_ack_toggle, // flips for every level-7 acknowledge

	output logic        nresetout,      // RSTO: the RESET instruction
	output logic [31:0] cacr_out,
	output logic [31:0] vbr_out,
	output logic        cache_maint_toggle, // flips for every completed CINV/CPUSH
	output logic        debug_halted,
	output logic [31:0] debug_pc
);

//--------------------------------------------------------------------------
// the core
//--------------------------------------------------------------------------
logic [31:0] a_o, d_o, d_i;
logic        ts_n, rw_n, ciout_n, ta_n, tea_n, tci_n, rsto_n, cmaint;
logic  [1:0] siz, tt;
logic  [2:0] tm;

ap68040 #(
	.FPU_REVISION(FPU_REVISION), .FPU_PIPE(FPU_PIPE), .LOOP_PRED(LOOP_PRED),
	.EARLY_RES(EARLY_RES), .DC1_ATC(DC1_ATC), .SKID(SKID), .DIV_STEPS(DIV_STEPS)
) core (
	.clk(clk), .bclk_en(1'b1), .rsti_n(nreset),
	.a_o(a_o), .a_oe(),
	// no other master: nothing to snoop
	.a_i(32'd0), .ts_n_i(1'b1), .rw_n_i(1'b1), .siz_i(2'd0), .tt_i(2'd0), .sc(2'd0),
	.mi_n(), .ta_n_o(), .ta_oe(),
	.d_i(d_i), .d_o(d_o), .d_oe(),
	.rw_n(rw_n), .siz(siz), .tt(tt), .tm(tm), .tln(), .upa(),
	.ciout_n(ciout_n), .lock_n(), .locke_n(),
	.ts_n(ts_n), .tip_n(), .ta_n(ta_n), .tea_n(tea_n),
	.tci_n(tci_n), .tbi_n(1'b0),
	.ipl_n(ipl_n), .avec_n(1'b0),
	.br_n(), .bg_n(1'b0), .bb_n_i(1'b1), .bb_n_o(), .bb_oe(),
	.rsto_n(rsto_n), .cdis_n(1'b1), .mdis_n(1'b1), .ipend_n(), .pst(),
	.dbg_pc(debug_pc), .dbg_retire(), .dbg_halted(debug_halted),
	.dbg_vbr(vbr_out), .dbg_cacr(cacr_out), .dbg_cmaint(cmaint)
);

assign nresetout = rsto_n;

always_ff @(posedge clk) begin
	if (!nreset)     cache_maint_toggle <= 1'b0;
	else if (cmaint) cache_maint_toggle <= ~cache_maint_toggle;
end

//--------------------------------------------------------------------------
// the transfer to request conversion
//--------------------------------------------------------------------------
// write data by byte lane (MC68040UM table 7-1), right-aligned for the adapter
function automatic logic [31:0] wlane(input logic [1:0] s, input logic [1:0] a, input logic [31:0] d);
	case (s)
		2'b01:   wlane = {24'd0, a[1] ? (a[0] ? d[7:0] : d[15:8]) : (a[0] ? d[23:16] : d[31:24])};
		2'b10:   wlane = {16'd0, a[1] ? d[15:0] : d[31:16]};
		default: wlane = d;
	endcase
endfunction

// SIZ1-SIZ0 to the adapter's size (a line is its first long word)
function automatic logic [1:0] asz(input logic [1:0] s);
	case (s)
		2'b01:   asz = `AP040_SZ_B;
		2'b10:   asz = `AP040_SZ_W;
		default: asz = `AP040_SZ_L;
	endcase
endfunction

// read data on every lane of its size
function automatic logic [31:0] rlane(input logic [1:0] s, input logic [31:0] d);
	case (s)
		`AP040_SZ_B: rlane = {4{d[7:0]}};
		`AP040_SZ_W: rlane = {2{d[15:0]}};
		default:     rlane = d;
	endcase
endfunction

localparam logic [1:0] C_IDLE = 2'd0,   // waiting for TS
                       C_REQ  = 2'd1,   // the request is with the adapter
                       C_ACK  = 2'd2,   // TA or TEA driven this bus clock
                       C_BERR = 2'd3;   // the watchdog's berr being withdrawn

logic [1:0] st;
logic       pend;       // a transfer arrived while berr was being withdrawn
logic       err_ack;    // the acknowledge being driven is TEA
logic       cach;       // the transfer's address is in the cacheable window

// the configured fast RAM (as cpu_wrapper decodes it for the RAM port)
function automatic logic fastram(input logic [31:0] a, input logic z2, input logic [4:0] b0,
                                 input logic e0, input logic [3:0] b1, input logic e1);
	fastram = ((a[31:27] == b0) && e0) || ((a[31:28] == b1) && e1) ||
	          ((a[31:24] == 8'd0) && (a[23] ^ |a[22:21]) && z2);
endfunction

wire ts   = !ts_n;
wire iack = (tt == 2'd3);   // interrupt or breakpoint acknowledge

always_ff @(posedge clk) begin
	ta_n  <= 1'b1;
	tea_n <= 1'b1;
	tci_n <= 1'b1;
	if (!nreset) begin
		st             <= C_IDLE;
		pend           <= 1'b0;
		err_ack        <= 1'b0;
		mem_req        <= 1'b0;
		mem_write      <= 1'b0;
		mem_instr      <= 1'b0;
		mem_size       <= 2'd0;
		mem_addr       <= '0;
		mem_wdata      <= '0;
		mem_tm         <= '0;
		mem_ci         <= 1'b0;
		cach           <= 1'b0;
		d_i            <= '0;
		nmi_ack_toggle <= 1'b0;
	end
	else begin
		// every memory transfer is latched as it starts (TS lasts one bus
		// clock); the core holds the address and data until TA
		if (ts && !iack) begin
			mem_write <= !rw_n;
			mem_instr <= (tm == 3'd2) || (tm == 3'd6);   // user, supervisor code
			mem_size  <= asz(siz);
			mem_addr  <= a_o;
			mem_wdata <= wlane(siz, a_o[1:0], d_o);
			mem_tm    <= tm;
			mem_ci    <= !ciout_n;
			cach      <= fastram(a_o, z2ram_ena, z3ram_base0, z3ram_ena0, z3ram_base1, z3ram_ena1);
		end
		// an acknowledge cycle is answered at once, in any state
		if (ts && iack) begin
			ta_n <= 1'b0;
			d_i  <= '0;
			if (tm == 3'd7) nmi_ack_toggle <= ~nmi_ack_toggle;
		end

		case (st)
		C_IDLE: begin
			if (ts && !iack) begin
				if (mem_berr) begin
					pend <= 1'b1;
					st   <= C_BERR;
				end
				else begin
					mem_req <= 1'b1;
					st      <= C_REQ;
				end
			end
		end

		C_REQ: begin
			if (mem_ack) begin
				mem_req <= 1'b0;
				d_i     <= rlane(mem_size, mem_rdata);
				ta_n    <= 1'b0;
				tci_n   <= cach;      // sampled with the first TA of a line
				err_ack <= 1'b0;
				st      <= C_ACK;
			end
			else if (mem_berr) begin
				mem_req <= 1'b0;
				tea_n   <= 1'b0;
				err_ack <= 1'b1;
				st      <= C_ACK;
			end
		end

		C_ACK: st <= err_ack ? C_BERR : C_IDLE;

		C_BERR: begin
			// the watchdog clears berr once the adapter has dropped the
			// request; a transfer that started meanwhile goes then
			if (ts && !iack) pend <= 1'b1;
			if (!mem_berr) begin
				if (pend || (ts && !iack)) begin
					pend    <= 1'b0;
					mem_req <= 1'b1;
					st      <= C_REQ;
				end
				else st <= C_IDLE;
			end
		end

		default: st <= C_IDLE;
		endcase
	end
end

endmodule
