//--------------------------------------------------------------------------//
// ap040_fpu_tie.vh - the lifted ap040_fpu on the pipelined core's fp_* port  //
// group, with everything M10.1 step 3 does not drive yet tied off.          //
//                                                                          //
// Included by rtl/compat/ap040_pipe_tg68k_compat.v (inside                 //
// `generate if (AP040_HAS_FPU)`) and by tb/tb_ap040_pipe_prog.v with        //
// -DFPU_REAL, so the bench and the shipping wrapper cannot drift apart:     //
// the programs that pass in simulation drive exactly the instance the       //
// bitstream carries.                                                        //
//                                                                          //
// The names it expects in scope are the core's own: fp_req, fp_op_class,   //
// fp_opmode, fp_src_fmt, fp_src_r, fp_dst_r, fp_din, fp_ia_we,             //
// fp_ia_wdata, fp_cr_sel, fp_cr_we, fp_cr_wdata (driven by the core) and   //
// fp_done, fp_accepted, fp_unimp, fp_unsupp, fp_exc_req, fp_exc_vec,       //
// fp_dout, fp_cr_rdata, fp_fm_rdata (driven back), plus clk, nreset and    //
// fp_ce.                                                                   //
//                                                                          //
// (M10 remainder, 2026-09-24) the $4160 BUSY frame is wired both ways --   //
// the unit prepares one for every unsupported data type, which is what     //
// the FPSP's vector-55 handler FSAVEs -- and so is the CU_SAVEPC = $FE     //
// resume (frestore_cusavepc / _et15 / _fpt15 / frestore_resume).           //
//                                                                          //
// ... and so is the DEFERRED exception's frame: pend_capture, cur_vec and  //
// frestore_e1_pend (FSAVE extracts it, FRESTORE re-arms it).               //
// Nothing on the unit is tied off any more.                                //
//--------------------------------------------------------------------------//

ap040_fpu u_fpu
(
	.clk(clk), .nreset(nreset), .ce(fp_ce),

	.req(fp_req), .op_class(fp_op_class), .opmode(fp_opmode),
	.src_fmt(fp_src_fmt), .src_r(fp_src_r), .dst_r(fp_dst_r), .din(fp_din),
	.done(fp_done), .accepted(fp_accepted),
	.unimp(fp_unimp), .unsupp(fp_unsupp),
	.exc_req(fp_exc_req), .exc_vec(fp_exc_vec), .dout(fp_dout),
	.fpcc(fp_fpcc),

	.cr_sel(fp_cr_sel), .cr_we(fp_cr_we), .cr_wdata(fp_cr_wdata), .cr_rdata(fp_cr_rdata),
	.bsun_req(fp_bsun_req), .bsun_enable(fp_bsun_en),

	.ia_we(fp_ia_we), .ia_wdata(fp_ia_wdata),

	.fm_sel(fp_fm_sel), .fm_we(fp_fm_we), .fm_wdata(fp_fm_wdata), .fm_rdata(fp_fm_rdata),

	.fpu_used(fp_used), .fstate_unimp(fp_st_unimp),
	.fstate_cmd1(fp_st_cmd1), .fstate_cmd3(fp_st_cmd3),
	.fstate_stag(fp_st_stag), .fstate_dtag(fp_st_dtag), .fstate_flags(fp_st_flags),
	.fstate_fpt(fp_st_fpt), .fstate_et(fp_st_et),
	.fsave_ack(fp_fsave_ack), .frestore_idle(fp_fridle), .frestore_unimp(fp_fr_unimp),
	.pend_capture(fp_pcap), .cur_vec(fp_cur_vec), .frestore_e1_pend(fp_fr_e1pend),
	.frestore_cusavepc(fp_fr_cusavepc), .frestore_et15(fp_fr_et15), .frestore_fpt15(fp_fr_fpt15),
	.frestore_resume(fp_fr_resume),
	.fstate_grs(fp_st_grs), .fstate_wbte15(fp_st_wbte15), .fstate_busy(fp_st_busy),
	.fstate_wbt(fp_st_wbt), .fstate_fpiar_c(fp_st_fpiar),
	.frestore_wbt(fp_fr_wbt), .frestore_fpiar(fp_fr_fpiar), .frestore_busy(fp_fr_busy),
	.frestore_cmd1(fp_fr_cmd1), .frestore_cmd3(fp_fr_cmd3),
	.frestore_stag(fp_fr_stag), .frestore_dtag(fp_fr_dtag), .frestore_flags(fp_fr_flags),
	.frestore_fpt(fp_fr_fpt), .frestore_et(fp_fr_et),
	.frestore_grs(fp_fr_grs), .frestore_wbte15(fp_fr_wbte15),
	.fp_reset(fp_frst)
);
