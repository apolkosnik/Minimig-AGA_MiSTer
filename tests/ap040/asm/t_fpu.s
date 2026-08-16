; AP040 FPU test: data movement stage (milestone H2)
;   FMOVE in all formats and directions, FMOVEM (registers and control),
;   condition codes, FBcc/FScc/FDBcc, FSAVE/FRESTORE frames, and the
;   unimplemented-instruction trap (vector 11, format $2)
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed
;   Arithmetic opmodes still trap at this stage: test 60+ pins that and
;   moves to hardware checks when the arithmetic engine lands.

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
IPLDLY		equ	$F148
IPLCAP		equ	$F14A
cnt_int2	equ	$360C
cnt_fpunimp	equ	$3600
cnt_fpdz	equ	$3602
cnt_fpsnan	equ	$3604
cnt_fpbsun	equ	$3606
cnt_fpline	equ	$3608
cnt_fpunsup	equ	$360A
cnt_ill4	equ	$3620
save_unimp	equ	$3624
unimp_frame	equ	$3A00
unsup_fa	equ	$360C
unsup_resume	equ	$3610
unsup_pc	equ	$3614
bsun_resume	equ	$3618
bsun_pc	equ	$361C

failt	macro
	move.w	#\1,d7
	jmp	fail_all	; jmp: reachable from the $8000 battery section
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
	dc.l	unexp		; 2 bus error
	dc.l	unexp		; 3 address error
	dc.l	h_ill4		; 4 illegal (FPU opmodes $78-$7F land here)
	rept	6
	dc.l	unexp		; vectors 5-10
	endr
	dc.l	h_fpunimp	; 11 F-line / FP unimplemented
	rept	14
	dc.l	unexp		; vectors 12-25
	endr
	dc.l	h_int2		; 26 level-2 autovector (F1 IRQ soak)
	rept	5
	dc.l	unexp		; vectors 27-31
	endr
	dc.l	h_trap0		; 32 TRAP #0: harness-replica test return
	rept	15
	dc.l	unexp		; vectors 33-47
	endr
	dc.l	h_fpbsun	; 48 signaling unordered conditional
	dc.l	unexp		; 49 FP inexact
	dc.l	h_fpdz		; 50 enabled FP divide-by-zero
	rept	3
	dc.l	unexp		; vectors 51-53
	endr
	dc.l	h_fpsnan	; 54 enabled signaling NaN
	dc.l	h_fpunsup	; 55 unimplemented data type
	rept	200
	dc.l	unexp		; vectors 56-255
	endr

	org	$400
start:
	clr.w	(cnt_fpunimp).l
	clr.w	(cnt_fpunsup).l
	clr.w	(cnt_fpdz).l
	clr.w	(cnt_fpsnan).l
	clr.w	(cnt_fpbsun).l
	clr.w	(cnt_fpline).l
	clr.w	(cnt_ill4).l
	clr.w	(save_unimp).l

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
	; Restoring IDLE into a NULL FPU must make a subsequent FSAVE emit IDLE.
	; The old RTL accepted the header but left fpu_used clear.
	move.l	#$41000000,($328C).l
	lea	($328C).l,a1
	frestore	(a1)+
	lea	($3298).l,a2
	fsave	-(a2)
	cmp.l	#$3294,a2
	beq.s	fs_idle_pd_ok
	failt	284
fs_idle_pd_ok:
	move.l	(a2),d0
	chkl	d0,$41000000,285
	clr.l	(a2)
	frestore	(a2)		; return to NULL before the vector-11 checks

;-------------------------------- unimplemented instructions (vector 11)
	; cputest FABS.B/0001: an address-register-direct source is not a
	; legal floating-point EA.  The 68040 reports a standard format-$0
	; F-line exception, not vector 4 and not an FPSP format-$2 frame.
	fmove.l	#77,fp1
	dc.w	$F208,$5898	; invalid fabs.b a0,fp1 encoding
	chkcnt	cnt_fpline,1,76
	fmove.l	fp1,d0		; the invalid instruction has no side effects
	chkl	d0,77,77

	; cputest FABS.D/0001: Dn cannot provide a double source.  This is
	; another malformed FPU command and must also use the format-$0 F-line.
	fmove.l	#88,fp1
	dc.w	$F200,$5498	; invalid fabs.d d0,fp1 encoding
	chkcnt	cnt_fpline,2,78
	fmove.l	fp1,d0
	chkl	d0,88,79

	fmove.l	#7,fp0		; FPU in use again
	move.l	#$202C,(exp_fmt).l
	move.w	#1,(save_unimp).l
	dc.w	$F200,$000E	; fsin.x fp0: transcendental, FPSP route
	chkcnt	cnt_fpunimp,1,43
	move.l	(unimp_frame+$00).l,d0
	chkl	d0,$41300000,260	; revision $41, 48-byte payload
	move.l	(unimp_frame+$04).l,d0
	chkl	d0,$00260000,261	; CMDREG3B mapping of command $000E
	move.l	(unimp_frame+$08).l,d0
	chkl	d0,0,262		; reserved
	move.l	(unimp_frame+$0C).l,d0
	chkl	d0,0,263		; normalized STAG, no GRS/WBT bits
	move.l	(unimp_frame+$10).l,d0
	chkl	d0,$000E0000,264	; CMDREG1B
	move.l	(unimp_frame+$14).l,d0
	chkl	d0,0,265		; normalized DTAG
	move.l	(unimp_frame+$18).l,d0
	chkl	d0,$04000000,266	; E1=1, E3=0, T=0
	move.l	(unimp_frame+$1C).l,d0
	chkl	d0,$40010000,267	; FPTEMP destination = +7.0
	move.l	(unimp_frame+$20).l,d0
	chkl	d0,$E0000000,268
	move.l	(unimp_frame+$24).l,d0
	chkl	d0,0,269
	move.l	(unimp_frame+$28).l,d0
	chkl	d0,$40010000,270	; ETEMP source = +7.0
	move.l	(unimp_frame+$2C).l,d0
	chkl	d0,$E0000000,271
	move.l	(unimp_frame+$30).l,d0
	chkl	d0,0,272

	; FRESTORE must consume the complete frame.  Saving the restored pending
	; state through -(An) must subtract all 52 bytes and reproduce the frame.
	lea	(unimp_frame).l,a1
	frestore	(a1)+
	cmp.l	#unimp_frame+$34,a1
	beq.s	unimp_pi_ok
	failt	273
unimp_pi_ok:
	fsave	-(a1)
	cmp.l	#unimp_frame,a1
	beq.s	unimp_pd_ok
	failt	274
unimp_pd_ok:
	move.l	(a1),d0
	chkl	d0,$41300000,275
	move.l	$10(a1),d0
	chkl	d0,$000E0000,276
	move.l	$28(a1),d0
	chkl	d0,$40010000,277

	; Memory-source software operations must capture the converted source,
	; not merely the raw 32-bit input window.  FINT.L #5,fp2 is opclass 2,
	; format long, destination FP2, opmode $01.
	dc.w	$F23C,$4101
	dc.l	5
	chkcnt	cnt_fpunimp,2,278
	move.l	(unimp_frame+$04).l,d0
	chkl	d0,$01010000,279	; CMDREG3B
	move.l	(unimp_frame+$10).l,d0
	chkl	d0,$41010000,280	; CMDREG1B
	move.l	(unimp_frame+$0C).l,d0
	chkl	d0,0,281		; normalized long-integer source
	move.l	(unimp_frame+$28).l,d0
	chkl	d0,$40010000,282	; ETEMP = extended +5.0
	move.l	(unimp_frame+$2C).l,d0
	chkl	d0,$A0000000,283
	fmovecr	#0,fp1		; constant ROM: also not hardware
	chkcnt	cnt_fpunimp,3,44

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
; A CREATED infinity (here from the divide) carries an all-zero mantissa:
; softfloat's floatx80_default_infinity_low is 0 and inf_clear_intbit is a
; 68060 flag, so the 040 never sets the explicit integer bit itself.  The
; FMOVE also starts a new instruction and therefore clears current, but
; not accrued, exception status.
	fmove.x	fp6,($32C0).l
	move.l	($32C0).l,d0
	chkl	d0,$7FFF0000,61
	move.l	($32C4).l,d0
	chkl	d0,0,62
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
; It takes the vector-55 datatype trap so the FPSP can inspect the operand.
	fmove.l	#99,fp0
	clr.l	($32D0).l
	clr.l	($32D4).l
	move.l	#1,($32D8).l
	lea	denx_cont(pc),a0
	move.l	a0,(unsup_resume).l
denx_op:
	fmove.x	($32D0).l,fp0
denx_cont:
	chkcnt	cnt_fpunsup,1,66
	move.l	(unsup_pc).l,d0
	chkl	d0,denx_op,76
	fmove.l	fp0,d0
	chkl	d0,99,67

; Enabled hardware exceptions use their architectural vectors and inhibit
; destination writeback.  The handler returns to the following instruction.
	fmove.l	#$400,fpcr	; enable divide-by-zero
	fmove.l	#7,fp6
	fmove.l	#0,fp7
	fdiv.x	fp7,fp6
	fnop			; synchronize: enabled FPU exceptions are
				; delivered pre-instruction at the next FPU
				; dispatch (68040 FPSP model)
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
	fnop			; synchronize the deferred enabled-SNAN trap
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
	lea	fbsun1(pc),a0
	move.l	a0,(bsun_resume).l
