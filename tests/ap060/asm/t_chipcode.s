; The AP68060 in Minimig: code in chip RAM in the instruction cache, kept
; coherent with chip RAM writes.  The adapter lets instruction fetches from
; chip RAM be cached (2 MB of chip RAM) and every chip RAM write reaches the
; instruction cache (sdram_ctrl's chip write slots, the snooper's side band),
; so a line the chipset rewrites -- a demo's blitter-generated code -- is
; dropped and fetched again.  The bench's DMA write ($F138.l the address,
; $F13C.w the word) writes chip RAM behind the processor and reports it as
; sdram_ctrl does (+nosnoop: not reported, and this test must fail).
;   1  a routine in chip RAM (MOVEQ #1,D0; RTS) run 200 times from the
;      cache: the sum
;   2  64 times: the DMA rewrites the MOVEQ's immediate with the pass's
;      number while the line is cached, the program waits as WaitBlit does
;      (a loop on a chip register read), then calls it: the new value
;   3  a routine the processor has not run yet, rewritten by the DMA, then
;      run: the new code
;   4  the processor's own write to chip RAM code, then CINVA as exec's
;      CacheClearU does: the new code
; The guarantee is the one a program relies on after WaitBlit: code fetched
; after a chip RAM read that completes after the write is the new code.
; (Code the front end fetched before the write, running ahead of an older
; store, is not fetched again -- the 68060's own rule for code modified
; behind it; the loop's backward branch on the read keeps it from running
; ahead into the call.)
; Data caches on with chip RAM data cache inhibited (DTT0); the instruction
; cache on, the code itself in chip RAM below $8000.

CODE	equ	$30000		; the routines, in chip RAM
CODE2	equ	$30100

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
	move.l	#$0000c040,d0	; DTT0: $00xxxxxx data cache inhibited
	movec	d0,dtt0
	move.l	#$a0808000,d0	; EDC, ESB, EBC, EIC
	movec	d0,cacr
	cinva	bc

	; the routines: MOVEQ #1,D0; RTS
	lea	(CODE).l,a0
	move.l	#$70014e75,(a0)
	lea	(CODE2).l,a0
	move.l	#$70054e75,(a0)
	cinva	ic		; (as after LoadSeg)

;---------------------------------------------------------------- 1
	moveq	#0,d1
	move.w	#199,d2
run1:	jsr	(CODE).l
	add.l	d0,d1
	dbra	d2,run1
	ck	d1,#200,1

;---------------------------------------------------------------- 2
	moveq	#2,d3		; the value the DMA puts in
	moveq	#63,d4
pass:	jsr	(CODE).l	; (the line is in the cache, with the old value)
	move.l	#CODE,($f138).l
	move.w	d3,d5
	or.w	#$7000,d5	; MOVEQ #n,D0
	move.w	d5,($f13c).l	; the DMA rewrites it
wb2:	tst.w	($f100).l	; WaitBlit: a loop on a chip register
	bmi.s	wb2		; (never set: one read)
	jsr	(CODE).l
	and.l	#$7f,d0
	cmp.l	d3,d0
	beq.s	passok
	move.w	#2,($f100).l
	bra.w	fail
passok:	addq.l	#1,d3
	and.l	#$7f,d3
	dbra	d4,pass

;---------------------------------------------------------------- 3
	move.l	#CODE2,($f138).l
	move.w	#$7009,($f13c).l	; MOVEQ #9,D0, never run before
wb3:	tst.w	($f100).l	; WaitBlit
	bmi.s	wb3
	jsr	(CODE2).l
	ck	d0,#9,3

;---------------------------------------------------------------- 4
	jsr	(CODE).l	; (cached)
	lea	(CODE).l,a0
	move.w	#$700b,(a0)	; the processor's own write: MOVEQ #11,D0
	tst.w	($f100).l
	cinva	ic
	jsr	(CODE).l
	ck	d0,#11,4

	move.w	#$600D,($f102).l
done:	bra.s	done
fail:	move.w	#$BAD0,($f102).l
	bra.s	done
