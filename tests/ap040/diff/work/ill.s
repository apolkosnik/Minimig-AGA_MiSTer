	org	0
	dc.l	$3400
	dc.l	start
	dc.l	unexp,unexp		; 2,3
	dc.l	h_ill			; 4 illegal instruction
	rept	251
	dc.l	unexp			; 5-255
	endr
	org	$400
start:
	move.w	#$2700,sr
	movea.l	#$3400,sp		; ISP
	movea.l	#$3000,a0
	movec	a0,usp			; USP = $3000
	move.l	#0,($3F00).l		; USP observed in handler
	move.l	#0,($3F04).l		; USP after return
	move.l	#0,($3F08).l		; stacked frame PC
; drop to user mode and execute the illegal opcode $003A
	move.w	#$0000,-(sp)
	pea	utest(pc)
	move.w	#$0000,-(sp)
	rte
utest:
	dc.w	$003A			; ori.b #x,(d16,pc): not alterable
	nop
ucont:
	trap	#0			; never reached
h_ill:
	move.l	2(sp),d0		; stacked PC
	move.l	d0,($3F08).l
	move	usp,a1			; USP as seen during the exception
	move.l	a1,($3F00).l
	move.l	a1,($3F04).l
	move.w	#$600D,($F102).l
stop1:	bra	stop1
unexp:
	move.l	#$99,($3F00).l
	move.w	6(sp),d0
	and.l	#$FFFF,d0
	move.l	d0,($3F0C).l		; format/vector word
	move.l	2(sp),($3F08).l		; stacked PC
	move	usp,a1
	move.l	a1,($3F04).l
	move.w	#$600D,($F102).l
stop2:	bra	stop2
