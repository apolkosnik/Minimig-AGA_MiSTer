; FMOVE.L FPn,Dn with a NaN / Inf source: does it trap, or convert with OPERR?
; Per probe at $3500+: 4 bytes result, 4 bytes FPSR, 4 bytes trap count.
	org	0
	dc.l	$4000
	dc.l	start
	rept	9
	dc.l	unexp
	endr
	dc.l	h_fline		; 11
	rept	43
	dc.l	unexp		; 12-54
	endr
	dc.l	h_unsupp	; 55 unsupported data type
	rept	200
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$4000,sp
	lea	(probes).l,a0
	lea	($3500).l,a1
	fmove.l	#0,fpcr
next:
	move.l	(a0),d0
	cmpi.l	#$DEADBEEF,d0
	beq.s	done
	move.l	(a0)+,($3600).l
	move.l	(a0)+,($3604).l
	move.l	(a0)+,($3608).l
	moveq	#0,d5
	moveq	#-1,d2
	fmove.l	#0,fpsr
	fmove.x	($3600).l,fp0
	fmove.l	fp0,d2
	fmove.l	fpsr,d3
	move.l	d2,(a1)+
	move.l	d3,(a1)+
	move.l	d5,(a1)+
	bra.s	next
done:
	move.w	#$600D,($F102).l
stop1:
	bra	stop1

h_fline:
	addq.l	#1,d5
	rte
h_unsupp:
	addq.l	#1,d5
	addq.l	#1,d5			; +2 marks vector 55
	rte

probes:
	dc.l	$7FFF0000,$FFFFFFFF,$FFFFFFFF	; NaN (all-ones, the 040 reset value)
	dc.l	$7FFF0000,$C0000000,$00000000	; quiet NaN
	dc.l	$7FFF0000,$00000000,$00000000	; +Inf
	dc.l	$FFFF0000,$00000000,$00000000	; -Inf
	dc.l	$00000000,$00000000,$00000001	; denormal (unsupported on 040)
	dc.l	$DEADBEEF
unexp:
	move.w	#$BAD0,($3FFE).l
	move.w	#$BAD0,($F102).l
stop2:
	bra	stop2
