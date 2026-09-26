//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_ea_fetch.v - <ea> fetch stage (rewritten for Minimig plan M1)      //
//                                                                          //
// Owns the data-read port and every multi-access sequence:                 //
//   ordinary instruction: memory-indirect pointer fetches (src, then dst),  //
//     the source operand load, the destination load of a read-modify-write, //
//     register operand reads; then one micro-op to EX.                      //
//   exception entry (TRAP, illegal, A/F-line, privilege, address error,    //
//     format error): waits until every older instruction has committed      //
//     (so SR and the stack pointers are architectural), then sends the      //
//     frame stores, reads the vector at VBR + 4*vector, and sends a final   //
//     micro-op that writes SP and SR and redirects to the handler.  The     //
//     stores go down the pipe like any store and are written in WB, so a    //
//     frame is never written for an instruction that is later flushed.      //
//   RTE: pops SR, PC, format word; checks the format (M68040UM 8.4, p. 8-20: //
//     $0/$1/$2/$3/$4/$7; anything else is a format error, vector 14); the   //
//     final micro-op writes SR and SP and redirects.  $1 pops its 8 bytes,  //
//     commits the SR it held and then processes the frame the new SR's      //
//     stack holds.                                                         //
//   reset (RESET_FROM_VECTORS): ISP <- (0), PC <- (4).                     //
//                                                                          //
// Exceptions are all taken here, never in EX: a branch to an odd address  //
// is converted in ID, JMP/JSR/RTS odd targets here.                         //
//                                                                          //
// Memory reads are single-clock requests (rd_req) answered by rd_ack some  //
// clocks later (the L1 model: the next clock).  A read waits while EX      //
// holds an older store (it has not reached memory yet); a store in WB is    //
// written in the same clock the read samples, write first, by the memory. //
//                                                                          //
// Coding rule (Icarus): combinational logic is pure functions of their     //
// arguments, assigned with assign -- see ap040_decode.v.                   //
//--------------------------------------------------------------------------//

