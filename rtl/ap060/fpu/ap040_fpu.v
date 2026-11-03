//--------------------------------------------------------------------------//
// AP040 - MC68040 compatible CPU                                           //
//                                                                          //
// ap040_fpu.v - on-chip FPU (milestone H)                                  //
//                                                                          //
// Programming model: FP0-FP7 in extended precision (96-bit memory image,   //
// 80 significant bits), FPCR (mode + exception enables), FPSR (condition   //
// codes, quotient, exception and accrued bytes), FPIAR.                    //
//                                                                          //
// Implemented hardware subset: data movement and B/W/L/S/D/X conversion,  //
// FABS/FNEG/FTST/FCMP, and iterative FADD/FSUB/FMUL/FDIV/FSQRT with FPCR   //
// precision/rounding, FPSR status/accrual, signaling NaNs and enabled      //
// arithmetic-exception vectors. Single/double stores generate gradual      //
// underflow; unsupported denormal/unnormal inputs take vector 55.          //
//                                                                          //
// 68060 rules (MC68060UM section 6): the core traps the unimplemented      //
// instructions, FMOVECR and packed decimal before dispatch; denormal and  //
// unnormal operands take vector 55; OVFL and UNFL always trap; the state  //
// frame is three long words (NULL, IDLE, EXCP), the exception operand in  //
// fstate_et.  FINT and FINTRZ are in hardware.                            //
//                                                                          //
// The core owns instruction decode, effective addresses and memory         //
// transfers; operands arrive left-aligned in a 96-bit window. FMOVEM       //
// traffic uses the raw register port (fm_*), architecturally exact bits    //
// with no condition code or rounding side effects.                         //
//                                                                          //
// The state machine closes a 120 MHz clock: each state does one carry      //
// chain, shift or flag decision, the arithmetic spread over more states   //
// (see FSM below); the optional pipeline (PIPE) keeps its 60 MHz stages.  //
//                                                                          //
// All state advances only when ce is high (clkena discipline).             //
//--------------------------------------------------------------------------//

`include "ap040_defs.svh"

module ap040_fpu
#(
	// the arithmetic pipeline (FMOVE/FADD/FSUB/FMUL on ordinary operands);
	// 0: every operation through the sequential state machine
	parameter PIPE = 1
)
(
	input             clk,
	input             nreset,
	input             ce,

	// command port: pulse req with the fields valid; done pulses on
	// completion, unimp pulses instead when the op is not in hardware
	input             req,
	input       [2:0] op_class,    // extension word [15:13]
	input       [6:0] opmode,      // extension word [6:0]
	input       [2:0] src_fmt,     // extension word [12:10] (opclass 2/3)
	input       [2:0] src_r,       // FPm
	input       [2:0] dst_r,       // FPn
	input      [95:0] din,         // memory operand, left aligned
	input             din_nice,    // din is an ordinary operand for the
	                               // pipeline (nice_mem: the interface forms
	                               // it as it registers din)
	input       [2:0] din_cls,     // with sel_x: din's class by src_fmt (din_class,
	                               // formed outside as din is registered)
	output reg        done,
	// the operation has passed operand classification: unimp/unsupp can no
	// longer occur, only completion or an enabled arithmetic exception.
	// The core uses this to run register-destination arithmetic in the
	// background while integer execution continues.
	output            accepted,
	output            wb_ok,       // F_WB this cycle, no exception (a register:
	                               // set only where none can be pending)
	// registered summaries for the core's holds, one flip-flop each
	output reg        known,       // unimp | unsupp | accepted | done | exc_req
	output reg        end_ok,      // (done | wb_ok) && !exc_req
	output reg        unimp,       // unimplemented instruction -> vector 11
	output reg        unsupp,      // unsupported data type -> vector 55
	output reg        exc_req,       // enabled arithmetic exception
	output reg [7:0]  exc_vec,
	output reg [95:0] dout,        // store result, left aligned

	output      [3:0] fpcc,        // FPSR condition codes {N,Z,I,NAN}

	// control registers (FMOVE/FMOVEM of FPCR/FPSR/FPIAR run in the core)
	input       [1:0] cr_sel,      // 0 FPIAR, 1 FPSR, 2 FPCR
	input             cr_we,
	input      [31:0] cr_wdata,
	output     [31:0] cr_rdata,
	input             bsun_req,     // signaling conditional on unordered
	output            bsun_enable,

	// FPIAR update on dispatch of an FP instruction (core provides PC)
	input             ia_we,
	input      [31:0] ia_wdata,

	// raw register port for FMOVEM (X format image, no side effects)
	input       [2:0] fm_sel,
	input             fm_we,
	input      [95:0] fm_wdata,
	output     [95:0] fm_rdata,

	// FSAVE/FRESTORE state: NULL until an FPU instruction runs
	output reg        fpu_used,    // 0: NULL frame, 1: IDLE or exception frame
	output            pdone,       // the request went into the pipeline this
	                               // cycle (done, combinationally; done itself
	                               // pulses only for the state machine)
	output      [7:0] okv_next,    // the register-ready flags next cycle, and
	input             sel_x,       // those of src_r/dst_r selected outside
	input             aok_x,       // into flip-flops, from the registers'
	input             bok_x,       // next values (else selected here)
	input       [6:0] opmode_n,    // with sel_x: opmode, op_class and src_fmt
	input       [2:0] op_class_n,  // as they will be next cycle (the static
	input       [2:0] src_fmt_n,   // pipeline eligibility is registered)
	// the registers' flags next cycle, {valid, unsupported, class tag[1:0]}
	// per register (register r in bits 4r+3:4r), and with sel_x those of
	// src_r and dst_r selected outside into flip-flops: the dispatch decides
	// and selects the invalid-register default from them
	output     [31:0] rfl_next,
	input       [3:0] sfl_x,
	input       [3:0] dfl_x,
	output            pbusy,       // pipelined operations in flight: FPU state
	                               // (registers, FPSR, condition codes) is not
	                               // current until they complete
	// the EXCP frame's exception operand: the source operand of the last
	// exception (FMOVEM image), or the one an FRESTORE loaded
	output reg [95:0] fstate_et,
	input             frestore_idle,   // FRESTORE of an IDLE or EXCP frame
	input             frestore_we,     // FRESTORE: the frame's exception operand,
	input      [79:0] frestore_wd,     // once every word is read: exponent, mantissa
	input             unimp_ack,       // the core trapped an unimplemented instruction or
	                                   // a packed operand: IDLE state, operand zero,
	input             unimp_keep,      // ... an unimplemented instruction: the NULL state stays
	input             fs_clr,          // and (not FMOVECR) the exception byte cleared
	input             fp_reset     // FRESTORE of a NULL frame
);

//---------------------------------------------------------------------------
// architectural state
//---------------------------------------------------------------------------

// FP registers as the 80 significant bits: {sign, exp[14:0], man[63:0]}.
// The two command-time read views are mirrored inside a small MLAB regfile.
wire [79:0] fr_src_raw;
wire [79:0] fr_dst_raw;
reg   [7:0] fr_valid;
// each register's unsupported data type (denormal/unnormal: the dispatch's
// datatype check), kept beside it as it is written: the check reads a flag,
// not a classification of the register file's read data
reg   [7:0] fr_unsup;
// ... and its class (unpack_x's tag), so the dispatch decides from flags and
// not from a classification of the register file's read data
reg   [1:0] fr_tag [0:7];
// src_r's and dst_r's flags {valid, unsupported, tag}: flip-flops selected
// outside from rfl_next a cycle ahead (sel_x), else selected here
wire  [3:0] sfl_l = {fr_valid[src_r], fr_unsup[src_r], fr_tag[src_r]};
wire  [3:0] dfl_l = {fr_valid[dst_r], fr_unsup[dst_r], fr_tag[dst_r]};
wire  [3:0] sfl   = sel_x ? sfl_x : sfl_l;
wire  [3:0] dfl   = sel_x ? dfl_x : dfl_l;
// Simulation/debug mirrors retain the long-standing hierarchical names used
// by the AP68040 benches.  The live datapath does not read them, so synthesis
// removes these arrays and their update logic.
reg        fr_s [0:7];
reg [14:0] fr_e [0:7];
reg [63:0] fr_m [0:7];

// Reset and FRESTORE NULL invalidate the payload instead of distributing a
// reset across 640 data bits.  Only these two command-time read views remain;
// FMOVEM stores share the source view and all later FPn uses are shadowed.
wire        fr_src_s = sfl[3] ? fr_src_raw[79]    : 1'b0;
wire [14:0] fr_src_e = sfl[3] ? fr_src_raw[78:64] : 15'h7FFF;
wire [63:0] fr_src_m = sfl[3] ? fr_src_raw[63:0]  : 64'hFFFF_FFFF_FFFF_FFFF;
wire        fr_dst_s = dfl[3] ? fr_dst_raw[79]    : 1'b0;
wire [14:0] fr_dst_e = dfl[3] ? fr_dst_raw[78:64] : 15'h7FFF;
wire [63:0] fr_dst_m = dfl[3] ? fr_dst_raw[63:0]  : 64'hFFFF_FFFF_FFFF_FFFF;
wire        fr_src_unsup = sfl[3] && sfl[2];
// synthesis translate_off
always @(posedge clk)
	if (nreset && sel_x && (sfl_x != sfl_l || dfl_x != dfl_l)) begin
		$display("FAIL: the outside selection of the register flags %h %h, src %0d dst %0d: %h %h",
		         sfl_x, dfl_x, src_r, dst_r, sfl_l, dfl_l);
		$finish;
	end
// synthesis translate_on

reg [31:0] fpcr;                  // [15:8] enables, [7:6] prec, [5:4] rnd
reg [31:0] fpsr;                  // [27:24] cc, [23:16] quot, [15:8] exc, [7:3] aexc
reg [31:0] fpiar;

assign fpcc = fpsr[27:24];
        // {N, Z, I, NAN}

wire [1:0] rnd_mode = fpcr[5:4];  // 00 RN, 01 RZ, 10 RM, 11 RP

assign cr_rdata = (cr_sel == 2'd0) ? fpiar :
                  (cr_sel == 2'd1) ? fpsr : fpcr;
assign bsun_enable = fpcr[15];

// Raw FMOVEM image: X format memory layout {s, e, 16'b0, m}.  Stores reuse
// the normal source-register read port; the core selects src_r one cycle
// before consuming fm_rdata.  fm_sel remains the independent restore port.
assign fm_rdata = {fr_src_s, fr_src_e, 16'd0, fr_src_m};

//---------------------------------------------------------------------------
// unpacked working format
//   value = (-1)^s * man * 2^(exp-16383), man[63] = integer bit
//   tag: 00 number (normalized here), 01 zero, 10 infinity, 11 NaN
//---------------------------------------------------------------------------

localparam T_NUM  = 2'd0;
localparam T_ZERO = 2'd1;
localparam T_INF  = 2'd2;
localparam T_NAN  = 2'd3;

// {s, e[16:0], m[63:0], t[1:0]} = 84 bits
// the opmodes F_EXEC sends to F_BIN (its ex_bin), and their op_kind
function bin_op;
	input [6:0] op;
	case (op)
		7'h22, 7'h62, 7'h66, 7'h28, 7'h68, 7'h6C, 7'h23, 7'h63, 7'h67, 7'h27,
		7'h20, 7'h60, 7'h64, 7'h24: bin_op = 1'b1;
		default: bin_op = 1'b0;
	endcase
endfunction
function [3:0] bin_kind;
	input [6:0] op;
	bin_kind = (op == 7'h23 || op == 7'h27 || op == 7'h63 || op == 7'h67) ? 4'd2 :
	           (op == 7'h20 || op == 7'h24 || op == 7'h60 || op == 7'h64) ? 4'd3 : 4'd1;
endfunction

function [83:0] unpack_x;
	input        s;
	input [14:0] e;
	input [63:0] m;
	reg    [1:0] t;
	begin
		if (e == 15'h7FFF) t = (m[62:0] != 63'd0) ? T_NAN : T_INF;
		else if (m == 64'd0) t = T_ZERO;
		else t = T_NUM;   // unnormals arrive here and are normalized below
		unpack_x = {s, {2'd0, e}, m, t};
	end
endfunction

// Only TRUE denormals (zero exponent, integer bit clear, nonzero
// fraction) and true unnormals (nonzero finite exponent, integer bit
// clear, nonzero mantissa) take the unimplemented-data-type route.
// PSEUDO-DENORMALS -- zero exponent with the integer bit SET -- are
// legal operands the hardware computes with directly, using the RAW
// exponent field (floatx80_is_denormal requires the integer bit clear;
// hardware cputest FDIV/FDADD with $0000-8xxx operands executes).
// Unnormal ZEROS (nonzero exponent, mantissa zero) behave as zeros.
function unsupported_x;
	input [14:0] e;
	input [63:0] m;
	begin
		unsupported_x = ((e == 15'd0) && !m[63] && (m[62:0] != 0)) ||
		                ((e != 15'd0) && (e != 15'h7FFF) && !m[63] &&
		                 (m != 64'd0));
	end
endfunction

function is_snan_x;
	input [14:0] e;
	input [63:0] m;
	begin
		is_snan_x = (e == 15'h7FFF) && (m[62:0] != 63'd0) && !m[62];
	end
endfunction

// count leading zeros of a 64-bit value (fixed encoder, no shifters)
// leading zeros of a 64-bit value (64 when zero): a tree, pairs merged
// level by level (the upper half's count, or the lower's with the upper
// half's size added when the upper half is empty)
function [6:0] clz64;
	input [63:0] v;
	reg        val [0:63];
	reg  [5:0] cnt [0:63];
	integer    k, i;
	begin
		for (i = 0; i < 64; i = i + 1) begin val[i] = v[i]; cnt[i] = 6'd0; end
		for (k = 1; k <= 6; k = k + 1)
			for (i = 0; i < (64 >> k); i = i + 1) begin
				cnt[i] = val[2*i+1] ? cnt[2*i+1] : (cnt[2*i] | (6'd1 << (k - 1)));
				val[i] = val[2*i+1] | val[2*i];
			end
		clz64 = val[0] ? {1'b0, cnt[0]} : 7'd64;
	end
endfunction

// 68040 state-frame tags (Table 9-15).  Register operands retain their raw
// extended image in the frame even when it is an unnormal value.
function [2:0] frame_tag_x;
	input [14:0] e;
	input [63:0] m;
	begin
		if (m == 64'd0 && e != 15'h7FFF) frame_tag_x = 3'd1;       // zero
		else if (unsupported_x(e, m))    frame_tag_x = 3'd4;       // X denorm/unnormal
		else if (e == 15'h7FFF && m[62:0] != 0) frame_tag_x = 3'd3; // NaN
		else if (e == 15'h7FFF)          frame_tag_x = 3'd2;       // infinity
		else                              frame_tag_x = 3'd0;       // normal
	end
endfunction

//---------------------------------------------------------------------------
// FSM
//---------------------------------------------------------------------------
// The state machine runs at 120 MHz: a state does one thing -- a carry
// chain, a shift, or a decision on flags that a previous state registered
// -- and the arithmetic is spread over states accordingly:
//   dispatch        decided from per-register class flags kept beside the
//                   register file, not from a classification of its read data
//   binary ops      F_BIN0 registers the operands' relations and the special
//                   case outcome (free-running units beside the state
//                   machine), F_BIN acts on the outcome
//   alignment       F_SHR shifts right by whole bytes, F_SHR2 by the rest
//   add/subtract    F_SHR2 forms the sum as it aligns, F_ADDN its carry (and
//                   for a difference the leading-zero count; F_NSH takes an
//                   exact zero)
//   normalization   the leading-zero count in one state, F_NSH shifts
//   multiply        DSP partial products, their sum in three registered steps
//   divide          two quotient bits a cycle, from 4r - d, 4r - 2d and
//                   4r - 3d formed side by side
//   square root     one root bit a cycle
//   rounding        F_ROUND forms the increment and the range compares,
//                   F_RND2 selects
//   stores          rounding, then the encoding, in states of their own
// The registers' input selects are kept narrow: the state is one-hot
// (fst1h) beside fst, a writer of a wide register writes it whatever its
// branch decides when the value is a don't-care otherwise, the operands'
// significand (a_m) and the arithmetic's result (z_m) are separate
// registers, and decisions use flags registered a state earlier.
// Every result and status bit is the single-cycle steps' (the WinUAE
// SoftFloat vectors, the cputest corpus and tb_fpu_pipe check it).

localparam F_IDLE   = 5'd0;
localparam F_SRC    = 5'd1;   // classify/convert the memory operand
localparam F_NCP    = 5'd2;   // an integer source's normalized significand to a_m
localparam F_EXEC   = 5'd3;   // move/abs/neg/tst/cmp/arith dispatch
localparam F_WB     = 5'd4;   // register writeback + condition codes
localparam F_SHR    = 5'd5;   // right shift with sticky: whole bytes
localparam F_PACKI  = 5'd6;   // integer store: the rounded magnitude
localparam F_BIN    = 5'd7;   // binary op: the outcome F_BIN0 registered
localparam F_BIN0   = 5'd8;   // binary op: operand relations, special cases
localparam F_INTS   = 5'd9;   // FINT/FINTRZ: the range checks, the shift set up
localparam F_MULT   = 5'd10;  // multiply: the product's pipeline
localparam F_DIVL   = 5'd11;  // divide loop
localparam F_SQRTL  = 5'd12;  // square root loop
localparam F_ADDN   = 5'd13;  // add/subtract result: carry, zero, leading zeros
localparam F_ROUND  = 5'd14;  // rounding: the increment and the range compares
localparam F_PACKS  = 5'd15;  // denormal single/double store packing
localparam F_UNFL   = 5'd16;  // gradual underflow at single/double precision
localparam F_STDONE = 5'd17;  // store completion: settled-status trap check
localparam F_INTR   = 5'd18;  // FINT/FINTRZ: round the shifted integer
localparam F_INTN   = 5'd19;  // FINT/FINTRZ: its leading zeros
localparam F_SHR2   = 5'd20;  // right shift with sticky: the remaining 0-7 bits
localparam F_RND2   = 5'd21;  // rounding: overflow, underflow, the result
localparam F_NSH    = 5'd22;  // normalize: the left shift
localparam F_PKR    = 5'd23;  // single/double store: the rounded encoding
localparam F_PACKI2 = 5'd24;  // integer store: range check
localparam F_PACKI3 = 5'd25;  // integer store: assembly

reg  [4:0] fst;
reg [25:0] fst1h;             // the same state, one-hot (the selects' flip-flops)
reg        lpf;               // a loop's last cycle (F_MULT, F_DIVL, F_SQRTL)
// x_kill as F_WB will see it, registered: set where an operation that ends
// in F_WB records an enabled SNAN, OPERR or DZ, or an OVFL or UNFL (the
// exception byte was cleared at dispatch), so the register file's write
// enable -- and the registers' next flags the core selects from -- start
// from flip-flops
reg        wk;
reg        wbw;               // F_WB writes its result (fr_wb_we, a register)
reg        r_ct;              // FCMP or FTST: no writeback
reg  [5:0] r_rng;             // a register store's exponent range checks (F_SRC)
reg  [6:0] r_dcnt, r_icnt;    // ... and its shift counts
// synthesis translate_off
always @(posedge clk)
	if (nreset && ((fst == F_MULT && lpf != (loop_n == 7'd3)) || (fst == F_DIVL && lpf != (loop_n == 7'd34)) ||
	               (fst == F_SQRTL && lpf != (loop_n == 7'd66)))) begin
		$display("FAIL: FPU loop-end flag %b, state %0d count %0d", lpf, fst, loop_n);
		$finish;
	end
// synthesis translate_on
// synthesis translate_off
always @(posedge clk)
	if (nreset && fst1h !== (26'd1 << fst)) begin
		$display("FAIL: FPU one-hot state %b, the state %0d", fst1h, fst);
		$finish;
	end
// synthesis translate_on
// unimp/unsupp decisions are made in the dispatch cycle (register
// sources, still F_IDLE), during source conversion (F_SRC), and by the
// destination-operand checks in F_EXEC and F_BIN.  The arithmetic,
// rounding and writeback states are strictly past every such decision:
// from there on nothing but done or an enabled-exception exc_req can
// follow.
// (the alignment shift of an add runs after every datatype check: the
// operation is accepted as it starts)
// wb_ok: a register, set as the state machine enters F_WB on a path that
// cannot have raised OVFL or UNFL, with every FPCR enable clear -- then no
// exception can be taken there.  Otherwise it stays clear and the core
// waits for done, a cycle later.  (Checked in simulation.)
reg  wbok_r;
assign wb_ok = wbok_r;
// the normalizer's destination (F_NSH): an integer or denormal source
// (back to F_EXEC), an add/subtract result (on to F_ROUND), FINT's integer
// (on to F_WB)
localparam N_OPN = 2'd0, N_POST = 2'd1, N_FINT = 2'd2;
reg  [1:0] n_mode;
// accepted: a register kept with every state assignment (acc_r: the state
// it goes to is one of these), so the core's holds start from a flip-flop
// and not from a decode of the state register; checked in simulation
reg  [4:0] sh_ret;            // staged shifter return state
wire acc_dec = (fst == F_ADDN) || (fst == F_MULT) || (fst == F_WB) || (fst == F_UNFL) ||
               ((fst == F_SHR || fst == F_SHR2) && (sh_ret == F_ADDN || sh_ret == F_UNFL)) ||
               (fst == F_NSH && n_mode == N_POST) ||
               (fst == F_DIVL) || (fst == F_SQRTL) ||
               (fst == F_ROUND) || (fst == F_RND2);
reg  acc_r;
function acc_of;
	input [4:0] st;
	begin
		acc_of = (st == F_ADDN) || (st == F_MULT) || (st == F_DIVL) || (st == F_UNFL) ||
		         (st == F_SQRTL) || (st == F_ROUND) || (st == F_RND2);
	end
endfunction
assign accepted = acc_r;
// synthesis translate_off
always @(posedge clk)
	if (nreset && acc_r !== acc_dec) begin
		$display("FAIL: FPU accepted register %b, the state's %b (fst %0d)", acc_r, acc_dec, fst);
		$finish;
	end
always @(posedge clk)
	if (nreset && known !== (unimp || unsupp || acc_r || done || exc_req)) begin
		$display("FAIL: FPU known register %b disagrees with its terms (fst %0d)", known, fst);
		$finish;
	end
always @(posedge clk)
	if (nreset && end_ok !== ((done || wbok_r) && !exc_req)) begin
		$display("FAIL: FPU end_ok register %b disagrees with its terms (fst %0d)", end_ok, fst);
		$finish;
	end
always @(posedge clk)
	if (nreset && wbok_r && (fst != F_WB || x_any)) begin
		$display("FAIL: FPU wb_ok outside a clean F_WB (fst %0d, x_any %b)", fst, x_any);
		$finish;
	end
// synthesis translate_on

reg  [2:0] r_fmt, r_dst;
reg        r_ae7;           // accrued-IOP before this instruction (fault backout)
reg  [6:0] r_op;
reg [95:0] r_din;
// the opmode decoded at dispatch: F_SRC and the arithmetic states test these
// flags, not a decode of r_op -- a binary operation and its kind, a move,
// the FSUB family (the source sign folded), FSGLMUL/FSGLDIV, the rounding
// precision (FPCR is not written while an operation runs)
reg        r_bin, r_mov, r_fsub, r_sgl;
reg  [3:0] r_kind;
reg  [1:0] r_prec;
// the memory operand's class by its format (unpack_x's tags, or C_DEN for
// an unsupported data type), formed as din is latched
localparam C_DEN = 3'd4;
reg  [2:0] r_dcls;
// the memory operand's significand in the working format, by r_fmt: one
// bus (and one negator, of the integer left-aligned: the same bits as a
// byte or word negated in place) for every unpack of r_din into a_m.  A
// single or double's integer bit is its exponent's: set for a normal
// number, clear for zero, a denormal, infinity and a NaN
// (formed from din as the dispatch latches it: unp_m is a register; FINT's
// rounded integer goes there too, for the normalizer's count)
function [63:0] unp_of;
	input [95:0] d;
	input  [2:0] f;
	reg   [31:0] im;
	reg          hs, hd;
	begin
		// (each width negated on its own, then selected: no select in
		// front of the carry chain)
		im = (f == 3'd0) ? (d[95] ? (32'd0 - d[95:64]) : d[95:64]) :
		     (f == 3'd4) ? {(d[95] ? (16'd0 - d[95:80]) : d[95:80]), 16'd0} :
		                   {(d[95] ? (8'd0 - d[95:88]) : d[95:88]), 24'd0};
		hs = (d[94:87] != 8'd0) && (d[94:87] != 8'hFF);
		hd = (d[94:84] != 11'd0) && (d[94:84] != 11'h7FF);
		unp_of = (f == 3'd1) ? {hs, d[86:64], 40'd0} :
		         (f == 3'd5) ? {hd, d[83:32], 11'd0} :
		         (f == 3'd0 || f == 3'd4 || f == 3'd6) ? {im, 32'd0} : d[63:0];
	end
endfunction
reg  [63:0] unp_m;
// ... and its exponent in the working format by its class (F_SRC): an
// integer's bit position, a single's or double's rebiased exponent (all
// ones for infinity and NaN, zero for zero), an extended's field
function [16:0] lde_of;
	input [95:0] d;
	input  [2:0] f;
	input  [2:0] c;
	reg   [16:0] e;
	begin
		e = (f == 3'd5) ? ({6'd0, d[94:84]} + 17'd15360)    // -1023+16383
		                : ({9'd0, d[94:87]} + 17'd16256);   // -127+16383
		case (f)
			3'd0: lde_of = 17'd16383 + 17'd31;
			3'd4: lde_of = 17'd16383 + 17'd15;
			3'd6: lde_of = 17'd16383 + 17'd7;
			3'd1, 3'd5: lde_of = (c == {1'b0, T_NAN} || c == {1'b0, T_INF}) ? 17'h07FFF :
			                     (c == {1'b0, T_ZERO}) ? 17'd0 : e;
			default: lde_of = {2'd0, d[94:80]};
		endcase
	end
endfunction
reg  [16:0] r_lde;

// operand/result in working format
reg         a_s;
reg  [16:0] a_e;
reg  [63:0] a_m;
reg   [1:0] a_t;
// The arithmetic's result significand has a register of its own: the add,
// multiply, divide, square root, normalize and round states write z_m,
// the dispatch, conversion and special-case states a_m -- two narrower
// input selects instead of one wide one.  The rounding reads z_m after
// arithmetic (zr), a_m after a move or an exact special case; writeback
// reads z_m after rounding (wz), a_m otherwise.
reg  [63:0] z_m;
reg         zr, wz;
// The arithmetic units' result as the significand and GRS of a value to
// round, by the operation (op_kind, a register): the sum, renormalized by
// its carry; the product by its top bit; the quotient by its integer bit;
// the root.  One select for F_ADDN, F_MULT, F_DIVL and F_SQRTL into z_m.
reg  [63:0] ur_m;
reg   [2:0] ur_g;
always @* begin
	case (1'b1)   // synthesis parallel_case
		okh[0]: begin
			ur_m = add_r[67] ? add_r[67:4] : add_r[66:3];
			ur_g = add_r[67] ? {add_r[3], add_r[2], add_r[1] | add_r[0]} : add_r[2:0];
		end
		okh[1]: begin
			ur_m = mul_pd[127] ? mul_pd[127:64] : mul_pd[126:63];
			ur_g = mul_pd[127] ? {mul_pd[63], mul_pd[62], mul_slo || (mul_pd[61:32] != 0)} :
			                     {mul_pd[62], mul_pd[61], mul_slo || (mul_pd[60:32] != 0)};
		end
		okh[2]: begin
			ur_m = qv[66] ? qv[66:3] : qv[65:2];
			ur_g = qv[66] ? {qv[2], qv[1], qv[0] | (acc_hi != 65'd0)} :
			                {qv[1], qv[0], (acc_hi != 65'd0)};
		end
		default: begin
			ur_m = qr[65:2];
			ur_g = {qr[1], qr[0], (srem != 69'd0)};
		end
	endcase
end
wire [63:0] rin = zr ? z_m : a_m;     // the significand being rounded
// the exponent sign-extended, as the store and FINT range checks read it
wire signed [17:0] a_ex = $signed({a_e[16], a_e});
wire signed [17:0] a_ez = $signed({1'b0, a_e});
// FINT's range checks (sE = a_e - 16383 > 62, < -1), registered from a_e
// as F_EXEC leaves it, for F_INTS
reg        ez_big, ez_small;
always @(posedge clk) begin
	ez_big   <= (a_ez > 18'sd16445);
	ez_small <= (a_ez < 18'sd16382);
end

// staged shifter: mantissa with 3 rounding bits {G,R,S}, count up to 127
reg [66:0] sh_v;              // {m[63:0], G, R, S}
reg  [6:0] sh_cnt;
reg [66:0] sh_c;              // sh_v shifted by whole bytes (F_SHR)

// second (destination) operand and arithmetic scratch
reg         b_s;
reg  [16:0] b_e;
reg  [63:0] b_m;
reg   [1:0] b_t;
reg         b_unsup;          // the destination is an unsupported data type
reg   [2:0] grs;              // result rounding bits before F_ROUND
reg         eff_sub;          // effective magnitude subtract
reg  [64:0] acc_hi;           // divide remainder
reg  [66:0] qv;               // divide quotient
reg  [65:0] qr;               // sqrt root
reg  [68:0] srem;             // sqrt remainder
reg  [65:0] srad;             // sqrt radicand feed (its nonzero top: the
                              // 132-bit radicand's low 66 bits are zero)
reg   [6:0] loop_n;
reg [127:0] mul_pd;           // the full product (F_MULT)
reg   [3:0] op_kind;          // 0 none, 1 add, 2 mul, 3 div, 4 sqrt
reg   [3:0] okh;              // ... one-hot {sqrt, div, mul, add} (the result select)
function [3:0] kind1h;
	input [3:0] k;
	kind1h = {k == 4'd4, k == 4'd3, k == 4'd2, k == 4'd1};
endfunction
reg   [1:0] r_pr;             // rounding precision latched for F_UNFL
reg signed [17:0] e_w;        // working exponent (wrap safe)

// v >> n with every bit shifted out ORed into bit 0 (n >= 67: all out):
// seven stages, each ORing what it shifts out into the sticky bit
function [66:0] shr_sticky;
	input [66:0] v;
	input [6:0]  n;
	reg   [66:0] x;
	reg          s;
	integer      k;
	begin
		x = v; s = 1'b0;
		for (k = 0; k < 7; k = k + 1)
			if (n[k]) begin
				s = s | |(x & ((67'd1 << (1 << k)) - 67'd1));
				x = x >> (1 << k);
			end
		shr_sticky = x | {66'd0, s};
	end
endfunction
// the same in two registered steps (F_SHR, F_SHR2): by 8k (k = n[6:3]),
// then by n[2:0].  The first step's sticky bit lands in bit 0, which the
// second shifts out into its own sticky bit when it shifts at all, so the
// two compose to shr_sticky(v, n).  The sticky bit of the byte step is an
// OR of whole bytes below the shift, each byte's OR formed beside it.
function [66:0] shr_bytes;
	input [66:0] v;
	input  [3:0] k;
	reg    [8:0] bz;          // byte j of v (bits 8j+7:8j) nonzero
	reg          s;
	integer      j;
	begin
		for (j = 0; j < 9; j = j + 1)
			bz[j] = (j == 8) ? |v[66:64] : |v[8*j +: 8];
		s = 1'b0;
		for (j = 0; j < 9; j = j + 1)
			if (j < k) s = s | bz[j];
		shr_bytes = (v >> {k, 3'b000}) | {66'd0, s};
	end
endfunction
function [66:0] shr_bits;
	input [66:0] v;
	input  [2:0] n;
	reg          s;
	integer      j;
	begin
		s = 1'b0;
		for (j = 0; j < 7; j = j + 1)
			if (j < n) s = s | v[j];
		shr_bits = (v >> n) | {66'd0, s};
	end
endfunction

reg        int_z;             // FINT: the rounded integer is zero (F_INTR)

// integer store bookkeeping
reg        pk_neg;
reg  [1:0] pk_isz;            // 0 byte, 1 word, 2 long
reg        pk_sat;            // infinity or far out of range: saturate (F_PACKI)
reg [64:0] pk_mg;             // the rounded magnitude (F_PACKI)
reg [31:0] pk_lo;             // its low long word, negated for a negative (F_PACKI2)
reg        pk_ovf;            // ... and out of the format's range
// hardware subset at this stage: move/abs/neg/tst/cmp families
function op_in_hw;
	input [6:0] op;
	begin
		case (op)
			7'h00, 7'h40, 7'h44,          // FMOVE, FSMOVE, FDMOVE
			7'h18, 7'h58, 7'h5C,          // FABS, FSABS, FDABS
			7'h1A, 7'h5A, 7'h5E,          // FNEG, FSNEG, FDNEG
			7'h38, 7'h3A,                 // FCMP, FTST
			7'h22, 7'h62, 7'h66,          // FADD, FSADD, FDADD
			7'h28, 7'h68, 7'h6C,          // FSUB, FSSUB, FDSUB
			7'h23, 7'h27, 7'h63, 7'h67,   // FMUL, FSGLMUL, FSMUL, FDMUL
			7'h20, 7'h24, 7'h60, 7'h64,   // FDIV, FSGLDIV, FSDIV, FDDIV
			7'h04, 7'h41, 7'h45,          // FSQRT, FSSQRT, FDSQRT
			7'h01, 7'h03:                 // FINT, FINTRZ (68060)
				op_in_hw = 1;
			default:
				op_in_hw = 0;
		endcase
	end
endfunction

// result precision for an opmode: 0 extended (per FPCR), 1 single, 2 double
function [1:0] prec_of;
	input [6:0] op;
	begin
		if (op == 7'h24 || op == 7'h27) prec_of = 2'd1;   // FSGLDIV/FSGLMUL
		else if (op >= 7'h40) prec_of = op[2] ? 2'd2 : 2'd1;
		// FPCR rounding precision: 00 extended, 01 single, 10 double, and
		// the reserved encoding 11 rounds as double (softfloat's 68k glue
		// falls through its default into the double case, and hardware
		// cputest agrees).
		else prec_of = (fpcr[7:6] == 2'b01) ? 2'd1 :
		               (fpcr[7:6] == 2'b00) ? 2'd0 : 2'd2;
	end
endfunction


// FSGLMUL and FSGLDIV round the significand to single precision but keep
// the EXTENDED exponent range: they go through roundSigAndPackFloatx80,
// which has no expOffset, unlike the roundAndPackFloatx80 used by every
// FPCR-precision and FS/FD operation.  Their overflow saturation value is
// the full all-ones mantissa at the extended maximum, again unlike the
// masked significand roundAndPackFloatx80 produces.
function op_sgl;
	input [6:0] op;
	begin
		op_sgl = (op == 7'h24) || (op == 7'h27);
	end
endfunction

// IEEE round-up decision from {lsb, G, R|S} and sign
function round_up;
	input       lsb, g, rs;
	input       sign;
	begin
		case (rnd_mode)
			2'b00:   round_up = g && (rs || lsb);   // nearest even
			2'b01:   round_up = 1'b0;               // toward zero
			2'b10:   round_up = sign && (g || rs);  // toward minus
			default: round_up = !sign && (g || rs); // toward plus
		endcase
	end
endfunction

// Highest-priority enabled FPSR exception, matching the architectural
// vector assignment.  Input bit 7 is BSUN and bit 0 is INEX1.
function [7:0] fp_exception_vector;
	input [7:0] ex;
	begin
		if      (ex[7]) fp_exception_vector = `AP040_VEC_FP_BSUN;
		else if (ex[6]) fp_exception_vector = `AP040_VEC_FP_SNAN;
		else if (ex[5]) fp_exception_vector = `AP040_VEC_FP_OPERR;
		else if (ex[4]) fp_exception_vector = `AP040_VEC_FP_OVFL;
		else if (ex[3]) fp_exception_vector = `AP040_VEC_FP_UNFL;
		else if (ex[2]) fp_exception_vector = `AP040_VEC_FP_DZ;
		else             fp_exception_vector = `AP040_VEC_FP_INEX;
	end