fbsun_op:
	fbsf.w	fbsun1
fbsun1:
	chkcnt	cnt_fpbsun,1,74
	move.l	(bsun_pc).l,d0
	chkl	d0,fbsun_op,77
	fmove.l	fpsr,d0
	and.l	#$00008000,d0
	chkl	d0,$8000,75
	fmove.l	#0,fpcr

;--------------------------- unsupported data types (vector 55, format $3)
; EVERY datatype fault stacks format $3.  Source operands keep the faulting
; PC with the source address in EA (zero for a register or immediate
; source, which has no address); register-to-memory stores are post-
; instruction exceptions with the following PC and the destination EA.
	fmove.l	#1,fp0			; keep the FPU in a known state
	move.l	#$00000000,($3300).l	; denormal extended: exp 0, mantissa set
	move.l	#$00010000,($3304).l
	move.l	#$00000000,($3308).l
	lea	($3300).l,a3
	move.l	#0,(cnt_fpunsup).l
	lea	den_src_cont(pc),a0
	move.l	a0,(unsup_resume).l
den_src_op:
	fmove.x	(a3),fp1		; faults: denormal source
den_src_cont:
	chkcnt	cnt_fpunsup,1,80
	move.l	(unsup_pc).l,d0
	chkl	d0,den_src_op,81	; the stacked PC identifies the FP op
	fmove.p	fp0,($3320).l		; packed decimal store: data type
	chkcnt	cnt_fpunsup,2,83
	move.l	(unsup_fa).l,d0
	chkl	d0,$3320,82		; format-$3 carries destination EA

	move.l	#$40000000,($3310).l	; unnormal: exponent set, msb of
	move.l	#$40000000,($3314).l	; the mantissa clear
	move.l	#$00000000,($3318).l
	lea	($3310).l,a3
	lea	unnorm_cont(pc),a0
	move.l	a0,(unsup_resume).l
unnorm_op:
	fmove.x	(a3),fp1
unnorm_cont:
	chkcnt	cnt_fpunsup,3,84

; IEEE NaNs loaded from S/D memory retain the 68040 extended NaN form:
; the payload is shifted into bits 62:11 and the explicit integer bit (63)
; stays clear.  FABS must only clear the sign, not canonicalize that bit.
	move.l	#$7FFFFFFF,($3330).l
	move.l	#$FFFFFFFF,($3334).l	; quiet double NaN, all payload bits set
	lea	($3330).l,a6
	dc.w	$F216,$5498		; fabs.d (a6),fp1
	fmove.x	fp1,($3340).l
	move.l	($3340).l,d0
	chkl	d0,$7FFF0000,91
	move.l	($3344).l,d0
	chkl	d0,$7FFFFFFF,92
	move.l	($3348).l,d0
	chkl	d0,$FFFFF800,93

;------------------------------------------------- FSGLMUL / FSGLDIV
; both source mantissas are chopped (not rounded) to 24 bits before the
; operation: 1 + 2^-24 + 2^-25 would round UP to 1 + 2^-23 in single
; precision, but chopping leaves exactly 1.0
	move.l	#$3FFF0000,($32E0).l
	move.l	#$800000C0,($32E4).l
	move.l	#$00000000,($32E8).l
	fmove.x	($32E0).l,fp0
	fmove.l	#1,fp1
	fsglmul.x	fp0,fp1
	fmove.x	fp1,($32F0).l
	move.l	($32F4).l,d0
	chkl	d0,$80000000,85		; exactly 1.0: chopped, not rounded
	move.l	($32F8).l,d0
	chkl	d0,0,86
	move.l	($32F0).l,d0
	chkl	d0,$3FFF0000,87
; FSGLDIV, unlike FSGLMUL, does NOT chop its operands: floatx80_sgldiv
; divides the full-width mantissas and only rounds the QUOTIENT to single
; precision.  1 / (1 + 2^-24 + 2^-25) is therefore just below one and
; rounds to 0.FFFFFF x 2^0, not to the chopped-exact 1.0.
	fmove.l	#1,fp1
	fsgldiv.x	fp0,fp1
	fmove.x	fp1,($32F0).l
	move.l	($32F4).l,d0
	chkl	d0,$FFFFFF00,88
	move.l	($32F8).l,d0
	chkl	d0,0,89
	move.l	($32F0).l,d0
	chkl	d0,$3FFE0000,90

;------------------------------- FMOVE honours the FPCR rounding precision
; A plain FMOVE into a register is an arithmetic instruction for rounding
; purposes: it rounds to the precision selected by FPCR bits 7:6, like
; every other result.  (qemu 11 does not do this, so the FP differential
; harness keeps to extended precision; WinUAE's fp_move takes the
; precision parameter and agrees with the behaviour asserted here.)
	move.l	#$3FFF0000,($3340).l	; 1.0 + a tail below single precision
	move.l	#$80000000,($3344).l
	move.l	#$00000FFF,($3348).l

	fmove.l	#$40,fpcr		; single precision, round to nearest
	fmove.x	($3340).l,fp0
	fmove.l	#0,fpcr
	fmove.x	fp0,($3350).l
	move.l	($3354).l,d0
	chkl	d0,$80000000,88		; rounded to 24 bits
	move.l	($3358).l,d0
	chkl	d0,0,89

	fmove.l	#$80,fpcr		; double precision, round to nearest
	fmove.x	($3340).l,fp1
	fmove.l	#0,fpcr
	fmove.x	fp1,($3360).l
	move.l	($3368).l,d0
	chkl	d0,$00001000,90		; rounded up at bit 11, tail cleared

	fmove.l	#$90,fpcr		; double precision, round toward zero
	fmove.x	($3340).l,fp2
	fmove.l	#0,fpcr
	fmove.x	fp2,($3370).l
	move.l	($3378).l,d0
	chkl	d0,$00000800,91		; truncated: keeps bit 11, drops the rest

	fmove.l	#0,fpcr			; extended: the value passes through
	fmove.x	($3340).l,fp3
	fmove.x	fp3,($3380).l
	move.l	($3388).l,d0
	chkl	d0,$00000FFF,92

;------------------------------------------------- gradual underflow
; The extended format uses the RAW exponent convention: a working
; exponent of ZERO still packs as a normal result with exponent field 0
; and the significand UNSHIFTED (the pseudo-denormal encoding, integer
; bit set), raising nothing.  Only below that is the result tiny: the
; significand shifts right by the exponent deficit (-er) with UNFL, and
; INEX2 when discarded bits are nonzero (WinUAE softfloat
; roundAndPackFloatx80: (0001-8000)/2 -> 0000-8000 clean, /4 ->
; 0000-4000 UNFL, 2^-16380 x 2^-13 -> 0000-0020.. shift 10, UNFL only,
; all reproduced by the compiled oracle).  FMOVEM is used to observe
; the register because an arithmetic FMOVE of a subnormal takes the
; unsupported data type trap, exactly as it does on 040 silicon.
	fmove.l	#0,fpcr
	move.l	#$00030000,($3390).l	; 2^-16380
	move.l	#$80000000,($3394).l
	move.l	#$00000000,($3398).l
	move.l	#$3FF20000,($33A0).l	; 2^-13
	move.l	#$80000000,($33A4).l
	move.l	#$00000000,($33A8).l
	fmove.x	($3390).l,fp0
	fmove.x	($33A0).l,fp1
	fmul.x	fp1,fp0			; 2^-16393: subnormal
	fmovem.x	fp0,($33B0).l
	move.l	($33B0).l,d0
	chkl	d0,0,93			; sign 0, exponent field 0
	move.l	($33B4).l,d0
	chkl	d0,$00200000,94		; significand shifted right by 10 (-er)
	move.l	($33B8).l,d0
	chkl	d0,0,95
	fmove.l	fpsr,d0
	and.l	#$00000800,d0
	chkl	d0,$800,96		; UNFL signalled
	fmove.l	fpsr,d0
	and.l	#$00000200,d0
	chkl	d0,0,209		; the shift was exact: no INEX2

; halving the smallest normal gives the largest subnormal
	move.l	#$00010000,($3390).l	; 2^-16382, the smallest normal
	move.l	#$80000000,($3394).l
	move.l	#$00000000,($3398).l
	fmove.x	($3390).l,fp2
	move.l	#$3FFE0000,($33A0).l	; 0.5 (vasm mis-encodes float
	move.l	#$80000000,($33A4).l	; literals, so build it by hand)
	move.l	#$00000000,($33A8).l
	fmove.x	($33A0).l,fp3
	fmul.x	fp3,fp2
	fmovem.x	fp2,($33C0).l
	move.l	($33C0).l,d0
	chkl	d0,0,97
	move.l	($33C4).l,d0
	chkl	d0,$80000000,98		; exponent 0 packs UNSHIFTED (pseudo-denorm)
	fmove.l	fpsr,d0
	and.l	#$00000A00,d0
	chkl	d0,0,208		; working exponent 0 is not tiny: no UNFL

; a TRUE subnormal operand (integer bit clear) is still an unsupported
; data type: vector 55, as on 040
	move.l	#0,(cnt_fpunsup).l
	fmove.x	fp0,($33D0).l
	chkcnt	cnt_fpunsup,1,99

; but the PSEUDO-denormal in fp2 (integer bit SET) is a legal operand:
; the store executes and the encoding survives untouched
	fmove.x	fp2,($33E0).l
	chkcnt	cnt_fpunsup,1,210	; no new fault
	move.l	($33E0).l,d0
	chkl	d0,0,211
	move.l	($33E4).l,d0
	chkl	d0,$80000000,212

