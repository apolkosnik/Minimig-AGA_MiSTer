; m68010.s - self checking test of the 68010 programming model on fx68k
;
; Runs in 68010 mode. The end status written to $FF0000 is the number of
; failed checks (0 = pass). Failures are logged at FAILLOG:
;   test id (word), check number (word), expected (long), actual (long)
;
; Memory map: see tb_fx68k.sv

FAILCNT		equ	$8000		; failed checks
NCHECKS		equ	$8004		; checks done
FAILPTR		equ	$8008
FAILLOG		equ	$8100

handler		equ	$7000		; exception handler for the next exception
resume		equ	$7004		; where the handler resumes
save_a0		equ	$7008
lastvec		equ	$700c		; vector number of the last exception (word)
tid		equ	$700e		; test id (word)
f_sp		equ	$7010		; frame of the last exception
f_sr		equ	$7014
f_pc		equ	$7016
f_fmt		equ	$701a
f_ssw		equ	$701c
f_addr		equ	$701e
f_vec		equ	$7022
pre_sp		equ	$7024
cnum		equ	$7028		; check number within the test (word)
nexc		equ	$702a		; exceptions taken (word)
ncont		equ	$702c		; bus errors continued (word)
f_iib		equ	$702e		; instruction input buffer of the last format 8 frame

END		equ	$ff0000
IPL		equ	$ff0002
PROBE		equ	$ff0010
NBKPT		equ	$ff0018
MIRROR		equ	$fd0000		; mirror of $0d0000, FC probed
MIRRAM		equ	$0d0000
BERRADR		equ	$fe0000
FMIRROR		equ	$fc0000		; mirror of $0d0000, a bus error on one access
FAULT		equ	$ff001c		; the n-th access to FMIRROR gets a bus error
ALTVBR		equ	$0c0000

SSP_TOP		equ	$000f0000
USP_TOP		equ	$000e0000

; ---------------------------------------------------------------------------

; check long: CHKL <expected>,<actual>
CHKL	macro
	move.l	\2,d6
	move.l	\1,d5
	bsr	check
	endm

; check word, zero extended: CHKW <expected>,<actual>
CHKW	macro
	moveq	#0,d6
	move.w	\2,d6
	move.l	\1,d5
	bsr	check
	endm

TEST	macro
test\1:
	move.w	#\1,tid
	clr.w	cnum
	endm

; the next exception is recorded and resumes at \1
EXPECT	macro
	move.l	#h_rec,handler
	move.l	#\1,resume
	move.l	sp,pre_sp
	endm

; checks of a recorded format 0 frame: vector, PC
FRAME0	macro
	CHKW	#\1,f_vec
	CHKW	#(\1)*4,f_fmt
	move.l	pre_sp,d0
	subq.l	#8,d0
	CHKL	d0,f_sp
	CHKL	#\2,f_pc
	endm

; ---------------------------------------------------------------------------

	org	0
	dc.l	SSP_TOP
	dc.l	start
vn	set	2
	rept	254
	dc.l	vstubs+vn*14
vn	set	vn+1
	endr

; one stub per vector: record the vector number and go to the handler
vstubs:
vn	set	0
	rept	256
	move.w	#vn,lastvec
	jmp	common
vn	set	vn+1
	endr

common:	move.l	a0,save_a0
	movea.l	handler,a0
	jmp	(a0)

; unexpected exception: end the test
h_unexp:
	move.w	lastvec,d0
	or.w	#$8000,d0
	move.w	d0,END
	bra.s	*

; record the frame and resume
h_rec:	movea.l	save_a0,a0
	move.l	sp,f_sp
	move.w	(sp),f_sr
	move.l	2(sp),f_pc
	move.w	6(sp),f_fmt
	move.w	8(sp),f_ssw
	move.l	10(sp),f_addr
	move.w	lastvec,f_vec
	addq.w	#1,nexc
	btst	#7,6(sp)		; format 8: abandon the faulted instruction,
	beq.s	.f0			; return with a format 0 frame
	move.w	(sp),50(sp)
	move.w	6(sp),56(sp)
	andi.w	#$0fff,56(sp)
	lea	50(sp),sp
