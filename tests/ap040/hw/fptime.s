; FPU latency probe: each block runs one op 256 times back-to-back.
; The tb's +prof histogram gives per-state cycles; here we bracket each
; block with a marker store so cycle counts can be read from the bus log.
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
	move.l	#$3FFF0000,($3400).l
	move.l	#$C0000000,($3404).l
	move.l	#$00000000,($3408).l
	move.l	#$40000000,($3410).l
	move.l	#$90000000,($3414).l
	move.l	#$00000000,($3418).l
	fmove.l	#0,fpcr
	fmove.x	($3400).l,fp0
	fmove.x	($3410).l,fp1
	fmove.x	($3400).l,fp2

	move.w	#$0001,($F108).l	; marker: FADD.X block
	rept	256
	fadd.x	fp0,fp2
	endr
	move.w	#$0002,($F108).l	; marker: FMUL.X block
	rept	256
	fmul.x	fp0,fp2
	endr
	move.w	#$0003,($F108).l	; marker: FDIV.X block
	rept	256
	fdiv.x	fp0,fp2
	endr
	move.w	#$0004,($F108).l	; marker: FSQRT.X block
	rept	256
	fsqrt.x	fp2
	endr
	move.w	#$0005,($F108).l	; marker: FMOVE.X reg block
	rept	256
	fmove.x	fp0,fp2
	endr
	move.w	#$0006,($F108).l	; marker: NOP baseline
	rept	256
	nop
	endr
	move.w	#$0007,($F108).l
	move.w	#$600D,($F102).l
stop1:
	bra	stop1
unexp:
	move.w	#$BAD0,($3FFE).l
	move.w	#$BAD0,($F102).l
stop2:
	bra	stop2
