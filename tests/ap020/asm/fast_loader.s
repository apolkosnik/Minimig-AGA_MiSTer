; AP020: loader for a program image that runs from Fast RAM
; assembled with vasmm68k_mot -Fbin -m68020 -I<dir of dhry_fast_img.bin>
; Vectors and handlers stay in chip RAM (VBR = 0).  Configures the Zorro II
; memory card, copies the image to $200000, sets the stack in Fast RAM and
; jumps to the image.
FAILREG	equ	$F100
DONEREG	equ	$F102
FAST	equ	$200000

	org	0
	dc.l	$3400
	dc.l	start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	move.b	#$20,$E80048		; configure the Zorro II memory card
	lea	image(pc),a0
	lea	FAST,a1
	move.l	#(image_end-image+3)/4-1,d0
copy:	move.l	(a0)+,(a1)+
	subq.l	#1,d0
	bpl.s	copy
	lea	FAST+$F0000,sp		; stack in Fast RAM
	jmp	FAST

unexp:
	move.w	#$00FF,FAILREG
	move.w	#$BAD0,DONEREG
halt:	bra.s	halt

	cnop	0,4
image:
	incbin	"dhry_fast_img.bin"
image_end:
