; AP040 store benchmark: what a store costs, bracketed by $F108 stamps.
;
; This is a MEASUREMENT program, not a test (see bench_loop.s): it exists
; to put a number on move.l Dn,(An)+ before and after the posted store
; (plan X3.3), on the same bench, in the same units.  The tb prints the
; cycle count between consecutive stamps; each block is 256 instructions,
; so cycles/256 is the per-instruction cost.
;
;   stamp 1 -> 2   256 x move.l d0,(a0)+          stores, back to back
;   stamp 2 -> 3   256 x { move.l d0,(a0)+ ; addq.l #1,d0 }
;                  a store followed by register work that a posted
;                  store lets the core do while the write drains
;   stamp 3 -> 4   256 x move.l d0,d1             register control
;   stamp 4 -> 5   256 x move.l (a0)+,d0          loads, for reference
;
; The destination block is walked once first so its lines are resident
; and the stores take the write-hit update path (X3.2), as a variable
; being written in a loop would on the real machine.
;
; assembled with vasmm68k_mot -Fbin -m68040

DONEREG	equ	$F102
STAMP	equ	$F108

BLOCK	equ	$5000		; 1 KB destination block

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
	move.l	#$80008000,d0	; caches on
	movec	d0,cacr

	lea	(BLOCK).l,a0	; walk the block: lines resident
	moveq	#63,d1
warm:
	move.l	(a0)+,d0
	dbra	d1,warm

	moveq	#0,d0
	lea	(BLOCK).l,a0
	move.w	#1,(STAMP).l
	rept	256
	move.l	d0,(a0)+
	endr

	lea	(BLOCK).l,a0
	move.w	#2,(STAMP).l
	rept	256
	move.l	d0,(a0)+
	addq.l	#1,d0
	endr

	move.w	#3,(STAMP).l
	rept	256
	move.l	d0,d1
	endr

	lea	(BLOCK).l,a0
	move.w	#4,(STAMP).l
	rept	256
	move.l	(a0)+,d0
	endr

	; an ISOLATED store: enough register work behind each one for the
	; drain to finish before the next, so the number is the core's own
	; view of a store rather than the bus's throughput
	lea	(BLOCK).l,a0
	move.w	#5,(STAMP).l
	rept	256
	move.l	d0,(a0)+
	move.l	d0,d1
	move.l	d1,d2
	move.l	d2,d3
	endr
	move.w	#6,(STAMP).l

	move.w	#$600D,(DONEREG).l
	stop	#$2700

unexp:
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2
