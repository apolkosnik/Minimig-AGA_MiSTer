//--------------------------------------------------------------------------//
// AP68060 - pipelined MC68060                                            //
//                                                                          //
// ap68060_fpif.sv - the FPU at the EX stage                                //
//                                                                          //
// Wraps the floating point unit (ap040_fpu: registers, conversion,        //
// arithmetic, FSAVE state) for the pipeline.  Microcode moves the data    //
// (memory, Dn, FMOVEM, frames); the OP_FPU uops below run the FPU side in //
// EX, in program order, and act only once they are the oldest uop in     //
// flight (WB empty), so no FPU side effect is ever taken back by an older //
// exception.  Sub-operation in uop.cond:                                  //
//                                                                          //
//   CHK   first uop of every FPU instruction (A = extension word, B =     //
//         operation word): waits for a background operation, delivers a  //
//         pending exception (pre-instruction: format $0, PC = this        //
//         instruction), latches the words, raises the encoding faults     //
//         (F-line, illegal, unimplemented EA, unimplemented instruction,  //
//         packed operand) before any side effect, and records FPIAR       //
//   EAL   latches the operand address; raises an unimplemented           //
//         instruction or packed operand found by CHK (its frame carries   //
//         the address)                                                    //
//   DISP  the FPU operation: FPm/<ea>/Dn to FPn, FPn to <ea>;            //
//         A, B and the latch carry the operand's long words               //
//   GET   long word 1 or 2 (imm) of a store result or an FMOVEM register //
//   END   last uop of a store, FMOVEM, FSAVE or FRESTORE: raises a store  //
//         exception after the stores, ends FSAVE, applies FRESTORE        //
//   CRR   CRW   control register slot read / write (imm / immb: 0 FPCR,  //
//         1 FPSR, 2 FPIAR; a slot not in the list does nothing)           //
//   LIST  FMOVEM: latches the register list;                              //
//         result: the signed byte adjustment of (An)+ / -(An)             //
//   MVR   MVW   FMOVEM: raw register read / write of the next slot        //
//   COND  FBcc (FScc, FTRAPcc: unimplemented);  DBCC  FDBcc (the same)    //
//   SV0   SVW   FSAVE: frame size (signed for -(An)) / frame word imm/4   //
//   RS0   RSW   FRESTORE: format check, frame size / frame word immb/4    //
//                                                                          //
// The 68060 FPU (MC68060UM section 6): the transcendentals, FMOVECR,      //
// FScc, FDBcc and FTRAPcc are unimplemented (vector 11, format $2);      //
// packed decimal operands take vector 55 (format $2), denormal and        //
// unnormal ones vector 55 (format $0 before the instruction, $3 after a   //
// store); X/P immediates, dynamic FMOVEM lists and FMOVEM.L #imm of more  //
// than one control register vector 60.  An arithmetic exception -- an     //
// enabled one, or OVFL/UNFL, which always trap -- puts the FPU in the     //
// EXCP state: it is taken as a pre-instruction exception by every FPU    //
// instruction until FSAVE (or FRESTORE) leaves the state (a store takes   //
// it post-instruction at once, format $3).  The state frame is three long //
// words: NULL $00, IDLE $60, EXCP $E0 with the exception's vector code,  //
// and the exception operand.                                              //
//                                                                          //
// FMOVE/FADD/FSUB/FMUL on ordinary operands go into the FPU's pipeline,  //
// done at issue (one may follow every cycle); every other uop that reads  //
// or writes FPU state waits until the pipeline is empty (pbusy).         //
// Register-destination arithmetic past every datatype check is released  //
// to the background; its exception becomes pending, for the next FPU     //
// instruction, as the 68060's register-destination exceptions are.       //
//--------------------------------------------------------------------------//

module ap68060_fpif
	import ap68060_pkg::*;
#(
	parameter bit         FPU_PIPE     = 1,
	parameter bit         NO_FPU       = 0      // the MC68LC060: no FPU (dfp is held high above)
)(
	input  logic        clk,
	input  logic        nreset,

	// the uop in EX
	input  logic        ex_v,           // an OP_FPU uop is in EX
	input  logic  [3:0] sub,
	input  logic        fuse,           // CHK: dispatch in the same uop (FPm to FPn)
	input  logic        eal,            // CHK: latch the EA as well (EAL in the same uop)
	input  logic  [7:0] imm,            // operand A constant
	input  logic  [7:0] immb,           // operand B constant
	input  logic [31:0] av,
	input  logic [31:0] bv,
	input  logic [15:0] aw,             // av, bv without the memory operand
	input  logic [15:0] bw,             // (CHK's words: registers, no mux)
	input  logic [15:0] dw_a,           // the same words of the uop entering
	input  logic [15:0] dw_b,           // EX (DC2's), and EX not holding
	input  logic        dw_ld,          // (DC2 moving on or EX emptying: the
	                                    // decode is of the uop EX has next)
	input  logic [31:0] latch,
	input  logic [31:0] ea,             // the uop's EA (EAL; FScc's operand)
	input  logic [31:0] pc,
	input  logic [31:0] target,         // FDBcc: the branch target
	input  logic        safe,           // no older uop is in flight
	input  logic        adv,            // the uop leaves EX this cycle
	input  logic        kill,
	input  logic        dfp,            // PCR.DFP: the FPU is disabled

	output logic        hold,
	output logic [31:0] res,
	output logic        dkill,          // no register write
	output logic        taken,          // FBcc / FDBcc
	output logic  [7:0] xvec,           // exception, 0 none
	output logic  [3:0] xfmt,
	output logic        xnext,          // stacked PC: the next instruction
	output logic [31:0] xaddr,          // frame address field
	output logic        xcommit,        // the uop's address updates stand
	output logic        st_kill,        // stores of this instruction suppressed

	// dynamic cancels at AG
	output logic  [7:0] mv_slots,       // FMOVEM slots that hold a register
	output logic  [2:0] cr_slots        // FMOVEM control slots FPCR FPSR FPIAR
);

localparam logic [3:0] FC_CHK = 4'd0, FC_DISP = 4'd1, FC_GET = 4'd2, FC_END = 4'd3,
                       FC_CRR = 4'd4, FC_CRW = 4'd5, FC_LIST = 4'd6, FC_MVR = 4'd7,
                       FC_MVW = 4'd8, FC_COND = 4'd9, FC_DBCC = 4'd10, FC_SV0 = 4'd11,
                       FC_SVW = 4'd12, FC_RS0 = 4'd13, FC_RSW = 4'd14, FC_EAL = 4'd15;

localparam logic [7:0] VEC_ILL = 8'd4, VEC_FLINE = 8'd11, VEC_FMTERR = 8'd14,
                       VEC_BSUN = 8'd48, VEC_UNSUP = 8'd55, VEC_UNIMPEA = 8'd60;

