; AP030: entry of a C program linked to run from Fast RAM ($200000); the
; chip-RAM loader (asm/fast_loader.s) has configured the card, copied this
; image and set the stack.  Caches on (both, bursts, write allocate).
	section	"CODE",code
	xref	_main
_start:
	move.l	#$00003111,d0
	movec	d0,cacr
	jsr	_main
	tst.l	d0
	bne.s	_fail
	move.w	#$600D,($F102).l
	stop	#$2700
_fail:
	move.w	d0,($F100).l
	move.w	#$BAD0,($F102).l
_h1:	bra.s	_h1
