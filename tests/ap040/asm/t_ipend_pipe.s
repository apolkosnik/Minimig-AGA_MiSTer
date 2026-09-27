; t_ipend_pipe.s - plan M9.T step 5: the IPEND claim, swept across a mask
; raise, with a range calibrated to THIS pipeline.  Runs under
; tb_ap040_pipe_compat.v.  Protocol: $F100 = failing check, $F102 = $600D.
;
; This is the pipelined core's replacement for t_exceptions.s test 136.  That
; test sweeps an IPL arrival delay of 1..20 clocks across a MOVE to SR that
; RAISES the mask and requires the sweep to STRADDLE it -- some arrivals
; qualify before the raise and are taken, some arrive after and are not.  The
; window is a property of the core's instruction timing, and this core is
; faster than the reference, so the reference's range does not straddle here.
;
; The rule itself -- a request that QUALIFIED against the mask must be taken
; at a following instruction boundary even though the mask went up in the
; meantime, which is what the 68040's IPEND bit means -- is asserted by the
; BENCH's tb_must shadow, which now watches this pipeline's own signals
; (M9.T step 4 found it had been shadowing nothing).  What this program adds
; is the evidence that the sweep actually exercised both sides of the rule.
;
;   1  at least one delay in the sweep was TAKEN (the arrival beat the raise)
;   2  at least one was NOT (it arrived after the mask closed), so the
;      bench's claim logic was exercised on both sides
;   3  every interrupt that was taken carried level 2's vector

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
IPLDLY		equ	$F148		; raise level 2 N clocks from now
cnt_int		equ	$3600
bad_vec		equ	$3604
taken		equ	$3608
notaken		equ	$360C

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
	clr.l	(taken).l
	clr.l	(notaken).l

	moveq	#1,d3			; the delay under test
sweep:
	move.w	#0,(IPLREG).l		; the lines are idle before each pass
	move.w	#$2000,sr		; mask 0: an arrival here QUALIFIES
	move.l	(cnt_int).l,d5
	move.w	d3,(IPLDLY).l		; ... in d3 clocks from now
	nop				; an arrival landing HERE qualifies and is
	nop				; taken at the next boundary
	nop
	move.w	#$2700,sr		; the mask closes around the arrival: an
	nop				; arrival after this point never qualifies
	nop
	nop
	nop
	nop
	nop
	move.w	#0,(IPLREG).l		; ... and the device withdraws it, so it
					; cannot leak into the next pass
	move.l	(cnt_int).l,d6
	sub.l	d5,d6			; 0 or 1 for this delay
	beq.s	sw_not
	addq.l	#1,(taken).l
	bra.s	sw_next
sw_not:
	addq.l	#1,(notaken).l
sw_next:
	addq.w	#1,d3
	cmp.w	#40,d3			; a wider sweep than the reference's 20:
	bls.s	sweep			; the coincidence moves with core speed
	move.w	#0,(IPLREG).l

	move.l	(taken).l,d0		; 1
	tst.l	d0
	bne.s	t_ok
	failt	1
t_ok:
	move.l	(notaken).l,d0		; 2
	tst.l	d0
	bne.s	n_ok
	failt	2
n_ok:
	move.l	(bad_vec).l,d0		; 3
	tst.l	d0
	beq.s	v_ok
	failt	3
v_ok:
	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

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