;-------------------- denormal memory operands in EVERY source format
; A denormalized operand is an unsupported data type whatever format it
; arrives in: single and double sources take vector 55 exactly like an
; extended one (cputest 68040_basicfpu FABS.D caught this taking the
; unimplemented-INSTRUCTION vector 11 instead).
	fmove.l	#1,fp0
	move.l	#0,(cnt_fpunsup).l

	move.l	#$00400000,($3400).l	; denormalized single
	lea	den_s_cont(pc),a0
	move.l	a0,(unsup_resume).l
	clr.l	(unsup_fa).l
den_s_op:
	fabs.s	($3400).l,fp1
den_s_cont:
	chkcnt	cnt_fpunsup,1,100
	; A memory source faults with a format-$3 frame carrying the SOURCE
	; address, not the bare format-$0 frame the 68040 UM section 9.6.2
	; describes.  cputest FABS.D expects 30,dc plus EA $4201037A.
	move.l	(unsup_fa).l,d0
	chkl	d0,$3400,137

	move.l	#$00001200,($3410).l	; denormalized double
	move.l	#$D400003F,($3414).l
	lea	den_d_cont(pc),a0
	move.l	a0,(unsup_resume).l
den_d_op:
	fabs.d	($3410).l,fp1
den_d_cont:
	chkcnt	cnt_fpunsup,2,101

	move.l	#$00000000,($3420).l	; denormalized extended
	move.l	#$00010000,($3424).l
	move.l	#$00000000,($3428).l
	lea	den_xadd_cont(pc),a0
	move.l	a0,(unsup_resume).l
den_xadd_op:
	fadd.x	($3420).l,fp0
den_xadd_cont:
	chkcnt	cnt_fpunsup,3,102

; a zero in any format is not a data type fault
	move.l	#$00000000,($3430).l
	fadd.s	($3430).l,fp0
	chkcnt	cnt_fpunsup,3,103
	fmove.l	fp0,d0
	chkl	d0,1,104

;------------- FPU effective addresses a data/address register cannot hold
; A double or extended operand does not fit a data register, and an address
; register is never an FP operand.  The 68040 reports both as unimplemented
; FP INSTRUCTIONS (vector 11), not as integer illegal instructions.
	move.l	#0,(cnt_fpline).l
	dc.w	$F200,$5400		; fmove.d d0,fp2: too wide for a data register
	chkcnt	cnt_fpline,1,105
	dc.w	$F209,$4800		; fmove.s a1,fp1: address register source
	chkcnt	cnt_fpline,2,106
	dc.w	$F209,$7480		; fmove.d fp1,a1: address register destination
	chkcnt	cnt_fpline,3,107
	dc.w	$F200,$7400		; fmove.d fp2,d0: too wide for a data register
	chkcnt	cnt_fpline,4,108

;----------------------------- NaN operands keep their sign through FABS/FNEG
; A NaN passes through unchanged: FABS does not clear its sign bit, and the
; N condition code reports that sign even though the value is a NaN.
	move.l	#$FFFFFFFF,d2		; as a single: a negative NaN
	fabs.s	d2,fp1
	fmovem.x	fp1,($33E0).l
	move.l	($33E0).l,d0
	chkl	d0,$FFFF0000,109	; sign still set, exponent all ones
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$09000000,110	; N and NAN both set

	fneg.s	d2,fp2			; FNEG likewise leaves a NaN alone
	fmovem.x	fp2,($33F0).l
	move.l	($33F0).l,d0
	chkl	d0,$FFFF0000,111

;-------------------- the reserved FPCR precision encoding rounds as double
; FPCR bits 7:6 select extended (00), single (01) or double (10); the
; reserved value 11 behaves as double rather than as extended.
	move.l	#$3FFF0000,($3400).l	; 1 + a tail below the double boundary
	move.l	#$80000000,($3404).l
	move.l	#$00000FFF,($3408).l
	fmove.l	#$D0,fpcr		; precision 11, round toward zero
	fmove.x	($3400).l,fp0
	fmove.l	#0,fpcr
	fmove.x	fp0,($3410).l
	move.l	($3418).l,d0
	chkl	d0,$00000800,112	; truncated at the double boundary

;----------------------- FABS and FNEG report precision-rounding inexactness
; Despite the PRM operation tables describing INEX2 as "Cleared", cputest's
; softfloat oracle routes FABS/FNEG through roundAndPackFloatx80.  Therefore
; they set INEX2 and accrued INEX whenever the selected precision discards
; nonzero bits, exactly like FMOVE.  This applies to register and memory X
; sources as well as sources which first require format conversion.
	move.l	#$BFFF0000,($3420).l	; -1.1000... with a tail below double
	move.l	#$8CCCCCCC,($3424).l
	move.l	#$CCCCCCCD,($3428).l

	fmove.l	#0,fpsr
	fmove.l	#$90,fpcr		; double precision, round toward zero
	fabs.x	($3420).l,fp0
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0		; exception and accrued bytes
	chkl	d0,$0208,113		; INEX2 plus the accrued INEX bit
	fmovem.x	fp0,($3430).l
	move.l	($3430).l,d0
	chkl	d0,$3FFF0000,114	; sign cleared, exponent kept
	move.l	($3438).l,d0
	chkl	d0,$CCCCC800,115	; truncated at the double boundary

	fmove.l	#0,fpsr
	fmove.l	#$90,fpcr
	fneg.x	($3420).l,fp1
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,116		; FNEG reports the discarded bits too
	fmovem.x	fp1,($3440).l
	move.l	($3440).l,d0
	chkl	d0,$3FFF0000,117	; negated from a negative source
	move.l	($3448).l,d0
	chkl	d0,$CCCCC800,118	; and rounded the same way

	fmove.l	#0,fpsr
	fmove.l	#$90,fpcr
	fmove.x	($3420).l,fp2		; same rounding, but FMOVE reports it
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,119		; INEX2 plus the accrued INEX bit

;--------------------------- range control at a reduced rounding precision
; The rounding precision narrows the exponent range as well as the
; significand: the PRM's range-control paragraph checks the intermediate
; exponent against "the representable range of the selected rounding
; precision", and softfloat's 68k roundAndPackFloatx80 does the same with
; its expOffset.  A result outside the single-precision range therefore
; overflows even though the extended destination register could hold it.
	move.l	#$40630000,($3450).l	; 2^100
	move.l	#$80000000,($3454).l
	move.l	#$00000000,($3458).l
	fmove.l	#0,fpcr
	fmove.x	($3450).l,fp0
	fmove.x	($3450).l,fp1
	fmove.l	#0,fpsr
	fmove.l	#$50,fpcr		; single precision, round toward zero
	fmul.x	fp1,fp0			; 2^200: past single, inside extended
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$00001040,d0
	chkl	d0,$1040,120		; OVFL and its accrued bit
	fmovem.x	fp0,($3460).l
	move.l	($3460).l,d0
	chkl	d0,$407E0000,121	; largest single, not 2^200
	move.l	($3464).l,d0
	chkl	d0,$FFFFFF00,122	; mantissa saturated at the single boundary

; and a result below the single-precision minimum underflows to that
; precision's minimum exponent, not to the extended denormal encoding
	move.l	#$3F800000,($3470).l	; 2^-127, below single's smallest normal
	move.l	#$80000000,($3474).l
	move.l	#$00000000,($3478).l
	move.l	#$3FFF0000,($3480).l	; 1.0
	move.l	#$80000000,($3484).l
	move.l	#$00000000,($3488).l
	fmove.l	#0,fpcr
	fmove.x	($3470).l,fp2
	fmove.x	($3480).l,fp3
	fmove.l	#0,fpsr
	fmove.l	#$40,fpcr		; single precision, round to nearest
	fmul.x	fp3,fp2			; the product is still 2^-127
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$00000800,d0
	chkl	d0,$800,123		; UNFL, though extended holds the value
	fmovem.x	fp2,($3490).l
	move.l	($3490).l,d0
	chkl	d0,$3F810000,124	; single's minimum exponent is kept
	move.l	($3494).l,d0
	chkl	d0,$40000000,125	; significand denormalized by one bit

; The move class is range-controlled like everything else: softfloat's
; floatx80_move/abs/neg round through roundAndPackFloatx80, whose expOffset
; narrows the exponent range to the selected precision.  (The PRM's FABS
; page claims OVFL is "Cleared", but the cputest reference is generated
; from softfloat, and on real silicon the case traps nonmaskably into the
; FPSP, which computes the range-controlled result as well.)  2^200 at
; single precision, round toward zero, therefore saturates at single's
; largest normal -- and because 2^200's mantissa loses no bits, OVFL is
; reported WITHOUT INEX2 (roundAndPackFloatx80 raises inexact on overflow
; only when discarded mantissa bits are nonzero).
	move.l	#$40C70000,($34A0).l	; 2^200
	move.l	#$80000000,($34A4).l
	move.l	#$00000000,($34A8).l
	fmove.l	#0,fpsr
	fmove.l	#$50,fpcr		; single precision, round toward zero
	fmove.x	($34A0).l,fp4
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$00001040,d0
	chkl	d0,$1040,126		; OVFL and its accrued bit
	fmove.l	fpsr,d0
	and.l	#$00000200,d0
	chkl	d0,0,127		; no INEX2: no mantissa bits discarded
	fmovem.x	fp4,($34B0).l
	move.l	($34B0).l,d0
	chkl	d0,$407E0000,128	; single's largest normal, extended form
	move.l	($34B4).l,d0
	chkl	d0,$FFFFFF00,129

