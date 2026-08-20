; AP040 milestone C integer ISA self test
; assembled with vasmm68k_mot -Fbin -m68040
;
; protocol with the testbench:
;   word write to $F100 = failing test number
;   word write to $F102 = $BAD0 on failure, $600D when all tests passed
;
; the program is fully self checking; expected values are encoded inline

FAILREG	equ	$F100
DONEREG	equ	$F102

; fail with test number \1
failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

; compare register \1 (long) against \2, fail with number \3
chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

; compare CCR (via MOVE from CCR) against \1, fail with number \2
chkccr	macro
	move.w	ccr,d6
	andi.w	#$1F,d6
	cmp.w	#\1,d6
	beq.s	ok\@
	failt	\2
ok\@:
	endm

	org	0
	dc.l	$3400		; initial ISP
	dc.l	start		; initial PC
	rept	254
	dc.l	unexp		; vectors 2-255: unexpected
	endr

	org	$400
start:
;------------------------------------------------- run cache-hot (P1)
; The whole integer battery executes with both internal caches enabled:
; every test after this point doubles as I/D-cache-hit coverage.  The
; caches are write-through with invalidate-on-write, so no test below
; needs cache maintenance.
	move.l	#$80008000,d0
	movec	d0,cacr

;----------------------------------------------------------------- moveq
	moveq	#-1,d0
	chkl	d0,$FFFFFFFF,1
	moveq	#0,d0
	chkccr	$04,2		; Z only

;----------------------------------------------------------------- add/sub flags
	move.l	#$7FFFFFFF,d0
	add.l	#1,d0
	chkccr	$0A,3		; N V
	chkl	d0,$80000000,4

	moveq	#0,d0
	subq.l	#1,d0
	chkccr	$19,5		; X N C
	chkl	d0,$FFFFFFFF,6

	move.w	#$FFFF,d0
	add.w	#1,d0
	chkccr	$15,7		; X Z C (word wraps to 0)

;----------------------------------------------------------------- addx/subx
	move.w	#$14,ccr	; X=1 Z=1
	moveq	#0,d0
	moveq	#0,d1
	addx.l	d1,d0
	chkccr	$00,9		; result nonzero clears sticky Z
	chkl	d0,1,8

	move.w	#$04,ccr	; X=0 Z=1
	moveq	#0,d1
	moveq	#0,d2
	addx.l	d2,d1
	chkccr	$04,10		; zero result keeps sticky Z

	move.w	#$10,ccr	; X=1 Z=0
	moveq	#0,d0
	negx.l	d0
	chkccr	$19,12		; X N C
	chkl	d0,$FFFFFFFF,11

;----------------------------------------------------------------- logic
	move.w	#0,ccr
	move.l	#$F0F0F0F0,d0
	and.l	#$0FF00FF0,d0
	chkl	d0,$00F000F0,13
	or.l	#$0F000F00,d0
	chkl	d0,$0FF00FF0,14
	eor.l	#$FFFFFFFF,d0
	chkl	d0,$F00FF00F,15
	not.l	d0
	chkl	d0,$0FF00FF0,16
	move.w	#0,ccr
	clr.l	d0
	chkccr	$04,17

;----------------------------------------------------------------- neg
	move.w	#0,ccr
	move.l	#1,d0
	neg.l	d0
	chkccr	$19,19
	chkl	d0,$FFFFFFFF,18
	move.b	#$80,d0
	neg.b	d0
	chkccr	$1B,20		; X N V C for byte $80

;----------------------------------------------------------------- shifts
	move.w	#0,ccr
	move.l	#$12345678,d0
	lsl.l	#4,d0
	chkccr	$11,22		; X C from bit 28
	chkl	d0,$23456780,21

	move.l	#$80000000,d0
	asr.l	#8,d0
	chkccr	$08,24		; N only
	chkl	d0,$FF800000,23

	move.w	#0,ccr
	move.l	#$8001,d0
	rol.w	#1,d0
	chkccr	$01,26		; C only, X untouched
	chkl	d0,$3,25

	move.w	#$10,ccr	; X=1
	move.l	#$8000,d0
	roxl.w	#1,d0
	chkccr	$11,28		; X C
	chkl	d0,$1,27

	move.w	#$01,ccr	; C=1 X=0
	moveq	#0,d1
	lsl.l	d1,d0		; count 0: C cleared
	chkccr	$00,29

	move.w	#$11,ccr	; C=1 X=1
	roxl.l	d1,d0		; count 0 ROX: C=X
	chkccr	$11,30

	move.l	#1,d0
	moveq	#40,d1
	lsl.l	d1,d0		; count over width
	chkccr	$04,32		; Z, C=0, X=0 after over-shift
	chkl	d0,0,31

	move.w	#$C000,($3000).l
	asl.w	($3000).l
	move.w	($3000).l,d0
	and.l	#$FFFF,d0
	chkl	d0,$8000,33

