	org	0
	dc.l	$4000
	dc.l	start
	rept	9
	dc.l	unexp		; 2-10
	endr
	dc.l	h11		; 11 F-line / unimplemented instruction
	rept	43
	dc.l	unexp		; 12-54
	endr
	dc.l	h55		; 55 unimplemented data type
	rept	200
	dc.l	unexp		; 56-255
	endr
	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$4000,sp
	move.l	#0,($3F00).l		; vector taken
	move.l	#0,($3F04).l		; frame format/vector word
; denormalized double at $3500: exponent field 0, mantissa nonzero
	move.l	#$00001200,($3500).l
	move.l	#$d400003f,($3504).l
	lea	($3500).l,a1
	fabs.d	(a1),fp2
	move.l	#$600D,($3F08).l	; reached only if no trap
	move.w	#$600D,($F102).l
stop1:	bra	stop1
h11:
	move.l	#11,($3F00).l
	move.w	6(sp),d0
	move.l	d0,($3F04).l
	move.w	#$600D,($F102).l
stopa:	bra	stopa
h55:
	move.l	#55,($3F00).l
	move.w	6(sp),d0
	move.l	d0,($3F04).l
	move.w	#$600D,($F102).l
stopb:	bra	stopb
unexp:
	move.l	#$99,($3F00).l
	move.w	6(sp),d0
	move.l	d0,($3F04).l
	move.w	#$600D,($F102).l
stopc:	bra	stopc