endfunction
// Operand shadow for the pending-exception frame: captured at
// F_EXEC/F_BIN entry, where the classified source is in hand -- by the
// time the exception is known (F_WB) the pipeline has consumed it.  An
// unsupported data type's or unimplemented instruction's operand is staged
// here too; et_cap copies it to fstate_et the cycle after.
reg [95:0] sh_src;
reg        et_cap;

//---------------------------------------------------------------------------
// arithmetic pipeline
//---------------------------------------------------------------------------
// FMOVE, FABS, FNEG, FADD, FSUB and FMUL (FPCR precision and the FS/FD
// forms; FMOVE also from a long, word or byte integer) whose
// operands are ordinary -- zeros, or normalized numbers whose unbiased
// exponent is within +-60 ("nice") -- can neither overflow nor underflow
// at any rounding precision, and with every FPCR exception enable clear
// they raise nothing that traps.  They run in a pipeline that takes one
// a cycle and writes its results in order; the sequential state machine
// starts an operation only once the pipeline is empty, and everything
// that reads FPU state waits for it (pbusy).  The arithmetic is the state
// machine's, step for step (the state machine spreads each step over more
// cycles), so results and FPSR are bit-identical (tb/tb_fpu_pipe.sv runs
// both side by side):
//   P1  zero cases, operand order and exponent difference (FMUL: the
//       exponent sum)                                  (F_BIN0, F_BIN)
//   P2  alignment shift with sticky (FMUL: the 32x32 partial products)
//                                                      (F_SHR, F_SHR2)
//   P3  add or subtract (FMUL: their sum, one-bit normalize)
//                                                      (F_SHR2, F_ADDN)
//   P4  normalize after a subtraction, or an integer source (F_NSH)
//   P5  round to the precision                         (F_ROUND, F_RND2)
//   P6  register, FPSR condition codes, INEX           (F_WB)
// The pipeline's stages keep the 60 MHz arrangement: it is not part of the
// 120 MHz configuration (PIPE=0).
// A source that an operation in P5 or P6 is writing when the next one is
// dispatched is forwarded into its P1 (from P6, or P7: P6 one cycle on);
// one written by P1-P4 holds the dispatch.

function pipe_opm;
	input [6:0] op;
	begin
		case (op)
			7'h00, 7'h40, 7'h44, 7'h22, 7'h62, 7'h66,
			7'h28, 7'h68, 7'h6C, 7'h23, 7'h63, 7'h67,
			7'h18, 7'h58, 7'h5C, 7'h1A, 7'h5A, 7'h5E: pipe_opm = 1'b1;
			default: pipe_opm = 1'b0;
		endcase
	end
endfunction

