; AP040 FPU test: data movement stage (milestone H2)
;   FMOVE in all formats and directions, FMOVEM (registers and control),
;   condition codes, FBcc/FScc/FDBcc, FSAVE/FRESTORE frames, and the
;   unimplemented-instruction trap (vector 11, format $2)
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed
;   Arithmetic opmodes still trap at this stage: test 60+ pins that and
;   moves to hardware checks when the arithmetic engine lands.

FAILREG		equ	$F100
DONEREG		equ	$F102
cnt_fpunimp	equ	$3600
cnt_fpdz	equ	$3602
cnt_fpsnan	equ	$3604
cnt_fpbsun	equ	$3606

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

chkcnt	macro
	move.w	(\1).l,d6
	and.l	#$FFFF,d6
	cmp.w	#\2,d6
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400		; initial ISP
	dc.l	start		; initial PC
	rept	9
	dc.l	unexp		; vectors 2-10
	endr
	dc.l	h_fpunimp	; 11 F-line / FP unimplemented
	rept	36
	dc.l	unexp		; vectors 12-47
	endr
	dc.l	h_fpbsun	; 48 signaling unordered conditional
	dc.l	unexp		; 49 FP inexact
	dc.l	h_fpdz		; 50 enabled FP divide-by-zero
	rept	3
	dc.l	unexp		; vectors 51-53
	endr
	dc.l	h_fpsnan	; 54 enabled signaling NaN
	rept	201
	dc.l	unexp		; vectors 55-255
	endr

	org	$400
start:
	clr.w	(cnt_fpunimp).l
	clr.w	(cnt_fpdz).l
	clr.w	(cnt_fpsnan).l
	clr.w	(cnt_fpbsun).l

;-------------------------------------------------- integer load/store
	fmove.l	#123,fp0
	fmove.l	fp0,d0
	chkl	d0,123,1

	fmove.w	#-5,fp1
	fmove.l	fp1,d1
	chkl	d1,-5,2

	fmove.b	#$80,fp2	; -128
	fmove.l	fp2,d2
	chkl	d2,-128,3

	fmove.w	fp2,d2		; word store merges low word
	and.l	#$FFFF,d2
	chkl	d2,$FF80,4

;-------------------------------------------------- condition codes
	fmove.l	fpsr,d3		; after loading fp2 = -128: N set
	and.l	#$0F000000,d3
	chkl	d3,$08000000,5

	ftst.x	fp0		; 123: no flags
	fmove.l	fpsr,d3
	and.l	#$0F000000,d3
	chkl	d3,0,6

	fneg.x	fp0		; -123
	fmove.l	fp0,d0
	chkl	d0,-123,7
	fmove.l	fpsr,d3
	and.l	#$0F000000,d3
	chkl	d3,$08000000,8

	fabs.x	fp0		; back to 123
	fmove.l	fp0,d0
	chkl	d0,123,9

	fmove.l	#0,fp3
	fmove.l	fpsr,d3		; zero result: Z
	and.l	#$0F000000,d3
	chkl	d3,$04000000,10

;-------------------------------------------------- single format
	fmove.s	fp0,($3200).l	; 123.0 single = $42F60000
	move.l	($3200).l,d0
	chkl	d0,$42F60000,11
	fmove.s	($3200).l,fp4
	fmove.l	fp4,d0
	chkl	d0,123,12
	dc.w	$F23C,$4600	; fmove.s #<-123.0>,fp4 (raw: vasm
	dc.l	$C2F60000	; mis-encodes single float literals)
	fmove.l	fp4,d0
	chkl	d0,-123,13

;-------------------------------------------------- double format
	fmove.d	fp0,($3208).l	; 123.0 double = $405EC00000000000
	move.l	($3208).l,d0
	chkl	d0,$405EC000,14
	move.l	($320C).l,d0
	chkl	d0,0,15
	fmove.d	($3208).l,fp5
	fmove.l	fp5,d0
	chkl	d0,123,16

