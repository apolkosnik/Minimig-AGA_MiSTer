; The AP68060 in Minimig: AGA's 32-bit chip RAM cycles (Minimig's chip32_en,
; chip_long).  The adapter hands cpu_wrapper a long word as two word
; accesses; cpu_wrapper makes an aligned long word in chip RAM one 32-bit
; chip cycle: a write's high word is held until the low one comes, a read's
; low word is kept for the second access.  Every access below is checked
; against what the other access widths see, so a word lost, swapped or
; written to the wrong half shows; the bench counts the 32-bit cycles
; (chip RAM $F134.w; $F136.w nonzero when the bench makes them).
;   1  long writes, read back as longs, words and bytes
;   2  word and byte writes over them, read back as longs
;   3  misaligned long words (A1 set): two word cycles, the same data
;   4  a chip-to-chip copy of 64 long words (MOVE.L (A0)+,(A1)+), then
;      MOVEM.L of 8 registers out and back
;   5  a long read after the bench's chipset DMA rewrote the long word
;      ($F120: $8000.l inverted behind the processor): both halves new
;   6  long writes back to back with word writes between them to other
;      addresses, then everything read back
;   7  32-bit cycles were made (when the bench makes them)
; Data caches on with chip RAM cache inhibited (DTT0, as 68060.library has
; it); the code runs from chip RAM, uncached.

CHIP	equ	$20000
BUF2	equ	$24000
CNT32	equ	$f134
ON32	equ	$f136

ck	macro			; \1 operand, \2 expected (with #), \3 test
	cmp.l	\2,\1
	beq.s	ok\@
	move.w	#\3,($f100).l
	bra.w	fail
ok\@:
	endm

	org	0
	dc.l	$7000,start
	rept	254
	dc.l	fail
	endr

	org	$400
start:
	move.w	#$2700,sr
	move.l	#$0000c040,d0	; DTT0: $00xxxxxx cache inhibited (precise)
	movec	d0,dtt0
	move.l	#$a0808000,d0	; EDC, ESB, EBC, EIC
	movec	d0,cacr
	move.w	(CNT32).l,d6	; (the count before)

;---------------------------------------------------------------- 1
	lea	(CHIP).l,a0
	move.l	#$11223344,(a0)
	move.l	#$55667788,4(a0)
	move.l	#$99aabbcc,8(a0)
	move.l	(a0),d0
	ck	d0,#$11223344,1
	move.l	4(a0),d0
	ck	d0,#$55667788,2
	moveq	#0,d0
	move.w	(a0),d0
	ck	d0,#$1122,3
	move.w	2(a0),d0
	ck	d0,#$3344,4
	move.w	10(a0),d0
	ck	d0,#$bbcc,5
	moveq	#0,d0
	move.b	1(a0),d0
	ck	d0,#$22,6
	move.b	7(a0),d0
	ck	d0,#$88,7

;---------------------------------------------------------------- 2
	move.w	#$abcd,2(a0)	; the low half of the first long word
	move.b	#$ee,4(a0)	; the top byte of the second
	move.l	(a0),d0
	ck	d0,#$1122abcd,10
	move.l	4(a0),d0
	ck	d0,#$ee667788,11

;---------------------------------------------------------------- 3
	move.l	#$deadbeef,14(a0)	; A1 set: two word cycles
	move.l	14(a0),d0
	ck	d0,#$deadbeef,20
	moveq	#0,d0
	move.w	14(a0),d0
	ck	d0,#$dead,21
	move.w	16(a0),d0
	ck	d0,#$beef,22
	move.l	12(a0),d0
	and.l	#$0000ffff,d0
	ck	d0,#$dead,23

;---------------------------------------------------------------- 4
	lea	(CHIP+$100).l,a0
	move.l	#$01020304,d1
	moveq	#63,d2
fill:	move.l	d1,(a0)+
	add.l	#$04040404,d1
	dbra	d2,fill
	lea	(CHIP+$100).l,a0
	lea	(BUF2).l,a1
	moveq	#63,d2
copy:	move.l	(a0)+,(a1)+
	dbra	d2,copy
	lea	(BUF2).l,a1
	move.l	#$01020304,d1
	moveq	#63,d2
cmp1:	move.l	(a1)+,d0
	cmp.l	d1,d0
	beq.s	cmp1ok
	move.w	#30,($f100).l
	bra.w	fail
cmp1ok:	add.l	#$04040404,d1
	dbra	d2,cmp1
	; MOVEM.L of 8 registers to chip RAM and back
	move.l	#$a1a2a3a4,d0
	move.l	#$b1b2b3b4,d1
	move.l	#$c1c2c3c4,d2
	move.l	#$d1d2d3d4,d3
	move.l	#$e1e2e3e4,d4
	move.l	#$f1f2f3f4,d5
	move.l	#$01234567,a2
	move.l	#$89abcdef,a3
	lea	(CHIP+$400).l,a0
	movem.l	d0-d5/a2-a3,(a0)
	moveq	#0,d0
	moveq	#0,d1
	moveq	#0,d2
	moveq	#0,d3
	moveq	#0,d4
	moveq	#0,d5
	suba.l	a2,a2
	suba.l	a3,a3
	movem.l	(a0),d0-d5/a2-a3
	ck	d0,#$a1a2a3a4,31
	ck	d1,#$b1b2b3b4,32
	ck	d4,#$e1e2e3e4,33
	ck	d5,#$f1f2f3f4,34
	ck	a2,#$01234567,35
	ck	a3,#$89abcdef,36
	moveq	#0,d0
	move.w	30(a0),d0	; the last register's low word
	ck	d0,#$cdef,37

;---------------------------------------------------------------- 5
	move.l	#$12345678,($8000).l
	move.l	($8000).l,d0
	ck	d0,#$12345678,40
	move.w	#1,($f120).l	; the bench inverts $8000.l
	tst.w	($f100).l	; (the posted write is done)
	move.l	($8000).l,d0
	ck	d0,#$edcba987,41

;---------------------------------------------------------------- 6
	lea	(CHIP+$800).l,a0
	lea	(CHIP+$900).l,a1
	moveq	#15,d2
	move.l	#$10000001,d1
mix:	move.l	d1,(a0)+	; a long word ...
	move.w	d2,(a1)+	; ... a word elsewhere
	move.b	d2,(a1)+	; ... and a byte
	addq.l	#1,a1
	add.l	#$01000001,d1
	dbra	d2,mix
	lea	(CHIP+$800).l,a0
	lea	(CHIP+$900).l,a1
	moveq	#15,d2
	move.l	#$10000001,d1
mixck:	move.l	(a0)+,d0
	cmp.l	d1,d0
	bne.s	mixbad
	moveq	#0,d0
	move.w	(a1)+,d0
	cmp.w	d2,d0
	bne.s	mixbad
	move.b	(a1)+,d0
	cmp.b	d2,d0
	bne.s	mixbad
	addq.l	#1,a1
	add.l	#$01000001,d1
	dbra	d2,mixck
	bra.s	mixok
mixbad:	move.w	#50,($f100).l
	bra.w	fail
mixok:

;---------------------------------------------------------------- 7
	tst.w	(ON32).l
	beq.s	no32
	move.w	(CNT32).l,d0
	sub.w	d6,d0
	cmp.w	#100,d0		; well over 100 aligned long words above
	bhs.s	no32
	move.w	#60,($f100).l
	bra.w	fail
no32:
	move.w	#$600D,($f102).l
done:	bra.s	done
fail:	move.w	#$BAD0,($f102).l
	bra.s	done