.f0:	andi.w	#$7fff,(sp)		; no trace after the return
	move.l	resume,2(sp)
	move.l	#h_unexp,handler
	rte

; bus error: record the SSW and the address, RTE continues the instruction
h_cont:	movea.l	save_a0,a0
	move.w	8(sp),f_ssw
	move.l	10(sp),f_addr
	move.w	24(sp),f_iib
	addq.w	#1,ncont
	move.l	#h_unexp,handler
	rte

; bus error: the handler does the cycle (SSW RR), a read gets $abcd from the
; data input buffer, a write isn't done
h_rr:	movea.l	save_a0,a0
	move.w	8(sp),f_ssw
	move.l	10(sp),f_addr
	addq.w	#1,ncont
	move.w	#$abcd,20(sp)
	ori.w	#$8000,8(sp)
	move.l	#h_unexp,handler
	rte

; back to supervisor mode (TRAP #15)
h_super:
	movea.l	save_a0,a0
	ori.w	#$2700,(sp)		; supervisor, interrupts masked
	move.l	#h_unexp,handler
	rte

; interrupt: record, clear the request
h_int:	movea.l	save_a0,a0
	move.w	#0,IPL
	bra	h_rec

; d5 expected, d6 actual
check:	addq.l	#1,NCHECKS
	addq.w	#1,cnum
	cmp.l	d5,d6
	beq.s	.ok
	move.l	a6,-(sp)
	addq.l	#1,FAILCNT
	movea.l	FAILPTR,a6
	move.w	tid,(a6)+
	move.w	cnum,(a6)+
	move.l	d5,(a6)+
	move.l	d6,(a6)+
	move.l	a6,FAILPTR
	movea.l	(sp)+,a6
.ok:	rts

GOUSER	macro
	move.l	#h_super,handler
	andi.w	#$d8ff,sr		; user mode, interrupt mask 0
	endm

GOSUPER	macro
	move.l	#h_super,handler
	trap	#15
	endm

; ---------------------------------------------------------------------------

	org	$2000
start:	clr.l	FAILCNT
	clr.l	NCHECKS
	move.l	#FAILLOG,FAILPTR
	move.l	#h_unexp,handler
	clr.w	nexc
	lea	USP_TOP,a0
	move.l	a0,usp

; 1: control registers after reset
	TEST	1
	movec	vbr,d0
	CHKL	#0,d0

; 2: MOVEC to and from VBR, SFC, DFC, USP with data and address registers
	TEST	2
	move.l	#$12345678,d0
	movec	d0,vbr
	movec	vbr,d1
	CHKL	#$12345678,d1
	movec	vbr,a1
	CHKL	#$12345678,a1
	move.l	#$89abcdef,a2
	movec	a2,vbr
	movec	vbr,d2
	CHKL	#$89abcdef,d2
	moveq	#0,d0
	movec	d0,vbr
	movec	vbr,d3
	CHKL	#0,d3
	moveq	#-1,d0
	movec	d0,sfc
	movec	sfc,d1
	CHKL	#7,d1
	movec	d0,dfc
	movec	dfc,d2
	CHKL	#7,d2
	moveq	#5,d0
	movec	d0,sfc
	moveq	#2,d0
	movec	d0,dfc
	movec	sfc,a3
	CHKL	#5,a3
	movec	dfc,a4
	CHKL	#2,a4
	move.l	#$000e1234,a0
	movec	a0,usp
	move.l	usp,a1
	CHKL	#$000e1234,a1
	move.l	#$000e5678,a2
	move.l	a2,usp
	movec	usp,d4
	CHKL	#$000e5678,d4
	movec	usp,a5
	CHKL	#$000e5678,a5
	move.l	#USP_TOP,d0
	movec	d0,usp
	movec	sp,vbr			; A7 is SSP in supervisor mode
	movec	vbr,d0
	CHKL	sp,d0
	moveq	#0,d0
	movec	d0,vbr
	move.l	sp,d1
	movec	sfc,sp			; SSP <= SFC, then restore
	move.l	sp,d2
	movea.l	d1,sp
	CHKL	#5,d2

; 3: MOVEC with an invalid control register is an illegal instruction
	TEST	3
	EXPECT	.r1
.i1:	dc.l	$4e7a0002		; movec cacr,d0
.r1:	FRAME0	4,.i1
	EXPECT	.r2
.i2:	dc.l	$4e7b0802		; movec d0,caar
.r2:	FRAME0	4,.i2
	EXPECT	.r3
.i3:	dc.l	$4e7a1003		; movec tc,d1
.r3:	FRAME0	4,.i3
	EXPECT	.r4
.i4:	dc.l	$4e7b8804		; movec a0,isp
.r4:	FRAME0	4,.i4

; 4: MOVEC, MOVES, MOVE from SR in user mode are privileged
	TEST	4
	clr.w	nexc
	GOUSER
	EXPECT	.r1
.i1:	movec	vbr,d0
.r1:	EXPECT	.r2
.i2:	movec	d0,sfc
.r2:	EXPECT	.r3
.i3:	moves.w	(a0),d0
.r3:	EXPECT	.r4
.i4:	move.w	sr,d0
.r4:	move.w	f_vec,d1
	move.w	f_fmt,d2
	move.l	f_pc,d3
	move.w	f_sr,d4
	GOSUPER
	CHKW	#8,d1
	CHKW	#$0020,d2
	CHKL	#.i4,d3
	CHKW	#$0000,d4
	CHKW	#4,nexc

; 5: format 0 frames
	TEST	5
	clr.w	nexc
	EXPECT	.r1
	move.w	#$2715,sr
	trap	#3
.r1:	FRAME0	35,.r1
	CHKW	#$2715,f_sr
	move.w	#$2700,sr

	EXPECT	.r2
	move.w	#$2702,sr		; V
	trapv
.r2:	FRAME0	7,.r2
	move.w	#$2700,sr

	moveq	#20,d0
	EXPECT	.r3
	chk.w	#10,d0
.r3:	FRAME0	6,.r3

	moveq	#-1,d0
	EXPECT	.r4
	chk.w	d1,d0
.r4:	FRAME0	6,.r4

	moveq	#0,d1
	EXPECT	.r5
	divu.w	d1,d0
.r5:	FRAME0	5,.r5

	EXPECT	.r6
	divs.w	#0,d0
.r6:	FRAME0	5,.r6

	EXPECT	.r7
.i7:	illegal
.r7:	FRAME0	4,.i7

	EXPECT	.r8
.i8:	dc.w	$a123			; line A
.r8:	FRAME0	10,.i8

	EXPECT	.r9
.i9:	dc.w	$f123			; line F
.r9:	FRAME0	11,.i9

	move.w	NBKPT,d7
	EXPECT	.r10
.i10:	bkpt	#3			; breakpoint acknowledge cycle, then illegal instruction
.r10:	FRAME0	4,.i10
	move.w	NBKPT,d3
	sub.w	d7,d3
	CHKW	#1,d3

	EXPECT	.r11
	trap	#0
.r11:	FRAME0	32,.r11
	EXPECT	.r12
	trap	#15
.r12:	FRAME0	47,.r12

	; trace: T set by MOVE to SR, traced after the NOP
	EXPECT	.r13
	move.w	#$a700,sr
	nop
.i13:	nop
.r13:	FRAME0	9,.i13
	CHKW	#$a700,f_sr
	move.w	#$2700,sr

	; privilege violation from user mode, frame on the SSP
	GOUSER
	EXPECT	.r14
.i14:	move.w	#$2700,sr
.r14:	GOSUPER
	CHKW	#8,f_vec
	CHKW	#$0020,f_fmt
	CHKL	#.i14,f_pc
	CHKW	#$0000,f_sr
	CHKL	#SSP_TOP-8,f_sp

	; TRAP from user mode
	GOUSER
	EXPECT	.r15
	trap	#5
.r15:	GOSUPER
	CHKW	#37,f_vec
	CHKW	#37*4,f_fmt
	CHKL	#.r15,f_pc
	CHKL	#SSP_TOP-8,f_sp
	CHKW	#15,nexc

; 6: interrupts, autovectored
	TEST	6
	move.l	#h_int,handler
	move.l	#.r1,resume
	move.l	sp,pre_sp
	move.w	#3,IPL
	stop	#$2000
.r1:	FRAME0	27,.r1
	CHKW	#$2000,f_sr
	move.w	#$2700,sr
	move.l	#h_int,handler
	move.l	#.r2,resume
	move.l	sp,pre_sp
	move.w	#7,IPL			; NMI
	stop	#$2700
.r2:	FRAME0	31,.r2
	CHKW	#$2700,f_sr
	move.w	#$2700,sr

; 7: VBR relocates the vector table
	TEST	7
	lea	0,a0
	lea	ALTVBR+$10,a1
	move.w	#255,d0
.cp:	move.l	(a0)+,(a1)+
	dbf	d0,.cp
	move.l	#h_vbr,ALTVBR+$10+32*4	; TRAP #0
	move.l	#h_vbr,ALTVBR+$10+4*4	; illegal
	move.l	#h_vbr,ALTVBR+$10+26*4	; level 2 interrupt
	move.l	#ALTVBR+$10,d0
	movec	d0,vbr
	clr.w	nexc
	move.l	sp,pre_sp
	trap	#0
	CHKW	#$0080,f_fmt
	CHKL	pre_sp,sp
	illegal
	CHKW	#$0010,f_fmt
	move.w	#2,IPL
	stop	#$2000
	CHKW	#$0068,f_fmt
	CHKW	#3,nexc
	move.w	#$2700,sr
	; vectors not overridden still go to the stubs
	EXPECT	.r1
	trap	#1
.r1:	FRAME0	33,.r1
	moveq	#0,d0
	movec	d0,vbr
	bra	t8

; relocated vector handler: record the format word and skip ILLEGAL
h_vbr:	move.w	6(sp),f_fmt
	addq.w	#1,nexc
	cmpi.w	#$0010,6(sp)
	bne.s	.not_ill
	addq.l	#2,2(sp)
.not_ill:
	move.w	#0,IPL
	rte

; 8: MOVES
t8:	TEST	8
	lea	MIRRAM,a0
	move.l	#$11223344,(a0)
	move.l	#$5566778a,4(a0)
	move.l	#$80818283,8(a0)
	move.l	#$f0e0d0c0,12(a0)
	moveq	#1,d0
	movec	d0,sfc
	moveq	#2,d0
	movec	d0,dfc

	lea	MIRROR,a1
	moveq	#0,d1
	moves.l	(a1),d1
	CHKL	#$11223344,d1
	CHKW	#$0009,PROBE		; read, FC 1
	move.l	#$deadbeef,d2
	moves.w	4(a1),d2
	CHKL	#$dead5566,d2
	CHKW	#$0009,PROBE
	move.l	#$deadbeef,d3
	moves.b	9(a1),d3
	CHKL	#$deadbe81,d3
	moves.w	12(a1),a2		; sign extended
	CHKL	#$fffff0e0,a2
	moves.w	(a1),a2
	CHKL	#$00001122,a2
	moves.b	8(a1),a3		; byte to An, sign extended
	CHKL	#$ffffff80,a3
	moves.b	3(a1),a3
	CHKL	#$00000044,a3
	moves.l	12(a1),a4
	CHKL	#$f0e0d0c0,a4

	moveq	#4,d0
	movec	d0,sfc
	moves.w	(a1)+,d4
	CHKW	#$000c,PROBE		; read, FC 4
	CHKL	#MIRROR+2,a1
	moves.b	(a1)+,d4
	CHKL	#MIRROR+3,a1
	CHKW	#$1133,d4
	lea	MIRROR+16,a1
	moves.l	-(a1),d4
	CHKL	#$f0e0d0c0,d4
	CHKL	#MIRROR+12,a1
	moves.b	-(a1),d4
	CHKL	#$f0e0d083,d4
	moveq	#6,d1
	lea	MIRROR,a1
	moves.w	2(a1,d1.w),d4
	CHKW	#$8081,d4
	moves.l	MIRROR+8,d7
	CHKL	#$80818283,d7

	; stores use DFC
	move.l	#$a1b2c3d4,d0
	lea	MIRROR+$20,a1
	moves.l	d0,(a1)
	CHKW	#$0002,PROBE		; write, FC 2
	CHKL	#$a1b2c3d4,MIRRAM+$20
	moves.w	d0,(a1)+
	CHKL	#MIRROR+$22,a1
	CHKW	#$c3d4,MIRRAM+$20
	moves.b	d0,-(a1)
	CHKL	#MIRROR+$21,a1
	CHKW	#$c3d4,MIRRAM+$20
	moves.b	d0,(a1)
	CHKW	#$c3d4,MIRRAM+$20
	moves.b	d0,4(a1)
	CHKL	#$00d40000,MIRRAM+$24
	move.l	#$76543210,a2
	lea	MIRROR+$28,a1
	moves.l	a2,(a1)
	CHKL	#$76543210,MIRRAM+$28
	moves.w	a2,4(a1)
	CHKW	#$3210,MIRRAM+$2c
	moves.b	a2,6(a1)		; byte from An
	CHKW	#$1000,MIRRAM+$2e
	moveq	#5,d0
	movec	d0,dfc
	moves.l	d0,MIRROR+$30
	CHKW	#$0005,PROBE		; write, FC 5
	CHKL	#5,MIRRAM+$30

	; condition codes are not affected
	move.w	#$271f,sr
	moves.l	MIRROR+$30,d0
	move.w	sr,d1
	move.w	#$2700,sr
	moves.l	MIRROR+$30,d0
	move.w	sr,d2
	move.w	#$2704,sr
	moves.l	MIRROR+$28,d0		; not zero
	move.w	sr,d3
	moves.l	d0,MIRROR+$34
	move.w	sr,d4
	move.w	#$2700,sr
	CHKW	#$271f,d1
	CHKW	#$2700,d2
	CHKW	#$2704,d3
	CHKW	#$2704,d4

	; MOVES with a register direct or PC relative EA is illegal
	EXPECT	.r1
.i1:	dc.w	$0e80,$0000		; moves.l d0,d0
.r1:	FRAME0	4,.i1
	EXPECT	.r2
.i2:	dc.w	$0e7a,$0000,$0000	; moves.w (d16,pc),d0
.r2:	FRAME0	4,.i2
	EXPECT	.r3
.i3:	dc.w	$0ec0,$0000		; size 11
.r3:	FRAME0	4,.i3

; 9: RTD
	TEST	9
	move.l	sp,d7
	move.l	#1,-(sp)
	move.l	#2,-(sp)
	move.l	#3,-(sp)
	bsr	rtd12
	CHKL	d7,sp
	move.l	sp,d7
	bsr	rtdm4
	subq.l	#8,d7
	CHKL	d7,sp
	addq.l	#8,sp
	move.l	sp,d7
	bsr	rtd0
	CHKL	d7,sp
	bra	t10

rtd12:	CHKL	#3,4(sp)
	rtd	#12
rtdm4:	rtd	#-8
rtd0:	rtd	#0

; 10: MOVE from CCR
t10:	TEST	10
	move.l	#$12345678,d0
	move.w	#$271f,sr
	move.w	ccr,d0
	move.w	sr,d1
	CHKL	#$1234001f,d0
	CHKW	#$271f,d1
	move.w	#$2700,sr
	move.w	ccr,d0
	CHKL	#$12340000,d0
	lea	$7100,a0
	move.w	#$ffff,(a0)
	move.w	#$2715,sr
	move.w	ccr,(a0)
	move.w	sr,d1
	CHKW	#$0015,$7100
	CHKW	#$2715,d1
	move.w	#$2700,sr
	lea	$7104,a0
	move.w	#$270a,sr
	move.w	ccr,-(a0)
	move.w	#$2700,sr
	CHKW	#$000a,$7102
	CHKL	#$7102,a0
	; works in user mode, not privileged
	clr.w	nexc
	moveq	#0,d2
	GOUSER
	move.w	#$0013,ccr
	move.w	ccr,d2
	GOSUPER
	CHKL	#$00000013,d2
	CHKW	#0,nexc
	; MOVE from SR still works in supervisor mode
	move.w	#$2504,sr
	move.w	sr,d3
	move.w	#$2700,sr
	CHKW	#$2504,d3

; 11: RTE with format 0, format 8 and invalid formats
	TEST	11
	move.l	sp,d7
	move.w	#$0084,-(sp)		; format 0
	pea	.r1
	move.w	#$2704,-(sp)
	rte
.r1:	move.w	sr,d0
	move.w	#$2700,sr
	CHKL	d7,sp
	CHKW	#$2704,d0

	move.l	sp,d7			; format 1 is a format error
	move.w	#$1084,-(sp)
	pea	.r3
	move.w	#$2704,-(sp)
	move.l	sp,d6
	move.l	sp,d5
	EXPECT	.r3e
.i3:	rte
.r3:	bra	fail_now
.r3e:	CHKW	#14,f_vec
	CHKW	#$0038,f_fmt
	CHKL	#.i3,f_pc
	CHKW	#$2700,f_sr
	move.l	pre_sp,d0
	subq.l	#8,d0
	CHKL	d0,f_sp
	CHKL	pre_sp,sp		; the bad frame was not popped
	addq.l	#8,sp
	CHKL	d7,sp

	move.l	sp,d7			; format $F
	move.w	#$f000,-(sp)
	pea	.r4
	move.w	#$0000,-(sp)
	EXPECT	.r4e
	move.w	#$2713,sr		; X, V, C: RTE sets N from the format, clears Z and V
.i4:	rte
.r4:	bra	fail_now
.r4e:	CHKW	#$0038,f_fmt
	CHKL	#.i4,f_pc
	CHKW	#$2719,f_sr
	addq.l	#8,sp
	CHKL	d7,sp

	move.l	sp,d7			; format 8 with a wrong version number
	lea	-58(sp),sp
	move.w	#$2701,(sp)
	move.l	#.r6,2(sp)
	move.w	#$8008,6(sp)
	move.w	#$0400,26(sp)		; version 1
	EXPECT	.r6e
.i6:	rte
.r6:	bra	fail_now
.r6e:	CHKW	#$0038,f_fmt
	CHKL	#.i6,f_pc
	move.l	pre_sp,d0
	subq.l	#8,d0
	CHKL	d0,f_sp
	lea	58(sp),sp
	CHKL	d7,sp

	; RTE to user mode
	move.w	#$0000,-(sp)
	pea	.r5
	move.w	#$0000,-(sp)
	rte
.r5:	move.l	sp,d0
	GOSUPER
	CHKL	#USP_TOP,d0
	CHKL	d7,sp

; 12: address error, format 8 frame
	TEST	12
	lea	-64(sp),a0		; mark the frame area
	moveq	#31,d0
.mk:	move.w	#$5a5a,(a0)+
	dbf	d0,.mk
	move.w	#$1234,$7100
	movea.l	#$7001,a0
	EXPECT	.r1
	move.w	$7100,d0		; data input buffer
	move.w	#$4321,$7102		; data output buffer
	move.w	(a0),d0
.r1:	movea.l	f_sp,a1			; copy the frame before calls use the stack
	lea	$7200,a2
	moveq	#28,d0
.cf:	move.w	(a1)+,(a2)+
	dbf	d0,.cf
	CHKW	#$5a5a,$7200+14		; unused words are not written
	CHKW	#$5a5a,$7200+18
	CHKW	#$5a5a,$7200+22
	CHKW	#$4321,$7200+16		; data output buffer
	CHKW	#$1234,$7200+20		; data input buffer
	moveq	#0,d3
	move.w	.r1,d3
	CHKW	d3,$7200+24		; instruction input buffer: the next word
	move.w	$7200+26,d3		; internal state, version number 0 in bits 13:10
	andi.w	#$3c00,d3
	CHKW	#0,d3
	CHKW	#3,f_vec
	CHKW	#$800c,f_fmt
	move.l	pre_sp,d0
	sub.l	#58,d0
	CHKL	d0,f_sp
	CHKL	pre_sp,sp
	CHKL	#$7001,f_addr
	CHKW	#$1105,f_ssw		; DF, read, supervisor data
	CHKW	#$2700,f_sr

	movea.l	#$7003,a0
	EXPECT	.r2
	move.l	d0,(a0)
.r2:	CHKW	#$800c,f_fmt
	CHKL	#$7003,f_addr
	CHKW	#$0005,f_ssw		; write, supervisor data
	CHKL	pre_sp,sp

	movea.l	#$7005,a0		; instruction fetch from an odd address
	EXPECT	.r3
	jmp	(a0)
.r3:	CHKW	#$800c,f_fmt
	CHKL	#$7005,f_addr
	CHKW	#$2106,f_ssw		; IF, read, supervisor program
	CHKL	pre_sp,sp

	GOUSER				; user data read
	movea.l	#$7007,a0
	EXPECT	.r4
	move.w	(a0),d0
.r4:	GOSUPER
	CHKW	#$800c,f_fmt
	CHKW	#$1101,f_ssw
	CHKW	#$0000,f_sr
	CHKL	#SSP_TOP-58,f_sp

; 13: bus error, format 8 frame
	TEST	13
	EXPECT	.r1
	move.w	BERRADR,d0
.r1:	CHKW	#2,f_vec
	CHKW	#$8008,f_fmt
	move.l	pre_sp,d0
	sub.l	#58,d0
	CHKL	d0,f_sp
	CHKL	pre_sp,sp
	CHKL	#BERRADR,f_addr
	CHKW	#$1105,f_ssw
	EXPECT	.r2
	move.w	d0,BERRADR+$10
.r2:	CHKW	#$8008,f_fmt
	CHKL	#BERRADR+$10,f_addr
	CHKW	#$0005,f_ssw
	EXPECT	.r3
	move.b	BERRADR+$21,d0
.r3:	CHKW	#$1305,f_ssw		; byte read
	CHKL	#BERRADR+$21,f_addr
	CHKL	pre_sp,sp

; 15: RTE format 8 continues the instruction of the bus error
	TEST	15
	move.l	#$11223344,MIRRAM+$100
	move.l	#$55667788,MIRRAM+$104
	clr.w	ncont
	; read, rerun by RTE
	move.l	#h_cont,handler
	move.w	#1,FAULT
	moveq	#0,d0
	move.w	FMIRROR+$100,d0
	CHKW	#$1122,d0
	CHKW	#1,ncont
	CHKW	#$1105,f_ssw		; DF, read, supervisor data
	CHKL	#FMIRROR+$100,f_addr
	; write, rerun
	move.l	#h_cont,handler
	move.w	#1,FAULT
	move.w	#$2468,FMIRROR+$108
	CHKW	#$2468,MIRRAM+$108
	CHKW	#2,ncont
	CHKW	#$0005,f_ssw
	; long write, the second word faults
	move.l	#h_cont,handler
	move.w	#2,FAULT
	move.l	#$a1b2c3d4,FMIRROR+$10c
	CHKL	#$a1b2c3d4,MIRRAM+$10c
	CHKL	#FMIRROR+$10e,f_addr
	; long read, the second word faults
	move.l	#h_cont,handler
	move.w	#2,FAULT
	move.l	FMIRROR+$104,d1
	CHKL	#$55667788,d1
	CHKL	#FMIRROR+$106,f_addr
	; memory to memory, the destination faults
	move.l	#h_cont,handler
	move.w	#2,FAULT
	move.w	FMIRROR+$102,FMIRROR+$110
	CHKW	#$3344,MIRRAM+$110
	; MOVEM, the third register faults (CHKL uses D5 and D6)
	moveq	#1,d1
	moveq	#2,d2
	moveq	#3,d3
	moveq	#4,d4
	move.l	#h_cont,handler
	move.w	#6,FAULT		; the low word of D3
	movem.l	d1-d4,FMIRROR+$120
	CHKL	#1,MIRRAM+$120
	CHKL	#2,MIRRAM+$124
	CHKL	#3,MIRRAM+$128
	CHKL	#4,MIRRAM+$12c
	CHKL	#FMIRROR+$12a,f_addr
	movea.l	#FMIRROR+$120,a1
	move.l	#h_cont,handler
	move.w	#3,FAULT
	moveq	#0,d1
	moveq	#0,d2
	moveq	#0,d3
	moveq	#0,d4
	movem.l	(a1)+,d1-d4
	CHKL	#1,d1
	CHKL	#2,d2
	CHKL	#3,d3
	CHKL	#4,d4
	CHKL	#FMIRROR+$130,a1
	; read-modify-write instruction, the write faults
	move.w	#$00ff,MIRRAM+$114
	move.l	#h_cont,handler
	move.w	#2,FAULT
	addq.w	#1,FMIRROR+$114
	CHKW	#$0100,MIRRAM+$114
	; the handler does the read (SSW RR): the data comes from the frame
	move.l	#h_rr,handler
	move.w	#1,FAULT
	moveq	#0,d0
	move.w	FMIRROR+$100,d0
	CHKW	#$abcd,d0
	CHKW	#$1105,f_ssw		; the SSW of the fault has RR clear
	; ... and the write: not done
	move.l	#h_rr,handler
	move.w	#1,FAULT
	move.w	#$5555,FMIRROR+$108
	CHKW	#$2468,MIRRAM+$108
	; instruction fetch from the mirror, the second word of the routine faults
	lea	MIRRAM+$200,a1
	move.w	#$7205,(a1)+		; moveq #5,d1
	move.w	#$7406,(a1)+		; moveq #6,d2
	move.w	#$4e75,(a1)+		; rts
	moveq	#0,d1
	moveq	#0,d2
	move.l	#h_cont,handler
	move.w	#2,FAULT
	jsr	FMIRROR+$200
	CHKL	#5,d1
	CHKL	#6,d2
	CHKW	#$2106,f_ssw		; IF, read, supervisor program
	CHKL	#FMIRROR+$202,f_addr
	CHKW	#11,ncont

; 14: trace on 68010 instructions
	TEST	14
	EXPECT	.r1
	move.w	#$a700,sr
.i1:	movec	vbr,d0
.r1:	move.w	#$2700,sr
	FRAME0	9,.r1
	EXPECT	.r2
	move.w	#$a700,sr
	moves.l	MIRROR,d0
.r2:	move.w	#$2700,sr
	FRAME0	9,.r2
	EXPECT	.r3
	move.w	#$a700,sr
	move.w	ccr,d0
.r3:	move.w	#$2700,sr
	FRAME0	9,.r3

; 16: DIVU/DIVS results. In 68010 mode the prefetch at the end of DIVU starts
; before the division, the instruction after it takes its extension words
; from that prefetch (IRC and DBIN)
	TEST	16
	move.l	#$11223344,($7100).l
	move.w	#3,($7104).l
	move.l	#$00012345,d1		; DIVU, quotient bit 0 set (dvumf)
	move.w	#2,d2
	divu.w	d2,d1
	move.l	($7100).l,d3
	CHKL	#$000191a2,d1
	CHKL	#$11223344,d3
	move.l	#$00001000,d1		; DIVU, quotient bit 0 clear (dvumd)
	divu.w	($7104).l,d1
	move.l	#$55667788,d3
	CHKL	#$00010555,d1
	CHKL	#$55667788,d3
	move.l	#$00100000,d1		; DIVU overflow
	move.w	#1,d2
	move.w	#0,ccr
	divu.w	d2,d1
	move.w	ccr,d4
	movea.l	($7100).l,a1
	CHKL	#$00100000,d1
	and.w	#3,d4
	CHKW	#2,d4			; V set, C clear
	CHKL	#$11223344,a1
	move.l	#$fffffff0,d1		; DIVS, negative dividend
	move.w	#4,d2
	divs.w	d2,d1
	move.l	($7100).l,d3
	CHKL	#$0000fffc,d1
	CHKL	#$11223344,d3
	move.l	#$00001000,d1		; DIVS, negative divisor
	move.w	#$fff0,d2
	divs.w	d2,d1
	CHKL	#$0000ff00,d1
	move.l	#$ffffff00,d1		; DIVS, both negative
	divs.w	d2,d1
	CHKL	#$00000010,d1
	move.l	#$80000000,d1		; DIVS overflow, negative dividend
	move.w	#1,d2
	move.w	#0,ccr
	divs.w	d2,d1
	move.w	ccr,d4
	CHKL	#$80000000,d1
	and.w	#3,d4
	CHKW	#2,d4

; done
	move.l	FAILCNT,d0
	move.w	d0,END
	bra.s	*

fail_now:
	move.w	#$7fff,END
	bra.s	*