;----------------------------------------------------------------- bit ops
	move.w	#0,ccr
	moveq	#0,d0
	bset	#35,d0		; modulo 32 = bit 3
	chkccr	$04,35		; bit was zero
	chkl	d0,8,34
	btst	#3,d0
	chkccr	$00,36
	bclr	#3,d0
	chkl	d0,0,37
	move.b	#0,($3002).l
	bset	#11,($3002).l	; memory: modulo 8 = bit 3
	move.b	($3002).l,d0
	and.l	#$FF,d0
	chkl	d0,8,38
	moveq	#6,d1
	moveq	#0,d2
	bchg	d1,d2
	chkl	d2,$40,39

;----------------------------------------------------------------- word mul/div
	move.l	#$FFFF,d0
	mulu.w	#$FFFF,d0
	chkl	d0,$FFFE0001,40
	move.l	#3,d0
	muls.w	#$FFFE,d0
	chkl	d0,$FFFFFFFA,41
	move.l	#42,d0
	divu.w	#10,d0
	chkl	d0,$00020004,42
	move.l	#-10,d0
	divs.w	#3,d0
	chkl	d0,$FFFFFFFD,43
	move.w	#0,ccr
	move.l	#$00100000,d0
	divu.w	#1,d0
	chkccr	$02,44		; overflow: V set
	chkl	d0,$00100000,45	; register unchanged

;----------------------------------------------------------------- long mul/div
	move.l	#$12345678,d0
	mulu.l	#2,d0
	chkl	d0,$2468ACF0,46
	move.l	#$80000000,d0
	move.l	#$80000000,d1
	mulu.l	d1,d2:d0
	chkl	d0,0,47
	chkl	d2,$40000000,48
	move.l	#5,d0
	muls.l	#-1,d0
	chkl	d0,$FFFFFFFB,49
	move.l	#$100,d0
	divu.l	#$10,d0
	chkl	d0,$10,50
	move.l	#43,d0
	divul.l	#5,d1:d0
	chkl	d0,8,51
	chkl	d1,3,52
	move.l	#2,d1
	moveq	#0,d0
	divu.l	#$10,d1:d0	; 64-bit dividend $2_0000_0000
	chkl	d0,$20000000,53
	chkl	d1,0,54
	moveq	#0,d0
	move.w	#0,ccr
	move.l	#1,d1
	divu.l	#1,d1:d0	; quotient needs 33 bits: overflow
	chkccr	$02,55
	chkl	d1,1,56		; unchanged

;----------------------------------------------------------------- BCD
	move.w	#0,ccr
	move.b	#$15,d0
	move.b	#$27,d1
	abcd	d1,d0
	and.l	#$FF,d0
	chkl	d0,$42,57
	move.w	#0,ccr
	move.b	#$42,d2
	move.b	#$15,d3
	sbcd	d3,d2
	and.l	#$FF,d2
	chkl	d2,$27,58
	move.w	#0,ccr
	move.b	#1,d4
	nbcd	d4
	and.l	#$FF,d4
	chkl	d4,$99,59

;----------------------------------------------------------------- ext/swap/exg
	move.l	#$80,d0
	ext.w	d0
	chkl	d0,$FF80,60
	ext.l	d0
	chkl	d0,$FFFFFF80,61
	move.l	#$80,d1
	extb.l	d1
	chkl	d1,$FFFFFF80,62
	move.l	#$12345678,d2
	swap	d2
	chkl	d2,$56781234,63
	move.l	#$11111111,d0
	move.l	#$22222222,d1
	exg	d0,d1
	chkl	d0,$22222222,64
	chkl	d1,$11111111,65
	movea.l	#$33333333,a1
	exg	d0,a1
	chkl	d0,$33333333,66

