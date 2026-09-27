; t_specread_pipe.s - no data read for an instruction the program does not
; execute.  A 68040 issues an operand read only for an instruction on the
; path it executes; an Amiga has read-sensitive registers (a CIA's ICR
; clears on read, DSKBYTR, serial data), so a read issued down a wrongly
; guessed path is a lost interrupt, not a harmless prefetch.  Runs under
; tb_ap040_pipe_compat.v, whose $F180 counts every read of it the core
; completes (the word at $F182).  Protocol: $F100 = failing check, $F102 =
; $600D / $BAD0.
;
; Found by the Kickstart bench with everything cacheable and the M14 read
; paths: exec's VHPOSR wait (`move.w (a0),d0 / dbra d1,*-2`) read $DFF006
; once more after the loop ended -- EA-calc's early read for the loop-top
; MOVE, the path ID guessed for the DBRA, went out before EA-fetch
; corrected the branch.
;
;   1  DBRA loop exit: the loop-top read of $F180 happens exactly once per
;      executed iteration (5)
;   2  a not-taken Bcc whose guessed target reads $F180: no read
;   3  an RTS followed by a read of $F180 that never runs: no read
;   4  a JMP (An) followed by one: no read
; each over four NOP distances, with the instruction read path hot.

FAILREG	equ	$F100
DONEREG	equ	$F102
CNT	equ	$F182

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

chkcnt	macro			; the count must be \1, else fail \2
	move.w	CNT,d0
	cmp.w	#\1,d0
	beq.s	.ok\@
	move.w	#\2,d7
	bra	fail_all
.ok\@:
	endm

	org	$400
start:	move.l	#$00008000,d0		; IE only: $F180/$F182 are read from memory
	movec	d0,cacr
	cpusha	bc
	lea	$F180,a0
	moveq	#1,d5			; Z = 0 for the Bcc shapes

	moveq	#3,d6			; four passes, the second onwards all hot
.pass:
; 1: DBRA exit
	clr.w	CNT
	moveq	#4,d1
.l1:	move.w	(a0),d0
	dbra	d1,.l1
	nop
	nop
	chkcnt	5,1
; 2: not-taken Bcc, guessed target reads
	clr.w	CNT
	tst.l	d5
	beq.b	.t2
	nop
	bra.b	.j2
.t2:	move.w	(a0),d0
.j2:	chkcnt	0,2
; 3: RTS, and a read after it that never runs
	clr.w	CNT
	bsr	r3
	chkcnt	0,3
; 4: JMP (An), and a read after it that never runs
	clr.w	CNT
	lea	.j4,a1
	jmp	(a1)
	move.w	(a0),d0
	move.w	(a0),d0
.j4:	chkcnt	0,4
	dbra	d6,.pass

	move.w	#$600d,DONEREG
.h:	bra.s	.h

r3:	rts
	move.w	(a0),d0
	move.w	(a0),d0

fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f
unexp:	move.w	#99,d7
	bra.s	fail_all