// 0 move, 1 add/subtract, 2 multiply
function [1:0] pipe_kind;
	input [6:0] op;
	begin
		case (op)
			7'h22, 7'h62, 7'h66, 7'h28, 7'h68, 7'h6C: pipe_kind = 2'd1;
			7'h23, 7'h63, 7'h67:                      pipe_kind = 2'd2;
			default:                                  pipe_kind = 2'd0;
		endcase
	end
endfunction

// an ordinary extended value: zero (not infinity), or normalized with
// an exponent of 16383 +- 60
function nice_x;
	input [14:0] e;
	input [63:0] m;
	begin
		nice_x = (m == 64'd0) ? (e != 15'h7FFF)
		                      : (m[63] && e >= 15'd16323 && e <= 15'd16443);
	end
endfunction

reg   [7:0] fr_nice;          // per register: nice_x of its contents
reg         req_pend;         // a request waiting for the pipeline
wire        rq = req || req_pend;

// stage registers
reg         p1_v, p2_v, p3_v, p4_v, p5_v, p6_v, p7_v;
reg   [6:0] p1_op, p2_op, p3_op, p4_op, p5_op;
reg   [2:0] p1_d, p2_d, p3_d, p4_d, p5_d, p6_d;
reg         p1_as, p1_bs, p1_az, p1_bz;
reg  [16:0] p1_ae, p1_be;
reg  [63:0] p1_am, p1_bm;
reg   [1:0] p1_af, p1_bf;     // forwarded from: 0 no, 1 P6, 2 P7
reg   [1:0] p2_k, p3_k;
reg         p2_z, p3_z, p4_z, p5_z, p6_z, p7_z;   // the result is zero
reg         p2_s, p3_s, p4_s, p5_s, p6_s, p7_s;
reg  signed [17:0] p2_e, p3_e, p4_e, p5_e;
reg  [16:0] p6_e, p7_e;
reg  [63:0] p2_bm, p2_sm, p3_bm, p4_m, p5_m, p6_m, p7_m;
reg   [6:0] p2_sh;
reg         p2_es, p3_es, p4_n;
reg  [66:0] p3_sv;
reg   [2:0] p4_g, p5_g;
reg         p6_inx, p6_nice;
reg         p1_ni, p2_ni, p3_ni;   // an integer source: normalize in P4