`include "ap040_pipe_defs.svh"

module ap040_ea_fetch
	import ap040_pipe_pkg::*;
#(
	// 1: merge the stores still in EX/WB into a read's answer (the L1 test
	// substrate answers the next clock, before they reach memory); 0: the
	// bus controller holds every read until older stores are in memory
	parameter STFWD = 1,
	// CAS2 with Dc1 = Dc2 and a failed compare: 0 = the 68040 (memory
	// operand 2 ends in the register: WinUAE's cpu_level >= 4 order, verified
	// on hardware -- Paul's decision, PLAN D7); 1 = the 020/030 (operand 1,
	// PRM 4-68)
	parameter CAS2_DC_ORDER_020 = 0,
	// 1: a full MC68040 (FPU): RTE rejects the LC/EC format $4 frame
	// (format error), as the reference with AP040_HAS_FPU; 0: the LC040 pops it
	parameter HAS_FPU = 0,
	// 1 (plan M11.1): this stage's redirect -- RTS/RTD/RTR, a memory-indirect
	// JMP/JSR, a Bcc/DBcc that ID guessed wrong -- is REGISTERED here instead
	// of going straight out to IF, ID and EA-calc.  It costs one clock on each
	// of those, and it takes the memory acknowledge off a path that fans out
	// to the whole prefetch queue: the wrapper registers the acknowledge on the
	// clk_114 edge immediately before the core's clk_38 edge, so everything it
	// reaches has ONE clk_114 period (cpu.xdc, and PLAN.md M11.1 for why this
	// is the only family the design still fails).  With it the acknowledge
	// reaches one local register instead.  0 = as before.
	parameter REDIR_REG = 0,
	// 1 (bus builds): a MOVEM -(An) store sends its An update on a trailing
	// micro-op of its own, so a fault on the last store (CM, a restart)
	// leaves An as it was -- a faulted store's micro-op keeps its register
	// writes (they are applied while WB holds it)
	parameter MM_TAIL = 0,
	// RESET: how long RSTO is asserted, in (enabled) clocks -- M68040UM
	// 7.x "the processor drives the reset out (RSTO) signal for 512 BCLK"
	parameter RSTO_CLKS = 512
)
(
	input             clk,
	input             nreset,
	input             ce,
	input             stall_in,   // EX cannot accept this cycle
	input             flush,
	input             keep_out,    // the flush is EX's own redirect while EX holds eaf_o: keep it

	input             eac_valid,
	input  eac_t      eac_i,

	input      [15:0] sr_in,      // architectural SR (WB write-through)
	input      [31:0] vbr_in,
	input       [2:0] sfc_in, dfc_in,   // MOVES
	input             older_busy, // EX or WB holds an instruction
	input             older_store,// EX holds a store that has not reached memory
	input             sync_busy,  // a store (EX, WB or posted) is not in memory yet: NOP waits
	input             reset_seq,  // run the reset vector fetch first
	// EA-calc's early read for the instruction moving in at the end of this
	// clock (issued when this stage does not use the port itself)
	input             early_v,
	input  rdreq_t    early,

	// register reads (with the regfile's WB write-through)
	output      [4:0] ra_a, ra_b, ra_c, ra_d,
	input      [31:0] rd_a, rd_b, rd_c, rd_d,
	// EX-stage writes, forwarded
	input             ex_w0_v, input [4:0] ex_w0_r, input [31:0] ex_w0_val,
	input             ex_u0_v, input [4:0] ex_u0_r, input [31:0] ex_u0_val,
	input             ex_u1_v, input [4:0] ex_u1_r, input [31:0] ex_u1_val,
	input             ex_ccr_v, input [4:0] ex_ccr,   // the CCR EX's micro-op leaves

	// data read port
	output            rd_req,
	output     [31:0] rd_addr,
	output      [1:0] rd_size,
	output      [2:0] rd_fc,      // the read's function code (MOVES: SFC)
	input             rd_ack,
	input      [31:0] rd_data_raw,
	input             rd_err,     // the read ended in an access error (M6)
	// WB's store ended in an access error (M6, synchronous stores): EX's
	// micro-op and this stage are flushed and vector 2 is taken
	// PTEST / PFLUSH (M7): level requests to the MMU until done
	output reg        pt_req,
	output reg        pt_write,
	output reg [31:0] pt_addr,
	input             pt_done,
	input      [31:0] pt_mmusr,
	output reg        pf_req,
	output reg  [1:0] pf_mode,
	output reg [31:0] pf_addr,
	input             pf_done,
	input             bus_idle,    // the memory port has no transfer (the MMU is ours)
	output            pmmu_busy,   // IF must not fetch
	// the FPU (plan M10.1): a pulse-request / pulse-done unit instantiated
	// OUTSIDE the core, as the MMU is.  The command port is bit fields of the
	// instruction's first extension word; `accepted` rises once classification
	// is past -- the point after which only completion or an enabled
	// arithmetic exception can follow -- so the instruction is released there
	// and the operation finishes in the background while integer instructions
	// run on.  Only CL_FPU drives any of this, and CL_FPU exists only with
	// HAS_FPU = 1.
	output reg        fp_req,
	output      [2:0] fp_op_class,
	output      [6:0] fp_opmode,
	output      [2:0] fp_src_fmt,
	output      [2:0] fp_src_r,
	output      [2:0] fp_dst_r,
	output     [95:0] fp_din,
	// FPIAR: the reference writes it on every dispatch that engages the unit
	// (lib/AP68040 ap040_core.v, `fpu_iawe`), so a handler -- and the FPSP --
	// reads the address of the instruction the unit is holding and not zero.
	output            fp_ia_we,
	output     [31:0] fp_ia_wdata,
	// (M10.2) the control registers: opclass 100/101 moves one longword per
	// selected register between the effective address and FPCR/FPSR/FPIAR.
	// cr_sel is 0 FPIAR, 1 FPSR, 2 FPCR and reads combinationally.
	output      [1:0] fp_cr_sel,
	output            fp_cr_we,
	output     [31:0] fp_cr_wdata,
	input      [31:0] fp_cr_rdata,
	// (M10.4) FMOVEM: the unit's RAW register port -- architecturally exact
	// bits, no condition codes, no rounding.  fm_rdata reads combinationally.
	output      [2:0] fp_fm_sel,
	output            fp_fm_we,
	output     [95:0] fp_fm_wdata,
	input      [95:0] fp_fm_rdata,
	// (M10.5) FSAVE / FRESTORE, the NULL and IDLE frames: `fp_used` says which
	// of the two FSAVE writes, and the two pulses are what FRESTORE of each
	// one does to the unit.
	input       [3:0] fp_fpcc,        // {N,Z,I,NAN} -- the unit's condition codes
	input             fp_bsun_en,     // BSUN is enabled in FPCR
	output            fp_bsun_req,    // a signalling predicate met an unordered result
	input             fp_used,
	output            fp_frst,          // FRESTORE of a NULL frame: reset the FPU
	output            fp_fridle,        // ... of an IDLE frame
	// (M10.7) the $4130 unimplemented-state frame: thirteen longwords out of
	// the unit's fstate_* on FSAVE, and back into its frestore_* on FRESTORE.
	input             fp_st_unimp,      // the unit is holding a state to save
	input      [15:0] fp_st_cmd1,
	input      [15:0] fp_st_cmd3,
	input       [2:0] fp_st_stag,
	input       [2:0] fp_st_dtag,
	input       [2:0] fp_st_flags,
	input       [2:0] fp_st_grs,
	input             fp_st_wbte15,
	input      [95:0] fp_st_fpt,
	input      [95:0] fp_st_et,
	output            fp_fsave_ack,     // the state has been extracted
	output            fp_fr_unimp,      // ... and this one installs a frame
	output     [15:0] fp_fr_cmd1,
	output     [15:0] fp_fr_cmd3,
	output      [2:0] fp_fr_stag,
	output      [2:0] fp_fr_dtag,
	output      [2:0] fp_fr_flags,
	output      [2:0] fp_fr_grs,
	output            fp_fr_wbte15,
	output     [95:0] fp_fr_fpt,
	output     [95:0] fp_fr_et,
	// (M10 remainder, 2026-09-24) the $4160 BUSY frame: 25 longwords.  The
	// unit prepares one for every unsupported data type (vector 55) and for
	// an e3 arithmetic exception; the FPSP FSAVEs it, and FRESTOREs a BUSY
	// frame of its own on the way out -- with CU_SAVEPC = $FE when the unit
	// is to COMPLETE the instruction from the frame's operands (resume).
	input             fp_st_busy,       // the state to save is the BUSY one
	input      [95:0] fp_st_wbt,        // WBTEMP
	input      [31:0] fp_st_fpiar,      // FPIARCU
	output            fp_fr_busy,
	output     [95:0] fp_fr_wbt,
	output     [31:0] fp_fr_fpiar,
	output      [7:0] fp_fr_cusavepc,
	output            fp_fr_et15,
	output            fp_fr_fpt15,
	input             fp_fr_resume,     // the restored frame starts the unit
	// (M10 remainder) the DEFERRED exception's frame (lib/AP68040 fpu_pendcap):
	// when a released operation's enabled exception becomes pending, the unit
	// prepares its E1 ($4130) or E3 ($4160) frame from its operand shadow; an
	// FSAVE then EXTRACTS that frame instead of taking the exception, and an
	// FRESTORE of an E1/E3 frame re-arms it for the next FP instruction.
	output reg        fp_pcap,          // pend_capture
	input             fp_fr_e1pend,     // frestore_e1_pend
	input       [7:0] fp_cur_vec,       // cur_vec: the enabled exception's vector
	input             fp_done,
	input             fp_accepted,
	input             fp_unimp,
	input             fp_unsupp,
	// (M10.3) an ENABLED arithmetic exception, vectors 48-54.  It can arrive
	// while the instruction is still here, or after it was released -- those
	// are different exceptions to the architecture and are handled apart.
	input             fp_exc_req,
	input       [7:0] fp_exc_vec,
	input      [95:0] fp_dout,
	// cache maintenance (M8): CINV / CPUSH drive the wrapper's cache port
	output reg        cinv_req,
	output reg        cinv_ic,
	output reg        cinv_dc,
	input             cinv_done,
	input             wb_fault,
	input             wb_fatm,     // ... from the MMU (ATC)
	input             wb_fma,      // ... on a split store's second page (SSW.MA)
	input      [31:0] wb_st_a, input [1:0] wb_st_s, input [31:0] wb_st_d, input [2:0] wb_st_f,
	input             wb_last,     // ... on the instruction's last micro-op (WB1 pending write)
	input  stf_t      wb_stf,
	input             rd_atc,     // ... from the MMU (else a physical bus error)
	input             rd_ma,      // ... on a split read's second page (SSW.MA)
	input      [31:0] bus_wdata,  // the memory port's last write data (the reference's stale WB3D)
	// the older stores not yet in memory when a read sampled it: the one in
	// WB now (it was in EX then) and the one in EX now (it was here then)
	input             wb_st_v, input [31:0] wb_st_addr, input [1:0] wb_st_size, input [31:0] wb_st_data,
	input             ex_st_v, input [31:0] ex_st_addr, input [1:0] ex_st_size, input [31:0] ex_st_data,

	output            eaf_stall,  // to EA-calc: the current instruction is not done
	output            eaf_blk,    // current instruction is serialising / sequenced

	output reg        eaf_valid,
	output ex_t       eaf_o,
	output            halted,
	// interrupts (plan M9 subset, pulled forward for gate 1): the core's
	// sampler (the reference's, lifted) says a level above the mask is
	// pending; EA-fetch takes it at an instruction boundary and toggles the
	// acknowledge.  stopped: the STOP state; rsto: RESET's reset out.
	input             irq_req,
	input       [2:0] irq_lvl,
	output            stopped,
	output            rsto,

	// redirect from this stage: RTS (its return address is loaded here) and
	// a JMP/JSR whose target needed a memory-indirect pointer
	output            eaf_redir_v,
	output     [31:0] eaf_redir_pc,
	// (REDIR_REG) the clock BEFORE the held redirect goes out: IF must not
	// start one more fetch down the old stream in it
	output            eaf_redir_soon
);

wire id_t i = eac_i.i;

//--------------------------------------------------------------- state
localparam [3:0] P_START = 4'd0,  // examine / wait for serialisation
                 P_OPS   = 4'd1,  // ordinary instruction: memory reads
                 P_EXC   = 4'd2,  // exception entry
                 P_RTE   = 4'd3,
                 P_RESET = 4'd4,
                 P_HALT  = 4'd5,
                 P_MOVEM = 4'd6,  // MOVEM: one micro-op per register
                 P_PMMU  = 4'd7,  // PFLUSH / PTEST: the MMU request, then a refetch
                 P_STOP  = 4'd8,  // STOP: the SR is written; waiting for an interrupt
                 P_RSTO  = 4'd9,  // RESET: RSTO asserted
                 P_CINV  = 4'd10, // CINV / CPUSH: the cache request, then a refetch
                 P_FPU   = 4'd11; // a floating-point instruction: the FPU request (M10.1)

reg  [3:0] ph;
// REDIR_REG (plan M11.1): the one-clock redirect slot, and the "gap clock"
// in which this stage must do nothing.  eac_v_use is what every decision
// here looks at; eaf_stall keeps the REAL eac_valid, so EA-calc holds.
reg         rdz_v;
reg  [31:0] rdz_pc;
wire        redir_gap = (REDIR_REG != 0) && rdz_v;
wire        eac_v_use = eac_valid && !redir_gap;
reg        rd_pend;        // a read is outstanding
reg        rd_drop;        // ... and belongs to a flushed instruction
reg  [2:0] rd_tag;         // which read it is
reg        done_smi, done_dmi, done_sld, done_dld;
reg [31:0] s_addr, d_addr; // after memory indirect
reg [31:0] s_val, d_val;   // loaded operands
reg        rst_pending;    // reset sequence still to run

// ---------------------------------------------------------------- the FPU
// (plan M10.1(c): the req / accepted / done interlock.)  fp_sent is set the
// clock AFTER the request goes out, so a `done` or `unimp` still standing
// from the previous operation cannot be read as this one's answer.
reg        fp_sent;
reg        fp_acc;         // accepted seen: classification is past
reg        fp_dn;          // done seen
reg [95:0] fp_buf;         // the memory operand under assembly, then the result
reg        fp_bg;          // a RELEASED operation is still running
wire       fp_live = fp_sent && !fp_req;
// (M10.1(b)) the operand path: a memory operand is 1, 2, 4, 8 or 12 bytes,
// so up to three longword beats, assembled LEFT aligned because that is what
// the unit's din window wants.  fp_addr is the saved EA -- an access error
// mid-operand is an ordinary one and the restart re-reads from here.
localparam [1:0] FS_RD = 2'd0, FS_REQ = 2'd1, FS_WR = 2'd2;
reg  [1:0] fp_stt;
reg  [1:0] fp_k;           // beat index
reg [31:0] fp_addr;
// (M10.2) opclass 100/101, the control registers.  The same three states
// carry it -- FS_RD reads the longwords, FS_WR writes them, FS_REQ is the
// register and immediate forms that touch no bus -- but nothing is sent to
// the unit's COMMAND port, so `fp_crd` (all transfers complete) stands in
// for the interlock's `fp_ok` and FPIAR is not written (ia_we = fp_req).
// (M10.3) the enabled arithmetic exceptions.  `fp_ae` is this instruction's
// own, latched the way fp_acc and fp_dn are so that it is seen in the same
// clock as a release that would otherwise win; `fp_pend` is one a RELEASED
// operation raised after its instruction had left, which becomes a
// PRE-instruction exception in front of the next floating-point instruction
// (lib/AP68040 ap040_core.v:1944 and :3600).
reg        fp_ae;
reg  [7:0] fp_avec;
reg        fp_pend;
reg  [7:0] fp_pvec;
// (M10.4) FMOVEM: the list being consumed, the register the beats belong to,
// and the write to the unit's raw port, armed the clock before it goes out
// for the same reason fp_cw is.
reg  [7:0] fp_list;
reg  [2:0] fp_fsel;
reg        fp_mw;
reg  [2:0] fp_mwsel;       // the register the armed write belongs to: the
                           // selector has moved on by the time it goes out
reg [95:0] fp_mwd;
// (M10.5) the two FRESTORE pulses, and the format error a frame this core
// cannot restore takes (vector 14, as the reference's default arm does)
reg        fp_rstp;
reg        fp_idlp;
reg        fp_fmte;
// (M10.7) the state frame: a thirteen-longword sequence with its own index,
// the fields latched on the way in, and the two pulses that hand the frame to
// the unit or take it away.
reg  [4:0] fp_fn;          // the frame beat: 0-12 ($4130) or 0-24 ($4160)
reg        fp_bsy;         // this FSAVE/FRESTORE frame is the $4160 BUSY one
reg        fp_rarm;        // an E1/E3 frame was just restored: re-arm its exception
reg        fp_frm;         // this FSAVE/FRESTORE is a $4130 frame, not NULL/IDLE
reg        fp_svack;
reg        fp_frup;
reg [15:0] fr_cmd1, fr_cmd3;
reg  [2:0] fr_stag, fr_dtag, fr_flags, fr_grs;
reg        fr_wbte15;
reg [95:0] fr_fpt, fr_et;
reg        fr_busy, fr_et15, fr_fpt15;
reg [95:0] fr_wbt;
reg [31:0] fr_fpiar;
reg  [7:0] fr_cusave;
reg        fp_cw;          // a control-register write goes out this clock
reg  [1:0] fp_csel;        // ... to this register: captured with the data, so
                           //     the beat index may advance on the same edge
reg [31:0] fp_cwd;
reg        fp_crd;         // every selected register has been transferred

// exception parameters (latched when an exception sequence starts)
reg  [7:0] x_vec;
reg  [3:0] x_fmt;
reg [31:0] x_pc, x_addr;
reg  [2:0] x_step;         // 0 frame stores, 3 vector read, 4 final, 5 wait + latch SR/SP
reg  [3:0] x_k;            // the frame longword being stored (0 .. size/4 - 1)
reg [31:0] x7 [2:14];      // format $7 longwords 2-14 (frame bytes 8-59), set when the fault is taken
integer    xk;
reg [15:0] x_sr;           // SR stacked
reg        x_pass2;        // (M9.T) building the format $1 throwaway frame
reg [31:0] x_sp1;          // ... and the master stack's new value, from pass 1
reg [31:0] x_sp;           // new SP (reset: the loaded ISP)
reg  [4:0] x_bank;
reg [31:0] x_target;

// RTE / reset
reg  [2:0] r_step;
reg [15:0] r_sr;
reg [31:0] r_pc;
reg [15:0] r_fv;

wire       s_bit    = sr_in[13];
wire [4:0] bank_now = sr_in[12] ? R_MSP : R_ISP;   // supervisor stack the SR selects

//--------------------------------------------------------------- operand reads
function automatic logic [4:0] ra_a_f(input logic [3:0] p, input eac_t e, input logic [4:0] bank,
                                      input logic pass2);
	// the supervisor stack pointer.  (M9.T) the throwaway pass reads the
	// INTERRUPT stack instead: the SR still selects the master stack, which
	// is where the normal frame just went.
	if (p == P_EXC && pass2) return R_ISP;
	if (p == P_EXC || p == P_RTE) return bank;
	if (e.i.cls == CL_CAS2) return {2'b00, e.i.ext[2:0]};    // Dc1 (the source is (Rn1))
	if (e.i.cls == CL_MOVEC && !e.i.imm[4])         // Rc -> Rn: an SP selector reads the physical SP
		return (e.i.imm[3:0] == CR_USP) ? R_USP : (e.i.imm[3:0] == CR_ISP) ? R_ISP : R_MSP;
	return e.src_r;
endfunction

assign ra_a = ra_a_f(ph, eac_i, bank_now, x_pass2);
assign ra_b = (eac_i.i.cls == CL_CAS2) ? {2'b00, eac_i.i.ext2[2:0]} : eac_i.dst_r;   // CAS2: Dc2

function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] rf,
                                    input logic w0v, input logic [4:0] w0r, input logic [31:0] w0d,
                                    input logic u0v, input logic [4:0] u0r, input logic [31:0] u0d,
                                    input logic u1v, input logic [4:0] u1r, input logic [31:0] u1d);
	if (w0v && w0r == r) return w0d;
	if (u1v && u1r == r) return u1d;
	if (u0v && u0r == r) return u0d;
	return rf;
endfunction

wire [31:0] op_a = fwd(ra_a, rd_a, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
// the destination register sees this instruction's own source update
// the third register operand (CAS Du, DIV.L Dr): no A7, no own update
assign ra_c = (eac_i.i.cls == CL_MOVEM) ? mm_sreg : eac_i.i.reg_c;   // MOVEM: the register being stored
wire [31:0] op_c = fwd(ra_c, rd_c, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
// the fourth (bitfield width in Dn)
assign ra_d = eac_i.i.reg_d;
wire [31:0] op_d = fwd(ra_d, rd_d, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);
wire [31:0] op_b = (eac_i.u0_v && eac_i.u0_r == ra_b) ? eac_i.u0_val :
                   fwd(ra_b, rd_b, ex_w0_v, ex_w0_r, ex_w0_val, ex_u0_v, ex_u0_r, ex_u0_val,
                       ex_u1_v, ex_u1_r, ex_u1_val);

//--------------------------------------------------------------- bitfields
// M68040UM / PRM BFxxx: offset = Do ? Dn (signed, 32 bits) : ext[10:6];
// width = Dw ? Dn mod 32 : ext[4:0], 0 meaning 32.  Memory: the field
// starts at bit (offset mod 8) of the byte at <ea> + (offset >> 3), and
// spans 1-5 bytes.  Reads and writes touch only the bytes holding the
// field: B / W / W+B / L / L+B by span (lib/AP68040 t_bitfield_mmu.s, the
// OPENSTEP 4.2 WindowServer BFTST at the end of an 8K page: a longword read
// of a one-byte field there faults on the next, invalid, page -- plan M7).
// Writes as the reference core (S_BF_WR1/2).
wire        is_bf   = (i.cls == CL_BF);
wire        bf_mem  = is_bf && (i.dst.kind == EK_MEM);
// Offset and width come from the register file (WB write-through), not
// from EX: a bitfield waits while EX is writing one of its registers
// (bf_rdblk, vhold below), so the read address and the span -- which decide
// reads and micro-ops -- stay off EX's result path (timing, plan M3).
wire [31:0] bf_off  = (i.reg_c != R_NONE) ? rd_c : {27'd0, i.ext[10:6]};
wire  [4:0] bf_w5   = (i.reg_d != R_NONE) ? rd_d[4:0] : i.ext[4:0];
wire  [5:0] bf_w    = (bf_w5 == 5'd0) ? 6'd32 : {1'b0, bf_w5};
wire [31:0] bf_addr = eac_i.dst_ea + {{3{bf_off[31]}}, bf_off[31:3]};
wire  [6:0] bf_bits = {4'd0, bf_off[2:0]} + {1'b0, bf_w} + 7'd7;
wire  [2:0] bf_n    = bf_bits[5:3];               // 1..5 bytes
wire        bf_modify = (i.alu[2:0] == 3'd2) || (i.alu[2:0] == 3'd4) || (i.alu[2:0] == 3'd6) || (i.alu[2:0] == 3'd7);
// a second store (the byte past a word or longword) needs a second micro-op
wire        bf_two  = bf_mem && bf_modify && (bf_n == 3'd3 || bf_n == 3'd5);

//--------------------------------------------------------------- ordinary instructions
wire addr_only    = (i.cls == CL_JMP || i.cls == CL_JSR || i.cls == CL_LEA || i.cls == CL_PEA);
wire needs_ld_src = ((i.src.kind == EK_MEM) && !addr_only && i.cls != CL_MOVEM) || (bf_mem && (bf_n == 3'd3 || bf_n == 3'd5));
// CHK2/CMP2 read the upper bound from <ea>+size into the "destination" load
wire needs_ld_dst = ((i.dst.kind == EK_MEM) && i.rmw && i.cls != CL_MOVEM) || (i.cls == CL_CHK2) || bf_mem;
wire need_smi = (i.src.kind == EK_MEM) && (i.src.mi != MI_NONE) && !cm_use;   // (CM: the EA is the stacked one)
wire need_dmi = (i.dst.kind == EK_MEM) && (i.dst.mi != MI_NONE) && !cm_use;

//--------------------------------------------------------------- MOVEM continuation (CM)
// M68040UM 8.4.6.2 (p. 8-25) and 8.4.6.7 (p. 8-27): an access fault on a
// MOVEM's data access stacks a format $7 frame with SSW CM set and the
// calculated effective address in the EA field; the stacked PC is the
// MOVEM (every transfer is repeated).  RTE of that frame restores the EA and
// restarts the MOVEM after its EA calculation when the mode is indexed or
// memory indirect (mode 6) or PC relative (mode 7, register 2/3) -- the
// MOVEM may have overwritten a register or the pointer the EA came from.
// A handler that clears CM gets the EA calculated again.  The pending
// continuation (cm_v) belongs to the instruction at the RTE's return PC
// only; a fault fetching that instruction stacks CM and the EA again.
// (lib/AP68040 never sets CM, D13; apolkosnik/AP68040 main does:
// t_movem_restart.s.)
reg  [31:0] mm_ea [0:1];   // each MOVEM's calculated EA, two slots: a store's fault
reg         mm_tag;        // reaches WB after the next MOVEM may have started
reg         cm_v;          // an RTE restored CM: the MOVEM at cm_pc uses cm_ea
reg  [31:0] cm_ea, cm_pc;
reg  [31:0] r_ea;          // RTE of a format $7 frame: its EA and SSW
reg  [15:0] r_ssw;
wire        mm_cmi  = (i.cls == CL_MOVEM) && !i.imm[1] && !i.imm[2];   // MOVEM proper (not MOVEP/MOVE16)
wire        cm_mode = i.imm[0] ? ((i.src.mode == 3'd6) || (i.src.mode == 3'd7 && (i.src.mreg == 3'd2 || i.src.mreg == 3'd3)))
                               : (i.dst.mode == 3'd6);
wire        cm_hit  = cm_v && (i.pc == cm_pc);                 // this is the instruction the RTE returned to
wire        cm_use  = cm_hit && mm_cmi && cm_mode;
// A MOVEM resumed by RTE with CM set continues the RTE: no interrupt is taken
// in front of it (apolkosnik/AP68040 t_movem_restart.s case 7, "CM resumes
// the interrupted instruction before a pending interrupt"; M68040UM 8.4.6.7
// restarts the MOVEM as part of the RTE's frame processing)
// Nor in front of an instruction whose first operand read has already gone
// out (EA-calc's early read, or a read issued since): the interrupt waits
// for the next boundary.  Taking it would read the operand twice -- once
// now, again after the RTE -- and a read with a side effect (a CIA's ICR
// read clears its flags, M68040UM 8.1.4: an interrupt is taken between
// instructions, the one in front has not accessed memory) would lose it.
// The deferral is bounded by the program: a boundary whose instruction takes
// no operand from memory (a branch, a register operation, the handler's own
// code) always comes, and t_irq_pipe.s check 33 holds every request in a run
// of 16 back-to-back loads to the same boundary rule.
wire        i_rd    = (rd_pend && !rd_drop) || done_smi || done_dmi || done_sld || done_dld;
wire        irq_now = irq_req && !(cm_hit && mm_cmi) && !i_rd;
wire [31:0] s_addr_now = done_smi ? s_addr : eac_i.src_ea;
wire [31:0] d_addr_now = done_dmi ? d_addr :
                         (i.cls == CL_CHK2) ? s_addr_now + ((i.size == SZ_B) ? 32'd1 : (i.size == SZ_W) ? 32'd2 : 32'd4) :
                         eac_i.dst_ea;

// next read the instruction needs: {valid, tag, addr, size}
function automatic rdreq_t next_rd(input logic nsmi, input logic dsmi, input logic ndmi, input logic ddmi,
                                   input logic nsld, input logic dsld, input logic ndld, input logic ddld,
                                   input logic [31:0] sea, input logic [31:0] dea,
                                   input logic [31:0] sa, input logic [31:0] da, input logic [1:0] sz,
                                   input logic [1:0] dsz, input logic dfirst);
	rdreq_t r;
	r = '0; r.sz = SZ_L;
	if (nsmi && !dsmi)      begin r.v = 1'b1; r.t = T_SMI; r.a = sea; end
	else if (ndmi && !ddmi) begin r.v = 1'b1; r.t = T_DMI; r.a = dea; end
	else if (dfirst && ndld && !ddld) begin r.v = 1'b1; r.t = T_DLD; r.a = da; r.sz = dsz; end
	else if (nsld && !dsld) begin r.v = 1'b1; r.t = T_SLD; r.a = sa; r.sz = sz; end
	else if (ndld && !ddld) begin r.v = 1'b1; r.t = T_DLD; r.a = da; r.sz = dsz; end
	return r;
endfunction

// RTR's second read (the PC at 2(SP)) is a long, its first (the CCR) a word
// a bitfield's longword at the field address, its fifth byte as the "source"
wire rdreq_t nx = next_rd(need_smi, done_smi, need_dmi, done_dmi, needs_ld_src, done_sld, needs_ld_dst, done_dld,
                          eac_i.src_ea, eac_i.dst_ea,
                          is_bf ? bf_addr + ((bf_n == 3'd3) ? 32'd2 : 32'd4) : s_addr_now, is_bf ? bf_addr : d_addr_now,
                          is_bf ? SZ_B : i.size,
                          (i.cls == CL_CHK2) ? i.size : !is_bf ? i.size2 :
                          (bf_n == 3'd1) ? SZ_B : (bf_n <= 3'd3) ? SZ_W : SZ_L,
                          is_bf);   // (a bitfield: the word/long first, then the byte -- WinUAE x_get_bitfield)

// Store-to-load forwarding.  The memory answers with what it held at the
// clock edge ending the read's issue clock (a store committing on that edge
// included, write first).  Older stores still in flight then are now in WB
// and EX; their bytes are merged in, WB's first, then EX's (the younger).
// So a load never waits for an older store (M68040UM 10.6: ADD Dn,(An) one
// clock back to back).
reg  [31:0] rd_a_q;        // address, size and function code of the outstanding read
reg   [1:0] rd_sz_q;
reg   [2:0] rd_fc_q;
wire [31:0] rd_data = (STFWD == 0) ? rd_data_raw : st_merge(st_merge(rd_data_raw, rd_a_q, rd_sz_q, wb_st_v, wb_st_addr, wb_st_size, wb_st_data),
                               rd_a_q, rd_sz_q, ex_st_v, ex_st_addr, ex_st_size, ex_st_data);

// the capture in this cycle, as the dispatch sees it
wire        cap      = rd_pend && rd_ack && !rd_drop && !rd_err;
// an access error on the answer (M6): the instruction takes vector 2
// (format $7) and restarts; during exception entry, RTE or reset it is a
// double fault (M68040UM 7.6.3, p. 7-43: the processor halts)
wire        cap_err  = rd_pend && rd_ack && !rd_drop && rd_err;
wire [31:0] s_addr_c = (cap && rd_tag == T_SMI) ? rd_data + eac_i.src_add : s_addr_now;
wire [31:0] d_addr_c = (cap && rd_tag == T_DMI) ? rd_data + eac_i.dst_add : d_addr_now;
wire        dn_smi   = done_smi || (cap && rd_tag == T_SMI);
wire        dn_dmi   = done_dmi || (cap && rd_tag == T_DMI);
wire        dn_sld   = done_sld || (cap && rd_tag == T_SLD);
wire        dn_dld   = done_dld || (cap && rd_tag == T_DLD);
wire [31:0] s_val_c  = (cap && rd_tag == T_SLD) ? rd_data : s_val;
wire [31:0] d_val_c  = (cap && rd_tag == T_DLD) ? rd_data : d_val;
// Timing (plan M3 OOC, WNS -8.6 ns before this): instructions whose
// EA-fetch decision -- trap or not, one micro-op or two, the field address
// -- depends on operand VALUES do not take them straight from EX's result
// or from a load answering this clock; they wait one clock and use the
// register-file write-through / the captured load instead.  (The EX write
// ports themselves never depend on a result: ap040_execute.v.)
wire vdep = (i.cls == CL_CHK) || (i.cls == CL_CHK2) || (i.cls == CL_MULDIV && i.imm[0]) || (i.cls == CL_DBCC) ||
            (i.cls == CL_BF) || (i.cls == CL_CAS2);
function automatic logic hz(input logic v, input logic [4:0] r, input logic [4:0] a, input logic [4:0] b,
                            input logic [4:0] c, input logic [4:0] d);
	return v && (r == a || r == b || r == c || r == d);
endfunction
// (BFEXTU/BFEXTS/BFFFO only write the register port a names: no wait for it)
wire [4:0] hz_a   = (i.cls == CL_BF && i.alu[2:0] != 3'd7) ? R_NONE : ra_a;
wire ex_haz = hz(ex_w0_v, ex_w0_r, hz_a, ra_b, ra_c, ra_d) || hz(ex_u0_v, ex_u0_r, hz_a, ra_b, ra_c, ra_d) ||
              hz(ex_u1_v, ex_u1_r, hz_a, ra_b, ra_c, ra_d);
wire vhold = vdep && (cap || ex_haz);
wire ops_done = (!need_smi || dn_smi) && (!need_dmi || dn_dmi) &&
                (!needs_ld_src || dn_sld) && (!needs_ld_dst || dn_dld) && !vhold;

// odd control-flow targets (M68040UM 8.2.2; reference ap040_core.v S_JMP1/S_JSR1/S_RET2)
wire jmp_odd = (i.cls == CL_JMP || i.cls == CL_JSR) && s_addr_c[0];
wire rts_odd = (i.cls == CL_RTS || i.cls == CL_RTD) && s_val_c[0];
wire rtr_odd = (i.cls == CL_RTR) && d_val_c[0];
wire indexed_mode = (i.src.mode == 3'd6) || (i.src.mode == 3'd7 && i.src.mreg == 3'd3);

//--------------------------------------------------------------- micro-op build
function automatic ex_t base_uop(input id_t i);
	ex_t x;
	x = '0;
	x.pc = i.pc; x.next_pc = i.next_pc; x.opcode = i.opcode;
	x.cls = i.cls; x.alu = i.alu; x.size = i.size; x.cond = i.cond;
	x.dr = R_NONE; x.u0_r = R_NONE; x.u1_r = R_NONE; x.sp_r = R_NONE;
	x.btarget = i.btarget;
	x.last = 1'b1;
	return x;
endfunction

function automatic ex_t xord(input eac_t e, input logic [31:0] opa, input logic [31:0] opb,
                             input logic [31:0] opc,
                             input logic [31:0] sa, input logic [31:0] sv,
                             input logic [31:0] da, input logic [31:0] dv);
	ex_t x;
	id_t i;
	i = e.i;
	x = base_uop(i);
	x.wr_ccr   = i.wr_ccr;
	x.nowrite  = i.nowrite;
	x.ccr_only = i.ccr_only;
	x.ext      = i.ext;
	x.dr2      = i.reg_c;
	// the third operand: CAS Du / DIV.L Dr (register), CHK2's upper bound
	// (the second load), PACK/UNPK's adjustment
	x.c = (i.cls == CL_CHK2) ? dv : (i.cls == CL_PACK || i.cls == CL_UNPK) ? i.imm : opc;
	if (i.cls == CL_MULDIV) x.imm4 = i.imm[3:0];
	case (i.src.kind)
		EK_DREG, EK_AREG: x.a = opa;
		EK_IMM:           x.a = i.src.bd;
		EK_MEM:           x.a = (i.cls == CL_JMP || i.cls == CL_JSR || i.cls == CL_LEA || i.cls == CL_PEA) ? sa : sv;
		default:          x.a = 32'd0;
	endcase
	case (i.dst.kind)
		EK_DREG, EK_AREG: begin x.b = opb; x.dk = DK_REG; x.dr = e.dst_r; end
		EK_MEM:           begin x.b = dv;  x.dk = DK_MEM; x.daddr = da; end
		EK_IMM:           x.b = i.dst.bd;                // BTST Dn,#imm
		default: ;
	endcase
	x.u0_v = e.u0_v; x.u0_r = e.u0_r; x.u0_val = e.u0_val;
	x.u1_v = e.u1_v; x.u1_r = e.u1_r; x.u1_val = e.u1_val;
	// MOVES An,(An)+ / -(An): the 68040 stores the updated An (PRM 6-25 note)
	if (i.fcsel == 2'd2 && e.u1_v && e.u1_r == e.src_r) x.a = e.u1_val;
	case (i.cls)
		// JMP/JSR/RTS were redirected before EX (EA-calc, or this stage)
		CL_JMP, CL_JSR: begin x.target = sa; x.redirect = 1'b0; end
		CL_RTS, CL_RTD: begin x.target = sv; x.redirect = 1'b0; end
		CL_RTR:         begin x.target = dv; x.redirect = 1'b0; x.dk = DK_NONE; end
		CL_MOVE2SR, CL_SROP: begin x.target = i.next_pc; x.redirect = 1'b1; end
		CL_STOP:  begin x.cls = CL_MOVE2SR; x.a = i.imm; x.dk = DK_NONE; x.redirect = 1'b0; x.last = 1'b0; end
		CL_RSTO:  begin x.cls = CL_NOP; x.dk = DK_NONE; end
		// LINK A7: the value pushed is the decremented SP (PRM LINK: SP-4 -> SP;
		// An -> (SP)), i.e. the push address
		CL_LINK:        x.a = (e.src_r == e.dst_r) ? da : opa;
		// EXG: Rx <- Ry (w0), Ry <- Rx (u0: the value is known here)
		CL_CAS: x.dr = e.src_r;           // Dc, written when the compare fails
		CL_EXG: begin
			x.dk = DK_REG; x.dr = e.src_r;
			x.u0_v = 1'b1; x.u0_r = e.dst_r; x.u0_val = opa;
		end
		CL_MOVEC: begin
			x.creg_sel = i.imm[3:0];
			x.creg_to  = i.imm[4];
			x.a        = opa;
			x.dk       = DK_NONE;
			x.dr       = R_NONE;
			if (!i.imm[4]) begin                 // Rc -> Rn
				x.dk = DK_REG; x.dr = e.src_r;
			end else if (i.imm[3:0] == CR_USP || i.imm[3:0] == CR_ISP || i.imm[3:0] == CR_MSP) begin
				x.dk = DK_REG;
				x.dr = (i.imm[3:0] == CR_USP) ? R_USP : (i.imm[3:0] == CR_ISP) ? R_ISP : R_MSP;
			end else begin
				// TC/TTRs/URP/SRP/CACR/...: the next instruction is fetched again,
				// under the new map (the reference's epf_flush on MOVEC)
				x.redirect = 1'b1; x.target = i.next_pc;
			end
		end
		default: ;
	endcase
	return x;
endfunction

wire ex_t x_ord1 = xord(eac_i, op_a, op_b, op_c, s_addr_c, s_val_c, d_addr_c, d_val_c);

// Bitfield evaluation on a 64-bit window: {Dn, Dn} for a register field
// (offset mod 32; a field past bit 0 wraps to bit 31), or the memory bytes
// {long, byte 5, 24'b0} (offset mod 8).  Flags per PRM BFxxx: N = the
// field's (BFINS: the inserted value's) most significant bit, Z = all zero,
// V = C = 0, X kept.  BFFFO: offset + the first set bit, or offset + width.
function automatic logic [5:0] clz32(input logic [31:0] v);
	logic [5:0] n;
	int k;
	n = 6'd32;
	for (k = 0; k < 32; k = k + 1)
		if (v[k]) n = 6'd31 - k[5:0];
	return n;
endfunction

typedef struct packed {
	logic [1:0]  nz;       // N, Z
	logic [31:0] val;      // BFEXTU/BFEXTS/BFFFO result, or the new field register
	logic [63:0] nw;       // the window with the new field in it (memory form)
} bfres_t;

function automatic bfres_t bf_eval(input logic [2:0] op, input logic [63:0] win, input logic [5:0] o,
                                   input logic [5:0] w, input logic [31:0] du, input logic [31:0] off,
                                   input logic regf);
	bfres_t r;
	logic [63:0] sh, m64, n64;
	logic [31:0] fl, maskl, ones, field, nf, al;
	sh    = win << o;
	fl    = sh[63:32];                                   // field left aligned
	maskl = (w == 6'd32) ? 32'hFFFF_FFFF : ~(32'hFFFF_FFFF >> w);
	ones  = (w == 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << w) - 32'd1);
	field = (w == 6'd32) ? fl : (fl >> (6'd32 - w));
	case (op)
		3'd2:    nf = (~field) & ones;                   // BFCHG
		3'd4:    nf = 32'd0;                             // BFCLR
		3'd6:    nf = ones;                              // BFSET
		default: nf = du & ones;                         // BFINS
	endcase
	r.nz[1] = (op == 3'd7) ? nf[w - 6'd1] : field[w - 6'd1];
	r.nz[0] = (op == 3'd7) ? (nf == 32'd0) : (field == 32'd0);
	al = fl & maskl;
	m64 = {maskl, 32'd0} >> o;
	n64 = {((w == 6'd32) ? nf : (nf << (6'd32 - w))), 32'd0} >> o;
	r.nw = (win & ~m64) | (n64 & m64);
	case (op)
		3'd1:    r.val = field;
		3'd3:    r.val = field | (field[w - 6'd1] ? ~ones : 32'd0);
		3'd5:    r.val = off + {26'd0, (al == 32'd0) ? w : clz32(al)};
		default: r.val = (win[63:32] & ~(m64[63:32] | m64[31:0])) |
		                 (n64[63:32] & m64[63:32]) | (n64[31:0] & m64[31:0]);   // register field
	endcase
	return r;
endfunction

// the bytes read, left aligned in the 64-bit window
function automatic logic [63:0] bf_win(input logic [2:0] n, input logic [31:0] dv, input logic [7:0] sb);
	case (n)
		3'd1:    return {dv[7:0], 56'd0};
		3'd2:    return {dv[15:0], 48'd0};
		3'd3:    return {dv[15:0], sb, 40'd0};
		3'd4:    return {dv, 32'd0};
		default: return {dv, sb, 24'd0};
	endcase
endfunction
wire bfres_t bfr = bf_eval(i.alu[2:0],
                           bf_mem ? bf_win(bf_n, d_val, s_val[7:0]) : {rd_b, rd_b},   // (vhold: loads captured,
                           bf_mem ? {3'd0, bf_off[2:0]} : {1'b0, bf_off[4:0]},
                           bf_w, rd_a, bf_off, !bf_mem);   //  no EX hazard: the register file)

// the bitfield micro-ops: 0 flags + register result + first store,
// 1 the trailing byte store of a 3- or 5-byte field
function automatic ex_t bf_uop(input ex_t x0, input logic sec, input eac_t e, input bfres_t r,
                               input logic mem, input logic modify, input logic two,
                               input logic [2:0] n, input logic [31:0] a);
	ex_t x;
	logic [2:0] op;
	op = e.i.alu[2:0];
	x = x0;
	x.a = {28'd0, r.nz, 2'b00};
	x.c = r.val;
	x.dk = DK_NONE; x.dr = R_NONE;
	x.st_v = 1'b0;
	if (op == 3'd1 || op == 3'd3 || op == 3'd5) begin x.dk = DK_REG; x.dr = e.src_r; end
	else if (!mem && modify)                    begin x.dk = DK_REG; x.dr = e.dst_r; end
	if (mem && modify) begin
		x.st_v = 1'b1; x.st_addr = a;
		case (n)
			3'd1:       begin x.st_size = SZ_B; x.st_data = {24'd0, r.nw[63:56]}; end
			3'd2, 3'd3: begin x.st_size = SZ_W; x.st_data = {16'd0, r.nw[63:48]}; end
			default:    begin x.st_size = SZ_L; x.st_data = r.nw[63:32]; end
		endcase
	end
	x.last = !two;
	if (sec) begin
		x.wr_ccr = 1'b0; x.dk = DK_NONE; x.dr = R_NONE;
		x.u0_v = 1'b0; x.u1_v = 1'b0;
		x.st_size = SZ_B;
		x.st_addr = a + ((n == 3'd3) ? 32'd2 : 32'd4);
		x.st_data = {24'd0, (n == 3'd3) ? r.nw[47:40] : r.nw[31:24]};
		x.last = 1'b1;
	end
	return x;
endfunction

// CAS2 (PRM 4-66..4-68): compare (Rn1) with Dc1, then (Rn2) with Dc2; both
// equal: Du1 -> (Rn1), Du2 -> (Rn2) (two micro-ops); else (Rn1) -> Dc1 (w0)
// and (Rn2) -> Dc2 (u1; w0 wins when Dc1 = Dc2: "memory operand 1 is
// stored", PRM 4-68 -- see PLAN D7), and the M68040 ends the locked
// sequence with a write of the second operand read (M68040UM 7.4.5 p. 7-26).
// EX's CMP makes the flags from x.b - x.a.
function automatic logic [31:0] mrg(input logic [31:0] old, input logic [31:0] v, input logic [1:0] sz);
	return (sz == SZ_W) ? {old[31:16], v[15:0]} : v;
endfunction

function automatic ex_t cas2_uop(input ex_t x0, input logic sec, input eac_t e,
                                 input logic [31:0] dc1, input logic [31:0] dc2,
                                 input logic [31:0] du1, input logic [31:0] du2,
                                 input logic [31:0] a1, input logic [31:0] m1,
                                 input logic [31:0] a2, input logic [31:0] m2, input logic order020);
	ex_t x;
	logic [1:0] sz;
	logic eq1, eq2;
	sz  = e.i.size;
	eq1 = (sz == SZ_W) ? (m1[15:0] == dc1[15:0]) : (m1 == dc1);
	eq2 = (sz == SZ_W) ? (m2[15:0] == dc2[15:0]) : (m2 == dc2);
	x = x0;
	x.a = eq1 ? dc2 : dc1;
	x.b = eq1 ? m2 : m1;
	x.dk = DK_NONE; x.dr = R_NONE;
	x.u0_v = 1'b0; x.u1_v = 1'b0;
	x.st_v = 1'b1; x.st_size = sz; x.st_rb = 1'b0;
	x.last = 1'b1;
	if (eq1 && eq2) begin
		x.st_addr = sec ? a2 : a1;
		x.st_data = (sec ? du2 : du1) & szmask(sz);
		x.last = sec;
		if (sec) x.wr_ccr = 1'b0;
	end else begin
		// w0 beats u1 in WB, so the register w0 names wins when Dc1 = Dc2
		if (order020) begin
			x.dk = DK_REG; x.dr = {2'b00, e.i.ext[2:0]}; x.c = mrg(dc1, m1, sz);
			x.u1_v = 1'b1; x.u1_r = {2'b00, e.i.ext2[2:0]}; x.u1_val = mrg(dc2, m2, sz);
		end else begin
			x.dk = DK_REG; x.dr = {2'b00, e.i.ext2[2:0]}; x.c = mrg(dc2, m2, sz);
			x.u1_v = 1'b1; x.u1_r = {2'b00, e.i.ext[2:0]}; x.u1_val = mrg(dc1, m1, sz);
		end
		x.st_addr = a2; x.st_data = m2 & szmask(sz); x.st_rb = 1'b1;
	end
	return x;
endfunction

// decided from the register file and the captured loads (vhold: no EX
// hazard, no load answering this clock), off EX's result path
wire cas2_two = (i.cls == CL_CAS2) &&
                ((i.size == SZ_W) ? (s_val[15:0] == rd_a[15:0]) : (s_val == rd_a)) &&
                ((i.size == SZ_W) ? (d_val[15:0] == rd_b[15:0]) : (d_val == rd_b));

reg bf_step;               // the second micro-op (bitfield trailing byte, CAS2 Du2) is next
wire ex_t x_ord0 = is_bf ? bf_uop(x_ord1, bf_step, eac_i, bfr, bf_mem, bf_modify, bf_two, bf_n, bf_addr) :
                   (i.cls == CL_CAS2) ? cas2_uop(x_ord1, bf_step, eac_i, rd_a, rd_b, rd_c, rd_d,   // (vhold: no EX hazard)
                                                 s_addr_c, s_val, d_addr_c, d_val,     // (vhold: loads captured)
                                                 CAS2_DC_ORDER_020 != 0) :
                   x_ord1;
wire two_uop = bf_two || cas2_two;
function automatic ex_t with_cc(input ex_t x, input logic c);
	ex_t y;
	y = x; y.cc = c;
	return y;
endfunction
wire [4:0] ex_ccr_here = ex_ccr_v ? ex_ccr : sr_in[4:0];
wire       br_cc       = cond_true(i.cond, ex_ccr_here);

// M3 traps, decided here where every operand is in hand (M68040UM 8.2.3
// p. 8-8: format $2, stacked PC = the next instruction, address field = the
// trapping one).  An (An)+/-(An) update of the trapping instruction stands.
function automatic logic signed [31:0] sized_s(input logic [31:0] v, input logic [1:0] sz);
	return (sz == SZ_B) ? $signed(sext8(v[7:0])) : (sz == SZ_W) ? $signed(sext16(v[15:0])) : $signed(v);
endfunction
// The trap decisions use the register file and the captured loads, never
// EX's result or a load answering this clock (vhold guarantees they are
// the same values when the decision is taken): timing, plan M3.
function automatic logic [31:0] dsrc(input id_t i, input logic [31:0] ra, input logic [31:0] sv);
	case (i.src.kind)
		EK_DREG, EK_AREG: return ra;
		EK_IMM:           return i.src.bd;
		default:          return sv;
	endcase
endfunction
wire [31:0] dec_src = dsrc(i, rd_a, s_val);
wire signed [31:0] chk_v  = sized_s(rd_b, i.size);
wire signed [31:0] chk_b  = sized_s(dec_src, i.size);
wire signed [31:0] c2_rn  = (i.dst.kind == EK_AREG) ? $signed(rd_b) : sized_s(rd_b, i.size);
wire signed [31:0] c2_lb  = sized_s(s_val, i.size);
wire signed [31:0] c2_ub  = sized_s(d_val, i.size);
wire c2_oob   = (c2_lb <= c2_ub) ? (c2_rn < c2_lb || c2_rn > c2_ub) : (c2_rn < c2_lb && c2_rn > c2_ub);
wire divz     = (i.cls == CL_MULDIV) && i.imm[0] &&
                ((i.size == SZ_W) ? (dec_src[15:0] == 16'd0) : (dec_src == 32'd0));
wire trap_u   = (i.cls == CL_CHK && (chk_v < 0 || chk_v > chk_b)) ||   // CHK: vector 6
                (i.cls == CL_CHK2 && i.ext[11] && c2_oob) ||            // CHK2: vector 6
                divz;                                                   // DIVx by zero: vector 5
wire trap_n   = (i.cls == CL_TRAPCC) && br_cc;                        // TRAPcc/TRAPV: vector 7
wire [7:0] trap_vec = divz ? 8'd5 : trap_n ? 8'd7 : 8'd6;

// MUL/DIV carry "divide by zero" in cc (EX then only clears C, 68040
// DIVU/DIVS by zero: X N Z V kept, reference S_MDL_RDQ)
// CAS: the compare's equality is decided here, so EX's store data and Dc
// value are selected by a register, not by its own compare (timing)
wire       cas_eq = (i.size == SZ_B) ? (x_ord0.a[7:0] == x_ord0.b[7:0]) :
                    (i.size == SZ_W) ? (x_ord0.a[15:0] == x_ord0.b[15:0]) : (x_ord0.a == x_ord0.b);
wire ex_t  x_ord       = with_cc(x_ord0, (i.cls == CL_MULDIV) ? divz : (i.cls == CL_CAS) ? cas_eq : br_cc);

function automatic logic [31:0] fsize(input logic [3:0] f);
	case (f)
		4'd2, 4'd3: return 32'd12;
		4'd4:       return 32'd16;
		4'd7:       return 32'd60;
		default:    return 32'd8;
	endcase
endfunction

// one exception-frame store
// longword k of the frame: {SR, PC}, {PC, format/vector}, then format $2's
// address, or format $7's words 8-59 (x7[k-2], M6)
function automatic ex_t exc_uop(input id_t i, input logic [3:0] k, input logic [31:0] sp,
                                input logic [15:0] sr, input logic [31:0] pc, input logic [3:0] fmt,
                                input logic [7:0] vec, input logic [31:0] addr, input logic [31:0] x7w);
	ex_t x;
	x = base_uop(i);
	x.cls  = CL_EXC;
	x.last = 1'b0;
	x.st_v = 1'b1; x.st_size = SZ_L;
	x.st_addr = sp + {26'd0, k, 2'b00};
	case (k)
		4'd0:    x.st_data = {sr, pc[31:16]};
		4'd1:    x.st_data = {pc[15:0], fmt, 2'b00, vec, 2'b00};
		// format $4 (the LC040's unimplemented-floating-point frame, M10.0):
		// longword 2 is the calculated effective address, longword 3 the PC of
		// the faulted instruction (M68040UM Appendix A.5.2, Table 12-1).  `i`
		// is still that instruction here: EA-fetch holds it through P_EXC.
		default: x.st_data = (fmt == 4'd7)                  ? x7w  :
		                     (fmt == 4'd4 && k == 4'd3)     ? i.pc : addr;
	endcase
	return x;
endfunction

// the exception-entry final micro-op
function automatic ex_t exc_final(input id_t i, input logic [4:0] bank, input logic [31:0] sp,
                                  input logic [15:0] sr, input logic [31:0] target,
                                  input logic irq, input logic [2:0] lvl,
                                  input logic mclr, input logic [31:0] msp2);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_EXC;
	x.exc = 1'b1;
	x.sp_v = 1'b1; x.sp_r = bank; x.sp_val = sp;
	// (M9.T) the throwaway pass also hands the MASTER stack back its own
	// new value: the normal frame went there, and this micro-op's `sp_r` is
	// the INTERRUPT stack the $1 frame went on.  Two stack pointers move, so
	// the second one rides on the micro-op's spare address-register write --
	// which must be u1, NOT u0: EX maps a sequenced `sp_v` onto u0
	// (ap040_execute.v, "a sequenced stack-pointer write goes out on the u0
	// port"), so a second write placed there is silently overwritten.
	if (mclr) begin x.u1_v = 1'b1; x.u1_r = R_MSP; x.u1_val = msp2; end
	// S set, T1/T0 cleared, M kept (M68040UM 8.1, p. 8-4) -- except for an
	// interrupt taken with M SET, which clears it (8.2.9: the throwaway
	// frame); an interrupt also sets the mask to its level (8.1.4)
	x.sr_v = 1'b1; x.sr_val = {2'b00, 1'b1, mclr ? 1'b0 : sr[12], sr[11], irq ? lvl : sr[10:8], sr[7:0]} & `AP040_SR_MASK;
	x.irq = irq;    // (the core acknowledges the interrupt when this commits)
	x.target = target;
	x.redirect = !target[0];
	x.last = !target[0];
	return x;
