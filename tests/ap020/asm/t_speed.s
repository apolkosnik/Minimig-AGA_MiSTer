; AP020 on Minimig: the speed limiter (cpu_cycles on the processor's own
; events, ap020_tg68k_compat).  Two timed loops, each between the bench's
; marks ($F1AC start, $F1AE stop): the bench checks that a limited mode
; never runs the processor ahead of the speed the limiter charges, runs it
; exactly at that speed where the processor sets the pace (start mark 1:
; charged and elapsed target cycles agree, the processor is held), and that
; the 68020 mode is never held.
;   1  a register loop from the instruction cache (ADDQ, DBF): mark 1
;   2  word reads from chip RAM in a loop: mark 2, the chip bus may be
;      slower than the modelled machine's
; assembled with vasmm68k_mot -Fbin -m68020
;
; bench (tb_ap020_wrapchip.sv) control ports:
;   $F100 failing test number, $F102 $600D/$BAD0
;   $F1AC start mark (1: processor bound, 2: bus bound), $F1AE stop mark

FAILREG	equ	$F100
DONEREG	equ	$F102
MSTART	equ	$F1AC
MSTOP	equ	$F1AE

	org	0
	dc.l	$8000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#$0008,d0		; C: clear the instruction cache
	movec	d0,cacr
	move.l	#$0001,d0		; E
	movec	d0,cacr

;---------------------------------------------------------------- 1: register loop, cached
	moveq	#0,d0
	move.w	#199,d1
l1w:	addq.l	#1,d0			; a first pass fills the cache
	dbf	d1,l1w
	moveq	#0,d0
	move.w	#1999,d1
	move.w	#1,MSTART		; the processor sets the pace
l1:	addq.l	#1,d0
	dbf	d1,l1
	move.w	#1,MSTOP
	cmp.l	#2000,d0
	beq.s	t2
	move.w	#1,FAILREG
	bra	fail_all

;---------------------------------------------------------------- 2: chip RAM word reads
t2:	lea	$6000,a0
	move.w	#$1234,(a0)
	move.w	#499,d1
	moveq	#0,d2
	move.w	#2,MSTART		; the chip bus may set it
l2:	add.w	(a0),d2
	dbf	d1,l2
	move.w	#1,MSTOP
	cmp.w	#$8D90,d2		; 500 x $1234, low word
	beq.s	tend
	move.w	#2,FAILREG
	bra	fail_all

tend:	move.w	#$600D,DONEREG
	stop	#$2700

fail_all:
	move.w	#$BAD0,DONEREG
halt1:	bra.s	halt1

unexp:	move.w	#$00FF,FAILREG
	move.w	#$BAD0,DONEREG
halt2:	bra.s	halt2
