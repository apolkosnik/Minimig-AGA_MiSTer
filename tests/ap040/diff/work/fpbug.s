	org	0
	dc.l	$4000
	dc.l	start
	rept	254
	dc.l	unexp
	endr
	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$4000,sp
; constant: 1.0 + a full-width mantissa tail (exp $3FFF, m=$8000000000000FFF)
	move.l	#$3FFF0000,($3400).l
	move.l	#$80000000,($3404).l
	move.l	#$00000FFF,($3408).l
; bug 1: FMOVE must round to the FPCR precision (single here)
	fmove.l	#$40,fpcr		; single precision, round to nearest
	fmove.x	($3400).l,fp0
	fmove.l	#0,fpcr
	fmove.x	fp0,($3F40).l
; bug 2: arithmetic must honour the rounding MODE at reduced precision
	fmove.l	#$90,fpcr		; double precision, round toward zero
	fmove.x	($3400).l,fp1		; (single-rounded value is exact here)
	move.l	#$3FFF0000,($3410).l
	move.l	#$80000000,($3414).l
	move.l	#$00000000,($3418).l
	fmove.x	($3400).l,fp1
	fadd.x	($3410).l,fp1		; 1+eps + 1: tail must truncate, not round
	fmove.l	#0,fpcr
	fmove.x	fp1,($3F50).l
	move.w	#$600D,($F102).l
stop1:	bra	stop1
unexp:	move.w	#$BAD0,($F102).l
stop2:	bra	stop2
