; AP020 on the Minimig CPU bus: Gayle IDE data transfers through the real
; cpu_wrapper, fastchip, gayle and ide modules.
; assembled with vasmm68k_mot -Fbin -m68020
;
; The bench's management side (as MiSTer's ARM would) loads one 256-word
; sector into drive 0's buffer and raises DRQ when $F1D0 is written; $F1D2
; reads nonzero once it is done.  The sector is read with 256 MOVE.W and
; again with 128 MOVE.L from the data register: the longword reads (two
; 16-bit cycles after dynamic bus sizing) must return exactly the words
; of the word reads, and the drive must finish both transfers.
;
; protocol with the bench (tb_ap020_wrapchip.sv):
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed

FAILREG	equ	$F100
DONEREG	equ	$F102
IDELOAD	equ	$F1D0
IDEDONE	equ	$F1D2
IDEDATA	equ	$DA0000
IDESTAT	equ	$DA001C		; register 7

bufw	equ	$4000		; the sector read by words
bufl	equ	$4400		; the sector read by longwords

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
	; sector by words
	bsr	load_sector
	lea	bufw,a1
	move.w	#255,d1
rdw:	move.w	IDEDATA,(a1)+
	dbf	d1,rdw
	move.b	IDESTAT,d0
	btst	#3,d0			; DRQ must be gone after 256 words
	beq.s	w_ok
	failt	1
w_ok:
	; the words must not all be the same (the pattern is loaded)
	move.w	bufw,d0
	cmp.w	bufw+2,d0
	bne.s	w_ok2
	failt	2
w_ok2:
	; word 5 of the pattern {i ^ $5A, i}, in either byte order
	move.w	bufw+10,d0
	cmp.w	#$5F05,d0
	beq.s	w_ok3
	cmp.w	#$055F,d0
	beq.s	w_ok3
	failt	4
w_ok3:
	move.w	bufw+510,d0		; the last word, i = 255
	cmp.w	#$A5FF,d0
	beq.s	w_ok4
	cmp.w	#$FFA5,d0
	beq.s	w_ok4
	failt	5
w_ok4:
	; the same sector by longwords
	bsr	load_sector
	lea	bufl,a1
	move.w	#127,d1
rdl:	move.l	IDEDATA,(a1)+
	dbf	d1,rdl
	move.b	IDESTAT,d0
	btst	#3,d0			; exactly 256 words consumed
	beq.s	l_ok
	failt	3
l_ok:
	lea	bufw,a0
	lea	bufl,a1
	move.w	#255,d1
cmp:	move.w	(a0)+,d0
	cmp.w	(a1)+,d0
	bne.s	l_bad
	dbf	d1,cmp
	move.w	#$600D,DONEREG
	stop	#$2700
l_bad:
	move.w	#255,d0
	sub.w	d1,d0
	add.w	#100,d0			; 100 + index of the first differing word
	move.w	d0,d7
	bra	fail_all

load_sector:
	clr.w	IDEDONE
	move.w	#1,IDELOAD
ls_w:	tst.w	IDEDONE
	beq.s	ls_w
	rts

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
fa:	bra.s	fa

unexp:
	move.w	#$FF,d7
	bra	fail_all