; Register-to-register follows the same rule.  The reserved precision field
; behaves as double, so this case discards eleven bits and reports INEX2.
	move.l	#$BFFF0000,($34D0).l
	move.l	#$8CCCCCCC,($34D4).l
	move.l	#$CCCCCCCD,($34D8).l
	fmovem.x	($34D0).l,fp1		; loaded bit-exact, no rounding
	fmove.l	#0,fpsr
	fmove.l	#$D0,fpcr		; reserved precision, round toward zero
	fabs.x	fp1,fp0
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,130		; INEX2 for the discarded double tail
	fmovem.x	fp0,($34E0).l
	move.l	($34E0).l,d0
	chkl	d0,$3FFF0000,131	; sign cleared
	move.l	($34E4).l,d0
	chkl	d0,$8CCCCCCC,132
	move.l	($34E8).l,d0
	chkl	d0,$CCCCC800,133	; truncated at the double boundary

; A non-extended source is also rounded in the same way.  cputest
; 68040_basicfpu FABS.D runs fabs.d (a0),fp2 with FPCR $40 and expects
; FPSR $00000208.  Source double
; $C1CBAA456E800000 becomes extended 401C-dd522b7400000000; rounding that
; to single drops $7400000000, below the halfway point, so it truncates.
	move.l	#$C1CBAA45,($34F0).l
	move.l	#$6E800000,($34F4).l
	fmove.l	#0,fpsr
	fmove.l	#$40,fpcr		; single precision, round to nearest
	fabs.d	($34F0).l,fp6
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,134		; INEX2 plus the accrued INEX bit
	fmovem.x	fp6,($3500).l
	move.l	($3500).l,d0
	chkl	d0,$401C0000,135	; sign cleared, exponent 16412
	move.l	($3504).l,d0
	chkl	d0,$DD522B00,136	; significand rounded to 24 bits

; The audit battery lives in its own section at $8000: the main code
; section must stay below $3200, where the test data area begins.
	jmp	audit_battery
audit_return:

;----------------------------------------------------------------- all done
	move.w	#$600D,(DONEREG).l
	stop	#$2700

;----------------------------------------------------------------- handlers
h_fpunimp:
	move.w	6(sp),d6
	cmp.w	#$002C,d6	; standard format-$0 F-line frame
	beq.s	h_fpline
	cmp.w	(exp_fmt+2).l,d6
	bne	hfail
	; A real FPSP handler must acknowledge every pending UNIMP state before
	; it can safely use the FPU again.  Save all format-$2 cases; save_unimp
	; merely marks the one whose complete payload is checked above.
	fsave	(unimp_frame).l
	clr.w	(save_unimp).l
	addq.w	#1,(cnt_fpunimp).l
	rte			; format $2 frame resumes after the FP op

h_fpline:
	addq.l	#4,2(sp)	; skip primary and command words
	addq.w	#1,(cnt_fpline).l
	rte

h_fpunsup:
	move.w	6(sp),d6
	cmp.w	#$30DC,d6	; EVERY datatype fault: format $3, vector 55
	bne	hfail		; (register/immediate sources stack EA = 0)
	move.l	8(sp),d6	; effective address field
	move.l	d6,(unsup_fa).l
	; A store stacks the following PC and resumes by itself.  A SOURCE
	; fault stacks the FP instruction's own PC, so the test has to step
	; over it; those tests arm unsup_resume, which is consumed here.
	tst.l	(unsup_resume).l
	beq.s	h_fpunsup_post
	move.l	2(sp),d6
	move.l	d6,(unsup_pc).l
	move.l	(unsup_resume).l,2(sp)
	clr.l	(unsup_resume).l
h_fpunsup_post:
	addq.w	#1,(cnt_fpunsup).l
	rte

h_fpdz:
	move.w	6(sp),d6
	cmp.w	#$00C8,d6	; format $0, vector 50 offset
	bne	hfail
	addq.w	#1,(cnt_fpdz).l
	rte

h_fpbsun:
	move.w	6(sp),d6
	cmp.w	#$00C0,d6	; format $0, vector 48 offset
	bne	hfail
	move.l	2(sp),d6
	move.l	d6,(bsun_pc).l
	move.l	(bsun_resume).l,2(sp)	; avoid retriggering the pre-exception
	addq.w	#1,(cnt_fpbsun).l
	rte

h_fpsnan:
	move.w	6(sp),d6
	cmp.w	#$00D8,d6	; format $0, vector 54 offset
	bne	hfail
	addq.w	#1,(cnt_fpsnan).l
	rte

hfail:
	failt	98

h_ill4:
	cmpi.w	#$0010,6(sp)	; format $0, vector 4 offset
	bne	hfail
	addq.l	#4,2(sp)	; skip primary and command words
	addq.w	#1,(cnt_ill4).l
	rte

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

;---------------------------------------------------------------------------
; WinUAE-oracle audit battery: placed at $8000 so its bulk (the full 16x32
; conditional-predicate sweep) cannot push the main code section into the
; $3200+ data area.
	org	$8000
audit_battery:
;======================= WinUAE-oracle audit battery (2026-08-06) =========

;-------------------------------------- FDIV specials: inf/0 is NOT DZ
; floatx80_div checks the dividend-infinity case before the divisor-zero
; case, so inf/0 returns a clean infinity with no DZ status at all.
	move.l	#$7FFF0000,($3700).l	; +inf, created form (mantissa zero)
	move.l	#$00000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp0	; dividend +inf, loaded bit-exact
	fmove.l	#0,fp1			; divisor zero
	fmove.l	#0,fpsr
	fdiv.x	fp1,fp0
	fmove.l	fpsr,d0
	and.l	#$00000410,d0		; DZ status and accrued DZ
	chkl	d0,0,138
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$02000000,139	; I only
	fmovem.x	fp0,($3710).l
	move.l	($3714).l,d0
	chkl	d0,0,140		; still the all-zero created mantissa

;----------------------------- 0/0: POSITIVE default NaN, OPERR status
	fmove.l	#0,fp2
	fmove.l	#0,fp3
	fmove.l	#0,fpsr
	fdiv.x	fp2,fp3
	fmove.l	fpsr,d0
	and.l	#$0F002080,d0		; ccs + OPERR + accrued IOP
	chkl	d0,$01002080,141	; NAN cc only: the default NaN is positive
	fmovem.x	fp3,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$7FFF0000,142
	move.l	($3714).l,d0
	chkl	d0,$FFFFFFFF,143	; all-ones mantissa

;----------------------- FSQRT of a negative: positive default NaN too
	fmove.l	#-1,fp4
	fmove.l	#0,fpsr
	fsqrt.x	fp4
	fmove.l	fpsr,d0
	and.l	#$0F002000,d0
	chkl	d0,$01002000,144	; NAN cc without N, OPERR
	fmovem.x	fp4,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$7FFF0000,145
	move.l	($3718).l,d0
	chkl	d0,$FFFFFFFF,146

;---------------- pass-through infinity keeps the operand's raw mantissa
; inf_clear_intbit is a 68060 flag: on the 040 FABS of a 6888x-style
; infinity (integer bit set) keeps that bit in the result.
	move.l	#$FFFF0000,($3700).l
	move.l	#$80000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp5
	fabs.x	fp5
	fmovem.x	fp5,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$7FFF0000,147	; sign cleared by FABS
	move.l	($3714).l,d0
	chkl	d0,$80000000,148	; integer bit preserved

;------------------------------------------ FCMP condition code corners
; equal NONZERO finite values compare as +0 regardless of sign
; (floatx80_cmp packs (0,0,0)), so -5 vs -5 gives Z with N clear;
; equal zeros and equal infinities keep the DESTINATION sign in N.
	fmove.l	#-5,fp0
	fmove.l	#-5,fp1
	fcmp.x	fp0,fp1
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$04000000,149	; Z only, N clear
	fmove.l	#0,fp2			; +0
	fmove.l	#0,fp3
	fneg.x	fp3			; -0 destination
	fcmp.x	fp2,fp3			; -0 - (+0)
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$0C000000,150	; N and Z: destination is -0
; a NaN comparison reports the propagated NaN's sign in N (the 040's
; cmp_signed_nan flag); the destination NaN is preferred
	move.l	#$FFFF0000,($3700).l	; negative quiet NaN
	move.l	#$C0000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp4
	fmove.l	#1,fp5
	fcmp.x	fp5,fp4			; dest fp4 is the negative NaN
	fmove.l	fpsr,d0
	and.l	#$0F000000,d0
	chkl	d0,$09000000,151	; N + NAN
; a denormalized DESTINATION is an unsupported data type for FCMP too
	move.l	#$00000000,($3700).l	; extended denormal
	move.l	#$00000000,($3704).l
	move.l	#$00000001,($3708).l
	fmovem.x	($3700).l,fp6
	move.l	#0,(cnt_fpunsup).l
	move.l	#$EEEEEEEE,(unsup_fa).l
	lea	fcmpd_cont(pc),a0
	move.l	a0,(unsup_resume).l
fcmpd_op:
	fcmp.x	fp5,fp6
fcmpd_cont:
	chkcnt	cnt_fpunsup,1,152
	move.l	(unsup_fa).l,d0
	chkl	d0,0,240		; register operands: format $3 with EA = 0

