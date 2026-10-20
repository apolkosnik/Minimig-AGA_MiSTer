; excep.s - exception processing on both 68000 and 68010
;
; Takes every kind of exception the 68000 has, plus the 68010 instructions
; (illegal on a 68000). Handlers detect the CPU (MOVEC is illegal on a 68000)
; and handle both frame formats, so the program runs in both modes. Each
; exception is logged at LOG: vector, SR, PC, and for bus and address errors
; the access address and status word.
;
; In 68000 mode the bus cycles must be identical on the original and the
; new fx68k.

LOG		equ	$9000
logptr		equ	$7000
resume		equ	$7004
lastvec		equ	$7008
is010		equ	$700a
save_a0		equ	$700c
nint		equ	$7010
END		equ	$ff0000
IPL		equ	$ff0002
BERRADR		equ	$fe0000
SSP_TOP		equ	$000f0000
USP_TOP		equ	$000e0000

	org	0
	dc.l	SSP_TOP
	dc.l	start
vn	set	2
	rept	254
	dc.l	vstubs+vn*14
vn	set	vn+1
	endr

vstubs:
vn	set	0
	rept	256
	move.w	#vn,lastvec
	jmp	handler
vn	set	vn+1
	endr

; log the exception and resume, both frame formats
handler:
	cmpi.w	#47,lastvec		; TRAP #15: back to supervisor mode
	bne.s	.log
	ori.w	#$2700,(sp)
	rte
.log:	move.l	a0,save_a0
	movea.l	logptr,a0
	move.w	lastvec,(a0)+
	cmpi.w	#4,lastvec
	bcc.s	.grp12
	cmpi.w	#2,lastvec
	bcs.s	.grp12
	tst.w	is010
	bne.s	.g0_010
	move.w	8(sp),(a0)+		; 68000 group 0: SR, PC, address, SSW
	move.l	10(sp),(a0)+
	move.l	2(sp),(a0)+
	move.w	(sp),(a0)+
	move.l	a0,logptr
	movea.l	save_a0,a0
	addq.l	#8,sp
	bra.s	.ret
.g0_010:
	move.w	(sp),(a0)+		; 68010 format 8
	move.l	2(sp),(a0)+
	move.l	10(sp),(a0)+
	move.w	8(sp),(a0)+
	move.l	a0,logptr
	movea.l	save_a0,a0
	move.w	(sp),50(sp)		; abandon the faulted instruction: return with
	move.w	6(sp),56(sp)		; a format 0 frame instead of format 8
	andi.w	#$0fff,56(sp)
	lea	50(sp),sp
	bra.s	.ret
.grp12:	move.w	(sp),(a0)+
	move.l	2(sp),(a0)+
	cmpi.w	#24,lastvec		; interrupt: clear the request
	bcs.s	.done
	cmpi.w	#31,lastvec
	bhi.s	.done
	move.w	#0,IPL
	addq.w	#1,nint
.done:	move.l	a0,logptr
	movea.l	save_a0,a0
.ret:	andi.w	#$7fff,(sp)		; no trace after the return
	tst.l	resume
	beq.s	.same
	move.l	resume,2(sp)
	clr.l	resume
.same:	rte

; next exception resumes at \1
AT	macro
	move.l	#\1,resume
	endm

SETODD	macro
	movea.l	#$7101,a0
	endm

	org	$2000
start:	move.l	#LOG,logptr
	clr.l	resume
	clr.w	is010
	clr.w	nint
	lea	USP_TOP,a0
	move.l	a0,usp
	; CPU detection: MOVEC is illegal on a 68000
	AT	.cpu0
	movec	vbr,d0
	move.w	#1,is010
.cpu0:

	; traps
	AT	.t0
	trap	#0
.t0:	AT	.t1
	trap	#1
.t1:	AT	.t2
	trap	#7
.t2:	AT	.t3
	trap	#14
.t3:	move.w	#$2702,sr
	AT	.t4
	move.w	#$2702,sr
	trapv
.t4:	move.w	#$2700,sr
	trapv				; no trap

	; CHK
	moveq	#5,d0
	moveq	#10,d1
	chk.w	d1,d0			; no trap
	AT	.c1
	chk.w	#3,d0
.c1:	moveq	#-2,d0
	AT	.c2
	chk.w	d1,d0
.c2:	lea	$7100,a0
	move.w	#2,(a0)
	moveq	#7,d0
	AT	.c3
	chk.w	(a0),d0
.c3:
	; divide by zero
	moveq	#0,d1
	AT	.d1
	divu.w	d1,d0
.d1:	AT	.d2
	divs.w	#0,d0
.d2:	clr.w	(a0)
	AT	.d3
	divu.w	(a0),d0
.d3:	AT	.d4
	divs.w	2(a0),d0
.d4:
	; illegal and unimplemented opcodes
	AT	.i1
	illegal
.i1:	AT	.i2
	dc.w	$a000
.i2:	AT	.i3
	dc.w	$afff
.i3:	AT	.i4
	dc.w	$f000
.i4:	AT	.i5
	dc.w	$ffff