;----------------------------------------------------------------- EA modes
	lea	($3000).l,a0
	move.l	#$AABBCCDD,(a0)
	move.l	(a0),d0
	chkl	d0,$AABBCCDD,67
	move.l	#$11112222,4(a0)
	moveq	#4,d1
	move.l	(0,a0,d1.w),d2
	chkl	d2,$11112222,68
	move.l	#$33334444,8(a0)
	move.l	(0,a0,d1.w*2),d2
	chkl	d2,$33334444,69
	move.l	#$55556666,$20(a0)
	move.l	($10,a0,d1.l*4),d3
	chkl	d3,$55556666,70

	; memory indirect pre-indexed: ([$40,a0],4)
	move.l	#$3050,($3040).l
	move.l	#$DEAD0001,($3054).l
	move.l	([$40,a0],4),d4
	chkl	d4,$DEAD0001,71

	; memory indirect post-indexed: ([$40,a0],d1.l*2,4) = $3050+8+4
	move.l	#$DEAD0002,($305C).l
	move.l	([$40,a0],d1.l*2,4),d5
	chkl	d5,$DEAD0002,72

	; PC relative
	move.l	tdata(pc),d6
	chkl	d6,$0BADCAFE,73
	moveq	#4,d2
	move.l	(tdata,pc,d2.l),d6
	chkl	d6,$0BADF00D,74

	; absolute short
	move.w	#$1234,($3000).w
	move.w	($3000).w,d0
	and.l	#$FFFF,d0
	chkl	d0,$1234,75

;----------------------------------------------------------------- adda/cmpa
	movea.l	#$10000,a5
	adda.w	#$8000,a5	; sign extends
	cmpa.l	#$8000,a5
	beq.s	t76ok
	failt	76
t76ok:
	movea.l	#-1,a5
	cmpa.w	#$FFFF,a5	; sign extended compare equal
	beq.s	t77ok
	failt	77
t77ok:
	suba.l	a5,a5
	cmpa.l	#0,a5
	beq.s	t78ok
	failt	78
t78ok:

;----------------------------------------------------------------- addq/subq to An
	movea.l	#$1000,a4
	addq.w	#5,a4		; whole register
	subq.l	#1,a4
	cmpa.l	#$1004,a4
	beq.s	t79ok
	failt	79
t79ok:

;----------------------------------------------------------------- control flow
	moveq	#0,d0
	bsr	sub1
	chkl	d0,1,80
	lea	sub1(pc),a2
	jsr	(a2)
	chkl	d0,2,81

	move.l	sp,d5		; sp checkpoints for link/unlk
	link	a6,#-16
	unlk	a6
	cmp.l	sp,d5
	beq.s	t82ok
	failt	82
t82ok:
	link.l	a6,#-$10000
	unlk	a6
	cmp.l	sp,d5
	beq.s	t83ok
	failt	83
t83ok:

	pea	4(a0)
	move.l	(sp)+,d0
	move.l	a0,d1
	addq.l	#4,d1
	cmp.l	d0,d1
	beq.s	t84ok
	failt	84
t84ok:

	moveq	#3,d0
	moveq	#0,d1
dbloop:
	addq.l	#1,d1
	dbra	d0,dbloop
	chkl	d1,4,85
	chkl	d0,$FFFF,86

	cmp.l	d1,d1
	seq	d2
	sne	d3
	and.l	#$FF,d2
	chkl	d2,$FF,87
	and.l	#$FF,d3
	chkl	d3,0,88

	; rtd
	move.l	sp,d5
	pea	($12345678).l	; junk long the callee will discard
	bsr	subrtd
	cmp.l	sp,d5
	beq.s	t89ok
	failt	89
t89ok:

	; cmpm
	lea	($3060).l,a0
	lea	($3064).l,a1
	move.w	#$5555,(a0)
	move.w	#$5555,(a1)
	cmpm.w	(a0)+,(a1)+
	beq.s	t90ok
	failt	90
t90ok:
	move.l	a0,d0
	chkl	d0,$3062,91

	; tas
	move.b	#0,($3003).l
	tas	($3003).l
	move.b	($3003).l,d0
	and.l	#$FF,d0
	chkl	d0,$80,92

