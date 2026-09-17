//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_regfile.v - D0-D7, A0-A6 and the three stack pointers              //
//                                                                          //
// Register index encoding on both read ports and the write port:          //
//   0..7  = D0..D7                                                         //
//   8..14 = A0..A6                                                         //
//   15    = A7, banked to USP/ISP/MSP by the current SR.S/SR.M state       //
//                                                                          //
// Writes are full 32-bit; the core performs read-modify-write merging for  //
// byte and word register destinations.                                     //
//--------------------------------------------------------------------------//

module ap040_regfile
(
	input             clk,
	input             ce,
	input             nreset,

	// active stack pointer selection
	input             sr_s,
	input             sr_m,

	// write port
	input             we,
	input       [3:0] waddr,
	input      [31:0] wdata,

	// read ports
	input       [3:0] raddr_a,
	output     [31:0] rdata_a,
	input       [3:0] raddr_b,
	output     [31:0] rdata_b,

	// direct stack pointer access for MOVEC/MOVE USP, independent of the
	// currently active bank (never asserted together with the main write)
	input             aux_we,
	input       [1:0] aux_sel,     // 0=USP 1=ISP 2=MSP
	input      [31:0] aux_wdata,
	output     [31:0] usp_q,
	output     [31:0] isp_q,
	output     [31:0] msp_q,

	// debug taps (registered values, no extra logic on the write path)
	output     [31:0] dbg_d0,
	output     [31:0] dbg_d1,
	output     [31:0] dbg_d2,
	output     [31:0] dbg_a0,
	output     [31:0] dbg_a7
);

// D0-D7 and A0-A6 in two mirrored MLAB banks rather than flip-flops, the
// same trade the FP register file makes: an MLAB gives one write and one
// read port, so two asynchronous reads need two copies of the data.  A7 is
// not in the array -- it resolves to one of the three stack pointers below,
// which stay in flops because several consumers read them directly.
//
// MLAB contents cannot be reset, and this core resets the integer registers
// to zero, so a 15-bit "written" vector carries that instead: an entry reads
// as zero until it has been written once.
//
// READ DURING WRITE.  no_rw_check does not promise the design never reads
// and writes one address in the same cycle; it says the read data is
// undefined when it does, and asks the fitter not to spend logic defending
// against it.  Here the two coincide constantly: an instruction writing Dn
// while the next reads Dn is ordinary, and counting it found 612 such cycles
// in t_integer alone.  Flip-flops returned the NEW word in that cycle.  An
// MLAB registers its write port on the clock edge and commits the word to
// the cells with an internal pulse during the cycle that FOLLOWS; an
// asynchronous read of that address in that cycle sees the old word, the
// new one, or the transition, depending on where in the cycle it is
// sampled -- which is exactly the datum the attribute declares undefined.
// Simulation models the array as updated on the edge and cannot show any of
// this; with nothing masking it the core did not boot (eb158fb71).
//
// So the write goes to the RAM on its edge, as flip-flops would take it, and
// a copy is held in pend_*.  A read of that address during the following
// enabled cycle -- the cycle in which the MLAB is committing it -- is
// answered from the copy, and the RAM's output is not used:
//
//   cycle N    write issued: RAM write port registered, copy taken in pend_*
//   cycle N+1  MLAB commits the word; a read of that address is answered
//              from pend_wdata, not the RAM being written
//   cycle N+2  the RAM holds it
//
// In simulation the bypass is invisible -- the array already holds the word
// in cycle N+1 -- and that is the point: it changes only what hardware
// returns.  The first version of this (78e7281e4) instead DELAYED the RAM
// write by a cycle and bypassed the cycle before it.  That left the RAM
// untouched during the bypassed cycle and let the MLAB commit during the
// next, unmasked one: the undefined read moved from N+1 to N+2 instead of
// being covered, and simulation, again, could not show it.  The board ran
// Workbench on that version, so N+2 reads are rarer than N+1 reads, not
// absent.
//
// no_rw_check STAYS, and with the bypass it is honest.  Dropping the
// attribute instead was tried and is worse in both directions: without it
// Quartus will not infer an MLAB here at all -- the fit reported ALMs used
// for memory 0.0, both mirrored banks in flip-flops, 1,172 registers and 673
// ALMs against the plain array's 576 and 459 -- so the file cost 214 ALMs and
// still had no memory in it.  The defect was never the attribute on its own;
// it was the attribute with nothing masking the datum it leaves undefined.
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] bank_a [0:15];
(* ramstyle = "MLAB, no_rw_check" *) reg [31:0] bank_b [0:15];
reg [14:0] rf_written;
reg        pend_we;
reg  [3:0] pend_waddr;
reg [31:0] pend_wdata;
reg [31:0] usp;
reg [31:0] isp;
reg [31:0] msp;
reg [31:0] dbg_shadow [0:3];