;-------------------------------------------------- extended format
	fmove.x	fp0,($3210).l	; 123.0 X = $4005 F600...
	move.l	($3210).l,d0
	chkl	d0,$40050000,17
	move.l	($3214).l,d0
	chkl	d0,$F6000000,18
	move.l	($3218).l,d0
	chkl	d0,0,19
	fmove.x	($3210).l,fp6
	fmove.l	fp6,d0
	chkl	d0,123,20

;-------------------------------------------------- register-direct S
	fmove.s	fp0,d4		; single image into Dn
	chkl	d4,$42F60000,21

;-------------------------------------------------- predec/postinc X
	lea	($3230).l,a0
	fmove.x	fp0,-(a0)
	cmp.l	#$3224,a0
	beq.s	fx1
	failt	22
fx1:
	move.l	($3224).l,d0
	chkl	d0,$40050000,23
	fmove.l	#0,fp6
	fmove.x	(a0)+,fp6
	cmp.l	#$3230,a0
	beq.s	fx2
	failt	24
fx2:
	fmove.l	fp6,d0
	chkl	d0,123,25

;-------------------------------------------------- FCMP and FBcc
	fmove.l	#5,fp0
	fmove.l	#3,fp1
	fcmp.x	fp1,fp0		; 5 - 3 > 0
	fmove.l	fpsr,d3
	and.l	#$0F000000,d3
	chkl	d3,0,26
	fbgt	fb1
	failt	27
fb1:
	fcmp.x	fp0,fp1		; 3 - 5 < 0
	fmove.l	fpsr,d3
	and.l	#$0F000000,d3
	chkl	d3,$08000000,28
	fblt.w	fb2
	failt	29
fb2:
	fbgt.w	fb3		; must not branch
	bra.s	fb4
fb3:
	failt	30
fb4:
	fcmp.x	fp0,fp0		; equal: Z
	fmove.l	fpsr,d3
	and.l	#$0F000000,d3
	chkl	d3,$04000000,31
	fbeq	fb5
	failt	32
fb5:
	fnop

; FBcc/FNOP do not update FPIAR on the 68040.  This mirrors the cputest
; FBcc/0001.dat failure seen on hardware (F280 9360 at $42050000).
	fmove.l	#-1,fpiar
	fbf.w	fbpi1
fbpi1:
	fmove.l	fpiar,d0
	chkl	d0,-1,76
	fnop
	fmove.l	fpiar,d0
	chkl	d0,-1,77

;-------------------------------------------------- FScc / FDBcc
	fcmp.x	fp1,fp0		; greater
	moveq	#0,d5
	fsgt	d5
	and.l	#$FF,d5
	chkl	d5,$FF,33
	fslt	d5
	and.l	#$FF,d5
	chkl	d5,0,34

	moveq	#3,d4
fdb1:
	fdbf	d4,fdb1		; false: pure count loop
	chkl	d4,$FFFF,35	; exits at -1 (word)

;-------------------------------------------------- FMOVEM registers
	fmove.l	#111,fp0
	fmove.l	#222,fp1
	fmovem.x	fp0-fp1,($3240).l
	fmove.l	#0,fp0
	fmove.l	#0,fp1
	fmovem.x	($3240).l,fp0-fp1
	fmove.l	fp0,d0
	chkl	d0,111,36
	fmove.l	fp1,d0
	chkl	d0,222,37

;-------------------------------------------------- control registers
	fmove.l	#$10,fpcr	; round to zero
	fmove.l	fpcr,d0
	chkl	d0,$10,38
	fmove.l	#$04000000,fpsr
	fmove.l	#-1,fpiar
	move.l	#-1,($3260).l
	move.l	#-1,($3264).l
	clr.l	($3268).l
	fmovem.l	fpcr/fpsr/fpiar,($3260).l
	move.l	($3260).l,d0
	chkl	d0,$10,39
	move.l	($3264).l,d0
	chkl	d0,$04000000,58
	move.l	($3268).l,d0
	chkl	d0,-1,78
	fmove.l	#0,fpcr
	fmove.l	#0,fpsr

