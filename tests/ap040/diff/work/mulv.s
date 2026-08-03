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
	move.l	#$10000,d0
	move.l	#$10000,d1
	move.w	#0,ccr
	mulu.l	d0,d1		; product 2^32: overflow, V=1 N=0 Z=1? result low=0 -> Z=1 V=1
	move.w	ccr,(a6)+
	move.l	#$10000,d2
	move.l	#$20003,d3
	move.w	#0,ccr
	muls.l	d2,d3		; $20003 * $10000 overflows signed: V=1
	move.w	ccr,(a6)+
	move.l	d1,(a6)+
	move.l	d3,(a6)+
	move.w	#$600D,($F102).l
loop1:
	bra	loop1