;----------------------------------------------------------------- movem
	move.l	#$01010101,d0
	move.l	#$02020202,d1
	move.l	#$03030303,d2
	move.l	#$04040404,d3
	movea.l	#$05050505,a5
	move.l	sp,d5
	movem.l	d0-d3/a5,-(sp)
	moveq	#0,d0
	moveq	#0,d2
	suba.l	a5,a5
	movem.l	(sp)+,d0-d3/a5
	chkl	d0,$01010101,93
	chkl	d2,$03030303,94
	move.l	a5,d4
	chkl	d4,$05050505,95
	cmp.l	sp,d5
	beq.s	t96ok
	failt	96
t96ok:
	move.l	#$8001,d0
	move.l	#$7FFF,d1
	movem.w	d0-d1,($3100).l
	moveq	#0,d4
	movem.w	($3100).l,d4-d5
	chkl	d4,$FFFF8001,97	; word loads sign extend
	chkl	d5,$00007FFF,98

;----------------------------------------------------------------- movep
	lea	($3200).l,a3
	move.l	#$11223344,d0
	movep.l	d0,0(a3)
	moveq	#0,d1
	movep.l	0(a3),d1
	chkl	d1,$11223344,99
	move.w	($3200).l,d2
	and.l	#$FF00,d2
	chkl	d2,$1100,100	; byte lands in the upper lane

;----------------------------------------------------------------- pack/unpk
	move.w	#$0407,d0
	moveq	#0,d1
	pack	d0,d1,#0
	and.l	#$FF,d1
	chkl	d1,$47,101
	move.b	#$47,d2
	moveq	#0,d3
	unpk	d2,d3,#0
	and.l	#$FFFF,d3
	chkl	d3,$0407,102

;----------------------------------------------------------------- move16
	lea	($3300).l,a0
	move.l	#$AAAA0001,(a0)+
	move.l	#$BBBB0002,(a0)+
	move.l	#$CCCC0003,(a0)+
	move.l	#$DDDD0004,(a0)+
	lea	($3300).l,a0
	lea	($3340).l,a1
	move16	(a0)+,(a1)+
	move.l	a0,d0
	chkl	d0,$3310,103
	move.l	a1,d0
	chkl	d0,$3350,104
	move.l	($3340).l,d0
	chkl	d0,$AAAA0001,105
	move.l	($334C).l,d0
	chkl	d0,$DDDD0004,106

;----------------------------------------------------------------- ccr moves
	move.w	#$1F,ccr
	move.w	ccr,d0
	and.l	#$FF,d0
	chkl	d0,$1F,107
	move.w	#$04,ccr
	move.w	ccr,d0
	and.l	#$FF,d0
	chkl	d0,$04,108

;----------------------------------------------------------------- tst
	suba.l	a4,a4
	tst.w	a4
	chkccr	$04,109
	move.l	#$80000000,d0
	tst.l	d0
	chkccr	$08,110
	clr.w	($3004).l
	tst.w	($3004).l
	chkccr	$04,111

;----------------------------------------------------------------- bitfields
	move.w	#0,ccr
	move.l	#$12345678,d0
	bfextu	d0{8:8},d1
	chkl	d1,$34,112
	move.l	#$F2345678,d0
	bfexts	d0{0:4},d2
	chkl	d2,$FFFFFFFF,113
	moveq	#0,d3
	bfset	d3{28:8}		; wraps around bit 0
	chkl	d3,$F000000F,114
	bfclr	d3{28:8}
	chkl	d3,0,115
	move.l	#$AAAA5555,d4
	bfchg	d4{16:16}
	chkl	d4,$AAAAAAAA,116
	move.l	#$00080000,d5
	bfffo	d5{0:32},d6
	chkl	d6,12,117
	bfffo	d5{0:8},d6
	chkl	d6,8,118		; empty field: offset + width
	moveq	#0,d7
	move.l	#$5A,d1
	bfins	d1,d7{4:8}
	chkl	d7,$05A00000,119
	move.w	d7,d7			; keep d7 for fail codes below
	moveq	#0,d7

	; memory bitfields
	move.l	#$11223344,($3080).l
	move.l	#$55667788,($3084).l
	bftst	($3080).l{12:8}
	bne.s	bf1ok
	failt	120
