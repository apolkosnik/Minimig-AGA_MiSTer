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
; case 1: X=0 Z=1, subx of equal regs: result 0, Z stays 1 -> $04
	moveq	#7,d0
	move.w	#$04,ccr
	subx.w	d0,d0
	move.w	ccr,(a6)+
; case 2: X=0 Z=0: result 0, Z stays 0 -> $00
	move.w	#$00,ccr
	subx.w	d0,d0
	move.w	ccr,(a6)+
; case 3: X=1 Z=1, negx of 0: result $FFFF -> N C X, Z cleared -> $19
	moveq	#0,d1
	move.w	#$14,ccr
	negx.w	d1
	move.w	ccr,(a6)+
; case 4: X=1 Z=1, negx of 0 long -> $19
	moveq	#0,d2
	move.w	#$14,ccr
	negx.l	d2
	move.w	ccr,(a6)+
; case 5: X=1, 5-5-1 word: $FFFF -> N C X -> $19
	moveq	#5,d3
	moveq	#5,d4
	move.w	#$10,ccr
	subx.w	d3,d4
	move.w	ccr,(a6)+
; case 6: X=1 Z=1, 6-5-1=0: Z stays 1 -> $04
	moveq	#5,d3
	moveq	#6,d4
	move.w	#$14,ccr
	subx.w	d3,d4
	move.w	ccr,(a6)+
; case 7: addx: X=1 Z=1, 3+4+1=8 -> all clear -> $00
	moveq	#3,d5
	moveq	#4,d6
	move.w	#$14,ccr
	addx.w	d5,d6
	move.w	ccr,(a6)+
; case 8: addx overflow: X=0 Z=0, $7FFF+$0001 -> N V -> $0A
	move.l	#$7FFF,d5
	move.l	#$1,d6
	move.w	#$00,ccr
	addx.w	d6,d5
	move.w	ccr,(a6)+
	move.w	#$600D,($F102).l
loop1:
	bra	loop1
