; t_icache_pipe.s - plan M14: the pipelined instruction read path (a read-
; only copy of the I-cache bank answering IF the clock after a fetch issues,
; ap040_cache.v g_ifp + ap040_pipe_tg68k_compat.v ia_ok).  Runs under
; tb_ap040_pipe_compat.v (cache_allow_all = 1: everything cacheable).
; Protocol: $F100 = failing check, $F102 = $600D / $BAD0.
;
; Each check puts a routine in the I-cache, rewrites it in memory, and asks
; for the NEW code in a situation where the 68040 must fetch it from memory
; (or from a line refilled from memory).  A read path that answers from its
; copy when it should not returns the OLD code, which is what the checks
; look for.  (Running stale code after a store WITHOUT CINV/CPUSH is the
; 68040's behaviour, M68040UM 4.x, and is not checked either way.)
;
;   1  CPUSHA IC after the rewrite: the new code runs (the copy's valid
;      bits must follow the CINV sweep)
;   2  CINVA IC, the same
;   9  as 1 in the first KB, where the physical tag is 0 (the sweep zeroes the
;      copy's tags too, so only a tag-0 line shows a stale valid bit)
;   3  CACR.IE cleared: fetches bypass the cache, the new code runs
;   4  an ITT0 with CM = cache-inhibited over the code: the new code runs
;  17  the same fetch again, now through the read path's instruction-ATC copy
;  10  logical page 3 remapped to physical $6000 and PFLUSHA: the ATC copy
;      must follow atc_v, not keep the old translation
;   8  the inhibited fetch in 4 hit a resident line and invalidated it (the
;      cache's CI-hit rule, a port-B row write): with the ITT gone and no
;      CINV, the next fetch misses and refills -- the new code runs
;   5  TC.E = 1 with logical page $3000 mapped to physical $4000: the code at
;      PHYSICAL $4000 runs, not the line cached for physical $3000
;   6  after all that, with everything back on, a routine runs from the
;      cache again (the path still answers)
;   7  a longer routine across several lines and sets, called repeatedly,
;      returns the right sum (plain hits, word and longword fetch halves)

FAILREG	equ	$F100
DONEREG	equ	$F102
R	equ	$23C0		; the rewritten routine: set $3C, which no code of this program shares (a refill of its row would re-mirror the whole row and hide a stale valid bit)
R0	equ	$03C0		; set $3C with physical tag 0 (vector 240: unused)
R3	equ	$3000		; logical page 3 (physical $3000 with TC off)
R4	equ	$4000		; physical page 4
R6	equ	$6000		; physical page 6
ROOT	equ	$5000
PTR	equ	$5200
PAGE	equ	$5400
CACR_ON	equ	$80008000

MQ	macro			; \1 = moveq #\1,d0 ; rts as one longword
	dc.w	$7000+\1,$4e75
	endm

chkd0	macro			; d0 must be \1, else fail \2
	cmp.l	#\1,d0
	beq.s	.ok\@
	move.w	#\2,d7
	bra	fail_all
.ok\@:
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

; 1: CPUSHA IC
	move.l	#$70014e75,R
	jsr	R
	chkd0	1,11
	move.l	#$70024e75,R
	cpusha	ic
	jsr	R
	chkd0	2,1

; 2: CINVA IC
	jsr	R			; (cached again)
	move.l	#$70034e75,R
	cinva	ic
	jsr	R
	chkd0	3,2

; 9: the same in the first KB (physical tag 0): the CINV sweep zeroes the
;    copy's TAGS as well, so a valid bit it failed to clear is only visible
;    to a line whose tag IS zero (vector 240's slot, unused here)
	move.l	#$70094e75,R0
	cpusha	ic
	jsr	R0
	chkd0	9,19
	move.l	#$700a4e75,R0
	cpusha	ic
	jsr	R0
	chkd0	$a,9

; 3: CACR.IE clear
	jsr	R			; cached: moveq #3
	move.l	#$80000000,d0		; DE only
	movec	d0,cacr
	move.l	#$70044e75,R
	jsr	R
	chkd0	4,3
	move.l	#CACR_ON,d0
	movec	d0,cacr
	cpusha	ic

; 4: ITT0 cache-inhibited over $00xxxxxx
	jsr	R			; cached: moveq #4
	move.l	#$0000c040,d0		; base $00 mask $00, E, S ignored, CM = 10
	movec	d0,itt0
	move.l	#$70054e75,R
	jsr	R
	chkd0	5,4
	moveq	#0,d0
	movec	d0,itt0
	jsr	R			; the inhibited fetch invalidated the line: refill
	chkd0	5,8
	cpusha	ic

; 5: TC.E = 1, logical $3000 -> physical $4000
	move.l	#$70064e75,R3		; physical $3000: moveq #6
	move.l	#$70074e75,R4		; physical $4000: moveq #7
	move.l	#$70084e75,R6		; physical $6000: moveq #8
	cpusha	bc
	jsr	R3			; TC off: caches the line at physical $3000
	chkd0	6,15
	lea	ROOT,a0			; root entry 0 -> pointer table
	move.l	#PTR|3,(a0)
	lea	PTR,a0			; pointer entry 0 -> page table
	move.l	#PAGE|3,(a0)
	lea	PAGE,a0			; 4K pages 0-15 identity, resident ...
	moveq	#0,d0
	moveq	#15,d1
.pt:	move.l	d0,d2
	or.l	#1,d2
	move.l	d2,(a0)+
	add.l	#$1000,d0
	dbra	d1,.pt
	move.l	#R4|1,PAGE+3*4		; ... except logical page 3 -> physical $4000
	move.l	#ROOT,d0
	movec	d0,srp
	movec	d0,urp
	pflusha
	move.l	#$8000,d0		; E, 4K pages
	movec	d0,tc
	jsr	R3			; logical $3000 = physical $4000
	chkd0	7,5
	jsr	R3			; again: the read path's ATC copy translates it
	chkd0	7,17
	move.l	#R6|1,PAGE+3*4		; remap logical page 3 -> physical $6000
	pflusha				; (the ATC copy must follow atc_v)
	jsr	R3
	chkd0	8,10
	moveq	#0,d0
	movec	d0,tc
	pflusha
	cpusha	ic

; 6: the path still answers once everything is back on
	jsr	R3			; physical $3000 again (TC off)
	chkd0	6,6
	jsr	R3
	chkd0	6,16

; 7: a multi-line routine, called several times
	moveq	#9,d6
	moveq	#0,d5
.l7:	bsr	sum
	add.l	d0,d5
	dbra	d6,.l7
	cmp.l	#10*SUMV,d5
	beq.s	.ok7
	move.w	#7,d7
	bra	fail_all
.ok7:

	move.w	#$600d,DONEREG
.h:	bra.s	.h

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f

unexp:	move.w	#99,d7
	bra.s	fail_all

; 40 bytes of mixed-length instructions per step, 12 steps: crosses sets and
; lines and exercises word-aligned (one-word) fetch answers after branches
	cnop	0,16
	dc.w	$4e71			; misalign the entry by a word
sum:	moveq	#0,d0
	rept	12
	addq.l	#1,d0
	add.l	#$100,d0
	nop
	bra.s	*+4
	dc.w	$4afc			; (skipped: ILLEGAL if a fetch returned garbage)
	addi.w	#$10,d0
	move.l	d0,d1
	add.l	d1,d0
	lsr.l	#1,d0
	endr
	rts
SUMV	equ	12*($1+$100+$10)
