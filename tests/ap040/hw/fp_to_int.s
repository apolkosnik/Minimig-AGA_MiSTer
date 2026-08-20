; FMOVE.L FPn,Dn conversion audit: the third instruction of the reported
; sequence.  Per probe, 8 bytes at $3500+: the converted longword, then
; FPSR (bit 13 OPERR marks an out-of-range conversion).
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
	lea	(probes).l,a0
	lea	($3500).l,a1
	fmove.l	#0,fpcr			; extended, round to nearest
next:
	move.l	(a0),d0
	cmpi.l	#$DEADBEEF,d0
	beq.s	done
	move.l	(a0)+,($3600).l		; store the extended image verbatim
	move.l	(a0)+,($3604).l
	move.l	(a0)+,($3608).l
	fmove.l	#0,fpsr
	fmove.x	($3600).l,fp0
	fmove.l	fp0,d2			; the conversion under test
	fmove.l	fpsr,d3
	move.l	d2,(a1)+
	move.l	d3,(a1)+
	bra.s	next
done:
	move.w	#$600D,($F102).l
stop1:
	bra	stop1

probes:
	dc.l	$40000000,$A0000000,$00000000	; 2.5
	dc.l	$40000000,$A6666666,$66666666	; 2.6
	dc.l	$C0000000,$A0000000,$00000000	; -2.5
	dc.l	$401D0000,$FFFFFFFD,$00000000	; 2147483646.5
	dc.l	$401D0000,$FFFFFFFE,$00000000	; 2147483647.0
	dc.l	$401D0000,$FFFFFFFF,$00000000	; 2147483647.5
	dc.l	$401E0000,$80000000,$00000000	; 2147483648.0
	dc.l	$C01E0000,$80000000,$00000000	; -2147483648.0
	dc.l	$C01E0000,$80000001,$00000000	; -2147483649.0
	dc.l	$DEADBEEF
unexp:
	move.w	#$BAD0,($3FFE).l
	move.w	#$BAD0,($F102).l
stop2:
	bra	stop2