;------------------- FSGLMUL/FSGLDIV keep the EXTENDED exponent range
; roundSigAndPackFloatx80 has no expOffset: 2^100 squared is 2^200 with
; no overflow, the mantissa merely rounds to single precision
	move.l	#$40630000,($3700).l	; 2^100
	move.l	#$80000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp0
	fmovem.x	($3700).l,fp1
	fmove.l	#0,fpsr
	fsglmul.x	fp0,fp1
	fmove.l	fpsr,d0
	and.l	#$00001040,d0
	chkl	d0,0,153		; no OVFL
	fmovem.x	fp1,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$40C70000,154	; exponent 200 survives
	move.l	($3714).l,d0
	chkl	d0,$80000000,155

;------------------------------ the 040 FPCR keeps all sixteen low bits
	fmove.l	#$FFFFFFFF,fpcr
	fmove.l	fpcr,d0
	chkl	d0,$0000FFFF,156	; WinUAE fpcr_mask = 0xffff for the 040
	fmove.l	#0,fpcr

;--------------- FMOVECR: vector 11, FPSR exception byte NOT cleared
; WinUAE faults FMOVECR before fpsr_clear_status runs, so preset status
; survives; FPIAR is updated to the faulting instruction
	fmove.l	#$00004008,fpsr		; SNAN status + accrued INEX
	fmove.l	#-1,fpiar
	move.l	#$202C,(exp_fmt).l
fmovecr_op:
	dc.w	$F200,$5C00		; fmovecr #$00,fp0
	chkcnt	cnt_fpunimp,4,157
	fmove.l	fpsr,d0
	and.l	#$0000FF08,d0
	chkl	d0,$4008,158		; exception byte preserved
	fmove.l	fpiar,d0
	lea	fmovecr_op(pc),a0
	cmp.l	a0,d0
	beq.s	fpiar_ok1
	failt	159
fpiar_ok1:
	fmove.l	#0,fpsr

;---------------- nonexisting opmode: immediate F-line, NO side effects
; opmode $05 does not exist on the 040: vector 11 with the plain format
; $0 frame, FPIAR untouched, FPSR untouched (fault_if_nonexisting_opmode
; runs before both updates)
	fmove.l	#$00004008,fpsr
	fmove.l	#-1,fpiar
	move.w	(cnt_fpline).l,d5	; running count differs by call site
	dc.w	$F200,$0005		; opclass 000 fp0,fp0 opmode $05
	addq.w	#1,d5
	move.w	(cnt_fpline).l,d6
	cmp.w	d5,d6
	beq.s	nex_ok
	failt	160
nex_ok:
	fmove.l	fpiar,d0
	chkl	d0,-1,161		; FPIAR preserved
	fmove.l	fpsr,d0
	and.l	#$0000FF08,d0
	chkl	d0,$4008,162		; FPSR preserved
	fmove.l	#0,fpsr

;------------------- opmodes $78-$7F take vector 4, of all things
	dc.w	$F200,$0078
	chkcnt	cnt_ill4,1,163

;------------------------- FBcc/FScc predicate bit 5 aliases, no trap
	move.w	(cnt_fpunimp).l,d5
	dc.w	$F2A0,$0002		; fbf.w with bit 5 set: never taken
	move.w	(cnt_fpunimp).l,d6
	cmp.w	d5,d6
	beq.s	alias_ok1
	failt	164
alias_ok1:
	move.w	(cnt_fpunimp).l,d5	; the alias must not trap either
	moveq	#0,d1
	dc.w	$F241,$0020		; fsf.b d1 with bit 5 set: aliases FSF
	and.l	#$FF,d1
	chkl	d1,0,165
	move.w	(cnt_fpunimp).l,d6
	cmp.w	d5,d6
	beq.s	alias_ok2
	failt	207
alias_ok2:

;------------------------------- FMOVEM 68040 register-mapping quirks
; a LOAD maps mask bit 7 to FP0 regardless of the mode field
	fmove.l	#123,fp7		; write through fp7, then reload into fp0
	fmovem.x	fp7,($3720).l
	fmove.l	#0,fp0
	lea	($3720).l,a3
	dc.w	$F213,$C080		; fmovem.x (a3),#$80: mode 00 load, bit7
	fmove.l	fp0,d0
	chkl	d0,123,166		; landed in FP0, not FP7
	fmove.l	fp7,d0
	chkl	d0,123,167		; FP7 untouched by the reload
; a STORE to a control EA with the predec-convention mode writes each
; register's three longwords REVERSED: low mantissa, high, exponent
	fmove.l	#123,fp7
	move.l	#0,($3730).l
	move.l	#0,($3734).l
	move.l	#0,($3738).l
	lea	($3730).l,a3
	dc.w	$F213,$E080		; fmovem.x #$80,(a3): mode 00 store, FP7
	move.l	($3730).l,d0
	chkl	d0,0,168		; low mantissa first
	move.l	($3734).l,d0
	chkl	d0,$F6000000,169	; high mantissa
	move.l	($3738).l,d0
	chkl	d0,$40050000,170	; exponent word last
; -(An) store with the POSTINC-convention mode: bit7 maps to FP0, the
; walk descends, and the longwords are reversed as well
	fmove.l	#111,fp0
	fmove.l	#222,fp1
	lea	($3760).l,a3
	dc.w	$F223,$F0C0		; fmovem.x #$C0,-(a3): mode 10 through predec
	cmp.l	#$3748,a3
	beq.s	mvq_ok1
	failt	171
mvq_ok1:
	move.l	($3748).l,d0		; FP1 at the bottom, reversed
	chkl	d0,0,172
	move.l	($374C).l,d0
	chkl	d0,$DE000000,173
	move.l	($3750).l,d0
	chkl	d0,$40060000,174
	move.l	($3754).l,d0		; FP0 above it, reversed
	chkl	d0,0,175
	move.l	($3758).l,d0
	chkl	d0,$DE000000,176
	move.l	($375C).l,d0
	chkl	d0,$40050000,177
; canonical predec store (mode 00): normal word order, FP0 lowest
	lea	($3790).l,a3
	dc.w	$F223,$E003		; fmovem.x fp0/fp1,-(a3): mode 00 predec
	cmp.l	#$3778,a3
	beq.s	mvq_ok2
	failt	178
mvq_ok2:
	move.l	($3778).l,d0		; FP0 at the bottom, normal order
	chkl	d0,$40050000,179
	move.l	($377C).l,d0
	chkl	d0,$DE000000,180
	move.l	($3784).l,d0		; FP1 above: exponent word
	chkl	d0,$40060000,181
; illegal direction/EA combinations F-line out
	move.w	(cnt_fpline).l,d5
	lea	($3720).l,a3
	dc.w	$F21B,$E080		; fmovem.x #$80,(a3)+ : store postinc EA
	addq.w	#1,d5
	move.w	(cnt_fpline).l,d6
	cmp.w	d5,d6
	beq.s	mvq_ok3
	failt	182
mvq_ok3:
	move.w	(cnt_fpline).l,d5
	lea	($3730).l,a3
	dc.w	$F223,$C080		; fmovem.x -(a3),#$80 : load predec EA
	addq.w	#1,d5
	move.w	(cnt_fpline).l,d6
	cmp.w	d5,d6
	beq.s	mvq_ok4
	failt	183
mvq_ok4:

;----------------------------------- control-register move refinements
; an empty register selection means FPIAR
	dc.w	$F23C,$8000		; fmovem.l #imm,<empty> = FPIAR
	dc.l	$12345678
	fmove.l	fpiar,d0
	chkl	d0,$12345678,184
; An transfers are legal for FPIAR only
	movea.l	#$00ABCDEF,a4
	dc.w	$F20C,$8400		; fmove.l a4,fpiar
	fmove.l	fpiar,d0
	chkl	d0,$00ABCDEF,185
	suba.l	a4,a4
	dc.w	$F20C,$A400		; fmove.l fpiar,a4
	cmpa.l	#$00ABCDEF,a4
	beq.s	cr_ok1
	failt	186
cr_ok1:
; an immediate source may load several registers back to back
	dc.w	$F23C,$9800		; fmovem.l #:#,fpcr/fpsr
	dc.l	$00000010
	dc.l	$0F000000
	fmove.l	fpcr,d0
	chkl	d0,$10,187
	fmove.l	fpsr,d0
	chkl	d0,$0F000000,188
	fmove.l	#0,fpcr
	fmove.l	#0,fpsr
; malformed control-register encodings are F-line traps
	move.w	(cnt_fpline).l,d5
	dc.w	$F201,$B800		; fmovem.l fpcr/fpsr,d1: multi to Dn
	addq.w	#1,d5
	move.w	(cnt_fpline).l,d6
	cmp.w	d5,d6
	beq.s	cr_ok2
	failt	189
cr_ok2:
	move.w	(cnt_fpline).l,d5
	dc.w	$F209,$9000		; fmove.l a1,fpcr: only FPIAR may use An
	addq.w	#1,d5
	move.w	(cnt_fpline).l,d6
	cmp.w	d5,d6
	beq.s	cr_ok3
	failt	190
cr_ok3:

;-------------- the full 68040 conditional-predicate table, 16 x 32
; every FPSR condition-code combination against every predicate, checked
; against WinUAE's condition_table_040_060 verbatim.  Predicates >= $10
; also set BSUN+AE_IOP when NAN is set, which is why the FPSR is written
; fresh for every row.
	fmove.l	#$00000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$CCCCCCCC,191
	fmove.l	#$01000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$FF00FF00,192
	fmove.l	#$02000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$CCCCCCCC,193
	fmove.l	#$03000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$FF00FF00,194
	fmove.l	#$04000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$AAAAAAAA,195
	fmove.l	#$05000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$BF2ABF2A,196
	fmove.l	#$06000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$AAAAAAAA,197
	fmove.l	#$07000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$BF2ABF2A,198
	fmove.l	#$08000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$F0F0F0F0,199
	fmove.l	#$09000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$FF00FF00,200
	fmove.l	#$0A000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$F0F0F0F0,201
	fmove.l	#$0B000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$FF00FF00,202
	fmove.l	#$0C000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$AAAAAAAA,203
	fmove.l	#$0D000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$BF2ABF2A,204
	fmove.l	#$0E000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$AAAAAAAA,205
	fmove.l	#$0F000000,fpsr
	moveq	#0,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001F	; fs<1F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001E	; fs<1E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001D	; fs<1D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001C	; fs<1C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001B	; fs<1B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$001A	; fs<1A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0019	; fs<19>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0018	; fs<18>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0017	; fs<17>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0016	; fs<16>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0015	; fs<15>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0014	; fs<14>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0013	; fs<13>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0012	; fs<12>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0011	; fs<11>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0010	; fs<10>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000F	; fs<0F>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000E	; fs<0E>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000D	; fs<0D>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000C	; fs<0C>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000B	; fs<0B>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$000A	; fs<0A>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0009	; fs<09>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0008	; fs<08>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0007	; fs<07>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0006	; fs<06>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0005	; fs<05>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0004	; fs<04>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0003	; fs<03>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0002	; fs<02>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0001	; fs<01>.b d1
	and.l	#1,d1
	or.l	d1,d2
	lsl.l	#1,d2
	moveq	#0,d1
	dc.w	$F241,$0000	; fs<00>.b d1
	and.l	#1,d1
	or.l	d1,d2
	chkl	d2,$BF2ABF2A,206
	fmove.l	#0,fpsr


;=============== pseudo-denormals are LEGAL operands (raw exponent zero)
; cputest 68040_intfpu FDIV/FDDIV/FDADD run with register images whose
; exponent field is zero but integer bit is SET.  floatx80_is_denormal
; requires the integer bit CLEAR, so these are not datatype faults: the
; hardware computes with the raw exponent field (verified against the
; compiled WinUAE softfloat on the exact cputest operands).
	move.l	#0,(cnt_fpunsup).l
; FDIV.B by -1: er stays 0, only the sign flips, the encoding survives
	move.l	#$00000000,($3700).l
	move.l	#$8000E373,($3704).l
	move.l	#$0F2F9F73,($3708).l
	fmovem.x	($3700).l,fp5
	moveq	#-1,d3
	fmove.l	#0,fpsr
	fdiv.b	d3,fp5
	chkcnt	cnt_fpunsup,0,213	; no datatype fault
	fmove.l	fpsr,d0
	chkl	d0,$08000000,214	; N only, no exception or accrued bits
	fmovem.x	fp5,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$80000000,215	; sign set, exponent field still 0
	move.l	($3714).l,d0
	chkl	d0,$8000E373,216
	move.l	($3718).l,d0
	chkl	d0,$0F2F9F73,217

; FDDIV.W by zero: divide-by-zero creates a clean +infinity even from a
; pseudo-denormal dividend
	move.l	#$00000000,($3700).l
	move.l	#$8000AAC2,($3704).l
	move.l	#$2BADD273,($3708).l
	fmovem.x	($3700).l,fp5
	clr.l	d3
	fmove.l	#0,fpsr
	dc.w	$F203,$52E4		; fddiv.w d3,fp5
	chkcnt	cnt_fpunsup,0,218
	fmove.l	fpsr,d0
	chkl	d0,$02000410,219	; I code, DZ status, accrued DZ
	fmovem.x	fp5,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$7FFF0000,220
	move.l	($3714).l,d0
	chkl	d0,0,221		; created infinity: mantissa zero

; FDIV.X: -0 divided by a pseudo-denormal is an ordinary signed zero
	move.l	#$00000000,($3700).l
	move.l	#$C9DA2488,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp3
	fmove.l	#0,fp2
	fneg.x	fp2			; -0
	fmove.l	#0,fpsr
	fdiv.x	fp3,fp2
	chkcnt	cnt_fpunsup,0,222
	fmove.l	fpsr,d0
	chkl	d0,$0C000000,223	; N and Z, no exceptions
	fmovem.x	fp2,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$80000000,224
	move.l	($3714).l,d0
	chkl	d0,0,225

; FDADD.X: a pseudo-denormal addend is 16000+ binades below the sum, so
; it only contributes sticky bits to the double-precision rounding
	move.l	#$401B0000,($3700).l
	move.l	#$C65516B1,($3704).l
	move.l	#$0A655AED,($3708).l
	fmovem.x	($3700).l,fp5
	move.l	#$00000000,($3720).l
	move.l	#$BC49BC80,($3724).l
	move.l	#$00000000,($3728).l
	lea	($3720).l,a0
	fmove.l	#0,fpsr
	dc.w	$F210,$4AE6		; fdadd.x (a0),fp5
	chkcnt	cnt_fpunsup,0,226
	fmove.l	fpsr,d0
	chkl	d0,$00000208,227	; INEX2 and accrued INEX
	fmovem.x	fp5,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$401B0000,228
	move.l	($3714).l,d0
	chkl	d0,$C65516B1,229
	move.l	($3718).l,d0
	chkl	d0,$0A655800,230

; an unnormal ZERO (nonzero exponent, mantissa zero) behaves as zero
; (WinUAE normalizes it at operand load; raw softfloat would call the
; encoding invalid, so the normalization must happen before arithmetic)
	move.l	#$40000000,($3700).l
	move.l	#$00000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp4
	fmove.l	#1,fp5
	fmove.l	#0,fpsr
	fadd.x	fp4,fp5
	chkcnt	cnt_fpunsup,0,231
	fmovem.x	fp5,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$3FFF0000,232	; 1.0 + (unnormal)0 = 1.0
	move.l	($3714).l,d0
	chkl	d0,$80000000,233

;================== vector-55 frames for operands with no address
; A register source stacks format $3 with the EA field ZERO (cputest
; FDMOVE.S Dn frame: 00,00,xx,xx,00,00,30,dc,00,00,00,00)
	fmove.l	#1,fp5
	move.l	#0,(cnt_fpunsup).l
	move.l	#$EEEEEEEE,(unsup_fa).l
	move.l	#$00000000,($3700).l	; true denormal (integer bit clear)
	move.l	#$00000000,($3704).l
	move.l	#$00000001,($3708).l
	fmovem.x	($3700).l,fp6
	lea	fregea_cont(pc),a0
	move.l	a0,(unsup_resume).l
fregea_op:
	fadd.x	fp6,fp5			; register source: no address
fregea_cont:
	chkcnt	cnt_fpunsup,1,234
	move.l	(unsup_fa).l,d0
	chkl	d0,0,235		; EA field is zero
	move.l	(unsup_pc).l,d0
	chkl	d0,fregea_op,236	; PC still names the FP instruction

