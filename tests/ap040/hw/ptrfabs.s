; ptrfabs -- minimal on-hardware reproduction probe for the cputest
; 68040_basicfpu FABS.X ([0]) failure (expected 0000-b6bad82c00000000,
; got 401c-d82c00000000df00 = the extended window 2 bytes higher).
;
; Runs the exact cputest per-test sequence standalone: rewrite the
; memory-indirect pointer at absolute address 0, immediately execute
; the exact instruction encoding F236 4998 95D1, compare FP3 against
; the freshly written pointer's operand window.  Three phases:
;   A: interrupts disabled, pointer rewritten before every dereference
;   B: interrupts enabled,  pointer rewritten before every dereference
;   C: interrupts disabled, pointer written once (static control)
; Output: "A:<fails> B:<fails> C:<fails> F:<first failing 12 bytes>"
;
; Assemble: vasmm68k_mot -Fhunkexe -m68040 -no-opt -o ptrfabs ptrfabs.s
; Run from an AmigaShell on the MiSTer (68040/AP040 core).

_LVODisable	equ	-120
_LVOEnable	equ	-126
_LVOAllocMem	equ	-198
_LVOFreeMem	equ	-210
_LVOCloseLibrary equ	-414
_LVOOpenLibrary	equ	-552
_LVORawDoFmt	equ	-522
_LVOOutput	equ	-60
_LVOWrite	equ	-48

LOOPS		equ	50000

	rsreset
v_dosbase	rs.l	1
v_chip		rs.l	1
v_save0		rs.l	1
v_tmp		rs.l	3
v_ff		rs.l	3
v_ffvalid	rs.w	1
		rs.w	1
v_buf		rs.b	128
v_size		rs.b	0

	SECTION	text,CODE

start:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	4.w,a6			; ExecBase
	lea	vars,a5

	lea	dosname(pc),a1
	moveq	#0,d0
	jsr	_LVOOpenLibrary(a6)
	move.l	d0,v_dosbase(a5)
	beq	exit_nodos

	move.l	#32,d0			; operand image block
	moveq	#2,d1			; MEMF_CHIP
	jsr	_LVOAllocMem(a6)
	move.l	d0,v_chip(a5)
	beq	exit_nochip

	; install the screenshot's operand image at chip+1 (odd address):
	; 00 00 40 1c b6 ba d8 2c 00 00 00 00 df 00
	move.l	v_chip(a5),a0
	lea	image(pc),a1
	moveq	#13,d0
.copy:
	move.b	(a1)+,1(a0)
	addq.l	#1,a0
	dbra	d0,.copy

	move.l	($0).w,v_save0(a5)	; preserve location 0

	moveq	#0,d3			; phase A fails
	moveq	#0,d4			; phase B fails
	moveq	#0,d5			; phase C fails
	clr.w	v_ffvalid(a5)

	; ---------------- phase A: Disable, rewrite every iteration
	jsr	_LVODisable(a6)
	bsr	loop_rewrite
	move.l	d0,d3
	jsr	_LVOEnable(a6)

	; ---------------- phase B: interrupts live
	bsr	loop_rewrite
	move.l	d0,d4

	; ---------------- phase C: Disable, static pointer
	jsr	_LVODisable(a6)
	bsr	loop_static
	move.l	d0,d5
	jsr	_LVOEnable(a6)

	move.l	v_save0(a5),($0).w	; restore location 0

	; ---------------- report
	move.l	v_ff+8(a5),-(sp)
	move.l	v_ff+4(a5),-(sp)
	move.l	v_ff(a5),-(sp)
	move.l	d5,-(sp)
	move.l	d4,-(sp)
	move.l	d3,-(sp)
	lea	fmt(pc),a0
	move.l	sp,a1
	lea	putch(pc),a2
	lea	v_buf(a5),a3
	jsr	_LVORawDoFmt(a6)
	lea	24(sp),sp

	move.l	v_dosbase(a5),a6
	jsr	_LVOOutput(a6)
	move.l	d0,d1
	beq	skip_write
	lea	v_buf(a5),a0
	move.l	a0,d2
	moveq	#-1,d3