// The pipeline's own normalizer (P4) and alignment shifter (P2): the
// single-cycle forms.  (The state machine's are split into registered
// steps below; the pipeline keeps the 60 MHz arrangement, stage for stage.)
wire  [6:0] p4_lz      = clz64(p4_m);
wire [66:0] p4_shifted = {p4_m, p4_g} << p4_lz;
wire [66:0] p2_sv      = shr_sticky({p2_sm, 3'd0}, p2_sh);

//---------------------------------------------------------------------------
// the state machine's arithmetic units
//---------------------------------------------------------------------------
// Free-running: each registers its result every cycle from the working
// registers, and the state that needs it reads it the cycle after the
// state that set up its operands -- no enables, no operand selects in
// front of the adders.

// right shift with sticky (F_SHR: whole bytes into sh_c; F_SHR2: the rest
// into sh_v).  An add's alignment of less than a byte skips F_SHR: F_BIN
// loads sh_c with the unshifted value itself.
always @(posedge clk)
	sh_c <= fst1h[F_BIN] ? {bo_swap ? b_m : a_m, 3'd0} : shr_bytes(sh_v, sh_cnt[6:3]);
wire [66:0] shr_out = shr_bits(sh_c, sh_cnt[2:0]);
// the bits a single's or double's rounding discards from it, nonzero
// (F_PACKS, F_UNFL: they follow F_SHR2), registered as it is written
reg         shx_s, shx_d;     // the bits below the kept ones
reg         shr_s, shr_d;     // ... below the guard bit (the sticky)
always @(posedge clk) begin
	shx_s <= (shr_out[42:0] != 43'd0);
	shx_d <= (shr_out[13:0] != 14'd0);
	shr_s <= (shr_out[41:0] != 42'd0);
	shr_d <= (shr_out[12:0] != 13'd0);
end

// add/subtract, in F_SHR2 as the alignment ends: one 68-bit adder of the
// larger magnitude and the aligned smaller one (shr_out), the latter
// inverted for an effective subtraction ({b_m, GRS} >= the aligned value:
// b is the larger magnitude)
reg  [67:0] add_r;
always @(posedge clk)
	add_r <= {1'b0, b_m, 3'd0} + ({1'b0, shr_out} ^ {68{eff_sub}}) + {67'd0, eff_sub};

// Normalization (an integer source in F_SRC, FINT's integer in F_INTN, a
// cancellation's difference in F_ADDN): the leading zeros of the value's
// top 64 bits, and the value pre-shifted by 32 when its top 32 bits are
// clear, registered; F_NSH then shifts by the rest (0-32).  {v, G, R, S}
// << lz as before.
// (Two counters -- the add result's (F_ADDN), and an integer source's as
// the dispatch unpacked it (F_SRC) or FINT's integer (F_INTN), both in
// unp_m -- the result selected after counting: no operand select in front
// of a counter.)
reg         lz_add;           // the count's source is the add result (F_ADDN)
wire  [6:0] lz_ad  = clz64(add_r[66:3]);
wire  [6:0] lz_un  = clz64(unp_m);
wire        z32_ad = (add_r[66:35] == 32'd0);
wire        z32_un = (unp_m[63:32] == 32'd0);
reg   [6:0] n_lz;
reg   [5:0] n_sh;
reg         n_zero;           // the top 64 bits are clear
reg         n_allz;           // ... and the add result's GRS too (a zero difference)
reg  [66:0] n_v;
always @(posedge clk) begin : lzu
	reg [6:0] lz;
	lz = lz_add ? lz_ad : lz_un;
	lz_add <= fst1h[F_SHR2];   // (F_ADDN follows F_SHR2)
	n_lz   <= lz;
	// the rest of the shift: lz - 32 with the top 32 bits clear (lz >= 32,
	// 64 when all are clear), else lz (< 32)
	n_sh   <= {lz[6], lz[4:0]};
	n_zero <= lz[6];
	n_allz <= (add_r[66:0] == 67'd0);
	n_v    <= lz_add ? (z32_ad ? {add_r[34:0], 32'd0} : add_r[66:0]) :
	                   (z32_un ? {unp_m[31:0], 35'd0} : {unp_m, 3'd0});
end
wire [66:0] nsh_out = n_v << n_sh;

// the rounding increments of the shifted value (sh_v[66:3]): FINT's and
// the integer store's at bit 0, a denormal single's or double's store
// (F_PACKS) at its last kept bit -- each its own adder
wire [64:0] shk   = {1'b0, sh_v[66:3]};
wire [64:0] shk_i = shk + 65'd1;
wire [24:0] shk_s = {1'b0, sh_v[66:43]} + 25'd1;   // (shk + 2^40)[64:40]
wire [53:0] shk_d = {1'b0, sh_v[66:14]} + 54'd1;   // (shk + 2^11)[64:11]

// one 64x64 multiplier for both: the state machine multiplies only in
// F_MULT, which it reaches with the pipeline empty (its operands are
// registers of its own, loaded by whichever goes to multiply: F_BIN0 for
// the state machine, P1 for the pipeline's FMUL).  The four 32x32 partial
// products are registered (in the DSP blocks).
reg   [63:0] mul_x, mul_y;
reg   [63:0] mul_hh, mul_hl, mul_lh, mul_ll;
always @(posedge clk) if (ce) begin
	mul_hh <= mul_x[63:32] * mul_y[63:32];
	mul_hl <= mul_x[63:32] * mul_y[31:0];
	mul_lh <= mul_x[31:0]  * mul_y[63:32];
	mul_ll <= mul_x[31:0]  * mul_y[31:0];
end
// The pipeline's P3 sums them in the cycle after ({hh, ll} is a
// concatenation; the cross products sum in 65 bits and land on bits 96:32).
wire  [64:0] mul_cross = {1'b0, mul_hl} + {1'b0, mul_lh};
wire [127:0] mul_out = {mul_hh, mul_ll} + {31'd0, mul_cross, 32'd0};
// The state machine's product, one adder a cycle: the 32x32 products
// finished into flip-flops (the DSP blocks leave a final addition of their
// own partial products in the fabric), the cross products' sum, the full
// sum.  The product of mul_x and mul_y is in mul_pd four cycles after
// they are loaded.
reg  [63:0] mf_hh, mf_hl, mf_lh, mf_ll, mc_hh, mc_ll;
reg  [64:0] mc_x;
reg         mul_slo;          // mul_pd[31:0] != 0
always @(posedge clk) if (ce) begin
	mf_hh  <= mul_hh;
	mf_hl  <= mul_hl;
	mf_lh  <= mul_lh;
	mf_ll  <= mul_ll;
	mc_x   <= {1'b0, mf_hl} + {1'b0, mf_lh};
	mc_hh  <= mf_hh;
	mc_ll  <= mf_ll;
	mul_pd <= {mc_hh, mc_ll} + {31'd0, mc_x, 32'd0};
	// the product's low long word passes the sum unchanged: its sticky
	// OR formed beside it
	mul_slo <= (mc_ll[31:0] != 32'd0);
end

// FDIV: two restoring steps a cycle without their carry chains in series.
// With r the remainder and d the divisor, 4r - 2d decides the first
// quotient bit and 4r - 3d or 4r - d the second; all three are formed at
// once (3d is a register: the divisor a_m is fixed while the divide runs).
// (2r - d first, then 2(2r - d) - d or 4r - d: the same bits and remainder.)
reg  [65:0] dv_d3;
always @(posedge clk) dv_d3 <= {1'b0, a_m, 1'b0} + {2'd0, a_m};
wire [67:0] dv_r4  = {2'd0, acc_hi[63:0], 2'd0};
wire [67:0] dv_c1  = dv_r4 - {4'd0, a_m};
wire [67:0] dv_c2  = dv_r4 - {3'd0, a_m, 1'b0};
wire [67:0] dv_c3  = dv_r4 - {2'd0, dv_d3};
wire        dv_q1  = !dv_c2[67];
wire        dv_q2  = dv_q1 ? !dv_c3[67] : !dv_c1[67];
wire [63:0] dv_rem = dv_q1 ? (dv_q2 ? dv_c3[63:0] : dv_c2[63:0]) :
                             (dv_q2 ? dv_c1[63:0] : dv_r4[63:0]);

// FSQRT: one restoring step a cycle -- the remainder shifts two bits (the
// radicand's next two enter), the trial is the root so far with 01, and
// the borrow of the trial subtraction is the root bit
wire [68:0] sq_r2  = {srem[66:0], srad[65:64]};
wire [69:0] sq_d   = {1'b0, sq_r2} - {2'b0, qr[65:0], 2'b01};
wire        sq_q   = !sq_d[69];
wire [68:0] sq_rem = sq_q ? sq_d[68:0] : sq_r2;

// F_BIN0: the binary operation's outcome and the values F_BIN takes,
// registered from the operands as F_BIN finds them (the special cases in
// floatx80_add/mul/div/sqrt's order; one-hot)
// (a number's case -- SQN, MULN, DIVN -- splits by the significand
// compares in F_BIN: exact or not; the outcome itself is the classes')
localparam BO_UNSUP = 0, BO_NANB = 1, BO_NANA = 2, BO_PASS = 3, BO_DNAN = 4,
           BO_SQN = 5, BO_ADDINF = 6, BO_ADDZZ = 7, BO_ADDAZ = 8, BO_ADDBZ = 9,
           BO_ADDGO = 10, BO_MULINF = 11, BO_MULZ = 12, BO_MULN = 13, BO_DIVBINF = 14,
           BO_DIVDZ = 15, BO_DIVZ = 16, BO_DIVN = 17;
reg  [17:0] bo;
reg         bo_sqx;           // sqrt: an even power of two (exact)
reg         bo_p2, bo_ap2;    // mul: a (chopped) power of two, the source one
reg         bo_dvx, bo_a8;    // div: exact; the divisor's significand is 1.0
reg         bo_swap;          // add: the source is the larger magnitude
reg   [6:0] bo_cnt;           // add: the alignment shift, saturated at 67
reg         bo_c8;            // ... and it is below a byte (no F_SHR)
reg  signed [17:0] bo_emul, bo_ediv, bo_esq;
reg         bo_sqodd;         // sqrt: the unbiased exponent is odd
reg         bo_q0;            // div: the integer quotient bit
reg  [64:0] bo_rem0;          // ... and the remainder after it
// F_BIN's new significand, ((b or a) & kept) | set, by bit region: b's
// (else a's); bits 63:40 and 39:0 kept (a chop or a constant clears them);
// bit 63, bit 62 (a quieted NaN) and bits 61:0 set (the default NaN)
reg         bo_mb, bo_kh, bo_kl, bo_s63, bo_s62, bo_slo;
// FSUB family: the source sign folded
wire        s_a    = (op_kind == 4'd1 && r_fsub) ? ~a_s : a_s;
// FSGLMUL chops both mantissas to single precision before multiplying
// (the result is single rounded); FSGLDIV divides the full mantissas
wire        chop   = r_sgl && (op_kind == 4'd2);
wire [63:0] am_eff = chop ? (a_m & 64'hFFFF_FF00_0000_0000) : a_m;
wire [63:0] bm_eff = chop ? (b_m & 64'hFFFF_FF00_0000_0000) : b_m;
always @(posedge clk) begin : bin0
	reg        k4, ap2, bp2, sqx, dvx, aswap;
	reg [16:0] dab, dba;
	reg [17:0] dx;
	reg [64:0] d0;
	reg [17:0] o;
	reg signed [17:0] sE;
	k4  = (op_kind == 4'd4);
	// an exact power of two (after the chop): the compare in parts on the
	// operand, beside the chop's select
	ap2 = (a_m[63:40] == 24'h80_0000) && (chop || a_m[39:0] == 40'd0);
	bp2 = (b_m[63:40] == 24'h80_0000) && (chop || b_m[39:0] == 40'd0);
	sE  = a_ex - 18'sd16383;
	sqx = (a_m == 64'h8000_0000_0000_0000) && !sE[0];
	dvx = (a_m == 64'h8000_0000_0000_0000) || (b_m == a_m);
	// (the magnitude compares are the borrows of subtractions -- carry
	// chains: the significands' is the divide's first step, d0)
	d0  = {1'b0, b_m} - {1'b0, a_m};
	dx  = {b_e[16], b_e} - {a_e[16], a_e};
	aswap = dx[17] || (a_e == b_e && d0[64]);
	dab = a_e - b_e;
	dba = b_e - a_e;
	o   = 18'd0;
	if (!k4 && b_unsup)           o[BO_UNSUP] = 1'b1;
	else if (!k4 && b_t == T_NAN) o[BO_NANB]  = 1'b1;   // destination NaN preferred
	else if (a_t == T_NAN)        o[BO_NANA]  = 1'b1;
	else case (op_kind)
		4'd4: begin
			if (a_t == T_ZERO)     o[BO_PASS] = 1'b1;   // sqrt(+-0) = +-0
			else if (a_s)          o[BO_DNAN] = 1'b1;   // negative: OPERR
			else if (a_t == T_INF) o[BO_PASS] = 1'b1;
			else                   o[BO_SQN]  = 1'b1;
		end
		4'd1: begin
			if (a_t == T_INF || b_t == T_INF) begin
				if (a_t == T_INF && b_t == T_INF && s_a != b_s) o[BO_DNAN] = 1'b1;
				else o[BO_ADDINF] = 1'b1;
			end
			else if (a_t == T_ZERO && b_t == T_ZERO) o[BO_ADDZZ] = 1'b1;
			else if (a_t == T_ZERO) o[BO_ADDAZ] = 1'b1;
			else if (b_t == T_ZERO) o[BO_ADDBZ] = 1'b1;
			else                    o[BO_ADDGO] = 1'b1;
		end
		4'd2: begin
			if (a_t == T_INF || b_t == T_INF) begin
				if (a_t == T_ZERO || b_t == T_ZERO) o[BO_DNAN] = 1'b1;   // 0 * inf
				else o[BO_MULINF] = 1'b1;
			end
			else if (a_t == T_ZERO || b_t == T_ZERO) o[BO_MULZ] = 1'b1;
			else o[BO_MULN] = 1'b1;
		end
		default: begin
			// floatx80_div: the dividend-infinity case before the
			// divisor-zero check, so inf/0 is a clean infinity, no DZ
			if ((a_t == T_INF && b_t == T_INF) || (a_t == T_ZERO && b_t == T_ZERO))
				o[BO_DNAN] = 1'b1;
			else if (b_t == T_INF)                  o[BO_DIVBINF] = 1'b1;
			else if (a_t == T_ZERO)                 o[BO_DIVDZ]   = 1'b1;
			else if (b_t == T_ZERO || a_t == T_INF) o[BO_DIVZ]    = 1'b1;
			else                                    o[BO_DIVN]    = 1'b1;
		end
	endcase
	bo <= o;
	bo_sqx <= sqx;
	bo_p2  <= ap2 || bp2;
	bo_ap2 <= ap2;
	bo_dvx <= dvx;
	bo_a8  <= (a_m == 64'h8000_0000_0000_0000);
	// the significand F_BIN writes (bin_am), by outcome: the operand a or b
	// (an infinity's own image, the swap, the dividend), the FSGLMUL chop,
	// the quiet bit of a propagated NaN, the default NaN, 0, 1.0 -- the
	// classes' part here, the compares' (the swap, a power of two, an exact
	// divide) applied in F_BIN from their registers
	bo_mb  <= o[BO_NANB] || o[BO_ADDAZ] || o[BO_DIVBINF] ||
	          ((o[BO_ADDINF] || o[BO_MULINF]) && b_t == T_INF);
	bo_kh  <= !(o[BO_DNAN] || o[BO_DIVDZ]);
	bo_kl  <= !(o[BO_DNAN] || o[BO_DIVDZ] || ((o[BO_MULZ] || o[BO_MULN]) && chop));
	bo_s63 <= o[BO_DNAN];
	bo_s62 <= o[BO_DNAN] || o[BO_NANB] || o[BO_NANA];
	bo_slo <= o[BO_DNAN];
	bo_swap  <= aswap;
	bo_cnt   <= aswap ? ((dab > 17'd66) ? 7'd67 : dab[6:0]) :
	                    ((dba > 17'd66) ? 7'd67 : dba[6:0]);
	bo_c8    <= aswap ? (dab < 17'd8) : (dba < 17'd8);
	bo_emul  <= a_ex + $signed({b_e[16], b_e}) - 18'sd16383;
	bo_ediv  <= $signed({b_e[16], b_e}) - a_ex + 18'sd16383;
	bo_esq   <= (sE >>> 1) + 18'sd16383;
	bo_sqodd <= sE[0];
	// the divide's first, integer quotient bit (unshifted)
	bo_q0    <= !d0[64];
	bo_rem0  <= d0[64] ? {1'b0, b_m} : d0;
end
// (an inexact divide's 1.0: a divide that is exact by an unequal divisor)
wire        bin_d1 = bo[BO_DIVN] && bo_dvx && !bo_a8;
wire        bin_mb = bo_mb || (bo[BO_ADDGO] && bo_swap) || (bo[BO_MULN] && bo_ap2) ||
                     (bo[BO_DIVN] && bo_a8);
wire [63:0] bin_am = ((bin_mb ? b_m : a_m) & {{24{bo_kh && !bin_d1}}, {40{bo_kl && !bin_d1}}}) |
                     {bo_s63 || bin_d1, bo_s62, {62{bo_slo}}};
// synthesis translate_off
always @(posedge clk)
	if (nreset && fst == F_BIN && (bo == 18'd0 || (bo & (bo - 18'd1)) != 18'd0)) begin
		$display("FAIL: FPU F_BIN outcome %b is not one-hot", bo);
		$finish;
	end
// synthesis translate_on

// F_ROUND: the precision's round-up decision, its increment, and the range
// compares for both outcomes of the increment's carry, registered for
// F_RND2's selections.  Range control: the rounding precision narrows the
// exponent range as well as the significand (softfloat's SOFTFLOAT_68K
// roundAndPackFloatx80 expOffset, 0x3F80 single / 0x3C00 double), EXCEPT
// for FSGLMUL/FSGLDIV, which round through roundSigAndPackFloatx80 and keep
// the extended range.  Extended (and the sgl class) use the RAW exponent
// convention: a working exponent of ZERO still packs as a normal result
// with exponent field 0 (the pseudo-denormal encoding) and no flags;
// tininess only starts below that, shifting by -er (softfloat probes:
// (0001-8000)/2 -> 0000-8000 clean, /4 -> 0000-4000 UNFL,
// 2^-16380*2^-13 -> 0000-0020.. shift 10).
reg  [63:0] rmask;            // the precision's kept bits
reg  signed [17:0] emax, emin;
always @* begin
	rmask = (r_prec == 2'd1) ? 64'hFFFF_FF00_0000_0000 :
	        (r_prec == 2'd2) ? 64'hFFFF_FFFF_FFFF_F800 : 64'hFFFF_FFFF_FFFF_FFFF;
	emax  = r_sgl ? 18'sd32766 : (r_prec == 2'd1) ? 18'sd16510 :
	        (r_prec == 2'd2) ? 18'sd17406 : 18'sd32766;
	emin  = r_sgl ? 18'sd0 : (r_prec == 2'd1) ? 18'sd16257 :
	        (r_prec == 2'd2) ? 18'sd15361 : 18'sd0;
end
reg         rn_up, rn_one, rn_inx, rn_ge, rn_gt, rn_lt, rn_xb0, rn_xb1;
reg  [64:0] rn_mi;
reg  signed [17:0] rn_e1;
reg   [6:0] rn_x0, rn_x1;
always @(posedge clk) begin : r1
	reg [63:0] rinc;          // the precision's ulp
	reg        up, inx;
	reg signed [17:0] x0, x1;
	case (r_prec)
		2'd1: begin
			up   = round_up(rin[40], rin[39], (rin[38:0] != 0) || (grs != 0), a_s);
			inx  = (rin[39:0] != 0) || (grs != 0);
			rinc = 64'h0000_0100_0000_0000;
		end
		2'd2: begin
			up   = round_up(rin[11], rin[10], (rin[9:0] != 0) || (grs != 0), a_s);
			inx  = (rin[10:0] != 0) || (grs != 0);
			rinc = 64'h0000_0000_0000_0800;
		end
		default: begin
			up   = round_up(rin[0], grs[2], grs[1:0] != 0, a_s);
			inx  = (grs != 0);
			rinc = 64'h0000_0000_0000_0001;
		end
	endcase
	// underflow's denormalizing shift: emin - er, er the exponent after
	// the rounding carry (F_RND2 selects; it is taken only below emin)
	x0 = emin - e_w;
	x1 = x0 - 18'sd1;
	rn_up  <= up;
	rn_inx <= inx;
	// the kept bits all ones: the increment carries out
	rn_one <= (r_prec == 2'd1) ? &rin[63:40] : (r_prec == 2'd2) ? &rin[63:11] : &rin;
	rn_mi  <= {1'b0, rin & rmask} + {1'b0, rinc};
	rn_e1  <= e_w + 18'sd1;
	rn_ge  <= (e_w >= emax);
	rn_gt  <= (e_w > emax);
	// underflow from the intermediate result, before rounding (MC68060UM
	// 6.4.1, 6.6.5; SoftFloat's 68K roundAndPack: zExp < expOffset + 1): a
	// rounding carry into the normal range does not undo it
	rn_lt  <= (e_w < emin);
	rn_x0  <= x0[6:0];
	rn_x1  <= x1[6:0];
	rn_xb0 <= (x0 > 18'sd66);
	rn_xb1 <= (x0 > 18'sd67);         // (x1 > 66)
end

// a single or double store of a number (F_SRC, encoded by F_PKR): the
// round-up decision, the increment, the overflow tests and the encoded
// exponent for both outcomes of the increment's carry, registered
reg         sp_up, sp_cy, sp_inx, sp_ov0, sp_ov1;
reg  [52:0] sp_mi;            // the kept bits plus one (24 single, 53 double)
reg  [10:0] sp_en0, sp_en1;   // the encoded exponent without, with the carry
always @(posedge clk) begin : spu
	reg [16:0] en0, en1;
	if (r_fmt == 3'd1) begin
		en0 = a_e - 17'd16256;   // -16383 +127
		en1 = a_e - 17'd16255;
		sp_up  <= round_up(a_m[40], a_m[39], (a_m[38:0] != 0), a_s);
		sp_cy  <= round_up(a_m[40], a_m[39], (a_m[38:0] != 0), a_s) && &a_m[63:40];
		sp_inx <= (a_m[39:0] != 0);
		sp_mi  <= {29'd0, a_m[63:40] + 24'd1};
		sp_ov0 <= (a_ez > 18'sd16510);   // a_e - 16383 > 127
		sp_ov1 <= (a_ez > 18'sd16509);   // a_e - 16382 > 127
		sp_en0 <= {3'd0, en0[7:0]};
		sp_en1 <= {3'd0, en1[7:0]};
	end
	else begin
		en0 = a_e - 17'd15360;   // -16383 +1023
		en1 = a_e - 17'd15359;
		sp_up  <= round_up(a_m[11], a_m[10], (a_m[9:0] != 0), a_s);
		sp_cy  <= round_up(a_m[11], a_m[10], (a_m[9:0] != 0), a_s) && &a_m[63:11];
		sp_inx <= (a_m[10:0] != 0);
		sp_mi  <= a_m[63:11] + 53'd1;
		sp_ov0 <= (a_ez > 18'sd17406);   // a_e - 16383 > 1023
		sp_ov1 <= (a_ez > 18'sd17405);
		sp_en0 <= en0[10:0];
		sp_en1 <= en1[10:0];
	end
end

// FCMP's condition codes for ordered operands, from F_EXEC's operands (F_WB
// uses them the cycle after; an unordered compare overrides them there).
// Equal ZEROS and equal INFINITIES report the destination sign in N; equal
// finite values compare as +0 (floatx80_cmp packs (0,0,0)), so N stays
// clear even for two negatives.
// (the operands' magnitude compares, registered: subtraction borrows --
// carry chains -- and equalities; the classes and signs are registers of
// their own, so F_WB combines flip-flops)
reg         c_egt, c_eeq, c_mgt, c_meq;
always @(posedge clk) begin : fcmp
	reg [17:0] de;
	reg [64:0] dm;
	de = {a_e[16], a_e} - {b_e[16], b_e};       // negative: b_e > a_e
	dm = {1'b0, a_m} - {1'b0, b_m};             // borrow: b_m > a_m
	c_egt <= de[17];
	c_eeq <= (b_e == a_e);
	c_mgt <= dm[64];
	c_meq <= (b_m == a_m);
end
reg         cmp_n, cmp_z;
always @* begin : fcmp_cc
	reg dz, eq, gt, dbig;
	dz = (b_t == T_ZERO);
	eq = (dz && a_t == T_ZERO) ||
	     (b_t == a_t && b_s == a_s && b_t != T_ZERO &&
	      (b_t == T_INF || (c_eeq && c_meq)));
	if (b_t == T_INF)      dbig = 1'b1;
	else if (a_t == T_INF) dbig = 1'b0;
	else dbig = c_egt || (c_eeq && c_mgt);
	if (dz)                 gt = a_s;
	else if (a_t == T_ZERO) gt = !b_s;
	else if (b_s != a_s)    gt = !b_s;
	else                    gt = b_s ? !dbig : dbig;
	cmp_z = eq;
	cmp_n = eq ? ((dz || b_t == T_INF) ? b_s : 1'b0) : !gt;
end
assign pbusy = p1_v || p2_v || p3_v || p4_v || p5_v || p6_v;
assign pdone = pipe_issue;

// the youngest writer in flight of register r: 0 none, 1 P1-P4 (wait),
// 2 P5 (forward from P6), 3 P6 (forward from P7)
// (from per-register vectors kept alongside the stages: the dispatch
// feeds pdone, and so the core's stall path -- no destination compares)
reg   [7:0] pb14, pb5, pb6;   // register r written by P1-P4, P5, P6
function [1:0] pw;
	input [2:0] r;
	begin
		if (pb14[r]) pw = 2'd1;
		else if (pb5[r]) pw = 2'd2;
		else if (pb6[r]) pw = 2'd3;
		else pw = 2'd0;
	end
endfunction

// the pipeline's register writers one cycle on
wire  [7:0] pb14_n = (pipe_issue ? (8'd1 << dst_r) : 8'd0) | (p1_v ? (8'd1 << p1_d) : 8'd0) |
                     (p2_v ? (8'd1 << p2_d) : 8'd0) | (p3_v ? (8'd1 << p3_d) : 8'd0);
wire  [7:0] pb5_n  = p4_v ? (8'd1 << p4_d) : 8'd0;
wire  [7:0] pb6_n  = p5_v ? (8'd1 << p5_d) : 8'd0;

// okv[r]: register r may be a pipelined operation's operand now -- not
// being written by P1-P4, and nice (P5's or P6's result as it will be, or
// the register's own).  Registered from the next state, so the dispatch
// (pdone, and the core's stall path) selects one flip-flop per operand.
reg   [7:0] okv;
reg   [7:0] okv_n;

// P5's result will be nice, decided a stage early (a register: it feeds
// the dispatch, pdone, and so the core's stall path): its exponent before
// rounding within +-59 (rounding adds at most one), P4's normalize taking
// up to 64 off -- conservative: a result this misses is only not
// forwarded (the dispatch waits for its write and reads the flag then)
reg  p5_nice;
wire p5_nice_n = p4_z || (p4_n ? (p4_e >= 18'sd16388 && p4_e <= 18'sd16442)
                                : (p4_e >= 18'sd16324 && p4_e <= 18'sd16442));

// the memory operand: single, double or extended; or an integer (long,
// word, byte) for a move, normalized in P4 as F_NSH does
reg         q_s, q_z, q_n, q_i;
reg  [16:0] q_e;
reg  [63:0] q_m;
always @* begin
	q_s = din[95]; q_z = 1'b0; q_n = 1'b0; q_i = 1'b0; q_e = 17'd0; q_m = 64'd0;
	case (src_fmt)
		3'd0: begin
			q_i = 1'b1; q_n = 1'b1;
			q_z = (din[95:64] == 32'd0);
			q_e = 17'd16383 + 17'd31;
			q_m = {(din[95] ? (32'd0 - din[95:64]) : din[95:64]), 32'd0};
		end
		3'd4: begin
			q_i = 1'b1; q_n = 1'b1;
			q_z = (din[95:80] == 16'd0);
			q_e = 17'd16383 + 17'd15;
			q_m = {(din[95] ? (16'd0 - din[95:80]) : din[95:80]), 48'd0};
		end
		3'd6: begin
			q_i = 1'b1; q_n = 1'b1;
			q_z = (din[95:88] == 8'd0);
			q_e = 17'd16383 + 17'd7;
			q_m = {(din[95] ? (8'd0 - din[95:88]) : din[95:88]), 56'd0};
		end
		3'd1: begin
			q_z = (din[94:64] == 31'd0);
			q_n = q_z || (din[94:87] >= 8'd67 && din[94:87] <= 8'd187);
			q_e = q_z ? 17'd0 : ({9'd0, din[94:87]} + 17'd16256);
			q_m = q_z ? 64'd0 : {1'b1, din[86:64], 40'd0};
		end
		3'd5: begin
			q_z = (din[94:32] == 63'd0);
			q_n = q_z || (din[94:84] >= 11'd963 && din[94:84] <= 11'd1083);
			q_e = q_z ? 17'd0 : ({6'd0, din[94:84]} + 17'd15360);
			q_m = q_z ? 64'd0 : {1'b1, din[83:32], 11'd0};
		end
		default: begin
			q_z = (din[63:0] == 64'd0);
			q_n = nice_x(din[94:80], din[63:0]);
			q_e = {2'd0, din[94:80]};
			q_m = din[63:0];
		end
	endcase
end

wire [1:0] q_kind = pipe_kind(opmode);
wire       q_reg  = (op_class == 3'b000);
wire       q_mem  = (op_class == 3'b010) &&
                    ((src_fmt == 3'd1 || src_fmt == 3'd5 || src_fmt == 3'd2) ||
                     // an integer (always ordinary) only for a move: a binary
                     // operation needs its source normalized before P1
                     ((src_fmt == 3'd0 || src_fmt == 3'd4 || src_fmt == 3'd6) &&
                      q_kind == 2'd0));
// what the operation's words alone decide: it can go into the pipeline
// (opmode, a register or memory source of a format it takes), its source
// is memory, it is a move (no destination operand); with sel_x
// registered from the next words, off the dispatch's path
function [2:0] q_static;
	input [6:0] opm;
	input [2:0] cls, fmt;
	reg [1:0] k;
	reg       m;
	begin
		k = pipe_kind(opm);
		m = (cls == 3'b010) && ((fmt == 3'd1 || fmt == 3'd5 || fmt == 3'd2) ||
		                        ((fmt == 3'd0 || fmt == 3'd4 || fmt == 3'd6) && k == 2'd0));
		q_static = {pipe_opm(opm) && ((cls == 3'b000) || m), m, k == 2'd0};
	end
endfunction
reg  [2:0] qs_q;
always @(posedge clk) qs_q <= q_static(opmode_n, op_class_n, src_fmt_n);
wire [2:0] qs_l = q_static(opmode, op_class, src_fmt);
wire [2:0] qs   = sel_x ? qs_q : qs_l;
// synthesis translate_off
always @(posedge clk)
	if (nreset && sel_x && qs_q != qs_l) begin
		$display("FAIL: the registered pipeline eligibility %b, the words' %b", qs_q, qs_l);
		$finish;
	end
// synthesis translate_on

wire [1:0] q_aw   = pw(src_r);
wire [1:0] q_bw   = pw(dst_r);
wire       q_aok  = qs[1] ? din_nice : sel_x ? aok_x : okv[src_r];
wire       q_bok  = qs[0] ? 1'b1 : sel_x ? bok_x : okv[dst_r];
assign okv_next = okv_n;
// (not in FRESTORE's unimplemented-frame cycle at all: the frame's
// resume decode stays off the dispatch, and with it the core's stall path;
// a request then goes to the state machine)
wire pipe_issue = (PIPE != 0) && ce && rq && fst1h[F_IDLE] && !fmq_v &&
                  (fpcr[15:8] == 8'd0) && qs[2] && q_aok && q_bok;

// synthesis translate_off
always @(posedge clk) begin : pb_check
	integer r;
	for (r = 0; r < 8; r = r + 1)
		if (nreset && (pb14[r] != ((p1_v && p1_d == r) || (p2_v && p2_d == r) ||
		                           (p3_v && p3_d == r) || (p4_v && p4_d == r)) ||
		               pb5[r] != (p5_v && p5_d == r) || pb6[r] != (p6_v && p6_d == r))) begin
			$display("FAIL: pipe writer vectors disagree with the stages (r %0d)", r);
			$finish;
		end
end
always @(posedge clk)
	if (ce && rq && q_mem && din_nice !== q_n) begin
		$display("FAIL: din_nice %b, the operand classifies as %b (fmt %0d din %h)",
		         din_nice, q_n, src_fmt, din);
		$finish;
	end
// synthesis translate_on

// P1: the operands (forwarded), the zero cases, order and exponents
reg         s1_as, s1_bs, s1_az, s1_bz;
reg  [16:0] s1_ae, s1_be;
reg  [63:0] s1_am, s1_bm;
always @* begin
	{s1_as, s1_ae, s1_am, s1_az} = (p1_af == 2'd1) ? {p6_s, p6_e, p6_m, p6_z} :
	                               (p1_af == 2'd2) ? {p7_s, p7_e, p7_m, p7_z} :
	                                                 {p1_as, p1_ae, p1_am, p1_az};
	{s1_bs, s1_be, s1_bm, s1_bz} = (p1_bf == 2'd1) ? {p6_s, p6_e, p6_m, p6_z} :
	                               (p1_bf == 2'd2) ? {p7_s, p7_e, p7_m, p7_z} :
	                                                 {p1_bs, p1_be, p1_bm, p1_bz};
end

always @(posedge clk) begin
	if (!nreset) begin
		p1_v <= 0; p2_v <= 0; p3_v <= 0; p4_v <= 0; p5_v <= 0; p6_v <= 0; p7_v <= 0;
		pb14 <= 8'd0; pb5 <= 8'd0; pb6 <= 8'd0; okv <= 8'd0;
	end
	else if (ce) begin
		//----------------------------------------------------------- dispatch
		p1_v <= pipe_issue;
		pb14 <= pb14_n;
		pb5  <= pb5_n;
		pb6  <= pb6_n;
		okv  <= okv_n;
		if (pipe_issue) begin
			p1_op <= opmode;
			p1_d  <= dst_r;
			p1_af <= (q_mem || q_aw == 2'd0) ? 2'd0 : (q_aw == 2'd2) ? 2'd1 : 2'd2;
			p1_bf <= (q_bw == 2'd0) ? 2'd0 : (q_bw == 2'd2) ? 2'd1 : 2'd2;
			p1_ni <= q_mem && q_i;
			if (q_mem) begin
				p1_as <= q_s; p1_ae <= q_e; p1_am <= q_m; p1_az <= q_z;
			end
			else begin
				p1_as <= fr_src_s; p1_ae <= {2'd0, fr_src_e}; p1_am <= fr_src_m;
				p1_az <= (fr_src_m == 64'd0);
			end
			p1_bs <= fr_dst_s; p1_be <= {2'd0, fr_dst_e}; p1_bm <= fr_dst_m;
			p1_bz <= (fr_dst_m == 64'd0);
		end

		//----------------------------------------------------------------- P1
		p2_v  <= p1_v;
		p2_ni <= p1_ni;
		p2_op <= p1_op;
		p2_d  <= p1_d;
		p2_z  <= 1'b0;
		p2_es <= 1'b0;
		p2_sh <= 7'd0;
		p2_sm <= 64'd0;
		case (pipe_kind(p1_op))
			2'd1: begin : p1_add
				reg        sa, aswap;
				reg [16:0] dd;
				// FSUB family: the source sign folded
				sa = (p1_op == 7'h28 || p1_op == 7'h68 || p1_op == 7'h6C) ? ~s1_as : s1_as;
				if (s1_az && s1_bz) begin
					p2_k <= 2'd0; p2_z <= 1'b1;
					p2_s <= (sa == s1_bs) ? sa : (rnd_mode == 2'b10);
					p2_e <= 18'sd0; p2_bm <= 64'd0;
				end
				else if (s1_az) begin
					// a zero source: the destination, rounded
					p2_k <= 2'd0; p2_s <= s1_bs;
					p2_e <= $signed({1'b0, s1_be}); p2_bm <= s1_bm;
				end
				else if (s1_bz) begin
					p2_k <= 2'd0; p2_s <= sa;
					p2_e <= $signed({1'b0, s1_ae}); p2_bm <= s1_am;
				end
				else begin
					aswap = (s1_ae > s1_be) || (s1_ae == s1_be && s1_am > s1_bm);
					dd    = aswap ? (s1_ae - s1_be) : (s1_be - s1_ae);
					p2_k  <= 2'd1;
					p2_es <= (sa != s1_bs);
					p2_s  <= aswap ? sa : s1_bs;
					p2_e  <= $signed({1'b0, aswap ? s1_ae : s1_be});
					p2_bm <= aswap ? s1_am : s1_bm;
					p2_sm <= aswap ? s1_bm : s1_am;
					p2_sh <= (dd > 17'd66) ? 7'd67 : dd[6:0];
				end
			end
			2'd2: begin
				p2_s <= s1_as ^ s1_bs;
				if (s1_az || s1_bz) begin
					p2_k <= 2'd0; p2_z <= 1'b1; p2_e <= 18'sd0; p2_bm <= 64'd0;
				end
				else begin
					p2_k  <= 2'd2;
					p2_e  <= $signed({1'b0, s1_ae}) + $signed({1'b0, s1_be}) - 18'sd16383;
					p2_bm <= s1_am;
					p2_sm <= s1_bm;
				end
			end
			default: begin
				// FMOVE; FABS clears the sign, FNEG flips it (F_EXEC)
				p2_k <= 2'd0; p2_z <= s1_az;
				p2_s <= (p1_op == 7'h18 || p1_op == 7'h58 || p1_op == 7'h5C) ? 1'b0 :
				        (p1_op == 7'h1A || p1_op == 7'h5A || p1_op == 7'h5E) ? ~s1_as : s1_as;
				p2_e <= s1_az ? 18'sd0 : $signed({1'b0, s1_ae});
				p2_bm <= s1_am;
			end
		endcase

		//----------------------------------------------------------------- P2
		p3_v  <= p2_v;
		p3_ni <= p2_ni;
		p3_op <= p2_op;
		p3_d  <= p2_d;
		p3_k  <= p2_k;
		p3_z  <= p2_z;
		p3_s  <= p2_s;
		p3_e  <= p2_e;
		p3_es <= p2_es;
		p3_bm <= p2_bm;
		p3_sv <= p2_sv;

		//----------------------------------------------------------------- P3
		p4_v  <= p3_v;
		p4_op <= p3_op;
		p4_d  <= p3_d;
		p4_s  <= p3_s;
		p4_z  <= p3_z;
		p4_e  <= p3_e;
		p4_n  <= p3_ni && !p3_z;      // an integer move: normalize
		p4_g  <= 3'd0;
		p4_m  <= p3_bm;
		case (p3_k)
			2'd1: begin : p3_add
				reg [67:0] sum;
				reg [66:0] diff;
				if (!p3_es) begin
					sum = {1'b0, p3_bm, 3'd0} + {1'b0, p3_sv};
					if (sum[67]) begin
						p4_m <= sum[67:4];
						p4_g <= {sum[3], sum[2], sum[1] | sum[0]};
						p4_e <= p3_e + 18'sd1;
					end
					else begin
						p4_m <= sum[66:3];
						p4_g <= sum[2:0];
					end
				end
				else begin
					diff = {p3_bm, 3'd0} - p3_sv;
					if (diff == 67'd0) begin
						p4_z <= 1'b1;
						p4_s <= (rnd_mode == 2'b10);
					end
					else begin
						p4_m <= diff[66:3];
						p4_g <= diff[2:0];
						p4_n <= 1'b1;
					end
				end
			end
			2'd2: begin
				// the partial products P2 registered, summed here
				if (mul_out[127]) begin
					p4_m <= mul_out[127:64];
					p4_g <= {mul_out[63], mul_out[62], (mul_out[61:0] != 0)};
					p4_e <= p3_e + 18'sd1;
				end
				else begin
					p4_m <= mul_out[126:63];
					p4_g <= {mul_out[62], mul_out[61], (mul_out[60:0] != 0)};
				end
			end
			default: ;
		endcase

		//----------------------------------------------------------------- P4
		p5_v  <= p4_v;
		p5_op <= p4_op;
		p5_d  <= p4_d;
		p5_s  <= p4_s;
		p5_z  <= p4_z;
		p5_e  <= p4_e;
		p5_m  <= p4_m;
		p5_g  <= p4_g;
		p5_nice <= p5_nice_n;
		if (p4_n) begin : p4_norm
			reg [6:0]  lz;
			reg [66:0] nv;
			lz = p4_lz;
			if (lz == 7'd64) begin
				p5_m <= {p4_g, 61'd0};
				p5_g <= 3'd0;
				p5_e <= p4_e - 18'sd64;
			end
			else begin
				nv = p4_shifted;
				p5_m <= nv[66:3];
				p5_g <= nv[2:0];
				p5_e <= p4_e - {11'd0, lz};
			end
		end

		//----------------------------------------------------------------- P5
		p6_v <= p5_v;
		p6_d <= p5_d;
		p6_s <= p5_s;
		p6_z <= p5_z;
		p6_inx <= 1'b0;
		p6_nice <= p5_nice;
		if (p5_z) begin
			p6_e <= 17'd0;
			p6_m <= 64'd0;
		end
		else begin : p5_round
			reg [64:0] mr, mk, mi;
			reg [63:0] rmask, rinc;
			reg        inx, up;
			reg signed [17:0] er;
			case (prec_of(p5_op))
				2'd1: begin
					up = round_up(p5_m[40], p5_m[39], (p5_m[38:0] != 0) || (p5_g != 0), p5_s);
					inx = (p5_m[39:0] != 0) || (p5_g != 0);
					rmask = 64'hFFFF_FF00_0000_0000;
					rinc  = 64'h0000_0100_0000_0000;
				end
				2'd2: begin
					up = round_up(p5_m[11], p5_m[10], (p5_m[9:0] != 0) || (p5_g != 0), p5_s);
					inx = (p5_m[10:0] != 0) || (p5_g != 0);
					rmask = 64'hFFFF_FFFF_FFFF_F800;
					rinc  = 64'h0000_0000_0000_0800;
				end
				default: begin
					up = round_up(p5_m[0], p5_g[2], p5_g[1:0] != 0, p5_s);
					inx = (p5_g != 0);
					rmask = 64'hFFFF_FFFF_FFFF_FFFF;
					rinc  = 64'h0000_0000_0000_0001;
				end
			endcase
			mk = {1'b0, p5_m & rmask};
			mi = mk + {1'b0, rinc};
			mr = up ? mi : mk;
			er = (up && mi[64]) ? (p5_e + 18'sd1) : p5_e;
			if (mr[64]) mr = {2'b01, 63'd0};
			p6_e <= er[16:0];
			p6_m <= mr[63:0];
			p6_inx <= inx;
		end

		//------------------------------------------------- P6 (and P7 after)
		p7_v <= p6_v;
		p7_s <= p6_s;
		p7_e <= p6_e;
		p7_m <= p6_m;
		p7_z <= p6_z;
	end
end

// single physical write port.  The core cannot dispatch FMOVEM while the FPU
// is in F_WB; keeping the explicit priority also matches the old procedural
// assignment order if that invariant is ever violated.
wire fr_wb_we = wbw;
// synthesis translate_off
always @(posedge clk)
	if (nreset && fst == F_SRC && r_op == 7'h7F &&
	    r_rng != {a_ex < 18'sd16257, a_ex < 18'sd16130, a_ex < 18'sd15361,
	              a_ex < 18'sd15234, a_ex > 18'sd16445, a_ex < 18'sd16382}) begin
		$display("FAIL: FPU store range checks %b disagree with the exponent %h", r_rng, a_e);
		$finish;
	end
always @(posedge clk)
	if (nreset && ((fst == F_WB && (wk != x_kill || r_ct != (r_op == 7'h38 || r_op == 7'h3A))) ||
	               wbw != (fst == F_WB && !wk && !r_ct))) begin
		$display("FAIL: FPU writeback kill %b, x_kill %b (FCMP/FTST %b)", wk, x_kill, r_ct);
		$finish;
	end
// synthesis translate_on
wire [14:0] fr_wb_e = (a_t == T_ZERO) ? 15'd0 :
                       (a_t == T_INF || a_t == T_NAN) ? 15'h7FFF : a_e[14:0];
// the 68060 writes every infinity with a zero mantissa (WinUAE
// infinity_clear_intbit: move, abs, neg, add, sub, mul, div, sqrt, int)
wire [63:0] fr_wb_m = (a_t == T_ZERO || a_t == T_INF) ? 64'd0 : wz ? z_m : a_m;
wire [79:0] p6_wd   = {p6_s, p6_z ? 15'd0 : p6_e[14:0], p6_z ? 64'd0 : p6_m};
wire [79:0] fm_wd   = {fm_wdata[95], fm_wdata[94:80], fm_wdata[63:0]};
wire        fr_bank_we = fm_we || fr_wb_we || p6_v;
wire  [2:0] fr_bank_wa = p6_v ? p6_d : fr_wb_we ? r_dst : fm_sel;
wire [79:0] fr_bank_wd = p6_v ? p6_wd : fr_wb_we ? {a_s, fr_wb_e, fr_wb_m} : fm_wd;

// unpack_x's tag of an extended image
function [1:0] tag_x;
	input [14:0] e;
	input [63:0] m;
	begin
		tag_x = (e == 15'h7FFF) ? ((m[62:0] != 63'd0) ? T_NAN : T_INF) :
		        (m == 64'd0) ? T_ZERO : T_NUM;
	end
endfunction
// the written value's flags, each formed from its own source beside the
// port's mux: a result's class is the state machine's tag a_t (checked in
// simulation against the written image)
// A result's flags (P6, F_WB) are written with it; an FMOVEM image's are
// formed from the registered image and written the cycle after it
// (fmq_*): its validity is immediate, and a request waits that cycle.
wire        wr_imm   = p6_v || fr_wb_we;
wire  [1:0] wr_tag   = p6_v ? tag_x(p6_wd[78:64], p6_wd[63:0]) : a_t;
// (a result is never an unsupported data type: a number is normalized,
// the special classes have canonical exponents -- checked in simulation)
wire        wr_unsup = 1'b0;
wire        wr_nice  = p6_v ? nice_x(p6_wd[78:64], p6_wd[63:0]) : nice_x(fr_wb_e, fr_wb_m);
reg         fmq_v;
reg   [2:0] fmq_sel;
reg   [3:0] fmq_fl;           // {unsupported, nice, tag[1:0]}
always @(posedge clk) begin
	fmq_v   <= ce && fm_we && !p6_v && !fr_wb_we;
	fmq_sel <= fm_sel;
	fmq_fl  <= {unsupported_x(fm_wd[78:64], fm_wd[63:0]), nice_x(fm_wd[78:64], fm_wd[63:0]),
	            tag_x(fm_wd[78:64], fm_wd[63:0])};
end

// synthesis translate_off
always @(posedge clk)
	if (ce && wr_imm && wr_unsup != unsupported_x(fr_bank_wd[78:64], fr_bank_wd[63:0])) begin
		$display("FAIL: FPU write unsupported flag %b, the written image's %b (fst %0d, %h)",
		         wr_unsup, unsupported_x(fr_bank_wd[78:64], fr_bank_wd[63:0]), fst, fr_bank_wd);
		$finish;
	end
always @(posedge clk)
	if (ce && wr_imm && wr_tag != tag_x(fr_bank_wd[78:64], fr_bank_wd[63:0])) begin
		$display("FAIL: FPU write tag %0d, the written image's %0d (fst %0d, %h)",
		         wr_tag, tag_x(fr_bank_wd[78:64], fr_bank_wd[63:0]), fst, fr_bank_wd);
		$finish;
	end
always @(posedge clk)
	if (nreset && fst == F_IDLE && rq && !pbusy && !fmq_v && !fr_bank_we &&
	    (src_tag != tag_x(fr_src_e, fr_src_m) || dst_tag != tag_x(fr_dst_e, fr_dst_m) ||
	     dst_unsup != unsupported_x(fr_dst_e, fr_dst_m))) begin
		$display("FAIL: FPU register class flags disagree with the registers (src %0d dst %0d)",
		         src_r, dst_r);
		$finish;
	end
always @(posedge clk)
	if (nreset && (fst == F_BIN0 || fst == F_EXEC) && b_unsup != unsupported_x(b_e[14:0], b_m)) begin
		$display("FAIL: FPU b_unsup %b, the destination classifies as %b", b_unsup,
		         unsupported_x(b_e[14:0], b_m));
		$finish;
	end
// synthesis translate_on

// the registers' flags one cycle on: valid (a write; FRESTORE NULL clears
// all, but not an F_WB write in the same cycle -- the order of the
// sequential assignments), unsupported (FRESTORE NULL clears), the tag
genvar gr;
generate for (gr = 0; gr < 8; gr = gr + 1) begin : rfl
	wire wr = wr_imm && fr_bank_wa == gr;
	wire fq = fmq_v && fmq_sel == gr;
	assign rfl_next[4*gr +: 4] = {
		(fr_wb_we && r_dst == gr) ||
		(!fp_reset && ((p6_v && p6_d == gr) || (fm_we && fm_sel == gr) || fr_valid[gr])),
		fp_reset ? 1'b0 : fq ? fmq_fl[3] : wr ? wr_unsup : fr_unsup[gr],
		fq ? fmq_fl[1:0] : wr ? wr_tag : fr_tag[gr]};
end endgenerate
// synthesis translate_off
reg [31:0] rfl_q;
always @(posedge clk) begin : rfl_check
	integer r;
	if (ce) rfl_q <= rfl_next;
	for (r = 0; r < 8; r = r + 1)
		if (nreset && $time > 0 && rfl_q[4*r +: 4] !== {fr_valid[r], fr_unsup[r], fr_tag[r]}) begin
			$display("FAIL: the registers' next flags %h, register %0d now %b%b%b", rfl_q[4*r +: 4],
			         r, fr_valid[r], fr_unsup[r], fr_tag[r]);
			$finish;
		end
end
// synthesis translate_on

// okv one cycle on: the writers' next state, P5's niceness as it is
// decided, P6's as it moves on, and the register file's flags after this
// cycle's write (every write makes the register valid) or FRESTORE NULL
always @* begin : okv_nx
	integer r;
	for (r = 0; r < 8; r = r + 1)
		okv_n[r] = pb14_n[r] ? 1'b0 :
		           pb5_n[r]  ? p5_nice_n :
		           pb6_n[r]  ? p5_nice :
		           fp_reset  ? 1'b0 :
		           (fmq_v && fmq_sel == r) ? fmq_fl[2] :
		           (wr_imm && fr_bank_wa == r) ? wr_nice :
		           (fr_valid[r] && fr_nice[r]);
end
// synthesis translate_off
always @(posedge clk)
	if (nreset && sel_x && (aok_x != okv[src_r] || bok_x != okv[dst_r])) begin
		$display("FAIL: the outside selection of okv %b%b, src %0d dst %0d: %b%b",
		         aok_x, bok_x, src_r, dst_r, okv[src_r], okv[dst_r]);
		$finish;
	end
always @(posedge clk) begin : okv_check
	integer r;
	for (r = 0; r < 8; r = r + 1)
		if (nreset && okv[r] != (pw(r) == 2'd1 ? 1'b0 : pw(r) == 2'd2 ? p5_nice :
		                         pw(r) == 2'd3 ? p6_nice : (fr_valid[r] && fr_nice[r]))) begin
			$display("FAIL: okv[%0d] %b disagrees with the pipeline and register flags", r, okv[r]);
			$finish;
		end
end
// synthesis translate_on

// synthesis translate_off
always @(posedge clk)
	if (ce && !fr_bank_we && !fmq_v && fr_src_unsup != unsupported_x(fr_src_e, fr_src_m)) begin
		$display("FAIL: fr_unsup[%0d] = %b, the register classifies as %b",
		         src_r, fr_src_unsup, unsupported_x(fr_src_e, fr_src_m));
		$finish;
	end
// synthesis translate_on

ap040_fp_regfile fpregs
(
	.clk(clk), .ce(ce), .we(fr_bank_we),
	.waddr(fr_bank_wa), .wdata(fr_bank_wd),
	.raddr_a(src_r), .rdata_a(fr_src_raw),
	.raddr_b(dst_r), .rdata_b(fr_dst_raw)
);

integer k;
always @(posedge clk) begin
	if (!nreset) begin
		for (k = 0; k < 8; k = k + 1) begin
			fr_s[k] <= 0;
			fr_e[k] <= 15'h7FFF;
			fr_m[k] <= 64'hFFFF_FFFF_FFFF_FFFF;
		end
	end
	else if (ce) begin
		if (fp_reset) begin
			for (k = 0; k < 8; k = k + 1) begin
				fr_s[k] <= 0;
				fr_e[k] <= 15'h7FFF;
				fr_m[k] <= 64'hFFFF_FFFF_FFFF_FFFF;
			end
		end
		if (fr_bank_we) begin
			fr_s[fr_bank_wa] <= fr_bank_wd[79];
			fr_e[fr_bank_wa] <= fr_bank_wd[78:64];
			fr_m[fr_bank_wa] <= fr_bank_wd[63:0];
		end
	end
end

// Exceptions (68060): the enabled ones, and OVFL and UNFL whether enabled
// or not (MC68060UM 6.6: nonmaskable, for the M68060SP to correct the
// default result).  Enabled SNAN, OPERR and DZ, and OVFL and UNFL, leave a
// destination register unmodified (6.6.4, 6.6.5: "the register is not
// affected, and a pre-instruction exception is reported"; the M68060SP
// reloads the destination and repeats the operation); an enabled INEX
// writes it before the trap.  (A memory destination, FMOVE OUT, is
// written in every case: its own path.)
wire [7:0] x_en   = (fpsr[15:8] & fpcr[15:8]) | {3'd0, fpsr[12], fpsr[11], 3'd0};
wire       x_any  = |x_en;
wire       x_kill = |(fpsr[14:13] & fpcr[14:13]) || (fpsr[10] && fpcr[10]) ||
                    fpsr[12] || fpsr[11];
// An enabled SNAN, OPERR or DZ still sets the condition codes from the
// default result (the quiet NaN, the default NaN, the infinity) that is not
// written: the M68060SP passes these straight to _real_snan/_operr/_dz
// without touching the FPSR, and Motorola's ftest.sa expects FPSR
// $09004080 after FADD.B #2,FP0 with FP0 a negative SNAN, $01002080 after
// -inf + +inf, $02000410 after FDIV.B #0 of 2.  OVFL and UNFL do not: the
// M68060SP forms their result and condition codes itself.
wire       x_cc   = |(fpsr[14:13] & fpcr[14:13]) || (fpsr[10] && fpcr[10]);

// the opmode's move class (FMOVE, FSMOVE, FDMOVE) and FSUB family
function op_mov;
	input [6:0] op;
	op_mov = (op == 7'h00) || (op == 7'h40) || (op == 7'h44);
endfunction
function op_fsub;
	input [6:0] op;
	op_fsub = (op == 7'h28) || (op == 7'h68) || (op == 7'h6C);
endfunction

// the class of a memory operand by its format: unpack_x's tags (L/W/B
// zero or a number), C_DEN for a denormalized single or double or an
// unsupported extended -- formed from din as the dispatch latches it, so
// F_SRC decides from three flip-flops
function [2:0] din_class;
	input [95:0] d;
	input  [2:0] f;
	begin
		case (f)
			3'd0: din_class = (d[95:64] == 32'd0) ? {1'b0, T_ZERO} : {1'b0, T_NUM};
			3'd4: din_class = (d[95:80] == 16'd0) ? {1'b0, T_ZERO} : {1'b0, T_NUM};
			3'd6: din_class = (d[95:88] == 8'd0)  ? {1'b0, T_ZERO} : {1'b0, T_NUM};
			3'd1: din_class = (d[94:87] == 8'hFF) ? ((d[86:64] != 0) ? {1'b0, T_NAN} : {1'b0, T_INF}) :
			                  (d[94:87] == 8'd0)  ? ((d[86:64] != 0) ? C_DEN : {1'b0, T_ZERO}) :
			                  {1'b0, T_NUM};
			3'd5: din_class = (d[94:84] == 11'h7FF) ? ((d[83:32] != 0) ? {1'b0, T_NAN} : {1'b0, T_INF}) :
			                  (d[94:84] == 11'd0)   ? ((d[83:32] != 0) ? C_DEN : {1'b0, T_ZERO}) :
			                  {1'b0, T_NUM};
			default: din_class = unsupported_x(d[94:80], d[63:0]) ? C_DEN :
			                     {1'b0, tag_x(d[94:80], d[63:0])};
		endcase
	end
endfunction

// synthesis translate_off
always @(posedge clk)
	if (nreset && sel_x && fst == F_IDLE && rq && op_class == 3'b010 && din_cls != din_class(din, src_fmt)) begin
		$display("FAIL: the outside class of the memory operand %0d, its own %0d", din_cls,
		         din_class(din, src_fmt));
		$finish;
	end
// synthesis translate_on

// the dispatch's operand classes, from the per-register flags (an invalid
// register reads as the default NaN)
wire [1:0] src_tag   = sfl[3] ? sfl[1:0] : T_NAN;
wire [1:0] dst_tag   = dfl[3] ? dfl[1:0] : T_NAN;
wire       dst_unsup = dfl[3] && dfl[2];
// FPCR enables all clear (no enabled exception can be taken: wb_ok)
reg        fpcr_en0;
// the command's decodes for the dispatch: {in hardware, a binary operation,
// a move, opclass 011 (a store), opclass 000 (a register source), FMOVECR
// (opclass 010, format 7), a packed format} -- registered from the next
// command's fields with sel_x (the dispatch decides from flip-flops), else
// decoded here
function [6:0] cmd_dec;
	input [6:0] opm;
	input [2:0] cls, fmt;
	cmd_dec = {op_in_hw(opm), bin_op(opm), op_mov(opm), cls == 3'b011, cls == 3'b000,
	           cls == 3'b010 && fmt == 3'd7, fmt == 3'd3};
endfunction
reg  [6:0] cd_q;
always @(posedge clk) cd_q <= cmd_dec(opmode_n, op_class_n, src_fmt_n);
wire [6:0] cd = sel_x ? cd_q : cmd_dec(opmode, op_class, src_fmt);
wire cd_hw = cd[6], cd_bin = cd[5], cd_mov = cd[4], cd_st = cd[3], cd_reg = cd[2],
     cd_mcr = cd[1], cd_pk = cd[0];
// synthesis translate_off
always @(posedge clk)
	if (nreset && sel_x && cd_q != cmd_dec(opmode, op_class, src_fmt)) begin
		$display("FAIL: the registered command decode %b, the command's %b", cd_q,
		         cmd_dec(opmode, op_class, src_fmt));
		$finish;
	end
// synthesis translate_on

always @(posedge clk) begin : fsm
	// the handshake outputs' next values, so their registered summaries
	// (known, end_ok) are flip-flops of their own
	reg n_done, n_unimp, n_unsupp, n_exc, n_acc, n_wbok;
	reg [4:0] n_fst;
	reg [25:0] n1h;         // the next state one-hot, as each transition sets it
	reg n_wk;
	if (!nreset) begin
		fst <= F_IDLE; fst1h <= 26'd1; acc_r <= 1'b0; wbok_r <= 1'b0; known <= 1'b0; end_ok <= 1'b0;
		lpf <= 1'b0; wk <= 1'b0; wbw <= 1'b0; r_ct <= 1'b0; r_rng <= 6'd0; r_dcnt <= 7'd0; r_icnt <= 7'd0;
		done <= 0; unimp <= 0; unsupp <= 0; exc_req <= 0; exc_vec <= 0;
		fpcr <= 0; fpsr <= 0; fpiar <= 0; fpcr_en0 <= 1'b1;
		fpu_used <= 0;
		fstate_et <= 0; et_cap <= 0;
		sh_src <= 0;
		dout <= 0;
		r_fmt <= 0; r_dst <= 0; r_op <= 0; r_din <= 0;
		r_ae7 <= 0;
		r_bin <= 0; r_mov <= 0; r_fsub <= 0; r_sgl <= 0; r_kind <= 0; r_prec <= 0;
		r_dcls <= 0;
		a_s <= 0; a_e <= 0; a_m <= 0; a_t <= 0; z_m <= 0; zr <= 0; wz <= 0;
		sh_v <= 0; sh_cnt <= 0;
		pk_neg <= 0; pk_isz <= 0; pk_mg <= 0; pk_sat <= 0; r_lde <= 0; pk_lo <= 0; pk_ovf <= 0; int_z <= 0; unp_m <= 0;
		b_s <= 0; b_e <= 0; b_m <= 0; b_t <= 0; b_unsup <= 0;
		grs <= 0; eff_sub <= 0; acc_hi <= 0;
		qv <= 0; qr <= 0; srem <= 0; srad <= 0; loop_n <= 0; op_kind <= 0; okh <= 4'd0;
		sh_ret <= F_PACKI; e_w <= 0; r_pr <= 0;
		n_mode <= N_OPN;
		// Invalid entries read as the default positive nonsignaling NaN.
		fr_valid <= 0;
		fr_unsup <= 0;
		fr_nice  <= 0;
		req_pend <= 0;
	end
	else if (ce) begin
		n_done = 1'b0; n_unimp = 1'b0; n_unsupp = 1'b0; n_exc = 1'b0;
		n_acc = acc_r; n_wbok = 1'b0;
		n_fst = fst; n1h = fst1h; n_wk = wk;
		et_cap <= 1'b0;
		if (wr_imm) begin
			fr_unsup[fr_bank_wa] <= wr_unsup;
			fr_nice[fr_bank_wa]  <= wr_nice;
			fr_tag[fr_bank_wa]   <= wr_tag;
		end
		if (fmq_v) begin
			fr_unsup[fmq_sel] <= fmq_fl[3];
			fr_nice[fmq_sel]  <= fmq_fl[2];
			fr_tag[fmq_sel]   <= fmq_fl[1:0];
		end
		// a request the pipeline or the state machine cannot take yet
		// (the pipeline draining, or a source still being computed)
		req_pend <= rq && !(fst1h[F_IDLE] && (pipe_issue || (!pbusy && !fmq_v)));
		// the multiplier's operands: an FMUL in P1 (the state machine is
		// idle whenever the pipeline holds an operation), or the state
		// machine's (F_BIN0: the partial products form during F_BIN)
		if (p1_v && pipe_kind(p1_op) == 2'd2) begin
			mul_x <= s1_am;
			mul_y <= s1_bm;
		end
		else if (fst1h[F_BIN0]) begin
			mul_x <= am_eff;
			mul_y <= bm_eff;
		end
		// the pipeline's writeback (P6): FPSR as F_WB and F_ROUND leave it
		if (p6_v) begin
			fr_valid[p6_d] <= 1;
			fpsr[15:8]  <= p6_inx ? 8'h02 : 8'h00;    // INEX2
			if (p6_inx) fpsr[3] <= 1;                 // accrued INEX
			fpsr[27:24] <= {p6_s, p6_z, 1'b0, 1'b0};
		end

		// side ports, independent of the FSM
		if (cr_we) begin
			case (cr_sel)
				2'd0: fpiar <= cr_wdata;
				2'd1: fpsr <= cr_wdata & 32'h0FFF_FFF8;
				// the 68060 FPCR has no bits 3:0 (WinUAE fpcr_mask 0xfff0)
				default: begin
					fpcr <= cr_wdata & 32'h0000_FFF0;
					fpcr_en0 <= (cr_wdata[15:8] == 8'd0);
				end
			endcase
			fpu_used <= 1;
		end
		if (ia_we) fpiar <= ia_wdata;
		if (bsun_req) begin
			fpsr[15] <= 1;
			fpsr[7] <= 1;
			fpu_used <= 1;
		end
		if (fm_we) begin
			fr_valid[fm_sel] <= 1;
			fpu_used <= 1;
		end
		if (fp_reset) begin
			fpcr <= 0; fpsr <= 0; fpiar <= 0; fpcr_en0 <= 1'b1;
			fpu_used <= 0;
			// FRESTORE of a NULL frame returns every data register to the
			// architectural default NaN through the validity view above.
			fr_valid <= 0;
			fr_unsup <= 0;
			fr_nice  <= 0;
		end
		if (frestore_idle) fpu_used <= 1;
		if (frestore_we) fstate_et <= {frestore_wd[79:64], 16'd0, frestore_wd[63:0]};
		if (unimp_ack) begin
			fstate_et <= 96'd0;
			if (!unimp_keep) fpu_used <= 1;
			if (fs_clr) fpsr[15:8] <= 8'd0;
		end

		// one-hot on the registered state (fst1h): every state's selects are
		// a flip-flop each, not a decode of fst
		case (1'b1)   // synthesis parallel_case
			fst1h[F_IDLE]: begin
				// The command, its decodes and the operands are latched in
				// every idle cycle (without a request they are don't-cares):
				// only the state, the handshake and the status byte follow
				// the request's decisions, so no decision is in front of the
				// working registers' inputs.  The destination operand and
				// the source register's class come from the flags; the
				// exception operand of a fault here is staged in sh_src.
				r_fmt  <= src_fmt;
				r_ae7  <= fpsr[7];
				r_dst  <= dst_r;
				r_op   <= (op_class == 3'b011) ? 7'h7F : opmode;   // internal: store
				r_ct   <= (opmode == 7'h38 || opmode == 7'h3A) && op_class != 3'b011;
				// a register store's exponent range checks (F_SRC): below
				// the single/double minimum normal, saturating the
				// denormalizing shift, the integer's range
				r_rng  <= {fr_src_e < 15'd16257, fr_src_e < 15'd16130, fr_src_e < 15'd15361,
				           fr_src_e < 15'd15234, fr_src_e > 15'd16445, fr_src_e < 15'd16382};
				// ... and its shift counts: -126 - sE and -1022 - sE (16257
				// and 15361 - e: both 1 - e mod 128), 63 - sE (16446 - e)
				r_dcnt <= 7'd1 - fr_src_e[6:0];
				r_icnt <= 7'd62 - fr_src_e[6:0];
				n_wk = 1'b0;
				r_din  <= din;
				unp_m  <= unp_of(din, src_fmt);
				r_lde  <= lde_of(din, src_fmt, sel_x ? din_cls : din_class(din, src_fmt));
				r_dcls <= sel_x ? din_cls : din_class(din, src_fmt);
				r_bin  <= bin_op(opmode);
				r_kind <= bin_kind(opmode);
				r_mov  <= op_mov(opmode);
				r_fsub <= op_fsub(opmode);
				r_sgl  <= op_sgl(opmode);
				r_prec <= prec_of(opmode);
				b_s <= fr_dst_s; b_e <= {2'd0, fr_dst_e}; b_m <= fr_dst_m;
				b_t <= dst_tag;  b_unsup <= dst_unsup;
				a_s <= fr_src_s; a_e <= {2'd0, fr_src_e}; a_m <= fr_src_m;
				a_t <= src_tag;  // (a memory operand's: F_SRC classifies)
				op_kind <= bin_kind(opmode); okh <= kind1h(bin_kind(opmode));
				grs <= 3'd0;
				e_w <= $signed({3'd0, fr_src_e});
				zr  <= 1'b0;
				wz  <= 1'b0;
				sh_src <= (!cd_st && (cd_mcr || !cd_hw)) ? 96'd0 :
				          (!cd_st && !cd_reg && cd_pk) ? {32'd0, din[63:0]} :
				          {fr_src_s, fr_src_e, 16'd0, fr_src_m};
				if (pipe_issue) begin
					// into the pipeline: complete as far as the core is
					// concerned (pdone, this cycle)
					fpu_used <= 1;
				end
				// (an FMOVEM image's flags written the cycle before are
				// still to be written: one cycle more)
				else if (rq && !pbusy && !fmq_v) begin
					// FPSR exception status is per instruction.  The accrued
					// exception byte is intentionally retained until software
					// writes FPSR.  FMOVECR (opclass 010 fmt 7) faults before
					// WinUAE's fpsr_clear_status runs, so it must leave the
					// exception byte untouched; nonexisting opmodes never reach
					// the FPU at all (classified in the core).
					if (!cd_mcr)
						fpsr[15:8] <= 8'd0;
					if (cd_st) begin
						// FMOVE FPn,<ea>: packed decimal and denormal/unnormal
						// register contents are unsupported data types; the
						// register value goes to the frame's exception operand
						if (cd_pk || src_fmt == 3'd7 || fr_src_unsup) begin
							n_unsupp = 1'b1; et_cap <= 1'b1;
							fpu_used <= 1;
						end
						else begin n_fst = F_SRC; n1h = 26'd1 << F_SRC; n_acc = 1'b0; end   // F_SRC routes stores via r_op = STORE
					end
					else if (cd_mcr || !cd_hw) begin
						// unimplemented in the FPU (the core traps these before
						// dispatch): IDLE, the operand zero
						n_unimp = 1'b1; et_cap <= 1'b1;
						fpu_used <= 1;
					end
					else if (cd_reg) begin
						if (fr_src_unsup) begin
							n_unsupp = 1'b1; et_cap <= 1'b1;
							fpu_used <= 1;
						end
						// a binary operation on a non-NaN source needs nothing
						// from F_EXEC but its bookkeeping (no SNaN to quiet, no
						// sign to change): straight to F_BIN0
						else if (cd_bin && src_tag != T_NAN) begin
							n_fst = F_BIN0; n1h = 26'd1 << F_BIN0; n_acc = 1'b0;
						end
						// a move: F_EXEC's work for it, here (its exception
						// shadow, GRS, the working exponent), then F_ROUND
						else if (cd_mov && src_tag != T_NAN) begin
							n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
						end
						else begin n_fst = F_EXEC; n1h = 26'd1 << F_EXEC; n_acc = 1'b0; end
					end
					// opclass 010, memory source: packed decimal (fmt 3) is
					// an unsupported data type.  The core has fetched all
					// twelve bytes; the frame's operand is the second and
					// third long words.
					else if (cd_pk) begin
						n_unsupp = 1'b1; et_cap <= 1'b1;
						fpu_used <= 1;
					end
					else begin n_fst = F_SRC; n1h = 26'd1 << F_SRC; n_acc = 1'b0; end
				end
			end

			fst1h[F_SRC]: begin : f_src
				if (r_op == 7'h7F) begin : f_store
					// register store: X is raw; S/D round (F_PKR encodes) or
					// go through the shifter as denormals; B/W/L go through
					// the shifter.  The shift is set up whatever the case
					// decides: a single or double below the precision's
					// minimum normal shifts into the denormal range by
					// -126 - sE or -1022 - sE (the same low seven bits,
					// r_dcnt; saturated at 127); an integer's integer part
					// lands in sh_v[66:3] (by 63 - sE, r_icnt), a value below
					// one is a sticky bit alone, a zero's significand is zero
					if (r_fmt == 3'd1 || r_fmt == 3'd5) begin
						sh_v   <= {a_m, 3'd0};
						sh_cnt <= ((r_fmt == 3'd5) ? r_rng[2] : r_rng[4]) ? 7'd127 : r_dcnt;
						sh_ret <= F_PACKS;
					end
					else begin
						sh_v   <= (a_t == T_NUM && r_rng[0]) ? 67'd1 : {a_m, 3'd0};
						sh_cnt <= r_icnt;
						sh_ret <= F_PACKI;
					end
					case (r_fmt)
						3'd2: begin
							// X passes the register image through, except
							// a signaling NaN: stored quieted with SNAN and
							// accrued IOP, then the F_STDONE enabled-trap
							// check (6.6.2: written, then the SNAN trap).
							// Anything else sets no status bits and is done
							// now.  (FMOVEM's raw images go through fm_*.)
							if (a_t == T_NAN && !a_m[62]) begin
								dout <= {a_s, a_e[14:0], 16'd0,
								         a_m | 64'h4000_0000_0000_0000};
								fpsr[14] <= 1;
								fpsr[7]  <= 1;
								fpu_used <= 1; n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; n_acc = 1'b0;
							end
							else begin
								dout <= {a_s, a_e[14:0], 16'd0, a_m};
								n_done = 1'b1; fpu_used <= 1;
								n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
							end
						end
						3'd1, 3'd5: begin : pk_sd
							reg dbl;
							dbl = (r_fmt == 3'd5);
							if (a_t != T_NUM) begin
								// NaN payload passes through commonNaN form:
								// the quiet bit is FORCED in the output and a
								// signaling source raises SNAN
								if (!dbl)
									dout <= (a_t == T_ZERO) ? {a_s, 95'd0} :
									        (a_t == T_INF)  ? {a_s, 8'hFF, 23'd0, 64'd0} :
									                          {a_s, 8'hFF,
									                           a_m[62:40] | 23'h400000, 64'd0};
								else
									dout <= (a_t == T_ZERO) ? {a_s, 95'd0} :
									        (a_t == T_INF)  ? {a_s, 11'h7FF, 52'd0, 32'd0} :
									                          {a_s, 11'h7FF,
									                           a_m[62:11] | 52'h8_0000_0000_0000,
									                           32'd0};
								if (a_t == T_NAN && !a_m[62]) begin
									fpsr[14] <= 1;
									fpsr[7]  <= 1;
								end
								fpu_used <= 1; n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; n_acc = 1'b0;  // OVFL/UNFL trap even when disabled (68060)
							end
							// below the precision's minimum normal exponent
							// (sE = a_e - 16383 < -126 or -1022): shift into the
							// denormal range, retaining G/R/S for the rounding
							// mode, by -126 - sE or -1022 - sE (saturated)
							else if (dbl ? r_rng[3] : r_rng[5]) begin
								n_fst = F_SHR; n1h = 26'd1 << F_SHR; n_acc = 1'b0;
							end
							// a number: rounded (sp_*, formed this cycle) and
							// encoded in F_PKR
							else begin n_fst = F_PKR; n1h = 26'd1 << F_PKR; n_acc = 1'b0; end
						end
						default: begin : pk_i
							// B/W/L: shift the mantissa so the integer part
							// lands in sh_v[66:3]; E = a_e - 16383 is the
							// position of the integer bit
							reg [63:0] qm;
							pk_isz <= (r_fmt == 3'd0) ? 2'd2 :
							          (r_fmt == 3'd4) ? 2'd1 : 2'd0;
							pk_neg <= a_s;
							pk_sat <= 1'b0;
							qm = a_m | 64'h4000_0000_0000_0000;
							if (a_t == T_ZERO) begin
								n_fst = F_PACKI; n1h = 26'd1 << F_PACKI; n_acc = 1'b0;
							end
							else if (a_t == T_NAN) begin
								// floatx80_to_int32/16/8: the QUIETED NaN's
								// top payload bits are stored; OPERR is only
								// raised for an already-quiet NaN, a
								// signaling one raises SNAN instead
								dout <= {(r_fmt == 3'd0) ? qm[63:32] :
								         (r_fmt == 3'd4) ? {qm[63:48], 16'd0} :
								                           {qm[63:56], 24'd0}, 64'd0};
								if (!a_m[62]) begin
									fpsr[14] <= 1;
									fpsr[7]  <= 1;
								end
								else begin
									fpsr[13] <= 1;
									fpsr[7]  <= 1;
								end
								fpu_used <= 1;
								// no enabled exception possible: done now
								if (fpcr_en0) begin n_done = 1'b1; n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; end
								else begin n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; end
								n_acc = 1'b0;
							end
							else if (a_t == T_INF || r_rng[1]) begin
								// infinity or far out of range (sE > 62):
								// OPERR with sign-dependent saturation
								pk_sat <= 1'b1;     // marker
								n_fst = F_PACKI; n1h = 26'd1 << F_PACKI; n_acc = 1'b0;
							end
							else if (r_rng[0]) begin
								// sE < -1: sticky only (sh_v below)
								n_fst = F_PACKI; n1h = 26'd1 << F_PACKI; n_acc = 1'b0;
							end
							else begin n_fst = F_SHR; n1h = 26'd1 << F_SHR; n_acc = 1'b0; end
						end
					endcase
				end
				else begin : f_load
					// memory operand to working format, by its class
					// (r_dcls, formed at dispatch).  The significand, the
					// working exponent and the operand shadow are written
					// whatever the class (the unpack bus unp_m serves every
					// format); the class selects the tag, the exponent field
					// and the next state.
					reg        sd, dbl;
					reg [16:0] e;            // a single's or double's biased exponent, rebiased
					reg [95:0] img;          // the operand's extended image (the frame's)
					sd  = (r_fmt == 3'd1 || r_fmt == 3'd5);
					dbl = (r_fmt == 3'd5);
					e   = dbl ? ({6'd0, r_din[94:84]} + 17'd15360)    // -1023+16383
					          : ({9'd0, r_din[94:87]} + 17'd16256);   // -127+16383
					a_s <= r_din[95];
					a_m <= unp_m;
					a_e <= r_lde;
					grs <= 3'd0;
					zr  <= 1'b0;
					op_kind <= r_kind; okh <= kind1h(r_kind);
					// (the working exponent: a number's; F_EXEC sets it for
					// the others, F_NSH's normalization for an integer)
					e_w <= $signed({1'b0, r_lde});
					// the extended image: a normal single/double's with the
					// explicit integer bit; a denormal's in the 060's "skewed"
					// form the M68060SP takes (fix_skewed_ops): exponent $3F80
					// / $3C00, the fraction under a clear J bit
					img = !sd ? {r_din[95], r_din[94:80], 16'd0, r_din[63:0]} :
					      (r_dcls == C_DEN) ?
					          (dbl ? {r_din[95], 15'h3C00, 16'd0, 1'b0, r_din[83:32], 11'd0}
					               : {r_din[95], 15'h3F80, 16'd0, 1'b0, r_din[86:64], 40'd0}) :
					      (dbl ? {r_din[95], e[14:0], 16'd0, 1'b1, r_din[83:32], 11'd0}
					           : {r_din[95], e[14:0], 16'd0, 1'b1, r_din[86:64], 40'd0});
					sh_src <= img;
					case (r_fmt)
						3'd0, 3'd4, 3'd6: begin
							a_t <= (r_dcls[1:0] == T_ZERO) ? T_ZERO : T_NUM;
							// (a_e: the integer bit at 63, 15 or 7)
							// a number: its leading zeros counted this cycle
							// (the normalizer, from unp_m), the shift in F_NSH
							n_mode <= N_OPN;
							if (r_dcls[1:0] == T_ZERO) begin n_fst = F_EXEC; n1h = 26'd1 << F_EXEC; end
							else begin n_fst = F_NSH; n1h = 26'd1 << F_NSH; end
							n_acc = 1'b0;
						end
						default: begin
							// a single or double: 68040 extended NaNs are
							// unnormal (the source payload with the explicit
							// integer bit clear; F_EXEC sets the quiet bit for
							// an SNaN), infinity is canonicalized during
							// writeback; a supported extended operand is
							// normalized already (unnormals and denormals trap)
							a_t <= r_dcls[1:0];
							if (r_dcls == C_DEN) begin
								// an unsupported data type (vector 55): a
								// denormalized single or double, an
								// unnormal or denormal extended
								n_unsupp = 1'b1; et_cap <= 1'b1;
								fpu_used <= 1;
								n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
							end
							// a binary operation on a number (any class for
							// an extended source but a NaN): straight to
							// F_BIN0, as for a register source
							else if (r_bin && (sd ? (r_dcls[1:0] == T_NUM) : (r_dcls[1:0] != T_NAN))) begin
								n_fst = F_BIN0; n1h = 26'd1 << F_BIN0; n_acc = 1'b0;
							end
							// a move: F_EXEC's work for it, here
							else if (r_mov && (sd ? (r_dcls[1:0] == T_NUM) : (r_dcls[1:0] != T_NAN))) begin
								n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
							end
							else begin n_fst = F_EXEC; n1h = 26'd1 << F_EXEC; n_acc = 1'b0; end
						end
					endcase
				end
			end

			fst1h[F_NCP]: begin
				// an integer source's normalized significand, from z_m (the
				// normalizer writes z_m only: a_m's input select stays narrow)
				a_m <= z_m;
				n_fst = F_EXEC; n1h = 26'd1 << F_EXEC; n_acc = 1'b0;
			end

			fst1h[F_NSH]: begin
				// the normalizing left shift, by the count registered the
				// cycle before (F_SRC, F_INTN, F_ADDN)
				z_m <= nsh_out[66:3];
				case (n_mode)
					N_OPN: begin
						// (an integer source: not zero, F_SRC routes that)
						a_e <= a_e - {10'd0, n_lz};
						n_fst = F_NCP; n1h = 26'd1 << F_NCP; n_acc = 1'b0;
					end
					N_POST: begin
						zr  <= 1'b1;
						grs <= nsh_out[2:0];
						e_w <= e_w - {11'd0, n_lz};
						if (n_allz) begin
							// an exact zero difference (the operands'
							// magnitudes were equal): +0, -0 rounding to minus
							a_t <= T_ZERO;
							a_s <= (rnd_mode == 2'b10);
							n_fst = F_WB; n1h = 26'd1 << F_WB;
						end
						else begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; end
						n_acc = 1'b1;
					end
					default: begin
						// FINT's integer: written back from z_m (wz)
						a_e <= a_e - {10'd0, n_lz};
						wz  <= 1'b1;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
				endcase
			end

			fst1h[F_EXEC]: begin
				// operand shadow for a possible deferred-exception frame
				sh_src <= {a_s, a_e[14:0], 16'd0, a_m};
				// a NaN quieted (written whatever follows: a datatype fault
				// goes idle)
				a_m[62] <= a_m[62] || (a_t == T_NAN);
				zr <= 1'b0;
				// FCMP evaluates its destination without passing through
				// F_BIN, so its unsupported-datatype check lives here -- and
				// it must precede the SNaN bookkeeping: the datatype fault
				// is taken before the arithmetic ever inspects a NaN, so the
				// status byte stays clean.
				if (r_op == 7'h38 && b_unsup) begin
					n_unsupp = 1'b1;
					et_cap <= 1'b1;   // (sh_src, written above)
					fpu_used <= 1;
					n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
				end
				else begin
				// Quiet signaling NaNs after recording SNAN.  Source and
				// FCMP destination checks occur before result dispatch so an
				// enabled SNAN is observed in F_WB and inhibits writeback.
				if (a_t == T_NAN && !a_m[62]) begin
					fpsr[14] <= 1;
					if (fpcr[14]) n_wk = 1'b1;   // (x_kill at F_WB)
					fpsr[7] <= 1;
				end
				if (r_op == 7'h38 && b_t == T_NAN && !b_m[62]) begin
					fpsr[14] <= 1;
					if (fpcr[14]) n_wk = 1'b1;   // (x_kill at F_WB)
					fpsr[7] <= 1;
				end
				case (r_op)
					7'h18, 7'h58, 7'h5C:
						if (a_t != T_NAN) a_s <= 0;                       // FABS
					7'h1A, 7'h5A, 7'h5E:
						if (a_t != T_NAN) a_s <= ~a_s;                    // FNEG
					default: ;
				endcase
				grs <= 3'd0;
				e_w <= a_ex;
				case (r_op)
					7'h38, 7'h3A: begin                          // FCMP/FTST
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					7'h00, 7'h40, 7'h44,
					7'h18, 7'h58, 7'h5C,
					7'h1A, 7'h5A, 7'h5E: begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1; end   // move class
					7'h04, 7'h41, 7'h45: begin               // FSQRT
						op_kind <= 4'd4; okh <= kind1h(4'd4);
						n_fst = F_BIN0; n1h = 26'd1 << F_BIN0; n_acc = 1'b0;
					end
					7'h01, 7'h03: begin                      // FINT, FINTRZ
						// a special value is its own integer; a number's
						// range checks form this cycle (ez_*), F_INTS acts
						if (a_t != T_NUM) begin
							n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
						end
						else begin n_fst = F_INTS; n1h = 26'd1 << F_INTS; n_acc = 1'b0; end
					end
					default: begin
						op_kind <= r_kind; okh <= kind1h(r_kind);
						n_fst = F_BIN0; n1h = 26'd1 << F_BIN0; n_acc = 1'b0;
					end
				endcase
				end
			end

			fst1h[F_BIN0]: begin
				// the operands' relations and the special cases are formed
				// this cycle (bo, bo_*); the multiplier's operands load
				n_fst = F_BIN; n1h = 26'd1 << F_BIN; n_acc = 1'b0;
			end

			fst1h[F_BIN]: begin : f_bin
				sh_src <= {a_s, a_e[14:0], 16'd0, a_m};
				// the significand, by outcome (bin_am: codes F_BIN0 registered)
				a_m <= bin_am;
				zr  <= 1'b0;
				// (bo is one-hot: checked in simulation)
				case (1'b1)   // synthesis parallel_case
					bo[BO_UNSUP]: begin
						// The destination datatype fault is taken with a clean
						// status byte: undo the source-SNaN record F_EXEC made
						// (the exception byte was zeroed at dispatch; r_ae7
						// holds the prior accrued-IOP bit)
						fpsr[14] <= 0;
						fpsr[7]  <= r_ae7;
						n_unsupp = 1'b1;
						et_cap <= 1'b1;   // (sh_src, written above)
						fpu_used <= 1;
						n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
					end
					bo[BO_NANB]: begin
						// NaN propagation, destination NaN preferred; a
						// signaling one raises SNAN
						if (!b_m[62]) begin
							fpsr[14] <= 1;
							if (fpcr[14]) n_wk = 1'b1;   // (x_kill at F_WB)
							fpsr[7] <= 1;
							b_m[62] <= 1;
						end
						a_s <= b_s;
						a_e <= b_e;
						a_t <= T_NAN;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_NANA]: begin
						a_t <= T_NAN;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_PASS]: begin
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_DNAN]: begin
						// operand error, the POSITIVE default NaN
						// (floatx80_default_nan: sign clear, all-ones mantissa)
						a_t <= T_NAN;
						a_s <= 0;
						a_e <= 17'h07FFF;
						fpsr[13] <= 1;
						if (fpcr[13]) n_wk = 1'b1;   // (x_kill at F_WB)
						fpsr[7] <= 1;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_SQN]: begin
						e_w <= bo_esq;
						grs <= 0;
						srad <= bo_sqodd ? {a_m, 2'b00} : {1'b0, a_m, 1'b0};
						srem <= 0;
						qr <= 0;
						lpf <= 1'b0;
						loop_n <= 0;
						// the exact square root of an even power of two
						if (bo_sqx) begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; end
						else begin n_fst = F_SQRTL; n1h = 26'd1 << F_SQRTL; end
						n_acc = 1'b1;
					end
					bo[BO_ADDINF]: begin
						// both-inf same sign returns the DEST operand raw
						// (addsub_swap_inf clear); a lone infinity keeps its
						// own mantissa bits
						a_s <= (a_t == T_INF && b_t != T_INF) ? s_a : b_s;
						a_t <= T_INF;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_ADDZZ]: begin
						a_s <= (s_a == b_s) ? s_a : (rnd_mode == 2'b10);
						a_t <= T_ZERO;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_ADDAZ]: begin
						a_s <= b_s;
						a_e <= b_e;
						a_t <= T_NUM;
						e_w <= $signed({b_e[16], b_e});
						n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
					end
					bo[BO_ADDBZ]: begin
						a_s <= s_a;
						e_w <= a_ex;
						n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
					end
					bo[BO_ADDGO]: begin
						// the larger magnitude to b, the smaller aligned to
						// it (F_SHR -- unless the shift is below a byte --
						// and F_SHR2, which adds)
						eff_sub <= (s_a != b_s);
						if (bo_swap) begin
							b_s <= s_a; b_e <= a_e; b_m <= a_m;
							a_s <= b_s; a_e <= b_e;
							e_w <= a_ex;
						end
						else begin
							a_s <= s_a;
							e_w <= $signed({b_e[16], b_e});
						end
						sh_v   <= {bo_swap ? b_m : a_m, 3'd0};
						sh_cnt <= bo_cnt;
						sh_ret <= F_ADDN;
						if (bo_c8) begin n_fst = F_SHR2; n1h = 26'd1 << F_SHR2; end
						else begin n_fst = F_SHR; n1h = 26'd1 << F_SHR; end
						n_acc = 1'b1;
					end
					bo[BO_MULINF]: begin
						// pass-through infinity keeps the raw mantissa of the
						// winning operand (dest first, floatx80_mul's order)
						a_t <= T_INF;
						a_s <= a_s ^ b_s;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_MULZ]: begin
						a_t <= T_ZERO;
						a_s <= a_s ^ b_s;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_MULN]: begin
						a_s <= a_s ^ b_s;
						e_w <= bo_emul;
						grs <= 0;
						lpf <= 1'b0;
						loop_n <= 0;
						// multiplication by an exact power of two only
						// changes sign/exponent and needs no multiply
						if (bo_p2) begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; end
						else begin n_fst = F_MULT; n1h = 26'd1 << F_MULT; end
						n_acc = 1'b1;
					end
					bo[BO_DIVBINF]: begin
						// dividend infinity passes through with its raw
						// mantissa bits
						a_t <= T_INF;
						a_s <= a_s ^ b_s;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_DIVDZ]: begin
						// finite dividend / zero: DZ + created infinity
						// (all-zero mantissa, floatx80_default_infinity)
						a_t <= T_INF;
						a_s <= a_s ^ b_s;
						fpsr[10] <= 1;
						if (fpcr[10]) n_wk = 1'b1;   // (x_kill at F_WB)
						fpsr[4] <= 1;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					bo[BO_DIVZ]: begin
						a_t <= T_ZERO;
						a_s <= a_s ^ b_s;
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
					end
					default: begin   // BO_DIVN
						a_s <= a_s ^ b_s;
						e_w <= bo_ediv;
						grs <= 0;
						// the first, integer quotient bit is formed already
						acc_hi <= bo_rem0;
						qv <= {66'd0, bo_q0};
						lpf <= 1'b0;
						loop_n <= 7'd1;
						// division by a power of two, or equal normalized
						// significands, is exact after exponent adjustment
						if (bo_dvx) begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; end
						else begin n_fst = F_DIVL; n1h = 26'd1 << F_DIVL; end
						n_acc = 1'b1;
					end
				endcase
			end

			fst1h[F_ADDN]: begin
				zr <= 1'b1;
				// the sum's carry renormalizes by one (a difference has
				// none), written whatever follows: a zero difference
				// writes a zero, a cancellation is renormalized by F_NSH
				// (its leading zeros counted this cycle, from add_r)
				z_m <= ur_m;
				grs <= ur_g;
				if (add_r[67]) e_w <= e_w + 18'sd1;
				n_mode <= N_POST;
				a_s <= b_s;
				a_t <= T_NUM;
				// a difference renormalizes in F_NSH (which also takes an
				// exact zero, from the counter stage's flag n_allz)
				if (!eff_sub) begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; end
				else begin n_fst = F_NSH; n1h = 26'd1 << F_NSH; end
				n_acc = 1'b1;
			end

			fst1h[F_MULT]: begin : f_mult
				zr <= 1'b1;
				// mul_pd: the full 128-bit product of the operands F_BIN0
				// loaded (partial products during F_BIN, their sums in the
				// three cycles since), taken in the loop's last cycle (lpf);
				// z_m and grs follow it every cycle (ur_m, ur_g)
				z_m <= ur_m;
				grs <= ur_g;
				a_t <= T_NUM;
				if (lpf) begin
					if (mul_pd[127]) e_w <= e_w + 18'sd1;
					n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
				end
				else begin
					loop_n <= loop_n + 7'd1;
					lpf    <= (loop_n == 7'd2);
				end
			end

			fst1h[F_DIVL]: begin : f_divl
				zr <= 1'b1;
				// the quotient so far, normalized by its integer bit, follows
				// it every cycle (ur_m, ur_g); taken in the loop's last cycle
				z_m <= ur_m;
				grs <= ur_g;
				a_t <= T_NUM;
				if (lpf) begin
					if (!qv[66]) e_w <= e_w - 18'sd1;
					n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1;
				end
				else begin
					// two restoring fraction bits per cycle (66 = 2 x 33)
					acc_hi <= {1'b0, dv_rem};
					qv <= {qv[64:0], dv_q1, dv_q2};
					loop_n <= loop_n + 7'd1;
					lpf    <= (loop_n == 7'd33);
				end
			end

			fst1h[F_SQRTL]: begin : f_sqrtl
				zr <= 1'b1;
				// the root so far is the result's significand, written every
				// cycle (the radicand is in srad)
				z_m <= ur_m;
				grs <= ur_g;
				a_t <= T_NUM;
				if (lpf) begin n_fst = F_ROUND; n1h = 26'd1 << F_ROUND; n_acc = 1'b1; end
				else begin
					// one result digit per cycle (66 of them)
					srad <= {srad[63:0], 2'b00};
					srem <= sq_rem;
					qr <= {qr[64:0], sq_q};
					loop_n <= loop_n + 7'd1;
					lpf    <= (loop_n == 7'd65);
				end
			end

			fst1h[F_ROUND]: begin
				// the rounding's increment and range compares form this
				// cycle (rn_*); a special value goes straight to writeback
				if (a_t != T_NUM) begin
					n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
				end
				else begin n_fst = F_RND2; n1h = 26'd1 << F_RND2; n_acc = 1'b1; end
			end

			fst1h[F_RND2]: begin : f_rnd2
				reg        carry, ovf, tomax;
				reg [63:0] mr;
				reg signed [17:0] er;
				// the increment carries out of the precision's top bit: the
				// significand becomes 1.0 and the exponent one more
				carry = rn_up && rn_one;
				mr  = carry ? 64'h8000_0000_0000_0000 : rn_up ? rn_mi[63:0] : (rin & rmask);
				er  = carry ? rn_e1 : e_w;
				ovf = carry ? rn_ge : rn_gt;
				tomax = (rnd_mode == 2'b01) ||
				        (rnd_mode == 2'b10 && !a_s) ||
				        (rnd_mode == 2'b11 && a_s);
				// the result, written whatever the range check decides (an
				// underflow keeps the destination: x_kill), and the
				// underflow's denormalizing shift set up beside it
				z_m <= !ovf ? mr : !tomax ? 64'd0 :      // created infinity: all-zero
				       r_sgl ? 64'hFFFF_FFFF_FFFF_FFFF :
				       (r_prec == 2'd1) ? 64'hFFFF_FF00_0000_0000 :
				       (r_prec == 2'd2) ? 64'hFFFF_FFFF_FFFF_F800 :
				                          64'hFFFF_FFFF_FFFF_FFFF;
				a_e <= (ovf && tomax) ? emax[16:0] : er[16:0];
				a_t <= (ovf && !tomax) ? T_INF : T_NUM;
				sh_v   <= {rin, grs};
				sh_cnt <= carry ? rn_x1 : rn_x0;
				wz     <= 1'b1;
				e_w    <= emin;
				r_pr   <= r_prec;
				sh_ret <= F_UNFL;
				if (ovf) begin
					fpsr[12] <= 1;              // OVFL
					n_wk = 1'b1;   // (x_kill at F_WB)
					fpsr[6]  <= 1;              // accrued OVFL
					fpsr[3]  <= 1;              // accrued INEX (from OVFL)
					// INEX2 itself only reports actually-discarded bits
					// (roundAndPackFloatx80 raises inexact on overflow
					// only when zSig0 & roundMask is nonzero)
					if (rn_inx) fpsr[9] <= 1;
					n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1;
				end
				else if (rn_lt) begin : f_unf
					// Gradual underflow.  At single or double rounding
					// precision the result is only subnormal with respect
					// to that precision, so it still fits the extended
					// format as a normal number: shift the significand
					// down to the precision's minimum exponent and test
					// what that loses (F_UNFL).  A tiny result takes UNFL
					// on the 68060 whatever the FPCR says and the
					// destination is kept (x_kill): only the status is
					// formed.
					fpsr[11] <= 1;              // UNFL status (tiny)
					n_wk = 1'b1;   // (x_kill at F_WB)
					// accrued UNFL is only recorded when the result is
					// ALSO inexact (updateaccrued: UNFL && INEX2); the
					// deep-flush is always inexact, the F_UNFL path
					// decides for itself
					if (carry ? rn_xb1 : rn_xb0) begin
						// the significand shifts out entirely
						fpsr[9] <= 1;           // INEX2
						fpsr[3] <= 1;
						fpsr[5] <= 1;           // accrued UNFL
						n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1;
					end
					else begin n_fst = F_SHR; n1h = 26'd1 << F_SHR; n_acc = 1'b1; end
				end
				else begin
					// Blanket INEX: FABS/FNEG round through the same
					// path as every op and report discarded bits even
					// for extended sources.  Twice hardware-adjudicated:
					// the 2026-08-07 FABS.X capture (FPSR $0208) and the
					// 2026-08-09 rerun on the revert-built bitstream,
					// which failed cputest exactly here.
					if (rn_inx) begin
						fpsr[9] <= 1;
						fpsr[3] <= 1;
					end
					n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
				end
			end

			fst1h[F_WB]: begin : f_wb
				reg nan;
				if (x_any) begin
					// the exception, its operand for the EXCP frame
					n_exc = 1'b1;
					exc_vec   <= fp_exception_vector(x_en);
					et_cap    <= 1'b1;
				end
				if (x_kill && !x_cc) begin
					// OVFL, UNFL: the destination is kept, the condition
					// codes are the M68060SP's
					fpu_used <= 1;
				end
				// (an enabled SNAN, OPERR, DZ: the condition codes as below,
				// the destination kept: fr_wb_we and fr_valid see x_kill)
				else if (r_op == 7'h38) begin
					// FCMP: condition codes from FPn - source (cmp_n,
					// cmp_z, from the compares formed in F_EXEC: the
					// operands are F_EXEC's -- it only quiets a NaN's
					// significand, and a NaN overrides).  A NaN compares unordered
					// with N clear on the 68060 (WinUAE sets
					// cmp_signed_nan for the 68040 only).
					nan = (a_t == T_NAN) || (b_t == T_NAN);
					fpsr[27:24] <= {cmp_n && !nan, cmp_z && !nan, 1'b0, nan};
				end
				else if (r_op == 7'h3A) begin
					// FTST
					fpsr[27:24] <= {a_s,
					                (a_t == T_ZERO),
					                (a_t == T_INF),
					                (a_t == T_NAN)};
				end
				else begin
					// writeback with condition codes, canonical encodings
					// for the special classes.  Infinity keeps whatever
					// mantissa the operation left in a_m: created
					// infinities carry all-zero bits and pass-through
					// infinities keep the operand's raw image -- the 68060
					// writes them with a zero mantissa (fr_wb_m).
					if (!x_kill) fr_valid[r_dst] <= 1;
					fpsr[27:24] <= {a_s,
					                (a_t == T_ZERO),
					                (a_t == T_INF),
					                (a_t == T_NAN)};
				end
				fpu_used <= 1;
				if (!x_any) n_done = 1'b1;
				n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
			end

			fst1h[F_INTS]: begin : f_ints
				// FINT of a number: the integer part lands in sh_v[66:3]
				// with the discarded bits as G, R, S (the integer store's
				// shift); a value of 2^63 and up (sE > 62) is integral
				reg signed [17:0] sE;
				sE = a_ez - 18'sd16383;
				sh_v   <= ez_small ? {64'd0, 3'b001} : {a_m, 3'd0};   // (sE < -1: sticky only)
				sh_cnt <= 7'd63 - sE[6:0];
				sh_ret <= F_INTR;
				if (ez_big) begin
					n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
				end
				else if (ez_small) begin n_fst = F_INTR; n1h = 26'd1 << F_INTR; n_acc = 1'b0; end
				else begin n_fst = F_SHR; n1h = 26'd1 << F_SHR; n_acc = 1'b0; end
			end

			fst1h[F_INTR]: begin : f_intr
				// FINT rounds by the FPCR mode, FINTRZ toward zero
				// (floatx80_round_to_int[_toward_zero]: no precision
				// rounding, INEX2 for discarded bits, a zero keeps the sign).
				// The rounded integer is zero when nothing rounds up from
				// zero, or everything below the carry is ones: tested on
				// sh_v beside the incrementer, decided in F_INTN.
				reg up;
				up = (r_op == 7'h03) ? 1'b0 :
				     round_up(sh_v[3], sh_v[2], (sh_v[1:0] != 0), a_s);
				if (sh_v[2:0] != 0) begin
					fpsr[9] <= 1;                        // INEX2
					fpsr[3] <= 1;                        // accrued INEX
				end
				int_z <= up ? (sh_v[66:3] == 64'hFFFF_FFFF_FFFF_FFFF) : (sh_v[66:3] == 64'd0);
				unp_m <= up ? shk_i[63:0] : shk[63:0];
				a_e <= 17'd16383 + 17'd63;
				n_fst = F_INTN; n1h = 26'd1 << F_INTN; n_acc = 1'b0;
			end

			fst1h[F_INTN]: begin
				// FINT's integer: zero (keeping the sign), or its leading
				// zeros counted this cycle (from unp_m) and the shift in F_NSH
				if (int_z) begin
					a_t <= T_ZERO; a_e <= 0;
					n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1; n_wbok = fpcr_en0;
				end
				else begin
					n_mode <= N_FINT;
					n_fst = F_NSH; n1h = 26'd1 << F_NSH; n_acc = 1'b0;
				end
			end

			fst1h[F_SHR]: begin
				// right shift with sticky collection: whole bytes this cycle
				// (sh_c), the remaining 0-7 bits in F_SHR2
				n_fst = F_SHR2; n1h = 26'd1 << F_SHR2;
			end

			fst1h[F_SHR2]: begin
				// {int[66:3], G, R, S}: the value shifted by sh_cnt, every
				// bit shifted out ORed into bit 0
				sh_v   <= shr_out;
				sh_cnt <= 7'd0;
				n_fst = sh_ret; n1h = 26'd1 << sh_ret; n_acc = acc_of(sh_ret);
			end

			fst1h[F_PACKI]: begin : f_packi
				// round the integer store: its magnitude (pk_mg); the
				// range check and the assembly in F_PACKI2
				if (pk_sat) begin
					// infinity / far out of range: OPERR, saturating to the
					// SIGN-DEPENDENT extreme (roundAndPackInt32/16/8)
					fpsr[13] <= 1;                       // OPERR
					fpsr[7]  <= 1;                       // accrued IOP
					dout <= {(pk_isz == 2'd2) ? (pk_neg ? 32'h8000_0000 : 32'h7FFF_FFFF) :
					         (pk_isz == 2'd1) ? (pk_neg ? {16'h8000, 16'd0} : {16'h7FFF, 16'd0}) :
					                            (pk_neg ? {8'h80, 24'd0} : {8'h7F, 24'd0}), 64'd0};
					fpu_used <= 1;
					// no enabled exception possible: done now
					if (fpcr_en0) begin n_done = 1'b1; n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; end
					else begin n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; end
					n_acc = 1'b0;
				end
				else begin
					pk_mg <= round_up(sh_v[3], sh_v[2], (sh_v[1:0] != 0), pk_neg) ? shk_i : shk;
					n_fst = F_PACKI2; n1h = 26'd1 << F_PACKI2; n_acc = 1'b0;
				end
			end

			fst1h[F_PACKI2]: begin : f_packi2
				// the rounded magnitude's range checked as it is (an n-bit
				// signed result holds below 2^(n-1), or exactly 2^(n-1)
				// when negative), and only the low long word negated for
				// the store; F_PACKI3 assembles
				reg         hi32, hi16, hi8;
				pk_lo <= pk_neg ? (32'd0 - pk_mg[31:0]) : pk_mg[31:0];
				hi32 = (pk_mg[64:32] != 0) || (pk_mg[31] && !(pk_neg && pk_mg[30:0] == 0));
				hi16 = (pk_mg[64:16] != 0) || (pk_mg[15] && !(pk_neg && pk_mg[14:0] == 0));
				hi8  = (pk_mg[64:8]  != 0) || (pk_mg[7]  && !(pk_neg && pk_mg[6:0]  == 0));
				pk_ovf <= (pk_isz == 2'd2) ? hi32 : (pk_isz == 2'd1) ? hi16 : hi8;
				n_fst = F_PACKI3; n1h = 26'd1 << F_PACKI3; n_acc = 1'b0;
			end

			fst1h[F_PACKI3]: begin : f_packi3
				reg  [31:0] lo;
				reg         ovf;
				lo  = pk_lo;
				ovf = pk_ovf;
				if (ovf) begin
					fpsr[13] <= 1;                   // OPERR
					fpsr[7]  <= 1;
					dout <= {(pk_isz == 2'd2) ? (pk_neg ? 32'h8000_0000 : 32'h7FFF_FFFF) :
					         (pk_isz == 2'd1) ? (pk_neg ? {16'h8000, 16'd0} : {16'h7FFF, 16'd0}) :
					                            (pk_neg ? {8'h80, 24'd0} : {8'h7F, 24'd0}), 64'd0};
				end
				else begin
					dout <= {(pk_isz == 2'd2) ? lo :
					         (pk_isz == 2'd1) ? {lo[15:0], 16'd0} :
					                            {lo[7:0], 24'd0}, 64'd0};
					if (sh_v[2:0] != 0) begin
						fpsr[9] <= 1;                // INEX2
						fpsr[3] <= 1;                // accrued INEX
					end
				end
				fpu_used <= 1;
				// no enabled exception possible: done now
				if (fpcr_en0) begin n_done = 1'b1; n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; end
				else begin n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; end
				n_acc = 1'b0;
			end

			fst1h[F_UNFL]: begin : f_unfl
				// A tiny result takes UNFL on the 68060 whatever the FPCR
				// says (nonmaskable, 6.5.2, 6.6.5: the M68060SP forms the
				// denormalized result), and the destination register is kept
				// (x_kill): only the status is formed here.  INEX2 when the
				// significand, shifted down to the rounding precision's
				// minimum exponent (F_SHR), loses bits at that precision.
				reg inx2;
				inx2 = (r_pr == 2'd0) ? (sh_v[2:0] != 0) : (r_pr == 2'd1) ? shx_s : shx_d;
				if (inx2) begin
					fpsr[9] <= 1;                   // INEX2
					fpsr[3] <= 1;
					fpsr[5] <= 1;                   // accrued UNFL (UNFL&&INEX2)
				end
				n_fst = F_WB; n1h = 26'd1 << F_WB; n_acc = 1'b1;
			end

			fst1h[F_PKR]: begin : f_pkr
				// a single or double store of a number: the rounding formed
				// in F_SRC (sp_*) selected by the increment's carry, which
				// renormalizes to 1.0 and one more in the exponent
				reg cy, ovf, tomax, dbl;
				dbl = (r_fmt == 3'd5);
				cy  = sp_cy;
				ovf = cy ? sp_ov1 : sp_ov0;
				if (ovf) begin
					tomax = (rnd_mode == 2'b01) ||
					        (rnd_mode == 2'b10 && !a_s) ||
					        (rnd_mode == 2'b11 && a_s);
					if (!dbl)
						dout <= tomax ? {a_s, 8'hFE, 23'h7FFFFF, 64'd0} :
						                {a_s, 8'hFF, 23'd0, 64'd0};
					else
						dout <= tomax ? {a_s, 11'h7FE, 52'hFFFFFFFFFFFFF, 32'd0} :
						                {a_s, 11'h7FF, 52'd0, 32'd0};
					// (EXC.INEX2 only for bits actually lost: accrued INEX
					// comes with the overflow, 6.6.7)
					fpsr[12] <= 1; fpsr[6] <= 1;
					if (sp_inx) fpsr[9] <= 1;
					fpsr[3] <= 1;
				end
				else begin
					if (!dbl)
						dout <= {a_s, cy ? sp_en1[7:0] : sp_en0[7:0],
						         cy ? 23'd0 : sp_up ? sp_mi[22:0] : a_m[62:40], 64'd0};
					else
						dout <= {a_s, cy ? sp_en1 : sp_en0,
						         cy ? 52'd0 : sp_up ? sp_mi[51:0] : a_m[62:11], 32'd0};
					if (sp_inx) begin fpsr[9] <= 1; fpsr[3] <= 1; end
				end
				fpu_used <= 1; n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; n_acc = 1'b0;  // OVFL/UNFL trap even when disabled (68060)
			end

			fst1h[F_PACKS]: begin : f_packs
				// Finish a single/double denormal after the staged shift.
				// A carry from the fraction becomes the minimum normal.
				reg [24:0] ms;
				reg [53:0] md;
				reg inx;
				if (r_fmt == 3'd1) begin
					inx = shx_s;
					ms = round_up(sh_v[43], sh_v[42], shr_s, a_s) ?
					     shk_s : {1'b0, sh_v[66:43]};
					dout <= {a_s, 7'd0, ms[23], ms[22:0], 64'd0};
				end
				else begin
					inx = shx_d;
					md = round_up(sh_v[14], sh_v[13], shr_d, a_s) ?
					     shk_d : {1'b0, sh_v[66:14]};
					dout <= {a_s, 10'd0, md[52], md[51:0], 32'd0};
				end
				// Tininess is detected BEFORE rounding.  Reaching F_PACKS
				// already means the value is below this precision's
				// minimum normal exponent (the sE < -126 / -1022 test at
				// the entry above), so UNFL is raised even when the
				// conversion is EXACT, and even when rounding carries the
				// significand back up to the minimum normal.  Gating it
				// on `inx && tiny` -- tininess measured AFTER rounding --
				// lost both cases: an exact extended 2^-127 stored as
				// single 00400000 reported no UNFL, and a value just
				// below the single normal boundary rounded to 00800000
				// reported only INEX.  softfloat sets UNFL for both.
				// Accrued UNFL still follows the 040's updateaccrued rule
				// (UNFL && INEX2), which is why it stays inside the
				// inexact branch.
				fpsr[11] <= 1;                        // UNFL status
				if (inx) begin
					fpsr[9] <= 1;                 // INEX2
					fpsr[3] <= 1;                 // accrued INEX
					fpsr[5] <= 1;                 // accrued UNFL
				end
				fpu_used <= 1;
				n_fst = F_STDONE; n1h = 26'd1 << F_STDONE; n_acc = 1'b0;  // OVFL/UNFL trap even when disabled (68060)
			end

			fst1h[F_STDONE]: begin
				// Store completion one cycle after the exits above, so the
				// status byte has settled: an ENABLED exception is reported
				// for post-instruction delivery by the core (write-then-trap
				// for float formats; the integer SNAN/OPERR set suppresses
				// the write, decided core-side).  Disabled exceptions
				// complete in hardware with the architectural default
				// result already in dout.
				n_done = 1'b1;
				if (x_any) begin
					n_exc = 1'b1;
					exc_vec   <= fp_exception_vector(x_en);
					et_cap    <= 1'b1;
				end
				n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0;
			end

			default: begin n_fst = F_IDLE; n1h = 26'd1 << F_IDLE; n_acc = 1'b0; end
		endcase
		// the exception operand of an exception or an unsupported data
		// type: staged in sh_src by the state that raises it, written the
		// cycle after (nothing reads it before an FSAVE), so fstate_et's
		// input is a four-way choice of flip-flops
		if (et_cap) fstate_et <= sh_src;

		fst     <= n_fst;
		fst1h   <= n1h;
		wk      <= n_wk;
		// F_WB's register write, decided as it is entered
		wbw     <= n1h[F_WB] && !n_wk && !r_ct;
		done    <= n_done;
		unimp   <= n_unimp;
		unsupp  <= n_unsupp;
		exc_req <= n_exc;
		acc_r   <= n_acc;
		wbok_r  <= n_wbok;
		known   <= n_unimp | n_unsupp | n_acc | n_done | n_exc;
		end_ok  <= (n_done | n_wbok) & !n_exc;
	end
end

endmodule

// Two mirrored simple-dual-port banks provide two asynchronous reads and one
// synchronous write.  Cyclone V MLABs support flow-through reads; keeping the
// memory alone in this module gives Quartus the canonical inference shape.
module ap040_fp_regfile
(
	input             clk,
	input             ce,
	input             we,
	input       [2:0] waddr,
	input      [79:0] wdata,
	input       [2:0] raddr_a,
	output     [79:0] rdata_a,
	input       [2:0] raddr_b,
	output     [79:0] rdata_b
);

// READ DURING WRITE.  no_rw_check does not promise the accesses never
// coincide -- it says the read data is undefined when they do, and asks the
// fitter not to spend logic on it.  This file coincides constantly: counting
// cycles where a read port sits on the register being written gives 1,329 in
// t_fpu alone, 57 in t_fpu_resume, 6 in t_fpu_frames, the very first being a
// write to FP0 with both read ports on FP0.
//
// The integer register file had the same shape and did not boot.  So the same
// remedy: hold the write one enabled cycle and answer a read of the pending
// address from pend_wdata, which discards exactly the datum the attribute
// leaves undefined.  Reads are otherwise unchanged, and an MLAB is still
// inferred because the attribute stays.  The hold also keeps the RAM's write
// inputs registered, which matters on its own: see ap040_regfile for the
// board result when the RAM was written straight from the datapath
// (06d90f6fb, yellow screen) and the non-unate clock edge TimeQuest reports
// for these cells.  Keep pend_* in front of the RAM.
(* ramstyle = "MLAB, no_rw_check" *) reg [79:0] bank_a [0:7];
(* ramstyle = "MLAB, no_rw_check" *) reg [79:0] bank_b [0:7];

reg        pend_we;
reg  [2:0] pend_waddr;
reg [79:0] pend_wdata;

wire hit_a = pend_we && (pend_waddr == raddr_a);
wire hit_b = pend_we && (pend_waddr == raddr_b);
assign rdata_a = hit_a ? pend_wdata : bank_a[raddr_a];
assign rdata_b = hit_b ? pend_wdata : bank_b[raddr_b];

always @(posedge clk) begin
	if (ce) begin
		// the write held from the previous enabled cycle
		if (pend_we) begin
			bank_a[pend_waddr] <= pend_wdata;
			bank_b[pend_waddr] <= pend_wdata;
		end
		pend_we    <= we;
		pend_waddr <= waddr;
		pend_wdata <= wdata;
	end
end

endmodule