bf1ok:
	bfset	($3080).l{12:8}
	move.l	($3080).l,d0
	chkl	d0,$112FF344,121
	bfclr	($3080).l{4:32}		; spans five bytes
	move.l	($3080).l,d0
	chkl	d0,$10000000,122
	move.l	($3084).l,d0
	chkl	d0,$05667788,123
	bfextu	($3084).l{0:16},d0
	chkl	d0,$0566,124
	move.l	#$77,d1
	bfins	d1,($3080).l{8:8}
	move.l	($3080).l,d0
	chkl	d0,$10770000,125

;----------------------------------------------------------------- CAS
	move.l	#$C0FFEE00,($3090).l
	move.l	#$C0FFEE00,d0		; Dc matches
	move.l	#$12341234,d1		; Du
	cas.l	d0,d1,($3090).l
	beq.s	cas1ok
	failt	126
cas1ok:
	move.l	($3090).l,d2
	chkl	d2,$12341234,127
	chkl	d0,$C0FFEE00,128	; Dc untouched on success
	moveq	#0,d2			; Dc mismatch
	cas.l	d2,d1,($3090).l
	bne.s	cas2ok
	failt	129
cas2ok:
	chkl	d2,$12341234,130	; Dc loaded with the operand
	move.b	#$77,($3094).l
	move.l	#$77,d3
	move.l	#$99,d4
	cas.b	d3,d4,($3094).l
	move.b	($3094).l,d0
	and.l	#$FF,d0
	chkl	d0,$99,131

;----------------------------------------------- BTST Dn,#imm and CMP2
	move.w	#0,ccr
	moveq	#1,d1
	btst	d1,#$02		; bit 1 of $02 is set
	chkccr	$00,132
	btst	d1,#$0D		; bit 1 of $0D is clear
	chkccr	$04,133

	move.w	#10,($30A0).l	; word bounds pair {10, 20}
	move.w	#20,($30A2).l
	move.w	#0,ccr
	moveq	#15,d0
	cmp2.w	($30A0).l,d0	; inside
	chkccr	$00,134
	moveq	#10,d0
	cmp2.w	($30A0).l,d0	; on the lower bound
	chkccr	$04,135
	moveq	#25,d0
	cmp2.w	($30A0).l,d0	; above
	chkccr	$01,136
	moveq	#5,d0
	cmp2.w	($30A0).l,d0	; below
	chkccr	$01,137
	move.l	#$00003000,($30A8).l	; long bounds for an address register
	move.l	#$00004000,($30AC).l
	movea.l	#$3800,a1
	cmp2.l	($30A8).l,a1
	chkccr	$00,138

;----------------------------------------------------------------- CAS2
	move.l	#$11110000,($30B0).l
	move.l	#$22220000,($30B8).l
	lea	($30B0).l,a0
	lea	($30B8).l,a1
	move.l	#$11110000,d0	; Dc1 matches
	move.l	#$22220000,d1	; Dc2 matches
	move.l	#$AAAA0001,d2	; Du1
	move.l	#$BBBB0002,d3	; Du2
	cas2.l	d0:d1,d2:d3,(a0):(a1)
	beq.s	c2aok
	failt	140
c2aok:
	move.l	($30B0).l,d4
	chkl	d4,$AAAA0001,141
	move.l	($30B8).l,d4
	chkl	d4,$BBBB0002,142
	chkl	d0,$11110000,143	; compare registers untouched on success

	moveq	#0,d0			; Dc1 mismatch: both loaded, no store
	cas2.l	d0:d1,d2:d3,(a0):(a1)
	bne.s	c2bok
	failt	144
c2bok:
	chkl	d0,$AAAA0001,145
	chkl	d1,$BBBB0002,146
	move.l	($30B0).l,d4
	chkl	d4,$AAAA0001,147	; memory unchanged

	; second compare mismatch: flags from the second compare
	move.l	#$AAAA0001,d0
	moveq	#0,d1
	cas2.l	d0:d1,d2:d3,(a0):(a1)
	bne.s	c2cok
	failt	148
c2cok:
	chkl	d1,$BBBB0002,149

	; word form
	move.w	#$1234,($30C0).l
	move.w	#$5678,($30C4).l
	lea	($30C0).l,a0
	lea	($30C4).l,a1
	move.l	#$1234,d0
	move.l	#$5678,d1
	move.l	#$1111,d2
	move.l	#$2222,d3
	cas2.w	d0:d1,d2:d3,(a0):(a1)
	beq.s	c2dok
	failt	150