.len:
	addq.l	#1,d3
	tst.b	(a0)+
	bne.s	.len
	jsr	_LVOWrite(a6)
skip_write:

	move.l	4.w,a6
	move.l	v_chip(a5),a1
	move.l	#32,d0
	jsr	_LVOFreeMem(a6)
exit_nochip:
	move.l	4.w,a6
	move.l	v_dosbase(a5),a1
	jsr	_LVOCloseLibrary(a6)
exit_nodos:
	movem.l	(sp)+,d2-d7/a2-a6
	moveq	#0,d0
	rts

; RawDoFmt character sink: a3 advances through v_buf
putch:
	move.b	d0,(a3)+
	rts

;-------------------------------------------------------------------------
; one full rewrite-alternating pass; returns fail count in d0
loop_rewrite:
	movem.l	d2/d6/a0-a2,-(sp)
	moveq	#0,d0
	move.l	#LOOPS-1,d6
	move.l	v_chip(a5),a1
	lea	1(a1),a0		; P1: window se=0000
	lea	3(a1),a1		; P2: window se=401c
	lea	v_tmp(a5),a2
.it:
	move.l	a0,($0).w		; fresh pointer P1
	fmove.l	#1,fp3
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,(a2)
	tst.l	(a2)
	bne.s	.bad1
	cmpi.l	#$B6BAD82C,4(a2)
	bne.s	.bad1
	tst.l	8(a2)
	bne.s	.bad1
.p2:
	move.l	a1,($0).w		; fresh pointer P2
	fmove.l	#1,fp3
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,(a2)
	cmpi.l	#$401C0000,(a2)
	bne.s	.bad2
	cmpi.l	#$D82C0000,4(a2)
	bne.s	.bad2
	cmpi.l	#$0000DF00,8(a2)
	bne.s	.bad2
.next:
	dbra	d6,.it
	movem.l	(sp)+,d2/d6/a0-a2
	rts
.bad1:
	addq.l	#1,d0
	bsr.s	record_ff
	bra.s	.p2
.bad2:
	addq.l	#1,d0
	bsr.s	record_ff
	bra.s	.next

; static-pointer control: write P1 once, dereference in a loop
loop_static:
	movem.l	d6/a0/a2,-(sp)
	moveq	#0,d0
	move.l	v_chip(a5),a0
	addq.l	#1,a0
	move.l	a0,($0).w		; pointer written ONCE
	move.l	#LOOPS-1,d6
	lea	v_tmp(a5),a2
.it:
	fmove.l	#1,fp3
	dc.w	$F236,$4998,$95D1	; fabs.x ([0]),fp3
	fmovem.x	fp3,(a2)
	tst.l	(a2)
	bne.s	.bad
	cmpi.l	#$B6BAD82C,4(a2)
	bne.s	.bad
	tst.l	8(a2)
	bne.s	.bad
.next:
	dbra	d6,.it
	movem.l	(sp)+,d6/a0/a2
	rts
.bad:
	addq.l	#1,d0
	bsr.s	record_ff
	bra.s	.next

; keep the first failing 12-byte image for the report
record_ff:
	tst.w	v_ffvalid(a5)
	bne.s	.done
	move.w	#1,v_ffvalid(a5)
	move.l	v_tmp(a5),v_ff(a5)
	move.l	v_tmp+4(a5),v_ff+4(a5)
	move.l	v_tmp+8(a5),v_ff+8(a5)
.done:
	rts

dosname:
	dc.b	"dos.library",0
fmt:
	dc.b	"A:%ld B:%ld C:%ld F:%08lx %08lx %08lx",10,0
image:
	dc.b	$00,$00,$40,$1C,$B6,$BA,$D8,$2C
	dc.b	$00,$00,$00,$00,$DF,$00
	even

	SECTION	bss,BSS
vars:
	ds.b	v_size
