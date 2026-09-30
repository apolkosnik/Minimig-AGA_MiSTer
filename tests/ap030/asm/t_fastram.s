; AP030 Fast RAM: the 32-bit synchronous port (ap030_fastram_fe/_be) with
; burst fills, on Zorro II RAM enabled through autoconfig
; assembled with vasmm68k_mot -Fbin -m68030
;
; Runs from chip RAM; the bench (tb_ap030_wrapchip.sv, FASTRAM=1) offers a
; 2 MB Zorro II memory card and serves it from a DDR3 model.
;
;   - autoconfig: the card is configured by writing its base register
;   - every operand size at every alignment, crossing 64-bit DDR3 words and
;     16-byte lines, written and read back (caches off: every access is a
;     bus cycle)
;   - a 4 KB address-pattern fill and verify, caches off and on (bursts)
;   - a routine copied to Fast RAM and executed there (instruction bursts)
;   - writes updating buffered and cached lines; RMW (TAS, CAS); MOVEM
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

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400		; initial ISP
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	moveq	#0,d0
	movec	d0,cacr

;---------------------------------------------------------------- autoconfig
	move.b	#$20,$E80048		; Zorro II memory card: configure (base $200000)
	lea	FAST,a0
	move.l	#$A5A5F00D,(a0)
	move.l	(a0),d0
	chkl	d0,$A5A5F00D,1

;---------------------------------------------------------------- sizes and alignments
	lea	FAST+$100,a0
	moveq	#0,d0
	moveq	#15,d1
clr1:	move.l	d0,(a0)+
	dbf	d1,clr1
	lea	FAST+$100,a0
	move.l	#$11223344,(a0)		; aligned long
	move.l	#$55667788,5(a0)	; +5: crosses a longword
	move.l	#$99AABBCC,$E(a0)	; +$E: crosses the 64-bit DDR3 word and nothing else
	move.l	#$DDEEFF00,$1E(a0)	; +$1E: crosses a 16-byte line
	move.w	#$1234,$29(a0)		; odd word
	move.b	#$56,$2C(a0)
	move.b	#$78,$2D(a0)
	move.b	#$9A,$2E(a0)
	move.b	#$BC,$2F(a0)
	move.w	#$DEF0,$32(a0)
	move.l	(a0),d0
	chkl	d0,$11223344,2
	move.l	4(a0),d0
	chkl	d0,$00556677,3
	move.l	8(a0),d0
	chkl	d0,$88000000,4
	move.l	$C(a0),d0
	chkl	d0,$000099AA,5
	move.l	$10(a0),d0
	chkl	d0,$BBCC0000,6
	move.l	$1C(a0),d0
	chkl	d0,$0000DDEE,7
	move.l	$20(a0),d0
	chkl	d0,$FF000000,8
	move.l	$28(a0),d0
	chkl	d0,$00123400,9
	move.l	$2C(a0),d0
	chkl	d0,$56789ABC,10
	move.l	$30(a0),d0
	chkl	d0,$0000DEF0,11
	move.l	5(a0),d0		; misaligned reads
	chkl	d0,$55667788,12
	move.l	$E(a0),d0
	chkl	d0,$99AABBCC,13
	move.l	$1E(a0),d0
	chkl	d0,$DDEEFF00,14
	move.w	$29(a0),d0
	and.l	#$FFFF,d0
	chkl	d0,$1234,15
	move.b	$2F(a0),d0
	and.l	#$FF,d0
	chkl	d0,$BC,16
	; a byte write into a line the read buffer holds
	move.l	$2C(a0),d0
	move.b	#$11,$2D(a0)
	move.l	$2C(a0),d0
	chkl	d0,$56119ABC,17

;---------------------------------------------------------------- pattern fill, caches off
	bsr	fill4k
	bsr	verify4k
	tst.l	d0
	beq.s	v1ok
	failt	20
v1ok:

;---------------------------------------------------------------- caches on: bursts
	move.l	#$3111+$808,d0		; clear, then enable both caches with bursts and WA
	movec	d0,cacr
	move.l	#$3111,d0
	movec	d0,cacr
	bsr	verify4k		; data cache fills by bursts
	tst.l	d0
	beq.s	v2ok
	failt	21
