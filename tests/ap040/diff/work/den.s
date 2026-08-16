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
	fmove.l	#0,fpcr			; extended, round to nearest
; A = 2^-16380 (exp field 3), B = 2^-13 (exp field 16370)
	move.l	#$00030000,($3400).l
	move.l	#$80000000,($3404).l
	move.l	#$00000000,($3408).l
	move.l	#$3FF20000,($3410).l
	move.l	#$80000000,($3414).l
	move.l	#$00000000,($3418).l
	fmove.x	($3400).l,fp0
	fmove.x	($3410).l,fp1
	fmul.x	fp1,fp0			; 2^-16393: subnormal for extended
	fmovem.x	fp0,($3F40).l
	fmove.l	fpsr,d0
	and.l	#$00000F00,d0		; exception byte: UNFL/INEX
	move.l	d0,($3F50).l
	move.w	#$600D,($F102).l
stop1:	bra	stop1
unexp:	move.w	#$BAD0,($F102).l
stop2:	bra	stop2
