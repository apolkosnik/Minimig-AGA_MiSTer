//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_top.v - the processor with the MC68030 pin set (UM Section 5)     //
//                                                                          //
// Bidirectional and three-state pins are presented as separate input,      //
// output and enable signals so the module can be used in simulation and    //
// wrapped for an FPGA's tristate buffers:                                  //
//   D31-D0    d_i / d_o / d_oe                                              //
//   A, FC, SIZ, R/W, RMC, AS, DS, DBEN, CIOUT, CBREQ   driven when bus_oe   //
//   RESET     reset_n_i (input) / reset_n_oe (drive low: RESET instruction) //
// Active-low pins carry the _n suffix.                                     //
//--------------------------------------------------------------------------//

`include "ap030_defs.svh"

module ap030_top
(
	input             clk,

	// bus
	output     [31:0] a,
	output      [2:0] fc,
	output      [1:0] siz,
	output            rw,
	output            rmc_n,
	output            as_n,
	output            ds_n,
	output            dben_n,
	output            ecs_n,
	output            ocs_n,
	output            ciout_n,
	output            cbreq_n,
	output            bus_oe,
	output     [31:0] d_o,
	output            d_oe,
	input      [31:0] d_i,
	input             dsack0_n,
	input             dsack1_n,
	input             sterm_n,
	input             berr_n,
	input             halt_n,
	input             avec_n,
	input             ciin_n,
	input             cback_n,
	input             br_n,
	output            bg_n,
	input             bgack_n,
	// interrupts
	input       [2:0] ipl_n,
	output            ipend_n,
	// reset (open drain: input from the pin, output enable drives it low)
	input             reset_n_i,
	output            reset_n_oe,
	// emulator support
	input             cdis_n,
	input             mmudis_n,
	output            refill_n,
	output            status_n,

	// observation
	output     [31:0] dbg_pc,
	output     [15:0] dbg_sr,
	output      [7:0] dbg_state,
	output            dbg_inst,
	output            dbg_halted,
	// system glue (emulator integration): VBR, CACR, cache-clear pulses
	output     [31:0] dbg_vbr,
	output     [31:0] dbg_cacr,
	output            dbg_cache_clear,  // pulse: CACR written with CD, CED, CI or CEI set
	// system options (tie to 0 for a plain MC68030):
	//  snoop_we/snoop_addr: another bus master wrote this address; the data
	//    cache entry for it is invalidated (the MC68030 has no snooping --
	//    this is glue for systems whose DMA writes cachable-by-allocation RAM)
	//  nmi_vec_nocache: the level 7 autovector fetch bypasses the data cache
	input             snoop_we,
	input      [31:0] snoop_addr,
	input             nmi_vec_nocache
);

//---------------------------------------------------------------------------
// reset: the pin is synchronized; while the RESET instruction drives it the
// processor ignores it, and an external assertion must outlast that by
// eight clocks to reset the processor (UM 7.8)
//---------------------------------------------------------------------------
reg  [1:0] rst_sync;
reg  [3:0] rst_cnt;
reg        rst;
wire       reset_drive;
always @(posedge clk) begin
	rst_sync <= {rst_sync[0], ~reset_n_i};
	if (reset_drive) begin rst_cnt <= 4'd0; end
	else if (rst_sync[1]) begin if (rst_cnt != 4'd15) rst_cnt <= rst_cnt + 4'd1; end
	else rst_cnt <= 4'd0;
	rst <= rst_sync[1] && !reset_drive && (rst_cnt >= 4'd7 || rst);
end
initial begin rst_sync = 2'b11; rst_cnt = 4'd15; rst = 1'b1; end
assign reset_n_oe = reset_drive;

// synchronized emulator inputs
reg cdis_s, mmudis_s;
always @(posedge clk) begin cdis_s <= ~cdis_n; mmudis_s <= ~mmudis_n; end

//---------------------------------------------------------------------------
// core <-> memory subsystem
//---------------------------------------------------------------------------
wire        d_stb, d_rw, d_rmc, d_rmc_last, d_rmc_release, d_iack, d_nocache;
wire [31:0] d_addr, d_wdata, d_rdata;
wire  [1:0] d_size;
wire  [2:0] d_fc;
wire        d_ack, d_fault, d_avec, d_iack_berr, d_late_fault, d_wpend;
wire [31:0] f_addr, f_dob, f_partial;
wire  [2:0] f_fc, f_got;
wire  [1:0] f_size;
wire        f_rw, f_rm;
wire        i_stb, i_ack, i_fault, i_ready;
wire [31:0] i_addr, i_data;
wire  [2:0] i_fc;
wire        op_req, op_done, reg_we, reg_fd, cfg_err, bus_quiet;
wire  [2:0] op_kind, op_level, op_fc, op_fcmask, reg_sel;
wire [31:0] op_la, op_desc_addr, reg_wdata_hi, reg_wdata_lo;
wire [31:0] tc, srp_hi, srp_lo, crp_hi, crp_lo, tt0, tt1;
wire [15:0] mmusr;
wire [31:0] cacr;
wire        cacr_ci, cacr_cei, cacr_cd, cacr_ced;
assign dbg_cacr = cacr;
assign dbg_cache_clear = cacr_ci | cacr_cd | cacr_cei | cacr_ced;
wire  [7:2] caar_idx;
wire        halted;

ap030_core core (
	.clk(clk), .rst(rst),
	.d_stb(d_stb), .d_addr(d_addr), .d_size(d_size), .d_rw(d_rw), .d_rmc(d_rmc), .d_rmc_last(d_rmc_last),
	.d_rmc_release(d_rmc_release), .d_iack(d_iack), .d_nocache(d_nocache), .d_fc(d_fc), .d_wdata(d_wdata),
	.d_ack(d_ack), .d_rdata(d_rdata), .d_fault(d_fault), .d_avec(d_avec), .d_iack_berr(d_iack_berr),
	.d_late_fault(d_late_fault), .d_wpend(d_wpend),
	.f_addr(f_addr), .f_fc(f_fc), .f_size(f_size), .f_rw(f_rw), .f_rm(f_rm), .f_dob(f_dob),
	.f_got(f_got), .f_partial(f_partial),
	.i_stb(i_stb), .i_addr(i_addr), .i_fc(i_fc), .i_ready(i_ready), .i_ack(i_ack), .i_data(i_data), .i_fault(i_fault),
	.op_req(op_req), .op_kind(op_kind), .op_level(op_level), .op_la(op_la), .op_fc(op_fc), .op_fcmask(op_fcmask),
	.op_done(op_done), .op_desc_addr(op_desc_addr),
	.reg_we(reg_we), .reg_sel(reg_sel), .reg_wdata_hi(reg_wdata_hi), .reg_wdata_lo(reg_wdata_lo), .reg_fd(reg_fd),
	.cfg_err(cfg_err), .tc(tc), .srp_hi(srp_hi), .srp_lo(srp_lo), .crp_hi(crp_hi), .crp_lo(crp_lo),
	.tt0(tt0), .tt1(tt1), .mmusr(mmusr), .bus_quiet(bus_quiet),
	.cacr(cacr), .cacr_ci(cacr_ci), .cacr_cei(cacr_cei), .cacr_cd(cacr_cd), .cacr_ced(cacr_ced), .caar_idx(caar_idx),
	.ipl_n(ipl_n), .ipend_n(ipend_n), .reset_drive(reset_drive), .status_n(status_n), .refill_n(refill_n),
	.halted(halted), .dbg_pc(dbg_pc), .dbg_sr(dbg_sr), .dbg_state(dbg_state), .dbg_inst(dbg_inst),
	.dbg_vbr(dbg_vbr)
,
	.nmi_vec_nocache(nmi_vec_nocache)
);

ap030_memsys memsys (
	.clk(clk), .rst(rst),
	.cacr(cacr), .cacr_ci(cacr_ci), .cacr_cei(cacr_cei), .cacr_cd(cacr_cd), .cacr_ced(cacr_ced),
	.caar_idx(caar_idx), .cdis(cdis_s), .mmudis(mmudis_s), .halted(halted),
	.d_stb(d_stb), .d_addr(d_addr), .d_size(d_size), .d_rw(d_rw), .d_rmc(d_rmc), .d_rmc_last(d_rmc_last),
	.d_rmc_release(d_rmc_release), .d_iack(d_iack), .d_nocache(d_nocache), .snoop_we(snoop_we), .snoop_addr(snoop_addr), .d_fc(d_fc), .d_wdata(d_wdata),
	.d_ack(d_ack), .d_rdata(d_rdata), .d_fault(d_fault), .d_avec(d_avec), .d_iack_berr(d_iack_berr),
	.d_late_fault(d_late_fault), .d_wpend(d_wpend),
	.f_addr(f_addr), .f_fc(f_fc), .f_size(f_size), .f_rw(f_rw), .f_rm(f_rm), .f_dob(f_dob),
	.f_got(f_got), .f_partial(f_partial),
	.i_stb(i_stb), .i_addr(i_addr), .i_fc(i_fc), .i_ready(i_ready), .i_ack(i_ack), .i_data(i_data), .i_fault(i_fault),
	.op_req(op_req), .op_kind(op_kind), .op_level(op_level), .op_la(op_la), .op_fc(op_fc), .op_fcmask(op_fcmask),
	.op_done(op_done), .op_desc_addr(op_desc_addr),
	.reg_we(reg_we), .reg_sel(reg_sel), .reg_wdata_hi(reg_wdata_hi), .reg_wdata_lo(reg_wdata_lo), .reg_fd(reg_fd),
	.cfg_err(cfg_err), .tc(tc), .srp_hi(srp_hi), .srp_lo(srp_lo), .crp_hi(crp_hi), .crp_lo(crp_lo),
	.tt0(tt0), .tt1(tt1), .mmusr(mmusr), .bus_quiet(bus_quiet),
	.a_o(a), .fc_o(fc), .siz_o(siz), .rw_o(rw), .rmc_n_o(rmc_n), .as_n_o(as_n), .ds_n_o(ds_n), .dben_n_o(dben_n),
	.ecs_n_o(ecs_n), .ocs_n_o(ocs_n), .ciout_n_o(ciout_n), .cbreq_n_o(cbreq_n), .bus_oe(bus_oe),
	.d_o(d_o), .d_oe(d_oe), .d_i(d_i),
	.dsack0_n(dsack0_n), .dsack1_n(dsack1_n), .sterm_n(sterm_n), .berr_n(berr_n), .halt_n(halt_n),
	.avec_n(avec_n), .ciin_n(ciin_n), .cback_n(cback_n), .br_n(br_n), .bgack_n(bgack_n),
	.bg_n_o(bg_n), .bus_granted()
);

assign dbg_halted = halted;

endmodule