endfunction

// the RTE final micro-op
function automatic ex_t rte_final(input id_t i, input logic [4:0] bank, input logic [31:0] sp,
                                  input logic [15:0] fv, input logic [15:0] sr, input logic [31:0] pc);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_RTE;
	x.sp_v = 1'b1; x.sp_r = bank; x.sp_val = sp + fsize(fv[15:12]);
	x.sr_v = 1'b1; x.sr_val = sr & `AP040_SR_MASK;
	x.target = pc;
	x.redirect = (fv[15:12] != 4'd1) && !pc[0];
	x.last = x.redirect;
	return x;
endfunction

function automatic ex_t reset_final(input id_t i, input logic [31:0] ssp, input logic [31:0] pc);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_RESET;
	x.pc = 32'hFFFF_FFFF;
	x.sp_v = 1'b1; x.sp_r = R_ISP; x.sp_val = ssp;
	x.target = pc; x.redirect = 1'b1;
	return x;
endfunction

wire rte_fmt_ok = (r_fv[15:12] <= 4'd3) || (r_fv[15:12] == 4'd4 && HAS_FPU == 0) || (r_fv[15:12] == 4'd7);
wire rte_goes   = (r_fv[15:12] != 4'd1) && !r_pc[0];   // the RTE final micro-op redirects

//--------------------------------------------------------------- the step logic
typedef struct packed {
	logic        issue;  logic [2:0] it; logic [31:0] ia; logic [1:0] isz;
	logic        disp;   // a micro-op goes to EX this cycle
	logic        fin;    // the current instruction leaves EA-fetch this cycle
	logic [2:0]  dsel;   // which micro-op: 0 ordinary, 1 frame store, 2 exc final, 3 rte final, 4 reset
	logic        exc_go; logic [7:0] ev; logic [3:0] ef; logic [31:0] epc; logic [31:0] eaddr;
	logic        mm_go;  // MOVEM: the EA is known (memory-indirect pointer fetched), start the transfers
	logic        irq;    // (with exc_go) the exception is an interrupt
} stp_t;

function automatic stp_t stepf(
	input logic [3:0] ph, input logic ev_valid, input logic rstp, input id_t i,
	input logic older_busy, input logic can_rd, input logic rd_pend, input logic rd_ack, input logic cap,
	input logic s_bit, input logic stall,
	input rdreq_t nx, input logic ops_done, input logic jmp_odd, input logic rts_odd, input logic rtr_odd,
	input logic trap_u, input logic trap_n, input logic [7:0] trap_vec,
	input logic indexed, input logic two, input logic tstep, input logic sync,
	input logic [31:0] s_addr_c, input logic [31:0] s_val_c, input logic [31:0] d_val_c,
	input logic [2:0] x_step, input logic [31:0] vbr, input logic [7:0] x_vec, input logic [31:0] x_target,
	input logic [2:0] r_step, input logic [31:0] sp_now, input logic fmt_ok, input logic rte_goes,
	input logic rx7, input logic rs_done, input logic has_fpu, input logic tr_arm);
	stp_t s;
	s = '0;
	case (ph)
		P_START, P_OPS: if (ev_valid && !rstp) begin
			// (an interrupt at this boundary overrides everything this chain
			// decides -- irq_st below, not a term in the chain: timing)
			if (i.serialize && older_busy && ph == P_START) begin
				// wait until everything older has committed
			end else if (i.priv && !s_bit) begin
				s.exc_go = 1'b1; s.ev = 8'd8; s.ef = 4'd0; s.epc = i.pc;
			end else if (i.cls == CL_EXC) begin
				s.exc_go = 1'b1; s.ev = i.exc_vec; s.ef = i.exc_fmt;
				s.epc = i.exc_next ? i.next_pc : i.pc;
				// A format $4 frame stacks the CALCULATED effective address,
				// which EA-calc has already produced -- no operand is read.
				// It is 0 when the instruction has no memory operand (D18).
				s.eaddr = (i.exc_fmt == 4'd4) ? ((i.src.kind == EK_MEM) ? s_addr_c : 32'd0)
				                              : i.exc_addr;
			end else if (i.cls == CL_RTE) begin
				// the sequence runs in P_RTE
			end else if (i.cls == CL_PMMU) begin
				// the sequence runs in P_PMMU
			end else if (i.cls == CL_CINV) begin
				// the sequence runs in P_CINV
			end else if (has_fpu && i.cls == CL_FPU) begin
				// the FPU request runs in P_FPU (M10.1(c)).  With HAS_FPU = 0
				// this arm folds away: CL_FPU is never decoded.
			end else if (i.cls == CL_STOP) begin
				// the SR micro-op, then the stopped state (P_STOP) -- unless
				// the STOP is TRACED (M9.T), when it loads the SR and ENDS:
				// the trace is taken in front of the instruction after it and
				// the stopped state is never entered at all
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd0; s.fin = tr_arm; end
			end else if (i.cls == CL_RSTO) begin
				// RSTO in P_RSTO
			end else if (i.cls == CL_NOP && sync) begin
				// NOP synchronises: it waits until every older store is in memory
				// (M68040UM 7.7 bus synchronisation, p. 7-43)
			end else begin
				if (nx.v && !cap && can_rd && !rd_pend) begin
					s.issue = 1'b1; s.it = nx.t; s.ia = nx.a; s.isz = nx.sz;
				end
				if (ops_done && !(rd_pend && !rd_ack)) begin
					if (jmp_odd) begin
						// JMP: the frame PC is where gencpu's PC had reached (reference S_JMP1);
						// JSR: the fault is on the fetch at the target, no push (S_JSR1)
						s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
						s.epc = (i.cls == CL_JSR) ? s_addr_c : (i.pc + (indexed ? 32'd6 : 32'd2));
						s.eaddr = {s_addr_c[31:1], 1'b0};
					end else if (rts_odd) begin
						// the pop is backed out (reference S_RET2): no micro-op, SP untouched
						s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
						s.epc = i.pc; s.eaddr = {s_val_c[31:1], 1'b0};
					end else if (trap_u) begin
						// CHK/CHK2/DIV by zero: the micro-op (flags; An updates stand)
						// commits, then the trap is taken with that SR
						if (!stall) begin
							s.disp = 1'b1; s.dsel = 3'd6;
							s.exc_go = 1'b1; s.ev = trap_vec; s.ef = 4'd2;
							s.epc = i.next_pc; s.eaddr = i.pc;
						end
					end else if (trap_n) begin
						s.exc_go = 1'b1; s.ev = trap_vec; s.ef = 4'd2;
						s.epc = i.next_pc; s.eaddr = i.pc;
					end else if (rtr_odd) begin
						// RTR to an odd PC: the popped CCR stands, SP does not move, and
						// the frame stacks the SR with that CCR (reference S_RET3)
						if (!stall) begin
							s.disp = 1'b1; s.dsel = 3'd5;
							s.exc_go = 1'b1; s.ev = 8'd3; s.ef = 4'd2;
							s.epc = i.pc; s.eaddr = {d_val_c[31:1], 1'b0};
						end
					end else if (i.cls == CL_MOVEM) begin
						s.mm_go = 1'b1;
					end else if (!stall) begin
						// a two-micro-op instruction (bitfield trailing byte) finishes on the second
						s.disp = 1'b1; s.dsel = 3'd0; s.fin = !two || tstep;
					end
				end
			end
		end
		P_EXC: begin
			if (x_step == 3'd0) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd1; end
			end else if (x_step == 3'd3) begin
				if (!rd_pend && can_rd) begin
					s.issue = 1'b1; s.it = T_VEC; s.ia = vbr + {22'd0, x_vec, 2'b00}; s.isz = SZ_L;
				end
			end else if (x_step == 3'd4) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd2; s.fin = !x_target[0]; end
			end
		end
		P_RTE: begin
			if (r_step <= 3'd2) begin
				if (!rd_pend && can_rd) begin
					s.issue = 1'b1; s.it = T_SEQ0 + r_step;
					s.ia = sp_now + ((r_step == 3'd0) ? 32'd0 : (r_step == 3'd1) ? 32'd2 : 32'd6);
					s.isz = (r_step == 3'd1) ? SZ_L : SZ_W;
				end
			end else if (r_step == 3'd3 && rx7) begin
				// format $7: the EA (restored for a MOVEM continuation) ...
				if (!rd_pend && can_rd) begin s.issue = 1'b1; s.it = T_DMI; s.ia = sp_now + 32'd8; s.isz = SZ_L; end
			end else if (r_step == 3'd4 && rx7) begin
				// ... and the SSW (its CM bit)
				if (!rd_pend && can_rd) begin s.issue = 1'b1; s.it = T_SMI; s.ia = sp_now + 32'd12; s.isz = SZ_W; end
			end else if (r_step == (rx7 ? 3'd5 : 3'd3)) begin
				if (fmt_ok) begin
					if (!stall) begin s.disp = 1'b1; s.dsel = 3'd3; s.fin = rte_goes; end
				end else begin
					// format error: vector 14, format $0, PC = the RTE
					s.exc_go = 1'b1; s.ev = 8'd14; s.ef = 4'd0; s.epc = i.pc;
				end
			end
		end
		// P_STOP: an interrupt above the (new) mask ends the stopped state
		// once the STOP's SR micro-op has committed, with the PC of the
		// instruction after the STOP (M68040UM 8.1.4; PRM STOP) -- irq_st
		// below, with the rest of the interrupt entry
		P_RSTO: if (ev_valid) begin
			if (rs_done && !stall) begin s.disp = 1'b1; s.dsel = 3'd0; s.fin = 1'b1; end
		end
		P_RESET: begin
			if (r_step <= 3'd1) begin
				if (!rd_pend) begin
					s.issue = 1'b1; s.it = T_SEQ0 + r_step; s.ia = (r_step == 3'd0) ? 32'd0 : 32'd4; s.isz = SZ_L;
				end
			end else if (r_step == 3'd2) begin
				if (!stall) begin s.disp = 1'b1; s.dsel = 3'd4; end
			end
		end
		default: ;
	endcase
	return s;
endfunction

// reads never wait for older stores (store-to-load forwarding, above)
// a bitfield's read address uses the register file: no read while EX writes one of its registers
wire bf_rdblk = is_bf && ex_haz;
wire [15:0] dbc_dec = rd_b[15:0] - 16'd1;
wire       br_taken = (i.cls == CL_BCC) ? br_cc : (!br_cc && dbc_dec != 16'hFFFF);

// T0 traces only CHANGES OF FLOW: a taken branch or a return, and the
// instructions the 68040 counts as pipeline synchronisation points, which
// decode carries in `t0sync` (the reference's `t0_special` list, copied
// verbatim, plus FDBcc and the FMOVEM store forms).  A conditional branch is
// known here and nowhere else: ID GUESSED IT TAKEN, so a not-taken one is the
// one that redirects, and `br_taken` above is the answer either way.
wire tr_flow = ((i.cls == CL_BCC) || (i.cls == CL_DBCC)) ? br_taken
             : (i.cls == CL_BSR) || (i.cls == CL_JMP) || (i.cls == CL_JSR) ||
               (i.cls == CL_RTS) || (i.cls == CL_RTD) || (i.cls == CL_RTR) ||
               (i.cls == CL_RTE) ||
               ((HAS_FPU != 0) && (ph == P_FPU) && fp_bcc && fp_ctk);
// STOP makes its own T0 decision: T1 traces it unconditionally, T0 only when
// the SR it writes CHANGES T1/T0/S/M or the interrupt mask (WinUAE's
// MakeFromSR returns before its trace decision when none of those move, and
// STOP has no check_t0_trace like the MOVE-to-SR family).  A traced STOP does
// not enter the stopped state at all.
wire tr_stop_t0 = {i.imm[15:12], i.imm[10:8]} != {sr_in[15:12], sr_in[10:8]};
wire tr_t0_ev   = (i.cls == CL_STOP) ? tr_stop_t0 : (i.t0sync || tr_flow);
wire tr_arm     = sr_in[15] || (sr_in[14] && tr_t0_ev);

// (timing) TRAPcc's decision, br_cc, comes from the CCR EX forwards this
// clock, and inside stepf it sat at the head of the if-chain that decides
// `fin` -- so EX's flags reached eaf_stall, and from there EA-calc's
// redirect, ID's consume and IF's fetch PC.  stepf is therefore evaluated
// with trap_n = 0 and the TRAPcc arm is applied AFTER it, where br_cc is one
// term of the last gate.  Exactly equivalent: trap_n implies i.cls ==
// CL_TRAPCC, so in stepf's P_START/P_OPS arm every class test before the
// final `else` is false, and so are jmp_odd (JMP/JSR), rts_odd (RTS/RTD) and
// trap_u (CHK/CHK2/DIV) -- the only arms that could have come first.  With
// trap_n = 0 that arm reaches the ordinary dispatch instead, which sets only
// disp/dsel/fin; trapn_ov puts them back to what the trap arm leaves (0) and
// sets the exception fields the trap arm sets.  The STOP arm's `tr_arm` is
// likewise given its STOP-only form (tr_t0_ev is tr_stop_t0 when i.cls ==
// CL_STOP), which is the same value there and has no branch in it.
function automatic stp_t trapn_ov(input stp_t s0, input logic go, input logic [7:0] vec,
                                  input logic [31:0] npc, input logic [31:0] pc);
	stp_t s;
	s = s0;
	if (go) begin
		s.disp = 1'b0; s.dsel = 3'd0; s.fin = 1'b0;
		s.exc_go = 1'b1; s.ev = vec; s.ef = 4'd2; s.epc = npc; s.eaddr = pc;
	end
	return s;
endfunction
wire tr_arm_stop = sr_in[15] || (sr_in[14] && tr_stop_t0);
wire trapn_arm = ((ph == P_START) || (ph == P_OPS)) && eac_v_use && !rst_pending &&
                 !(i.serialize && older_busy && ph == P_START) && !(i.priv && !s_bit) &&
                 ops_done && !(rd_pend && !rd_ack);
wire stp_t st0_nt = stepf(ph, eac_v_use, rst_pending, i, older_busy, !bf_rdblk, rd_pend, rd_ack, cap,
                      s_bit, stall_in, nx, ops_done, jmp_odd, rts_odd, rtr_odd, trap_u, 1'b0, trap_vec,
                      indexed_mode, two_uop, bf_step, sync_busy, s_addr_c, s_val_c,
                      d_val_c, x_step, vbr_in, x_vec, x_target, r_step, rd_a, rte_fmt_ok, rte_goes,
                      r_fv[15:12] == 4'd7, rs_cnt == 10'd0, HAS_FPU != 0, tr_arm_stop);
wire stp_t st0 = trapn_ov(st0_nt, trap_n && trapn_arm, trap_vec, i.next_pc, i.pc);

//--------------------------------------------------------------- access errors
// A data read that ends in an access error (M68040UM 8.2.1, p. 8-6): the
// instruction is abandoned -- it has committed nothing except, for MOVEM,
// registers a restart loads again -- and takes vector 2 with a format $7
// frame whose PC is the instruction itself (restart).  The frame words
// follow the reference core (lib/AP68040 ap040_core.v aerr_start /
// aerr_word): EA = FA = the transfer's first byte (MOVE16: EA line
// aligned), SSW {CP CU CT CM = 0, MA = 0, ATC, LK, RW = !LK, X = 0, SIZE,
// TT, TM}, WB1S-WB3S = 0, WB3A = FA, WB3D = the port's last write data,
// the rest 0.
function automatic logic [15:0] ssw_f(input logic cm, input logic ma, input logic atc, input logic lk, input logic wr, input logic [1:0] sz,
                                      input logic m16, input logic moves, input logic [2:0] fc);
	logic [1:0] tt, szf;
	logic [2:0] tm;
	tt = 2'b00; tm = fc;
	if (moves && (fc[1:0] == 2'b00 || fc[1:0] == 2'b11)) tt = 2'b10;
	else if (moves && fc[1]) tm = {fc[2], 2'b01};         // FC 2/6: data space (p. 8-28)
	if (m16) tt = 2'b01;
	szf = m16 ? 2'b11 : (sz == SZ_B) ? 2'b01 : (sz == SZ_W) ? 2'b10 : 2'b00;
	return {3'b000, cm, ma, atc, lk, !wr && !lk, 1'b0, szf, tt, tm};
endfunction
wire        aer_lk   = (i.cls == CL_CAS) || (i.cls == CL_CAS2) ||
                       (i.cls == CL_ALU && i.alu == `AP040_ALU_TAS && i.dst.kind == EK_MEM);
wire        aer_m16  = (i.cls == CL_MOVEM) && i.imm[2];
wire [15:0] aer_ssw  = ssw_f(ph == P_MOVEM && mm_cmi, rd_ma, rd_atc, aer_lk, 1'b0, rd_sz_q, aer_m16, i.fcsel != 2'd0, rd_fc_q);
// A store's access error (synchronous stores: the micro-op is still in
// WB).  On the instruction's last micro-op everything else it did has
// committed: the write is reported pending in WB1 and the stacked PC is past
// the instruction (M68040UM 8.4.6.3 case 3; the handler completes WB1, as
// NetBSD's trap.c does; a MOVE16 carries its line in PD0-PD3, case 4).  On
// an earlier micro-op (MOVEM, MOVE16, a bitfield's or CAS2's first store)
// the instruction restarts, as the reference core does, WB1S = 0.  A fault
// on an exception-frame store is a double fault.
wire [15:0] wf_ssw  = ssw_f(wb_stf.cm, wb_fma, wb_fatm, wb_stf.lk, 1'b1, wb_st_s, wb_stf.m16, wb_stf.moves, wb_st_f);
function automatic logic [7:0] wbs_f(input logic [15:0] ssw);
	return {1'b1, ssw[6:0]};               // V, SIZE, TT, TM (Figure 8-8)
endfunction
wire        wf_dbl  = wb_fault && (wb_stf.exc || ph == P_EXC || ph == P_RTE || ph == P_RESET);
wire        wf_last = wb_last && !wb_stf.cm;      // MOVEM: CM and a restart, never WB1
wire        wf_go   = wb_fault && !wf_dbl;
wire        aerr_go  = cap_err && eac_v_use && (ph == P_START || ph == P_OPS || ph == P_MOVEM);
wire        aerr_dbl = cap_err && (ph == P_EXC || ph == P_RTE || ph == P_RESET);

//--------------------------------------------------------------- MOVEM
// PRM 4-128..4-131.  Mask bit k names D0..D7, A0..A7 (k = 0..15), reversed
// for -(An).  One micro-op per register: a store (the register read through
// port c, EX-forwarded), or a load's register write (word loads sign-extend
// into Dn as well).  Memory to
// registers with (An)+: the base register is not loaded, it gets the
// incremented address.  (-(An): the base register's stored value is its
// initial value minus the size, PRM 4-128.)  The An update rides on the
// last micro-op.  Loads
// go one per clock: the next read issues in the clock a read answers; a
// load answering while EX stalls waits in mm_have.  mm_mask and mm_addr
// are the saved state M6's restart will use (plan M4 Files).
reg  [15:0] mm_mask;       // registers still to transfer (loads: still to read)
reg  [31:0] mm_addr;       // next address
reg         mm_empty;      // the mask was zero: one empty micro-op retires it
reg   [4:0] mm_rreg;       // the outstanding read's register
reg         mm_rlast;      // ... and it is the last one
reg         mm_have;       // a loaded value waiting for EX
reg  [31:0] mm_hdata;
reg   [4:0] mm_hreg;
reg         mm_hlast;

wire        mm_ld   = i.imm[0];
// MOVEP (PRM 4-133): the same sequencer on bytes at every other address;
// stores send the register's bytes high first, loads collect the bytes and
// write Dx once (the low word for .W) with the last one
wire        mm_p    = i.imm[1];
wire  [4:0] mp_reg  = mm_ld ? eac_i.dst_r : eac_i.src_r;
// MOVE16 (PRM 4-125): the four source longwords are read into m16_buf
// (one per clock) and each is stored to the destination line as soon as it
// is in (the lines are aligned to 16, so they are the same line or
// disjoint: a store never changes a longword still to be read); a
// postincremented register gets +16 once (the same register named twice:
// once -- WinUAE gencpu i_MOVE16, PRM silent).  The line is moved in
// address order (the burst's start-at-EA order is a bus detail the M5
// adapter can add).
wire        mm_16   = i.imm[2];
reg   [3:0] m16_smask;     // longwords still to store
reg   [3:0] m16_have;      // longwords read
reg  [31:0] m16_saddr;     // next store address
reg  [31:0] m16_buf [0:3];
reg   [1:0] mm_rk;         // the outstanding read's index (MOVE16)
wire        mm_lde  = mm_16 ? 1'b1 : mm_ld;        // MOVE16's reads run through the load path
wire  [1:0] m16_ks  = m16_smask[0] ? 2'd0 : m16_smask[1] ? 2'd1 : m16_smask[2] ? 2'd2 : 2'd3;
wire        m16_sd  = mm_16 && (m16_smask != 4'd0) && m16_have[m16_ks] && !stall_in;
wire        m16_sf  = m16_sd && ((m16_smask & (m16_smask - 4'd1)) == 4'd0);
wire        mm_pre  = (i.dst.kind == EK_MEM) && (i.dst.mode == 3'd4);
wire        mm_post = (i.src.kind == EK_MEM) && (i.src.mode == 3'd3);
wire  [4:0] mm_base = mm_ld ? eac_i.src_r : eac_i.dst_r;
wire [31:0] mm_sz   = (mm_p || i.size == SZ_W) ? 32'd2 : 32'd4;

function automatic logic [3:0] lsb16(input logic [15:0] m);
	logic [3:0] k;
	int j;
	k = 4'd0;
	for (j = 15; j >= 0; j = j - 1)
		if (m[j]) k = j[3:0];
	return k;
endfunction
function automatic logic [4:0] mm_reg(input logic [3:0] k, input logic pre, input logic s, input logic m);
	logic [3:0] j;
	j = pre ? 4'd15 - k : k;
	return (j == 4'd15) ? resolve_sp(R_A7L, s, m) : {1'b0, j};   // 0-7 D0-D7, 8-14 A0-A6
endfunction
// (timing) mm_k is a register: lsb16 of the mask is formed the clock before,
// from the value mm_mask is being given, at every place mm_mask is written
// (MOVEM start, a load issued, a store dispatched, reset), so mm_k_q always
// equals lsb16(mm_mask) and the priority encoder is off the path from the
// mask through the register-file read address (ra_c) into op_c / st_data.
reg   [3:0] mm_k_q;
wire  [3:0] mm_k     = mm_k_q;
`ifndef SYNTHESIS
always @(posedge clk)
	if (nreset && mm_k_q !== lsb16(mm_mask))
		$display("ERROR: ap040_ea_fetch: mm_k_q %0d != lsb16(mm_mask %h) at %0t", mm_k_q, mm_mask, $time);
`endif
wire  [4:0] mm_sreg  = mm_p ? mp_reg : mm_reg(mm_k, mm_pre, s_bit, sr_in[12]);
reg  [23:0] mp_acc;        // MOVEP load: the bytes so far
wire        mm_one   = (mm_mask & (mm_mask - 16'd1)) == 16'd0;   // at most one register left

// the step: loads issue from mm_mask and dispatch from the answer (or
// mm_have); stores dispatch from mm_mask
typedef struct packed {
	logic issue; logic disp; logic fin; logic from_buf; logic to_buf; logic empty;
	logic tail;   // the last -(An) store went: the An update follows on its own
	logic tailu;  // ... this is that micro-op
} mms_t;
function automatic mms_t mm_step(input logic ld, input logic [15:0] mask, input logic empty,
                                 input logic pend, input logic cap, input logic have, input logic stall,
                                 input logic rlast, input logic hlast, input logic one, input logic mp,
                                 input logic sblk,
                                 input logic nodisp, input logic tailreq, input logic tail);
	mms_t r;
	r = '0;
	if (tail) begin
		if (!stall) begin r.disp = 1'b1; r.fin = 1'b1; r.empty = 1'b1; r.tailu = 1'b1; end
	end else if (empty) begin
		if (!stall) begin r.disp = 1'b1; r.fin = 1'b1; r.empty = 1'b1; end
	end else if (ld) begin
		if (have) begin
			if (!stall) begin r.disp = 1'b1; r.from_buf = 1'b1; r.fin = hlast; end
		end else if (cap && (!mp || rlast) && !nodisp) begin   // (MOVEP: only the last byte; MOVE16: none)
			if (!stall) begin r.disp = 1'b1; r.fin = rlast; end
			else r.to_buf = 1'b1;
		end
		r.issue = (mask != 16'd0) && (!pend || cap) && !have && !stall;
	end else begin
		// (a store waits while EX writes the register it stores: its value
		// comes from the register file, never from EX -- timing)
		if (!stall && mask != 16'd0 && !sblk) begin r.disp = 1'b1; r.fin = one && !tailreq; r.tail = one && tailreq; end
	end
	return r;
endfunction
wire mm_sblk = hz(ex_w0_v, ex_w0_r, ra_c, ra_c, ra_c, ra_c) || hz(ex_u0_v, ex_u0_r, ra_c, ra_c, ra_c, ra_c) ||
               hz(ex_u1_v, ex_u1_r, ra_c, ra_c, ra_c, ra_c);
reg  mm_tail;              // the trailing An-update micro-op is next
wire mms_t mms = mm_step(mm_lde, mm_mask, mm_empty, rd_pend, cap, mm_have, stall_in, mm_rlast, mm_hlast, mm_one,
                         mm_p, mm_sblk, mm_16, (MM_TAIL != 0) && mm_pre && !mm_ld && !mm_p && !mm_16, mm_tail);

function automatic ex_t mm_uop(input id_t i, input mms_t m, input logic ld, input logic [4:0] r,
                               input logic [31:0] v, input logic [31:0] addr, input logic last,
                               input logic upd, input logic [4:0] br, input logic [31:0] bval,
                               input logic skipw, input logic mp, input logic [3:0] k);
	ex_t x;
	x = base_uop(i);
	x.cls = CL_MOVEM;
	x.last = last;
	if (m.empty) ;
	else if (ld) begin
		if (!skipw) begin
			x.dk = DK_REG; x.dr = r;
			x.c = mp ? v : (i.size == SZ_W) ? sext16(v[15:0]) : v;   // (MOVEP: v is the merged Dx)
		end
	end else if (mp) begin                        // byte k, high first
		x.st_v = 1'b1; x.st_addr = addr; x.st_size = SZ_B;
		x.st_data = {24'd0, (i.size == SZ_W) ? v[8 * (1 - k[0]) +: 8] : v[8 * (3 - k[1:0]) +: 8]};
	end else begin
		x.st_v = 1'b1; x.st_addr = addr; x.st_size = i.size;
		x.st_data = (i.size == SZ_W) ? {16'd0, v[15:0]} : v;
	end
	if (last && upd && (!m.empty || m.tailu)) begin x.u1_v = 1'b1; x.u1_r = br; x.u1_val = bval; end
	return x;
endfunction
wire  [4:0] mm_dreg = mm_lde ? (mms.from_buf ? mm_hreg : mm_rreg) : mm_sreg;
// -(An) with the base in the list: the MC68020/30/40 store the initial
// value decremented by the operand size (PRM 4-128; plan D8)
// MOVEP load: the last byte completes Dx (.W: its low word; op_b = Dx)
wire [31:0] mp_val  = (i.size == SZ_W) ? {op_b[31:16], mp_acc[7:0], rd_data[7:0]} : {mp_acc, rd_data[7:0]};
wire [31:0] mm_dval = mm_ld ? (mms.from_buf ? mm_hdata : mm_p ? mp_val : rd_data) :
                      (mm_pre && mm_sreg == mm_base) ? rd_c - mm_sz : rd_c;
function automatic ex_t m16_upd(input ex_t x0, input logic m16, input logic last, input eac_t e);
	ex_t x;
	x = x0;
	if (m16 && last) begin
		x.u0_v = e.i.imm[3]; x.u0_r = e.src_r; x.u0_val = e.src_ea + 32'd16;
		x.u1_v = e.i.imm[4]; x.u1_r = e.dst_r;
		x.u1_val = ((e.src_r == e.dst_r) ? e.src_ea : e.dst_ea) + 32'd16;
	end
	return x;
endfunction
// A control-mode load that names its base register writes it only with the
// last register (the reference's mm_base_pend), so a restart after an
// access error part way recomputes the EA from the original base; (An)+
// never loads the base (it gets the incremented address).
wire        mm_bnow = mm_ld && !mm_p && (mm_dreg == mm_base) && mms.disp && !mms.empty;
wire [31:0] mm_lval = (i.size == SZ_W) ? sext16(mm_dval[15:0]) : mm_dval;
reg         mm_bv;         // the base register's loaded value is waiting
reg  [31:0] mm_bval;
wire        mm_upd  = (mm_pre || mm_post) || mm_bv || mm_bnow;
wire [31:0] mm_uval = mm_tail ? mm_addr + mm_sz :              // (the trailing micro-op: after the last decrement)
                      (mm_pre || mm_post) ? mm_addr : mm_bnow ? mm_lval : mm_bval;
wire ex_t   mm_x0   = mm_uop(i, mms, mm_lde, mm_dreg, mm_dval, mm_addr, mms.fin, mm_upd,
                             mm_base, mm_uval, mm_ld && !mm_p && mm_dreg == mm_base, mm_p, mm_k);
wire ex_t   m16_x   = m16_upd(mm_uop(i, '0, 1'b0, 5'd0, m16_buf[m16_ks], m16_saddr, m16_sf, 1'b0,
                                     5'd0, 32'd0, 1'b0, 1'b0, 4'd0),
                              1'b1, m16_sf, eac_i);
wire ex_t   mm_x    = mm_16 ? m16_x : mm_x0;

function automatic stp_t mm_st(input mms_t m, input logic [31:0] a, input logic [1:0] sz);
	stp_t t;
	t = '0;
	t.issue = m.issue; t.it = T_SLD; t.ia = a; t.isz = sz;
	t.disp = m.disp; t.dsel = 3'd7; t.fin = m.fin;
	return t;
endfunction
function automatic stp_t m16_st_f(input stp_t t0, input logic sd, input logic sf);
	stp_t t;
	t = t0; t.disp = sd; t.fin = sf;
	return t;
endfunction
wire stp_t st1 = (ph != P_MOVEM) ? st0 :
                 mm_16 ? m16_st_f(mm_st(mms, mm_addr, i.size), m16_sd, m16_sf) :
                 mm_st(mms, mm_addr, mm_p ? SZ_B : i.size);
//--------------------------------------------------------------- the FPU
// The command port is bit fields of the first extension word (M10.1(a)), so
// id_t needs no new field: `ext` already carries it for MOVEC's selector.
// Opclass 011 (FMOVE FPn,<ea>) names its floating-point register in the
// DESTINATION field, and ap040_fpu reads it on src_r (lib/AP68040
// ap040_core.v:3898), so that one form maps ext[9:7] there.
assign fp_op_class = i.ext[15:13];
assign fp_opmode   = i.ext[6:0];
assign fp_src_fmt  = i.ext[12:10];
assign fp_src_r    = (i.ext[15:13] == 3'b011) ? i.ext[9:7] : i.ext[12:10];
assign fp_dst_r    = i.ext[9:7];
// FPIAR is written with the dispatching instruction's own PC, on the same
// clock the request goes out; `i` does not move while P_FPU owns the stage,
// so the PC that rides the pulse is the instruction in the unit.  This is
// the reference's rule exactly: every `fpu_iawe` in lib/AP68040's
// ap040_core.v is asserted together with `fpu_req`, and the subset that
// reaches the unit today (opclass 000/010/011) is all FPIAR-writing.  When
// opclass 100/101 arrives it must NOT write FPIAR -- a move to or from a
// control register leaves it alone -- so that decode has to break this
// equality rather than extend it.
assign fp_ia_we    = fp_req;
assign fp_ia_wdata = (HAS_FPU != 0) ? i.pc : 32'd0;
// where the operand comes from, always LEFT aligned in the 96-bit window:
// memory (assembled in fp_buf), the instruction stream (the decoder's
// fpimm -- never a bus access, lib/AP68040 S_FPU_IMM), or a data register.
// (M10.2) opclass 100/101: the effective address is the SOURCE when the
// control registers are the destination (ext[13] = 0) and the destination
// when they are the source (ext[13] = 1), so it joins the same two wires.
// (M10.5) FSAVE and FRESTORE carry NO floating-point extension word, so the
// class wires below must not read `ext` for them: every one is qualified on
// the opcode's own field.
wire        fp_gen     = (i.opcode[8:6] == 3'b000);
wire        fp_sv      = (HAS_FPU != 0) && (i.opcode[8:6] == 3'b100);   // FSAVE
wire        fp_rs      = (HAS_FPU != 0) && (i.opcode[8:6] == 3'b101);   // FRESTORE
// (M10 remainder) a pending deferred exception is NOT taken in front of an
// FSAVE that finds its frame prepared -- the FSAVE extracts it -- nor in front
// of an FRESTORE, which replaces the state wholesale (lib/AP68040 S_FSAVE1,
// S_FREST1: "FRESTORE neither reports it").  An FSAVE with no frame left (it
// was extracted already) still takes it: the reference's frameless fallback.
wire        fp_pex     = fp_rs || (fp_sv && fp_st_unimp);
wire        fp_cr      = (HAS_FPU != 0) && fp_gen && (i.ext[15:14] == 2'b10);
// (M10.8) the conditional forms.  FBcc takes its predicate from the OPCODE,
// the FScc family from the extension word; bit 5 of the six-bit field aliases
// and is not a trap (WinUAE's fpp_cond masks with $1F, and t_fpu.s section 44
// pins it), so only bits 4:0 are read.
wire        fp_bcc     = (HAS_FPU != 0) && (i.opcode[8:6] == 3'b010 || i.opcode[8:6] == 3'b011);
wire        fp_sccf    = (HAS_FPU != 0) && (i.opcode[8:6] == 3'b001);
wire        fp_dbcc    = fp_sccf && (i.opcode[5:3] == 3'b001);
wire        fp_trapcc  = fp_sccf && (i.opcode[5:0] == 6'b111_010 ||
                                     i.opcode[5:0] == 6'b111_011 ||
                                     i.opcode[5:0] == 6'b111_100);
wire        fp_scc     = fp_sccf && !fp_dbcc && !fp_trapcc;
wire        fp_cnd     = fp_bcc || fp_sccf;
wire  [5:0] fp_pred    = fp_bcc ? i.opcode[5:0] : i.ext[5:0];
// the 68040 predicate table (lib/AP68040 fp_cond, M68000PM/AD Table 3-x)
function automatic logic fp_ctrue(input logic [5:0] pred, input logic [3:0] cc);
	logic n, z, nan;
	n = cc[3]; z = cc[2]; nan = cc[0];
	case (pred[3:0])
		4'h0: return 1'b0;                      // F / SF
		4'h1: return z;                         // EQ
		4'h2: return !(nan | z | n);            // OGT
		4'h3: return z | !(nan | n);            // OGE
		4'h4: return n & !(nan | z);            // OLT
		4'h5: return z | (n & !nan);            // OLE
		4'h6: return !(nan | z);                // OGL
		4'h7: return !nan;                      // OR
		4'h8: return nan;                       // UN
		4'h9: return nan | z;                   // UEQ
		4'hA: return nan | !(n | z);            // UGT
		4'hB: return nan | z | !n;              // UGE
		4'hC: return nan | (n & !z);            // ULT
		4'hD: return nan | z | n;               // ULE
		4'hE: return !z;                        // NE
		default: return 1'b1;                   // T / ST
	endcase
endfunction
wire        fp_ctk     = fp_ctrue(fp_pred, fp_fpcc);
// a SIGNALLING predicate (bit 4) that meets an unordered result records BSUN
// whether or not the trap is enabled, and takes vector 48 when it is
wire        fp_bsun_h  = fp_cnd && fp_pred[4] && fp_fpcc[0];
assign fp_bsun_req     = (HAS_FPU != 0) && fp_bsun_h && (ph == P_FPU) && !fp_crd;
wire        fp_bsun_go = fp_bsun_h && fp_bsun_en;
// FScc writes a byte of all ones or all zeros; FDBcc counts Dn.w down
wire [31:0] fp_sccv    = {24'd0, {8{fp_ctk}}};
wire [15:0] fp_dbn     = op_a[15:0] - 16'd1;
wire        fp_cr_st   = fp_cr && i.ext[13];        // FPcr -> <ea>
wire  [2:0] fp_crmask  = (i.ext[12:10] == 3'd0) ? 3'b001 : i.ext[12:10];  // empty = FPIAR
wire  [1:0] fp_crn     = {1'b0, fp_crmask[2]} + {1'b0, fp_crmask[1]} + {1'b0, fp_crmask[0]};
// the k-th selected register in FPCR, FPSR, FPIAR order -- which is also
// ascending address order (PRM FMOVEM, lib/AP68040 S_FPU_CR) -- as cr_sel,
// whose encoding (2 FPCR, 1 FPSR, 0 FPIAR) is the same bit position.
function automatic logic [1:0] cr_nth(input logic [2:0] m, input logic [1:0] k);
	logic [1:0] seen;
	logic [1:0] r;
	seen = 2'd0; r = 2'd0;
	if (m[2]) begin if (seen == k) r = 2'd2; seen = seen + 2'd1; end
	if (m[1]) begin if (seen == k) r = 2'd1; seen = seen + 2'd1; end
	if (m[0]) begin if (seen == k) r = 2'd0; seen = seen + 2'd1; end
	return r;
endfunction
assign fp_cr_sel   = fp_cw ? fp_csel : cr_nth(fp_crmask, fp_k);
assign fp_cr_we    = fp_cw;
assign fp_cr_wdata = fp_cwd;
// (M10.4) FMOVEM of the FP registers: twelve bytes each, and two ordering
// quirks the reference takes from WinUAE's fmovem2mem (PLAN.md D21) --
//   `fp_lsb`  a PREDECREMENT store consumes the mask from its LSB, so the
//             ascending walk reproduces the hardware's descending layout;
//   `fp_rev`  a store whose mask convention disagrees with its address
//             direction writes each register's three longwords in reverse.
// A load always maps mask bit 7 to FP0, whatever the mode field says.
wire        fp_mvm   = (HAS_FPU != 0) && fp_gen && (i.ext[15:14] == 2'b11);
wire        fp_mvst  = fp_mvm && i.ext[13];
// (M10.9) a DYNAMIC list: the mask is in the data register `reg_c` names, so
// the count and the (An)+ / -(An) step are run-time values -- the step goes
// out through the an_ov hook, which is what it was built for.
wire        fp_mvdy  = fp_mvm && i.ext[11];
wire  [7:0] fp_mvmk  = fp_mvdy ? op_c[7:0] : i.ext[7:0];
wire  [3:0] fp_mvn   = {3'd0, fp_mvmk[7]} + {3'd0, fp_mvmk[6]} + {3'd0, fp_mvmk[5]} +
                       {3'd0, fp_mvmk[4]} + {3'd0, fp_mvmk[3]} + {3'd0, fp_mvmk[2]} +
                       {3'd0, fp_mvmk[1]} + {3'd0, fp_mvmk[0]};
wire  [6:0] fp_mvb12 = {fp_mvn, 3'd0} + {1'b0, fp_mvn, 2'd0};       // 12 x n
reg   [6:0] fp_mvb12_q;   // fp_mvb12 as it was in the P_FPU entry clock (fp_anv)
wire        fp_mvpd  = fp_mvst && (i.dst.upd == UPD_PRE);
wire        fp_lsb   = fp_mvpd;
wire        fp_rev   = fp_mvst && (i.ext[12] == fp_mvpd);
// the next register the list selects: the highest bit set, or the lowest for
// a predecrement store (lib/AP68040 S_FPU_MVM's scan), mapped to a register
// by the mask convention
function automatic logic [2:0] mv_bit(input logic [7:0] m, input logic lsb);
	logic [2:0] b;
	logic       found;
	integer     j;
	b = 3'd0; found = 1'b0;
	for (j = 7; j >= 0; j = j - 1)
		if (!found && m[lsb ? (3'd7 - j[2:0]) : j[2:0]]) begin
			b = lsb ? (3'd7 - j[2:0]) : j[2:0];
			found = 1'b1;
		end
	return b;
endfunction
wire  [2:0] fp_mvb  = mv_bit(fp_list, fp_lsb);
wire  [2:0] fp_mvr  = (!fp_mvst || i.ext[12]) ? (3'd7 - fp_mvb) : fp_mvb;
assign fp_fm_sel   = fp_mw ? fp_mwsel : fp_fsel;
assign fp_frst     = fp_rstp;
assign fp_fridle   = fp_idlp;
// FSAVE writes ONE longword: the IDLE frame when the unit has been used, the
// NULL frame when it has not (lib/AP68040 S_FSAVE1's `fpu_used ? ... : ...`).
wire [31:0] fp_svw = fp_used ? 32'h4100_0000 : 32'h0000_0000;
assign fp_fsave_ack = fp_svack;
assign fp_fr_unimp  = fp_frup;
assign fp_fr_cmd1   = fr_cmd1;
assign fp_fr_cmd3   = fr_cmd3;
assign fp_fr_stag   = fr_stag;
assign fp_fr_dtag   = fr_dtag;
assign fp_fr_flags  = fr_flags;
assign fp_fr_grs    = fr_grs;
assign fp_fr_wbte15 = fr_wbte15;
assign fp_fr_fpt    = fr_fpt;
assign fp_fr_et     = fr_et;
assign fp_fr_busy   = fr_busy;
assign fp_fr_wbt    = fr_wbt;
assign fp_fr_fpiar  = fr_fpiar;
assign fp_fr_cusavepc = fr_cusave;
assign fp_fr_et15   = fr_et15;
assign fp_fr_fpt15  = fr_fpt15;
// the thirteen longwords of the $4130 frame, laid out as lib/AP68040's
// fsave_unimp_word does -- the same order the FPSP reads them in
function automatic logic [31:0] fp_frame_w(input logic [3:0] n);
	case (n)
		4'd0:  return 32'h4130_0000;
		4'd1:  return {fp_st_cmd3, 16'd0};
		4'd2:  return 32'd0;
		4'd3:  return {fp_st_stag, 3'd0, fp_st_grs, 23'd0};
		4'd4:  return {fp_st_cmd1, 16'd0};
		4'd5:  return {fp_st_dtag, 8'd0, fp_st_wbte15, 20'd0};
		4'd6:  return {5'd0, fp_st_flags[2], fp_st_flags[1], 4'd0, fp_st_flags[0], 20'd0};
		4'd7:  return fp_st_fpt[95:64];
		4'd8:  return fp_st_fpt[63:32];
		4'd9:  return fp_st_fpt[31:0];
		4'd10: return fp_st_et[95:64];
		4'd11: return fp_st_et[63:32];
		default: return fp_st_et[31:0];
	endcase
endfunction
// (M10 remainder) the 25 longwords of the $4160 BUSY frame, laid out as
// lib/AP68040's fsave_busy_word does (WinUAE's 68040 fpuop_save order, and the
// offsets Motorola's fpsp.h counts from the top of the frame: WBTEMP LV-76,
// FPIARCU LV-60, CMDREG3B LV-48, STAG LV-40, CMDREG1B LV-36, DTAG LV-32,
// E_BYTE LV-28, FPTEMP LV-24, ETEMP LV-12).  The last twelve longwords are the
// $4130 frame's; CU_SAVEPC (word 2) and the reserved words are zero.
function automatic logic [31:0] fp_busy_w(input logic [4:0] n);
	case (n)
		5'd0:  return 32'h4160_0000;
		5'd6:  return {fp_st_wbt[95:80], 16'd0};
		5'd7:  return fp_st_wbt[63:32];
		5'd8:  return fp_st_wbt[31:0];
		5'd10: return fp_st_fpiar;
		5'd13: return {fp_st_cmd3, 16'd0};
		5'd15: return {fp_st_stag, 3'd0, fp_st_grs, 23'd0};
		5'd16: return {fp_st_cmd1, 16'd0};
		5'd17: return {fp_st_dtag, 8'd0, fp_st_wbte15, 20'd0};
		5'd18: return {5'd0, fp_st_flags[2], fp_st_flags[1], 4'd0, fp_st_flags[0], 20'd0};
		5'd19: return fp_st_fpt[95:64];
		5'd20: return fp_st_fpt[63:32];
		5'd21: return fp_st_fpt[31:0];
		5'd22: return fp_st_et[95:64];
		5'd23: return fp_st_et[63:32];
		5'd24: return fp_st_et[31:0];
		default: return 32'd0;
	endcase
endfunction
wire  [4:0] fp_flast = fp_bsy ? 5'd24 : 5'd12;   // the frame's last beat
// a frame beat's address, and the value An takes when the instruction ends:
// FSAVE's base was already walked back by 48 at entry, FRESTORE's An steps by
// the whole 52 bytes
wire [31:0] fp_fadr = fp_addr + {25'd0, fp_fn, 2'b00};
// the effective address as EA-calc gave it, before any frame or list walk
wire [31:0] fp_addr0 = fp_mem_dst ? d_addr_c : s_addr_c;
// (timing) fp_anv is only used in P_FPU, after the entry clock, and the
// dynamic list's register cannot change in between: an FP instruction
// serialises (nothing older is in EX or WB at entry, so op_c is the register
// file's value), and FMOVEM writes no data register.  So the count latched at
// entry (fp_mvb12_q) is the same value op_c would give, and EX's forwarded
// result no longer reaches the An update through the popcount.
wire [31:0] fp_anv  = fp_mvdy ? ((i.dst.upd == UPD_PRE) || (i.src.upd == UPD_PRE)
                                ? fp_addr0 - {25'd0, fp_mvb12_q} + 32'd12
                                : fp_addr0 + {25'd0, fp_mvb12_q}) :
                      fp_sv   ? fp_addr : (fp_addr + (fp_bsy ? 32'd100 : 32'd52));
assign fp_fm_we    = fp_mw;
assign fp_fm_wdata = fp_mwd;
// the longword of the selected register this beat carries, reversed when the
// conventions disagree
wire [31:0] fp_mvwv = ((fp_rev ? (2'd2 - fp_k) : fp_k) == 2'd0) ? fp_fm_rdata[95:64] :
                      ((fp_rev ? (2'd2 - fp_k) : fp_k) == 2'd1) ? fp_fm_rdata[63:32]
                                                                : fp_fm_rdata[31:0];
wire        fp_mem_src = (fp_gen && (i.ext[15:13] == 3'b010) && (i.src.kind == EK_MEM)) ||
                         (fp_cr && !i.ext[13] && (i.src.kind == EK_MEM)) ||
                         (fp_mvm && !i.ext[13]) || fp_rs;
wire        fp_mem_dst = (fp_gen && (i.ext[15:13] == 3'b011) && (i.dst.kind == EK_MEM)) ||
                         (fp_cr_st && (i.dst.kind == EK_MEM)) || fp_mvst || fp_sv ||
                         (fp_scc && (i.dst.kind == EK_MEM));
assign fp_din      = fp_mem_src             ? fp_buf :
                     (i.src.kind == EK_IMM) ? i.fpimm :
                     (i.size == SZ_B) ? {op_a[7:0],  88'd0} :
                     (i.size == SZ_W) ? {op_a[15:0], 80'd0} : {op_a[31:0], 64'd0};
// ... and the result, taken from the left of the dout window by size
// (a control-register store into Dn or An reads the unit combinationally)
wire [31:0] fp_rv  = fp_cr             ? fp_cr_rdata :
                     (i.size == SZ_B) ? {24'd0, fp_buf[95:88]} :
                     (i.size == SZ_W) ? {16'd0, fp_buf[95:80]} : fp_buf[95:64];
// the operand's length in bytes, and the beats it takes on the bus
wire  [4:0] fp_nb    = i.imm[4:0];
wire  [1:0] fp_beats = (fp_nb <= 5'd4) ? 2'd1 : (fp_nb == 5'd8) ? 2'd2 : 2'd3;
wire  [1:0] fp_bsz   = fp_scc ? SZ_B :
                       (fp_mvm || fp_sv || fp_rs) ? SZ_L : (fp_nb == 5'd1) ? SZ_B : (fp_nb == 5'd2) ? SZ_W : SZ_L;
wire [31:0] fp_baddr = fp_scc ? fp_addr :
                       fp_frm ? fp_fadr :
                       (fp_mvm || fp_sv || fp_rs) ? fp_addr :
                       (fp_nb <= 5'd2) ? fp_addr : (fp_addr + {28'd0, fp_k, 2'b00});
wire [31:0] fp_bdata = fp_scc          ? fp_sccv :
                       (fp_sv && fp_frm) ? (fp_bsy ? fp_busy_w(fp_fn) : fp_frame_w(fp_fn[3:0])) :
                       fp_sv           ? fp_svw :
                       fp_mvm          ? fp_mvwv :
                       fp_cr           ? fp_cr_rdata :
                       (fp_nb == 5'd1) ? {24'd0, fp_buf[95:88]} :
                       (fp_nb == 5'd2) ? {16'd0, fp_buf[95:80]} :
                       (fp_k == 2'd0)  ? fp_buf[95:64] :
                       (fp_k == 2'd1)  ? fp_buf[63:32] : fp_buf[31:0];
wire        fp_blast = (fp_k == fp_beats - 2'd1);
// opclass 011 stores the FPU's answer, so it waits for `done`; everything
// else leaves the unit running and is released at `accepted`
wire        fp_need_res = fp_gen && (i.ext[15:13] == 3'b011);
// (M10.2) a control-register move sends the unit no command, so what stands
// in for the interlock is `every selected register has been transferred`
wire        fp_ok  = fp_cnd ? fp_crd :
                     (fp_cr || fp_mvm || fp_sv || fp_rs) ? fp_crd
                                       : (fp_live && (fp_dn || (fp_acc && !fp_need_res)));
function automatic ex_t fpu_uop(input ex_t x0, input logic [31:0] rv);
	ex_t y;
	y = x0; y.c = rv;
	return y;
endfunction
// (M10.8) the conditional forms' micro-op: FBcc redirects when it is taken,
// FDBcc writes the counter and redirects when it did not expire, FScc writes
// the byte, FTRAPcc's exception comes out of fp_st instead.
// EVERY value this reads is an ARGUMENT, and that is not style: a function
// called from a continuous assignment is not reliably re-evaluated when a
// signal it reads from the enclosing scope changes (Icarus does not put such
// signals in the assignment's sensitivity list).  The symptom was an FBcc
// whose target was right and whose `redirect` was stale -- the first one
// after an FCMP took the branch only if the condition had already been true.
// Every other micro-op builder in this file takes its values the same way.
function automatic ex_t fp_cnd_uop(input ex_t x0, input logic bcc, input logic dbcc,
                                   input logic scc, input logic ctk,
                                   input logic [31:0] tgt_b, input logic [31:0] tgt_d,
                                   input logic [4:0] dreg, input logic [31:0] dval,
                                   input logic dbend, input logic [31:0] sccv);
	ex_t y;
	y = x0;
	y.st_v = 1'b0;
	if (bcc) begin
		y.cls = CL_NOP; y.dk = DK_NONE; y.dr = R_NONE;
		y.redirect = ctk;
		y.target   = tgt_b;
	end else if (dbcc) begin
		// NOT CL_NOP: EX writes a register only from a class that has a
		// writeback arm, and CL_NOP has none -- which is why FBcc above can
		// use it (it only redirects) and this one cannot.
		y.dk = DK_NONE; y.dr = R_NONE;
		if (!ctk) begin
			y.dk = DK_REG; y.dr = dreg; y.c = dval;
			y.redirect = !dbend;
			y.target   = tgt_d;
		end
	end else if (scc) begin
		y.c = sccv;
	end
	return y;
endfunction
wire ex_t fp_x = fp_cnd ? fp_cnd_uop(x_ord, fp_bcc, fp_dbcc, fp_scc, fp_ctk,
                                     i.pc + 32'd2 + i.imm, i.pc + 32'd4 + i.imm,
                                     {1'b0, i.opcode[2:0]}, {op_a[31:16], fp_dbn},
                                     fp_dbn == 16'hFFFF, fp_sccv)
                        : fpu_uop(x_ord, fp_rv);
// the (An)+ / -(An) update ALONE.  It is dispatched in front of an unimp or
// unsupp exception, because the update STANDS on both (lib/AP68040
// ap040_core.v:4593-4625), and as the trailing micro-op of a memory store, so
// that an access error on any beat leaves An as it was and the restart
// recalculates the same effective address.
function automatic ex_t fp_upd_uop(input ex_t x0, input logic last);
	ex_t y;
	y = x0;
	y.dk = DK_NONE; y.dr = R_NONE; y.st_v = 1'b0; y.redirect = 1'b0;
	y.wr_ccr = 1'b0; y.cls = CL_NOP; y.last = last;
	return y;
endfunction
// (M10.7) AN EXPLICIT ADDRESS-REGISTER UPDATE VALUE FROM EA-FETCH.  Worth
// reading even if you are not here for FSAVE: every `(An)+` / `-(An)` step in
// this core is computed by EA-calc from a byte count the DECODER knew -- the
// operand's size (M10.1), four per control register (M10.2), twelve per
// floating-point register (M10.4) -- and that works because the length of all
// of those is a property of the encoding.  A state FRAME is the first thing
// whose length is not: it depends on what the unit is holding when the
// instruction runs, so decode cannot size it and EA-calc cannot step by it.
// This is the way out, and it is the general one: the micro-op already
// carries u0_v/u0_r/u0_val (source update) and u1_v/u1_r/u1_val (destination
// update) for address-register writes, so EA-fetch overrides the VALUE and
// leaves the register selection where it was.  Anything else with a
// run-time-sized step -- the $4160 BUSY frame, a future MOVEM variant -- uses
// the same hook rather than inventing another.
function automatic ex_t an_ov(input ex_t x0, input logic ov, input logic [31:0] v);
	ex_t y;
	y = x0;
	if (ov) begin
		if (y.u0_v) y.u0_val = v;
		if (y.u1_v) y.u1_val = v;
	end
	return y;
endfunction
// one beat of a memory store, or the trailing update micro-op
function automatic ex_t fp_st_uop(input ex_t x0, input logic beat, input logic [31:0] a,
                                  input logic [31:0] d, input logic [1:0] sz);
	ex_t y;
	y = fp_upd_uop(x0, !beat);
	if (beat) begin
		y.u0_v = 1'b0; y.u1_v = 1'b0;      // they ride the trailing micro-op
		y.st_v = 1'b1; y.st_addr = a; y.st_data = d; y.st_size = sz;
	end
	return y;
endfunction
wire ex_t fp_w = (fp_stt == FS_WR) ? an_ov(fp_st_uop(x_ord,
                                              (fp_mvm || fp_sv || fp_scc) ? !(fp_crd && fp_k == 2'd3)
                                                                            : (fp_k != fp_beats),
                                              fp_baddr, fp_bdata, fp_bsz),
                                          fp_frm || fp_mvdy, fp_anv)
                                   : an_ov(fp_x, fp_frm || fp_mvdy, fp_anv);
// The unimplemented-instruction and unsupported-data-type faults, with the
// frames lib/AP68040's go_fp_unimp / go_fp_unsupp use -- both validated on
// the v24 cputest corpus (PLAN.md D19):
//   unimp  vector 11, format $2, the NEXT instruction's PC, and the operand
//          EA, or the faulting instruction's own PC when it has none;
//   unsupp vector 55, format $3, the next PC, and the EA or zero.
function automatic stp_t fp_st(input stp_t t0, input logic inph, input logic stall,
                               input logic live, input logic unimp, input logic unsupp,
                               input logic [31:0] npc, input logic [31:0] ea_u, input logic [31:0] ea_s,
                               input logic rd_go, input logic [31:0] ra, input logic [1:0] rsz,
                               input logic wr_go, input logic wr_fin,
                               input logic got, input logic mem_dst,
                               input logic pend, input logic [7:0] pvec, input logic [31:0] ipc,
                               input logic aexc, input logic [7:0] avec, input logic st_dst,
                               input logic fmte, input logic bsun, input logic trapc);
	stp_t t;
	t = t0;
	if (inph) begin
		t = '0;
		// (M10.3) an enabled arithmetic exception left over from a RELEASED
		// operation is taken in front of THIS instruction, which has not
		// started: pre-instruction, format $0, its own PC, and FPIAR still
		// names the one that faulted (lib/AP68040 ap040_core.v:3600).  It is
		// raised here, inside P_FPU, and NOT as a term in the dispatch chain:
		// that chain is the core's longest path and build m9s measured about
		// 0.9 ns for one term in it.
		if (pend) begin
			t.exc_go = 1'b1; t.ev = pvec; t.ef = 4'd0; t.epc = ipc; t.eaddr = 32'd0;
		end
		// ... and one THIS instruction raised before it could be released is
		// post-instruction: format $0 with the NEXT instruction's PC
		// (ap040_core.v:4217, whose condition is `fpu_exc_req && !fp_st`).
		// A STORE with an enabled exception is the reference's other three
		// arms -- format $3, the operand's EA, and the destination written
		// first or not depending on the class -- and is NOT built here: the
		// unit pulses `done` on that path (`ap040_fpu.v:2156`), so the store
		// completes and the trap is dropped rather than hanging.  Recorded as
		// the remaining gap of M10.3.  No (An)+ / -(An) update rides it: the reference
		// commits one on every other arm of that state and not on this one,
		// which in this pipeline happens by itself, because the update rides a
		// dispatch micro-op that never goes out.
		else if (live && aexc && !mem_dst && !st_dst) begin
			t.exc_go = 1'b1; t.ev = avec; t.ef = 4'd0; t.epc = npc; t.eaddr = 32'd0;
		end
		// (M10.8) a signalling predicate that met an unordered result, with
		// BSUN enabled: vector 48, format $0, the instruction's own PC.  The
		// unit records BSUN in FPSR either way -- that is `fp_bsun_req`, a
		// side port, not this.
		else if (bsun) begin
			t.exc_go = 1'b1; t.ev = 8'd48; t.ef = 4'd0; t.epc = ipc; t.eaddr = 32'd0;
		end
		// ... and FTRAPcc, which is TRAPcc's frame: vector 7, format $2, the
		// NEXT instruction's PC and the faulting one's address
		else if (trapc) begin
			t.exc_go = 1'b1; t.ev = 8'd7; t.ef = 4'd2; t.epc = npc; t.eaddr = ipc;
		end
		// (M10.5) FRESTORE of a frame this core cannot restore: the format
		// error, vector 14 with format $0 and the instruction's own PC, which
		// is the reference's default arm (ap040_core.v S_FREST2)
		else if (fmte) begin
			t.exc_go = 1'b1; t.ev = 8'd14; t.ef = 4'd0; t.epc = ipc; t.eaddr = 32'd0;
		end
		else if (live && (unimp || unsupp)) begin
			// Both faults are reported AFTER the operand has been fetched, so
			// the (An)+ / -(An) update stands: it is dispatched here, in front
			// of the exception, exactly as a trapping CHK's micro-op is
			// (lib/AP68040 ap040_core.v:4593-4625 and its S_FPU_GO comment).
			if (!stall) begin
				t.disp = 1'b1; t.dsel = 3'd6;
				t.exc_go = 1'b1;
				t.ev    = unimp ? 8'd11 : 8'd55;
				t.ef    = unimp ? 4'd2  : 4'd3;
				t.epc   = npc;
				t.eaddr = unimp ? ea_u : ea_s;
			end
		end else if (rd_go) begin
			t.issue = 1'b1; t.it = T_SLD; t.ia = ra; t.isz = rsz;
		end else if (wr_go) begin
			if (!stall) begin t.disp = 1'b1; t.dsel = 3'd4; t.fin = wr_fin; end
		end else if (got && !mem_dst && !stall) begin
			t.disp = 1'b1; t.dsel = 3'd4; t.fin = 1'b1;
		end
	end
	return t;
endfunction
// the effective address the two faults report: the operand's, when it has
// one.  unimp puts the faulting instruction's own PC there instead when it
// does not (lib/AP68040 go_fp_unimp: `fp_ea_v ? t_a : pc_i`); unsupp puts
// zero (go_fp_unsupp).  fp_addr is the saved EA, which is also what a
// restart after a mid-operand access error recalculates.
wire        fp_ea_v = fp_mem_src || fp_mem_dst;

function automatic stp_t aerr_st(input stp_t t0, input logic go, input id_t i, input logic [31:0] fa);
	stp_t t;
	t = t0;
	if (go) begin
		t = '0;
		t.exc_go = 1'b1; t.ev = 8'd2; t.ef = 4'd7; t.epc = i.pc; t.eaddr = fa;
	end
	return t;
endfunction
function automatic stp_t pm_st(input stp_t t0, input logic inph, input logic got, input logic stall);
	stp_t t;
	t = t0;
	if (inph) begin
		t = '0;
		if (got && !stall) begin t.disp = 1'b1; t.dsel = 3'd4; t.fin = 1'b1; end   // (dsel 4: see dmux)
	end
	return t;
endfunction
// An interrupt above the mask is taken at an instruction boundary
// (M68040UM 8.1.4, p. 8-12): vector 24 + level, format $0, PC = the
// instruction that has not started, mask = the level.  It overrides whatever
// the dispatch chain decided for that instruction rather than sitting at the
// top of it -- the chain is the core's longest combinational path (EA-fetch's
// output to IF's fetch PC), and a term there costs ~0.9 ns of WNS.
// It is ARMED one clock ahead (irq_take, a register) and then overrides only
// the DISPATCH fields.  Two rules learned from the whole-design builds:
//   - a term at the head of stepf's chain costs ~0.9 ns (build m9s: 180 new
//     failing endpoints, worst -0.483);
//   - an override of the chain's RESULT is worse still, because the memory
//     request is computed from it and the acknowledge path (clk_114 -> clk_38,
//     8.815 ns) then carries the extra mux (build m9sb: -1.307).
// With the arm registered, the combinational chain never sees the interrupt:
// the dispatch mux selects on a flip-flop, and the read request is simply
// ANDed with it.
function automatic stp_t irq_st(input stp_t s, input logic go, input logic [2:0] lvl,
                                input logic [31:0] pc);
	stp_t t;
	begin
		t = s;
		if (go) begin
			t.disp = 1'b0; t.fin = 1'b0; t.mm_go = 1'b0;
			t.exc_go = 1'b1; t.irq = 1'b1;
			t.ev = 8'd24 + {5'd0, lvl}; t.ef = 4'd0; t.epc = pc; t.eaddr = 32'd0;
		end
		return t;
	end
endfunction
//--------------------------------------------------------------- trace (M9.T)
// T1 traces EVERY instruction (M68040UM 8.2.6, p. 8-10).  The trace is a
// POST-instruction exception: the instruction completes and the trace is
// taken in front of the NEXT one -- vector 9, format $2, the stacked PC =
// the next instruction and the format-$2 address field = the PC of the
// instruction that was traced (the reference's fetch_next does exactly this:
// `exc(VEC_TRACE, 4'd2, pc, pc_i)`).
//
// The T bits are sampled at the START of an instruction, so the MOVE to SR
// that SETS T1 is not itself traced and the one that CLEARS it is.  That
// falls out of the pipeline here rather than needing a register of its own:
// an instruction's own SR write commits at ITS writeback, which is after it
// has left EA-fetch, and `sr_in` is the write-through of that commit -- so
// `sr_in` while the instruction is still here IS its starting SR, and arming
// at `st.fin` reads exactly the value the rule asks for.  Nothing else can
// move it underneath: every SR writer redirects, so no younger instruction
// is in flight beside it.
//
// It is delivered the way M9's interrupt is -- a REGISTER that overrides the
// dispatch, never a term in stepf's chain, which is the core's longest
// combinational path and where build m9s measured ~0.9 ns for one term.
// `hold` is the registered "a trace is due" and it stops the NEXT instruction
// at the boundary, which a trace -- unlike an interrupt -- REQUIRES: an
// interrupt may be taken at any later boundary, so M9 lets the instruction go
// and takes it in front of the following one, but a trace belongs to exactly
// one boundary.  Without the hold the arm is simply overwritten by the next
// instruction's, and four traced instructions produce one trace.  It is an AND
// with a flip-flop, the shape m9s's fix settled on, not a term in the chain.
function automatic stp_t tr_st(input stp_t s, input logic [3:0] ph, input logic hold,
                               input logic go,
                               input logic [31:0] npc, input logic [31:0] tpc);
	stp_t t;
	begin
		t = s;
		if (hold && ph == P_START) begin
			t.disp = 1'b0; t.fin = 1'b0; t.mm_go = 1'b0; t.issue = 1'b0;
		end
		if (go) begin
			t.disp = 1'b0; t.fin = 1'b0; t.mm_go = 1'b0;
			t.exc_go = 1'b1; t.irq = 1'b0;
			t.ev = 8'd9; t.ef = 4'd2; t.epc = npc; t.eaddr = tpc;
		end
		return t;
	end
endfunction
reg         tr_take;      // a trace is due in front of the next instruction
reg  [31:0] tr_pc;        // the traced instruction's PC (the $2 address field)
// A T0 change-of-flow trace is resolved only once the TARGET has entered the
// pipeline, so an illegal instruction at the target wins and cancels it
// (reference go_pc: `flow_t0_pend`).  A T1 trace is not: it is taken at the
// boundary before the target is looked at.
reg         tr_yield;
// `!older_busy` is the interrupt's rule for the same reason: the traced
// instruction's writeback must have committed before the frame's SR is
// latched.  An interrupt at the same boundary WINS (irq_st sits outside this
// one); what the 68040 then does with the displaced trace -- deliver it at
// the interrupt handler's first instruction -- is the next step of M9.T.
// irq_hold is the REGISTERED "a request is pending and may be taken in front
// of whatever is at the boundary": while it is set no instruction is
// dispatched at P_START and no read is issued, so the entry cannot race the
// instruction it is taken in front of.  Everything it is made of is a
// register or a cheap term, and it reaches the dispatch as a mux select, not
// as a term inside stepf.
reg        irq_take;
reg  [2:0] irq_take_lvl;
wire [31:0] irq_take_pc = (ph == P_STOP) ? i.next_pc : i.pc;
wire irq_go = irq_take && eac_v_use && !rst_pending && !older_busy &&
              ((ph == P_START) || (ph == P_STOP));
wire stp_t st_i = aerr_st(irq_st(fp_st(pm_st(st1, ph == P_PMMU || ph == P_CINV, pm_got, stall_in),
                                     (HAS_FPU != 0) && (ph == P_FPU), stall_in, fp_live, fp_unimp, fp_unsupp,
                                     i.next_pc, fp_ea_v ? fp_addr : i.pc, fp_ea_v ? fp_addr : 32'd0,
                                     (fp_stt == FS_RD) && !rd_pend && !((fp_cr || fp_mvm || fp_rs) && fp_crd) && !fp_mw,
                                     fp_baddr, fp_bsz,
                                     (fp_stt == FS_WR),
                                     (fp_mvm || fp_sv || fp_scc) ? (fp_crd && fp_k == 2'd3) : (fp_k == fp_beats),
                                     fp_ok, fp_mem_dst,
                                     (HAS_FPU != 0) && fp_pend && !fp_pex, fp_pvec, i.pc,
                                     (HAS_FPU != 0) && fp_ae, fp_avec, fp_need_res,
                                     (HAS_FPU != 0) && fp_fmte,
                                     (HAS_FPU != 0) && fp_bsun_go && (ph == P_FPU) && !fp_crd,
                                     (HAS_FPU != 0) && fp_trapcc && fp_ctk && !fp_bsun_go),
                               irq_go, irq_take_lvl, irq_take_pc), aerr_go, i, rd_a_q);
// (M9.T step 4) A TRACE AND AN INTERRUPT PENDING AT THE SAME BOUNDARY: the
// trace goes FIRST.  M68040UM 8.3, Table 8-4 puts Trace in priority group 6
// and Interrupt in group 8, "with 0 as the highest priority", and 8.3 then
// says what happens to the loser: "As soon as the M68040 has completed
// exception processing for a condition when an interrupt exception is
// pending, it begins exception processing for the interrupt exception instead
// of executing the exception handler for the original exception condition."
// So the trace frame is built, and the still-pending interrupt is taken in
// FRONT OF THE TRACE HANDLER's first instruction -- which this core already
// does for any exception (t_exceptions tests 93-105).  The interrupt handler
// returns to the trace handler, which returns to the traced program.
//
// This is a deliberate divergence from lib/AP68040, which takes the interrupt
// first and delivers the displaced trace at the interrupt handler's entry
// (its `texc` machinery), and from WinUAE, which takes the interrupt and DROPS
// the trace.  The reference's own comment calls its behaviour OPEN.  PLAN D23
// has the three readings side by side; the manual is authority rule 1.
wire tr_go = tr_take && eac_v_use && !rst_pending && !older_busy &&
             (ph == P_START) && !(tr_yield && st_i.exc_go && !irq_go);

// the trace is applied OUTSIDE the interrupt override, so it wins a boundary
// they both want (M68040UM 8.3: trace is priority group 6, interrupt 8).  The
// interrupt is not acknowledged here -- `tr_st` clears the `irq` flag -- so
// the request simply stays pending and is taken in front of the trace
// handler's first instruction.
wire stp_t st = tr_st(st_i, ph, tr_take, tr_go, i.pc, tr_pc);

//--------------------------------------------------------------- PFLUSH / PTEST
// M68040UM 3.7 (MMU instructions): privileged; they wait for everything
// older (serialize), then for the memory port to be idle -- the reference
// waits for the queue fetch to retire, the MMU has one port -- with IF held
// off; the request is a level until done; PTEST's MMUSR is written by the
// final micro-op, and both refetch the next instruction so nothing younger
// was translated under the old map (the reference's epf_flush).
reg        x_irq;          // the exception in progress is an interrupt ...
reg  [2:0] x_lvl;          // ... of this level (the new mask)
reg  [9:0] rs_cnt;         // RESET: RSTO clocks left
assign stopped = (ph == P_STOP);
assign rsto    = (ph == P_RSTO);
reg        pm_sent;        // the request went out
reg        pm_got;         // ... and was answered
reg [31:0] pm_mmusr;
// IF holds off while a PTEST/PFLUSH owns the MMU, and while a CINV is in
// flight: the final micro-op then refetches, so the prefetch buffer cannot
// serve a word fetched before the invalidate (M68040UM 4.5: CINV I must
// reach code the pipeline has already read; the reference's epf_flush)
assign pmmu_busy = (ph == P_PMMU) || (ph == P_CINV);
function automatic ex_t pmmu_uop(input id_t i, input logic [31:0] mmusr);
	ex_t x;
	x = base_uop(i);
	x.dk = DK_NONE;
	if (i.imm[3]) begin
		x.cls = CL_MOVEC; x.creg_to = 1'b1; x.creg_sel = CR_MMUSR; x.a = mmusr;
	end else x.cls = CL_NOP;
	x.redirect = 1'b1; x.target = i.next_pc;
	return x;
endfunction
wire ex_t pm_x = pmmu_uop(i, pm_mmusr);


// RTR to an odd PC: the CCR alone commits
function automatic ex_t ccr_only_uop(input ex_t x);
	ex_t y;
	y = x; y.u0_v = 1'b0; y.u1_v = 1'b0; y.redirect = 1'b0; y.last = 1'b0;
	return y;
endfunction

// a trapping CHK/CHK2/DIV: the micro-op commits, the exception follows
function automatic ex_t no_last(input ex_t x);
	ex_t y;
	y = x; y.redirect = 1'b0; y.last = 1'b0;
	return y;
endfunction

function automatic ex_t dmux(input logic [2:0] sel, input ex_t o, input ex_t f, input ex_t e,
                             input ex_t r, input ex_t z, input ex_t c, input ex_t n, input ex_t m);
	case (sel)
		3'd7: return m;
		3'd0: return o;
		3'd1: return f;
		3'd2: return e;
		3'd3: return r;
		3'd5: return c;
		3'd6: return n;
		default: return z;
	endcase
endfunction

wire ex_t disp_x0 = dmux(st.dsel, x_ord,
                        exc_uop(i, x_k, x_sp, x_sr, x_pc, x_fmt, x_vec, x_addr, x7[(x_k < 4'd2) ? 4'd2 : x_k]),
                        exc_final(i, x_bank, x_sp, x_sr, x_target, x_irq, x_lvl, x_pass2, x_sp1),
                        rte_final(i, bank_now, rd_a, r_fv, r_sr, r_pc),
                        ((HAS_FPU != 0) && (ph == P_FPU)) ? fp_w :
                        (ph == P_PMMU || ph == P_CINV) ? pm_x : reset_final(i, x_sp, r_pc),
                        ccr_only_uop(x_ord),
                        ((HAS_FPU != 0) && (ph == P_FPU)) ? fp_upd_uop(x_ord, 1'b0) : no_last(x_ord),
                        mm_x);
// every store's function code: the frame stores and ordinary stores are
// data in the current mode (the frame: supervisor), MOVES: DFC
function automatic ex_t with_fc(input ex_t x, input logic [2:0] fc, input id_t i, input logic exc,
                                input logic m16, input logic lk, input logic cm, input logic cmt);
	ex_t y;
	y = x; y.st_fc = fc;
	y.stf.npc = (i.cls == CL_JSR) ? x.target : (i.cls == CL_BSR) ? i.btarget : i.next_pc;
	y.stf.ipc = i.pc;
	y.stf.exc = exc;
	y.stf.m16 = m16;
	y.stf.lk  = lk;
	y.stf.moves = (i.fcsel == 2'd2);
	y.stf.cm  = cm;
	y.stf.cmt = cmt;
	return y;
endfunction
wire ex_t disp_x = with_fc(disp_x0, (st.dsel == 3'd1) ? 3'd5 : (st.dsel == 3'd0 && i.fcsel == 2'd2) ? dfc_in : fc_data,
                           i, ph == P_EXC, aer_m16, aer_lk, ph == P_MOVEM && mm_cmi, mm_tag);

// the early read goes out when this stage leaves the port free and is
// taking the next instruction (its current one finishes, or it is empty)
// function codes: supervisor/user data (5/1), MOVES: SFC for its read
// (plan M4; the lifted MMU's c_fc in M7)
wire [2:0] fc_data = s_bit ? 3'd5 : 3'd1;
// (exception entry's vector read and RTE's pops: supervisor data)
assign rd_fc     = (st.issue && (ph == P_START || ph == P_OPS) && i.fcsel == 2'd1) ? sfc_in :
                   (ph == P_EXC || ph == P_RTE || ph == P_RESET) ? 3'd5 : fc_data;
// An early read is issued only for an instruction that is known to be on
// the executed path.  The instruction finishing here may still redirect --
// a Bcc (not BRA) or DBcc ID guessed taken, corrected here when not taken; RTS/RTD/RTR;
// a memory-indirect JMP/JSR -- and then the instruction in EA-calc is on a
// wrong path and must not read: an Amiga has read-sensitive registers (a
// CIA's ICR clears on read), and a 68040 reads operands only for the
// instructions it executes.  The same holds in REDIR_REG's gap clock, when
// the held redirect is going out.  (Found by the Kickstart bench with the
// M14 read paths: exec's VHPOSR wait read $DFF006 once more after its DBRA
// fell through; t_specread_pipe.s.)  `redir_cls` is decoded from this
// stage's input register, so no term reaches the redirect chain.
wire   redir_cls = eac_v_use && ((i.cls == CL_BCC && i.cond != 4'h0) || i.cls == CL_DBCC ||
                                 i.cls == CL_RTS || i.cls == CL_RTD || i.cls == CL_RTR ||
                                 ((i.cls == CL_JMP || i.cls == CL_JSR) && !eac_i.redirected));
wire   use_early = early_v && early.v && !st.issue && (!rd_pend || rd_ack) &&
                   (st.fin || !eac_v_use) && !rst_pending &&
                   !redir_cls && !((REDIR_REG != 0) && rdz_v);
// An armed interrupt holds back only the reads it can be taken in front of:
// the instruction still at P_START (irq_go fires only there, or in P_STOP,
// which reads nothing) and the NEXT instruction's early read.  An
// instruction that has LEFT P_START -- P_OPS, P_MOVEM, P_FPU -- cannot be
// interrupted; it must finish, and it cannot finish without its reads.
// irq_take arms in whatever phase it sees a request with nothing read yet
// and no read going out, so gating every read on it wedged such an
// instruction for good: its read never went out, it never returned to
// P_START, and the interrupt was never taken.  No request, no fault, no
// exception -- the board's black screen of 2026-09-23 (a MOVEM load past
// its first clock when Enable()'s INTENA write let a pending Paula request
// through; t_irqwedge_pipe.s).  `irq_blk` is registers only: the chain
// still sees a flip-flop's worth of logic, not a term (the m9s rule).
wire   irq_blk   = irq_take && (ph == P_START);
assign rd_req    = ((st.issue && !irq_blk) || (use_early && !irq_take)) && !flush && !tr_take;   // (registered: out of stepf)
assign rd_addr   = st.issue ? st.ia  : early.a;
assign rd_size   = st.issue ? st.isz : early.sz;
wire [2:0] rd_t  = st.issue ? st.it  : early.t;
assign eaf_stall = eac_valid && !st.fin;
// (MOVEM blocks EA-calc for its whole stay: its register writes are not in eac_t)
assign eaf_blk   = eac_v_use && (i.serialize || (ph != P_START && ph != P_OPS) || i.cls == CL_MOVEM);
assign halted    = (ph == P_HALT);

// Bcc/DBcc were guessed taken by ID; a not-taken one is corrected here,
// with the CCR the instruction ahead of it (in EX, or committing in WB)
// leaves -- a two-clock correction instead of the four a redirect from EX
// costs (M68040UM 10.5 p. 10-11: Bcc not taken 3, DBcc 3/4).
// (the counter from the register file: a DBcc waits while EX writes it --
// vdep -- so the loop test is off EX's result path, timing)

wire        redir_now  = st.disp && st.dsel == 3'd0 && !flush &&
                        (i.cls == CL_RTS || i.cls == CL_RTD || i.cls == CL_RTR ||
                         ((i.cls == CL_JMP || i.cls == CL_JSR) && !eac_i.redirected) ||
                         ((i.cls == CL_BCC || i.cls == CL_DBCC) && !br_taken));
wire [31:0] redir_pc_now = (i.cls == CL_RTS || i.cls == CL_RTD) ? s_val_c :
                           (i.cls == CL_RTR) ? d_val_c :
                           (i.cls == CL_BCC || i.cls == CL_DBCC) ? i.next_pc : s_addr_c;

// REDIR_REG (plan M11.1): hold the redirect one clock.  `rdz_v` is the GAP
// clock: this stage does nothing in it (eac_v_use below is low, so stepf sees
// no instruction and eaf_stall therefore holds EA-calc), the redirect goes out
// from the register, and flush_eac kills the instruction EA-calc took in the
// meantime -- which never reaches here.  An older redirect (EX or WB) wins and
// clears the slot.
always @(posedge clk) begin
	if (!nreset) begin
		rdz_v <= 1'b0; rdz_pc <= 32'd0;
	end else if (ce) begin
		if (flush)            rdz_v <= 1'b0;
		else if (!rdz_v && redir_now) begin rdz_v <= 1'b1; rdz_pc <= redir_pc_now; end
		else                  rdz_v <= 1'b0;
	end
end

// The gap clock costs one fetch if IF is left alone: it would issue one more
// request down the OLD stream before the redirect arrives.  Architecturally
// that is fine -- a 68040 prefetches far past an RTS and the answer is
// dropped -- but it changes the core's memory footprint, and tb_ap040_pipe_
// reset's memory model catches it.  So IF is held for that one clock.  The
// acknowledge does reach IF through this, but only as one term of the fetch
// REQUEST, not as the clock enable of the whole queue.
assign eaf_redir_soon = (REDIR_REG != 0) && redir_now && !rdz_v;
assign eaf_redir_v  = (REDIR_REG != 0) ? rdz_v  : redir_now;
assign eaf_redir_pc = (REDIR_REG != 0) ? rdz_pc : redir_pc_now;

//--------------------------------------------------------------- registers
always @(posedge clk) begin
	if (!nreset) begin
		ph <= P_START; rd_pend <= 1'b0; rd_tag <= 3'd0; rd_drop <= 1'b0;
		done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
		s_addr <= 32'd0; d_addr <= 32'd0; s_val <= 32'd0; d_val <= 32'd0;
		x_vec <= 8'd0; x_fmt <= 4'd0; x_pc <= 32'd0; x_addr <= 32'd0; x_step <= 3'd0; x_k <= 4'd0;
		x_sr <= 16'd0; x_sp <= 32'd0; x_bank <= R_ISP; x_target <= 32'd0;
		x_pass2 <= 1'b0; x_sp1 <= 32'd0;
		bf_step <= 1'b0;
		pt_req <= 1'b0; pt_write <= 1'b0; pt_addr <= 32'd0; pf_req <= 1'b0; pf_mode <= 2'd0; pf_addr <= 32'd0;
		pm_sent <= 1'b0; pm_got <= 1'b0; pm_mmusr <= 32'd0;
		cinv_req <= 1'b0; cinv_ic <= 1'b0; cinv_dc <= 1'b0;
		fp_req <= 1'b0; fp_sent <= 1'b0; fp_acc <= 1'b0; fp_dn <= 1'b0; fp_buf <= 96'd0; fp_bg <= 1'b0;
		fp_stt <= FS_RD; fp_k <= 2'd0; fp_addr <= 32'd0;
		fp_cw <= 1'b0; fp_csel <= 2'd0; fp_cwd <= 32'd0; fp_crd <= 1'b0;
		fp_ae <= 1'b0; fp_avec <= 8'd0; fp_pend <= 1'b0; fp_pvec <= 8'd0;
		fp_list <= 8'd0; fp_mvb12_q <= 7'd0; fp_fsel <= 3'd0; fp_mw <= 1'b0; fp_mwd <= 96'd0; fp_mwsel <= 3'd0;
		fp_rstp <= 1'b0; fp_idlp <= 1'b0; fp_fmte <= 1'b0;
		fp_fn <= 5'd0; fp_frm <= 1'b0; fp_svack <= 1'b0; fp_frup <= 1'b0; fp_bsy <= 1'b0; fp_rarm <= 1'b0; fp_pcap <= 1'b0;
		fr_busy <= 1'b0; fr_et15 <= 1'b0; fr_fpt15 <= 1'b0; fr_wbt <= 96'd0;
		fr_fpiar <= 32'd0; fr_cusave <= 8'd0;
		fr_cmd1 <= 16'd0; fr_cmd3 <= 16'd0; fr_stag <= 3'd0; fr_dtag <= 3'd0;
		fr_flags <= 3'd0; fr_grs <= 3'd0; fr_wbte15 <= 1'b0; fr_fpt <= 96'd0; fr_et <= 96'd0;
		x_irq <= 1'b0; x_lvl <= 3'd0; rs_cnt <= 10'd0;
		irq_take <= 1'b0; irq_take_lvl <= 3'd0;
		tr_take <= 1'b0; tr_pc <= 32'd0; tr_yield <= 1'b0;
		mm_ea[0] <= 32'd0; mm_ea[1] <= 32'd0; mm_tag <= 1'b0;
		cm_v <= 1'b0; cm_ea <= 32'd0; cm_pc <= 32'd0; r_ea <= 32'd0; r_ssw <= 16'd0;
		mm_mask <= 16'd0; mm_k_q <= 4'd0; mm_addr <= 32'd0; mm_empty <= 1'b0; mm_rreg <= 5'd0; mm_rlast <= 1'b0; mm_tail <= 1'b0;
		mm_have <= 1'b0; mm_hdata <= 32'd0; mm_hreg <= 5'd0; mm_hlast <= 1'b0;
		mm_bv <= 1'b0; mm_bval <= 32'd0;
		r_step <= 3'd0; r_sr <= 16'd0; r_pc <= 32'd0; r_fv <= 16'd0;
		rst_pending <= reset_seq;
		eaf_valid <= 1'b0; eaf_o <= '0;
	end else if (ce) begin
		// the EX-side output register
		if ((flush && !keep_out) || wf_go) eaf_valid <= 1'b0;
		else if (!stall_in) begin
			eaf_valid <= st.disp;
			if (st.disp) eaf_o <= disp_x;
		end
		// read bookkeeping.  A read still outstanding when a flush arrives
		// is answered later; rd_drop throws that answer away.
		if (rd_req) begin rd_pend <= 1'b1; rd_tag <= rd_t; rd_a_q <= rd_addr; rd_sz_q <= rd_size; rd_fc_q <= rd_fc; end
		else if (rd_ack) begin rd_pend <= 1'b0; rd_drop <= 1'b0; end
		if (wf_go) begin
			// the faulted store's instruction is done or restarts; everything
			// behind it (EX's micro-op, this stage) is abandoned
			eaf_valid <= 1'b0;
			ph <= P_EXC; x_step <= 3'd5; x_vec <= 8'd2; x_fmt <= 4'd7; x_irq <= 1'b0;
			x_pc <= wf_last ? wb_stf.npc : wb_stf.ipc;
			x_addr <= wb_st_a;
			x7[2] <= wb_stf.cm ? mm_ea[wb_stf.cmt] :                              // EA (MOVEM: calculated)
			         wb_stf.m16 ? {wb_st_a[31:4], 4'd0} : wb_st_a;
			x7[3] <= {wf_ssw, 16'h0000};                                          // SSW, WB3S
			x7[4] <= {16'h0000, 8'h00, wf_last ? wbs_f(wf_ssw) : 8'h00};          // WB2S, WB1S
			x7[5] <= wb_st_a;                                                     // FA
			x7[6] <= wf_last ? 32'd0 : wb_st_a;                                   // WB3A
			x7[7] <= wf_last ? 32'd0 : wb_st_d;                                   // WB3D
			x7[8] <= 32'd0; x7[9] <= 32'd0;                                       // WB2A, WB2D
			x7[10] <= wf_last ? wb_st_a : 32'd0;                                  // WB1A
			x7[11] <= !wf_last ? 32'd0 : wb_stf.m16 ? m16_buf[0] : wb_st_d;       // WB1D / PD0
			x7[12] <= (wf_last && wb_stf.m16) ? m16_buf[1] : 32'd0;               // PD1
			x7[13] <= (wf_last && wb_stf.m16) ? m16_buf[2] : 32'd0;               // PD2
			x7[14] <= (wf_last && wb_stf.m16) ? m16_buf[3] : 32'd0;               // PD3
			bf_step <= 1'b0; mm_have <= 1'b0; mm_empty <= 1'b0; mm_tail <= 1'b0;
			done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
			if (rd_pend && !rd_ack) rd_drop <= 1'b1;
		end else if (flush) begin
			ph <= P_START; bf_step <= 1'b0; mm_have <= 1'b0; mm_empty <= 1'b0; mm_tail <= 1'b0;
			fp_req <= 1'b0;
			done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
			if (rd_pend && !rd_ack) rd_drop <= 1'b1;
		end else begin
			if (cap) begin
				case (rd_tag)
					T_SMI: begin s_addr <= rd_data + eac_i.src_add; done_smi <= 1'b1; end
					T_DMI: begin d_addr <= rd_data + eac_i.dst_add; done_dmi <= 1'b1; end
					T_SLD: begin s_val <= rd_data; done_sld <= 1'b1; end
					T_DLD: begin d_val <= rd_data; done_dld <= 1'b1; end
					T_SEQ0: begin
						if (ph == P_RESET) x_sp <= rd_data; else r_sr <= rd_data[15:0];
						r_step <= r_step + 3'd1;
					end
					T_SEQ1: begin r_pc <= rd_data; r_step <= r_step + 3'd1; end
					T_SEQ2: begin r_fv <= rd_data[15:0]; r_step <= r_step + 3'd1; end
					T_VEC:  begin x_target <= rd_data; x_step <= 3'd4; end
				endcase
			end
			case (ph)
				P_START: begin
					if (rst_pending) begin
						ph <= P_RESET; r_step <= 3'd0;
					end else if (eac_v_use && !(i.serialize && older_busy) && !irq_take && !tr_take) begin
						if (!st.exc_go && i.cls == CL_STOP) begin
							// (M9.T) a TRACED stop loads the SR and carries on:
							// it never enters the stopped state.  No guard is
							// needed on this assignment -- stepf gives the
							// traced STOP its `fin`, and `if (st.fin) ph <=
							// P_START` at the end of this block is the later
							// assignment and wins.  A mutant that added
							// `&& !tr_arm` here SURVIVED, which is how the
							// redundancy was found.
							if (st.disp) ph <= P_STOP;
						end else if (!st.exc_go && i.cls == CL_RSTO) begin
							ph <= P_RSTO; rs_cnt <= RSTO_CLKS[9:0] - 10'd1;
						end else if (!st.exc_go && i.cls == CL_CINV) begin
							ph <= P_CINV; pm_sent <= 1'b0; pm_got <= 1'b0;
						end else if (!st.exc_go && i.cls == CL_PMMU) begin
							ph <= P_PMMU; pm_sent <= 1'b0; pm_got <= 1'b0;
						end else if (!st.exc_go && HAS_FPU != 0 && i.cls == CL_FPU) begin
							// (M10.1(c)) one FP instruction at a time: a second
							// one waits here while a released operation is still
							// running, which is also what keeps FBcc/FScc from
							// reading a live `fpcc`.
							// (and not in the clock the unit prepares a deferred
							// exception's frame, or an FSAVE would judge it frameless)
							if (!fp_bg && !fp_pcap) begin
								ph <= P_FPU;
								fp_sent <= 1'b0; fp_acc <= 1'b0; fp_dn <= 1'b0; fp_k <= 2'd0;
								fp_ae <= 1'b0;
								// the saved effective address: the operand's,
								// and what a restart after a mid-operand
								// access error recalculates
								fp_addr <= fp_mem_dst ? d_addr_c : s_addr_c;
								fp_cw <= 1'b0;
								// (M10.2) a control-register move sends the unit no
								// command: it is longword transfers and nothing else,
								// and a store into Dn or An is finished before it
								// starts -- cr_rdata reads combinationally.
								fp_crd <= fp_cr_st && !fp_mem_dst;
								fp_fmte <= 1'b0; fp_frm <= 1'b0; fp_svack <= 1'b0; fp_frup <= 1'b0; fp_bsy <= 1'b0;
								fp_mw <= 1'b0;
								// (M10.4) FMOVEM walks a register list, twelve bytes
								// each: the list is consumed as it goes and the first
								// register is picked here.
								fp_list <= fp_mvmk & ~(8'd1 << mv_bit(fp_mvmk, fp_lsb));
								fp_mvb12_q <= fp_mvb12;
								fp_fsel <= (!fp_mvst || i.ext[12]) ? (3'd7 - mv_bit(fp_mvmk, fp_lsb))
								                                   : mv_bit(fp_mvmk, fp_lsb);
								// (M10.3) a PENDING exception is taken in front of this
								// instruction, so nothing of it starts: no command,
								// no operand beats, no register list
								if (fp_pend && !fp_pex) ;
								// (M10.5) FSAVE writes one longword, FRESTORE reads one
								// (M10.8) a conditional form reads `fpcc` and nothing else --
								// except FScc to memory, which writes one byte
								else if (fp_cnd) begin
									// the condition is read one clock AFTER the phase is entered,
									// never in the entry clock itself: `fp_crd` is shared with the
									// other classes and whatever the previous FP instruction left
									// in it would otherwise dispatch this one immediately, before
									// its operand read has settled.  One clock, and it is the same
									// shape as every other P_FPU arm.
									fp_crd <= 1'b0;
									if (fp_scc && (i.dst.kind == EK_MEM)) begin
										fp_stt <= FS_WR; fp_k <= 2'd0;
										fp_addr <= d_addr_c;
									end
									// ... and everything else must LEAVE the store state, or a
									// conditional that follows an FScc into memory inherits FS_WR
									// and dispatches through the store path instead of its own
									else fp_stt <= FS_REQ;
								end
								else if (fp_sv) begin
									fp_stt <= FS_WR;
									// (M10.7) the unit is holding a state: this FSAVE is the
									// thirteen-longword $4130 frame, not the one-longword
									// NULL/IDLE one, and a -(An) FSAVE must walk its base back
									// by the REST of the frame -- EA-calc only knew about four.
									// (M10 remainder) ... or the 25-longword $4160 BUSY
									// frame, whose -(An) walk is 96 more
									if (fp_st_unimp) begin
										fp_frm <= 1'b1; fp_fn <= 5'd0; fp_bsy <= fp_st_busy;
										fp_pend <= 1'b0;      // extracted, not reported
										if (i.dst.upd == UPD_PRE)
											fp_addr <= d_addr_c - (fp_st_busy ? 32'd96 : 32'd48);
									end
								end
								else if (fp_rs) fp_stt <= FS_RD;
								else if (fp_mvm) begin
									fp_stt <= fp_mvst ? FS_WR : FS_RD;
									// (M10.9) a dynamic list's step was not known to
									// EA-calc, so the base and the register update
									// are computed here
									// EA-calc stepped by ONE register (see decode), so
									// the base is short by the other n-1
									if (fp_mvdy && (i.dst.upd == UPD_PRE))
										fp_addr <= d_addr_c - {25'd0, fp_mvb12} + 32'd12;
								end
								else if (fp_cr) begin
									if (fp_mem_src)      fp_stt <= FS_RD;
									else if (fp_mem_dst) fp_stt <= FS_WR;
									else                 fp_stt <= FS_REQ;
								end
								else if (fp_mem_src) fp_stt <= FS_RD;        // beats first
								else begin fp_stt <= FS_REQ; fp_req <= 1'b1; end
							end
						end else if (!st.exc_go && i.cls == CL_RTE) begin
							ph <= P_RTE; r_step <= 3'd0;
						end else if (!st.exc_go && !st.fin) ph <= P_OPS;
					end
				end
				P_EXC: begin
					if (x_step == 3'd0 && st.disp) begin
						x_k <= x_k + 4'd1;
						if ({28'd0, x_k} == (fsize(x_fmt) >> 2) - 32'd1) begin
							// (M9.T) an INTERRUPT taken with M set stacks TWO
							// frames (M68040UM 8.2.9, 8.4.2): the normal one on
							// the MASTER stack, which has just gone out, and
							// then a four-word format $1 THROWAWAY on the
							// INTERRUPT stack.  The throwaway's SR image keeps
							// M set with only S forced, so that the RTE which
							// pops it switches back to the master stack where
							// the real frame lives.  M itself is cleared by the
							// final micro-op.
							if (x_irq && x_sr[12] && !x_pass2) begin
								x_pass2 <= 1'b1;
								x_sp1   <= x_sp;
								x_fmt   <= 4'd1;
								x_sr    <= x_sr | 16'h2000;
								x_bank  <= R_ISP;
								x_k     <= 4'd0;
								x_step  <= 3'd6;   // one clock to read the ISP
							end
							else x_step <= 3'd3;
						end
					end
					if (x_step == 3'd6) begin
						x_sp   <= rd_a - 32'd8;   // ra_a reads the ISP in pass 2
						x_step <= 3'd0;
					end
					if (x_step == 3'd4 && st.disp && x_target[0]) begin
						// odd handler address: an address error on top (reference
						// S_EXC_JMP), or a double fault for vectors 2 and 3
						if (x_vec == 8'd2 || x_vec == 8'd3) ph <= P_HALT;
						else begin
							x_vec  <= 8'd3; x_fmt <= 4'd2;
							x_pc   <= {22'd0, x_vec, 2'b00};
							x_addr <= {x_target[31:1], 1'b0};
							x_step <= 3'd5;           // wait for the commit, then restart
						end
					end
					if (x_step == 3'd4 && st.disp && !x_target[0]) x_pass2 <= 1'b0;
					if (x_step == 3'd5 && !older_busy) begin
						x_pass2 <= 1'b0;
						x_sr   <= sr_in;
						x_bank <= bank_now;
						x_sp   <= rd_a - fsize(x_fmt);  // ra_a = bank_now in P_EXC
						x_step <= 3'd0; x_k <= 4'd0;
					end
				end
				P_RTE: begin
					// (format $7: its EA and SSW, T_DMI / T_SMI in this phase)
					if (cap && rd_tag == T_DMI) begin r_ea <= rd_data; r_step <= r_step + 3'd1; end
					if (cap && rd_tag == T_SMI) begin r_ssw <= rd_data[15:0]; r_step <= r_step + 3'd1; end
					if (st.disp) begin
						cm_v  <= (r_fv[15:12] == 4'd7) && r_ssw[12];
						cm_ea <= r_ea; cm_pc <= r_pc;
					end
					if (r_step == ((r_fv[15:12] == 4'd7) ? 3'd5 : 3'd3) && st.disp && !rte_goes) begin
						if (r_fv[15:12] == 4'd1) begin
							ph <= P_START;              // $1: process the next frame after the commit
						end else begin
							// odd PC after the RTE committed SR and SP: address error with the
							// restored SR (reference S_RTE_FIN2), PC = the RTE
							ph <= P_EXC; x_step <= 3'd5;
							x_vec <= 8'd3; x_fmt <= 4'd2; x_pc <= i.pc; x_addr <= {r_pc[31:1], 1'b0}; x_irq <= 1'b0;
						end
					end
				end
				P_RSTO: if (rs_cnt != 10'd0) rs_cnt <= rs_cnt - 10'd1;
				P_CINV: begin
					// the request is a level until the cache answers; it goes
					// out once the memory port is idle, so no transfer is in
					// flight while lines are dropped
					if (!pm_sent && bus_idle) begin
						pm_sent <= 1'b1;
						cinv_req <= 1'b1; cinv_ic <= i.imm[1]; cinv_dc <= i.imm[0];
					end
					if (cinv_req && cinv_done) begin
						cinv_req <= 1'b0; pm_got <= 1'b1;
					end
				end
				P_FPU: if (HAS_FPU != 0) begin
					// the request is a one-clock pulse; fp_sent goes up the
					// clock after it, so a `done` or `unimp` still standing
					// from the previous operation is never read as this one's
					fp_req <= 1'b0;
					if (fp_req) fp_sent <= 1'b1;
					if (fp_live) begin
						if (fp_accepted) fp_acc <= 1'b1;
						if (fp_done) begin fp_dn <= 1'b1; fp_buf <= fp_dout; end
						// (M10.3) latched like the other two, because the unit can
						// raise it in the same clock as `accepted` and it must win
						// over the release that clock would otherwise cause
						if (fp_exc_req) begin fp_ae <= 1'b1; fp_avec <= fp_exc_vec; end
					end
					if (fp_pend && st.exc_go) fp_pend <= 1'b0;
					// the memory operand, LEFT aligned: one byte, one word, or
					// one, two or three longwords
					if (!fp_cr && !fp_mvm && !fp_sv && !fp_rs &&
					    fp_stt == FS_RD && cap && rd_tag == T_SLD) begin
						case (fp_nb)
							5'd1: fp_buf[95:88] <= rd_data[7:0];
							5'd2: fp_buf[95:80] <= rd_data[15:0];
							default: case (fp_k)
								2'd0:    fp_buf[95:64] <= rd_data;
								2'd1:    fp_buf[63:32] <= rd_data;
								default: fp_buf[31:0]  <= rd_data;
							endcase
						endcase
						if (fp_blast) begin fp_stt <= FS_REQ; fp_req <= 1'b1; fp_k <= 2'd0; end
						else          fp_k <= fp_k + 2'd1;
					end
						// (M10.2) a control-register move has no operand window:
						// each longword goes straight to its register.  The write
						// is armed here and goes out the next clock with the
						// register it was armed for, so the beat index may move on
						// the same edge.
						fp_cw <= 1'b0;
						// (M10.5) FSAVE: one store beat, then the trailing update
						// micro-op; FRESTORE: one read, then the frame decides.
						fp_rstp <= 1'b0; fp_idlp <= 1'b0; fp_svack <= 1'b0; fp_frup <= 1'b0;
						// (M10.7) the $4130 frame: thirteen longwords out, or twelve more
						// in after the header said $41300000.
						// (M10.8) the conditional forms: one settled clock, then the
						// micro-op that branches, writes the byte or counts down
						if (fp_cnd && !fp_crd && !(fp_scc && fp_mem_dst)) fp_crd <= 1'b1;
						if (fp_scc && fp_stt == FS_WR && st.disp && !fp_crd) begin
							fp_crd <= 1'b1; fp_k <= 2'd3;
						end
						if (fp_sv && fp_frm && fp_stt == FS_WR && st.disp && !fp_crd) begin
							if (fp_fn == fp_flast) begin
								fp_crd <= 1'b1; fp_k <= 2'd3;
								// the unit keeps the state until the whole frame is out
								fp_svack <= 1'b1;
							end
							else fp_fn <= fp_fn + 5'd1;
						end
						else if (fp_sv && fp_stt == FS_WR && st.disp && !fp_crd) begin
							fp_crd <= 1'b1; fp_k <= 2'd3;
						end
						if (fp_rs && fp_frm && fp_bsy && fp_stt == FS_RD && cap && rd_tag == T_SLD && !fp_crd) begin
							// (M10 remainder) the BUSY payload, in lib/AP68040
							// S_FREST_B's order, plus what a resume needs:
							// CU_SAVEPC and the ETE15/FPTE15 exponent flags
							// (upstream apolkosnik/AP68040 880b81c)
							case (fp_fn)
								5'd2:  fr_cusave <= rd_data[31:24];
								5'd6:  fr_wbt[95:64] <= rd_data;
								5'd7:  fr_wbt[63:32] <= rd_data;
								5'd8:  fr_wbt[31:0]  <= rd_data;
								5'd10: fr_fpiar <= rd_data;
								5'd13: fr_cmd3 <= rd_data[31:16];
								5'd15: begin fr_stag <= rd_data[31:29]; fr_et15 <= rd_data[28]; fr_grs <= rd_data[25:23]; end
								5'd16: fr_cmd1 <= rd_data[31:16];
								5'd17: begin fr_dtag <= rd_data[31:29]; fr_fpt15 <= rd_data[28]; fr_wbte15 <= rd_data[20]; end
								5'd18: fr_flags <= {rd_data[26], rd_data[25], rd_data[20]};
								5'd19: fr_fpt[95:64] <= rd_data;
								5'd20: fr_fpt[63:32] <= rd_data;
								5'd21: fr_fpt[31:0]  <= rd_data;
								5'd22: fr_et[95:64] <= rd_data;
								5'd23: fr_et[63:32] <= rd_data;
								5'd24: fr_et[31:0]  <= rd_data;
								default: ;
							endcase
							if (fp_fn == 5'd24) begin fp_crd <= 1'b1; fp_frup <= 1'b1; fp_rarm <= 1'b1; end
							else fp_fn <= fp_fn + 5'd1;
						end
						else if (fp_rs && fp_frm && fp_stt == FS_RD && cap && rd_tag == T_SLD && !fp_crd) begin
							// the payload, in lib/AP68040 S_FREST_U's order
							case (fp_fn[3:0])
								4'd1:  fr_cmd3 <= rd_data[31:16];
								4'd3:  begin fr_stag <= rd_data[31:29]; fr_grs <= rd_data[25:23]; end
								4'd4:  fr_cmd1 <= rd_data[31:16];
								4'd5:  begin fr_dtag <= rd_data[31:29]; fr_wbte15 <= rd_data[20]; end
								4'd6:  fr_flags <= {rd_data[26], rd_data[25], rd_data[20]};
								4'd7:  fr_fpt[95:64] <= rd_data;
								4'd8:  fr_fpt[63:32] <= rd_data;
								4'd9:  fr_fpt[31:0]  <= rd_data;
								4'd10: fr_et[95:64] <= rd_data;
								4'd11: fr_et[63:32] <= rd_data;
								4'd12: fr_et[31:0]  <= rd_data;
								default: ;                       // 2: the reserved longword
							endcase
							if (fp_fn == 5'd12) begin fp_crd <= 1'b1; fp_frup <= 1'b1; fp_rarm <= 1'b1; end
							else fp_fn <= fp_fn + 5'd1;
						end
						else if (fp_rs && fp_stt == FS_RD && cap && rd_tag == T_SLD && !fp_crd) begin
							fp_crd <= 1'b1;
							// version byte 0 is the NULL frame, $41000000 the IDLE
							// frame; anything this core cannot install takes the
							// format error rather than being accepted.
							if (rd_data[31:24] == 8'd0)          begin fp_rstp <= 1'b1; fp_pend <= 1'b0; end
							else if (rd_data == 32'h4100_0000)   begin fp_idlp <= 1'b1; fp_pend <= 1'b0; end
							else if (rd_data == 32'h4130_0000 || rd_data == 32'h4160_0000) begin
								// (M10.7) the unimplemented-state frame: twelve more
								// longwords follow, and the instruction is not finished;
								// (M10 remainder) the BUSY frame: twenty-four more
								fp_crd <= 1'b0; fp_frm <= 1'b1; fp_fn <= 5'd1;
								fp_bsy <= rd_data[22];      // size $60, not $30
								fr_busy <= rd_data[22];
								if (!rd_data[22]) begin
									// a $4130 frame carries none of these
									fr_cusave <= 8'd0; fr_et15 <= 1'b0; fr_fpt15 <= 1'b0;
									fr_wbt <= 96'd0; fr_fpiar <= 32'd0;
								end
							end
							else                                 fp_fmte <= 1'b1;
						end
						// (M10.4) FMOVEM: three longwords per register, the list
						// consumed as it goes.  A load assembles the register in
						// fp_buf and writes it to the unit's raw port; a store
						// reads that port and emits one beat per longword.
						fp_mw <= 1'b0;
						if (fp_mvm && !fp_crd) begin
							if (fp_stt == FS_RD && cap && rd_tag == T_SLD) begin
								case (fp_k)
									2'd0:    fp_buf[95:64] <= rd_data;
									2'd1:    fp_buf[63:32] <= rd_data;
									default: fp_buf[31:0]  <= rd_data;
								endcase
								fp_addr <= fp_addr + 32'd4;
								if (fp_k == 2'd2) begin
									// the third longword is not in fp_buf yet
									fp_mw    <= 1'b1;
									fp_mwsel <= fp_fsel;
									fp_mwd   <= {fp_buf[95:32], rd_data};
									fp_k   <= 2'd0;
									if (fp_list == 8'd0) fp_crd <= 1'b1;
									else begin
										fp_list <= fp_list & ~(8'd1 << fp_mvb);
										fp_fsel <= fp_mvr;
									end
								end
								else fp_k <= fp_k + 2'd1;
							end
							if (fp_stt == FS_WR && st.disp) begin
								fp_addr <= fp_addr + 32'd4;
								if (fp_k == 2'd2) begin
									if (fp_list == 8'd0) begin fp_crd <= 1'b1; fp_k <= 2'd3; end
									else begin
										fp_list <= fp_list & ~(8'd1 << fp_mvb);
										fp_fsel <= fp_mvr;
										fp_k    <= 2'd0;
									end
								end
								else fp_k <= fp_k + 2'd1;
							end
						end
						if (fp_cr && !fp_crd && !fp_cw) begin
							if (fp_stt == FS_RD && cap && rd_tag == T_SLD) begin
								fp_cw <= 1'b1; fp_csel <= cr_nth(fp_crmask, fp_k); fp_cwd <= rd_data;
								if (fp_k == fp_crn - 2'd1) fp_crd <= 1'b1;
								else                       fp_k   <= fp_k + 2'd1;
							end
							// no bus at all: an immediate list comes from the
							// instruction stream (one longword per register, left
							// aligned in fpimm) and a register source is one long
							else if (fp_stt == FS_REQ) begin
								fp_cw <= 1'b1; fp_csel <= cr_nth(fp_crmask, fp_k);
								fp_cwd <= (i.src.kind == EK_IMM)
								          ? ((fp_k == 2'd0) ? i.fpimm[95:64] :
								             (fp_k == 2'd1) ? i.fpimm[63:32] : i.fpimm[31:0])
								          : op_a;
								if (fp_k == fp_crn - 2'd1) fp_crd <= 1'b1;
								else                       fp_k   <= fp_k + 2'd1;
							end
						end
					// the answer is in and the destination is memory: store it
					if (!fp_mvm && !fp_sv && !fp_rs && fp_stt == FS_REQ && fp_ok && fp_mem_dst) begin fp_stt <= FS_WR; fp_k <= 2'd0; end
					if (!fp_mvm && !fp_sv && !fp_rs && fp_stt == FS_WR && st.disp) fp_k <= fp_k + 2'd1;
				end
				P_PMMU: begin
					if (!pm_sent && bus_idle) begin
						pm_sent <= 1'b1;
						if (i.imm[3]) begin pt_req <= 1'b1; pt_write <= i.imm[2]; pt_addr <= rd_a; end
						else begin pf_req <= 1'b1; pf_mode <= i.imm[1:0]; pf_addr <= rd_a; end
					end
					if (pt_req && pt_done) begin pt_req <= 1'b0; pm_got <= 1'b1; pm_mmusr <= pt_mmusr; end
					if (pf_req && pf_done) begin pf_req <= 1'b0; pm_got <= 1'b1; end
				end
				P_RESET: begin
					if (r_step == 3'd2 && st.disp) begin
						rst_pending <= 1'b0; ph <= P_START; r_step <= 3'd0;
					end
				end
				default: ;
			endcase
			// an exception starts: step 5 waits for everything older to
			// commit, then latches SR and the supervisor SP
			// the pending-interrupt hold, one clock behind the sampler
			irq_take     <= irq_now && !rd_req && ph != P_EXC && ph != P_RTE &&
			                ph != P_RESET && ph != P_HALT;
			irq_take_lvl <= irq_lvl;
			// (M9.T) arm a trace as the instruction leaves: `sr_in` is still
			// its STARTING SR here, because its own SR write commits at its
			// writeback, one stage later.  Exception entry is not a traced
			// instruction, so P_EXC/P_RESET do not arm.
			if (st.fin && ph != P_EXC && ph != P_RESET) begin
				tr_take  <= tr_arm;
				tr_pc    <= i.pc;
				tr_yield <= !sr_in[15];   // a T0-only trace yields to the target's exception
			end
			// no trace survives the exception its own instruction took: the
			// TRAP takes the TRAP and nothing else (the reference clears the
			// pending trace inside exc(), and hardware agrees -- cputest
			// basic/all reported "Got unexpected trace exception" when an
			// earlier revision let one through)
			if (st.exc_go) tr_take <= 1'b0;
			if (st.exc_go && ph != P_EXC && i.cls == CL_EXC && i.exc_vec == 8'd2) begin
				// an instruction fetch fault (ID marked the instruction): FA =
				// the faulted fetch, SSW RW = 1, SIZE of the fetch, TM = 6/2
				x7[2]  <= cm_hit ? cm_ea : i.exc_addr;          // (a pending CM keeps its EA)
				x7[3]  <= {ssw_f(cm_hit, 1'b0, i.imm[0], 1'b0, 1'b0, i.size, 1'b0, 1'b0, s_bit ? 3'd6 : 3'd2), 16'h0000};
				x7[4]  <= 32'd0;
				x7[5]  <= i.exc_addr;
				x7[6]  <= i.exc_addr;
				x7[7]  <= bus_wdata;
				for (xk = 8; xk <= 14; xk = xk + 1) x7[xk] <= 32'd0;
			end
			if (aerr_go) begin
				x7[2]  <= (ph == P_MOVEM && mm_cmi) ? mm_ea[mm_tag] :    // EA (MOVEM: calculated)
				          aer_m16 ? {rd_a_q[31:4], 4'd0} : rd_a_q;
				x7[3]  <= {aer_ssw, 16'h0000};                           // SSW, WB3S
				x7[4]  <= 32'd0;                                         // WB2S, WB1S
				x7[5]  <= rd_a_q;                                        // FA
				x7[6]  <= rd_a_q;                                        // WB3A
				x7[7]  <= bus_wdata;                                     // WB3D
				for (xk = 8; xk <= 14; xk = xk + 1) x7[xk] <= 32'd0;
				mm_have <= 1'b0;
			end
			if (st.exc_go) begin
				ph     <= P_EXC;
				x_vec  <= st.ev; x_fmt <= st.ef; x_pc <= st.epc; x_addr <= st.eaddr;
				x_step <= 3'd5;
				x_irq  <= st.irq; x_lvl <= irq_lvl;
			end
			if (st.disp && st.dsel == 3'd0 && two_uop && !st.fin) bf_step <= 1'b1;
			// MOVEM
			if (st0.mm_go && ph != P_MOVEM) begin
				ph       <= P_MOVEM;
				mm_mask  <= mm_16 ? 16'h000F : i.ext;
				mm_k_q   <= lsb16(mm_16 ? 16'h000F : i.ext);
				mm_empty <= !mm_16 && (i.ext == 16'd0);
				mm_addr  <= mm_16 ? (s_addr_c & ~32'd15) : cm_use ? cm_ea : mm_ld ? s_addr_c : d_addr_c;
				if (mm_cmi) begin
					mm_tag <= !mm_tag;
					mm_ea[!mm_tag] <= cm_use ? cm_ea : mm_ld ? s_addr_c : d_addr_c;
				end
				mm_have  <= 1'b0;
				m16_smask <= 4'hF; m16_have <= 4'h0;
				mm_bv <= 1'b0;
				m16_saddr <= d_addr_c & ~32'd15;
			end
			if (ph == P_MOVEM) begin
				if (mms.issue) begin
					mm_rreg  <= mm_sreg; mm_rlast <= mm_one; mm_rk <= mm_k[1:0];
					mm_mask  <= mm_mask & ~(16'd1 << mm_k);
					mm_k_q   <= lsb16(mm_mask & ~(16'd1 << mm_k));
					mm_addr  <= mm_addr + mm_sz;
				end
				if (mm_16 && cap) begin m16_buf[mm_rk] <= rd_data; m16_have[mm_rk] <= 1'b1; end
				if (m16_sd) begin
					m16_smask[m16_ks] <= 1'b0;
					m16_saddr <= m16_saddr + 32'd4;
				end
				if (!mm_lde && mms.disp) begin
					mm_mask  <= mm_mask & ~(16'd1 << mm_k);
					mm_k_q   <= lsb16(mm_mask & ~(16'd1 << mm_k));
					mm_addr  <= mm_pre ? mm_addr - mm_sz : mm_addr + mm_sz;
				end
				if (mms.to_buf) begin
					mm_have <= 1'b1; mm_hdata <= mm_p ? mp_val : rd_data; mm_hreg <= mm_rreg; mm_hlast <= mm_rlast;
				end
				if (mm_p && cap) mp_acc <= {mp_acc[15:0], rd_data[7:0]};
				if (mms.from_buf) mm_have <= 1'b0;
				if (mm_bnow && !mms.fin) begin mm_bv <= 1'b1; mm_bval <= mm_lval; end
				if (mms.fin) begin mm_empty <= 1'b0; mm_tail <= 1'b0; end
				if (mms.tail) mm_tail <= 1'b1;
			end
			// (M10.1(c)) the released operation: `fp_bg` holds the next FP
			// instruction back until the unit answers, and nothing else does.
			// (M10.2) a control-register move releases nothing: it sent no
			// command, so `done` will never come and a background flag set
			// here would deadlock the next FP instruction at P_START.
			// (M10 remainder) ... except a FRESTORE whose BUSY frame restarts the
			// unit (CU_SAVEPC = $FE): that command is released the same way
			// and the next FP instruction waits for its `done`
			if (HAS_FPU != 0 && ph == P_FPU && st.disp && st.fin) fp_bg <= (!fp_cr && !fp_mvm && !fp_sv && !fp_rs && !fp_cnd && !(fp_dn || fp_done)) ||
			                                                              (fp_rs && fp_frm && fp_bsy && fp_fr_resume && !fp_done);
			else if (HAS_FPU != 0 && fp_bg && fp_done)            fp_bg <= 1'b0;
			// (M10.3) a RELEASED operation's enabled exception: the instruction
			// has left, so it cannot be reported against it.  It becomes
			// pending for the next FP dispatch, and clearing fp_bg here is the
			// part that must not be forgotten -- otherwise the next floating-
			// point instruction waits at P_START for ever, which is the hang
			// M10.2 found for a different reason.  The second term catches an
			// exception that arrives in the very clock of the release, when
			// fp_bg is not set yet.
			fp_pcap <= 1'b0;
			if (HAS_FPU != 0 && fp_exc_req &&
			    (fp_bg || (ph == P_FPU && st.disp && st.fin && !fp_cr && !fp_mvm && !fp_sv && !fp_rs && !fp_cnd && !fp_ae))) begin
				fp_bg   <= 1'b0;
				fp_pend <= 1'b1;
				fp_pvec <= fp_exc_vec;
				fp_pcap <= 1'b1;     // the unit prepares the frame from its shadow
			end
			// (M10 remainder) a completed FRESTORE of an E1/E3 frame re-arms the
			// deferred exception for the NEW context, vectored by the FPSR/FPCR
			// enables the unit now holds (lib/AP68040 S_FREST_UD/BD) -- the clock
			// after the frame's last longword, when the unit has installed it --
			// unless the frame restarts the unit (CU_SAVEPC $FE), whose command
			// may raise its own
			if (HAS_FPU != 0 && fp_rarm) begin
				fp_rarm <= 1'b0;
				fp_pend <= fp_fr_e1pend && !(fr_busy && fp_fr_resume);
				fp_pvec <= fp_cur_vec;
			end
			if (aerr_dbl || wf_dbl) ph <= P_HALT;
			if (ph != P_RTE && eac_v_use && cm_hit && (st.fin || st.exc_go || st0.mm_go)) cm_v <= 1'b0;
			if (st.fin) begin
				ph <= P_START; bf_step <= 1'b0;
				done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
			end
		end
		// This stage's OWN redirect (RTS/RTD/RTR, a memory-indirect JMP/JSR,
		// a not-taken Bcc/DBcc) flushes EA-calc and ID (flush_eac), but not
		// this stage -- `flush` is EX's redirect or WB's SMC refetch.  Any read
		// in flight then belongs to a flushed, YOUNGER instruction: the
		// redirecting one finished its reads before it could redirect, and
		// the early read (use_early) is issued for the instruction in EA-calc.
		// Its answer must be thrown away and nothing it already delivered
		// (done_*) may be handed to the next instruction.  Before this, a
		// guessed-taken Bcc's target read its operand early, EA-fetch
		// corrected the branch, and the late answer became the fall-through
		// instruction's operand (exec's Enqueue in Kickstart 3.1.4 with the
		// M14 instruction read path; t_earlydrop_pipe.s).
		if (eaf_redir_v && !flush && !wf_go) begin
			if ((rd_pend && !rd_ack) || rd_req) rd_drop <= 1'b1;
			done_smi <= 1'b0; done_dmi <= 1'b0; done_sld <= 1'b0; done_dld <= 1'b0;
		end
	end
end

endmodule
