; AP020 on the Minimig CPU bus (ap020_tg68k_compat + cpu_wrapper)
; assembled with vasmm68k_mot -Fbin -m68020
;
; Covers what the adapter itself decides:
;   - byte lanes of the 16-bit port: bytes, words and longwords at every
;     alignment, written and read back (the 68020 splits them, UM 5.2)
;   - interrupt acknowledge: autovectored (vector 24 + level)
;   - CPU space cycles other than IACK end in BERR: a coprocessor
;     instruction takes the F-line exception, BKPT the illegal one
;   - the RESET instruction completes and execution continues
;   - ROM ($F80000, the bench mirrors its memory there) with the caches
;     on: the port answers as a 32-bit port and delivers each operand's
;     bytes at every size and alignment (pin-bus data is not cached)
;
; protocol with the bench (tb_ap020_wrapchip.sv):
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed
;   word write to $F110 = interrupt request level (0 releases)

FAILREG	equ	$F100
DONEREG	equ	$F102
IPLREG	equ	$F110

exccnt	equ	$3000		; word: exceptions taken
lastvec	equ	$3002		; word: vector number of the last exception
lastpc	equ	$3004		; long: stacked PC of the last exception
skip	equ	$3008		; long: added to the stacked PC by the handler
buf	equ	$3100		; test data

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

chkw	macro
	move.w	\1,d6
	and.l	#$FFFF,d6
	cmp.l	#\2,d6
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400		; initial ISP
	dc.l	start
	rept	254
	dc.l	h_exc		; every vector: record and return
	endr

	org	$400
start:
	clr.w	exccnt
	clr.l	skip

;---------------------------------------------------------------- byte lanes
	lea	buf,a0
	move.l	#$11223344,(a0)		; aligned long: two word cycles
	move.l	#$55667788,5(a0)	; odd long: byte, word, byte
	move.w	#$99AA,11(a0)		; odd word: two byte cycles
	move.b	#$BB,14(a0)		; even byte (UDS)
	move.b	#$CC,15(a0)		; odd byte (LDS)
	move.l	(a0),d0
	chkl	d0,$11223344,1
	move.l	4(a0),d0
	chkl	d0,$00556677,2
	move.l	8(a0),d0
	chkl	d0,$88000099,3
	move.l	12(a0),d0
	chkl	d0,$AA00BBCC,4
	move.l	5(a0),d0		; misaligned reads
	chkl	d0,$55667788,5
	move.w	11(a0),d0
	chkw	d0,$99AA,6
	move.b	15(a0),d0
	and.l	#$FF,d0
	chkl	d0,$CC,7
	move.b	14(a0),d0
	and.l	#$FF,d0
	chkl	d0,$BB,8
	; MOVEP: alternate bytes on one lane
	move.l	#$D1D2D3D4,d1
	movep.l	d1,17(a0)		; odd: LDS only
	move.l	16(a0),d0
	chkl	d0,$00D100D2,9
	move.l	20(a0),d0
	chkl	d0,$00D300D4,10
	; read-modify-write
	move.b	#$05,24(a0)
	tas	24(a0)
	move.b	24(a0),d0
	and.l	#$FF,d0
	chkl	d0,$85,11

;---------------------------------------------------------------- interrupts: autovectors
	move.w	#$2000,sr		; mask 0
	move.w	#3,IPLREG		; level 3 request
	nop
	nop
	nop
	chkw	exccnt,1,20
	chkw	lastvec,27,21		; 24 + 3
	move.w	#$2500,sr		; mask 5: a level 4 request waits
	move.w	#4,IPLREG
	nop
	nop
	chkw	exccnt,1,22
	move.w	#$2300,sr		; mask 3: now it is taken
	nop
	nop
	chkw	exccnt,2,23
	chkw	lastvec,28,24
	move.w	#$2700,sr

;---------------------------------------------------------------- CPU space: no coprocessor
	move.l	#4,skip			; FMOVE is two words
fl1:	fmove.l	d0,fp0			; coprocessor 1: BERR on the CIR -> F-line
	chkw	exccnt,3,30
	chkw	lastvec,11,31
	move.l	lastpc,d0
	chkl	d0,fl1,32
	move.l	#2,skip
bk1:	bkpt	#1			; breakpoint acknowledge: BERR -> illegal
	chkw	exccnt,4,33
	chkw	lastvec,4,34
	move.l	lastpc,d0
	chkl	d0,bk1,35
	clr.l	skip

;---------------------------------------------------------------- ROM, caches on
	move.l	#$0008,d0		; C: clear the cache
	movec	d0,cacr
	move.l	#$0001,d0		; E
	movec	d0,cacr
	lea	$F80000+romtab,a0
	moveq	#0,d0
	move.b	1(a0),d0		; byte 1
	chkl	d0,$22,50
	move.l	(a0),d0
	chkl	d0,$11223344,51
	moveq	#0,d0
	move.w	6(a0),d0		; word at offset 2
	chkl	d0,$7788,52
	move.l	4(a0),d0
	chkl	d0,$55667788,53
	moveq	#0,d0
	move.b	11(a0),d0		; byte 3
	chkl	d0,$CC,54
	move.l	8(a0),d0
	chkl	d0,$99AABBCC,55
	moveq	#0,d0
	move.w	12(a0),d0		; word at offset 0
	chkl	d0,$DDEE,56
	move.l	12(a0),d0
	chkl	d0,$DDEEFF01,57
	move.l	#$0008,d0
	movec	d0,cacr

;---------------------------------------------------------------- RESET instruction
	reset
	moveq	#42,d0
	chkl	d0,42,40

	move.w	#$600D,DONEREG
	stop	#$2700

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
halt1:	bra.s	halt1

;---------------------------------------------------------------- handler
; frame: 0(sp) SR, 2(sp) PC, 6(sp) format/vector
h_exc:
	movem.l	d6/a6,-(sp)
	lea	8(sp),a6
	move.w	6(a6),d6
	and.w	#$0FFF,d6
	lsr.w	#2,d6
	move.w	d6,lastvec
	move.l	2(a6),lastpc
	addq.w	#1,exccnt
	cmp.w	#24,d6			; an interrupt: release the request
	blo.s	h_noirq
	cmp.w	#31,d6
	bhi.s	h_noirq
	move.w	#0,IPLREG
h_noirq:
	move.l	skip,d6
	add.l	d6,2(a6)
	movem.l	(sp)+,d6/a6
	rte

	cnop	0,4
romtab:	dc.l	$11223344,$55667788,$99AABBCC,$DDEEFF01