c2dok:
	move.w	($30C0).l,d4
	and.l	#$FFFF,d4
	chkl	d4,$1111,151

;----------------------------------------------------------------- BCD with
; non-BCD digit inputs: the decimal correction is byte-wide on real
; hardware (cputest 68040_default reference data), and N/V are unchanged
	move.b	#$FF,d0
	move.b	#$FF,d1
	move.w	#0,ccr
	abcd	d1,d0			; $FF+$FF+0 -> $64, X=C=1
	chkccr	$11,152
	and.l	#$FF,d0
	chkl	d0,$64,153

	move.b	#$FF,d2
	move.b	#$FF,d3
	move.w	#$1A,ccr		; X=1, N/V preset: must survive
	abcd	d3,d2			; $FF+$FF+1 -> $65, X=C=1
	chkccr	$1B,154
	and.l	#$FF,d2
	chkl	d2,$65,155

	move.b	#$00,d0
	move.b	#$FF,d1
	move.w	#0,ccr
	sbcd	d1,d0			; $00-$FF -> $9B, X=C=1
	chkccr	$11,156
	and.l	#$FF,d0
	chkl	d0,$9B,157

	move.b	#$12,d2
	move.b	#$0E,d3
	move.w	#0,ccr
	sbcd	d3,d2			; low-nibble borrow only: -> $FE, X=C=1
	chkccr	$11,158
	and.l	#$FF,d2
	chkl	d2,$FE,159

	move.b	#$FF,d4
	move.w	#0,ccr
	nbcd	d4			; 0-$FF -> $9B, X=C=1
	chkccr	$11,160
	and.l	#$FF,d4
	chkl	d4,$9B,161

	move.b	#$10,d5
	move.w	#0,ccr
	nbcd	d5			; 0-$10 -> $90, X=C=1
	chkccr	$11,162
	and.l	#$FF,d5
	chkl	d5,$90,163

	move.b	#$99,d0
	move.b	#$01,d1
	move.w	#$04,ccr		; Z preset: stays set on zero result
	abcd	d1,d0			; $99+$01 -> $00, X=Z=C=1
	chkccr	$15,164
	and.l	#$FF,d0
	chkl	d0,0,165

;----------------------------------------------------------------- CHK flags
; 68040: N always tracks the value's sign, C cleared when in bounds
; (set on traps only for specific sign combos), Z/V/X unchanged
	move.l	#16,d0
	move.w	#$1F,ccr
	chk.l	d0,d0		; value 16, bound 16: in bounds
	chkccr	$16,166		; N,C cleared; X,Z,V survive

	move.l	#0,d1
	move.l	#10,d2
	move.w	#$04,ccr
	chk.l	d2,d1		; value 0, bound 10: in bounds
	chkccr	$04,167		; Z preserved, N=C=0

;----------------------------------------------------- DIVS.L 32-bit overflow
; 68040: V=1, C=0, N/Z and destination unchanged
	move.l	#$80000000,d0
	moveq	#-1,d1
	move.w	#$0C,ccr
	divs.l	d1,d0		; $80000000/-1 overflows
	chkccr	$0E,168		; V set, N/Z preserved
	chkl	d0,$80000000,169

;--------------------------------------------------- MULx.L with Dh == Dl
; the 68040 writes Dh before Dl, so the shared register keeps the LOW
; product half (020/030 end with the high half); V/C clear, X preserved
	move.l	#$10000,d0
	move.l	#$10000,d1
	move.w	#$1F,ccr
	mulu.l	d1,d0:d0	; $10000*$10000 = $1_0000_0000
	chkccr	$10,170		; N=0 Z=0 (64-bit product nonzero) V=C=0, X kept
	chkl	d0,0,171	; low half, not the high half