; Dynamic FMOVEM masks must adjust (An)+ by the selected register count,
; not by the extension word's register-number field.
	fmove.l	#333,fp7
	move.l	#$80,d0
	lea	($3300).l,a0
	fmovem.x	d0,-(a0)
	cmp.l	#$32F4,a0
	beq.s	fmvdyn1
	failt	59
fmvdyn1:
	move.l	($32F4).l,d1
	chkl	d1,$40070000,60

;-------------------------------------------------- FSAVE / FRESTORE
	lea	($3290).l,a1
	fsave	-(a1)		; FPU used: 4-byte IDLE frame
	cmp.l	#$328C,a1
	beq.s	fs1
	failt	40
fs1:
	move.l	($328C).l,d0
	chkl	d0,$41000000,41
	frestore	(a1)+	; restore the idle state
	clr.l	-(a1)
	frestore	(a1)+	; NULL frame: reset
	lea	($3298).l,a2
	fsave	-(a2)		; back to NULL
	move.l	($3294).l,d0
	chkl	d0,0,42
	frestore	(a2)+

;-------------------------------- unimplemented instructions (vector 11)
	fmove.l	#7,fp0		; FPU in use again
	move.l	#$202C,(exp_fmt).l
	fsin.x	fp0		; transcendental: FPSP trap on a real 040
	chkcnt	cnt_fpunimp,1,43
	fmovecr	#0,fp1		; constant ROM: also not hardware
	chkcnt	cnt_fpunimp,2,44

;-------------------------------------------------- arithmetic (stage H3)
	fmove.l	#123,fp0
	fmove.l	#456,fp1
	fmul.x	fp0,fp1		; 56088
	fmove.l	fp1,d0
	chkl	d0,56088,45
	fdiv.x	fp0,fp1		; 456
	fmove.l	fp1,d0
	chkl	d0,456,46
	fadd.x	fp0,fp1		; 579
	fmove.l	fp1,d0
	chkl	d0,579,47
	fsub.x	fp0,fp1		; 456
	fmove.l	fp1,d0
	chkl	d0,456,48

	fmove.l	#144,fp2
	fsqrt.x	fp2
	fmove.l	fp2,d0
	chkl	d0,12,49

	fmove.l	#1,fp3		; 1/3 in extended, round to nearest
	fmove.l	#3,fp4
	fdiv.x	fp4,fp3
	fmove.x	fp3,($32A0).l
	move.l	($32A0).l,d0
	chkl	d0,$3FFD0000,50
	move.l	($32A4).l,d0
	chkl	d0,$AAAAAAAA,51
	move.l	($32A8).l,d0
	chkl	d0,$AAAAAAAB,52

	fmove.l	#2,fp5		; sqrt(2) exact extended rounding
	fsqrt.x	fp5
	fmove.x	fp5,($32B0).l
	move.l	($32B4).l,d0
	chkl	d0,$B504F333,53
	move.l	($32B8).l,d0
	chkl	d0,$F9DE6484,54

	fmove.l	#7,fp6		; divide by zero: inf, I cc, DZ flag
	fmove.l	#0,fp7
	fdiv.x	fp7,fp6
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$02000000,55
	fmove.l	fpsr,d0
	and.l	#$00000400,d0
	chkl	d0,$400,56
; Arithmetic infinity must have the explicit integer bit in its
; extended memory encoding.  The FMOVE also starts a new instruction
; and therefore clears current, but not accrued, exception status.
	fmove.x	fp6,($32C0).l
	move.l	($32C0).l,d0
	chkl	d0,$7FFF0000,61
	move.l	($32C4).l,d0
	chkl	d0,$80000000,62
	fmove.l	fpsr,d0
	and.l	#$0000FF00,d0
	chkl	d0,0,63
	fmove.l	fpsr,d0
	and.l	#$00000010,d0
	chkl	d0,$10,64

	fmove.l	#$10,fpcr	; round to zero: 1/3 truncates
	fmove.l	#1,fp3
	fmove.l	#3,fp4
	fdiv.x	fp4,fp3
	fmove.x	fp3,($32A0).l
	move.l	($32A8).l,d0
	chkl	d0,$AAAAAAAA,57
	fmove.l	#0,fpcr

