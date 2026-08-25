; AP040 cache benchmark: loop-heavy, locality-rich workload.
;
; This is a MEASUREMENT program, not a test: it exists to answer whether
; ap040_cache earns its keep on code that a cache is supposed to help,
; as opposed to the straight-line once-through code that makes up the
; regression programs.  Run it under +prof and compare total cycles
; between the AP040_TB_CACHE=1 and AP040_TB_CACHE=0 builds.
;
; The workload is deliberately cache-friendly on both axes:
;   - instruction locality: a short inner loop executed thousands of
;     times, well inside one 4KB I-cache side
;   - data locality: a 256-byte array walked repeatedly, so every pass
;     after the first should hit in the D-cache
;
; It still verifies its own arithmetic, so a miscompiled or
; mis-cached run cannot silently report a good cycle count.
;
; assembled with vasmm68k_mot -Fbin -m68040

FAILREG	equ	$F100
DONEREG	equ	$F102

ARRAY	equ	$4000		; 256 bytes of working data
PASSES	equ	200		; outer repetitions
ELEMS	equ	64		; longwords per pass

	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	move.l	#$80008000,d0	; caches on (a no-op in the g_nocache build)
	movec	d0,cacr

;---------------------------------------------------- initialise array
	lea	(ARRAY).l,a0
	moveq	#ELEMS-1,d1
init:
	move.l	d1,(a0)+
	dbra	d1,init

;------------------------------------------------------- the workload
; sum the array PASSES times, accumulating into d2.  Both the loop body
; and the data stay resident, so with a working cache almost every
; access after the first pass is a hit.
	moveq	#0,d2
	move.w	#PASSES-1,d3
outer:
	lea	(ARRAY).l,a0
	moveq	#ELEMS-1,d1
inner:
	move.l	(a0)+,d0
	add.l	d0,d2
	dbra	d1,inner
	dbra	d3,outer

;------------------------------------------------------------- verify
; each pass sums 0..ELEMS-1 = 2016 for ELEMS=64; times 200 passes
	cmp.l	#2016*PASSES,d2
	beq.s	done
	move.w	#1,d7
	bra.s	fail_all

done:
	move.w	#$600D,(DONEREG).l
	stop	#$2700

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt1:
	bra.s	halt1

unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2