.i5:	AT	.i6
	dc.w	$4e7a,$0801		; movec (68010)
.i6:	AT	.i7
	dc.w	$4e7b,$0000
.i7:	AT	.i8
	dc.w	$0e50,$0000		; moves (68010)
.i8:	AT	.i9
	dc.w	$42c0			; move from ccr (68010)
.i9:	AT	.i10
	pea	.i10
	dc.w	$4e74,$0000		; rtd (68010)
.i10:	tst.w	is010
	bne.s	.i10a
	addq.l	#4,sp			; illegal on a 68000, return address still stacked
.i10a:	AT	.i11
	dc.w	$4848			; bkpt (68010)
.i11:	AT	.i12
	dc.w	$4afb
.i12:	AT	.i13
	dc.w	$42fc			; move ccr,#imm
.i13:	AT	.i14
	dc.w	$40fa			; move sr,(d16,pc)
.i14:
	; privilege violations from user mode
	andi.w	#$d8ff,sr
	AT	.p1
	move.w	#$2000,sr
.p1:	AT	.p2
	ori.w	#$0700,sr
.p2:	AT	.p3
	andi.w	#$f8ff,sr
.p3:	AT	.p4
	eori.w	#$2000,sr
.p4:	AT	.p5
	move.l	a0,usp
.p5:	AT	.p6
	move.l	usp,a1
.p6:	AT	.p7
	reset
.p7:	AT	.p8
	rte
.p8:	AT	.p9
	stop	#$2000
.p9:	AT	.p10
	dc.w	$4e7a,$0801		; movec in user mode (privilege violation on a 68010)
.p10:	AT	.p11
	move.w	sr,d0			; privileged on a 68010
.p11:	trap	#15
	move.w	#$2700,sr

	; trace
	AT	.r1
	move.w	#$a700,sr
	nop
.r1:	AT	.r2
	move.w	#$a700,sr
	bra.s	.r2t
	nop
.r2t:	nop
.r2:	AT	.r3
	move.w	#$a700,sr
	move.l	d0,d1
.r3:	move.w	#$2700,sr
	AT	.r4
	move.w	#$a700,sr
	dbf	d0,.r4
.r4:	move.w	#$2700,sr

	; interrupts, autovectored, taken during STOP
	AT	.n1
	move.w	#1,IPL
	stop	#$2000
.n1:	AT	.n2
	move.w	#4,IPL
	stop	#$2300
.n2:	AT	.n3
	move.w	#7,IPL
	stop	#$2700
.n3:	move.w	#$2000,sr
	move.w	#6,IPL			; taken in the instruction stream
	nop
	nop
	nop
	nop
	move.w	#$2700,sr
	move.w	#2,IPL			; masked
	nop
	move.w	#$2200,sr		; still masked
	nop
	move.w	#$2000,sr		; taken
	nop
	nop
	move.w	#$2700,sr

	; address errors
	SETODD
	AT	.a1
	move.w	(a0),d0
.a1:	SETODD
	AT	.a2
	move.l	d0,(a0)
.a2:	SETODD
	AT	.a3
	move.w	(a0)+,d0
.a3:	SETODD
	AT	.a4
	add.w	-(a0),d0
.a4:	SETODD
	AT	.a5
	jmp	(a0)
.a5:	SETODD
	AT	.a6
	jsr	2(a0)
.a6:	move.l	sp,d7
	AT	.a7
	move.l	#$7101,-(sp)
	rts
.a7:	movea.l	d7,sp
	SETODD
	AT	.a8
	movem.w	d0-d3,(a0)
.a8:	SETODD
	AT	.a9
	movem.l	(a0),d0-d3
.a9:	AT	.a10
	move.w	$7103,d0
.a10:	SETODD
	AT	.a11
	clr.w	2(a0)
.a11:	SETODD
	andi.w	#$d8ff,sr		; user mode
	AT	.a12
	move.w	(a0),d0
.a12:	trap	#15
	move.w	#$2700,sr

	; bus errors
	AT	.b1
	move.w	BERRADR,d0
.b1:	AT	.b2
	move.w	d0,BERRADR+2
.b2:	AT	.b3
	move.b	BERRADR+5,d0
.b3:	AT	.b4
	move.l	BERRADR+8,d0
.b4:	AT	.b5
	jmp	BERRADR+$100
.b5:	AT	.b6
	tas	BERRADR+$11
.b6:	AT	.b7
	movem.l	BERRADR+$20,d0-d1
.b7:
	; TAS, RESET, RTR, MOVE USP, STOP from supervisor
	lea	$7200,a0
	clr.b	(a0)
	tas	(a0)
	tas	(a0)
	reset
	pea	.s1
	move.w	#$001f,-(sp)
	rtr
.s1:	move.w	sr,d0
	move.w	#$2700,sr
	lea	$e1000,a1
	move.l	a1,usp
	move.l	usp,a2
	move.w	d0,(LOG-4).l
	move.l	a2,(LOG-8).l
	move.l	logptr,d0
	sub.l	#LOG,d0
	move.w	d0,(LOG-10).l
	move.w	nint,(LOG-12).l
	move.w	#0,END
	bra.s	*