;-------------------------------------------------- boundary data types
; Exact 2^-127 is a representable single subnormal and must not flush.
	move.l	#$3F800000,($32D0).l
	move.l	#$80000000,($32D4).l
	clr.l	($32D8).l
	fmove.x	($32D0).l,fp5
	fmove.s	fp5,($32DC).l
	move.l	($32DC).l,d0
	chkl	d0,$00400000,65

; A denormal extended source is an unimplemented data type on the 68040.
; It must take vector 11 instead of wrapping its exponent into infinity.
	fmove.l	#99,fp0
	clr.l	($32D0).l
	clr.l	($32D4).l
	move.l	#1,($32D8).l
	move.l	#$202C,(exp_fmt).l
	fmove.x	($32D0).l,fp0
	chkcnt	cnt_fpunimp,3,66
	fmove.l	fp0,d0
	chkl	d0,99,67

; Enabled hardware exceptions use their architectural vectors and inhibit
; destination writeback.  The handler returns to the following instruction.
	fmove.l	#$400,fpcr	; enable divide-by-zero
	fmove.l	#7,fp6
	fmove.l	#0,fp7
	fdiv.x	fp7,fp6
	chkcnt	cnt_fpdz,1,68
	fmove.l	fpsr,d0
	and.l	#$00000400,d0
	chkl	d0,$400,70
	fmove.l	fp6,d0
	chkl	d0,7,69
	fmove.l	#0,fpcr

; Signaling NaNs are quieted, set SNAN, and honor the SNAN enable.
	fmove.l	#55,fp0
	move.l	#$7F800001,($32DC).l
	fmove.l	#$4000,fpcr
	fmove.s	($32DC).l,fp0
	chkcnt	cnt_fpsnan,1,71
	fmove.l	fpsr,d0
	and.l	#$00004000,d0
	chkl	d0,$4000,72
	fmove.l	fp0,d0
	chkl	d0,55,73
	fmove.l	#0,fpcr

; Signaling condition predicates on unordered set BSUN and vector when
; enabled.  Predicate SF remains false after the handler returns.
	fmove.l	#$01000000,fpsr	; NAN condition code
	fmove.l	#$8000,fpcr	; enable BSUN
	fbsf.w	fbsun1
fbsun1:
	chkcnt	cnt_fpbsun,1,74
	fmove.l	fpsr,d0
	and.l	#$00008000,d0
	chkl	d0,$8000,75
	fmove.l	#0,fpcr

;----------------------------------------------------------------- all done
	move.w	#$600D,(DONEREG).l
	stop	#$2700

;----------------------------------------------------------------- handlers
h_fpunimp:
	move.w	6(sp),d6
	cmp.w	(exp_fmt+2).l,d6
	bne.s	hfail
	addq.w	#1,(cnt_fpunimp).l
	rte			; format $2 frame resumes after the FP op

h_fpdz:
	move.w	6(sp),d6
	cmp.w	#$00C8,d6	; format $0, vector 50 offset
	bne.s	hfail
	addq.w	#1,(cnt_fpdz).l
	rte

h_fpbsun:
	move.w	6(sp),d6
	cmp.w	#$00C0,d6	; format $0, vector 48 offset
	bne.s	hfail
	addq.w	#1,(cnt_fpbsun).l
	rte

h_fpsnan:
	move.w	6(sp),d6
	cmp.w	#$00D8,d6	; format $0, vector 54 offset
	bne.s	hfail
	addq.w	#1,(cnt_fpsnan).l
	rte

hfail:
	failt	98

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt1:
	bra.s	halt1

unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2

exp_fmt	equ	$3610
