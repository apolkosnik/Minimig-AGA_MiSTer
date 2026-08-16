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
; identity page table for 64 x 4K pages at $4400, page 11 -> physical $C000
	lea	($4400).l,a0
	moveq	#0,d0
	moveq	#63,d1
tloop:
	move.l	d0,d2
	lsl.l	#8,d2
	lsl.l	#4,d2
	addq.l	#3,d2
	move.l	d2,(a0)+
	addq.l	#1,d0
	dbra	d1,tloop
	move.l	#$0000C003,($442C).l	; page 11 ($B000) -> PA $C000
	move.l	#$00004203,($4000).l
	move.l	#$00004403,($4200).l
	move.l	#0,($B000).l
	move.l	#0,($C000).l
; enable, write through the remapped page, disable
	move.l	#$4000,d0
	movec	d0,urp
	movec	d0,srp
	move.l	#$8000,d0
	movec	d0,tc
	pflusha
	move.l	#$DEAD1234,($B000).l
	lea	($B000).l,a1
	moveq	#5,d0
	movec	d0,dfc
	ptestr	(a1)
	movec	mmusr,d3
	move.l	#0,d0
	movec	d0,tc
; copy the evidence into the compared window
	move.l	($B000).l,($3F00).l	; physical $B000
	move.l	($C000).l,($3F04).l	; physical $C000
	move.l	($4414).l,($3F08).l	; page 5 descriptor: U/M history bits
	move.l	d3,($3F0C).l		; MMUSR after PTESTR of $B000
	move.w	#$600D,($F102).l
stop1:	bra	stop1
unexp:	move.w	#$BAD0,($3FFE).l
	move.w	#$BAD0,($F102).l
stop2:	bra	stop2
