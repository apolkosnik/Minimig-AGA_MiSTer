; t_irqwedge_pipe.s - the board's black screen (2026-09-23): an interrupt that
; arrives while an instruction is PAST its first EA-fetch clock but has not
; yet issued a read it needs.  Runs under tb_ap040_pipe_compat.v.  Protocol:
; $F100 = failing check, $F102 = $600D.
;
; The hardware capture (ILA, build/stage_ap040_pipe_m9se_ila): Kickstart
; 46.143's timer.device ends a Disable()d section with Enable() -- the
; INTENA write that lets an already-pending Paula request through -- and
; RTS, returning into code that restores registers with MOVEM.  The core
; then stopped for good: no memory request, no fault, no exception entry.
;
; The mechanism this program pins: EA-fetch arms the interrupt (irq_take)
; one clock after it sees the request, in ANY phase that has no read in
; flight and issues none that clock.  While armed it suppresses every read,
; and it is TAKEN only in P_START / P_STOP.  An instruction that has left
; P_START (P_OPS, P_MOVEM) and still needs a read therefore never gets it,
; never finishes, never returns to P_START -- and the interrupt is never
; taken either.  Three shapes reach that clock:
;   A  MOVEM (An),<list> behind a DIVU: the load step waits for EX (stall)
;      with nothing in flight, for the whole of the divide
;   B  a subroutine that saves with MOVEM -(SP), does a store, restores with
;      MOVEM (SP)+ and returns -- the board's own sequence
;   C  a bitfield read behind an EX write of its offset register (bf_rdblk)
;   D  THE BOARD'S SEQUENCE: a routine ends with Enable() -- a slow
;      synchronous store that itself raises IPL part way through ($F158,
;      the bench's model of the uncached INTENA write) -- and RTS, returning
;      into a MOVEM (SP)+ restore.  The store holds WB, the RTS holds EX, the
;      MOVEM waits in P_MOVEM with nothing in flight, and the request lands
;      there.  The rise is swept across the store, clock by clock.
;
; The sweep moves the IPL arrival (the $F148 delay) across all three, one
; clock at a time, with the mask at 0 throughout: every pass must take the
; interrupt exactly once and leave every loaded register right.
;
;   1  a pass took the interrupt zero times or more than once
;   2  shape A loaded the wrong values
;   3  shape B restored the wrong values
;   4  shape C extracted the wrong field
;   5  the interrupt carried the wrong vector
;   6  the divide produced the wrong quotient
;   7  shape D: a pass took the interrupt zero times or more than once
;   8  shape D restored the wrong values

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
IPLDLY		equ	$F148		; raise level 2 N clocks from now
IOREG		equ	$3800		; the store (plain memory)
SLOWIE		equ	$F158		; slow store: IPL := data[2:0], data[15:8] clocks in
cnt_int		equ	$3600
bad_vec		equ	$3604
tbl		equ	$3700		; shape A's source
bfsrc		equ	$3720		; shape C's source

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	24
	dc.l	unexp		; 2-25
	endr
	dc.l	h_int2		; 26: autovector, level 2
	rept	229
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	clr.l	(cnt_int).l
	clr.l	(bad_vec).l
	lea	(tbl).l,a0
	move.l	#$11111111,(a0)+
	move.l	#$22222222,(a0)+
	move.l	#$33333333,(a0)+
	move.l	#$44444444,(a0)+
	move.l	#$A5C3F00F,(bfsrc).l

	moveq	#1,d3			; the delay under test
sweep:
	move.w	#0,(IPLREG).l		; the lines are idle before each pass
	move.l	(cnt_int).l,d5
	move.w	#$2000,sr		; mask 0: every arrival qualifies
	move.w	d3,(IPLDLY).l		; ... in d3 clocks from now

	; A: a MOVEM load waiting behind a divide in EX
	lea	(tbl).l,a0
	move.l	#100000,d1
	divu.w	#7,d1			; 14285 r 5 (check 6)
	movem.l	(a0),d0/d2/d4/a1

	; B: save, store, restore, return
	bsr	sub

	; C: a bitfield read whose offset register EX is still writing
	lea	(bfsrc).l,a2
	moveq	#8,d6
	bfextu	(a2){d6:8},d7		; bits 8-15 of $A5C3F00F = $C3

	nop				; let an arrival that came in
	nop				; late land at a boundary
	nop
	nop
	nop
	nop
	move.w	#$2700,sr
	move.w	#0,(IPLREG).l

	move.l	(cnt_int).l,d6		; 1: exactly one interrupt per pass
	sub.l	d5,d6
	cmp.l	#1,d6
	beq.s	c1_ok
	failt	1
c1_ok:
	cmp.l	#$11111111,d0		; 2
	bne.s	c2_bad
	cmp.l	#$22222222,d2
	bne.s	c2_bad
	cmp.l	#$33333333,d4
	bne.s	c2_bad
	cmpa.l	#$44444444,a1
	beq.s	c2_ok
c2_bad:	failt	2
c2_ok:
	cmp.l	#$5A5A5A5A,a3		; 3: the values sub restored
	bne.s	c3_bad
	cmp.l	#$A5A5A5A5,a4
	beq.s	c3_ok
c3_bad:	failt	3
c3_ok:
	cmp.l	#$C3,d7			; 4
	beq.s	c4_ok
	failt	4
c4_ok:
	cmp.l	#$000537CD,d1		; 6: 100000 = 7 * 14285 + 5
	beq.s	c6_ok
	failt	6
c6_ok:
	addq.w	#1,d3
	cmp.w	#90,d3			; wide enough to cross all three shapes
	bls	sweep

	; D: Enable() + RTS into a MOVEM restore, the rise swept across the store
	moveq	#0,d3
sweep_d:
	move.w	#0,(IPLREG).l
	move.l	(cnt_int).l,d5
	move.w	#$2000,sr
	move.l	#$0BADCAFE,d0
	move.l	#$FEEDF00D,d1
	movem.l	d0-d1,-(sp)
	moveq	#0,d0
	moveq	#0,d1
	move.w	d3,d4
	lsl.w	#8,d4
	or.w	#2,d4			; level 2, d3 clocks into the store
	bsr	enable_sub
	movem.l	(sp)+,d0-d1		; the caller's restore
	nop
	nop
	nop
	nop
	nop
	nop
	move.w	#$2700,sr
	move.w	#0,(IPLREG).l
	move.l	(cnt_int).l,d6		; 7
	sub.l	d5,d6
	cmp.l	#1,d6
	beq.s	c7_ok
	failt	7
c7_ok:
	cmp.l	#$0BADCAFE,d0		; 8
	bne.s	c8_bad
	cmp.l	#$FEEDF00D,d1
	beq.s	c8_ok
c8_bad:	failt	8
c8_ok:
	addq.w	#1,d3
	cmp.w	#30,d3			; past the store's 24-clock acknowledge
	bls	sweep_d

	move.l	(bad_vec).l,d0		; 5
	tst.l	d0
	beq.s	v_ok
	failt	5
v_ok:
	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

sub:
	move.l	#$5A5A5A5A,a3
	move.l	#$A5A5A5A5,a4
	movem.l	a3/a4,-(sp)
	move.l	#0,a3
	move.l	#0,a4
	move.w	#$C000,(IOREG).l	; the Enable() store
	movem.l	(sp)+,a3/a4
	rts

enable_sub:
	move.w	d4,(SLOWIE).l		; Enable(): the write that lets IPL through
	rts

h_int2:
	addq.l	#1,(cnt_int).l
	move.w	#0,(IPLREG).l
	cmpi.w	#$0068,6(sp)		; format $0, vector offset $68
	beq.s	hi_ok
	addq.l	#1,(bad_vec).l
hi_ok:
	rte

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
unexp:
	move.w	6(sp),d7
	andi.w	#$0FFF,d7
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