v2ok:
	not.l	d5			; a different pattern over the cached data
	bsr	fill4k
	bsr	verify4k
	tst.l	d0
	beq.s	v3ok
	failt	22
v3ok:
	; a write hit updates the cached line and Fast RAM; clearing the cache
	; and reading again must find the same value in memory
	lea	FAST+$1000,a0
	move.l	(a0),d0
	move.w	#$CAFE,2(a0)
	move.l	(a0),d1
	move.l	#$3111+$800,d0		; CD: clear the data cache
	movec	d0,cacr
	move.l	(a0),d2
	cmp.l	d1,d2
	beq.s	wcok
	failt	23
wcok:
	and.l	#$FFFF,d2
	chkl	d2,$CAFE,24

;---------------------------------------------------------------- code in Fast RAM
	lea	fastcode(pc),a0
	lea	FAST+$8000,a1
	moveq	#(fastcode_end-fastcode)/2-1,d0
cpy:	move.w	(a0)+,(a1)+
	dbf	d0,cpy
	move.l	#$3111+$8,d0		; CI: the copy went through the data side
	movec	d0,cacr
	moveq	#0,d0
	jsr	FAST+$8000
	chkl	d0,$0000F00D,30
	moveq	#0,d0
	jsr	FAST+$8000		; again, from the instruction cache
	chkl	d0,$0000F00D,31

;---------------------------------------------------------------- RMW and MOVEM
	lea	FAST+$2000,a0
	move.b	#$05,(a0)
	tas	(a0)
	move.b	(a0),d0
	and.l	#$FF,d0
	chkl	d0,$85,40
	move.l	#$12345678,4(a0)
	move.l	#$12345678,d1
	move.l	#$0BADCAFE,d2
	cas.l	d1,d2,4(a0)
	beq.s	casok
	failt	41
casok:
	move.l	4(a0),d0
	chkl	d0,$0BADCAFE,42
	movem.l	d0-d7/a0-a6,-(sp)
	lea	FAST+$3000,a1
	move.l	#$01010101,d0
	move.l	d0,d1
	add.l	d0,d1
	move.l	d1,d2
	add.l	d0,d2
	move.l	d2,d3
	add.l	d0,d3
	move.l	d3,d4
	add.l	d0,d4
	movem.l	d0-d4,(a1)		; 20 bytes: bursts on the way back
	moveq	#0,d0
	moveq	#0,d1
	moveq	#0,d2
	moveq	#0,d3
	moveq	#0,d4
	move.l	#$3111+$800,d5
	movec	d5,cacr
	movem.l	(a1),d0-d4
	add.l	d0,d1
	add.l	d1,d2
	add.l	d2,d3
	add.l	d3,d4
	cmp.l	#$0F0F0F0F,d4
	movem.l	(sp)+,d0-d7/a0-a6
	beq.s	mmok
	failt	43
mmok:

	move.w	#$600D,DONEREG
	stop	#$2700

;---------------------------------------------------------------- helpers
; fill4k: FAST+$1000.. with address ^ d5 (1024 longwords)
fill4k:
	lea	FAST+$1000,a0
	move.w	#1023,d1
f4:	move.l	a0,d0
	eor.l	d5,d0
	move.l	d0,(a0)+
	dbf	d1,f4
	rts
; verify4k: d0 = 0 when all match
verify4k:
	lea	FAST+$1000,a0
	move.w	#1023,d1
v4:	move.l	a0,d0
	eor.l	d5,d0
	cmp.l	(a0)+,d0
	bne.s	v4bad
	dbf	d1,v4
	moveq	#0,d0
	rts
v4bad:	moveq	#1,d0
	rts

; copied to Fast RAM and executed there
fastcode:
	moveq	#0,d0
	move.w	#$F000,d0
	add.w	#$000D,d0
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	rts
fastcode_end:

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
halt1:	bra.s	halt1

unexp:
	move.w	#$00FF,FAILREG
	move.w	#$BAD0,DONEREG
halt2:	bra.s	halt2
