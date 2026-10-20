//
// FX68K
//
// M68000 cycle accurate, fully synchronous
// Copyright (c) 2018,2021 by Jorge Cwik
// 
// TODO:
// - Everything except bus retry already implemented.

// altera message_off 10030
// altera message_off 10230

`timescale 1 ns / 1 ns

//`define USE_E_CLKEN
/*
	Define USE_E_CLKEN will output two signals that generate a single cycle pulse just before the raising and falling edges of E.
	Use this when you need to generate changes that must be simultaneous with these edges.
	Most systems don't need this. Note that these signals are not registered. 
 */

// Define this to run a self contained compilation test build
// `define FX68K_TEST

localparam CF = 0, VF = 1, ZF = 2, NF = 3, XF = 4, SF = 13;

localparam UADDR_WIDTH = 10;
localparam UROM_WIDTH = 17;
localparam UROM_DEPTH = 2048;		// Two banks: 68000 and 68010

localparam NADDR_WIDTH = 10;
localparam NANO_WIDTH = 100;
localparam NANO_DEPTH = 2048;

// 68010 nanoword extensions (bits above the 68000 nanoword)
localparam NANO_EXTLATCH = 68;		// Extension word latch <= IRC
localparam NANO_IRSYNTH = 69;		// IR <= synthesized opcode
localparam NANO_TVNFORCE = 70;		// 71-70 Force TVN: 01 illegal, 10 format error
localparam NANO_AUVBR = 72;			// AU <= VBR + DBL[9:0]
localparam NANO_SSW010 = 73;		// FTU <= 68010 SSW
localparam NANO_CCRONLY = 74;		// SR to FTU reads the CCR only
localparam NANO_IRLOOP = 75;		// Loop mode: IR <= IRC loads the looped instruction
localparam NANO_IRCLOOP = 76;		// Loop mode: IRC <= first word of the DBcc
localparam NANO_AUK = 77;			// 78-77 AU constant: 01 +6, 10 +22, 11 +30
localparam NANO_FMTCCR = 79;		// RTE invalid format: N <= format bit 15, Z,V <= 0
localparam NANO_DOBX = 80;			// 82-80 DOB source: 1 zero, 2 saved DOB, 3 SSW, 4 IRC, 5 DIB
localparam NANO_AOBZERO = 83;		// AOB <= 0
localparam NANO_TPEND = 84;			// Tpend <= T, like FTU updTpend
localparam NANO_HILATCH = 85;		// Latch the high words of RX and RY
localparam NANO_HISEL = 86;			// ... RX high is the data operand (otherwise RY high)
localparam NANO_HIOP = 87;			// ALU operands are the latched high words
localparam NANO_FTUABL = 88;		// ABL <= FTU (like FTU ftu2Abl, the FTU control is free)
localparam NANO_AUCC = 89;			// 90-89 AU input on the IRD condition: 01 cc ? AB : 2, 10 cc ? 2 : AB
localparam NANO_SHIDX = 91;			// 95-91 internal state word of the bus error frame
localparam NANO_SHW = 96;			// internal state word <= DBIN
localparam NANO_RESUME = 97;		// RTE format 8: resume the faulted instruction
localparam NANO_AUK2 = 98;			// AU constant bit 2: AUK 5 +16, 6 -14, 7 ALU output +2
localparam NANO_AOBPC = 99;			// AOB <= PC (with AOB from AB)

localparam BSER1_NMA = 'h003;
localparam RSTP0_NMA = 'h002;
localparam HALT1_NMA = 'h001;
localparam TRAC1_NMA = 'h1C0;
localparam ITLX1_NMA = 'h1C4;

localparam TVN_SPURIOUS = 12;
localparam TVN_AUTOVEC = 13;
localparam TVN_INTERRUPT = 15;

// 68010 microcode entry points (see ucode010/gen_ucode010.py)
localparam RTE1_NMA = 'h010;
localparam RTD1_NMA = 'h011;
localparam MVC1_NMA = 'h012;
localparam MVS1_NMA = 'h013;
localparam CCRW1_NMA = 'h3f0;		// MOVE from CCR, Dn
localparam CCMW1_NMA = 'h3f1;		// MOVE from CCR, memory (after the EA)
localparam LDB1_NMA = 'h3f2;		// Loop mode DBcc
localparam BK1_NMA = 'h3f3;			// BKPT
// 68010 timing: other entry points for some instructions
localparam USPI_NMA = 'h3f4;		// MOVE An,USP (2 clocks more than the 68000)
localparam USPO_NMA = 'h3f5;		// MOVE USP,An
localparam MLPD_NMA = 'h3f6;		// MOVE.L Rn,-(An)
localparam RL1S_NMA = 'h3f7;		// ADDA/SUBA.L Rn/#,An, AND/OR.L #,Dn: rorl1 with the 68000 time
localparam RA1S_NMA = 'h3f8;		// ANDI/ORI/EORI.L #,Dn: roal1 with the 68000 time
// Effective address without the operand read (Scc, MOVE from SR/CCR)
localparam NAI_NMA = 'h3f9;			// (An)
localparam NAIP_NMA = 'h3fa;		// (An)+
localparam NAID_NMA = 'h3fb;		// -(An)
localparam NAD_NMA = 'h3fc;			// (d16,An)
localparam NAX_NMA = 'h3fd;			// (d8,An,Xn)
localparam NAW_NMA = 'h3fe;			// (xxx).W
localparam NAL_NMA = 'h3ff;			// (xxx).L
localparam TASI1_NMA = 'h0f0;		// TAS: 2 clocks more before the write
localparam TASI2_NMA = 'h0f1;		// TAS: 4 clocks more
localparam CPDW_NMA = 'h0f2;		// CLR.B/W -(An) (MOVE.B/W Dn,-(An) and 2 clocks)
localparam CXW_NMA = 'h0f3;			// CLR.B/W (d8,An,Xn)
localparam CXL_NMA = 'h0f4;			// CLR.L (d8,An,Xn)
localparam MVSK1_NMA = 'h0f5;		// MOVES with 2, 4, 6 clocks more
localparam MVSK2_NMA = 'h0f6;
localparam MVSK3_NMA = 'h0f7;
localparam MVSKD_NMA = 'h0f8;		// MOVES -(An): 2 or 6 clocks more, on the direction

// 68010 synthesized instructions
localparam SYN_NONE = 2'd0;
localparam SYN_MOVEC = 2'd1;
localparam SYN_MOVES = 2'd2;
localparam SYN_MOVESB = 2'd3;		// MOVES.B

localparam NANO_DOB_DBD = 2'b01;
localparam NANO_DOB_ADB = 2'b10;
localparam NANO_DOB_ALU = 2'b11;


// Clocks, phases and resets
typedef struct {
	logic clk;
	logic extReset;			// External sync reset on emulated system
	logic pwrUp;			// Asserted together with reset on emulated system coldstart
	logic enPhi1, enPhi2;	// Clock enables. Next cycle is PHI1 or PHI2
} s_clks;

// IRD decoded signals
typedef struct {
	logic isPcRel;
	logic isTas;
	logic implicitSp;
	logic toCcr;
	logic rxIsDt, ryIsDt;
	logic rxIsUsp, rxIsMovem, movemPreDecr;
	logic isByte;
	logic isMovep;
	logic [2:0] rx, ry;
	logic rxIsAreg, ryIsAreg;
	logic [15:0] ftuConst;
	logic [5:0] macroTvn;
	logic inhibitCcr;

	// 68010 synthesized instructions (MOVEC/MOVES)
	logic rxOvr, ryOvr;				// RX/RY taken from the extension word
	logic [4:0] rxOvrMux;			// RX register (control register for MOVEC)
	logic [3:0] ryOvrReg;			// RY register, before SP mapping
	logic ryOvrAreg;				// RY uses address register bus routing
	logic isMoves;					// Data accesses use SFC/DFC, CCR unchanged
	logic movesSext;				// MOVES.B to An, sign extend the byte
	logic ryZero;					// RY is the zero register (68010 CLR as MOVE)
} s_irdecod;

// Nano code decoded signals
typedef struct {
	logic permStart;
	logic waitBusFinish;
	logic isWrite;
	logic busByte;
	logic isRmc;
	logic noLowByte, noHighByte;
	
	logic updTpend, clrTpend;
	logic tvn2Ftu, const2Ftu;
	logic ftu2Dbl, ftu2Abl;
	logic abl2Pren, updPren;
	logic inl2psw, ftu2Sr, sr2Ftu, ftu2Ccr, pswIToFtu;
	logic ird2Ftu, ssw2Ftu;
	logic initST;
	logic Ir2Ird;
	
	logic auClkEn, noSpAlign;
	logic [2:0] auCntrl;
	logic todbin, toIrc;
	logic dbl2Atl, abl2Atl, atl2Abl, atl2Dbl;
	logic abh2Ath, dbh2Ath;
	logic ath2Dbh, ath2Abh;
	
	logic db2Aob, ab2Aob, au2Aob;
	logic aob2Ab, updSsw;
	// logic adb2Dob, dbd2Dob, alu2Dob;
	logic [1:0] dobCtrl;
	
	logic abh2reg, abl2reg;
	logic reg2abl, reg2abh;
	logic dbh2reg, dbl2reg;
	logic reg2dbl, reg2dbh;
	logic ssp, pchdbh, pcldbl, pclabl, pchabh;
	
	logic rxh2dbh, rxh2abh;
	logic dbl2rxl, dbh2rxh;
	logic rxl2db, rxl2ab;
	logic abl2rxl, abh2rxh;
	logic dbh2ryh, abh2ryh;
	logic ryl2db, ryl2ab;
	logic ryh2dbh, ryh2abh;
	logic dbl2ryl, abl2ryl;
	logic rz;
	logic rxlDbl;
	
	logic [2:0] aluColumn;
	logic [1:0] aluDctrl;
	logic aluActrl;
	logic aluInit, aluFinish;
	logic abd2Dcr, dcr2Dbd;
	logic dbd2Alue, alue2Dbd;
	logic dbd2Alub, abd2Alub;
	
	logic alu2Dbd, alu2Abd;
	logic au2Db, au2Ab, au2Pc;
	logic dbin2Abd, dbin2Dbd;
	logic extDbh, extAbh;
	logic ablAbd, ablAbh;
	logic dblDbd, dblDbh;
	logic abdIsByte;

	// 68010
	logic extLatch, irSynth;		// Latch extension word, IR <= synthesized opcode
	logic [1:0] tvnForce;			// Force TVN: 1 illegal, 2 format error
	logic auVbr;					// AU <= VBR + DBL[9:0]
	logic ssw010;					// FTU <= 68010 special status word
	logic ccrOnly;					// SR to FTU reads the CCR only (MOVE from CCR)
	logic irLoop, ircLoop;			// Loop mode: IR <= looped instruction, IRC <= DBcc
	logic [1:0] auK;				// AU constant: 1 +6, 2 +22, 3 +30
	logic fmtCcr;					// RTE invalid format: N <= bit 15, Z,V <= 0
	logic [2:0] dobX;				// DOB source: 1 zero, 2 saved DOB, 3 SSW, 4 IRC, 5 DIB
	logic aobZero;					// AOB <= 0
	logic aobPc;					// AOB <= PC
	logic tpend010;					// Tpend <= T (updTpend without the FTU)
	logic hiLatch, hiSel, hiOp;		// Long ALU ops: latch the high words of RX/RY, ALU on them
	logic ftuAbl;					// ABL <= FTU, without the FTU control field
	logic [1:0] auCc;				// AU input: 1 AB if the IRD condition is true else +2, 2 the opposite
	logic [4:0] shIdx;				// Bus error frame internal state word (1-24)
	logic shW;						// ... <= DBIN (RTE)
	logic resume;					// RTE format 8: restore the internal state, rerun the faulted cycle
	logic auK2;						// AU constant (with auK): 5 +16, 6 -14, 7 ALU output +2
} s_nanod;