; an immediate source also has no address: EA = 0 (cputest FABS.P #imm)
	move.l	#$EEEEEEEE,(unsup_fa).l
	lea	fimm_cont(pc),a0
	move.l	a0,(unsup_resume).l
fimm_op:
	dc.w	$F23C,$4880		; fmove.x #<denormal>,fp1
	dc.l	$00000000,$00000000,$00000001
fimm_cont:
	chkcnt	cnt_fpunsup,2,237
	move.l	(unsup_fa).l,d0
	chkl	d0,0,238
	move.l	(unsup_pc).l,d0
	chkl	d0,fimm_op,239

;================== memory-indirect FP operands (cputest FDIV.W ([0]))
; full-extension EAs with base suppress and memory indirection feed the
; FPU the word AT THE POINTED-TO address, including odd ones
	move.l	#$00003750,($3740).l	; pointer -> $3750
	move.l	#$00003759,($3744).l	; pointer -> ODD address
	move.l	#$00003750,($3748).l	; pointer for outer displacement
	move.w	#5,($3750).l
	move.w	#9,($3754).l
	move.b	#0,($3759).l		; word at $3759 = $0007
	move.b	#7,($375A).l
	fmove.l	#10,fp5
	fdiv.w	([$3740.w]),fp5
	fmove.l	fp5,d0
	chkl	d0,2,241		; 10 / mem[[${3740}]] = 10/5
	fmove.l	#3,fp4
	fmul.w	([$3744.w]),fp4
	fmove.l	fp4,d0
	chkl	d0,21,242		; odd-address word operand: 3*7
	fmove.l	#1,fp3
	fadd.w	([$3748.w],4),fp3
	fmove.l	fp3,d0
	chkl	d0,10,243		; outer displacement: 1+9
	fmove.l	#0,fp6
	fmove.l	#0,fpsr
	fdiv.w	([$3740.w]),fp6
	fmove.l	fpsr,d0
	and.l	#$0F002000,d0
	chkl	d0,$04000000,244	; 0/5 is +0 with Z, never 0/0 OPERR

; RESOLVED 2026-08-09: the suppression revert was tested on hardware
; and cputest FABS.X failed exactly here -- blanket INEX (this $0208)
; is confirmed twice.  Exact 68040_basicfpu FABS.X capture 2026-08-07:
; FPCR $40, extended register source with a tail below bit 24 ->
; destination 3fff-8ccccd00..., FPSR $00000208.
	move.l	#$BFFF0000,($3780).l
	move.l	#$8CCCCCCC,($3784).l
	move.l	#$CCCCCCCD,($3788).l
	fmovem.x	($3780).l,fp1		; raw source, no load-time rounding
	fmove.l	#0,fpsr
	fmove.l	#$40,fpcr		; single precision, nearest-even
	fabs.x	fp1,fp0
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,245
	fmovem.x	fp0,($3790).l
	move.l	($3790).l,d0
	chkl	d0,$3FFF0000,246
	move.l	($3794).l,d0
	chkl	d0,$8CCCCD00,247
	move.l	($3798).l,d0
	chkl	d0,0,248

; FNEG uses the same rounding/status path.  Reload the unrounded positive
; image so this is not merely negating the already-rounded FABS result.
	move.l	#$3FFF0000,($3780).l
	fmovem.x	($3780).l,fp1
	fmove.l	#0,fpsr
	fmove.l	#$40,fpcr
	fneg.x	fp1,fp0
	fmove.l	#0,fpcr
	fmove.l	fpsr,d0
	and.l	#$0000FFFF,d0
	chkl	d0,$0208,249
	fmovem.x	fp0,($3790).l
	move.l	($3790).l,d0
	chkl	d0,$BFFF0000,250
	move.l	($3794).l,d0
	chkl	d0,$8CCCCD00,251
	move.l	($3798).l,d0
	chkl	d0,0,252

; Exact 68040_basicfpu FADD.P effective-address failure captured on hardware
; 2026-08-07.  $0795 is a full extension word with base suppression, a null
; base displacement, D0.W*8 post-indexing, and null outer displacement:
;
;             EA = mem.l[$00000000] + (D0.W * 8)
;
; With mem.l[0]=1 and D0=$154, vector 55's format-$3 EA field must therefore
; be $00000AA1.  Packed operands are unsupported on the 68040, but the source
; is fetched before the datatype trap, so install twelve readable bytes there.
	move.l	#1,($0000).l
	move.l	#$5A000000,($0AA1).l
	move.l	#0,($0AA5).l
	move.l	#0,($0AA9).l
	move.l	#$00000154,d0
	move.l	#0,(cnt_fpunsup).l
	move.l	#$EEEEEEEE,(unsup_fa).l
	lea	fpind_cont(pc),a0
	move.l	a0,(unsup_resume).l
fpind_op:
	dc.w	$F231,$4CA2,$0795	; fadd.p ([D0.w*8]),fp1
fpind_cont:
	chkcnt	cnt_fpunsup,1,253
	move.l	(unsup_fa).l,d1
	chkl	d1,$00000AA1,254
	move.l	(unsup_pc).l,d1
	chkl	d1,fpind_op,255

;=========== FABS.X ([0]),fp3 -- hardware cputest 68040_basicfpu fail
; Full-extension EA: null base displacement, base AND index suppressed,
; null outer displacement -> operand pointer at ABSOLUTE address 0.
; The operand itself sits at an ODD address; the hardware fail read the
; 12-byte window from P+2 (FP3 = 401c-d82c00000000df00), so the memory
; image below mirrors the screenshot bytes exactly: a +2 window
; reproduces that precise wrong value.
	move.l	#$00003761,($0).l	; pointer -> odd operand address
	move.b	#$00,($3761).l		; se word 0000 (sign +, exp 0)
	move.b	#$00,($3762).l
	move.b	#$40,($3763).l		; pad word 401c (ignored on read)
	move.b	#$1C,($3764).l
	move.b	#$B6,($3765).l		; mantissa b6bad82c00000000
	move.b	#$BA,($3766).l		; (pseudo-denormal: int bit set)
	move.b	#$D8,($3767).l
	move.b	#$2C,($3768).l
	move.b	#$00,($3769).l
	move.b	#$00,($376A).l
	move.b	#$00,($376B).l
	move.b	#$00,($376C).l
	move.b	#$DF,($376D).l		; trailing bytes a +2 window would
	move.b	#$00,($376E).l		; pull into the mantissa
	movea.l	#$DEADBEEF,a6		; suppressed base must not matter
	movea.l	#$00000072,a1		; suppressed index must not matter
	fmove.l	#1,fp3
	fmove.l	#0,fpsr
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,($3710).l
	move.l	($3710).l,d0
	chkl	d0,0,256		; se 0000, not the +2 window's 401c
	move.l	($3714).l,d0
	chkl	d0,$B6BAD82C,257
	move.l	($3718).l,d0
	chkl	d0,0,258
	fmove.l	fpsr,d0
	chkl	d0,0,259		; extended pseudo-denormal FABS: no flags

;================ chained-dependency benchmark loop (user 68040 kernel)
; fadd/fmul/fsub/fdiv/fmul/fadd/fsub/fmul all accumulating in fp0 with
; fp1=3, fp2=4 collapses to x <- 12x + 31 per pass, every step exact in
; extended precision while the value fits the mantissa.  Eight passes
; from 2 give 2071729987; no step discards bits so FPSR stays clean.
; (The original uses DBNE, which tests the INTEGER CCR that no FPU op
; writes -- looped here with dbra instead.)
	fmove.l	#2,fp0
	fmove.l	#3,fp1
	fmove.l	#4,fp2
	fmove.l	#0,fpsr
	moveq	#7,d3
fpubench_loop:
	fadd.x	fp1,fp0
	fmul.x	fp2,fp0
	fsub.x	fp1,fp0
	fdiv.x	fp2,fp0
	fmul.x	fp1,fp0
	fadd.x	fp2,fp0
	fsub.x	fp1,fp0
	fmul.x	fp2,fp0
	dbra	d3,fpubench_loop
	fmove.l	fp0,d0
	chkl	d0,2071729987,260	; 12^8 chain, exact
	fmove.l	fpsr,d0
	chkl	d0,0,261		; every step exact: no status at all

; the same kernel saturates: from 2^16382 the fmul.x by 4 overflows to
; +inf under round-to-nearest and every following op passes it through
	move.l	#$7FFE0000,($3700).l	; 2^16382
	move.l	#$80000000,($3704).l
	move.l	#$00000000,($3708).l
	fmovem.x	($3700).l,fp0
	fmove.l	#0,fpsr
	fadd.x	fp1,fp0			; +3: absorbed, INEX2
	fmul.x	fp2,fp0			; x4: OVFL -> +inf
	fsub.x	fp1,fp0
	fdiv.x	fp2,fp0
	fmul.x	fp1,fp0
	fadd.x	fp2,fp0
	fsub.x	fp1,fp0
	fmul.x	fp2,fp0
	fmovem.x	fp0,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$7FFF0000,262	; +infinity
	move.l	($3714).l,d0
	chkl	d0,0,263		; created infinity: zero mantissa
	fmove.l	fpsr,d0
	chkl	d0,$02000048,264	; I code; accrued OVFL+INEX only

;=========== pointer-rewrite ([0]) sequences -- cputest per-test behavior
; cputest rewrites the indirect pointer at absolute 0 immediately before
; every test.  Both hardware failures decode as ONE STALE 16-BIT HALF of
; that just-rewritten longword (FABS.X: low half stale -> operand window
; at 4023; FADD.P: high half stale -> frame EA 80090AA1).  Alternate the
; pointer between values differing in one half and dereference with the
; exact failing encodings immediately after each rewrite, so a lost or
; stale half-word is instantly visible in the result.
	moveq	#7,d3
ptrl:
	move.l	#$00003761,($0).l	; fresh pointer, low half $3761
	fmove.l	#1,fp3
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$00000000,265	; a stale low half reads the $3763
	move.l	($3714).l,d0		; window: se 401c
	chkl	d0,$B6BAD82C,266
	move.l	($3718).l,d0
	chkl	d0,$00000000,267
	move.l	#$00003763,($0).l	; rewrite: only the LOW half changes
	fmove.l	#1,fp3
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,($3710).l
	move.l	($3710).l,d0
	chkl	d0,$401C0000,268	; a stale low half reads the $3761
	move.l	($3714).l,d0		; window: se 0000
	chkl	d0,$D82C0000,269
	move.l	($3718).l,d0
	chkl	d0,$0000DF00,270
	dbra	d3,ptrl

	; integer memory-indirect control: same rewrite pattern, plain read
	move.l	#$00003761,($0).l
	move.l	([$0.w]),d1
	chkl	d1,$0000401C,271
	move.l	#$00003763,($0).l
	move.l	([$0.w]),d1
	chkl	d1,$401CB6BA,272

	; packed source: always vector 55; consecutive frames carry EAs that
	; differ in one half, so a stale half of the stacked EA longword (the
	; FADD.P hardware signature 80090AA1) cannot cancel out
	move.l	#0,($0AAD).l		; 12 readable bytes from every EA below
	move.l	#$00000154,d0
	moveq	#3,d4
pkl:
	move.l	#1,($0).l		; EA = 1 + $AA0 = $00000AA1
	move.l	#0,(cnt_fpunsup).l
	lea	pk1c(pc),a0
	move.l	a0,(unsup_resume).l
	dc.w	$F231,$4CA2,$0795	; fadd.p ([D0.w*8]),fp1
pk1c:
	chkcnt	cnt_fpunsup,1,273
	move.l	(unsup_fa).l,d1
	chkl	d1,$00000AA1,274
	move.l	#3,($0).l		; EA = $00000AA3: low half changes
	move.l	#0,(cnt_fpunsup).l
	lea	pk2c(pc),a0
	move.l	a0,(unsup_resume).l
	dc.w	$F231,$4CA2,$0795	; fadd.p ([D0.w*8]),fp1
pk2c:
	chkcnt	cnt_fpunsup,1,275
	move.l	(unsup_fa).l,d1
	chkl	d1,$00000AA3,276
	move.l	#5,($0).l		; EA = $00000AA5: differs from both
	move.l	#0,(cnt_fpunsup).l
	lea	pk3c(pc),a0
	move.l	a0,(unsup_resume).l
	dc.w	$F231,$4CA2,$0795	; fadd.p ([D0.w*8]),fp1
pk3c:
	chkcnt	cnt_fpunsup,1,277
	move.l	(unsup_fa).l,d1
	chkl	d1,$00000AA5,278
	dbra	d4,pkl

;=========== faithful cputest harness replica around fabs.x ([0])
; ptrfabs on hardware (move.l pointer rewrite, straight-line code) passes,
; so replicate cputest's ACTUAL inter-test context from WinUAE's
; cputest/asm.S execute_testfpu and main.c tomem: the pointer longword is
; rewritten BYTE-WISE, then all eight FP registers are reloaded from the
; register image with FMOVEM.X, FPIAR/FPCR/FPSR are loaded, the integer
; file is reloaded with MOVEM.L, and an RTE drops into the USER-mode test
; block whose tail (fnop) matches the screenshot.  The register images
; are the exact "Registers before" of failing test 1789.
	move.w	#0,(hr_iter).l
hr_loop:
	; --- tomem: byte-wise pointer rewrite at absolute 0 (order 0,1,2,3)
	move.w	(hr_iter).l,d0
	btst	#0,d0
	bne.s	hr_p2
	move.b	#$00,($0).l
	move.b	#$00,($1).l
	move.b	#$37,($2).l
	move.b	#$61,($3).l		; pointer = $00003761
	bra.s	hr_go
hr_p2:
	move.b	#$00,($0).l
	move.b	#$00,($1).l
	move.b	#$37,($2).l
	move.b	#$63,($3).l		; pointer = $00003763
hr_go:
	; --- execute_testfpu replica
	lea	hr_fpimg(pc),a0
	fmovem.x	(a0),fp0-fp7
	lea	hr_fpctl(pc),a1
	fmove.l	(a1)+,fpiar
	fmove.l	(a1)+,fpcr
	fmove.l	(a1)+,fpsr
	lea	hr_ustk+64(pc),a1
	move.l	a1,usp
	move.w	#$0080,-(sp)		; format 0, filler vector offset
	pea	hr_ublk(pc)
	move.w	#$0000,-(sp)		; SR: user mode, all IRQs enabled
	lea	hr_iregs(pc),a0
	movem.l	(a0),d0-d7/a0-a6
	rte

	; --- user-mode test block, tail per the hardware capture
hr_ublk:
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fnop
	trap	#0

	; --- back in supervisor mode: verify FP3 against the FRESH pointer
hr_back:
	fmovem.x	fp3,($3720).l
	move.w	(hr_iter).l,d0
	btst	#0,d0
	bne.s	hr_c2
	move.l	($3720).l,d0
	chkl	d0,$00000000,279	; window at $3761
	move.l	($3724).l,d0
	chkl	d0,$B6BAD82C,280
	move.l	($3728).l,d0
	chkl	d0,$00000000,281
	bra.s	hr_next
hr_c2:
	move.l	($3720).l,d0
	chkl	d0,$401C0000,282	; window at $3763
	move.l	($3724).l,d0
	chkl	d0,$D82C0000,283
	move.l	($3728).l,d0
	chkl	d0,$0000DF00,284
hr_next:
	move.w	(hr_iter).l,d0
	addq.w	#1,d0
	move.w	d0,(hr_iter).l
	cmp.w	#8,d0
	blo	hr_loop

;=========== background FPU execution (non-blocking S_FPU_GO)
; A register-destination FDIV runs while the integer pipeline continues.
; The quotient must be correct afterwards, and an enabled divide-by-zero
; from a released op must be delivered pre-instruction at the next FPU
; dispatch point -- after the intervening integer work, not during it.
	fmove.l	#100,fp0
	fmove.l	#7,fp1
	fdiv.x	fp1,fp0			; released: runs in the background
	moveq	#0,d0			; integer work overlapping the divide
	moveq	#24,d1
bgspin:
	addq.l	#3,d0
	dbra	d1,bgspin
	chkl	d0,75,285		; the integer stream really ran
	fmove.l	fp0,d0
	chkl	d0,14,286		; 100/7 rounded to nearest = 14
	fmove.l	#$4000,fpcr		; enable SNAN (a late, rounding-stage
	fmove.l	#5,fp2			; trap: DZ fires early/synchronously)
	move.l	#$7F800001,($32DC).l
	move.l	#0,(cnt_fpsnan).l
	fmove.s	($32DC).l,fp2		; released; SNAN trap becomes pending
	moveq	#17,d3			; more integer work: the trap must NOT
	add.l	d3,d3			; interrupt this stream
	chkcnt	cnt_fpsnan,0,287	; counter untouched mid-stream
	fnop				; FPU dispatch point: trap delivers here
	chkcnt	cnt_fpsnan,1,288
	fmove.l	fp2,d0
	chkl	d0,5,289		; writeback inhibited by the trap
	fmove.l	#0,fpcr

;=========== IRQ arrival sweep across background FPU execution (F1 soak)
; A level-2 interrupt lands at a swept clk offset inside a released FDIV
; while the integer stream continues; the handler runs FSAVE/FRESTORE --
; the AmigaOS task-switch idiom.  Every offset must deliver the interrupt
; exactly once, the quotient must survive, and nothing may wedge (a stuck
; wait here trips the testbench's global timeout).  Benches whose modeled
; clock alignment cannot deliver IPL at all (turbo co-sim at non-hardware
; CPU_PHASE values) advertise it through the capability word and the
; sweep is bypassed rather than faked.
	tst.w	(IPLCAP).l
	beq	soak_done
	clr.w	(cnt_int2).l
	move.w	#$2000,sr	; open the mask for level 2
	moveq	#1,d7
soak_loop:
	move.w	d7,(IPLDLY).l	; arm the delayed IPL2
	fmove.l	#100,fp0
	fmove.l	#7,fp1
	fdiv.x	fp1,fp0		; released: runs in the background
	moveq	#0,d0
	moveq	#24,d1
soak_spin:
	addq.l	#3,d0
	dbra	d1,soak_spin
	fnop			; FPU sync point
	fmove.l	fp0,d0
	chkl	d0,14,290	; quotient survived the interrupt
soak_wait:
	move.w	(cnt_int2).l,d0
	cmp.w	d7,d0		; exactly one delivery per armed delay
	bne.s	soak_wait
	addq.w	#1,d7
	cmp.w	#48,d7
	bls.s	soak_loop
	chkcnt	cnt_int2,48,291
	move.w	#$2700,sr	; interrupts masked again
soak_done:

	jmp	audit_return

; level-2 autovector: the task-switch idiom around a possibly-active
; background FPU op -- FSAVE gates on quiescence, FRESTORE rearms
h_int2:
	fsave	-(sp)
	frestore	(sp)+
	move.w	#0,(IPLREG).l	; release the IPL lines
	addq.w	#1,(cnt_int2).l
	rte

; TRAP #0 from the user-mode block: record nothing, redirect the return
; into the supervisor flow at hr_back with interrupts masked again.
h_trap0:
	move.w	#$2700,(sp)
	lea	hr_back(pc),a0
	move.l	a0,2(sp)
	rte

hr_iter	equ	$372C

	even
hr_fpimg:				; exact FABS.X test 1789 register image
	dc.w	$3FFF,$0000
	dc.l	$8CCCCCCC,$CCCCCCCD	; FP0
	dc.w	$C001,$0000
	dc.l	$8FFFFFFF,$FFFFFFFC	; FP1
	dc.w	$8000,$0000
	dc.l	$00000000,$00000000	; FP2 (-0.0)
	dc.w	$70B4,$0000
	dc.l	$BBC77C16,$00000000	; FP3 preload
	dc.w	$075F,$0000
	dc.l	$FF64ABB6,$00000000	; FP4
	dc.w	$401A,$0000
	dc.l	$9D4E6619,$4392A766	; FP5
	dc.w	$C01D,$0000
	dc.l	$B61C5011,$A1C22B68	; FP6
	dc.w	$7FFF,$0000
	dc.l	$FFFFFFFF,$FFFFFFFF	; FP7 (NaN)
hr_fpctl:
	dc.l	$FFFFFFFF		; FPIAR canary
	dc.l	$00000000		; FPCR
	dc.l	$00000000		; FPSR
hr_iregs:				; integer file per the capture (A7
	dc.l	$000000D6,$00000000	; slot unused by MOVEM d0-d7/a0-a6)
	dc.l	$7FFB5F7F,$E00FBFFF
	dc.l	$8017FFC4,$00050505
	dc.l	$00202020,$6433AAA6
	dc.l	$00000000,$00000072
	dc.l	$00007FEE,$0000FFFF
	dc.l	$7FFFFF62,$C03FFFFF
	dc.l	$00003300
hr_ustk:
	ds.b	64
