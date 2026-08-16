	org	0
	dc.l	$4000
	dc.l	start
	rept	254
	dc.l	start
	endr
	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$4000,sp
	lea	($3800).l,a6
	move.l	#$F0,d5
	move.l	#$10,d4
	move.w	#0,ccr
	sub.b	d4,d5		; $E0: N=1 C=0 X=0 Z=0
	move.w	ccr,(a6)+	; expect $0008
	subx.w	d5,d5		; 0 - 0 - X(0) = 0: Z stays 0 -> $0000
	move.w	ccr,(a6)+	; first read
	move.w	ccr,(a6)+	; second read (after the first flushed)
	nop
	move.w	ccr,(a6)+	; third read after a nop
	move.w	#$600D,($F102).l
loop1:
	bra	loop1