// A7 resolves to the active stack pointer
wire [1:0] sp_sel = !sr_s ? 2'd0 : (sr_m ? 2'd2 : 2'd1); // 0=USP 1=ISP 2=MSP
wire [31:0] sp_active = (sp_sel == 2'd0) ? usp : (sp_sel == 2'd1) ? isp : msp;

// direct expressions, not a function: a function referencing the register
// arrays breaks continuous-assign sensitivity on some simulators
wire hit_a = pend_we && (pend_waddr == raddr_a[3:0]);
wire hit_b = pend_we && (pend_waddr == raddr_b[3:0]);
wire [31:0] q_a = hit_a ? pend_wdata
                        : (rf_written[raddr_a[3:0]] ? bank_a[raddr_a[3:0]] : 32'd0);
wire [31:0] q_b = hit_b ? pend_wdata
                        : (rf_written[raddr_b[3:0]] ? bank_b[raddr_b[3:0]] : 32'd0);
assign rdata_a = (raddr_a == 4'd15) ? sp_active : q_a;
assign rdata_b = (raddr_b == 4'd15) ? sp_active : q_b;

integer i;
always @(posedge clk) begin
	if (!nreset) begin
		rf_written <= 0;
		pend_we <= 0; pend_waddr <= 0; pend_wdata <= 0;
		dbg_shadow[0] <= 0; dbg_shadow[1] <= 0;
		dbg_shadow[2] <= 0; dbg_shadow[3] <= 0;
		usp <= 0;
		isp <= 0;
		msp <= 0;
	end
	else if (ce) begin
		// the word goes to the RAM on this edge; pend_* is the copy that
		// answers reads of it while the MLAB commits it
		pend_we <= 0;
		if (we) begin
			if (waddr != 4'd15) begin
				bank_a[waddr] <= wdata;
				bank_b[waddr] <= wdata;
				rf_written[waddr] <= 1'b1;
				pend_we <= 1;
				pend_waddr <= waddr;
				pend_wdata <= wdata;
				// the halt beacon's fixed taps would each need their own
				// mirrored bank; four shadow words are cheaper
				if (waddr == 4'd0) dbg_shadow[0] <= wdata;
				if (waddr == 4'd1) dbg_shadow[1] <= wdata;
				if (waddr == 4'd2) dbg_shadow[2] <= wdata;
				if (waddr == 4'd8) dbg_shadow[3] <= wdata;
			end
			else begin
				case (sp_sel)
					2'd0:    usp <= wdata;
					2'd1:    isp <= wdata;
					default: msp <= wdata;
				endcase
			end
		end
		if (aux_we) begin
			case (aux_sel)
				2'd0:    usp <= aux_wdata;
				2'd1:    isp <= aux_wdata;
				default: msp <= aux_wdata;
			endcase
		end
	end
end

assign usp_q = usp;
assign isp_q = isp;
assign msp_q = msp;

assign dbg_d0 = dbg_shadow[0];
assign dbg_d1 = dbg_shadow[1];
assign dbg_d2 = dbg_shadow[2];
assign dbg_a0 = dbg_shadow[3];
assign dbg_a7 = sp_active;

endmodule
