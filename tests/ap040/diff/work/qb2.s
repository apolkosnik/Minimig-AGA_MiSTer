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
	move.l	#$01B5B732,d3
	move.w	#$18,ccr
	negx.w	d3
	move.w	ccr,(a6)+	; A: qemu flag state after negx
	move.w	#$12,ccr
	move.w	ccr,(a6)+	; B: should be 0012
	movem.l	d0-d3,($3F00).l
	move.w	ccr,(a6)+	; C: should still be 0012
	move.w	#$12,ccr
	nop
	move.w	ccr,(a6)+	; D: control without movem
	move.w	#$600D,($F102).l
loop1:
	bra	loop1
