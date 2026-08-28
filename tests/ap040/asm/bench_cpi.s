; AP040 CPI microbenchmark: per-instruction-class cost.
;
; Each block is 256 iterations of 16 IDENTICAL unrolled instructions plus a
; dbra, stamped before and after on $F108, so
;
;     clocks per instruction = stamp delta / 4096
;
; with the dbra amortized to 1/16 per instruction.  Caches are ON: this
; measures the CORE, not the bus, so everything hot must hit.  Data accesses
; go to one line that the preamble warms.
;
; Stamps:
;   $0010/$0011  16x nop
;   $0020/$0021  16x add.l  d2,d3        register ALU
;   $0030/$0031  16x move.l d2,d3        register move
;   $0040/$0041  16x move.l (a0),d3      load, cache hit, same line
;   $0050/$0051  16x move.l d3,(a0)      store, write-through, same line
;   $0060/$0061  16x lea 4(a0),a0        EA arithmetic (rewound each iter)
;   $0070/$0071  16x moveq #7,d3         immediate
;   $0080/$0081  8x (add.l d2,d3 ; move.l (a0),d3)  ALU/load mix
;   $0090/$0091  16 taken bra.s per iteration
;   $00A0/$00A1  16x add.l d3,d3         dependent chain

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
	move.l	#$80008000,d0
	movec	d0,cacr

	lea	($3000).l,a0
	move.l	#$11223344,(a0)		; warm the line
	move.l	(a0),d1

	moveq	#0,d2
	moveq	#0,d3

; ---------------------------------------------------------------- 16x nop
	move.w	#$0010,($F108).l
	move.w	#255,d6
b1:	rept	16
	nop
	endr
	dbra	d6,b1
	move.w	#$0011,($F108).l

; ---------------------------------------------------------- 16x add.l d2,d3
	move.w	#$0020,($F108).l
	move.w	#255,d6
b2:	rept	16
	add.l	d2,d3
	endr
	dbra	d6,b2
	move.w	#$0021,($F108).l

; --------------------------------------------------------- 16x move.l d2,d3
	move.w	#$0030,($F108).l
	move.w	#255,d6
b3:	rept	16
	move.l	d2,d3
	endr
	dbra	d6,b3
	move.w	#$0031,($F108).l

; -------------------------------------------------------- 16x move.l (a0),d3
	move.w	#$0040,($F108).l
	move.w	#255,d6
b4:	rept	16
	move.l	(a0),d3
	endr
	dbra	d6,b4
	move.w	#$0041,($F108).l

; -------------------------------------------------------- 16x move.l d3,(a0)
	move.w	#$0050,($F108).l
	move.w	#255,d6
b5:	rept	16
	move.l	d3,(a0)
	endr
	dbra	d6,b5
	move.w	#$0051,($F108).l

; --------------------------------------------------------- 16x lea 4(a0),a0
	move.w	#$0060,($F108).l
	move.w	#255,d6
b6:	rept	16
	lea	4(a0),a0
	endr
	lea	-64(a0),a0
	dbra	d6,b6
	move.w	#$0061,($F108).l

; ----------------------------------------------------------- 16x moveq #7,d3
	move.w	#$0070,($F108).l
	move.w	#255,d6
b7:	rept	16
	moveq	#7,d3
	endr
	dbra	d6,b7
	move.w	#$0071,($F108).l

; ------------------------------------------- 8x (add.l d2,d3; move.l (a0),d3)
	move.w	#$0080,($F108).l
	move.w	#255,d6
b8:	rept	8
	add.l	d2,d3
	move.l	(a0),d3
	endr
	dbra	d6,b8
	move.w	#$0081,($F108).l

; ---------------------------------------------- 16 taken bra.s per iteration
	move.w	#$0090,($F108).l
	move.w	#255,d6
b9:
	rept	16
	bra.s	*+4
	endr
	dbra	d6,b9
	move.w	#$0091,($F108).l

; ------------------------------------------------ 16x add.l d3,d3 dependent
	move.w	#$00A0,($F108).l
	move.w	#255,d6
bA:	rept	16
	add.l	d3,d3
	endr
	dbra	d6,bA
	move.w	#$00A1,($F108).l

	move.w	#$600D,($F102).l
	stop	#$2700

unexp:
	move.w	#$0099,($F100).l
	move.w	#$BAD0,($F102).l
h:	bra.s	h