;------------------------------------------------- shift/rotate count edges
; register count 0: N/Z from the unchanged operand, V=C=0, X preserved,
; except ROXd where C=X; count>=width via iteration
	move.l	#$8000,d0
	moveq	#0,d1
	move.w	#$11,ccr	; X and C set
	lsr.w	d1,d0		; count 0
	chkccr	$18,172		; X kept, C cleared, N from d0
	chkl	d0,$8000,173

	move.l	#$8000,d0
	moveq	#0,d1
	move.w	#$10,ccr	; X only
	roxr.w	d1,d0		; count 0: C = X
	chkccr	$19,174		; X kept, C=X=1, N=1
	chkl	d0,$8000,175

	move.l	#1,d0
	moveq	#16,d1
	move.w	#0,ccr
	lsl.w	d1,d0		; count == width: last real bit out
	chkccr	$15,176		; X=C=1, Z=1
	chkl	d0,0,177

	move.l	#1,d0
	moveq	#17,d1
	move.w	#$10,ccr	; X preset
	lsl.w	d1,d0		; count > width: zeros shift out
	chkccr	$04,178		; X=C=0, Z=1
	chkl	d0,0,179

	move.l	#$80,d0
	moveq	#63,d1
	move.w	#0,ccr
	asr.b	d1,d0		; maximum count: sign fill
	chkccr	$19,180		; X=C=1 (sign), N=1
	and.l	#$FF,d0
	chkl	d0,$FF,181

	move.l	#$8001,d0
	moveq	#16,d1
	move.w	#0,ccr
	rol.w	d1,d0		; full cycle: value back, C = original bit 0
	chkccr	$09,182		; N=1, C=1
	chkl	d0,$8001,183

	move.l	#$1234,d0
	moveq	#17,d1
	move.w	#$10,ccr	; X set
	roxl.w	d1,d0		; count 17 = full 17-bit cycle: all restored
	chkccr	$11,184		; X restored, C=X
	chkl	d0,$1234,185

;------------------------------------- MOVEM predec with base reg in list
; the 68040 stores the initial base value minus the operation size
	lea	($3200).l,a0
	move.l	#$11112222,d0
	movem.l	d0/a0,-(a0)
	chkl	a0,$31F8,186	; final base = start - 2 regs
	move.l	($31FC).l,d1
	chkl	d1,$31FC,187	; stored a0 = initial - 4 (040 rule)
	move.l	($31F8).l,d2
	chkl	d2,$11112222,188

	lea	($3220).l,a1
	move.l	#$33334444,d3
	movem.w	d3/a1,-(a1)	; word form: initial - 2
	chkl	a1,$321C,189
	move.w	($321E).l,d4
	and.l	#$FFFF,d4
	chkl	d4,$321E,190	; stored a1.w = (initial - 2) low word
	move.w	($321C).l,d5
	and.l	#$FFFF,d5
	chkl	d5,$4444,191

;------------------------------------------- store into the fetch queue
; A CPU write landing inside the free-running fetch queue's window must
; flush it: the stale prefetched word would otherwise execute.  The 040
; architecture only requires CPUSH/CINV for self-modifying code, but the
; queue snoops its own stores as insurance -- the previous fetch-buffered
; core booted DiagROM and not AmigaOS on hardware with exactly this
; hazard, invisible to every CINV-disciplined test.  The divide keeps
; the queue filled across smcq while the store rewrites it.
	moveq	#0,d7
	move.l	#$80000000,d0
	movec	d0,cacr		; I-cache bypassed: the queue is the only
				; instruction staleness this test probes (a
				; cached stale line is t_cache's contract and
				; needs CINV by design)
	lea	smcq(pc),a0
	move.l	#100,d0
	divu.w	#3,d0		; queue runs ahead through smcq
	move.w	#$5247,(a0)	; nop -> addq.w #1,d7, while queued
smcq:
	nop
	moveq	#0,d0
	cmp.l	#1,d7		; the REWRITTEN instruction must have run
	beq.s	smcq_ok
	failt	192
smcq_ok:
	cinva	ic		; drop the line cached before the bypass
	move.l	#$80008000,d0
	movec	d0,cacr		; cache-hot again

;----------------------------------------------------------------- all done
	move.w	#$600D,(DONEREG).l
	stop	#$2700

;----------------------------------------------------------------- helpers
sub1:
	addq.l	#1,d0
	rts

subrtd:
	rtd	#4

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt1:
	bra.s	halt1

unexp:
	move.w	#$00FF,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2

	even
tdata:
	dc.l	$0BADCAFE
	dc.l	$0BADF00D
