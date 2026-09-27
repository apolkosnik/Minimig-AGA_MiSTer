; t_dcache_pipe.s - plan M14 step 3: the data read path (a read-only copy
; of the D-cache bank answering EA-fetch's read the clock after it issues,
; ap040_cache.v g_dfp, ap040_mmu.v g_dfp, the core's store-order rule).
; Runs under tb_ap040_pipe_compat.v (cache_allow_all = 1: everything
; cacheable) with its DMA agent ($F1E4 address, $F1E6 data, $F1EA = 1 no
; snoop, $F1E8 = delay arms it).  Protocol: $F100 = failing check, $F102 =
; $600D / $BAD0.
;
;   1  a DMA write with its snoop invalidates a cached longword: the next
;      read sees the new value
;   2  the same with the DMA landing 0..47 clocks into a burst of reads: the
;      values read change at most once, from old to new, never back
;   3  (after 2) the last value read is the new one
;   4  store then load of the same longword, word and byte, back to back,
;      many times: every load sees the store before it
;  15  a store with nothing else in flight, then a load of it (0..7 ALU
;      instructions in front; (An) and d16(An)): the load sees the store
;  16  every store happens once: 50 stores to the bench's store-counting
;      register count 50 (the registered store completion must not re-send)
;   5  CACR.DE clear: a read goes to memory (a DMA write without a snoop
;      changed it), not to the cached copy
;   6  a misaligned longword (not served by the path) reads right
;   7  TC.E = 1, logical page 2 -> physical $4000: a read through the data
;      ATC copy returns physical $4000's data
;   8  remapped to physical $6000 and PFLUSHA: the ATC copy follows
;   9  the page made cache-inhibited (CM = 10) and PFLUSHA, memory changed
;      without a snoop: the read goes to memory
;  10  a DTT0 with CM = inhibited over the data, TC off: the same

FAILREG	equ	$F100
DONEREG	equ	$F102
DMA_A	equ	$F1E4
DMA_D	equ	$F1E6
DMA_GO	equ	$F1E8
DMA_NS	equ	$F1EA
X	equ	$2400		; a cached longword (its low word is the DMA target)
BUF	equ	$2800		; read samples
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	bc
	clr.w	DMA_NS

; 1: DMA with snoop
	move.l	#$11112222,X
	move.l	X,d0			; cached
	cmp.l	#$11112222,d0
	beq.s	.c1a
	failt	11
.c1a:	move.w	#X+2,DMA_A
	move.w	#$3333,DMA_D
	move.w	#0,DMA_GO
	moveq	#50,d1
.w1:	dbra	d1,.w1
	move.l	X,d0
	cmp.l	#$11113333,d0
	beq.s	.c1b
	failt	1
.c1b:

; 2/3: the DMA lands inside a burst of reads, swept 0..47 clocks
	moveq	#0,d6			; the delay
.l2:	move.l	#$44440000,X		; old value (the store updates the line)
	move.l	X,d0			; cached
	move.w	#X+2,DMA_A
	move.w	#$5555,DMA_D
	move.w	d6,DMA_GO
	lea	BUF,a1
	rept	24
	move.l	X,(a1)+
	endr
	moveq	#50,d1
.w2:	dbra	d1,.w2
	; the samples: $44440000 ... then $44445555 ..., never back
	lea	BUF,a1
	moveq	#23,d1
	moveq	#0,d2			; seen the new value
.s2:	move.l	(a1)+,d0
	cmp.l	#$44445555,d0
	beq.s	.new2
	cmp.l	#$44440000,d0
	beq.s	.old2
	failt	12			; neither
.old2:	tst.b	d2
	beq.s	.n2
	failt	2			; old after new
.new2:	st	d2
.n2:	dbra	d1,.s2
	move.l	X,d0
	cmp.l	#$44445555,d0
	beq.s	.c3
	failt	3
.c3:	addq.l	#1,d6
	cmp.l	#48,d6
	bne	.l2

; 4: store then load, back to back
	move.l	X,d0			; cached
	moveq	#0,d5
	move.w	#199,d6
.l4:	move.l	d5,X
	move.l	X,d0
	cmp.l	d5,d0
	beq.s	.c4a
	failt	4
.c4a:	move.w	d5,X+2
	move.w	X+2,d0
	cmp.w	d5,d0
	beq.s	.c4b
	failt	14
.c4b:	move.b	d5,X+1
	move.b	X+1,d0
	cmp.b	d5,d0
	beq.s	.c4c
	failt	24
.c4c:	add.l	#$01030507,d5
	dbra	d6,.l4

; 15: a store with nothing else in flight, then a load of the same longword:
;     the load's early read can go out in the clock the store is handed to EX
;     (the store is visible to the core's store-order rule only a clock
;     later).  Shapes: 0..7 ALU instructions in front, (An) and d16(An).
	lea	X,a2
	move.l	X,d0			; cached
	moveq	#7,d6
.l15:	move.l	d6,d5
	swap	d5
	move.w	d6,d5			; a value per pass
	move.l	#$10000,d3
	lea	sh15,a3
	move.l	d6,d2
	lsl.l	#2,d2
	move.l	(a3,d2.l),a3
	jsr	(a3)
	cmp.l	d5,d0
	beq.s	.c15a
	failt	15
.c15a:	cmp.l	d5,d1
	beq.s	.c15b
	failt	25
.c15b:	dbra	d6,.l15

; 5: DE clear, memory changed behind the cache
	move.l	#$66660000,X
	move.l	X,d0			; cached
	move.l	#$00008000,d0		; IE only
	movec	d0,cacr
	move.w	#1,DMA_NS
	move.w	#X+2,DMA_A
	move.w	#$7777,DMA_D
	move.w	#0,DMA_GO
	moveq	#50,d1
.w5:	dbra	d1,.w5
	move.l	X,d0
	cmp.l	#$66667777,d0
	beq.s	.c5
	failt	5
.c5:	clr.w	DMA_NS
	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	dc

; 6: a misaligned longword
	move.l	#$01234567,X
	move.l	#$89abcdef,X+4
	move.l	X,d0
	move.l	X+2,d0
	cmp.l	#$456789ab,d0
	beq.s	.c6
	failt	6
.c6:

; 7/8/9: the data ATC copy.  4K pages 0-15 identity except logical page 2.
; The longword is at offset $100 (set $10): the walker's U-bit write-back to
; the descriptors at $5000/$5408 snoops set 0 clear, which must not be the set
; this test watches.
	move.l	#$0a0a0a0a,$4100
	move.l	#$0b0b0b0b,$6100
	move.l	#$0c0c0c0c,$2100	; physical page 2 itself
	lea	ROOT,a0
	move.l	#PTR|3,(a0)
	lea	PTR,a0
	move.l	#PAGE|3,(a0)
	lea	PAGE,a0
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.l	#1,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#$4000|1,PAGE+2*4	; logical page 2 -> physical $4000
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	cpusha	bc
	move.l	$2100,d0		; TC off: physical $2100's line is cached (so a
					;  read path that skipped translation would hit it)
	pflusha
	move.l	#$8000,d0
	movec	d0,tc
	move.l	$2100,d0
	move.l	$2100,d0		; (again: through the ATC copy)
	cmp.l	#$0a0a0a0a,d0
	beq.s	.c7
	failt	7
