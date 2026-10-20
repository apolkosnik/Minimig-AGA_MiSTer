; smoke test: TRAP and RTE
	org	0
	dc.l	$000f0000		; SSP
	dc.l	start			; PC
	dcb.l	30,unexpected
	dc.l	trap0			; vector 32
	dcb.l	223,unexpected

	org	$400
start:	move.l	#$12345678,d0
	trap	#0
	cmp.l	#$87654321,d0
	bne	fail
	move.w	#0,$ff0000
fail:	move.w	#1,$ff0000
unexpected:
	move.w	#2,$ff0000

trap0:	not.l	d0
	rol.l	#4,d0
	ror.l	#4,d0
	move.l	#$87654321,d0
	rte
