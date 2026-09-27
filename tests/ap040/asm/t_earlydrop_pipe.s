; t_earlydrop_pipe.s - an early read that belongs to a WRONG-PATH instruction
; must be thrown away when EA-fetch's own redirect flushes that instruction.
; Runs under tb_ap040_pipe_compat.v.  Protocol: $F100 = failing check, $F102
; = $600D / $BAD0.
;
; Found by the Kickstart bench with everything cacheable (M14 step 1, the
; pipelined instruction read path): exec's Enqueue at $F81B2C,
;     beq.b  $F81B34        ; not taken -- ID guesses taken
;     cmp.b  9(a0),d1
;     ...
; $F81B34: move.l 4(a0),d0   ; the guessed path
; With fetches answered in a clock, the guessed path's MOVE reached EA-calc
; and its early read of 4(a0) went out before EA-fetch corrected the branch.
; EA-fetch's redirect flushes EA-calc and ID (flush_eac), but rd_drop was set
; only by EX's redirect or WB's SMC refetch (EA-fetch's own `flush`), so the
; late answer of 4(a0) was captured as the CMP's operand.
;
; The check: a not-taken Bcc whose guessed target reads a COLD line (a slow
; answer: a miss, a line fill through the 16-bit bus) and whose fall-through
; reads a HOT longword.  The fall-through must see the HOT value.  The
; distance between the two reads is swept with a run of NOPs in front of the
; Bcc and with the target's alignment, over 16 cold lines.
;   1  the fall-through read returned the wrong-path operand

FAILREG	equ	$F100
DONEREG	equ	$F102
HOT	equ	$2000
COLD	equ	$4000		; 16 lines, $4000-$40FF, each cold on first touch

	org	0
	dc.l	$7000
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:	move.l	#$80008000,d0
	movec	d0,cacr
	cpusha	bc
	move.l	#$600dcafe,HOT
	lea	HOT,a1
	moveq	#1,d5			; Z = 0: every beq below falls through
	move.l	(a1),d0			; HOT is hot
	lea	COLD,a0
	moveq	#15,d6			; 16 cold lines ...
.line:	lea	shapes,a3
	moveq	#7,d4			; ... times 8 shapes
.shape:	move.l	(a3)+,a2
	move.l	#$bad0bad0,4(a0)	; the wrong-path operand (write-through,
	cinva	dc			;  no allocate; then make the line a miss)
	move.l	(a1),d0			; HOT hot again
	moveq	#0,d2
	jsr	(a2)
	cmp.l	#$600dcafe,d2
	bne	fail1
	dbra	d4,.shape
	lea	16(a0),a0
	dbra	d6,.line
	bra	pass

fail1:	move.w	#1,d7
	bra	fail_all
pass:	move.w	#$600d,DONEREG
.h:	bra.s	.h
fail_all:
	move.w	d7,FAILREG
	move.w	#$bad0,DONEREG
.f:	bra.s	.f
unexp:	move.w	#99,d7
	bra.s	fail_all

; shapes: 0..3 NOPs in front of the branch, the target on either word
; alignment: 8 routines, each `tst.l d5 / beq.b target / move.l (a1),d2 /
; rts / [pad] target: move.l 4(a0),d2 / rts`
SHAPE	macro			; \1 = NOPs, \2 = 1 to put a word of padding before the target
	rept	\1
	nop
	endr
	tst.l	d5
	beq.b	.t\@
	move.l	(a1),d2
	rts
	if	\2
	dc.w	$4afc
	endif
.t\@:	move.l	4(a0),d2
	rts
	endm

	cnop	0,4
shapes:	dc.l	s0,s1,s2,s3,s4,s5,s6,s7
	cnop	0,4
s0:	SHAPE	0,0
	cnop	0,4
s1:	SHAPE	0,1
	cnop	0,4
s2:	SHAPE	1,0
	cnop	0,4
s3:	SHAPE	1,1
	cnop	0,4
s4:	SHAPE	2,0
	cnop	0,4
s5:	SHAPE	2,1
	cnop	0,4
s6:	SHAPE	3,0
	cnop	0,4
s7:	SHAPE	3,1
