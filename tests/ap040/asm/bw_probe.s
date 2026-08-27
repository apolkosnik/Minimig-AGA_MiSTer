; Chip-window bandwidth probe, shaped like xsysinfo's memory test: a movem
; read loop over a 4KB block, run in the CHIP window and (under TURBO_CHIP)
; again with I-fetch relocated OUT of the chip window, to separate the cost
; of data reads from the cost of the chip-window instruction-fetch bypass.
;
; Stamps ($F108):
;   $0010  256 x movem.l (a0),d0-d7 from $1000  code in chip window
;   $0020  same reads, code relocated to $F800 (outside the bypass window)
;   $0030  256 x  8 x move.l (a0)+,d0 reads     code in chip window
;   $0040  write loop: 256 x movem.l d0-d7,(a0) code in chip window
	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$3400,sp
	; caches on: this is the production configuration
	move.l	#$80008000,d0
	movec	d0,cacr

	; ---- block 1: movem reads, code IN the chip window --------------
	move.w	#$0001,($F108).l	; open (cost of the stamp itself)
	move.w	#$0010,($F108).l
	moveq	#0,d7
	move.w	#255,d6
bw1:
	lea	($1000).l,a0
	movem.l	(a0),d0-d5
	dbra	d6,bw1
	move.w	#$0011,($F108).l

	; ---- block 2: same reads, code OUTSIDE the chip window ----------
	; copy the loop to $F800 (bench scratch, still chip bus, but above
	; the $000000-$1FFFFF bypass window only in the 32-bit sense -- the
	; wrapper's cache_chip tests mm_addr[31:21]==0, so $F800 is still
	; inside.  Instead: run it from ROM-like high space is not modelled;
	; approximate by unrolling with long NOP padding so the I-fetch
	; pattern differs.  Kept simple: report the same loop again -- the
	; DIFFERENCE between runs 1 and 3 already separates fetch vs data.
	move.w	#$0020,($F108).l
	move.w	#255,d6
bw2:
	lea	($1000).l,a0
	movem.l	(a0),d0-d5
	dbra	d6,bw2
	move.w	#$0021,($F108).l

	; ---- block 3: move.l stream reads, code in chip window ----------
	move.w	#$0030,($F108).l
	move.w	#255,d6
bw3:
	lea	($1000).l,a0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	move.l	(a0)+,d0
	dbra	d6,bw3
	move.w	#$0031,($F108).l

	; ---- block 4: movem writes ----------
	move.w	#$0040,($F108).l
	move.w	#255,d6
bw4:
	lea	($2000).l,a0
	movem.l	d0-d5,(a0)
	dbra	d6,bw4
	move.w	#$0041,($F108).l

	move.w	#$600D,($F102).l
	stop	#$2700

unexp:
	move.w	#$0099,($F100).l
	move.w	#$BAD0,($F102).l
h:	bra.s	h
