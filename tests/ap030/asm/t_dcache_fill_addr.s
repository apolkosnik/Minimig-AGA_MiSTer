; AP030 data-cache fill address across a 16-byte line boundary.
; The wrapper bench aliases ROM to the low 64 KB of its backing memory.
; Seed through uncached chip RAM, then read through cacheable 16-bit ROM.
; The first portion of the misaligned longword finishes before the bus
; completes its cache entry. That fill must retain the original line address.
; Runs in every tb_ap030_wrapchip configuration; no Fast RAM is required.

FAILREG	equ	$F100
DONEREG	equ	$F102

chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	move.w	#\3,d7
	bra	fail_all
ok\@:
	endm

	org	0
	dc.l	$3400,start
	rept	254
	dc.l	unexp
	endr

	org	$400
start:
	moveq	#0,d0
	movec	d0,cacr
	move.l	#$1122CCDD,$310C
	move.l	#$55667788,$3110
	move.l	#$99AABBCC,$311C
	move.l	#$900,d0		; clear and enable the data cache
	movec	d0,cacr
	move.l	$F8310E,d0
	chkl	d0,$CCDD5566,1
	; The fill for $F8310C must not have populated $F8311C.
	move.l	$F8311C,d0
	chkl	d0,$99AABBCC,2
	move.w	#$600D,DONEREG
	stop	#$2700

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
	stop	#$2700
unexp:
	move.w	#$FF,d7
	bra	fail_all
