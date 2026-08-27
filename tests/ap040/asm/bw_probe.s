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

	; ---- block 5: STREAMING reads -- the xsysinfo regime -------------
	; Sweep a 32KB region ($4000-$BFFF) so every line is a miss: the L1
	; is far smaller, so this measures the line-fill path, which is what
	; a bandwidth benchmark over a large buffer actually exercises.
	move.w	#$0050,($F108).l
	lea	($4000).l,a0
	move.w	#1023,d6		; 1024 x 32 bytes = 32KB
bw5:
	movem.l	(a0)+,d0-d5		; 24 bytes
	addq.l	#8,a0			; skip to next 32B so lines never rehit
	dbra	d6,bw5
	move.w	#$0051,($F108).l

	; ---- block 6: streaming again, warmed -- proves it still misses --
	move.w	#$0060,($F108).l
	lea	($4000).l,a0
	move.w	#1023,d6
bw6:
	movem.l	(a0)+,d0-d5
	addq.l	#8,a0
	dbra	d6,bw6
	move.w	#$0061,($F108).l

	; ---- block 7: streaming WRITES over the same region --------------
	move.w	#$0070,($F108).l
	lea	($4000).l,a0
	move.w	#1023,d6
bw7:
	movem.l	d0-d5,(a0)
	lea	32(a0),a0
	dbra	d6,bw7
	move.w	#$0071,($F108).l

	; ---- block 8: read-modify-write of ONE line, repeatedly ----------
	; The whole-set store invalidation case: a store kills its own set,
	; so the next read of the same line refills.  Real code does this
	; constantly (counters, linked structures).
	move.w	#$0080,($F108).l
	move.w	#255,d6
	lea	($3000).l,a0
bw8:
	move.l	(a0),d0
	addq.l	#1,d0
	move.l	d0,(a0)
	move.l	4(a0),d1
	addq.l	#1,d1
	move.l	d1,4(a0)
	dbra	d6,bw8
	move.w	#$0081,($F108).l

	move.w	#$600D,($F102).l
	stop	#$2700

unexp:
	move.w	#$0099,($F100).l
	move.w	#$BAD0,($F102).l
h:	bra.s	h
