; AP020 startup for compiled C on the Minimig chip bench (64 KB of RAM):
; vectors, stack, main, verdict through the bench's control ports
	section	"CODE",code
	xref	_main
	dc.l	$0000E000		; initial ISP (below the control ports at $F1xx)
	dc.l	_start
	rept	254
	dc.l	_unexp
	endr
_start:
	jsr	_main
	tst.l	d0
	bne.s	_fail
	move.w	#$600D,($F102).l
	stop	#$2700
_fail:
	move.w	d0,($F100).l
	move.w	#$BAD0,($F102).l
_h1:	bra.s	_h1
_unexp:
	move.w	#$00FF,($F100).l
	move.w	#$BAD0,($F102).l
_h2:	bra.s	_h2