.c7:	move.l	#$6000|1,PAGE+2*4	; remap -> physical $6000
	pflusha
	move.l	$2100,d0
	move.l	$2100,d0
	cmp.l	#$0b0b0b0b,d0
	beq.s	.c8
	failt	8
.c8:	move.l	#$6000|$41,PAGE+2*4	; physical $6000, CM = 10 (inhibited)
	pflusha
	move.w	#1,DMA_NS
	move.w	#$6102,DMA_A		; (the DMA agent writes PHYSICAL memory)
	move.w	#$0d0d,DMA_D
	move.w	#0,DMA_GO
	moveq	#50,d1
.w9:	dbra	d1,.w9
	move.l	$2100,d0
	cmp.l	#$0b0b0d0d,d0
	beq.s	.c9
	failt	9
.c9:	clr.w	DMA_NS
	moveq	#0,d0
	movec	d0,tc
	pflusha
	cpusha	dc

; 10: DTT0 inhibited over $00xxxxxx, TC off
	move.l	#$0e0e0000,X
	move.l	X,d0			; cached
	move.l	#$0000c040,d0
	movec	d0,dtt0
	move.w	#1,DMA_NS
	move.w	#X+2,DMA_A
	move.w	#$0f0f,DMA_D
	move.w	#0,DMA_GO
	moveq	#50,d1
.w10:	dbra	d1,.w10
	move.l	X,d0
	cmp.l	#$0e0e0f0f,d0
	beq.s	.c10
	failt	10
.c10:	clr.w	DMA_NS
	moveq	#0,d0
	movec	d0,dtt0
	cpusha	dc

; 16: every store happens once: 50 stores to the bench's store-counting
;     register $F1F4, back to back and interleaved with loads, count 50
	move.l	#$00008000,d0		; IE only: $F1F6 is read from memory
	movec	d0,cacr
	clr.w	$f1f6
	moveq	#24,d1
.l16:	move.w	d1,$f1f4
	move.w	d1,$f1f4
	move.l	X,d0
	dbra	d1,.l16
	move.w	$f1f6,d0
	cmp.w	#50,d0
	beq.s	.c16
	failt	16
.c16:	move.l	#CACR_ON,d0
	movec	d0,cacr

	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; test 15's shapes: \1 ALU instructions, a store to (a2) and a load of it,
; then the same with d16(An)
SH15	macro
	rept	\1
	add.l	d3,d4
	endr
	move.l	d5,(a2)
	move.l	(a2),d0
	rept	\1
	add.l	d3,d4
	endr
	move.l	d5,4(a2)
	move.l	4(a2),d1
	rts
	endm
	cnop	0,4
sh15:	dc.l	h0,h1,h2,h3,h4,h5,h6,h7
h0:	SH15	0
h1:	SH15	1
h2:	SH15	2
h3:	SH15	3
h4:	SH15	4
h5:	SH15	5
h6:	SH15	6
h7:	SH15	7
