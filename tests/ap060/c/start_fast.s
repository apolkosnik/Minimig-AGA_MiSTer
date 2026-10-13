; AP060: entry of a C program linked to run from Fast RAM ($200000); the
; chip-RAM loader (asm/fast_loader.s) has configured the card, copied this
; image and set the stack.  Both 68060 caches on (CACR EDC, EIC); the
; default data cache mode with the MMU off is write-through (TCR = 0).
	section	"CODE",code
	xref	_main
_start:
	move.l	#$80008000,d0
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