// CHK's fault classes (chk_dec)
localparam logic [3:0] K_NONE = 4'd0,
                       K_FLINE = 4'd1,     // F-line, format $0
                       K_ILL = 4'd2,       // illegal (opmodes $78-$7F)
                       K_UNIMP = 4'd3,     // unimplemented, format $2, no operand address
                       K_FMOVECR = 4'd4,   // the same, the exception byte kept
                       K_UNIMPM = 4'd5,    // unimplemented, the memory operand's address
                       K_EA60 = 4'd6,      // unimplemented effective address, format $0
                       K_PK = 4'd7,        // packed operand in Dn: vector 55, format $2
                       K_PKM = 4'd8,       // packed operand in memory, its address
                       K_DFPM = 4'd9;      // FPU disabled, the memory operand's address

//--------------------------------------------------------------------------
// helpers
//--------------------------------------------------------------------------
function automatic logic [3:0] fp_bytes(input logic [2:0] f);
	case (f)
		3'd0, 3'd1: fp_bytes = 4'd4;
		3'd4:       fp_bytes = 4'd2;
		3'd6:       fp_bytes = 4'd1;
		3'd5:       fp_bytes = 4'd8;
		default:    fp_bytes = 4'd12;
	endcase
endfunction

// a memory operand the FPU pipeline takes (ap040_fpu q_n): an integer, or
// a zero or normalized single/double/extended with an unbiased exponent
// within +-60 (formed here, as the operand is registered, so the FPU's
// dispatch starts from a register)
function automatic logic nice_mem(input logic [95:0] d, input logic [2:0] f);
	case (f)
		3'd0, 3'd4, 3'd6: nice_mem = 1'b1;
		3'd1: nice_mem = (d[94:64] == 31'd0) || (d[94:87] >= 8'd67 && d[94:87] <= 8'd187);
		3'd5: nice_mem = (d[94:32] == 63'd0) || (d[94:84] >= 11'd963 && d[94:84] <= 11'd1083);
		3'd2: nice_mem = (d[63:0] == 64'd0) ? (d[94:80] != 15'h7FFF)
		                 : (d[63] && d[94:80] >= 15'd16323 && d[94:80] <= 15'd16443);
		default: nice_mem = 1'b0;
	endcase
endfunction

// WinUAE fault_if_nonexisting_opmode: 1 = F-line (format $0, no side
// effects), 2 = opmodes $78-$7F, which the 68040 reports as illegal
function automatic logic [1:0] opmode_class(input logic [6:0] op);
	case (op)
		7'h05, 7'h07, 7'h0B, 7'h13, 7'h17, 7'h1B,
		7'h29, 7'h2A, 7'h2B, 7'h2C, 7'h2D, 7'h2E, 7'h2F,
		7'h39, 7'h3B, 7'h3C, 7'h3D, 7'h3E, 7'h3F,
		7'h42, 7'h43, 7'h46, 7'h47,
		7'h48, 7'h49, 7'h4A, 7'h4B, 7'h4C, 7'h4D, 7'h4E, 7'h4F,
		7'h50, 7'h51, 7'h52, 7'h53, 7'h54, 7'h55, 7'h56, 7'h57,
		7'h59, 7'h5B, 7'h5D, 7'h5F,
		7'h61, 7'h65, 7'h69, 7'h6A, 7'h6B, 7'h6D, 7'h6E, 7'h6F,
		7'h70, 7'h71, 7'h72, 7'h73, 7'h74, 7'h75, 7'h76, 7'h77:
			opmode_class = 2'd1;
		7'h78, 7'h79, 7'h7A, 7'h7B, 7'h7C, 7'h7D, 7'h7E, 7'h7F:
			opmode_class = 2'd2;
		default:
			opmode_class = 2'd0;
	endcase
endfunction

// the opmodes the 68060 executes in hardware (the others: the M68060SP)
function automatic logic op_in_hw(input logic [6:0] op);
	case (op)
		7'h00, 7'h40, 7'h44, 7'h18, 7'h58, 7'h5C, 7'h1A, 7'h5A, 7'h5E,
		7'h38, 7'h3A, 7'h22, 7'h62, 7'h66, 7'h28, 7'h68, 7'h6C,
		7'h23, 7'h27, 7'h63, 7'h67, 7'h20, 7'h24, 7'h60, 7'h64,
		7'h04, 7'h41, 7'h45, 7'h01, 7'h03:
			op_in_hw = 1'b1;
		default:
			op_in_hw = 1'b0;
	endcase
endfunction

// IEEE predicate over the FPSR condition codes {N, Z, I, NAN}
function automatic logic fp_cond(input logic [5:0] pred, input logic [3:0] cc);
	logic n, z, nan;
	n = cc[3]; z = cc[2]; nan = cc[0];
	case (pred[3:0])
		4'h0: fp_cond = 1'b0;
		4'h1: fp_cond = z;
		4'h2: fp_cond = !(nan | z | n);
		4'h3: fp_cond = z | !(nan | n);
		4'h4: fp_cond = n & !(nan | z);
		4'h5: fp_cond = z | (n & !nan);
		4'h6: fp_cond = !(nan | z);
		4'h7: fp_cond = !nan;
		4'h8: fp_cond = nan;
		4'h9: fp_cond = nan | z;
		4'hA: fp_cond = nan | !(n | z);
		4'hB: fp_cond = nan | z | !n;
		4'hC: fp_cond = nan | (n & !z);
		4'hD: fp_cond = nan | z | n;
		4'hE: fp_cond = !z;
		default: fp_cond = 1'b1;
	endcase
endfunction

// operand window: A, B, latch, left aligned by the source format
function automatic logic [95:0] din_of(input logic [2:0] f, input logic [31:0] a,
                                       input logic [31:0] b, input logic [31:0] c);
	case (f)
		3'd4:       din_of = {a[15:0], 80'd0};
		3'd6:       din_of = {a[7:0], 88'd0};
		3'd5:       din_of = {a, b, 32'd0};
		3'd2, 3'd3: din_of = {a, b, c};
		default:    din_of = {a, 64'd0};
	endcase
endfunction

//--------------------------------------------------------------------------
// the FPU
//--------------------------------------------------------------------------
logic        f_req, f_crwe, f_iawe, f_bsun, f_fmwe, f_rst;
logic        f_rest_idle, f_uack, f_fsclr;
logic  [2:0] f_class, f_fmt, f_srcr, f_dstr, f_fmsel;
logic  [7:0] f_okvn;          // the FPU's register-ready flags, next cycle
logic        f_aok, f_bok;    // ... of the next source and destination
logic  [6:0] f_opm;
// (f_din also carries FMOVEM's register data: an operation's instruction
// waits until the FPU has taken its operand, so FMOVEM's writes come later)
logic [95:0] f_din;
logic        f_dnice;          // f_din is an ordinary operand (the FPU pipeline)
logic  [1:0] f_crsel;
logic [31:0] f_crwd, f_iapc;
logic        f_done, f_accepted, f_unimp, f_unsupp, f_excreq, f_used, f_wbok;
// (the FPU's accepted is a register of its own: the holds start from it)
logic        f_pbusy;          // pipelined operations in flight
logic        f_pdone;          // the request went into the pipeline (this cycle)
// the released operation ends cleanly: done, or its F_WB without an
// exception (a cycle sooner)
wire         f_end = (f_done || f_wbok) && !f_excreq;
logic        fresh;            // a fused CHK's request went out last cycle
logic  [7:0] f_excvec;
logic [95:0] f_dout, f_fmrd;
logic  [3:0] f_cc;
logic [31:0] f_crrd;
logic        f_bsun_en;
logic [95:0] f_xop;            // the EXCP frame's exception operand
// FRESTORE: the frame's words are staged as they are read and go to the
// exception operand together, once the last one is in: a format error or a
// fault on a later word leaves the operand as it was (Appendix D, 8.2.1)
logic        f_rwe;
logic [15:0] rs_w0;            // the exponent word's upper half
logic [31:0] rs_w1;
logic [31:0] f_rwd;            // the last word

generate if (!NO_FPU) begin : g_fpu
	ap040_fpu #(.PIPE(FPU_PIPE)) fpu (
		.clk(clk), .nreset(nreset), .ce(1'b1),
		.req(f_req), .op_class(f_class), .opmode(f_opm), .wb_ok(f_wbok),
		.src_fmt(f_fmt), .src_r(f_srcr), .dst_r(f_dstr),
		.din(f_din), .din_nice(f_dnice), .done(f_done), .accepted(f_accepted),
		.unimp(f_unimp), .unsupp(f_unsupp),
		.exc_req(f_excreq), .exc_vec(f_excvec), .dout(f_dout),
		.fpcc(f_cc),
		.cr_sel(f_crsel), .cr_we(f_crwe), .cr_wdata(f_crwd), .cr_rdata(f_crrd),
		.bsun_req(f_bsun), .bsun_enable(f_bsun_en),
		.ia_we(f_iawe), .ia_wdata(f_iapc),
		.fm_sel(f_fmsel), .fm_we(f_fmwe), .fm_wdata(f_din), .fm_rdata(f_fmrd),
		.fpu_used(f_used), .pbusy(f_pbusy), .pdone(f_pdone),
		.okv_next(f_okvn), .sel_x(1'b1), .aok_x(f_aok), .bok_x(f_bok),
		.opmode_n(n_opm), .op_class_n(n_class), .src_fmt_n(n_fmt),
		.fstate_et(f_xop), .frestore_idle(f_rest_idle),
		.frestore_we(f_rwe), .frestore_wd({rs_w0, rs_w1, f_rwd}),
		.unimp_ack(f_uack), .fs_clr(f_fsclr),
		.fp_reset(f_rst)
	);
end else begin : g_nofpu
	// the MC68LC060: the FPU is disabled for good (dfp), every FPU
	// instruction traps at CHK or EAL, so nothing reaches the unit
	assign f_accepted = 1'b0;
	assign f_wbok     = 1'b0;
	assign f_cc       = 4'd0;
	assign f_crrd     = 32'd0;
	assign f_bsun_en  = 1'b0;
	assign f_fmrd     = 96'd0;
	assign f_pdone    = 1'b0;
	assign f_okvn     = 8'hFF;
	assign f_pbusy    = 1'b0;
	always_comb begin
		f_done = 1'b0; f_unimp = 1'b0; f_unsupp = 1'b0; f_excreq = 1'b0;
		f_excvec = 8'd0; f_dout = 96'd0; f_used = 1'b0; f_xop = 96'd0;
	end
end endgenerate

//--------------------------------------------------------------------------
// state
//--------------------------------------------------------------------------
logic [15:0] opw_q, ext_q;     // the instruction's words (latched by CHK)
logic        fsr_q;            // ... it is FSAVE or FRESTORE (for END's hold)
logic [31:0] lst_q;            // ... FMOVEM's LIST result for a static list: its
                               // bytes, negated for -(An)
logic        bg;               // a released operation is running
logic        pend;             // the EXCP state: its exception, taken by every FPU
logic  [7:0] pend_vec;         // instruction but FSAVE and FRESTORE
logic        go;               // DISP: the request is out
logic        done_q;           // DISP (store): the outcome is known
logic [31:0] eaa;              // the operand address
logic        eav;
logic        sx_v;             // a store's exception, raised by END
logic  [7:0] sx_vec;
logic  [3:0] sx_fmt;
logic [31:0] sx_addr;
logic        sx_kill;          // the stores are suppressed
logic        sx_commit;        // ... and the address updates stand
logic  [3:0] dfr;              // CHK's fault left for EAL (the operand address)
logic  [7:0] list;             // FMOVEM: the register list
logic        mv_lsb, mv_rev, mv_st, mv_m1;
logic  [2:0] slot;
logic        mvr_wait;         // MVR: the raw read port's set-up cycle
logic        crr_wait;         // CRR: the control register read's cycle
logic [95:0] get_q;            // the long words GET returns
logic  [1:0] sv_kind;          // FSAVE frame: 0 NULL, 1 IDLE, 2 EXCP
logic  [2:0] sv_v;             // ... its vector code
logic  [1:0] rs_kind;          // FRESTORE frame, the same codes
logic  [2:0] rs_v;

// the words decoded: CHK's own, else the latched ones
wire [15:0] opw = (sub == FC_CHK) ? bw : opw_q;
wire [15:0] ext = (sub == FC_CHK) ? aw : ext_q;
wire  [2:0] eam = opw[5:3];
wire  [2:0] ear = opw[2:0];
wire  [2:0] ocl = ext[15:13];
wire  [2:0] fmt = ext[12:10];
wire  [6:0] opm = ext[6:0];
wire        is_gen   = (opw[15:6] == 10'b1111_0010_00);
wire        is_cc    = (opw[15:6] == 10'b1111_0010_01);   // FScc FDBcc FTRAPcc
wire        is_bcc   = (opw[15:7] == 9'b1111_0010_1);
wire        is_fsave = (opw[15:6] == 10'b1111_0011_00);
wire        is_frest = (opw[15:6] == 10'b1111_0011_01);
wire        is_fdbcc = is_cc && (eam == 3'd1);
wire        ea_dn    = (eam == 3'd0);
wire        ea_an    = (eam == 3'd1);
wire        ea_pi    = (eam == 3'd3);
wire        ea_pd    = (eam == 3'd4);
wire        ea_imm   = (eam == 3'd7) && (ear == 3'd4);
wire        ea_pcrel = (eam == 3'd7) && (ear == 3'd2 || ear == 3'd3);
wire        ea_dalt  = (eam >= 3'd2) && !(eam == 3'd7 && ear >= 3'd2);
// control registers of FMOVE(M): FPCR FPSR FPIAR; an empty list is FPIAR
wire  [2:0] crl      = (ext[12:10] == 3'd0) ? 3'b001 : ext[12:10];

//--------------------------------------------------------------------------
// CHK: the encoding faults, in WinUAE fpuop_arithmetic2's 68060 order
//--------------------------------------------------------------------------
// (a function of the two words: CHK's are immediates, known in DC2, so the
// decode is registered as the uop enters EX -- off the hold and exception
// paths; the live decode checks it in simulation)
function automatic logic [6:0] chk_dec(input logic [15:0] ow, input logic [15:0] ew);
	logic [1:0] oc;
	logic [2:0] em, er, ol, fm, cl;
	logic       dn, an, pi, pd, im, pc, dalt, mem, ia, un;
	logic [3:0] k;
	em = ow[5:3]; er = ow[2:0];
	ol = ew[15:13]; fm = ew[12:10];
	cl = ew[12:10];
	dn = (em == 3'd0); an = (em == 3'd1); pi = (em == 3'd3); pd = (em == 3'd4);
	im = (em == 3'd7) && (er == 3'd4);
	pc = (em == 3'd7) && (er == 3'd2 || er == 3'd3);
	dalt = (em >= 3'd2) && !(em == 3'd7 && er >= 3'd2);
	mem = (em >= 3'd2) && !(em == 3'd7 && er >= 3'd4);     // an operand address
	k = K_NONE; ia = 1'b0;
	oc = opmode_class(ew[6:0]);
	un = !op_in_hw(ew[6:0]);
	if (ow[15:6] == 10'b1111_0010_00) case (ol)
		3'b000, 3'b010: begin
			if (ol == 3'b010 && fm == 3'd7) begin
				// FMOVECR: unimplemented before the opmode is looked at
				k = K_FMOVECR; ia = 1'b1;
			end
			else if (oc == 2'd1) k = K_FLINE;
			else if (oc == 2'd2) k = K_ILL;
			else begin
				// FPIAR is set before the operand is fetched
				ia = 1'b1;
				if (ol == 3'b000) begin
					if (un) k = K_UNIMP;
				end
				else if (dn) begin
					if (un) k = K_UNIMP;
					else if (fm == 3'd3) k = K_PK;
					else if (fm == 3'd2 || fm == 3'd5) k = K_FLINE;
				end
				else if (an) k = un ? K_UNIMP : K_FLINE;
				else if (im) begin
					if (fm == 3'd2 || fm == 3'd3) k = K_EA60;
					else if (un) k = K_UNIMP;
				end
				else if (!mem) k = K_FLINE;
				else if (un) k = K_UNIMPM;
				else if (fm == 3'd3) k = K_PKM;
			end
		end
		3'b001: k = K_FLINE;
		3'b011: begin
			if (dn) begin
				if (fm == 3'd3 || fm == 3'd7) begin k = K_PK; ia = 1'b1; end
				else if (fm == 3'd2 || fm == 3'd5) k = K_FLINE;
			end
			else if (!dalt) k = K_FLINE;
			else if (fm == 3'd3 || fm == 3'd7) begin k = K_PKM; ia = 1'b1; end
		end
		3'b100, 3'b101: begin
			// one control register to or from Dn; only FPIAR with An
			// (Dn with no register: FPIAR; An with none: F-line on the 68060)
			if (dn && !(cl == 3'b000 || cl == 3'b100 || cl == 3'b010 || cl == 3'b001)) k = K_FLINE;
			else if (an && cl != 3'b001) k = K_FLINE;
			else if (ew[13] && (im || pc)) k = K_FLINE;
			else if (!ew[13] && im && !(cl == 3'b000 || cl == 3'b100 ||
			                            cl == 3'b010 || cl == 3'b001)) k = K_EA60;
		end
		default: begin   // FMOVEM data registers
			if (em < 3'd2 || im) k = K_FLINE;
			else if (ew[13] && (pi || pc)) k = K_FLINE;
			else if (!ew[13] && pd) k = K_FLINE;
			else if (ew[11]) k = K_EA60;       // a dynamic list
		end
	endcase
	// FScc FDBcc FTRAPcc (unimplemented) and FBcc record FPIAR
	if (ow[15:6] == 10'b1111_0010_01 || ow[15:7] == 9'b1111_0010_1) ia = 1'b1;
	chk_dec = {k, ia,
	           (ow[15:7] == 9'b1111_0011_0),
	           (ow[15:6] == 10'b1111_0010_01)};
endfunction
logic [6:0] cq;                 // chk_dec of the uop in EX (CHK's words)
always_ff @(posedge clk)
	if (!nreset) cq <= '0;
	else if (dw_ld) cq <= chk_dec(dw_b, dw_a);
wire [3:0] chk_k  = cq[6:3];
wire chk_ia  = cq[2];
wire chk_fs  = cq[1];           // FSAVE or FRESTORE
wire chk_cc  = cq[0];           // FScc FDBcc FTRAPcc
// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && ex_v && sub == FC_CHK && cq != chk_dec(bw, aw)) begin
		$display("FAIL: fpif: CHK's registered decode %b, its words decode %b", cq, chk_dec(bw, aw));
		$finish;
	end
// synthesis translate_on

// FMOVEM slot -> list bit -> register
function automatic logic [2:0] slot_bit(input logic [2:0] k, input logic lsb);
	slot_bit = lsb ? k : (3'd7 - k);
endfunction
// mv_slots: list in slot order, a register of its own (set with list and
// mv_lsb, so the same value a cycle earlier than a decode of them: it feeds
// AG's dynamic cancel, and so the register file's write enable)
wire [2:0] cur_bit = slot_bit(slot, mv_lsb);
wire [2:0] cur_reg = (!mv_st || mv_m1) ? (3'd7 - cur_bit) : cur_bit;  // loads: bit 7 = FP0
wire       cur_on  = list[cur_bit];
assign cr_slots = {crl[0], crl[1], crl[2]};       // bit 0 = FPCR slot
function automatic logic [1:0] crsel_of(input logic [1:0] k);   // the FPU's cr_sel
	crsel_of = (k == 2'd0) ? 2'd2 : (k == 2'd1) ? 2'd1 : 2'd0;
endfunction

// LIST's result from the instruction's words as CHK latches them
function automatic logic [31:0] lst_of(input logic [15:0] ow, input logic [15:0] xw);
	logic [3:0] n;
	logic [6:0] b;
	n = 4'd0;
	for (int i = 0; i < 8; i++) n = n + {3'd0, xw[i]};
	b = 7'(n) * 7'd12;
	lst_of = (ow[5:3] == 3'd4) ? -{25'd0, b} : {25'd0, b};
endfunction
// ... and for a dynamic list (Dn): from the operand, the words latched
function automatic logic [31:0] lst_dyn(input logic [15:0] ow, input logic [7:0] l);
	logic [3:0] n;
	logic [6:0] b;
	n = 4'd0;
	for (int i = 0; i < 8; i++) n = n + {3'd0, l[i]};
	b = 7'(n) * 7'd12;
	lst_dyn = (ow[5:3] == 3'd4) ? -{25'd0, b} : {25'd0, b};
endfunction
// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && ex_v && sub == FC_LIST && res != ((ea_pd) ? -{25'd0, l_bytes} : {25'd0, l_bytes})) begin
		$display("FAIL: fpif: the LIST result %h, the list's %h", res,
		         (ea_pd) ? -{25'd0, l_bytes} : {25'd0, l_bytes});
		$finish;
	end
// synthesis translate_on
// FMOVEM list and adjustment (LIST, combinational for its result)
logic [7:0] l_now;
logic [6:0] l_bytes;
always_comb begin
	logic [3:0] n;
	l_now = ext[11] ? av[7:0] : ext[7:0];
	n = 4'd0;
	for (int i = 0; i < 8; i++) n = n + {3'd0, l_now[i]};
	l_bytes = 7'(n) * 7'd12;
end

// FSAVE frame (MC68060UM figure 6-10): the exception operand's exponent and
// the frame format and vector code, then the operand's mantissa
wire [1:0] sv_now  = !f_used ? 2'd0 : pend ? 2'd2 : 2'd1;
wire [2:0] pend_vc = (pend_vec == VEC_UNSUP) ? 3'd7 : pend_vec[2:0];   // 48-54: 0-6
function automatic logic [7:0] frame_fmt(input logic [1:0] k);
	frame_fmt = (k == 2'd2) ? 8'hE0 : (k == 2'd1) ? 8'h60 : 8'h00;
endfunction
// FRESTORE: $00, $60 and $E0 are frames; any other format is a format error
wire       rs_ok   = (av[15:8] == 8'h00) || (av[15:8] == 8'h60) || (av[15:8] == 8'hE0);
wire [1:0] rs_now  = (av[15:8] == 8'hE0) ? 2'd2 : (av[15:8] == 8'h60) ? 2'd1 : 2'd0;

// a fault raised by EAL (CHK's, waiting for the operand address): a
// 12-byte operand's -(An) address is the decremented An + 8, extended as
// well as packed (the M68060SP's _dcalc_ea: "for extended precision and
// packed is 8 bytes too big"; WinUAE get_fp_value does it for packed)
wire [31:0] dfr_addr = ea + ((ea_pd && (fmt == 3'd2 || fmt == 3'd3 || fmt == 3'd7)) ? 32'd8 : 32'd0);

// FPU disabled (PCR.DFP, MC68060UM 8.2.4): every floating-point instruction
// takes vector 11 with a format $4 frame -- PC the next instruction, +8 the
// memory operand's address (0 for a register operand; for -(An) the first
// operand byte, An - 4 for extended and packed), +$C the instruction (the
// backend puts its PC there), the address register not modified.  The
// operand address comes from the routine's EA uop (EAL, or CHK with it);
// FSAVE, FRESTORE, FScc/FDBcc/FTRAPcc, FBcc and FMOVEM -(An)/(An)+ have none
// and report 0.
wire        dfp_gen  = is_gen && (ext[15:13] == 3'b000 || ext[15:13] == 3'b010 || ext[15:13] == 3'b011);
wire [31:0] dfp_addr = ea_imm ? 32'd0 :
                       ea + ((ea_pd && dfp_gen && (fmt == 3'd2 || fmt == 3'd3 || fmt == 3'd7)) ? 32'd8 : 32'd0);
// the routine reaches an EA uop for this instruction's memory operand
wire        dfp_mem  = is_gen && (eam >= 3'd2) && !ea_imm &&
                       !(ext[15:14] == 2'b11 && (ea_pd || ea_pi));
// FScc <mem> (not FTRAPcc, whose mode 7 words are its operand): the address
// comes with its COND uop
wire        dfp_scc  = is_cc && !is_fdbcc && (eam >= 3'd2) && !(eam == 3'd7 && ear >= 3'd2);

//--------------------------------------------------------------------------
// the uop in EX
//--------------------------------------------------------------------------
wire chk_pend = pend && !chk_fs;     // (CHK's) FSAVE/FRESTORE save or replace it
// uops with no FPU side effect need not wait to be the oldest: GET reads
// the latched result; END of an instruction with no store exception
// pending and not FSAVE/FRESTORE does nothing (a fault of an older uop
// discards it with the rest)
// (END's instruction is the latched one: fsr_q, not the opcode decode)
wire nosafe = (sub == FC_GET) || (sub == FC_END && !sx_v && !fsr_q);
// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && ex_v && sub == FC_END && fsr_q != (is_fsave || is_frest)) begin
		$display("FAIL: fpif: fsr_q %b, the instruction's FSAVE/FRESTORE %b", fsr_q, is_fsave || is_frest);
		$finish;
	end
// synthesis translate_on

logic [31:0] res_g;            // the result as the hold logic forms it (checked, then unused)
always_comb begin
	hold    = 1'b0;
	res_g     = 32'd0;
	dkill   = 1'b0;
	taken   = 1'b0;
	xvec    = 8'd0;
	xfmt    = 4'd0;
	xnext   = 1'b0;
	xaddr   = pc;
	xcommit = 1'b0;
	st_kill = sx_kill;
	if (ex_v) begin
		if (!safe && !nosafe) hold = 1'b1;
		// FPU state (registers, FPSR, condition codes, control registers,
		// frames) is current only once the pipelined operations complete:
		// only a new operation (CHK, EAL, DISP) goes ahead of them
		else if (f_pbusy && !(sub == FC_CHK || sub == FC_EAL || sub == FC_DISP || sub == FC_GET))
			hold = 1'b1;
		else case (sub)
			FC_CHK: begin
				// the released operation completing this cycle without an
				// exception lets CHK go (one that raises one makes it pending
				// at this edge: CHK waits and delivers it)
				// the FPU sees it now: done at once if it went into the
				// pipeline (pdone: the registered done of this cycle may be
				// a released operation's, which fresh masks)
				if (dfp) begin
					// the FPU disabled: the trap here, or at the EA uop (FScc:
					// its COND).  Words the FPU would not recognise keep their
					// F-line and illegal instruction exceptions (8.2.4)
					if (chk_k == K_FLINE) xvec = VEC_FLINE;
					else if (chk_k == K_ILL) xvec = VEC_ILL;
					else if (eal || !(dfp_mem || dfp_scc)) begin
						xvec = VEC_FLINE; xfmt = 4'd4; xnext = 1'b1;
						xaddr = eal ? dfp_addr : 32'd0;
					end
				end
				else if (fuse && go && fresh && !f_pdone) hold = 1'b1;
				else if (fuse && go) begin
					// dispatched (below): DISP's outcome.  A datatype trap is
					// a pre-instruction exception: format $0 with the NEXT PC
					// (MC68060UM table 6-10; the M68060SP emulates the
					// instruction and returns past it); an arithmetic
					// exception becomes pending
					if (f_unimp) begin
						xvec = VEC_FLINE; xfmt = 4'd2; xnext = 1'b1;
						xaddr = 32'd0; xcommit = 1'b1;
					end
					else if (f_unsupp) begin
						xvec = VEC_UNSUP; xnext = 1'b1; xcommit = 1'b1;
					end
					else if (!(f_accepted || f_done || f_pdone || f_excreq)) hold = 1'b1;
				end
				else if (bg && !f_end) hold = 1'b1;
				else if (chk_pend) begin
					xvec = pend_vec;
				end
				else case (chk_k)
					K_FLINE: xvec = VEC_FLINE;
					K_ILL:   xvec = VEC_ILL;
					K_UNIMP, K_FMOVECR: begin
						xvec = VEC_FLINE; xfmt = 4'd2; xnext = 1'b1; xaddr = 32'd0;
					end
					K_EA60:  xvec = VEC_UNIMPEA;
					K_PK: begin
						xvec = VEC_UNSUP; xfmt = 4'd2; xnext = 1'b1; xaddr = 32'd0;
					end
					K_UNIMPM, K_PKM: if (eal) begin
						xvec = (chk_k == K_PKM) ? VEC_UNSUP : VEC_FLINE;
						xfmt = 4'd2; xnext = 1'b1; xaddr = dfr_addr;
					end
					default: if (fuse) hold = 1'b1;    // dispatching this cycle
				endcase
			end
			FC_DISP: begin
				if (ocl == 3'b011) begin
					// a store: its outcome first; its exception comes from END
					if (!done_q) hold = 1'b1;
					if (ea_dn) begin
						case (fmt)
							3'd4:    res_g = {bv[31:16], f_dout[95:80]};
							3'd6:    res_g = {bv[31:8], f_dout[95:88]};
							default: res_g = f_dout[95:64];
						endcase
						dkill = sx_kill;
					end
					else case (fmt)
						3'd4:    res_g = {16'd0, f_dout[95:80]};
						3'd6:    res_g = {24'd0, f_dout[95:88]};
						default: res_g = f_dout[95:64];
					endcase
				end
				else if (go && f_unimp) begin
					xvec = VEC_FLINE; xfmt = 4'd2; xnext = 1'b1;
					xaddr = eav ? eaa : 32'd0;
				end
				// a datatype trap: format $0, the NEXT PC and the address
				// register updated ((An)+/-(An) done: the M68060SP takes the
				// operand from the frame and does not touch An, table 6-10)
				else if (go && f_unsupp) begin
					xvec = VEC_UNSUP; xnext = 1'b1; xcommit = 1'b1;
				end
				else if (!(go && (f_accepted || f_done || f_pdone || f_excreq))) hold = 1'b1;
			end
			FC_GET: res_g = (imm[1:0] == 2'd1) ? get_q[63:32] : get_q[31:0];
			FC_EAL: if (dfr == K_DFPM) begin
				xvec = VEC_FLINE; xfmt = 4'd4; xnext = 1'b1; xaddr = dfp_addr;
			end
			else if (dfr != K_NONE) begin
				xvec = (dfr == K_PKM) ? VEC_UNSUP : VEC_FLINE;
				xfmt = 4'd2; xnext = 1'b1; xaddr = dfr_addr;
			end
			FC_END: begin
				if (sx_v) begin
					xvec = sx_vec; xfmt = sx_fmt; xnext = 1'b1; xaddr = sx_addr;
					xcommit = sx_commit;
				end
			end
			FC_CRR: begin
				res_g   = f_crrd;
				dkill = !cr_slots[imm[1:0]];
				if (!crr_wait) hold = 1'b1;
			end
			FC_LIST: res_g = (ea_pd) ? -{25'd0, l_bytes} : {25'd0, l_bytes};
			FC_MVR: begin
				res_g = mv_rev ? f_fmrd[31:0] : f_fmrd[95:64];
				if (!mvr_wait) hold = 1'b1;
			end
			FC_COND, FC_DBCC: begin
				logic [5:0] pred;
				logic c;
				logic [15:0] disp;
				pred = opw[5:0];
				c = fp_cond(pred, f_cc);
				disp = target[15:0] - pc[15:0] - 16'd4;
				if (dfr == K_DFPM) begin
					// FScc <mem>, the FPU disabled: its operand's address
					xvec = VEC_FLINE; xfmt = 4'd4; xnext = 1'b1; xaddr = ea;
				end
				else if (!is_bcc) begin
					// FScc, FDBcc, FTRAPcc: unimplemented on the 68060.  The
					// frame's address: FScc's operand address (none for Dn),
					// FDBcc's extension word and displacement, FTRAPcc none
					xvec = VEC_FLINE; xfmt = 4'd2; xnext = 1'b1;
					xaddr = is_fdbcc ? {ext, disp} : (is_cc && eam >= 3'd2 && sub == FC_COND &&
					         !(eam == 3'd7 && ear >= 3'd2)) ? ea : 32'd0;
				end
				else if (pred[4] && f_cc[0] && f_bsun_en) begin
					xvec = VEC_BSUN;
				end
				else taken = c;
			end
			FC_SV0: begin
				// (FSAVE takes no exception: an exception state is saved)
				if (bg) hold = 1'b1;
				res_g = ea_pd ? -32'd12 : 32'd12;
			end
			FC_SVW: case (imm[3:2])
				2'd0:    res_g = {f_xop[95:80], frame_fmt(sv_kind), 5'd0, sv_v};
				2'd1:    res_g = f_xop[63:32];
				default: res_g = f_xop[31:0];
			endcase
			FC_RS0: begin
				if (bg) hold = 1'b1;
				res_g = 32'd12;
				if (!rs_ok) xvec = VEC_FMTERR;
			end
			default: ;
		endcase
	end
end

// the result, by the sub-operation only: EX takes it when the uop
// completes, so it need not wait for the hold's conditions (ex_v, safe,
// the pipeline): those stay off the result's path to the register file
always_comb begin
	res = 32'd0;
	case (sub)
		FC_DISP: if (ocl == 3'b011) begin
			if (ea_dn) case (fmt)
				3'd4:    res = {bv[31:16], f_dout[95:80]};
				3'd6:    res = {bv[31:8], f_dout[95:88]};
				default: res = f_dout[95:64];
			endcase
			else case (fmt)
				3'd4:    res = {16'd0, f_dout[95:80]};
				3'd6:    res = {24'd0, f_dout[95:88]};
				default: res = f_dout[95:64];
			endcase
		end
		FC_GET:  res = (imm[1:0] == 2'd1) ? get_q[63:32] : get_q[31:0];
		FC_CRR:  res = f_crrd;
		FC_LIST: res = ext_q[11] ? lst_dyn(opw_q, av[7:0]) : lst_q;
		FC_MVR:  res = mv_rev ? f_fmrd[31:0] : f_fmrd[95:64];
		FC_SV0:  res = ea_pd ? -32'd12 : 32'd12;
		FC_SVW:  case (imm[3:2])
			2'd0:    res = {f_xop[95:80], frame_fmt(sv_kind), 5'd0, sv_v};
			2'd1:    res = f_xop[63:32];
			default: res = f_xop[31:0];
		endcase
		FC_RS0:  res = 32'd12;
		default: ;
	endcase
end
// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && ex_v && res_g != res && res_g != 32'd0) begin
		$display("FAIL: fpif result %h, the gated one %h (sub %0d)", res, res_g, sub);
		$finish;
	end
// synthesis translate_on

//--------------------------------------------------------------------------
// sequential
//--------------------------------------------------------------------------
wire act = ex_v && (safe || nosafe);

// the source and destination registers as they will be next cycle (CHK
// with DISP, DISP, the MVR read): the FPU's register-ready flags are
// selected by them ahead, into flip-flops (f_aok, f_bok), so its dispatch
// -- pdone, and with it the core's stall path -- starts from those
// (and the operation's class, opmode and format: the FPU registers whether
// the request can go into its pipeline from them, a cycle ahead)
logic [2:0] n_srcr, n_dstr, n_class, n_fmt;
logic [6:0] n_opm;
always_comb begin
	n_srcr  = f_srcr;
	n_dstr  = f_dstr;
	n_class = f_class;
	n_opm   = f_opm;
	n_fmt   = f_fmt;
	if (!nreset) begin
		n_srcr = '0; n_dstr = '0; n_class = '0; n_opm = '0; n_fmt = '0;
	end
	else if (act) case (sub)
		FC_CHK: if (fuse && !go && !(bg && !f_end) && !chk_pend && chk_k == K_NONE && !dfp) begin
			n_srcr  = ext[12:10];
			n_dstr  = ext[9:7];
			n_class = ocl;
			n_opm   = opm;
			n_fmt   = fmt;
		end
		FC_DISP: if (!go) begin
			n_srcr  = (ocl == 3'b011) ? ext[9:7] : ext[12:10];
			n_dstr  = ext[9:7];
			n_class = ocl;
			n_opm   = opm;
			n_fmt   = fmt;
		end
		FC_MVR: if (!mvr_wait) n_srcr = cur_reg;
		default: ;
	endcase
end

always_ff @(posedge clk) begin
	if (!nreset) begin
		opw_q <= '0; ext_q <= '0; fsr_q <= 1'b0; lst_q <= '0;
		bg <= 1'b0; pend <= 1'b0; pend_vec <= '0; fresh <= 1'b0;
		go <= 1'b0; done_q <= 1'b0; eaa <= '0; eav <= 1'b0;
		sx_v <= 1'b0; sx_vec <= '0; sx_fmt <= '0; sx_addr <= '0; sx_kill <= 1'b0;
		sx_commit <= 1'b0; dfr <= K_NONE;
		list <= '0; mv_slots <= '0; mv_lsb <= 1'b0; mv_rev <= 1'b0; mv_st <= 1'b0; mv_m1 <= 1'b0;
		slot <= '0; mvr_wait <= 1'b0; crr_wait <= 1'b0; get_q <= '0;
		sv_kind <= '0; sv_v <= '0; rs_kind <= '0; rs_v <= '0;
		f_req <= 1'b0; f_crwe <= 1'b0; f_iawe <= 1'b0; f_bsun <= 1'b0; f_fmwe <= 1'b0; f_rst <= 1'b0;
		f_rest_idle <= 1'b0; f_uack <= 1'b0; f_fsclr <= 1'b0;
		f_class <= '0; f_fmt <= '0; f_srcr <= '0; f_dstr <= '0; f_fmsel <= '0; f_opm <= '0;
		f_aok <= 1'b0; f_bok <= 1'b0;
		f_din <= '0; f_dnice <= 1'b0; f_crsel <= '0; f_crwd <= '0; f_iapc <= '0;
		f_rwe <= 1'b0; rs_w0 <= '0; rs_w1 <= '0; f_rwd <= '0;
	end
	else begin
		f_req <= 1'b0; f_crwe <= 1'b0; f_iawe <= 1'b0; f_bsun <= 1'b0; f_fmwe <= 1'b0;
		f_rwe <= 1'b0;
		f_rst <= 1'b0; f_rest_idle <= 1'b0; f_uack <= 1'b0; f_fsclr <= 1'b0;
		fresh     <= 1'b0;

		// a released operation: completion, or its exception pending for
		// the next FPU instruction (the FPU keeps the operand)
		if (bg && f_done) bg <= 1'b0;
		if (bg && f_excreq) begin
			bg        <= 1'b0;
			pend      <= 1'b1;
			pend_vec  <= f_excvec;
		end

		f_srcr  <= n_srcr;
		f_dstr  <= n_dstr;
		f_class <= n_class;
		f_opm   <= n_opm;
		f_fmt   <= n_fmt;
		f_aok  <= f_okvn[n_srcr];
		f_bok  <= f_okvn[n_dstr];

		if (act) case (sub)
			FC_CHK: if (fuse && !go && !(bg && !f_end) && !chk_pend && chk_k == K_NONE && !dfp) begin
				// FPm to FPn: CHK's latching and DISP's request at once
				opw_q   <= opw;
				fsr_q   <= is_fsave || is_frest;
				lst_q   <= lst_of(opw, ext);
				ext_q   <= ext;
				eav     <= 1'b0;
				sx_v    <= 1'b0;
				sx_kill <= 1'b0;
				done_q  <= 1'b0;
				dfr     <= K_NONE;
				go      <= 1'b1;
				f_req   <= 1'b1;
				f_iawe  <= 1'b1;
				f_iapc  <= pc;
				f_din   <= din_of(fmt, av, bv, latch);
				f_dnice <= nice_mem(din_of(fmt, av, bv, latch), fmt);
				fresh   <= 1'b1;
			end
			else if (fuse && go) begin
				// the operation's outcome: a datatype trap or an arithmetic
				// exception puts the FPU in the EXCP state
				if (f_unsupp) begin pend <= 1'b1; pend_vec <= VEC_UNSUP; end
				if (f_excreq) begin pend <= 1'b1; pend_vec <= f_excvec; end
				if (adv) begin
					go <= 1'b0;
					if (f_accepted && !f_done && !f_excreq) bg <= 1'b1;
				end
			end
			else if (adv) begin
				opw_q <= opw;
				fsr_q <= is_fsave || is_frest;
				lst_q <= lst_of(opw, ext);
				ext_q <= ext;
				// (an immediate operand has no address: its frames, EA 0)
				eav   <= eal && !ea_imm;
				if (eal) eaa <= ea;
				sx_v  <= 1'b0;
				sx_kill <= 1'b0;
				go    <= 1'b0;
				done_q <= 1'b0;
				dfr   <= K_NONE;
				if (dfp) begin
					// FPU disabled: nothing reaches the FPU; the trap is at
					// the EA uop when the operand address comes later
					if (!eal && (dfp_mem || dfp_scc) && !(chk_k == K_FLINE || chk_k == K_ILL)) dfr <= K_DFPM;
				end
				else if (!chk_pend) begin
					// an implemented instruction leaves the NULL state
					// (MC68060UM 6.7; WinUAE fpuop_arithmetic: fpu_state = 1),
					// the data movements too (FMOVE of a control register,
					// FMOVEM); FNOP and the conditionals stay NULL
					if (is_gen && chk_k == K_NONE) f_rest_idle <= 1'b1;
					if (chk_ia) begin
						f_iawe <= 1'b1;
						f_iapc <= pc;
					end
					case (chk_k)
						// unimplemented, packed: the IDLE state, the operand
						// zero, and (not FMOVECR) the exception byte clear
						K_UNIMP, K_PK: begin f_uack <= 1'b1; f_fsclr <= 1'b1; end
						K_FMOVECR: f_uack <= 1'b1;
						K_UNIMPM, K_PKM: if (eal) begin
							f_uack <= 1'b1; f_fsclr <= 1'b1;
						end
						else dfr <= chk_k;
						default: ;
					endcase
				end
			end
			FC_EAL: begin
				// an immediate operand has no address (its frames: EA 0)
				eaa <= ea;
				eav <= !ea_imm;
				if (adv && dfr != K_NONE) begin
					if (dfr != K_DFPM) begin f_uack <= 1'b1; f_fsclr <= 1'b1; end
					dfr    <= K_NONE;
				end
			end
			FC_DISP: begin
				if (!go) begin
					go      <= 1'b1;
					f_req   <= 1'b1;
					f_iawe  <= 1'b1;
					f_iapc  <= pc;
					f_din   <= din_of(fmt, av, bv, latch);
					f_dnice <= nice_mem(din_of(fmt, av, bv, latch), fmt);
				end
				else if (ocl == 3'b011) begin
					if (f_unimp || f_unsupp || f_done) begin
						done_q <= 1'b1;
						get_q  <= f_dout;
					end
					if (f_unimp) begin
						sx_v <= 1'b1; sx_vec <= VEC_FLINE; sx_fmt <= 4'd2;
						sx_addr <= eav ? eaa : 32'd0; sx_kill <= 1'b1; sx_commit <= 1'b0;
					end
					else if (f_unsupp) begin
						// a denormal or unnormal register: nothing stored.  The
						// M68060SP stores the result itself at the frame's EA
						// (fout): for B/W/L/S/D the address register update
						// stands; for X the EA of -(An) is An + 8 and An stays
						// (_calc_ea_fout)
						sx_v <= 1'b1; sx_vec <= VEC_UNSUP; sx_fmt <= 4'd3;
						sx_addr <= ea_dn ? 32'd0 : (eaa + ((ea_pd && fmt == 3'd2) ? 32'd8 : 32'd0));
						sx_kill <= 1'b1; sx_commit <= (fmt != 3'd2);
						pend <= 1'b1; pend_vec <= VEC_UNSUP;
					end
					else if (f_done && f_excreq) begin
						// the destination is written as if the trap were
						// disabled, then the post-instruction exception
						sx_v <= 1'b1; sx_vec <= f_excvec; sx_fmt <= 4'd3;
						sx_addr <= ea_dn ? 32'd0 : eaa; sx_kill <= 1'b0; sx_commit <= 1'b1;
						pend <= 1'b1; pend_vec <= f_excvec;
					end
				end
				else begin
					if (f_unsupp) begin pend <= 1'b1; pend_vec <= VEC_UNSUP; end
					if (f_excreq) begin pend <= 1'b1; pend_vec <= f_excvec; end
					if (adv && f_accepted && !f_done && !f_excreq) bg <= 1'b1;
				end
			end
			FC_CRR: begin
				// the FPU reads the selected register combinationally:
				// select, then take it the next cycle
				if (adv) crr_wait <= 1'b0;
				else begin
					f_crsel  <= crsel_of(imm[1:0]);
					crr_wait <= 1'b1;
				end
			end
			FC_CRW: if (adv) begin
				f_crsel <= crsel_of(immb[1:0]);
				f_crwe  <= cr_slots[immb[1:0]];
				f_crwd  <= av;
			end
			FC_LIST: if (adv) begin
				// the 68060 ignores the mode field: -(An) stores FP7 first
				// (list bit 0 = FP7), every other form FP0 first (bit 7)
				list   <= l_now;
				for (int k = 0; k < 8; k++)
					mv_slots[k] <= l_now[slot_bit(3'(k), ext[13] && ea_pd)];
				mv_st  <= ext[13];
				mv_m1  <= !ea_pd;
				mv_lsb <= ext[13] && ea_pd;
				mv_rev <= 1'b0;
				slot   <= 3'd0;
			end
			FC_MVR: begin
				if (!mvr_wait) begin
					// the raw image comes through the source-register port
					mvr_wait <= 1'b1;
				end
				else if (adv) begin
					get_q    <= mv_rev ? {f_fmrd[31:0], f_fmrd[63:32], f_fmrd[95:64]} : f_fmrd;
					mvr_wait <= 1'b0;
					slot     <= slot + 3'd1;
				end
			end
			FC_MVW: if (adv) begin
				if (cur_on) begin
					f_fmsel <= cur_reg;
					f_fmwe  <= 1'b1;
					f_din   <= {av, bv, latch};
				end
				slot <= slot + 3'd1;
			end
			FC_COND, FC_DBCC: if (adv && is_bcc) begin
				// a signaling predicate on unordered sets BSUN; an enabled
				// BSUN is the EXCP state (taken again until FSAVE)
				if (opw[4] && f_cc[0]) begin
					f_bsun <= 1'b1;
					if (f_bsun_en) begin pend <= 1'b1; pend_vec <= VEC_BSUN; end
				end
			end
			FC_END: if (adv) begin
				sx_v <= 1'b0; sx_kill <= 1'b0;
				// FSAVE leaves the EXCP state (the exception is in the frame)
				if (is_fsave) pend <= 1'b0;
				if (is_frest) case (rs_kind)
					2'd0: begin f_rst <= 1'b1; pend <= 1'b0; end
					2'd1: begin f_rest_idle <= 1'b1; pend <= 1'b0; end
					default: begin
						// EXCP: its exception, for the next FPU instruction
						f_rest_idle <= 1'b1;
						pend     <= 1'b1;
						pend_vec <= (rs_v == 3'd7) ? VEC_UNSUP : {5'b00110, rs_v};
					end
				endcase
			end
			FC_SV0: if (adv) begin
				sv_kind <= sv_now;
				sv_v    <= (sv_now == 2'd2) ? pend_vc : 3'd0;
			end
			FC_RS0: if (adv) begin
				rs_kind <= rs_now;
				rs_v    <= av[2:0];
				rs_w0   <= av[31:16];
			end
			FC_RSW: if (adv) begin
				// words 1 and 2: the second is the last read, and with it
				// the whole operand is written
				if (immb[3:2] == 2'd1) rs_w1 <= av;
				else begin
					f_rwe <= 1'b1;
					f_rwd <= av;
				end
			end
			default: ;
		endcase
		if (!(ex_v && sub == FC_CRR)) crr_wait <= 1'b0;
		// a request is done with when its uop leaves (a fused CHK may follow)
		if (act && adv && sub == FC_DISP) go <= 1'b0;
		if (kill) begin
			go <= 1'b0; mvr_wait <= 1'b0; crr_wait <= 1'b0;
		end
	end
end

endmodule
