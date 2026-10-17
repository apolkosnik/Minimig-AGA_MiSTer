; AP020 on Minimig: Kickstart 3.2's Supervisor() frame build on a stack in
; Fast RAM (the native port), as captured on the board with the AP030:
;
;	subq.l	#8,a7
;	move.w	sr,(a7)
;	move.l	#$F80CC0,2(a7)
;	move.w	#$20,6(a7)
;	btst	#5,(a7)		; the stacked S bit must read back set
;
; followed by the scheduler's MOVEM push/pop below the frame.  Repeated at
; every word alignment of A7 across a 16-byte line, with the caches off,
; with CACR $0001 (E: Kickstart's boot setting) and $0009 (E, C).
; assembled with vasmm68k_mot -Fbin -m68020
;
; protocol with the bench:
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed

FAILREG	equ	$F100
DONEREG	equ	$F102
FAST	equ	$200000

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	moveq	#0,d0
	movec	d0,cacr
	move.b	#$20,$E80048		; Zorro II memory card at $200000
	lea	cacrs(pc),a3
	moveq	#2,d6			; three CACR settings
next_cacr:
	move.l	(a3)+,d0
	movec	d0,cacr
	moveq	#0,d5			; A7 offset 0..14 in words
next_off:
	move.l	a7,a4
	lea	FAST+$1020,a7
	suba.l	d5,a7
	; poison the frame area first (a stale line must not show through)
	move.l	#$DEADBEEF,-8(a7)
	move.l	#$DEADBEEF,-4(a7)
	move.w	#$2710,sr
	subq.l	#8,a7
	move.w	sr,(a7)
	move.l	#$00F80CC0,2(a7)
	move.w	#$20,6(a7)
	btst	#5,(a7)
	bne.s	s_ok
	move.l	a4,a7
	failt	1
s_ok:
	movem.l	d0-d1/a0-a1/a5-a6,-(a7)
	move.w	#$2700,sr
	movem.l	(a7)+,d0-d1/a0-a1/a5-a6
	move.w	(a7),d0
	move.l	2(a7),d1
	move.w	6(a7),d2
	move.l	a4,a7
	cmp.w	#$2710,d0
	beq.s	w0
	failt	2
w0:	cmp.l	#$00F80CC0,d1
	beq.s	w1
	failt	3
w1:	cmp.w	#$0020,d2
	beq.s	w2
	failt	4
w2:	addq.l	#2,d5
	cmp.l	#16,d5
	bne	next_off
	dbf	d6,next_cacr

;---------------------------------------------------------------- from the instruction cache
; Kickstart runs this from cacheable ROM: the code is copied to Fast RAM
; (cacheable, native port) and called with the caches on, so the
; instructions issue back to back; the supervisor stack is in Fast RAM
	lea	fsub(pc),a0
	lea	FAST+$8000,a1
	moveq	#(fsub_end-fsub)/2-1,d0
cpy:	move.w	(a0)+,(a1)+
	dbf	d0,cpy
	move.l	#$0009,d0		; caches on, cleared (the copy went through the data side)
	movec	d0,cacr
	moveq	#7,d6			; several passes: the first ones fill the cache
	moveq	#0,d5			; A7 offset in words
fpass:
	move.l	a7,a4
	lea	FAST+$1100,a7
	suba.l	d5,a7
	move.l	#$11111111,-4(a7)
	move.l	#$DEADBEEF,-12(a7)
	jsr	FAST+$8000		; pushes the return address at A7-4
	move.l	a4,a7
	cmp.w	#$2710,d0		; the SR word of the frame
	beq.s	fq1
	failt	5
fq1:	cmp.l	#$00F80CC0,d1
	beq.s	fq2
	failt	6
fq2:	addq.l	#2,d5
	and.l	#14,d5
	dbf	d6,fpass

; and as Kickstart does: from the ROM window ($F8xxxx, cacheable, reached
; through the 16-bit asynchronous port; the bench mirrors its memory there)
	moveq	#7,d6
	moveq	#0,d5
rpass:
	move.l	a7,a4
	lea	FAST+$1100,a7
	suba.l	d5,a7
	move.l	#$11111111,-4(a7)
	jsr	$F80000+fsub
	move.l	a4,a7
	cmp.w	#$2710,d0
	beq.s	fq3
	failt	7
fq3:	cmp.l	#$00F80CC0,d1
	beq.s	fq4
	failt	8
fq4:	addq.l	#2,d5
	and.l	#14,d5
	dbf	d6,rpass
	moveq	#0,d0
	movec	d0,cacr
	move.w	#$600D,DONEREG
	stop	#$2700

cacrs:	dc.l	$00000000,$00000001,$00000009

; copied to Fast RAM: Kickstart's Supervisor() frame build after a call
fsub:
	move.w	#$2710,sr
	ori.w	#$2000,sr
	subq.l	#8,a7
	move.w	sr,(a7)
	move.l	#$00F80CC0,2(a7)
	move.w	#$20,6(a7)
	move.w	(a7),d0
	move.l	2(a7),d1
	addq.l	#8,a7
	move.w	#$2700,sr
	rts
fsub_end:

fail_all:
	moveq	#0,d0
	movec	d0,cacr
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
fa:	bra.s	fa

unexp:
	move.w	#$FF,d7
	bra	fail_all