module fx68k(
	input clk,
	input HALTn,					// Used for single step only. Force high if not used
	// input logic HALTn = 1'b1,			// Not all tools support default port values
	
	// These two signals don't need to be registered. They are not async reset.
	input extReset,			// External sync reset on emulated system
	input pwrUp,			// Asserted together with reset on emulated system coldstart	
	input enPhi1, enPhi2,	// Clock enables. Next cycle is PHI1 or PHI2

	output eRWn, output ASn, output LDSn, output UDSn,
	output logic E, output VMAn,	
	
`ifdef USE_E_CLKEN
	// Next cycle would be raising/falling edge of E output
	output E_PosClkEn, E_NegClkEn,
`endif	

	output FC0, output FC1, output FC2,
	output BGn,
	output oRESETn, output oHALTEDn,
	input DTACKn, input VPAn,
	input BERRn,
	input BRn, BGACKn,
	input IPL0n, input IPL1n, input IPL2n,
	input [15:0] iEdb, output [15:0] oEdb,
	output [23:1] eab,

	// 68010 mode. Sampled during reset.
	input cpu010,
	output [31:0] VBR
	);

	// wire clock = Clks.clk;
	s_clks Clks;

	// 68010 mode can only change on reset
	reg is010;
	always_ff @( posedge clk) begin
		if( extReset)
			is010 <= cpu010;
	end

	assign Clks.clk = clk;	
	assign Clks.extReset = extReset;
	assign Clks.pwrUp = pwrUp;	
	assign Clks.enPhi1 = enPhi1;
	assign Clks.enPhi2 = enPhi2;
	
	wire wClk;
	
	// Internal sub clocks T1-T4
	enum int unsigned { T0 = 0, T1, T2, T3, T4} tState;
	wire enT1 = Clks.enPhi1 & (tState == T4) & ~wClk;
	wire enT2 = Clks.enPhi2 & (tState == T1);
	wire enT3 = Clks.enPhi1 & (tState == T2);
	wire enT4 = Clks.enPhi2 & ((tState == T0) | (tState == T3));
	
	// T4 continues ticking during reset and group0 exception.
	// We also need it to erase ucode output latched on T4.
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			tState <= T0;
		else begin
		case( tState)
		T0: if( Clks.enPhi2) tState <= T4;
		T1: if( Clks.enPhi2) tState <= T2;
		T2: if( Clks.enPhi1) tState <= T3;
		T3: if( Clks.enPhi2) tState <= T4;
		T4: if( Clks.enPhi1) tState <= wClk ? T0 : T1;
		endcase
		end
	end
	
	// The following signals are synchronized with 3 couplers, phi1-phi2-phi1.
	// Will be valid internally one cycle later if changed at the rasing edge of the clock.
	//
	// DTACK, BERR
		
	// DTACK valid at S6 if changed at the rasing edge of S4 to avoid wait states.
	// SNC (sncClkEn) is deasserted together (unless DTACK asserted too early).
	//	
	// We synchronize some signals half clock earlier. We compensate later
	reg rDtack, rBerr;
	reg [2:0] rIpl, iIpl;
	reg Vpai, BeI, Halti, BRi, BgackI, BeiDelay;
	// reg rBR, rHALT;
	wire BeDebounced = ~( BeI | BeiDelay);

	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			rBerr <= 1'b0;
			BeI <= 1'b0;
		end
		else if( Clks.enPhi2) begin
			rDtack <= DTACKn;
			rBerr <= BERRn;
			rIpl <= ~{ IPL2n, IPL1n, IPL0n};
			iIpl <= rIpl;
			
			// Needed for cycle accuracy but only if BR or HALT are asserted on the wrong edge of the clock			
			// rBR <= BRn;
			// rHALT <= HALTn;
		end
		else if( Clks.enPhi1) begin
			Vpai <= VPAn;
			BeI <= rBerr;
			BeiDelay <= BeI;
			BgackI <= BGACKn;
			
			BRi <= BRn;
			Halti <= HALTn;
			// BRi <= rBR;
			// Halti <= rHALT;			
		end	
	end

	// Instantiate micro and nano rom
	logic [NANO_WIDTH-1:0] nanoLatch;
	logic [NANO_WIDTH-1:0] nanoOutput;
	logic [UROM_WIDTH-1:0] microLatch;
	logic [UROM_WIDTH-1:0] microOutput;
	
	logic [UADDR_WIDTH-1:0] microAddr, nma; 

	// 68010 bus/address error: the internal state when the faulted microcycle ended is saved
	// in the frame (snapshot in excUnit), restored by RTE, which also reruns the cycle. The
	// microinstruction to continue with is the one already latched then (microAddr).
	wire [15:0] shIr, shIrd, shFtu, shExtW, shMisc1, shNext, shSsw, shDib;
	wire [5:0] shCtl;
	wire resumeT3 = enT3 & nanoLatch[ NANO_RESUME];
	logic [NADDR_WIDTH-1:0] orgAddr;
	logic [NADDR_WIDTH:0] nanoAddr;			// Bank (68010) and row
	wire rstUrom;

	// For the time being, address translation is done for nanorom only. 
	// RTE format 8 resume: the next microinstruction is the one after the faulted one
	wire [UADDR_WIDTH-1:0] nmaR = nanoLatch[ NANO_RESUME] ? shNext[UADDR_WIDTH-1:0] : nma;
	microToNanoAddr microToNanoAddr( .uAddr( nmaR), .is010, .orgAddr);
	
	// Output of these modules will be updated at T2 at the latest (depending on clock division)
	
	nanoRom nanoRom( .clk( Clks.clk), .nanoAddr, .nanoOutput);
	uRom uRom( .clk( Clks.clk), .microAddr( { is010, microAddr}), .microOutput);
	
	always_ff @( posedge Clks.clk) begin
		// uaddr originally latched on T1, except bits 6 & 7, the conditional bits, on T2
		// Seems we can latch whole address at either T1 or T2

		// Originally it's invalid on hardware reset, and forced later when coming out of reset
		if( Clks.pwrUp) begin
			microAddr <= RSTP0_NMA;
			nanoAddr <= RSTP0_NMA;
		end
		else if( enT1) begin
			microAddr <= nmaR;
			nanoAddr <= { is010, orgAddr};		// Register translated uaddr to naddr
		end
			
		if( Clks.extReset) begin
			microLatch <= '0;
			nanoLatch <= '0;
		end
		else if( rstUrom) begin
			// Originally reset these bits only. Not strictly needed like this.
			// Can reset the whole register if it is important.
			{ microLatch[16], microLatch[15], microLatch[0]} <= '0;
			nanoLatch <= '0;
		end
		else if( enT3) begin
			microLatch <= microOutput;
			nanoLatch <= nanoOutput;
		end
					
	end
	

	// Decoded nanocode signals
	s_nanod Nanod;
	// IRD decoded control signals
	s_irdecod Irdecod;

	//	
	reg Tpend;
	reg intPend;											// Interrupt pending
	reg pswT, pswS;
	reg [ 2:0] pswI;
	wire [7:0] ccr;
	
	wire [15:0] psw = { pswT, 1'b0, pswS, 2'b00, pswI, ccr};

	reg [15:0] ftu;
	reg [15:0] Irc, Ir, Ird;

	// 68010 CLR to memory doesn't read the operand: it executes as MOVE D0,<ea> with a
	// zero source register (same flags, X unchanged). IRD holds the MOVE, irdOrig the CLR.
	reg [15:0] irdOrig;
	reg irdClr;
	wire irIsClr = is010 & (Ir[15:8] == 8'h42) & (Ir[7:6] != 2'b11) & (Ir[5:4] != 2'b00) &
				((Ir[5:3] != 3'b111) | (Ir[2:1] == 2'b00));
	wire [1:0] clrMoveSize = (Ir[7:6] == 2'b00) ? 2'b01 : (Ir[7:6] == 2'b01) ? 2'b11 : 2'b10;
	wire [15:0] irDec = irIsClr ? { 2'b00, clrMoveSize, Ir[2:0], Ir[5:3], 6'b000000} : Ir;
	
	wire [15:0] alue;
	wire [15:0] Abl;
	wire prenEmpty, au05z, dcr4, ze;
	wire atl15;
	
	wire [UADDR_WIDTH-1:0] a1, a2, a3;
	wire isPriv, isIllegal, isLineA, isLineF;
	

	// 68010 MOVEC and MOVES are executed by the MOVE USP and MOVE microcode.
	// The prologue latches the extension word and loads IR with the equivalent opcode.
	reg [15:0] extW = '0;					// Extension word
	reg [1:0] irSyn, irdSyn;				// IR/IRD hold a synthesized opcode
	logic [15:0] synthIr;
	logic [1:0] synthKind;

	always_comb begin
		// MOVES size 00/01/10 to MOVE size 01/11/10
		logic [1:0] msz;
		logic isA, isB;
		msz = (Ir[7:6] == 2'b00) ? 2'b01 : { 1'b1, ~Ir[7]};
		isA = Irc[15];
		isB = (Ir[7:6] == 2'b00);

		if( Ir[15:8] == 8'h0E) begin
			synthKind = isB ? SYN_MOVESB : SYN_MOVES;
			if( Irc[11])			// Rn => <ea>: MOVE Rn,<ea>. MOVE.B An is done as Dn + RY override.
				synthIr = { 2'b00, msz, Ir[2:0], Ir[5:3], 2'b00, isA & ~isB, Irc[14:12]};
			else					// <ea> => Rn: MOVE <ea>,Dn or MOVEA. MOVES.B to An as MOVEA.W.
				synthIr = { 2'b00, isA & isB ? 2'b11 : msz, Irc[14:12], 2'b00, isA, Ir[5:0]};
		end
		else begin
			// MOVEC Rc,Rn as MOVE USP,An. MOVEC Rn,Rc as MOVE An,USP
			synthKind = SYN_MOVEC;
			synthIr = Ir[0] ? 16'h4e60 : 16'h4e68;
		end
	end

	// 68010 loop mode
	//
	// A one-word loopable instruction X at L followed by DBcc Dn,L (displacement -4) at L+2.
	// The first time the DBcc starts the loop is armed. When the DBcc branched back and X
	// starts again (the second fetch of X and of the DBcc), the loop is active: the
	// DBcc runs the loop mode microcode, which dispatches X again without fetching, and
	// the fetch of the displacement at the end of X is a virtual bus cycle served from
	// the loop buffer. Any other instruction or exception ends loop mode.
	
	localparam LOOP_IDLE = 2'd0, LOOP_ARMED = 2'd1, LOOP_ACTIVE = 2'd2;
	reg [1:0] loopState;
	reg loopDbPend;							// X is executing, the DBcc is next
	reg [15:0] loopX, loopD, loopDisp;		// Loop buffer: X, DBcc, displacement
	reg [15:0] ssw010;						// 68010 special status word: IF DF RM HB BY RW, FC
	logic [2:0] rFC;						// Function code of the bus cycle
	reg [22:0] loopW;						// Word address of X
	wire A0Sel, dnZero;
	wire [31:0] pcOut;
	wire [22:0] pcW = pcOut[23:1];
	wire virtReq, virtStart, realStart;
	
	// Table A-1 of the M68000 User's Manual. Memory modes are (An), (An)+, -(An).
	function automatic logic loopable( input [15:0] op);
		logic memEa, regEa, memDst, size11;
		memEa = (op[5:3] == 3'b010) | (op[5:3] == 3'b011) | (op[5:3] == 3'b100);
		regEa = (op[5:3] == 3'b000) | (op[5:3] == 3'b001);
		memDst = (op[8:6] == 3'b010) | (op[8:6] == 3'b011) | (op[8:6] == 3'b100);
		size11 = (op[7:6] == 2'b11);
		case( op[15:12])
		// MOVE memory to memory, or register to (An), (An)+
		4'h1, 4'h2, 4'h3:	loopable = memDst & (memEa | (regEa & (op[8:6] != 3'b100)));
		// ADD, SUB, AND, OR, CMP <ea>,Dn / ADDA, SUBA, CMPA <ea>,An / ADD, SUB, AND, OR, EOR Dn,<ea>
		// SUBX, ADDX, CMPM, SBCD, ABCD -(Ay),-(Ax) / (Ay)+,(Ax)+
		4'h9, 4'hB, 4'hD:	loopable = memEa | (op[8] & ~size11 & (op[5:3] == 3'b001));
		4'h8, 4'hC:			loopable = (memEa & ~size11) | (op[8:3] == 6'b100001);
		// NEGX, CLR, NEG, NOT, TST, NBCD
		4'h4:				loopable = memEa & ( (~size11 & ((op[11:8] == 4'h0) | (op[11:8] == 4'h2) |
								(op[11:8] == 4'h4) | (op[11:8] == 4'h6) | (op[11:8] == 4'hA))) |
								(op[11:6] == 6'b100000) );
		// Memory shift and rotate
		4'hE:				loopable = memEa & size11 & ~op[11];
		default:			loopable = 1'b0;
		endcase
	endfunction
	
	// A1 dispatch: the next instruction (in IR) starts, or an exception. IRD is loaded
	// with IR at the same time, it still holds the instruction that ended. The
	// prefetch of the next word reaches IRC during the first uinstruction.
	wire dispatch = enT1 & (microLatch[3:1] == 3'b010);
	wire irIsDbcc = (Ir[15:12] == 4'h5) & (Ir[7:3] == 5'b11001);
	wire loopEntry = is010 & ~pswT & irIsDbcc & loopable( irdOrig);
	reg loopCand;							// DBcc after a loopable instruction, check the displacement
	wire loopActive = (loopState == LOOP_ACTIVE);
	wire loopDbNext = loopActive & loopDbPend & (Ir == loopD);
	wire loopNoInt = loopActive & loopDbPend;
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			loopState <= LOOP_IDLE;
			loopDbPend <= 1'b0;
			loopCand <= 1'b0;
		end
		else if( enT1 & loopCand) begin
			// first uinstruction of the DBcc, IRC holds the displacement
			loopCand <= 1'b0;
			if( Irc == 16'hfffc) begin
				loopState <= LOOP_ARMED;
				loopDisp <= Irc;
			end
		end
		else if( dispatch) begin
			loopDbPend <= 1'b0;
			if( A0Sel)
				loopState <= LOOP_IDLE;
			else if( loopDbNext)
				loopState <= LOOP_ACTIVE;
			else if( (loopState != LOOP_IDLE) & (Ir == loopX) & (pcW == loopW + 23'd1)) begin
				loopState <= LOOP_ACTIVE;
				loopDbPend <= 1'b1;
			end
			else if( loopEntry & ~A0Sel) begin
				loopState <= LOOP_IDLE;
				loopCand <= 1'b1;
				loopX <= irdOrig;
				loopD <= Ir;
				loopW <= pcW - 23'd2;
			end
			else
				loopState <= LOOP_IDLE;
		end
	end
	
	// Virtual instruction fetches from the loop buffer
	wire [22:0] loopOff = eab - loopW;
	reg virtSel;
	reg [15:0] virtData;
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			virtSel <= 1'b0;
		else if( virtStart) begin
			virtSel <= 1'b1;
			virtData <= nanoLatch[ NANO_RESUME] ? shDib :
						(loopOff == 23'd0) ? loopX : (loopOff == 23'd1) ? loopD : loopDisp;
		end
		else if( realStart)
			virtSel <= 1'b0;
	end
	wire [15:0] edbIn = virtSel ? virtData : iEdb;
	
	// IR & IRD forwarding
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			irSyn <= SYN_NONE;
			irdSyn <= SYN_NONE;
		end
		else if( enT1) begin
			if( Nanod.Ir2Ird) begin
				Ird <= irDec;
				irdOrig <= Ir;
				irdClr <= irIsClr;
				irdSyn <= irSyn;
			end
			else if(microLatch[0]) begin	// prevented by IR => IRD !
				Ir <= Nanod.irLoop ? loopX : Irc;
				irSyn <= SYN_NONE;
			end
			else if( Nanod.irSynth) begin
				Ir <= synthIr;
				irSyn <= synthKind;
			end

			if( Nanod.extLatch)
				extW <= Irc;
		end
		else if( resumeT3) begin
			Ir <= shIr;
			Ird <= shIrd;
			irSyn <= shNext[15:14];
			irdSyn <= shMisc1[15:14];
			irdClr <= shMisc1[13];
			// CLR <mem> was executing as MOVE D0,<ea>
			irdOrig <= shMisc1[13] ? { 8'h42, (shIrd[13:12] == 2'b01) ? 2'b00 : (shIrd[13:12] == 2'b11) ? 2'b01 : 2'b10,
								shIrd[8:6], shIrd[11:9]} : shIrd;
			extW <= shExtW;
		end
	end
	
	wire [3:0] tvn;
	wire waitBusCycle, busStarting;
	wire BusRetry = 1'b0;
	wire busAddrErr;
	wire bciWrite;						// Last bus cycle was write
	wire bgBlock, busAvail;
	wire addrOe;

	wire busIsByte = nanoLatch[ NANO_RESUME] ? shSsw[9] : Nanod.busByte & (Irdecod.isByte | Irdecod.isMovep);
	wire aob0;
	
	reg iStop;								// Internal signal for ending bus cycle
	reg A0Err;								// Force bus/address error ucode
	reg excRst;								// Signal reset exception to sequencer
	reg BerrA;
	reg Spuria, Avia;
	wire Iac;
	
	reg rAddrErr, iBusErr, Err6591;
	wire iAddrErr = rAddrErr & addrOe;		// To simulate async reset
	wire enErrClk;

	// Reset micro/nano latch after T4 of the current ublock.
	assign rstUrom = Clks.enPhi1 & enErrClk;

	reg errSeen;
	wire snap = is010 & rstUrom & ~errSeen;
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			errSeen <= 1'b0;
		else if( rstUrom)
			errSeen <= 1'b1;
		else if( ~enErrClk)
			errSeen <= 1'b0;
	end

	wire [UADDR_WIDTH-1:0] a1Dec;
	uaddrDecode uaddrDecode( .opcode( irDec), .is010, .synMovec( irSyn == SYN_MOVEC), .synMoves( irSyn[1]),
		.clr( irIsClr),
		.a1( a1Dec), .a2, .a3, .isPriv, .isIllegal, .isLineA, .isLineF, .lineBmap());
	assign a1 = loopDbNext ? LDB1_NMA : a1Dec;		// DBcc in loop mode

	// MOVEC control register is SFC, DFC, USP or VBR
	wire movecOk = (Irc[11:1] == 11'h000) | (Irc[11:1] == 11'h400);
	wire [3:0] dbinFmt, dbinVer;
	wire [2:0] sfc, dfc;

	sequencer sequencer( .Clks, .enT3, .microLatch, .Ird,
		.A0Err, .excRst, .BerrA, .busAddrErr, .Spuria, .Avia,
		.Tpend, .intPend, .isIllegal, .isPriv, .isLineA, .isLineF,
		.nma, .a1, .a2, .a3, .tvn,
		.psw, .prenEmpty, .au05z, .dcr4, .ze, .alue01( alue[1:0]), .alue15( alue[15]), .atl15, .i11( Irc[ 11]),
		.movecOk, .dbinFmt, .dbinVer, .dnZero, .loopNoInt, .A0Sel);

	excUnit excUnit( .Clks, .Nanod, .Irdecod, .enT1, .enT2, .enT3, .enT4,
		.Ird, .ftu, .iEdb( edbIn), .pswS,
		.prenEmpty, .au05z, .dcr4, .ze, .AblOut( Abl), .atl15, .eab, .aob0, .Irc, .oEdb,
		.alue, .ccr,
		.dbinFmt, .dbinVer, .sfc, .dfc, .vbr( VBR), .pcOut, .dnZero, .loopD, .ssw010,
		.dataSpace( rFC[1:0] == 2'b01),
		.snap, .snapIr( Ir), .snapIrd( Ird), .snapExtW( extW), .snapNext( microAddr),
		.snapTop( { irSyn, irdSyn, irdClr, Tpend}),
		.shIr, .shIrd, .shFtu, .shExtW, .shMisc1, .shNext, .shSsw, .shDib, .shCtl);

	nDecoder3 nDecoder( .Clks, .Nanod, .Irdecod, .enT2, .enT4, .microLatch, .nanoLatch, .shSsw, .shCtl);

	irdDecode irdDecode( .ird( Ird), .synKind( irdSyn), .extW, .irdClr, .Irdecod);

	wire bciByte, bciRmc;
	busControl busControl( .Clks, .enT1, .enT4, .permStart( Nanod.permStart), .permStop( Nanod.waitBusFinish), .iStop,
		.aob0, .isWrite( Nanod.isWrite), .isRmc( Nanod.isRmc), .isByte( busIsByte), .busAvail,
		.bciWrite, .bciByte, .bciRmc, .virtReq, .virtStart, .realStart,
		.addrOe, .bgBlock, .waitBusCycle, .busStarting, .busAddrErr,
		.rDtack, .BeDebounced, .Vpai,
		.ASn, .LDSn, .UDSn, .eRWn);
		
	busArbiter busArbiter( .Clks, .BRi, .BgackI, .Halti, .bgBlock, .busAvail, .BGn);
		
		
	// Output reset & halt control
	wire [1:0] uFc = microLatch[ 16:15];
	logic oReset, oHalted;
	assign oRESETn = !oReset;
	assign oHALTEDn = !oHalted;
	
	// FC without permStart is special, either reset or halt
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			oReset <= 1'b0;
			oHalted <= 1'b0;
		end
		else if( enT1) begin
			oReset <= (uFc == 2'b01) & !Nanod.permStart;
			oHalted <= (uFc == 2'b10) & !Nanod.permStart;
		end
	end
		
	assign { FC2, FC1, FC0} = rFC;					// ~rFC;
	assign Iac = {rFC == 3'b111};					// & Control output enable !!
	
	// 68010 loop mode: instruction fetches of the loop come from the loop buffer
	// 68010 RTE format 8 with SSW RR (the handler did the read): data from the DIB of the frame
	assign virtReq = (loopActive & (rFC[1:0] == 2'b10) & (loopOff < 23'd3)) |
					(nanoLatch[ NANO_RESUME] & shSsw[15] & shSsw[8]);

	always_ff @( posedge Clks.clk) begin
		logic [1:0] fc;

		// If FC is type 'n' (0) at ucode, access type depends on PC relative mode
		// We don't care about RZ in this case. Those uinstructions with RZ don't start a bus cycle.
		fc[1] = microLatch[ 16] | ( ~microLatch[ 15] & Irdecod.isPcRel);
		fc[0] = microLatch[ 15] | ( ~microLatch[ 16] & ~Irdecod.isPcRel);

		if( Clks.extReset)
			rFC <= '0;
		else if( enT1 & Nanod.permStart) begin		// S0 phase of bus cycle
			// 68010 MOVES: data accesses use SFC (read) or DFC (write)
			if( nanoLatch[ NANO_RESUME])
				rFC <= shSsw[2:0];					// 68010 rerun of the faulted cycle
			else if( Irdecod.isMoves & (fc == 2'b01))
				rFC <= Nanod.isWrite ? dfc : sfc;
			else
				rFC <= { pswS | (is010 & (fc == 2'b11)), fc};		// 68010 BKPT in user mode
		end
	end
	
		
	// IPL interface
	reg [2:0] inl;							// Int level latch
	reg updIll;
	reg prevNmi;
	
	wire nmi = (iIpl == 3'b111);
	wire iplStable = (iIpl == rIpl);
	wire iplComp = iIpl > pswI;

	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			intPend <= 1'b0;
			prevNmi <= 1'b0;
		end
		else begin
			if( Clks.enPhi2)
				prevNmi <= nmi;
				
			// Originally async RS-Latch on PHI2, followed by a transparent latch on T2
			// Tricky because they might change simultaneously
			// Syncronous on PHI2 is equivalent as long as the output is read on T3!
			
			// Set on stable & NMI edge or compare
			// Clear on: NMI Iack or (stable & !NMI & !Compare)

			if( Clks.enPhi2) begin
				if( iplStable & ((nmi & ~prevNmi) | iplComp) )
					intPend <= 1'b1;
				else if( ((inl == 3'b111) & Iac) | (iplStable & !nmi & !iplComp) )
					intPend <= 1'b0;
			end			
		end
		
		if( Clks.extReset) begin
			inl <= '1;
			updIll <= 1'b0;
		end
		else if( enT4)
			updIll <= microLatch[0];		// Update on any IRC->IR
		else if( enT1 & updIll)
			inl <= iIpl;					// Timing is correct.
			
		// Spurious interrupt, BERR on Interrupt Ack.
		// Autovector interrupt. VPA on IACK.
		// Timing is tight. Spuria is deasserted just after exception exception is recorded.
		if( enT4) begin
			Spuria <= ~BeiDelay & Iac;
			Avia <= ~Vpai & Iac;
		end
			
	end
		
	assign enErrClk = iAddrErr | iBusErr;
	assign wClk = waitBusCycle | ~BeI | iAddrErr | Err6591;
	
	// E clock and counter, VMA
	reg [3:0] eCntr;
	reg rVma;
	
	assign VMAn = rVma;
	
	// Internal stop just one cycle before E falling edge
	wire xVma = ~rVma & (eCntr == 8);
	
`ifdef USE_E_CLKEN
	assign E_PosClkEn = (Clks.enPhi2 & (eCntr == 5));
	assign E_NegClkEn = (Clks.enPhi2 & (eCntr == 9));
`endif
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			E <= 1'b0;
			eCntr <='0;
			rVma <= 1'b1;
		end
		if( Clks.enPhi2) begin
			if( eCntr == 9)
				E <= 1'b0;
			else if( eCntr == 5)
				E <= 1'b1;

			if( eCntr == 9)
				eCntr <= '0;
			else
				eCntr <= eCntr + 1'b1;
		end
		
		if( Clks.enPhi2 & addrOe & ~Vpai & (eCntr == 3))
			rVma <= 1'b0;
		else if( Clks.enPhi1 & eCntr == '0)
			rVma <= 1'b1;
	end
		
	always_ff @( posedge Clks.clk) begin
	
		// This timing is critical to stop the clock phases at the exact point on bus/addr error.
		// Timing should be such that current ublock completes (up to T3 or T4).
		// But T1 for the next ublock shouldn't happen. Next T1 only after resetting ucode and ncode latches.
		
		if( Clks.extReset)
			rAddrErr <= 1'b0;
		else if( Clks.enPhi1) begin
			if( busAddrErr & addrOe)		// Not on T1 ?!
				rAddrErr <= 1'b1;
			else if( ~addrOe)				// Actually async reset!
				rAddrErr <= 1'b0;
		end
		
		if( Clks.extReset)
			iBusErr <= 1'b0;
		else if( Clks.enPhi1) begin
			iBusErr <= ( BerrA & ~BeI & ~Iac & !BusRetry);
		end

		if( Clks.extReset)
			BerrA <= 1'b0;
		else if( Clks.enPhi2) begin
			if( ~BeI & ~Iac & addrOe)
				BerrA <= 1'b1;
			// else if( BeI & addrOe)			// Bad, async reset since addrOe raising edge
			else if( BeI & busStarting)			// So replaced with this that raises one cycle earlier
				BerrA <= 1'b0;
		end

		// Signal reset exception to sequencer.
		// Originally cleared on 1st T2 after permstart. Must keep it until TVN latched.
		if( Clks.extReset)
			excRst <= 1'b1;
		else if( enT2 & Nanod.permStart)
			excRst <= 1'b0;
		
		if( Clks.extReset)
			A0Err <= 1'b1;								// A0 Reset
		else if( enT3)									// Keep set until new urom words are being latched
			A0Err <= 1'b0;
		else if( Clks.enPhi1 & enErrClk & (busAddrErr | BerrA))		// Check bus error timing
			A0Err <= 1'b1;
		
		if( Clks.extReset) begin
			iStop <= 1'b0;
			Err6591 <= 1'b0;
		end
		else if( Clks.enPhi1)
			Err6591 <= enErrClk;
		else if( Clks.enPhi2)
			iStop <= xVma | (Vpai & (iAddrErr | ~rBerr));
	end
	
	// PSW
	logic irdToCcr_t4;
	always_ff @( posedge Clks.clk) begin				
		if( Clks.pwrUp) begin
			Tpend <= 1'b0;
			{pswT, pswS, pswI } <= '0;
			irdToCcr_t4 <= '0;
		end
		
		else if( enT4) begin
			irdToCcr_t4 <= Irdecod.toCcr;
		end
		
		else if( enT3) begin
		
			// UNIQUE IF !!	
			if( nanoLatch[ NANO_RESUME])
				Tpend <= shMisc1[12];
			else if( Nanod.updTpend | Nanod.tpend010)
				Tpend <= pswT;
			else if( Nanod.clrTpend)
				Tpend <= 1'b0;
			
			// UNIQUE IF !!	
			if( Nanod.ftu2Sr & !irdToCcr_t4)
				{pswT, pswS, pswI } <= { ftu[ 15], ftu[13], ftu[10:8]};
			else begin
				if( Nanod.initST) begin
					pswS <= 1'b1;
					pswT <= 1'b0;
				end
				if( Nanod.inl2psw)
					pswI <= inl;
			end
				
		end
	end
		
	// FTU
	reg [4:0] ssw;
	reg [3:0] tvnLatch;
	logic [15:0] tvnMux;
	reg inExcept01;
	
	// Seems CPU has a buglet here.
	// Flagging group 0 exceptions from TVN might not work because some bus cycles happen before TVN is updated.
	// But doesn't matter because a group 0 exception inside another one will halt the CPU anyway and won't save the SSW.
		

	always_ff @( posedge Clks.clk) begin

		// Updated at the start of the exception ucode
		if( Nanod.updSsw & enT3) begin
			ssw <= { ~bciWrite, inExcept01, rFC};
			ssw010 <= { 2'b00, ~bciWrite & (rFC[1:0] == 2'b10), ~bciWrite & (rFC[1:0] == 2'b01),
						bciRmc, 1'b0, bciByte, ~bciWrite, 5'b0, rFC};
		end

		// Update TVN on T1 & IR=>IRD
		if( enT1 & Nanod.Ir2Ird) begin
			tvnLatch <= tvn;
			inExcept01 <= (tvn != 1);
		end
		else if( enT1 & (| Nanod.tvnForce)) begin
			tvnLatch <= Nanod.tvnForce[1] ? 4'd14 : 4'd4;		// Format error or illegal instruction
			inExcept01 <= 1'b1;
		end

		if( Clks.pwrUp)
			ftu <= '0;
		else if( resumeT3)
			ftu <= shFtu;
		else if( enT3) begin
			unique case( 1'b1)
			Nanod.ssw010:				ftu <= ssw010;
			Nanod.tvn2Ftu:				ftu <= tvnMux;

			// 0 on unused bits seem to come from ftuConst PLA previously clearing FBUS
			Nanod.sr2Ftu:				ftu <= Nanod.ccrOnly ? {11'b0, ccr[4:0]} :
											{pswT, 1'b0, pswS, 2'b00, pswI, 3'b000, ccr[4:0] };

			Nanod.ird2Ftu:				ftu <= Ird;
			Nanod.ssw2Ftu:				ftu[4:0] <= ssw;						// Undoc. Other bits must be preserved from IRD saved above!
			Nanod.pswIToFtu:			ftu <= { 12'hFFF, pswI, 1'b0};			// Interrupt level shifted
			Nanod.const2Ftu:			ftu <= Irdecod.ftuConst;
			Nanod.abl2Pren:				ftu <= Abl;								// From ALU or datareg. Used for SR modify
			default:					ftu <= ftu;
			endcase
		end
	end

	always_comb begin
		if( inExcept01) begin
			// Unique IF !!!
			if( tvnLatch == TVN_SPURIOUS)
				tvnMux = {9'b0, 5'd24, 2'b00};
			else if( tvnLatch == TVN_AUTOVEC)
				tvnMux = {9'b0, 2'b11, pswI, 2'b00};				// Set TVN PLA decoder
			else if( tvnLatch == TVN_INTERRUPT)
				tvnMux = {6'b0, Ird[7:0], 2'b00};					// Interrupt vector was read and transferred to IRD
			else
				// 68010 bus and address error frame is format 8
				tvnMux = {is010 & (tvnLatch[3:1] == 3'b001), 9'b0, tvnLatch, 2'b00};
		end
		else
			tvnMux = { 8'h0, Irdecod.macroTvn, 2'b00};
	end
				
endmodule

// Nanorom (plus) decoder for die nanocode
module nDecoder3( input s_clks Clks, input s_irdecod Irdecod, output s_nanod Nanod,
	input enT2, enT4,
	input [UROM_WIDTH-1:0] microLatch,
	input [NANO_WIDTH-1:0] nanoLatch,
	input [15:0] shSsw,				// 68010 RTE format 8: SSW of the frame
	input [5:0] shCtl);				// ... data capture of the faulted cycle

localparam NANO_IR2IRD = 67;
localparam NANO_TOIRC = 66;
localparam NANO_ALU_COL = 63;		// ALU operator column order is 63-64-65 !
localparam NANO_ALU_FI = 61;	// ALU finish-init 62-61
localparam NANO_TODBIN = 60;
localparam NANO_ALUE = 57;			// 57-59 shared with DCR control
localparam NANO_DCR = 57;			// 57-59 shared with ALUE control
localparam NANO_DOBCTRL_1 = 56;		// Input to control and permwrite
localparam NANO_LOWBYTE = 55;		// Used by MOVEP
localparam NANO_HIGHBYTE = 54;
localparam NANO_DOBCTRL_0 = 53;		// Input to control and permwrite
localparam NANO_ALU_DCTRL = 51;	// 52-51 databus input mux control
localparam NANO_ALU_ACTRL = 50;	// addrbus input mux control
localparam NANO_DBD2ALUB = 49;
localparam NANO_ABD2ALUB = 48;
localparam NANO_DBIN2DBD = 47;
localparam NANO_DBIN2ABD = 46;
localparam NANO_ALU2ABD = 45;
localparam NANO_ALU2DBD = 44;
localparam NANO_RZ = 43;
localparam NANO_BUSBYTE = 42;		// If *both* this set and instruction is byte sized, then bus cycle is byte sized.
localparam NANO_PCLABL = 41;
localparam NANO_RXL_DBL = 40;		// Switches RXL/RYL on DBL/ABL buses
localparam NANO_PCLDBL = 39;
localparam NANO_ABDHRECHARGE = 38;
localparam NANO_REG2ABL = 37;		// register to ABL
localparam NANO_ABL2REG = 36;		// ABL to register
localparam NANO_ABLABD = 35;
localparam NANO_DBLDBD = 34;
localparam NANO_DBL2REG = 33;		// DBL to register
localparam NANO_REG2DBL = 32;		// register to DBL
localparam NANO_ATLCTRL = 29;		// 31-29
localparam NANO_FTUCONTROL = 25;
localparam NANO_SSP = 24;
localparam NANO_RXH_DBH = 22;		// Switches RXH/RYH on DBH/ABH buses
localparam NANO_AUOUT = 20;			// 21-20
localparam NANO_AUCLKEN = 19;
localparam NANO_AUCTRL = 16;		// 18-16
localparam NANO_DBLDBH = 15;
localparam NANO_ABLABH = 14;
localparam NANO_EXT_ABH = 13;
localparam NANO_EXT_DBH = 12;
localparam NANO_ATHCTRL = 9;		// 11-9
localparam NANO_REG2ABH = 8;		// register to ABH
localparam NANO_ABH2REG = 7;		// ABH to register
localparam NANO_REG2DBH = 6;		// register to DBH
localparam NANO_DBH2REG = 5;		// DBH to register
localparam NANO_AOBCTRL = 3;		// 4-3
localparam NANO_PCH = 0;			// 1-0 PchDbh PchAbh
localparam NANO_NO_SP_ALGN = 0;		// Same bits as above when both set

localparam NANO_FTU_UPDTPEND = 1;		// Also loads FTU constant according to IRD !
localparam NANO_FTU_INIT_ST = 15;		// Set S, clear T (but not TPEND)
localparam NANO_FTU_CLRTPEND = 14;
localparam NANO_FTU_TVN = 13;
localparam NANO_FTU_ABL2PREN = 12;		// ABL => FTU & ABL => PREN. Both transfers enabled, but only one will be used depending on uroutine.
localparam NANO_FTU_SSW = 11;
localparam NANO_FTU_RSTPREN = 10;
localparam NANO_FTU_IRD = 9;
localparam NANO_FTU_2ABL = 8;
localparam NANO_FTU_RDSR = 7;
localparam NANO_FTU_INL = 6;
localparam NANO_FTU_PSWI = 5;		// Read Int Mask into FTU
localparam NANO_FTU_DBL = 4;
localparam NANO_FTU_2SR = 2;
localparam NANO_FTU_CONST = 1;


	reg [3:0] ftuCtrl;	
	
	logic [2:0] athCtrl, atlCtrl;
	assign athCtrl = nanoLatch[ NANO_ATHCTRL+2: NANO_ATHCTRL];
	assign atlCtrl = nanoLatch[ NANO_ATLCTRL+2: NANO_ATLCTRL];
	wire [1:0] aobCtrl = nanoLatch[ NANO_AOBCTRL+1:NANO_AOBCTRL];
	wire [1:0] dobCtrl = {nanoLatch[ NANO_DOBCTRL_1], nanoLatch[NANO_DOBCTRL_0]};
	
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			// Reverse order!
			ftuCtrl <= { nanoLatch[ NANO_FTUCONTROL+0], nanoLatch[ NANO_FTUCONTROL+1], nanoLatch[ NANO_FTUCONTROL+2], nanoLatch[ NANO_FTUCONTROL+3]} ;
				
			Nanod.auClkEn <= !nanoLatch[ NANO_AUCLKEN];
			Nanod.auCntrl <= nanoLatch[ NANO_AUCTRL+2 : NANO_AUCTRL+0];
			Nanod.auVbr <= nanoLatch[ NANO_AUVBR];
			Nanod.tpend010 <= nanoLatch[ NANO_TPEND];
			Nanod.hiLatch <= nanoLatch[ NANO_HILATCH];
			Nanod.hiSel <= nanoLatch[ NANO_HISEL];
			Nanod.hiOp <= nanoLatch[ NANO_HIOP];
			Nanod.ftuAbl <= nanoLatch[ NANO_FTUABL];
			Nanod.auCc <= nanoLatch[ NANO_AUCC+1:NANO_AUCC];
			Nanod.shIdx <= nanoLatch[ NANO_SHIDX+4:NANO_SHIDX];
			Nanod.shW <= nanoLatch[ NANO_SHW];
			Nanod.resume <= nanoLatch[ NANO_RESUME];
			Nanod.auK2 <= nanoLatch[ NANO_AUK2];
			Nanod.ssw010 <= nanoLatch[ NANO_SSW010];
			Nanod.ccrOnly <= nanoLatch[ NANO_CCRONLY];
			Nanod.auK <= nanoLatch[ NANO_AUK+1:NANO_AUK];
			Nanod.dobX <= nanoLatch[ NANO_DOBX+2:NANO_DOBX];
			Nanod.noSpAlign <= (nanoLatch[ NANO_NO_SP_ALGN + 1:NANO_NO_SP_ALGN] == 2'b11);			
			Nanod.extDbh <= nanoLatch[ NANO_EXT_DBH];
			Nanod.extAbh <= nanoLatch[ NANO_EXT_ABH];
			Nanod.todbin <= nanoLatch[ NANO_RESUME] ? shCtl[4] : nanoLatch[ NANO_TODBIN];
			Nanod.toIrc <=  nanoLatch[ NANO_RESUME] ? shCtl[5] : nanoLatch[ NANO_TOIRC];
			
			// ablAbd is disabled on byte transfers (adbhCharge plus irdIsByte). Not sure the combination makes much sense.
			// It happens in a few cases but I don't see anything enabled on abL (or abH) section anyway.
			
			Nanod.ablAbd <= nanoLatch[ NANO_ABLABD];
			Nanod.ablAbh <= nanoLatch[ NANO_ABLABH];
			Nanod.dblDbd <= nanoLatch[ NANO_DBLDBD];
			Nanod.dblDbh <= nanoLatch[ NANO_DBLDBH];
			
			Nanod.dbl2Atl <= (atlCtrl == 3'b010);
			Nanod.atl2Dbl <= (atlCtrl == 3'b011);
			Nanod.abl2Atl <= (atlCtrl == 3'b100);
			Nanod.atl2Abl <= (atlCtrl == 3'b101);

			Nanod.aob2Ab <= (athCtrl == 3'b101);		// Used on BSER1 only
			
			Nanod.abh2Ath <= (athCtrl == 3'b001) | (athCtrl == 3'b101);
			Nanod.dbh2Ath <= (athCtrl == 3'b100);
			Nanod.ath2Dbh <= (athCtrl == 3'b110);
			Nanod.ath2Abh <= (athCtrl == 3'b011);			

			Nanod.alu2Dbd <= nanoLatch[ NANO_ALU2DBD];
			Nanod.alu2Abd <= nanoLatch[ NANO_ALU2ABD];
			
			Nanod.abd2Dcr <= (nanoLatch[ NANO_DCR+1:NANO_DCR] == 2'b11);
			Nanod.dcr2Dbd <= (nanoLatch[ NANO_DCR+2:NANO_DCR+1] == 2'b11);
			Nanod.dbd2Alue <= (nanoLatch[ NANO_ALUE+2:NANO_ALUE+1] == 2'b10);
			Nanod.alue2Dbd <= (nanoLatch[ NANO_ALUE+1:NANO_ALUE] == 2'b01);

			Nanod.dbd2Alub <= nanoLatch[ NANO_DBD2ALUB];
			Nanod.abd2Alub <= nanoLatch[ NANO_ABD2ALUB];			
			
			// Originally not latched. We better should because we transfer one cycle later, T3 instead of T1.
			Nanod.dobCtrl <= dobCtrl;
			// Nanod.adb2Dob <= (dobCtrl == 2'b10);			Nanod.dbd2Dob <= (dobCtrl == 2'b01);			Nanod.alu2Dob <= (dobCtrl == 2'b11);
							
		end
	end
	
	// Update SSW at the start of Bus/Addr error ucode
	assign Nanod.updSsw = Nanod.aob2Ab;

	assign Nanod.updTpend = (ftuCtrl == NANO_FTU_UPDTPEND);
	assign Nanod.clrTpend = (ftuCtrl == NANO_FTU_CLRTPEND);
	assign Nanod.tvn2Ftu = (ftuCtrl == NANO_FTU_TVN);
	assign Nanod.const2Ftu = (ftuCtrl == NANO_FTU_CONST);
	assign Nanod.ftu2Dbl = (ftuCtrl == NANO_FTU_DBL) | ( ftuCtrl == NANO_FTU_INL);	
	assign Nanod.ftu2Abl = (ftuCtrl == NANO_FTU_2ABL);	
	assign Nanod.inl2psw = (ftuCtrl == NANO_FTU_INL);
	assign Nanod.pswIToFtu = (ftuCtrl == NANO_FTU_PSWI);
	assign Nanod.ftu2Sr = (ftuCtrl == NANO_FTU_2SR);
	assign Nanod.sr2Ftu = (ftuCtrl == NANO_FTU_RDSR);
	assign Nanod.ird2Ftu = (ftuCtrl == NANO_FTU_IRD);		// Used on bus/addr error
	assign Nanod.ssw2Ftu = (ftuCtrl == NANO_FTU_SSW);
	assign Nanod.initST = (ftuCtrl == NANO_FTU_INL) | (ftuCtrl == NANO_FTU_CLRTPEND) | (ftuCtrl == NANO_FTU_INIT_ST);
	assign Nanod.abl2Pren = (ftuCtrl == NANO_FTU_ABL2PREN);
	assign Nanod.updPren = (ftuCtrl == NANO_FTU_RSTPREN);
	
	assign Nanod.Ir2Ird = nanoLatch[ NANO_IR2IRD];
	assign Nanod.extLatch = nanoLatch[ NANO_EXTLATCH];
	assign Nanod.irSynth = nanoLatch[ NANO_IRSYNTH];
	assign Nanod.tvnForce = nanoLatch[ NANO_TVNFORCE+1:NANO_TVNFORCE];
	assign Nanod.irLoop = nanoLatch[ NANO_IRLOOP];
	assign Nanod.ircLoop = nanoLatch[ NANO_IRCLOOP];
	assign Nanod.fmtCcr = nanoLatch[ NANO_FMTCCR];
	assign Nanod.aobZero = nanoLatch[ NANO_AOBZERO];
	assign Nanod.aobPc = nanoLatch[ NANO_AOBPC];

	// ALU control better latched later after combining with IRD decoding
		
	assign Nanod.aluDctrl = nanoLatch[ NANO_ALU_DCTRL+1 : NANO_ALU_DCTRL];
	assign Nanod.aluActrl = nanoLatch[ NANO_ALU_ACTRL];
	assign Nanod.aluColumn = { nanoLatch[ NANO_ALU_COL], nanoLatch[ NANO_ALU_COL+1], nanoLatch[ NANO_ALU_COL+2]};
	wire [1:0] aluFinInit = nanoLatch[ NANO_ALU_FI+1:NANO_ALU_FI];
	assign Nanod.aluFinish = (aluFinInit == 2'b10);
	assign Nanod.aluInit = (aluFinInit == 2'b01);

	// FTU 2 CCR encoded as both ALU Init and ALU Finish set.
	// In theory this encoding allows writes to CCR without writing to SR
	// But FTU 2 CCR and to SR are both set together at nanorom.
	assign Nanod.ftu2Ccr = ( aluFinInit == 2'b11);

	assign Nanod.abdIsByte = nanoLatch[ NANO_ABDHRECHARGE];
	
	// Not being latched on T4 creates non unique case warning!
	assign Nanod.au2Db = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b01);
	assign Nanod.au2Ab = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b10);
	assign Nanod.au2Pc = (nanoLatch[ NANO_AUOUT + 1: NANO_AUOUT] == 2'b11);
	
	assign Nanod.db2Aob = (aobCtrl == 2'b10);
	assign Nanod.ab2Aob = (aobCtrl == 2'b01);
	assign Nanod.au2Aob = (aobCtrl == 2'b11);
	
	assign Nanod.dbin2Abd = nanoLatch[ NANO_DBIN2ABD];
	assign Nanod.dbin2Dbd = nanoLatch[ NANO_DBIN2DBD];
	
	// 68010 RTE format 8: rerun of the faulted bus cycle, or a virtual read of the data input
	// buffer when the handler did the cycle (SSW RR)
	wire resumeNow = nanoLatch[ NANO_RESUME];
	wire resumeCycle = resumeNow & (~shSsw[15] | shSsw[8]);
	assign Nanod.permStart = (| aobCtrl) | resumeCycle;
	assign Nanod.isWrite  = ( | dobCtrl) | (resumeNow & ~shSsw[15] & ~shSsw[8]);
	assign Nanod.waitBusFinish = nanoLatch[ NANO_TOIRC] | nanoLatch[ NANO_TODBIN] | Nanod.isWrite | resumeCycle;
	assign Nanod.busByte = nanoLatch[ NANO_BUSBYTE];
	
	assign Nanod.noLowByte = nanoLatch[ NANO_LOWBYTE];
	assign Nanod.noHighByte = nanoLatch[ NANO_HIGHBYTE];	
			
	// Not registered. Register at T4 after combining
	// Might be better to remove all those and combine here instead of at execution unit !!
	assign Nanod.abl2reg = nanoLatch[ NANO_ABL2REG];
	assign Nanod.abh2reg = nanoLatch[ NANO_ABH2REG];
	assign Nanod.dbl2reg = nanoLatch[ NANO_DBL2REG];
	assign Nanod.dbh2reg = nanoLatch[ NANO_DBH2REG];
	assign Nanod.reg2dbl = nanoLatch[ NANO_REG2DBL];
	assign Nanod.reg2dbh = nanoLatch[ NANO_REG2DBH];
	assign Nanod.reg2abl = nanoLatch[ NANO_REG2ABL];
	assign Nanod.reg2abh = nanoLatch[ NANO_REG2ABH];
	
	assign Nanod.ssp = nanoLatch[ NANO_SSP];
	
	assign Nanod.rz = nanoLatch[ NANO_RZ];
	
	// Actually DTL can't happen on PC relative mode. See IR decoder.
	
	wire dtldbd = 1'b0;
	wire dthdbh = 1'b0;
	wire dtlabd = 1'b0;
	wire dthabh = 1'b0;
	
	wire dblSpecial = Nanod.pcldbl | dtldbd;
	wire dbhSpecial = Nanod.pchdbh | dthdbh;
	wire ablSpecial = Nanod.pclabl | dtlabd;
	wire abhSpecial = Nanod.pchabh | dthabh;
			
	//
	// Combine with IRD decoding
	// Careful that IRD is updated only on T1! All output depending on IRD must be latched on T4!
	//
	
	// PC used instead of RY on PC relative instuctions
	
	assign Nanod.rxlDbl = nanoLatch[ NANO_RXL_DBL];
	wire isPcRel = Irdecod.isPcRel & !Nanod.rz;
	wire pcRelDbl = isPcRel & !nanoLatch[ NANO_RXL_DBL];
	wire pcRelDbh = isPcRel & !nanoLatch[ NANO_RXH_DBH];
	wire pcRelAbl = isPcRel & nanoLatch[ NANO_RXL_DBL];
	wire pcRelAbh = isPcRel & nanoLatch[ NANO_RXH_DBH];
	
	assign Nanod.pcldbl = nanoLatch[ NANO_PCLDBL] | pcRelDbl;
	assign Nanod.pchdbh = (nanoLatch[ NANO_PCH+1:NANO_PCH] == 2'b01) | pcRelDbh;
	
	assign Nanod.pclabl = nanoLatch[ NANO_PCLABL] | pcRelAbl;
	assign Nanod.pchabh = (nanoLatch[ NANO_PCH+1:NANO_PCH] == 2'b10) | pcRelAbh;

	// Might be better not to register these signals to allow latching RX/RY mux earlier!
	// But then must latch Irdecod.isPcRel on T3!

	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			Nanod.rxl2db <= Nanod.reg2dbl & !dblSpecial & nanoLatch[ NANO_RXL_DBL];
			Nanod.rxl2ab <= Nanod.reg2abl & !ablSpecial & !nanoLatch[ NANO_RXL_DBL];
			
			Nanod.dbl2rxl <= Nanod.dbl2reg & !dblSpecial & nanoLatch[ NANO_RXL_DBL];	
			Nanod.abl2rxl <= Nanod.abl2reg & !ablSpecial & !nanoLatch[ NANO_RXL_DBL];	

			Nanod.rxh2dbh <= Nanod.reg2dbh & !dbhSpecial & nanoLatch[ NANO_RXH_DBH];			
			Nanod.rxh2abh <= Nanod.reg2abh & !abhSpecial & !nanoLatch[ NANO_RXH_DBH];			
				
			Nanod.dbh2rxh <= Nanod.dbh2reg & !dbhSpecial & nanoLatch[ NANO_RXH_DBH];
			Nanod.abh2rxh <= Nanod.abh2reg & !abhSpecial & !nanoLatch[ NANO_RXH_DBH];	

			Nanod.dbh2ryh <= Nanod.dbh2reg & !dbhSpecial & !nanoLatch[ NANO_RXH_DBH];
			Nanod.abh2ryh <= Nanod.abh2reg & !abhSpecial & nanoLatch[ NANO_RXH_DBH];	

			Nanod.dbl2ryl <= Nanod.dbl2reg & !dblSpecial & !nanoLatch[ NANO_RXL_DBL];	
			Nanod.abl2ryl <= Nanod.abl2reg & !ablSpecial & nanoLatch[ NANO_RXL_DBL];	

			Nanod.ryl2db <= Nanod.reg2dbl & !dblSpecial & !nanoLatch[ NANO_RXL_DBL];
			Nanod.ryl2ab <= Nanod.reg2abl & !ablSpecial & nanoLatch[ NANO_RXL_DBL];

			Nanod.ryh2dbh <= Nanod.reg2dbh & !dbhSpecial & !nanoLatch[ NANO_RXH_DBH];			
			Nanod.ryh2abh <= Nanod.reg2abh & !abhSpecial & nanoLatch[ NANO_RXH_DBH];					
		end
		
		// Originally isTas only delayed on T2 (and seems only a late mask rev fix)
		// Better latch the combination on T4
		if( enT4)
			Nanod.isRmc <= Irdecod.isTas & nanoLatch[ NANO_BUSBYTE];
	end
			
	
endmodule

//
// IRD execution decoder. Complements nano code decoder
//
// IRD updated on T1, while ncode still executing. To avoid using the next IRD,
// decoded signals must be registered on T3, or T4 before using them.
//
module irdDecode( input [15:0] ird,
			input [1:0] synKind,			// IRD is a synthesized 68010 MOVEC/MOVES opcode
			input [15:0] extW,				// and its extension word
			input irdClr,					// IRD is the MOVE D0,<ea> of a 68010 CLR
			output s_irdecod Irdecod);

	wire [3:0] line = ird[15:12];
	logic [15:0] lineOnehot;

	// 68010 MOVEC executes as MOVE USP. RX is the control register, RY the general register.
	// MOVES executes as MOVE. MOVES.B from An reads An through the data register path,
	// MOVES.B to An executes as MOVEA.W with a byte access sign extended to a word.
	wire synMovec = (synKind == SYN_MOVEC);
	wire synMoves = synKind[1];
	wire movesBStoreA = (synKind == SYN_MOVESB) & extW[15] & extW[11];
	wire movesBLoadA = (synKind == SYN_MOVESB) & extW[15] & ~extW[11];

	always_comb begin
		Irdecod.rxOvr = synMovec;
		case( { extW[11], extW[0]})
		2'b00:		Irdecod.rxOvrMux = 5'd18;		// SFC
		2'b01:		Irdecod.rxOvrMux = 5'd19;		// DFC
		2'b10:		Irdecod.rxOvrMux = 5'd15;		// USP
		2'b11:		Irdecod.rxOvrMux = 5'd20;		// VBR
		endcase

		Irdecod.ryOvr = synMovec | movesBStoreA;
		Irdecod.ryOvrReg = extW[15:12];
		Irdecod.ryOvrAreg = synMovec;
	end

	assign Irdecod.isMoves = synMoves;
	assign Irdecod.ryZero = irdClr;
	assign Irdecod.movesSext = movesBLoadA;

	// This can be registered and pipelined from the IR decoder !
	onehotEncoder4 irdLines( line, lineOnehot);
	
	wire isRegShift = (lineOnehot['he]) & (ird[7:6] != 2'b11);
	wire isDynShift = isRegShift & ird[5];
					
	assign Irdecod.isPcRel = (& ird[ 5:3]) & ~isDynShift & !ird[2] & ird[1];		
	assign Irdecod.isTas = lineOnehot[4] & (ird[11:6] == 6'b101011);
	
	assign Irdecod.rx = ird[11:9];
	assign Irdecod.ry = ird[ 2:0];

	wire isPreDecr = (ird[ 5:3] == 3'b100);
	wire eaAreg = (ird[5:3] == 3'b001);
		
	// rx is A or D
	// movem
	always_comb begin
		unique case( 1'b1)
		lineOnehot[1],
		lineOnehot[2],
		lineOnehot[3]:
					// MOVE: RX always Areg except if dest mode is Dn 000
					Irdecod.rxIsAreg = (| ird[8:6]);

		lineOnehot[4]:		Irdecod.rxIsAreg = (& ird[8:6]);		// not CHK (LEA)

		lineOnehot['h8]:	Irdecod.rxIsAreg = eaAreg & ird[8] & ~ird[7];	// SBCD
		lineOnehot['hc]:	Irdecod.rxIsAreg = eaAreg & ird[8] & ~ird[7];	// ABCD/EXG An,An				
		
		lineOnehot['h9],
		lineOnehot['hb],
		lineOnehot['hd]:	Irdecod.rxIsAreg =
							(ird[7] & ird[6]) |								// SUBA/CMPA/ADDA
							(eaAreg & ird[8] & (ird[7:6] != 2'b11));		// SUBX/CMPM/ADDX		
		default:
				Irdecod.rxIsAreg = Irdecod.implicitSp;
		endcase
	end	

	// RX is movem
	always_comb begin
		Irdecod.rxIsMovem = lineOnehot[4] & ~ird[8] & ~Irdecod.implicitSp;
	end
	assign Irdecod.movemPreDecr = Irdecod.rxIsMovem & isPreDecr;
	
	// RX is DT.
	// but SSP explicit or pc explicit has higher priority!
	// addq/subq (scc & dbcc also, but don't use rx)
	// Immediate including static bit
	assign Irdecod.rxIsDt = lineOnehot[5] | (lineOnehot[0] & ~ird[8]);
	
	// RX is USP
	assign Irdecod.rxIsUsp = lineOnehot[4] & (ird[ 11:4] == 8'he6);
	
	// RY is DT
	// rz or PC explicit has higher priority
	
	wire eaImmOrAbs = (ird[5:3] == 3'b111) & ~ird[1];
	assign Irdecod.ryIsDt = eaImmOrAbs & ~isRegShift;
		
	// RY is Address register
	always_comb begin
		logic eaIsAreg;
		
		// On most cases RY is Areg expect if mode is 000 (DATA REG) or 111 (IMM, ABS,PC REL)
		eaIsAreg = (ird[5:3] != 3'b000) & (ird[5:3] != 3'b111);
		
		unique case( 1'b1)
				// MOVE: RY always Areg expect if mode is 000 (DATA REG) or 111 (IMM, ABS,PC REL)
				// Most lines, including misc line 4, also.
		default:		Irdecod.ryIsAreg = eaIsAreg;

		lineOnehot[5]:	// DBcc is an exception
						Irdecod.ryIsAreg = eaIsAreg & (ird[7:3] != 5'b11001);

		lineOnehot[6],
		lineOnehot[7]:	Irdecod.ryIsAreg = 1'b0;

		lineOnehot['he]:
						Irdecod.ryIsAreg = ~isRegShift;
		endcase
	end	

	// Byte sized instruction
		
	// Original implementation sets this for some instructions that aren't really byte size
	// but doesn't matter because they don't have a byte transfer enabled at nanocode, such as MOVEQ
		
	wire xIsScc = (ird[7:6] == 2'b11) & (ird[5:3] != 3'b001); 
	wire xStaticMem = (ird[11:8] == 4'b1000) & (ird[5:4] == 2'b00);		// Static bit to mem
	always_comb begin
		unique case( 1'b1)
		lineOnehot[0]:
				Irdecod.isByte = 
				( ird[8] & (ird[5:4] != 2'b00)					) |	// Dynamic bit to mem
				( (ird[11:8] == 4'b1000) & (ird[5:4] != 2'b00)	) |	// Static bit to mem
				( (ird[8:7] == 2'b10) & (ird[5:3] == 3'b001)	) |	// Movep from mem only! For byte mux
				( (ird[8:6] == 3'b000) & !xStaticMem );				// Immediate byte
								
		lineOnehot[1]:			Irdecod.isByte = 1'b1;		// MOVE.B
	
		
		lineOnehot[4]:			Irdecod.isByte = (ird[7:6] == 2'b00) | Irdecod.isTas;		
		lineOnehot[5]:			Irdecod.isByte = (ird[7:6] == 2'b00) | xIsScc;
		
		lineOnehot[8],
		lineOnehot[9],
		lineOnehot['hb],
		lineOnehot['hc],
		lineOnehot['hd],
		lineOnehot['he]:		Irdecod.isByte = (ird[7:6] == 2'b00);

		default:				Irdecod.isByte = 1'b0;
		endcase

		// MOVES.B to An executes as MOVEA.W
		if( movesBLoadA)
			Irdecod.isByte = 1'b1;
	end
	
	// Need it for special byte size. Bus is byte, but whole register word is modified.
	assign Irdecod.isMovep = lineOnehot[0] & ird[8] & eaAreg;
	
	
	// rxIsSP implicit use of RX for actual SP transfer
	//
	// This logic is simple and will include some instructions that don't actually reference SP.
	// But doesn't matter as long as they don't perform any RX transfer.
	
	always_comb begin
		unique case( 1'b1)
		lineOnehot[6]:		Irdecod.implicitSp = (ird[11:8] == 4'b0001);		// BSR
		lineOnehot[4]:
			// Misc like RTS, JSR, etc
			Irdecod.implicitSp = (ird[11:8] == 4'b1110) | (ird[11:6] == 6'b1000_01);
		default:			Irdecod.implicitSp = 1'b0;
		endcase
	end
	
	// Modify CCR (and not SR)
	// Probably overkill !! Only needs to distinguish SR vs CCR
	// RTR, MOVE to CCR, xxxI to CCR
	assign Irdecod.toCcr =	( lineOnehot[4] & ((ird[11:0] == 12'he77) | (ird[11:6] == 6'b010011)) ) |
							( lineOnehot[0] & (ird[8:6] == 3'b000));
	
	// FTU constants
	// This should not be latched on T3/T4. Latch on T2 or not at all. FTU needs it on next T3.
	// Note: Reset instruction gets constant from ALU not from FTU!
	logic [15:0] ftuConst;
	wire [3:0] zero28 = (ird[11:9] == 0) ? 4'h8 : { 1'b0, ird[11:9]};		// xltate 0,1-7 into 8,1-7

	always_comb begin
		unique case( 1'b1)
		lineOnehot[6],														// Bcc short
		lineOnehot[7]:		ftuConst = { { 8{ ird[ 7]}}, ird[ 7:0] };		// MOVEQ
		
		lineOnehot['h5],													// addq/subq/static shift double check this
		lineOnehot['he]:	ftuConst = { 12'b0, zero28};
		
		// MULU/MULS DIVU/DIVS
		lineOnehot['h8],
		lineOnehot['hc]:	ftuConst = 16'h0f;

		lineOnehot[4]:		ftuConst = 16'h80;								// TAS

		default:			ftuConst = '0;
		endcase	
	end	
	assign Irdecod.ftuConst = ftuConst;
	
	//
	// TRAP Vector # for group 2 exceptions
	//
	
	always_comb begin
		if( lineOnehot[4]) begin
			case ( ird[6:5])
			2'b00,2'b01:	Irdecod.macroTvn = 6;					// CHK
			2'b11:			Irdecod.macroTvn = 7;					// TRAPV
			2'b10:			Irdecod.macroTvn = {2'b10, ird[3:0]};	// TRAP
			endcase
		end
		else
							Irdecod.macroTvn = 5;					// Division by zero
	end
	
	
	wire eaAdir = (ird[ 5:3] == 3'b001);
	wire size11 = ird[7] & ird[6];
	
	// Opcodes variants that don't affect flags
	// ADDA/SUBA ADDQ/SUBQ MOVEA

	assign Irdecod.inhibitCcr =
		( (lineOnehot[9] | lineOnehot['hd]) & size11) |				// ADDA/SUBA
		( lineOnehot[5] & eaAdir) |									// ADDQ/SUBQ to An (originally checks for line[4] as well !?)
		( (lineOnehot[2] | lineOnehot[3]) & ird[8:6] == 3'b001);	// MOVEA
		
endmodule

/*
 Execution unit

 Executes register transfers set by the microcode. Originally through a set of bidirectional buses.
 Most sources are available at T3, but DBIN only at T4! CCR also might be updated at T4, but it is not connected to these buses.
 We mux at T1 and T2, then transfer to the destination at T3. The exception is AOB that need to be updated earlier.

*/

module excUnit( input s_clks Clks,
	input enT1, enT2, enT3, enT4,
	input s_nanod Nanod, input s_irdecod Irdecod,
	input [15:0] Ird,			// ALU row (and others) decoder needs it	
	input pswS,
	input [15:0] ftu,
	input [15:0] iEdb,
	
	output logic [7:0] ccr,
	output [15:0] alue,
	
	output prenEmpty, au05z,
	output logic dcr4, ze,
	output logic aob0,
	output [15:0] AblOut,
	output atl15,						// 68010 DIVU
	output logic [15:0] Irc,
	output logic [15:0] oEdb,
	output logic [23:1] eab,

	// 68010
	output [3:0] dbinFmt,		// RTE format
	output [3:0] dbinVer,		// RTE format 8 version number
	input [15:0] ssw010,		// for the bus error frame
	input dataSpace,
	output [2:0] sfc, dfc,
	output [31:0] vbr,
	output [31:0] pcOut,		// loop mode
	output dnZero,
	input [15:0] loopD,
	// 68010 bus error frame: internal state
	input snap,
	input [15:0] snapIr, snapIrd, snapExtW,
	input [UADDR_WIDTH-1:0] snapNext,
	input [5:0] snapTop,				// irSyn, irdSyn, irdClr, Tpend
	output [15:0] shIr, shIrd, shFtu, shExtW, shMisc1, shNext, shSsw, shDib,
	output [5:0] shCtl);

localparam REG_USP = 15;
localparam REG_SSP = 16;
localparam REG_DT = 17;
localparam REG_SFC = 18;		// 68010 control registers
localparam REG_DFC = 19;
localparam REG_VBR = 20;
localparam REG_ZERO = 21;		// 68010 CLR as MOVE: always zero

	// 68010 bus error frame internal state words (see below)
	reg [15:0] sh[ 1:24];
	wire [4:0] aluCore;
	wire aluCoreH;

	// Register file
	reg [15:0] regs68L[ 22];
	reg [15:0] regs68H[ 22];

	assign sfc = regs68L[ REG_SFC][2:0];
	assign dfc = regs68L[ REG_DFC][2:0];
	assign vbr = { regs68H[ REG_VBR], regs68L[ REG_VBR]};

// synthesis translate off
	/*
		It is bad practice to initialize simulation registers that the hardware doesn't.
		There is risk that simulation would be different than the real hardware. But in this case is the other way around.
		Some ROM uses something like sub.l An,An at powerup which clears the register
		Simulator power ups the registers with 'X, as they are really undetermined at the real hardware.
		But the simulator doesn't realize (it can't) that the same value is substracting from itself,
		and that the result should be zero even when it's 'X - 'X.
	*/
	
	initial begin
		for( int i = 0; i < 21; i++) begin
			regs68L[i] <= '0;
			regs68H[i] <= '0;
		end
	end
	
	// For simulation display only
	wire [31:0] SSP = { regs68H[REG_SSP], regs68L[REG_SSP]};
	
// synthesis translate on
	

	wire [15:0] aluOut;
	wire [15:0] dbin;
	logic [15:0] dcrOutput = '0;

	reg [15:0] PcL, PcH;
	assign pcOut = { PcH, PcL};

	reg [31:0] auReg, aob;

	reg [15:0] Ath, Atl;

	// Bus execution
	reg [15:0] Dbl, Dbh;
	reg [15:0] Abh, Abl;
	reg [15:0] Abd, Dbd;
	
	assign AblOut = Abl;
	assign atl15 = Atl[15];
	assign au05z = (~| auReg[5:0]);
	
	logic [15:0] dblMux, dbhMux;
	logic [15:0] abhMux, ablMux;
	logic [15:0] abdMux, dbdMux;
	
	logic abdIsByte;
		
	logic Pcl2Dbl, Pch2Dbh;
	logic Pcl2Abl, Pch2Abh;
	
	
	// RX RY muxes	
	// RX and RY actual registers
	logic [4:0] actualRx, actualRy;

	// 68010 long register ALU ops: the high words of the operands are latched with the low
	// word operation, the high word operation runs while the low result is written back.
	reg [15:0] hiD, hiA;
	always_ff @( posedge Clks.clk) begin
		if( enT3 & Nanod.hiLatch) begin
			hiD <= Nanod.hiSel ? regs68H[ actualRx] : regs68H[ actualRy];
			hiA <= Nanod.hiSel ? regs68H[ actualRy] : regs68H[ actualRx];
		end
	end
	assign dnZero = (regs68L[ actualRy] == 16'h0000);		// DBcc counter
	logic [3:0] movemRx = '0;
	logic byteNotSpAlign;			// Byte instruction and no sp word align
	
	// IRD decoded signals must be latched. See comments on decoder
	// But nanostore decoding can't be latched before T4.
	//
	// If we need this earlier we can register IRD decode on T3 and use nano async

	logic [4:0] rxMux, ryMux;
	logic [3:0] rxReg, ryReg;
	logic rxIsSp, ryIsSp;
	logic rxIsAreg, ryIsAreg;
	
	always_comb begin
	
		// Unique IF !!
		if( Nanod.ssp) begin
			rxMux = REG_SSP;
			rxIsSp = 1'b1;
			rxReg = 1'bX;
		end
		else if( Irdecod.rxOvr) begin			// 68010 MOVEC control register
			rxMux = Irdecod.rxOvrMux;
			rxIsSp = 1'b1;
			rxReg = 1'bX;
		end
		else if( Irdecod.rxIsUsp) begin
			rxMux = REG_USP;
			rxIsSp = 1'b1;
			rxReg = 1'bX;
		end
		else if( Irdecod.rxIsDt & !Irdecod.implicitSp) begin
			rxMux = REG_DT;
			rxIsSp = 1'b0;
			rxReg = 1'bX;
		end
		else begin
			if( Irdecod.implicitSp)
				rxReg = 15;
			else if( Irdecod.rxIsMovem)
				rxReg = movemRx;
			else
				rxReg = { Irdecod.rxIsAreg, Irdecod.rx};
				
			if( (& rxReg)) begin
				rxMux = pswS ? REG_SSP : 15;
				rxIsSp = 1'b1;
			end
			else begin
				rxMux = { 1'b0, rxReg};
				rxIsSp = 1'b0;
			end
		end

		// RZ has higher priority!		
		if( Irdecod.ryZero & !Nanod.rz) begin
			ryMux = REG_ZERO;
			ryIsSp = 1'b0;
			ryReg = 'X;
		end
		else if( Irdecod.ryIsDt & !Nanod.rz) begin
			ryMux = REG_DT;
			ryIsSp = 1'b0;
			ryReg = 'X;
		end
		else begin
			ryReg = Nanod.rz ? Irc[15:12] :
					Irdecod.ryOvr ? Irdecod.ryOvrReg : {Irdecod.ryIsAreg, Irdecod.ry};
			ryIsSp = (& ryReg);
			if( ryIsSp & pswS)			// No implicit SP on RY
				ryMux = REG_SSP;
			else
				ryMux = { 1'b0, ryReg};
		end
					
	end	
	
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			byteNotSpAlign <= Irdecod.isByte & ~(Nanod.rxlDbl ? rxIsSp : ryIsSp);
				
			actualRx <= rxMux;
			actualRy <= ryMux;
			
			rxIsAreg <= rxIsSp | rxMux[3];
			// 68010 MOVEC Dn uses the address register routing, MOVES.B An the data register one
			if( Irdecod.ryOvr & !Nanod.rz & !(Irdecod.ryIsDt & !Nanod.rz))
				ryIsAreg <= Irdecod.ryOvrAreg;
			else
				ryIsAreg <= ryIsSp | ryMux[3];
		end
		
		if( enT4)
			abdIsByte <= Nanod.abdIsByte & Irdecod.isByte;
	end
			
	// Set RX/RY low word to which bus segment is connected.
		
	wire ryl2Abl = Nanod.ryl2ab & (ryIsAreg | Nanod.ablAbd);
	wire ryl2Abd = Nanod.ryl2ab & (~ryIsAreg | Nanod.ablAbd);
	wire ryl2Dbl = Nanod.ryl2db & (ryIsAreg | Nanod.dblDbd);
	wire ryl2Dbd = Nanod.ryl2db & (~ryIsAreg | Nanod.dblDbd);

	wire rxl2Abl = Nanod.rxl2ab & (rxIsAreg | Nanod.ablAbd);
	wire rxl2Abd = Nanod.rxl2ab & (~rxIsAreg | Nanod.ablAbd);
	wire rxl2Dbl = Nanod.rxl2db & (rxIsAreg | Nanod.dblDbd);
	wire rxl2Dbd = Nanod.rxl2db & (~rxIsAreg | Nanod.dblDbd);
	
	// Buses. Main mux
	
	logic abhIdle, ablIdle, abdIdle;
	logic dbhIdle, dblIdle, dbdIdle;
	
	always_comb begin
		{abhIdle, ablIdle, abdIdle} = '0;
		{dbhIdle, dblIdle, dbdIdle} = '0;

		unique case( 1'b1)
		ryl2Dbd:				dbdMux = regs68L[ actualRy];
		rxl2Dbd:				dbdMux = regs68L[ actualRx];
		Nanod.alue2Dbd:			dbdMux = alue;
		Nanod.dbin2Dbd:			dbdMux = dbin;
		Nanod.alu2Dbd:			dbdMux = aluOut;
		Nanod.dcr2Dbd:			dbdMux = dcrOutput;
		default: begin			dbdMux = 'X;	dbdIdle = 1'b1;				end
		endcase
	
		unique case( 1'b1)
		rxl2Dbl:				dblMux = regs68L[ actualRx];
		ryl2Dbl:				dblMux = regs68L[ actualRy];
		Nanod.ftu2Dbl:			dblMux = ftu;
		Nanod.au2Db:			dblMux = auReg[15:0];
		Nanod.atl2Dbl:			dblMux = Atl;
		Pcl2Dbl:				dblMux = PcL;
		default: begin			dblMux = 'X;	dblIdle = 1'b1;				end
		endcase
			
		unique case( 1'b1)
		Nanod.rxh2dbh:			dbhMux = regs68H[ actualRx];
		Nanod.ryh2dbh:			dbhMux = regs68H[ actualRy];
		Nanod.au2Db:			dbhMux = auReg[31:16];
		Nanod.ath2Dbh:			dbhMux = Ath;
		Pch2Dbh:				dbhMux = PcH;
		default: begin			dbhMux = 'X;	dbhIdle = 1'b1;				end
		endcase

		unique case( 1'b1)
		ryl2Abd:				abdMux = regs68L[ actualRy];
		rxl2Abd:				abdMux = regs68L[ actualRx];
		Nanod.dbin2Abd:			abdMux = dbin;
		Nanod.alu2Abd:			abdMux = aluOut;
		default: begin			abdMux = 'X;	abdIdle = 1'b1;				end
		endcase

		unique case( 1'b1)
		Pcl2Abl:				ablMux = PcL;
		rxl2Abl:				ablMux = regs68L[ actualRx];
		ryl2Abl:				ablMux = regs68L[ actualRy];
		Nanod.ftu2Abl | Nanod.ftuAbl:	ablMux = ftu;
		Nanod.au2Ab:			ablMux = auReg[15:0];
		Nanod.aob2Ab:			ablMux = aob[15:0];
		Nanod.atl2Abl:			ablMux = Atl;
		default: begin			ablMux = 'X;	ablIdle = 1'b1;				end
		endcase
			
		unique case( 1'b1)		
		Pch2Abh:				abhMux = PcH;
		Nanod.rxh2abh:			abhMux = regs68H[ actualRx];
		Nanod.ryh2abh:			abhMux = regs68H[ actualRy];
		Nanod.au2Ab:			abhMux = auReg[31:16];
		Nanod.aob2Ab:			abhMux = aob[31:16];
		Nanod.ath2Abh:			abhMux = Ath;
		default: begin			abhMux = 'X;	abhIdle = 1'b1;				end
		endcase
			
	end
	
	// Source starts driving the bus on T1. Bus holds data until end of T3. Destination latches at T3.

	// These registers store the first level mux, without bus interconnections.
	// Even when this uses almost to 100 registers, it saves a lot of comb muxing and it is much faster.
	reg [15:0] preAbh, preAbl, preAbd;
	reg [15:0] preDbh, preDbl, preDbd;
	
	always_ff @( posedge Clks.clk) begin

		// Register first level mux at T1		
		if( enT1) begin
			{preAbh, preAbl, preAbd} <= { abhMux, ablMux, abdMux};
			{preDbh, preDbl, preDbd} <= { dbhMux, dblMux, dbdMux};			
		end
		
		// Process bus interconnection at T2. Many combinations only used on DIV
		// We use a simple method. If a specific bus segment is not driven we know that it should get data from a neighbour segment.
		// In some cases this is not true and the segment is really idle without any destination. But then it doesn't matter.
		
		if( enT2) begin
			if( Nanod.extAbh)
				Abh <= { 16{ ablIdle ? preAbd[ 15] : preAbl[ 15] }};
			else if( abhIdle)
				Abh <= ablIdle ? preAbd : preAbl;
			else
				Abh <= preAbh;

			if( ~ablIdle)
				Abl <= preAbl;
			else
				Abl <= Nanod.ablAbh ? preAbh : preAbd;

			Abd <= ~abdIdle ? preAbd : ablIdle ? preAbh : preAbl;

			if( Nanod.extDbh)
				Dbh <= { 16{ dblIdle ? preDbd[ 15] : preDbl[ 15] }};
			else if( dbhIdle)
				Dbh <= dblIdle ? preDbd : preDbl;
			else
				Dbh <= preDbh;

			if( ~dblIdle)
				Dbl <= preDbl;
			else
				Dbl <= Nanod.dblDbh ? preDbh : preDbd;

			Dbd <= ~dbdIdle ? preDbd: dblIdle ? preDbh : preDbl;
			
			/*
			Dbl <= dblMux;			Dbh <= dbhMux;
			Abd <= abdMux;			Dbd <= dbdMux;
			Abh <= abhMux;			Abl <= ablMux; */
		end
	end

	// AOB
	//
	// Originally change on T1. We do on T2, only then the output is enabled anyway.
	//
	// AOB[0] is used for address error. But even when raises on T1, seems not actually used until T2 or possibly T3.
	// It is used on T1 when deasserted at the BSER exception ucode. Probably deassertion timing is not critical. 
	// But in that case (at BSER), AOB is loaded from AU, so we can safely transfer on T1.

	// We need to take directly from first level muxes that are updated and T1
			
	wire au2Aob = Nanod.au2Aob | (Nanod.au2Db & Nanod.db2Aob);
	
	always_ff @( posedge Clks.clk) begin
		// UNIQUE IF !
		
		if( enT1 & au2Aob)		// From AU we do can on T1
			aob <= auReg;
		else if( enT2 & Nanod.resume)
			aob <= { sh[20], sh[21]};				// 68010 rerun of the faulted cycle
		else if( enT2) begin
			if( Nanod.db2Aob)
				aob <= { preDbh, ~dblIdle ? preDbl : preDbd};
			else if( Nanod.ab2Aob)
				aob <= Nanod.aobZero ? 32'd0 : Nanod.aobPc ? { PcH, PcL} : { preAbh, ~ablIdle ? preAbl : preAbd};
		end
	end

	assign eab = aob[23:1];
	assign aob0 = aob[0];
				
	// AU
	logic [31:0] auInpMux;

	// Bcc/DBcc condition, as ccTest of the sequencer
	function automatic logic ccCond( input [3:0] c, input [3:0] f);
		logic cf, vf, zf, nf;
		{ nf, zf, vf, cf} = f;
		unique case( c)
		'h0: ccCond = 1'b1;
		'h1: ccCond = 1'b0;
		'h2: ccCond = ~cf & ~zf;
		'h3: ccCond = cf | zf;
		'h4: ccCond = ~cf;
		'h5: ccCond = cf;
		'h6: ccCond = ~zf;
		'h7: ccCond = zf;
		'h8: ccCond = ~vf;
		'h9: ccCond = vf;
		'ha: ccCond = ~nf;
		'hb: ccCond = nf;
		'hc: ccCond = nf ~^ vf;
		'hd: ccCond = nf ^ vf;
		'he: ccCond = ~zf & (nf ~^ vf);
		'hf: ccCond = zf | (nf ^ vf);
		endcase
	endfunction

	// `ifdef ALW_COMB_BUG
	// Old Modelsim bug. Doesn't update ouput always. Need excplicit sensitivity list !?
	// always @( Nanod.auCntrl) begin
	
	always_comb begin
		// 68010 constants
		if( Nanod.auK2)
			// RTD: the sign extended displacement in the ALU output latch, +2
			auInpMux = (Nanod.auK == 2'b01) ? 16 : (Nanod.auK == 2'b11) ? { {16{ aluOut[15]}}, aluOut} + 32'd2 : -14;
		else if( Nanod.auK != 2'b00)
			auInpMux = (Nanod.auK == 2'b01) ? 6 : (Nanod.auK == 2'b10) ? 22 : 30;
		else if( Nanod.auCc != 2'b00)
			// 68010 Bcc/DBcc: branch address or next word, on the condition
			auInpMux = (ccCond( Ird[11:8], ccr[3:0]) ^ Nanod.auCc[1]) ? { Abh, Abl} : 32'd2;
		else
		unique case( Nanod.auCntrl)
		3'b000:		auInpMux = 0;
		3'b001:		auInpMux = byteNotSpAlign | Nanod.noSpAlign ? 1 : 2;		// +1/+2
		3'b010:		auInpMux = -4;
		3'b011:		auInpMux = { Abh, Abl};
		3'b100:		auInpMux = 2;
		3'b101:		auInpMux = 4;
		3'b110:		auInpMux = -2;
		3'b111:		auInpMux = byteNotSpAlign | Nanod.noSpAlign ? -1 : -2;	// -1/-2
		default:	auInpMux = 'X;
		endcase
	end

	// Simulation problem
	// Sometimes (like in MULM1) DBH is not set. AU is used in these cases just as a 6 bits counter testing if bits 5-0 are zero.
	// But when adding something like 32'hXXXX0000, the simulator (incorrectly) will set *all the 32 bits* of the result as X.

// synthesis translate_off 
	`define SIMULBUGX32 1
	wire [16:0] aulow = Dbl + auInpMux[15:0];
	wire [31:0] auResult = {Dbh + auInpMux[31:16] + aulow[16], aulow[15:0]};
// synthesis translate_on

	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			auReg <= '0;
		else if( enT3 & Nanod.resume)
			auReg <= { sh[1], sh[2]};
		else if( enT3 & Nanod.auClkEn & Nanod.auVbr)
			auReg <= vbr + { 22'b0, Abl[9:0]};			// 68010 exception vector address
		else if( enT3 & Nanod.auClkEn)
			`ifdef SIMULBUGX32
				auReg <= auResult;
			`else
				auReg <= { Dbh, Dbl } + auInpMux;
			`endif
	end
	
	
	// Main A/D registers
	
	always_ff @( posedge Clks.clk) begin
		if( enT3) begin
			if( Nanod.dbl2rxl | Nanod.abl2rxl) begin
				if( ~rxIsAreg) begin
					if( Nanod.dbl2rxl)			regs68L[ actualRx] <= Dbd;
					else if( abdIsByte)			regs68L[ actualRx][7:0] <= Abd[7:0];
					else						regs68L[ actualRx] <= Abd;
				end
				else
					regs68L[ actualRx] <= Nanod.dbl2rxl ? Dbl : Abl;
			end
				
			if( Nanod.dbl2ryl | Nanod.abl2ryl) begin
				if( ~ryIsAreg) begin
					if( Nanod.dbl2ryl)			regs68L[ actualRy] <= Dbd;
					else if( abdIsByte)			regs68L[ actualRy][7:0] <= Abd[7:0];
					else						regs68L[ actualRy] <= Abd;				
				end
				else
					regs68L[ actualRy] <= Nanod.dbl2ryl ? Dbl : Abl;
			end
			
			// High registers are easier. Both A & D on the same buses, and not byte ops.
			if( Nanod.dbh2rxh | Nanod.abh2rxh)
				regs68H[ actualRx] <= Nanod.dbh2rxh ? Dbh : Abh;
			if( Nanod.dbh2ryh | Nanod.abh2ryh)
				regs68H[ actualRy] <= Nanod.dbh2ryh ? Dbh : Abh;

			// 68010 SFC and DFC are 3 bits
			if( (actualRx == REG_SFC) | (actualRx == REG_DFC)) begin
				if( Nanod.dbl2rxl | Nanod.abl2rxl)
					regs68L[ actualRx] <= { 13'b0, Nanod.dbl2rxl ? Dbl[2:0] : Abl[2:0]};
				if( Nanod.dbh2rxh | Nanod.abh2rxh)
					regs68H[ actualRx] <= '0;
			end
		end

		// The zero register is never written
		regs68L[ REG_ZERO] <= '0;
		regs68H[ REG_ZERO] <= '0;

		// 68010 control registers are cleared on reset
		if( Clks.extReset) begin
			for( int i = REG_SFC; i <= REG_VBR; i++) begin
				regs68L[ i] <= '0;
				regs68H[ i] <= '0;
			end
		end
	end
		
	// PC & AT
	reg dbl2Pcl, dbh2Pch, abh2Pch, abl2Pcl;
		
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			{ dbl2Pcl, dbh2Pch, abh2Pch, abl2Pcl } <= '0;
			
			Pcl2Dbl <= 1'b0;
			Pch2Dbh <= 1'b0;
			Pcl2Abl <= 1'b0;
			Pch2Abh <= 1'b0;
		end
		else if( enT4) begin				// Must latch on T4 !
			dbl2Pcl <= Nanod.dbl2reg & Nanod.pcldbl;
			dbh2Pch <= Nanod.dbh2reg & Nanod.pchdbh;
			abh2Pch <= Nanod.abh2reg & Nanod.pchabh;
			abl2Pcl <= Nanod.abl2reg & Nanod.pclabl;
			
			Pcl2Dbl <= Nanod.reg2dbl & Nanod.pcldbl;
			Pch2Dbh <= Nanod.reg2dbh & Nanod.pchdbh;
			Pcl2Abl <= Nanod.reg2abl & Nanod.pclabl;
			Pch2Abh <= Nanod.reg2abh & Nanod.pchabh;
		end
		
		// Unique IF !!!
		if( enT1 & Nanod.au2Pc)
			PcL <= auReg[15:0];
		else if( enT3 & Nanod.resume)
			PcL <= sh[18];
		else if( enT3) begin
			if( dbl2Pcl)
				PcL <= Dbl;
			else if( abl2Pcl)
				PcL <= Abl;
		end
			
		// Unique IF !!!
		if( enT1 & Nanod.au2Pc)
			PcH <= auReg[31:16];
		else if( enT3 & Nanod.resume)
			PcH <= sh[17];
		else if( enT3) begin
			if( dbh2Pch)
				PcH <= Dbh;
			else if( abh2Pch)
				PcH <= Abh;
		end

		// Unique IF !!!
		if( enT3 & Nanod.resume)
			Atl <= sh[4];
		else if( enT3) begin
			if( Nanod.dbl2Atl)
				Atl <= Dbl;
			else if( Nanod.abl2Atl)
				Atl <= Abl;
		end

		// Unique IF !!!
		if( enT3 & Nanod.resume)
			Ath <= sh[3];
		else if( enT3) begin
			if( Nanod.abh2Ath)
				Ath <= Abh;
			else if( Nanod.dbh2Ath)
				Ath <= Dbh;
		end

	end

	// Movem reg mask priority encoder
	
	wire rmIdle;
	logic [3:0] prHbit;
	logic [15:0] prenLatch = '0;
	
	// Invert reg order for predecrement mode
	assign prenEmpty = (~| prenLatch);	
	pren rmPren( .mask( prenLatch), .hbit (prHbit));

	always_ff @( posedge Clks.clk) begin
		// Cheating: PREN always loaded from DBIN
		// Must be on T1 to branch earlier if reg mask is empty!
		if( enT3 & Nanod.resume) begin
			prenLatch <= sh[12];
			movemRx <= sh[14][11:8];
		end
		else if( enT1 & Nanod.abl2Pren)
			prenLatch <= dbin;
		else if( enT3 & Nanod.updPren) begin
			prenLatch [prHbit] <= 1'b0;
			movemRx <= Irdecod.movemPreDecr ? ~prHbit : prHbit;
		end
	end
	
	// DCR
	wire [15:0] dcrCode;

	wire [3:0] dcrInput = abdIsByte ? { 1'b0, Abd[ 2:0]} : Abd[ 3:0];
	onehotEncoder4 dcrDecoder( .bin( dcrInput), .bitMap( dcrCode));
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp)
			dcr4 <= '0;
		else if( enT3 & Nanod.resume) begin
			dcrOutput <= 16'h1 << sh[15][9:6];
			dcr4 <= sh[14][1];
		end
		else if( enT3 & Nanod.abd2Dcr) begin
			dcrOutput <= dcrCode;
			dcr4 <= Abd[4];
		end
	end
	
	// ALUB
	reg [15:0] alub;
	
	always_ff @( posedge Clks.clk) begin
		if( enT3 & Nanod.resume)
			alub <= sh[7];
		else if( enT3) begin
			// UNIQUE IF !!
			if( Nanod.dbd2Alub)
				alub <= Dbd;
			else if( Nanod.abd2Alub)
				alub <= Abd;				// abdIsByte affects this !!??
		end
	end
	
	wire alueClkEn = enT3 & Nanod.dbd2Alue;

	// DOB/DBIN/IRC
	
	logic [15:0] dobInput;
	wire dobIdle = (~| Nanod.dobCtrl);
	
	always_comb begin
		unique case (Nanod.dobCtrl)
		NANO_DOB_ADB:		dobInput = Abd;
		NANO_DOB_DBD:		dobInput = Dbd;
		NANO_DOB_ALU:		dobInput = aluOut;
		default:			dobInput = 'X;
		endcase
	end

	wire [5:0] ioCtl;
	wire [15:0] dib;
	dataIo dataIo( .Clks, .enT1, .enT2, .enT3, .enT4, .Nanod, .Irdecod,
			.iEdb, .dobIdle, .dobInput, .aob0, .loopD, .ssw010, .dataSpace,
			.shWord( sh[ Nanod.shIdx]), .shDob( sh[22]), .shDbin( sh[8]), .shIrc( sh[24]), .shDib( sh[23]),
			.shCtl( sh[15][5:0]), .ctlOut( ioCtl), .dibOut( dib),
			.Irc, .dbin, .oEdb);

	assign dbinFmt = dbin[15:12];
	assign dbinVer = dbin[13:10];

	fx68kAlu alu(
		.clk( Clks.clk), .pwrUp( Clks.pwrUp), .enT1, .enT3, .enT4,
		.ird( Ird), .noCcrForce( Irdecod.isMoves),
		.fmtCcr( Nanod.fmtCcr & (dbin[15:12] != 4'h0) & (dbin[15:12] != 4'h8)), .fmtN( dbin[15]),
		.aluColumn( Nanod.aluColumn), .aluAddrCtrl( Nanod.aluActrl),
		.init( Nanod.aluInit), .finish( Nanod.aluFinish), .aluIsByte( Irdecod.isByte),
		.ftu2Ccr( Nanod.ftu2Ccr),
		.alub, .ftu, .alueClkEn, .alue,
		.aluDataCtrl( Nanod.aluDctrl), .iDataBus( Nanod.hiOp ? hiD : Dbd), .iAddrBus( Nanod.hiOp ? hiA : Abd),
		.resume( enT3 & Nanod.resume), .resLatch( sh[5]), .resAlue( sh[6]), .resCore( sh[14][7:3]), .resH( sh[14][2]),
		.coreOut( aluCore), .coreHOut( aluCoreH),
		.ze, .aluOut, .ccr);

	// 68010 internal state words of the bus error frame (format 8). A snapshot when the
	// microcycle of the faulted bus cycle ended, written to the frame (SP+26 to SP+56),
	// and the frame words read by RTE: 1-16 the internal state, 17-24 PC, SSW, fault
	// address, data output, data input and instruction input buffers.
	//
	//   1,2  AU            8  DBIN       14  IRD syn, CLR, Tpend, MOVEM RX, ALU core flags, DCR4
	//   3,4  AT            9  IR         15  DCR, data capture of the faulted cycle
	//   5    ALU latch     10 IRD        16  IR syn, next microaddress (bits 13-10 = version 0)
	//   6    ALUE          11 FTU
	//   7    ALUB          12 MOVEM mask
	//                      13 MOVEC/MOVES extension word
	logic [3:0] dcrIdx;

	// Simulation: undefined bits (don't care ALU and bus results) are written as 0
	function automatic logic [15:0] defined( input [15:0] v);
		defined = v;
		// synthesis translate_off
		for( int i = 0; i < 16; i++)
			if( (v[i] !== 1'b0) && (v[i] !== 1'b1))
				defined[i] = 1'b0;
		// synthesis translate_on
	endfunction

	always_comb begin
		dcrIdx = '0;
		for( int i = 0; i < 16; i++)
			if( dcrOutput[ i]) dcrIdx = i;
	end
	always_ff @( posedge Clks.clk) begin
		if( snap) begin
			sh[1] <= defined( auReg[31:16]);
			sh[2] <= defined( auReg[15:0]);
			sh[3] <= defined( Ath);
			sh[4] <= defined( Atl);
			sh[5] <= defined( aluOut);
			sh[6] <= defined( alue);
			sh[7] <= defined( alub);
			sh[8] <= defined( dbin);
			sh[9] <= defined( snapIr);
			sh[10] <= defined( snapIrd);
			sh[11] <= defined( ftu);
			sh[12] <= defined( prenLatch);
			sh[13] <= defined( snapExtW);
			sh[14] <= defined( { snapTop[3:1], snapTop[0], movemRx, aluCore, aluCoreH, dcr4, 1'b0});
			sh[15] <= defined( { 6'b0, dcrIdx, ioCtl});
			sh[16] <= defined( { snapTop[5:4], 4'b0000, snapNext});
		end
		else if( enT3 & Nanod.shW)
			sh[ Nanod.shIdx] <= dbin;
	end
	assign shIr = sh[9];
	assign shIrd = sh[10];
	assign shFtu = sh[11];
	assign shExtW = sh[13];
	assign shMisc1 = sh[14];
	assign shNext = sh[16];
	assign shSsw = sh[19];
	assign shDib = sh[23];
	assign shCtl = sh[15][5:0];

endmodule

//
// Data bus I/O
// At a separate module because it is a bit complicated and the timing is special.
// Here we do the low/high byte mux and the special case of MOVEP.
//
// Original implementation is rather complex because both the internal and external buses are bidirectional.
// Input is latched async at the EDB register.
// We capture directly from the external data bus to the internal registers (IRC & DBIN) on PHI2, starting the external S7 phase, at a T4 internal period.

module dataIo( input s_clks Clks,
	input enT1, enT2, enT3, enT4,
	input s_nanod Nanod, input s_irdecod Irdecod,
	input [15:0] iEdb,
	input aob0,

	input dobIdle,
	input [15:0] dobInput,
	input [15:0] loopD,			// 68010 loop mode: first word of the DBcc
	input [15:0] ssw010,		// 68010 bus error frame
	input dataSpace,			// The bus cycle is a data space access
	input [15:0] shWord,		// 68010 bus error frame: internal state word
	input [15:0] shDob, shDbin, shIrc, shDib,	// RTE format 8: restore
	input [5:0] shCtl,
	output [5:0] ctlOut,		// data capture of the bus cycle
	output [15:0] dibOut,
	
	output logic [15:0] Irc,	
	output logic [15:0] dbin,
	output logic [15:0] oEdb
	);

	reg [15:0] dob;
	
	// DBIN/IRC
	
	// Timing is different than any other register. We can latch only on the next T4 (bus phase S7).
	// We need to register all control signals correctly because the next ublock will already be started.
	// Can't latch control on T4 because if there are wait states there might be multiple T4 before we latch.
	
	reg xToDbin, xToIrc;
	reg [15:0] dib;
	reg dbinNoLow, dbinNoHigh;
	reg byteMux, isByte_T4;
	reg sext_T4, dbinSext;

	always_ff @( posedge Clks.clk) begin

		// Byte mux control. Can't latch at T1. AOB might be not ready yet.
		// Must latch IRD decode at T1 (or T4). Then combine and latch only at T3.

		// Can't latch at T3, a new IRD might be loaded already at T1.
		// Ok to latch at T4 if combination latched then at T3
		if( enT4) begin
			isByte_T4 <= Irdecod.isByte;	// Includes MOVEP from mem, we could OR it here
			sext_T4 <= Irdecod.movesSext;
		end

		if( enT3 & Nanod.resume)
			{ byteMux, dbinNoLow, dbinNoHigh, dbinSext} <= shCtl[3:0];
		else if( enT3) begin
			dbinNoHigh <= Nanod.noHighByte;
			dbinNoLow <= Nanod.noLowByte;
			byteMux <= Nanod.busByte & isByte_T4 & ~aob0;
			dbinSext <= Nanod.busByte & sext_T4;		// 68010 MOVES.B to An
		end
		
		if( enT1) begin
			// If on wait states, we continue latching until next T1
			xToDbin <= 1'b0;
			xToIrc <= 1'b0;			
		end
		else if( enT3) begin
			xToDbin <= Nanod.todbin;
			xToIrc <= Nanod.toIrc;
		end

		// Capture on T4 of the next ucycle
		// If there are wait states, we keep capturing every PHI2 until the next T1
		
		if( xToIrc & Clks.enPhi2)
			Irc <= iEdb;
		else if( enT1 & Nanod.ircLoop)
			Irc <= loopD;
		else if( enT3 & Nanod.resume)
			Irc <= shIrc;
		// 68010 data input buffer: data space reads only, not instruction or extension words
		if( xToDbin & dataSpace & Clks.enPhi2)
			dib <= iEdb;
		else if( enT3 & Nanod.resume)
			dib <= shDib;

		if( enT3 & Nanod.resume)
			dbin <= shDbin;
		else if( xToDbin & Clks.enPhi2) begin
			// Original connects both halves of EDB.
			if( ~dbinNoLow)
				dbin[ 7:0] <= byteMux ? iEdb[ 15:8] : iEdb[7:0];
			if( dbinSext)
				dbin[ 15:8] <= { 8{ byteMux ? iEdb[ 15] : iEdb[ 7]}};
			else if( ~dbinNoHigh)
				dbin[ 15:8] <= ~byteMux & dbinNoLow ? iEdb[ 7:0] : iEdb[ 15:8];
		end
	end
	
	// DOB
	logic byteCycle;	
	reg [15:0] dobSave;
	
	always_ff @( posedge Clks.clk) begin
		// Originaly on T1. Transfer to internal EDB also on T1 (stays enabled upto the next T1). But only on T4 (S3) output enables.
		// It is safe to do on T3, then, but control signals if derived from IRD must be registered.
		// Originally control signals are not registered.
		
		// Wait states don't affect DOB operation that is done at the start of the bus cycle. 

		if( enT4)
			byteCycle <= Nanod.busByte & Irdecod.isByte;		// busIsByte but not MOVEP
		
		// Originally byte low/high interconnect is done at EDB, not at DOB.
		if( enT3 & (Nanod.dobX == 3'd7))
			dob <= shDob;						// 68010 rerun of a faulted write
		else if( enT3 & ~dobIdle & (Nanod.dobX != 3'd0)) begin
			// 68010 bus error frame
			case( Nanod.dobX)
			3'd1:		dob <= 16'h0000;
			3'd2:		dob <= dobSave;
			3'd3:		dob <= ssw010;
			3'd4:		dob <= Irc;
			3'd5:		dob <= dib;
			default:	dob <= shWord;
			endcase
		end
		else if( enT3 & ~dobIdle) begin
			dob[7:0] <= Nanod.noLowByte ? dobInput[15:8] : dobInput[ 7:0];
			dob[15:8] <= (byteCycle | Nanod.noHighByte) ? dobInput[ 7:0] : dobInput[15:8];
		end
		
		// Data output buffer of the faulted bus cycle
		if( enT3 & Nanod.updSsw)
			dobSave <= dob;
	end
	assign oEdb = dob;
	assign ctlOut = { xToIrc, xToDbin, byteMux, dbinNoLow, dbinNoHigh, dbinSext};
	assign dibOut = dib;

endmodule


// Provides ucode routine entries (A1/A3) for each opcode
// Also checks for illegal opcode and priv violation

// This is one of the slowest part of the processor.
// But no need to optimize or pipeline because the result for a1-a3 is not needed until at least 4 cycles.
// IR updated at the least one microinstruction earlier.
// Just need to configure the timing analizer correctly.
// isPriv, isIllegal might be needed as soon as two cycles later


module uaddrDecode( 
	input [15:0] opcode,
	input is010,
	input synMovec,						// IR holds the MOVE USP of a MOVEC
	input synMoves,						// IR holds the MOVE of a MOVES
	input clr,							// the opcode is the MOVE D0,<ea> of a CLR
	output [UADDR_WIDTH-1:0] a1, a2, a3,
	output logic isPriv, isIllegal, isLineA, isLineF,
	output [15:0] lineBmap);
	
	wire [3:0] line = opcode[15:12];
	logic [3:0] eaCol, movEa;
	wire [UADDR_WIDTH-1:0] plaA1;
	wire plaIll;

	onehotEncoder4 irLineDecod( line, lineBmap);
	
	assign isLineA = lineBmap[ 'hA];
	assign isLineF = lineBmap[ 'hF];
	
	// 68010 instructions
	wire isMoveCcr = is010 & (opcode[15:6] == 10'h10B);
	wire isRte = is010 & (opcode == 16'h4e73);
	wire isRtd = is010 & (opcode == 16'h4e74);
	wire isMovec = is010 & (opcode[15:1] == 15'h273D);
	wire isMoves = is010 & (opcode[15:8] == 8'h0E);
	wire isBkpt = is010 & (opcode[15:3] == 13'h0909);
	// MOVES <ea> is memory alterable
	wire movesOk = (opcode[7:6] != 2'b11) &
				( ((opcode[5:3] != 3'b000) & (opcode[5:3] != 3'b001) & (opcode[5:3] != 3'b111)) |
				  (opcode[5:1] == 5'b11100) );
	
	// MOVE from CCR uses the MOVE from SR microcode
	wire [15:0] plaOpcode = isMoveCcr ? (opcode & 16'hfdff) : opcode;
	
	wire [UADDR_WIDTH-1:0] plaA2, plaA3;
	pla_lined pla_lined( .movEa( movEa), .col( eaCol),
		.opcode( plaOpcode), .lineBmap( lineBmap),
		.palIll( plaIll), .plaA1( plaA1), .plaA2( plaA2), .plaA3( plaA3) );
	
	// MOVE from CCR enters its own copies of strw1 (Dn) and stmw1 (memory)
	wire ccrDn = isMoveCcr & (opcode[5:3] == 3'b000);

	// 68010 timing
	// MOVE USP and MOVEC Rc,Rn: 2 clocks more. MOVEC Rn,Rc is MOVE An,USP without them.
	wire moveUsp = is010 & (opcode[15:4] == 12'h4e6) & ~(synMovec & ~opcode[3]);
	// MOVE.L Dn/An,-(An): 2 clocks more
	wire moveLPd = is010 & (line == 4'h2) & (opcode[8:6] == 3'b100) & (opcode[5:4] == 2'b00) & ~synMoves;
	// CLR.B/W -(An), CLR (d8,An,Xn): 2 clocks more than the MOVE. CLR.L -(An) is moveLPd.
	wire clrPdW = clr & (opcode[8:6] == 3'b100) & (opcode[13:12] != 2'b10);
	wire clrX = clr & (opcode[8:6] == 3'b110);
	// Scc, MOVE from SR/CCR to memory: effective address without the operand read
	wire memEa = (opcode[5:4] != 2'b00);
	wire isScc = (line == 4'h5) & (opcode[7:6] == 2'b11) & (opcode[5:3] != 3'b001);
	wire nfEa = is010 & memEa & (isScc | (opcode[15:6] == 10'h103) | isMoveCcr);
	logic [UADDR_WIDTH-1:0] nfA1;
	always_comb begin
		unique case( opcode[5:3])
		3'b010:		nfA1 = NAI_NMA;
		3'b011:		nfA1 = NAIP_NMA;
		3'b100:		nfA1 = NAID_NMA;
		3'b101:		nfA1 = NAD_NMA;
		3'b110:		nfA1 = NAX_NMA;
		default:	nfA1 = opcode[0] ? NAL_NMA : NAW_NMA;
		endcase
	end
	// TAS: (An), -(An), (d8,An,Xn) 2 clocks more, (An)+ 4 clocks more
	wire isTasM = is010 & (opcode[15:6] == 10'h12b) & memEa & (opcode[5:3] != 3'b111);
	wire tasI1 = isTasM & ((opcode[5:3] == 3'b010) | (opcode[5:3] == 3'b100) | (opcode[5:3] == 3'b110));
	wire tasI2 = isTasM & (opcode[5:3] == 3'b011);
	// MOVES: 2-6 clocks more depending on the mode (and the direction for -(An))
	logic [UADDR_WIDTH-1:0] movesA1;
	always_comb begin
		unique case( opcode[5:3])
		3'b010:		movesA1 = MVSK2_NMA;
		3'b011:		movesA1 = MVSK3_NMA;
		3'b100:		movesA1 = MVSKD_NMA;			// the prologue branches on the direction
		3'b110:		movesA1 = MVSK2_NMA;
		default:	movesA1 = MVSK1_NMA;
		endcase
	end
	// Long register ALU ops are 2 clocks faster, except ADDA/SUBA.L Rn/#,An, AND/OR.L #,Dn
	// and ANDI/ORI/EORI.L #,Dn. Rn sources enter rorl1 with a1, # sources with a2.
	wire isAddaL = ((line == 4'h9) | (line == 4'hD)) & (opcode[8:6] == 3'b111);
	wire addaLReg = is010 & isAddaL & (opcode[5:4] == 2'b00);
	wire slowLImm = is010 & (opcode[5:0] == 6'b111100) &
				(isAddaL | (((line == 4'h8) | (line == 4'hC)) & (opcode[8:6] == 3'b010)));
	wire slowLogI = is010 & (line == 4'h0) & (opcode[8] == 1'b0) & (opcode[7:6] == 2'b10) & (opcode[5:3] == 3'b000) &
				((opcode[11:9] == 3'b000) | (opcode[11:9] == 3'b001) | (opcode[11:9] == 3'b101));

	assign a1 = isRte ? RTE1_NMA : isRtd ? RTD1_NMA : isMovec ? MVC1_NMA : isMoves ? movesA1 :
				nfEa ? nfA1 : clrPdW ? CPDW_NMA : clrX ? (opcode[13:12] == 2'b10 ? CXL_NMA : CXW_NMA) :
				ccrDn ? CCRW1_NMA : isBkpt ? BK1_NMA :
				moveUsp ? (opcode[3] ? USPO_NMA : USPI_NMA) : moveLPd ? MLPD_NMA : addaLReg ? RL1S_NMA : plaA1;

	assign a2 = isMoveCcr ? CCMW1_NMA : slowLImm ? RL1S_NMA : slowLogI ? RA1S_NMA : plaA2;
	assign a3 = isMoveCcr ? CCMW1_NMA : tasI1 ? TASI1_NMA : tasI2 ? TASI2_NMA : plaA3;
	assign isIllegal = (isRtd | isMovec | isBkpt) ? 1'b0 : isMoves ? ~movesOk : plaIll;
	
	// ea decoding   
	assign eaCol = eaDecode( plaOpcode[ 5:0]);
	assign movEa = eaDecode( {plaOpcode[ 8:6], plaOpcode[ 11:9]} );

	// EA decode
	function [3:0] eaDecode;
	input [5:0] eaBits;
	begin
	unique case( eaBits[ 5:3])
	3'b111:
		case( eaBits[ 2:0])
		3'b000:   eaDecode = 7;            // Absolute short
		3'b001:   eaDecode = 8;            // Absolute long
		3'b010:   eaDecode = 9;            // PC displacement
		3'b011:   eaDecode = 10;           // PC offset
		3'b100:   eaDecode = 11;           // Immediate
		default:  eaDecode = 12;           // Invalid
		endcase
         
	default:   eaDecode = eaBits[5:3];      // Register based EAs
	endcase
	end
	endfunction
	
	
	/*
	Privileged instructions:

	ANDI/EORI/ORI SR
	MOVE to SR
	MOVE to/from USP
	RESET
	RTE
	STOP
	*/
	
	always_comb begin
		unique case( lineBmap)
           
		// ori/andi/eori SR, 68010 moves
		'h01:   isPriv = ((opcode & 16'hf5ff) == 16'h007c) | (isMoves & movesOk);
      
		'h10:
			begin
			// No priority !!!
				if( (opcode & 16'hffc0) == 16'h46c0)        // move to sr
					isPriv = 1'b1;
				
				else if( is010 & ((opcode & 16'hffc0) == 16'h40c0) & ~plaIll)	// 68010 move from sr
					isPriv = 1'b1;
				
				else if( isMovec)							// 68010 movec
					isPriv = 1'b1;
				
				else if( (opcode & 16'hfff0) == 16'h4e60)   // move usp
					isPriv = 1'b1;
		
				else if(	opcode == 16'h4e70 ||			// reset
							opcode == 16'h4e73 ||			// rte
							opcode == 16'h4e72)				// stop
					isPriv = 1'b1;
				else
					isPriv = 1'b0;
			end
         
		default:   isPriv = 1'b0;
		endcase
	end

	
endmodule

// bin to one-hot, 4 bits to 16-bit bitmap
module onehotEncoder4( input [3:0] bin, output reg [15:0] bitMap);
	always_comb begin
	case( bin)
		'b0000:   bitMap = 16'h0001;
		'b0001:   bitMap = 16'h0002;
		'b0010:   bitMap = 16'h0004;
		'b0011:   bitMap = 16'h0008;
		'b0100:   bitMap = 16'h0010;
		'b0101:   bitMap = 16'h0020;
		'b0110:   bitMap = 16'h0040;
		'b0111:   bitMap = 16'h0080;
		'b1000:   bitMap = 16'h0100;
		'b1001:   bitMap = 16'h0200;
		'b1010:   bitMap = 16'h0400;
		'b1011:   bitMap = 16'h0800;
		'b1100:   bitMap = 16'h1000;
		'b1101:   bitMap = 16'h2000;
		'b1110:   bitMap = 16'h4000;
		'b1111:   bitMap = 16'h8000;
	endcase
	end
endmodule

// priority encoder
// used by MOVEM regmask
// this might benefit from device specific features
// MOVEM doesn't need speed, will read the result 2 CPU cycles after each update.
module pren( mask, hbit);
   parameter size = 16;
   parameter outbits = 4;

   input [size-1:0] mask;
   output reg [outbits-1:0] hbit;
   // output reg idle;
   
   always @( mask) begin
      integer i;
      hbit = 0;
      // idle = 1;
      for( i = size-1; i >= 0; i = i - 1) begin
          if( mask[ i]) begin
             hbit = i;
             // idle = 0;
         end
      end
   end

endmodule

// Microcode sequencer

module sequencer( input s_clks Clks, input enT3,
	input [UROM_WIDTH-1:0] microLatch,
	input A0Err, BerrA, busAddrErr, Spuria, Avia,
	input Tpend, intPend, isIllegal, isPriv, excRst, isLineA, isLineF,
	input [15:0] psw,
	input prenEmpty, au05z, dcr4, ze, i11,
	input [1:0] alue01,
	input alue15, atl15,				// 68010 MULS source sign, DIVU remainder bit 15
	input [15:0] Ird,
	input [UADDR_WIDTH-1:0] a1, a2, a3,
	input movecOk,						// 68010 MOVEC control register valid
	input [3:0] dbinFmt,				// 68010 RTE frame format
	input dnZero,						// 68010 loop mode: DBcc counter is zero
	input [3:0] dbinVer,				// 68010 RTE format 8 version number
	input loopNoInt,					// 68010 loop mode: no interrupt after the looped instruction
	output A0Sel,
	output logic [3:0] tvn,
	output logic [UADDR_WIDTH-1:0] nma);
	
	logic [UADDR_WIDTH-1:0] uNma;
	logic [UADDR_WIDTH-1:0] grp1Nma;	
	logic [1:0] c0c1;
	reg a0Rst;
	wire inGrp0Exc;
	
	// assign nma = Clks.extReset ? RSTP0_NMA : (A0Err ? BSER1_NMA : uNma);
	// assign nma = A0Err ? (a0Rst ? RSTP0_NMA : BSER1_NMA) : uNma;
	
    // word type I: 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // NMA :        .. .. 09 08 01 00 05 04 03 02 07 06 .. .. .. .. ..
	
	wire [UADDR_WIDTH-1:0] dbNma = { microLatch[ 14:13], microLatch[ 6:5], microLatch[ 10:7], microLatch[ 12:11]};

	// Group 0 exception.
	// Separated block from regular NMA. Otherwise simulation might depend on order of assigments.
	always_comb begin
		if( A0Err) begin
			if( a0Rst)					// Reset
				nma = RSTP0_NMA;
			else if( inGrp0Exc)			// Double fault
				nma = HALT1_NMA;
			else						// Bus or address error
				nma = BSER1_NMA;
		end
		else
			nma = uNma;
	end

	always_comb begin
		// Format II (conditional) or I (direct branch)
		if( microLatch[1])
			uNma = { microLatch[ 14:13], c0c1, microLatch[ 10:7], microLatch[ 12:11]};		
		else
			case( microLatch[ 3:2])
			0:   uNma = dbNma;   // DB
			1:   uNma = A0Sel ? grp1Nma : a1;
			2:   uNma = a2;
			3:   uNma = a3;
			endcase			
	end

	// Format II, conditional, NMA decoding
	wire [1:0] enl = { Ird[6], prenEmpty};		// Updated on T3
	
	wire [1:0] ms0 = { Ird[8], alue01[0]};
	wire [3:0] m01 = { au05z, Ird[8], alue01};
	wire [1:0] nz1 = { psw[ NF], psw[ ZF]};
	wire [1:0] nv  = { psw[ NF], psw[ VF]};
	
	logic ccTest;
	wire [4:0] cbc = microLatch[ 6:2];			// CBC bits
	
	always_comb begin
		unique case( cbc)
		'h0:    c0c1 = {i11, i11};						// W/L offset EA, from IRC

		'h1:    c0c1 = (au05z) ? 2'b01 : 2'b11;			// Updated on T3
		'h11:   c0c1 = (au05z) ? 2'b00 : 2'b11;

		'h02:   c0c1 = { 1'b0, ~psw[ CF]};				// C used in DIV
		'h12:   c0c1 = { 1'b1, ~psw[ CF]};

		'h03:   c0c1 = {psw[ ZF], psw[ ZF]};			// Z used in DIVU
		
		'h04:											// nz1, used in DIVS
			case( nz1)
               'b00:         c0c1 = 2'b10;
               'b10:         c0c1 = 2'b01;
               'b01,'b11:    c0c1 = 2'b11;
            endcase		

		'h05:   c0c1 = {psw[ NF], 1'b1};				// N used in CHK and DIV
		'h15:   c0c1 = {1'b1, psw[ NF]};
		
		// nz2, used in DIVS (same combination as nz1)
		'h06:   c0c1 = { ~nz1[1] & ~nz1[0], 1'b1};
		
		'h07:											// ms0 used in MUL
		case( ms0)
		 'b10, 'b00: c0c1 = 2'b11;
		 'b01: c0c1 = 2'b01;
		 'b11: c0c1 = 2'b10;
		endcase		
		
		'h08:											// m01 used in MUL
		case( m01)
		'b0000,'b0001,'b0100,'b0111:  c0c1 = 2'b11;
		'b0010,'b0011,'b0101:         c0c1 = 2'b01;
		'b0110:                       c0c1 = 2'b10;
		default:                      c0c1 = 2'b00;
		endcase

		// Conditional		
		'h09:   c0c1 = (ccTest) ? 2'b11 : 2'b01;
		'h19:   c0c1 = (ccTest) ? 2'b11 : 2'b10;
		
		// DCR bit 4 (high or low word)
		'h0c:   c0c1 = dcr4 ? 2'b01: 2'b11;
		'h1c:   c0c1 = dcr4 ? 2'b10: 2'b11;		
		
		// DBcc done
		'h0a:   c0c1 = ze ? 2'b11 : 2'b00;
		
		// nv, used in CHK
		'h0b:   c0c1 = (nv == 2'b00) ? 2'b00 : 2'b11;
		
		// V, used in trapv
		'h0d:   c0c1 = { ~psw[ VF], ~psw[VF]};		
		
		// 68010 MOVEC control register: valid or illegal
		'h10:   c0c1 = movecOk ? 2'b11 : 2'b00;
		
		// 68010 RTE frame format: 0, 8 or format error
		'h13:   c0c1 = (dbinFmt == 4'h0) ? 2'b00 : (dbinFmt == 4'h8) ? 2'b01 : 2'b11;
		
		// 68010 loop mode DBcc: condition true, count expired, or loop
		'h14:   c0c1 = ccTest ? 2'b11 : dnZero ? 2'b01 : 2'b00;
		
		// 68010 RTE format 8: version number
		'h16:   c0c1 = (dbinVer == 4'h0) ? 2'b00 : 2'b11;

		// 68010 MULS with a negative source (2 clocks more)
		'h17:   c0c1 = (Ird[8] & alue15) ? 2'b11 : 2'b00;

		// 68010 DIVU: bit 15 of the remainder in AT, like N used in DIV ('h05)
		'h18:   c0c1 = { atl15, 1'b1};
		
		// enl, combination of pren idle and word/long on IRD
		'h0e,'h1e:
			case( enl)
			2'b00:	c0c1 = 'b10;
			2'b10:	c0c1 = 'b11;
			// 'hx1 result 00/01 depending on condition 0e/1e
			2'b01,2'b11:
					c0c1 = { 1'b0, microLatch[ 6]};
			endcase
			
		default: 				c0c1 = 'X;
		endcase
	end
	
	// CCR conditional
	always_comb begin
		unique case( Ird[ 11:8])		
		'h0: ccTest = 1'b1;						// T
		'h1: ccTest = 1'b0;						// F
		'h2: ccTest = ~psw[ CF] & ~psw[ ZF];	// HI
		'h3: ccTest = psw[ CF] | psw[ZF];		// LS
		'h4: ccTest = ~psw[ CF];				// CC (HS)
		'h5: ccTest = psw[ CF];					// CS (LO)
		'h6: ccTest = ~psw[ ZF];				// NE
		'h7: ccTest = psw[ ZF];					// EQ
		'h8: ccTest = ~psw[ VF];				// VC
		'h9: ccTest = psw[ VF];					// VS
		'ha: ccTest = ~psw[ NF];				// PL
		'hb: ccTest = psw[ NF];					// MI
		'hc: ccTest = (psw[ NF] & psw[ VF]) | (~psw[ NF] & ~psw[ VF]);				// GE
		'hd: ccTest = (psw[ NF] & ~psw[ VF]) | (~psw[ NF] & psw[ VF]);				// LT
		'he: ccTest = (psw[ NF] & psw[ VF] & ~psw[ ZF]) |
				 (~psw[ NF] & ~psw[ VF] & ~psw[ ZF]);								// GT
		'hf: ccTest = psw[ ZF] | (psw[ NF] & ~psw[VF]) | (~psw[ NF] & psw[VF]);		// LE
		endcase
	end
	
	// Exception logic
	logic rTrace, rInterrupt;
	logic rIllegal, rPriv, rLineA, rLineF;
	logic rExcRst, rExcAdrErr, rExcBusErr;
	logic rSpurious, rAutovec;
	wire grp1LatchEn, grp0LatchEn;
			
	// Originally control signals latched on T4. Then exception latches updated on T3
	assign grp1LatchEn = microLatch[0] & (microLatch[1] | !microLatch[4]);
	assign grp0LatchEn = microLatch[4] & !microLatch[1];
	
	assign inGrp0Exc = rExcRst | rExcBusErr | rExcAdrErr;
	
	always_ff @( posedge Clks.clk) begin
		if( grp0LatchEn & enT3) begin
			rExcRst <= excRst;
			rExcBusErr <= BerrA;
			rExcAdrErr <= busAddrErr;
			rSpurious <= Spuria;
			rAutovec <= Avia;
		end
		
		// Update group 1 exception latches
		// Inputs from IR decoder updated on T1 as soon as IR loaded
		// Trace pending updated on T3 at the start of the instruction
		// Interrupt pending on T2
		if( grp1LatchEn & enT3) begin
			rTrace <= Tpend;
			rInterrupt <= intPend & ~loopNoInt;
			rIllegal <= isIllegal & ~isLineA & ~isLineF;
			rLineA <= isLineA;
			rLineF <= isLineF;
			rPriv <= isPriv & !psw[ SF];
		end
	end

	// exception priority
	always_comb begin
		grp1Nma = TRAC1_NMA;
		if( rExcRst)
			tvn = '0;							// Might need to change that to signal in exception
		else if( rExcBusErr | rExcAdrErr)
			tvn = { 1'b1, rExcAdrErr};
			
		// Seudo group 0 exceptions. Just for updating TVN
		else if( rSpurious | rAutovec)
			tvn = rSpurious ? TVN_SPURIOUS : TVN_AUTOVEC;
		
		else if( rTrace)
			tvn = 9;
		else if( rInterrupt) begin
			tvn = TVN_INTERRUPT;
			grp1Nma = ITLX1_NMA;
		end
		else begin
			unique case( 1'b1)					// Can't happen more than one of these
			rIllegal:			tvn = 4;
			rPriv:				tvn = 8;
			rLineA:				tvn = 10;
			rLineF:				tvn = 11;
			default:			tvn = 1;		// Signal no group 0/1 exception
			endcase
		end
	end
	
	assign A0Sel = rIllegal | rLineF | rLineA | rPriv | rTrace | rInterrupt;
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			a0Rst <= 1'b1;
		else if( enT3)
			a0Rst <= 1'b0;
	end
	
endmodule


//
// DMA/BUS Arbitration
//

module busArbiter( input s_clks Clks,
		input BRi, BgackI, Halti, bgBlock,
		output busAvail,
		output logic BGn);
		
	enum int unsigned { DRESET = 0, DIDLE, D1, D_BR, D_BA, D_BRA, D3, D2} dmaPhase, next;

	always_comb begin
		case(dmaPhase)
		DRESET:	next = DIDLE;
		DIDLE:	begin
				if( bgBlock)
					next = DIDLE;
				else if( ~BgackI)
					next = D_BA;
				else if( ~BRi)
					next = D1;
				else
					next = DIDLE;
				end

		D_BA:	begin							// Loop while only BGACK asserted, BG negated here
				if( ~BRi & !bgBlock)
					next = D3;
				else if( ~BgackI & !bgBlock)
					next = D_BA;
				else
					next = DIDLE;
				end
				
		D1:		next = D_BR;							// Loop while only BR asserted
		D_BR:	next = ~BRi & BgackI ? D_BR : D_BA;		// No direct path to IDLE !
		
		D3:		next = D_BRA;
		D_BRA:	begin						// Loop while both BR and BGACK asserted
				case( {BgackI, BRi} )
				2'b11:	next = DIDLE;		// Both deasserted
				2'b10:	next = D_BR;		// BR asserted only
				2'b01:	next = D2;			// BGACK asserted only
				2'b00:	next = D_BRA;		// Stay here while both asserted
				endcase
				end
				
		// Might loop here if both deasserted, should normally don't arrive here anyway?
		// D2:		next = (BgackI & BRi) | bgBlock ? D2: D_BA;

		D2:		next = D_BA;
		
		default:	next = DIDLE;			// Should not reach here normally		
		endcase
	end
		
	logic granting;
	always_comb begin
		unique case( next)
		D1, D3, D_BR, D_BRA:	granting = 1'b1;
		default:				granting = 1'b0;
		endcase
	end
	
	reg rGranted;
	assign busAvail = Halti & BRi & BgackI & ~rGranted;
		
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			dmaPhase <= DRESET;
			rGranted <= 1'b0;
		end
		else if( Clks.enPhi2) begin
			dmaPhase <= next;
			// Internal signal changed on PHI2
			rGranted <= granting;
		end

		// External Output changed on PHI1
		if( Clks.extReset)
			BGn <= 1'b1;
		else if( Clks.enPhi1)
			BGn <= ~rGranted;
		
	end
			
endmodule

module busControl( input s_clks Clks, input enT1, input enT4,
		input permStart, permStop, iStop,
		input aob0,
		input isWrite, isByte, isRmc,
		input busAvail,
		output bgBlock,
		output busAddrErr,
		output waitBusCycle,
		output busStarting,			// Asserted during S0
		output logic addrOe,		// Asserted from S1 to the end, whole bus cycle except S0
		output bciWrite,			// Used for SSW on bus/addr error
		output bciByte, bciRmc,		// 68010 SSW
		input virtReq,				// 68010 loop mode: complete this read without a bus cycle
		output virtStart, realStart,	// The bus cycle is virtual / real, valid on PHI1 in S0
		
		input rDtack, BeDebounced, Vpai,
		output ASn, output LDSn, output UDSn, eRWn);

	reg rAS, rLDS, rUDS, rRWn;
	assign ASn = rAS;
	assign LDSn = rLDS;
	assign UDSn = rUDS;
	assign eRWn = rRWn;

	//reg dataOe;
		
	reg bcPend;
	reg isWriteReg, isRmcReg, wendReg;
	reg bciByteReg;
	assign bciWrite = isWriteReg;
	assign bciByte = bciByteReg;
	assign bciRmc = isRmcReg;
	reg addrOeDelay;
	reg isByteT4;

	wire canStart, busEnd;
	wire bcComplete, bcReset;
	
	wire isRcmReset = bcComplete & bcReset & isRmcReg;
	
	assign busAddrErr = aob0 & ~bciByteReg;
	
	// Bus retry not really supported.
	// It's BERR and HALT and not address error, and not read-modify cycle.
	wire busRetry = ~busAddrErr & 1'b0;
	
	enum int unsigned { SRESET = 0, SIDLE, S0, S2, S4, S6, SRMC_RES, SVIRT} busPhase, next;
	
	// 68010 loop mode instruction fetch: no strobes, completes after S0
	wire virt = virtReq & ~isWriteReg;
	assign virtStart = Clks.enPhi1 & (busPhase == S0) & virt;
	assign realStart = Clks.enPhi1 & (busPhase == S0) & ~virt;

	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset)
			busPhase <= SRESET;
		else if( Clks.enPhi1)
			busPhase <= next;
	end
	
	always_comb begin
		case( busPhase)
		SRESET:		next = SIDLE;
		SRMC_RES:	next = SIDLE;			// Single cycle special state when read phase of RMC reset
		S0:			next = virt ? SVIRT : S2;
		SVIRT:		next = canStart ? S0 : SIDLE;
		S2:			next = S4;
		S4:			next = busEnd ? S6 : S4;
		S6:			next = isRcmReset ? SRMC_RES : (canStart ? S0 : SIDLE);
		SIDLE:		next = canStart ? S0 : SIDLE;
		default:	next = SIDLE;
		endcase
	end	
	
	// Idle phase of RMC bus cycle. Might be better to just add a new state
	wire rmcIdle = (busPhase == SIDLE) & ~ASn & isRmcReg;
		
	assign canStart = (busAvail | rmcIdle) & (bcPend | permStart) & !busRetry & !bcReset;
		
	wire busEnding = (next == SIDLE) | (next == S0);
	
	assign busStarting = (busPhase == S0);
		
	// term signal (DTACK, BERR, VPA, adress error)
	assign busEnd = ~rDtack | iStop;
				
	// bcComplete asserted on raising edge of S6 (together with SNC).
	assign bcComplete = (busPhase == S6) | (busPhase == SVIRT);
	
	// A virtual cycle can complete before the uinstruction waiting for it latched permStop.
	// It stays complete until the next bus cycle is requested.
	reg virtDone;
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset | (enT1 & permStart))
			virtDone <= 1'b0;
		else if( Clks.enPhi2 & (busPhase == SVIRT))
			virtDone <= 1'b1;
	end
	
	// Clear bus info latch on completion (regular or aborted) and no bus retry (and not PHI1).
	// bciClear asserted half clock later on PHI2, and bci latches cleared async concurrently
	wire bciClear = bcComplete & ~busRetry;
	
	// Reset on reset or (berr & berrDelay & (not halt or rmc) & not 6800 & in bus cycle) (and not PHI1)
	assign bcReset = Clks.extReset | (addrOeDelay & BeDebounced & Vpai);
		
	// Enable uclock only on S6 (S8 on Bus Error) or not bciPermStop
	assign waitBusCycle = wendReg & !bcComplete & !virtDone;
	
	// Block Bus Grant when starting new bus cycle. But No need if AS already asserted (read phase of RMC)
	// Except that when that RMC phase aborted on bus error, it's asserted one cycle later!
	assign bgBlock = ((busPhase == S0) & ASn) | (busPhase == SRMC_RES);
	
	always_ff @( posedge Clks.clk) begin
		if( Clks.extReset) begin
			addrOe <= 1'b0;
		end
		else if( Clks.enPhi2 & ( busPhase == S0))			// From S1, whole bus cycle except S0
				addrOe <= 1'b1;
		else if( Clks.enPhi1 & (busPhase == SRMC_RES))
			addrOe <= 1'b0;
		else if( Clks.enPhi1 & ~isRmcReg & busEnding)
			addrOe <= 1'b0;
			
		if( Clks.enPhi1)
			addrOeDelay <= addrOe;
		
		if( Clks.extReset) begin
			rAS <= 1'b1;
			rUDS <= 1'b1;
			rLDS <= 1'b1;
			rRWn <= 1'b1;
			//dataOe <= '0;
		end
		else begin
/*
			if( Clks.enPhi2 & isWriteReg & (busPhase == S2))
				dataOe <= 1'b1;
			else if( Clks.enPhi1 & (busEnding | (busPhase == SIDLE)) )
				dataOe <= 1'b0;
*/						
			if( Clks.enPhi1 & busEnding)
				rRWn <= 1'b1;
			else if( Clks.enPhi1 & isWriteReg) begin
				// Unlike LDS/UDS Asserted even in address error
				if( (busPhase == S0) & isWriteReg)
					rRWn <= 1'b0;
			end

			// AS. Actually follows addrOe half cycle later!
			if( Clks.enPhi1 & (busPhase == S0) & ~virt)
				rAS <= 1'b0;
			else if( Clks.enPhi2 & (busPhase == SRMC_RES))		// Bus error on read phase of RMC. Deasserted one cycle later
				rAS <= 1'b1;			
			else if( Clks.enPhi2 & bcComplete & ~SRMC_RES)
				if( ~isRmcReg)									// Keep AS asserted on the IDLE phase of RMC
					rAS <= 1'b1;
			
			if( Clks.enPhi1 & (busPhase == S0)) begin
				if( ~isWriteReg & !busAddrErr & ~virt) begin
					rUDS <= ~(~bciByteReg | ~aob0);
					rLDS <= ~(~bciByteReg | aob0);
				end
			end
			else if( Clks.enPhi1 & isWriteReg & (busPhase == S2) & !busAddrErr) begin
					rUDS <= ~(~bciByteReg | ~aob0);
					rLDS <= ~(~bciByteReg | aob0);
			end		
			else if( Clks.enPhi2 & bcComplete) begin
				rUDS <= 1'b1;
				rLDS <= 1'b1;
			end
			
		end
		
	end
	
	// Bus cycle info latch. Needed because uinstr might change if the bus is busy and we must wait.
	// Note that urom advances even on wait states. It waits *after* updating urom and nanorom latches.
	// Even without wait states, ublocks of type ir (init reading) will not wait for bus completion.
	// Originally latched on (permStart AND T1).
	
	// Bus cycle info latch: isRead, isByte, read-modify-cycle, and permStart (bus cycle pending). Some previously latched on T4?
	// permStop also latched, but unconditionally on T1
	
	// Might make more sense to register this outside this module
	always_ff @( posedge Clks.clk) begin
		if( enT4) begin
			isByteT4 <= isByte;
		end
	end
	
	// Bus Cycle Info Latch
	always_ff @( posedge Clks.clk) begin
		if( Clks.pwrUp) begin
			bcPend <= 1'b0;
			wendReg <= 1'b0;	
			isWriteReg <= 1'b0;
			bciByteReg <= 1'b0;
			isRmcReg <= 1'b0;		
		end
		
		else if( Clks.enPhi2 & (bciClear | bcReset)) begin
			bcPend <= 1'b0;
			wendReg <= 1'b0;
		end
		else begin
			if( enT1 & permStart) begin
				isWriteReg <= isWrite;
				bciByteReg <= isByteT4;
				isRmcReg <= isRmc & ~isWrite;	// We need special case the end of the read phase only.
				bcPend <= 1'b1;
			end
			if( enT1)
				wendReg <= permStop;
		end
	end
			
endmodule

//
// microrom and nanorom instantiation
//
// There is bit of wasting of resources here. An extra registering pipeline happens that is not needed.
// This is just for the purpose of helping inferring block RAM using pure generic code. Inferring RAM is important for performance.
// Might be more efficient to use vendor specific features such as clock enable.
//

module uRom( input clk, input [UADDR_WIDTH:0] microAddr, output logic [UROM_WIDTH-1:0] microOutput);
	reg [UROM_WIDTH-1:0] uRam[ UROM_DEPTH];		
	initial begin
		$readmemb("microrom.mem", uRam);
	end
	
	always_ff @( posedge clk) 
		microOutput <= uRam[ microAddr];
endmodule


module nanoRom( input clk, input [NADDR_WIDTH:0] nanoAddr, output logic [NANO_WIDTH-1:0] nanoOutput);
	reg [NANO_WIDTH-1:0] nRam[ NANO_DEPTH];		
	initial begin
		$readmemb("nanorom.mem", nRam);
	end
	
	always_ff @( posedge clk) 
		nanoOutput <= nRam[ nanoAddr];
endmodule

// Translate uaddr to nanoaddr
module microToNanoAddr(
	input [UADDR_WIDTH-1:0] uAddr,
	input is010,
	output [NADDR_WIDTH-1:0] orgAddr);

	wire [UADDR_WIDTH-1:2] baseAddr = uAddr[UADDR_WIDTH-1:2];
	logic [NADDR_WIDTH-1:2] orgBase;
	assign orgAddr = { orgBase, uAddr[1:0]};

	always @( baseAddr, is010)
	begin
		// nano ROM (136 addresses, plus the 68010 additions)
		case( baseAddr)

'h00: orgBase = 7'h0 ;
'h01: orgBase = 7'h1 ;
'h02: orgBase = 7'h2 ;
'h03: orgBase = 7'h2 ;
'h08: orgBase = 7'h3 ;
'h09: orgBase = 7'h4 ;
'h0A: orgBase = 7'h5 ;
'h0B: orgBase = 7'h5 ;
'h10: orgBase = 7'h6 ;
'h11: orgBase = 7'h7 ;
'h12: orgBase = 7'h8 ;
'h13: orgBase = 7'h8 ;
'h18: orgBase = 7'h9 ;
'h19: orgBase = 7'hA ;
'h1A: orgBase = 7'hB ;
'h1B: orgBase = 7'hB ;
'h20: orgBase = 7'hC ;
'h21: orgBase = 7'hD ;
'h22: orgBase = 7'hE ;
'h23: orgBase = 7'hD ;
'h28: orgBase = 7'hF ;
'h29: orgBase = 7'h10 ;
'h2A: orgBase = 7'h11 ;
'h2B: orgBase = 7'h10 ;
'h30: orgBase = 7'h12 ;
'h31: orgBase = 7'h13 ;
'h32: orgBase = 7'h14 ;
'h33: orgBase = 7'h14 ;
'h38: orgBase = 7'h15 ;
'h39: orgBase = 7'h16 ;
'h3A: orgBase = 7'h17 ;
'h3B: orgBase = 7'h17 ;
'h40: orgBase = 7'h18 ;
'h41: orgBase = 7'h18 ;
'h42: orgBase = 7'h18 ;
'h43: orgBase = 7'h18 ;
'h44: orgBase = 7'h19 ;
'h45: orgBase = 7'h19 ;
'h46: orgBase = 7'h19 ;
'h47: orgBase = 7'h19 ;
'h48: orgBase = 7'h1A ;
'h49: orgBase = 7'h1A ;
'h4A: orgBase = 7'h1A ;
'h4B: orgBase = 7'h1A ;
'h4C: orgBase = 7'h1B ;
'h4D: orgBase = 7'h1B ;
'h4E: orgBase = 7'h1B ;
'h4F: orgBase = 7'h1B ;
'h54: orgBase = 7'h1C ;
'h55: orgBase = 7'h1D ;
'h56: orgBase = 7'h1E ;
'h57: orgBase = 7'h1F ;
'h5C: orgBase = 7'h20 ;
'h5D: orgBase = 7'h21 ;
'h5E: orgBase = 7'h22 ;
'h5F: orgBase = 7'h23 ;
'h70: orgBase = 7'h24 ;
'h71: orgBase = 7'h24 ;
'h72: orgBase = 7'h24 ;
'h73: orgBase = 7'h24 ;
'h74: orgBase = 7'h24 ;
'h75: orgBase = 7'h24 ;
'h76: orgBase = 7'h24 ;
'h77: orgBase = 7'h24 ;
'h78: orgBase = 7'h25 ;
'h79: orgBase = 7'h25 ;
'h7A: orgBase = 7'h25 ;
'h7B: orgBase = 7'h25 ;
'h7C: orgBase = 7'h25 ;
'h7D: orgBase = 7'h25 ;
'h7E: orgBase = 7'h25 ;
'h7F: orgBase = 7'h25 ;
'h84: orgBase = 7'h26 ;
'h85: orgBase = 7'h27 ;
'h86: orgBase = 7'h28 ;
'h87: orgBase = 7'h29 ;
'h8C: orgBase = 7'h2A ;
'h8D: orgBase = 7'h2B ;
'h8E: orgBase = 7'h2C ;
'h8F: orgBase = 7'h2D ;
'h94: orgBase = 7'h2E ;
'h95: orgBase = 7'h2F ;
'h96: orgBase = 7'h30 ;
'h97: orgBase = 7'h31 ;
'h9C: orgBase = 7'h32 ;
'h9D: orgBase = 7'h33 ;
'h9E: orgBase = 7'h34 ;
'h9F: orgBase = 7'h35 ;
'hA4: orgBase = 7'h36 ;
'hA5: orgBase = 7'h36 ;
'hA6: orgBase = 7'h37 ;
'hA7: orgBase = 7'h37 ;
'hAC: orgBase = 7'h38 ;
'hAD: orgBase = 7'h38 ;
'hAE: orgBase = 7'h39 ;
'hAF: orgBase = 7'h39 ;
'hB4: orgBase = 7'h3A ;
'hB5: orgBase = 7'h3A ;
'hB6: orgBase = 7'h3B ;
'hB7: orgBase = 7'h3B ;
'hBC: orgBase = 7'h3C ;
'hBD: orgBase = 7'h3C ;
'hBE: orgBase = 7'h3D ;
'hBF: orgBase = 7'h3D ;
'hC0: orgBase = 7'h3E ;
'hC1: orgBase = 7'h3F ;
'hC2: orgBase = 7'h40 ;
'hC3: orgBase = 7'h41 ;
'hC8: orgBase = 7'h42 ;
'hC9: orgBase = 7'h43 ;
'hCA: orgBase = 7'h44 ;
'hCB: orgBase = 7'h45 ;
'hD0: orgBase = 7'h46 ;
'hD1: orgBase = 7'h47 ;
'hD2: orgBase = 7'h48 ;
'hD3: orgBase = 7'h49 ;
'hD8: orgBase = 7'h4A ;
'hD9: orgBase = 7'h4B ;
'hDA: orgBase = 7'h4C ;
'hDB: orgBase = 7'h4D ;
'hE0: orgBase = 7'h4E ;
'hE1: orgBase = 7'h4E ;
'hE2: orgBase = 7'h4F ;
'hE3: orgBase = 7'h4F ;
'hE8: orgBase = 7'h50 ;
'hE9: orgBase = 7'h50 ;
'hEA: orgBase = 7'h51 ;
'hEB: orgBase = 7'h51 ;
'hF0: orgBase = 7'h52 ;
'hF1: orgBase = 7'h52 ;
'hF2: orgBase = 7'h52 ;
'hF3: orgBase = 7'h52 ;
'hF8: orgBase = 7'h53 ;
'hF9: orgBase = 7'h53 ;
'hFA: orgBase = 7'h53 ;
'hFB: orgBase = 7'h53 ;

// 68010 microcode, generated by ucode010/gen_ucode010.py
// 68010 nanomap begin
'h04: orgBase = 8'h54 ;
'h05: orgBase = 8'h55 ;
'h06: orgBase = 8'h56 ;
'h07: orgBase = 8'h57 ;
'h0C: orgBase = 8'h58 ;
'h0D: orgBase = 8'h59 ;
'h0E: orgBase = 8'h5A ;
'h0F: orgBase = 8'h5B ;
'h14: orgBase = 8'h5C ;
'h15: orgBase = 8'h5D ;
'h16: orgBase = 8'h5E ;
'h17: orgBase = 8'h5F ;
'h1C: orgBase = 8'h60 ;
'h1D: orgBase = 8'h61 ;
'h1E: orgBase = 8'h62 ;
'h1F: orgBase = 8'h63 ;
'h24: orgBase = 8'h64 ;
'h25: orgBase = 8'h65 ;
'h26: orgBase = 8'h66 ;
'h27: orgBase = 8'h67 ;
'h2C: orgBase = 8'h68 ;
'h2D: orgBase = 8'h69 ;
'h2E: orgBase = 8'h6A ;
'h3C: orgBase = 8'h6B ;
'h3D: orgBase = 8'h6C ;
'h3E: orgBase = 8'h6D ;
'h80: orgBase = 8'h6E ;
'h81: orgBase = 8'h6F ;
'h82: orgBase = 8'h70 ;
'h83: orgBase = 8'h71 ;
'h90: orgBase = 8'h72 ;
'h91: orgBase = 8'h73 ;
'h92: orgBase = 8'h74 ;
'hA3: orgBase = 8'h75 ;
'hB0: orgBase = 8'h76 ;
'hB1: orgBase = 8'h77 ;
'hB2: orgBase = 8'h78 ;
'hB3: orgBase = 8'h79 ;
'hFC: orgBase = 8'h7A ;
'hFD: orgBase = 8'h7B ;
'hFE: orgBase = 8'h7C ;
'hFF: orgBase = 8'h7D ;
// 68010 nanomap end

			default:
				orgBase = 'X;
		endcase

		// 68010: 68000 groups with changed nanowords use their own rows in bank 1
		if( is010) begin
			case( baseAddr)
// 68010 remap begin
'h08: orgBase = 8'h7E ;
'h1B: orgBase = 8'h7F ;
'h20: orgBase = 8'h80 ;
'h30: orgBase = 8'h81 ;
'h43: orgBase = 8'h82 ;
'h71: orgBase = 8'h83 ;
'hC2: orgBase = 8'h84 ;
'hC8: orgBase = 8'h85 ;
// 68010 remap end
			default: ;
			endcase
		end
	end

endmodule

//
// For compilation test only
//

`ifdef FX68K_TEST
module fx68kTop( input clk32, 
	input extReset,
	// input pwrUp,

	input DTACKn, input VPAn,
	input BERRn,
	input BRn, BGACKn,
	input IPL0n, input IPL1n, input IPL2n,
	input [15:0] iEdb,
	
	output [15:0] oEdb,
	output eRWn, output ASn, output LDSn, output UDSn,
	output logic E, output VMAn,	
	output FC0, output FC1, output FC2,
	output BGn,
	output oRESETn, output oHALTEDn,
	output [23:1] eab
	);

	// Clock must be at least twice the desired frequency. A 32 MHz clock means a maximum 16 MHz effective frequency.
	// In this example we divide the clock by 4. Resulting on an effective processor running at 8 MHz.
	
	reg [1:0] clkDivisor = '0;
	always @( posedge clk32) begin
		clkDivisor <= clkDivisor + 1'b1;
	end
		
	/*
	These two signals must be a single cycle pulse. They don't need to be registered.
	Same signal can't be asserted twice in a row. Other than that there are no restrictions.
	There can be any number of cycles, or none, even variable non constant cycles, between each pulse.
	*/
	
	wire enPhi1 = (clkDivisor == 2'b11);
	wire enPhi2 = (clkDivisor == 2'b01);
		
		
	fx68k fx68k( .clk( clk32),
		.extReset, .pwrUp( extReset), .enPhi1, .enPhi2,
	
		.DTACKn, .VPAn, .BERRn, .BRn, .BGACKn,
		.IPL0n, .IPL1n, .IPL2n,
		.iEdb,
		
		.oEdb,
		.eRWn, .ASn, .LDSn, .UDSn,
		.E, .VMAn,	
		.FC0, .FC1, .FC2,
		.BGn,
		.oRESETn, .oHALTEDn, .eab);

endmodule
`endif
