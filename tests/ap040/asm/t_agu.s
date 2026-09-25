; Addresses made a stage early (doc_AP040_PIPELINE_RESTRUCTURING_PLAN.md,
; phase 4). The pipelined core forms the address of a simple access --
; (An), (An)+, -(An), (d16,An), absolute -- in EA-calculate, before the
; instructions ahead of it have finished, so the base can come from any of:
; the instruction just ahead's own (An)+/-(An) step, EX's result (an ALU
; result or a load's data), EX's An step, a register a MOVEM has just
; loaded, or the register file. Every case here puts the access straight
; behind the instruction that makes its base, once for each of those. Runs
; on both cores (tests/ap040/run_verilator.py and run_pipe_verilator.py).
;
;  1-4   (An)+ loads back to back, straight behind the LEA that set An.
;  5-9   -(An) stores back to back, then -(An) loads back to back.
; 10-12  An (An)+ load, then a store through the same register.
; 13-15  (An)+ stores back to back; -(An) store, then (An)+ load of it.
; 16-17  MOVEA.L (A0)+,A0, then (A0): the loaded value is the next base,
;        not the step.
; 18-19  MOVEA.L (A1),A0, then a load and a store through A0 at once.
; 20-23  ADDQ, ADDA, LEA and MOVEA.L Dn straight into a load or a store.
; 24-27  Byte pushes and pops through A7, which step by two.
; 28-30  ADDA.W (A0)+: a word read steps by two.
; 31-36  CLR/ST/SF through (A0)+ back to back, each size, and through -(A7).
; 37-38  EXG A0,A1, then both.
; 39-42  LINK, then (A6) and (A7); UNLK, then a push and a pop.
; 43-45  MOVEM.L loading two pointers, then both at once; MOVEM (A0)+.
; 46-47  An (An)+ step two instructions ahead, behind a register-only one.
; 48-49  MOVEA.L (A0)+,A0 two ahead: its result, not its step.
; 50-52  Read-modify-writes through (An)+ and -(An) back to back.
; 53     An absolute store, then an absolute load of it.
; 54-57  (An)+ loops under DBRA: a sum, then stores.
; 58-61  Displacement stores straight behind an (An)+ step, an ADDQ and a
;        MOVEA load of their base.
; 62-64  (d16,PC) loads, one straight behind another.
; 65-68  MULU.L/DIVU.L with a 64-bit result and an (An)+ source: three
;        register effects, the step written early from EX by a path of its
;        own; the next instruction's base is that An.
; 69-70  MOVEC to ISP, then (A7): a stack pointer written from WB's
;        auxiliary port, which nothing forwards.
;
; Protocol (tb_ap040_program.v, tb_ap040_pipe_program.v): word write to
; $F100 = failing test number, $F102 = $BAD0 on failure, $600D when done.

FAILREG	equ	$F100
DONEREG	equ	$F102
TABLE	equ	$5000		; 128 longwords: TABLE+4k holds $10000000+k
SCR	equ	$5400		; scratch
STACK	equ	$3400

check	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	move.w	#\3,d7
	bra	fail
ok\@:
	endm

	org	0
	dc.l	STACK,start
	rept	254
	dc.l	unexpected
	endr

	org	$400
start:
	lea	(TABLE).l,a0
	move.l	#$10000000,d0
	move.w	#127,d1
fill:	move.l	d0,(a0)+
	addq.l	#1,d0
	dbra	d1,fill

;------------------------------------------ 1-4: (An)+ loads back to back
	lea	(TABLE).l,a0
	move.l	(a0)+,d0
	move.l	(a0)+,d1
	move.l	(a0)+,d2
	check	d0,$10000000,1
	check	d1,$10000001,2
	check	d2,$10000002,3
	check	a0,TABLE+12,4

;------------------------------ 5-9: -(An) stores, then -(An) loads, in a row
	lea	(SCR+$20).l,a1
	move.l	#$A1A1A1A1,d3
	move.l	#$B2B2B2B2,d4
	move.l	#$C3C3C3C3,d5
	move.l	d3,-(a1)
	move.l	d4,-(a1)
	move.l	d5,-(a1)
	check	a1,SCR+$14,5
	move.l	(SCR+$18).l,d0
	check	d0,$B2B2B2B2,6
	lea	(SCR+$20).l,a1
	move.l	-(a1),d0
	move.l	-(a1),d1
	move.l	-(a1),d2
	check	d0,$A1A1A1A1,7
	check	d1,$B2B2B2B2,8
	check	d2,$C3C3C3C3,9

;---------------------------- 10-12: an (An)+ load, then a store through An
	lea	(TABLE).l,a0
	move.l	(a0)+,d0		; $10000000; A0 = TABLE+4
	move.l	d0,(a0)+		; to TABLE+4; A0 = TABLE+8
	move.l	(a0),d1
	check	a0,TABLE+8,10
	check	d1,$10000002,11
	move.l	(TABLE+4).l,d2
	check	d2,$10000000,12
	move.l	#$10000001,(TABLE+4).l

;------------------ 13-15: (An)+ stores; -(An) store, then (An)+ load of it
	lea	(SCR+$30).l,a2
	move.l	d3,(a2)+
	move.l	d4,(a2)+
	move.l	(SCR+$34).l,d0
	check	d0,$B2B2B2B2,13
	move.l	d5,-(a2)		; over the B2 at SCR+$34
	move.l	(a2)+,d1
	check	d1,$C3C3C3C3,14
	check	a2,SCR+$38,15

;------------------------------ 16-17: MOVEA.L (A0)+,A0, then (A0)
	move.l	#TABLE+$20,(SCR+$40).l
	lea	(SCR+$40).l,a0
	movea.l	(a0)+,a0		; the load wins over the step
	move.l	(a0),d0
	check	a0,TABLE+$20,16
	check	d0,$10000008,17

;------------------- 18-19: MOVEA.L (A1),A0, then a load and a store through A0
	lea	(SCR+$40).l,a1
	movea.l	(a1),a0
	move.l	(a0),d0
	check	d0,$10000008,18
	movea.l	(a1),a3
	move.l	#$5A5A5A5A,d6
	move.l	d6,(a3)
	move.l	(TABLE+$20).l,d0
	check	d0,$5A5A5A5A,19
	move.l	#$10000008,(TABLE+$20).l

;------------------------ 20-23: ADDQ, ADDA, LEA, MOVEA.L Dn into an access
	lea	(TABLE).l,a0
	addq.l	#8,a0
	move.l	(a0),d0
	check	d0,$10000002,20
	moveq	#16,d1
	adda.l	d1,a0			; TABLE+$18
	move.l	d6,(a0)
	move.l	(TABLE+$18).l,d0
	check	d0,$5A5A5A5A,21
	move.l	#$10000006,(TABLE+$18).l
	lea	4(a0),a3		; TABLE+$1C
	move.l	(a3),d0
	check	d0,$10000007,22
	move.l	a3,d2
	addq.l	#8,d2
	movea.l	d2,a4			; TABLE+$24
	move.l	(a4),d0
	check	d0,$10000009,23

;--------------------------------- 24-27: bytes through A7 step by two
	move.b	#$11,d0
	move.b	#$22,d1
	move.b	d0,-(a7)
	move.b	d1,-(a7)
	move.l	a7,d2
	check	d2,STACK-4,24
	move.b	(a7)+,d3
	move.b	(a7)+,d4
	and.l	#$FF,d3
	and.l	#$FF,d4
	check	d3,$22,25
	check	d4,$11,26
	move.l	a7,d2
	check	d2,STACK,27

;------------------------------------- 28-30: ADDA.W (A0)+ steps by two
	lea	(TABLE).l,a0
	suba.l	a1,a1
	adda.w	(a0)+,a1		; $1000
	adda.w	(a0)+,a1		; $0000
	move.l	(a0)+,d0
	check	d0,$10000001,28
	check	a1,$1000,29
	check	a0,TABLE+8,30

;------------------------ 31-36: CLR/ST/SF through (A0)+ and -(A7), in a row
	lea	(TABLE+$40).l,a0
	clr.l	(a0)+			; TABLE+$40
	clr.w	(a0)+			; TABLE+$44, high word
	clr.b	(a0)+			; TABLE+$46
	st	(a0)+			; TABLE+$47
	sf	(a0)+			; TABLE+$48, high byte
	check	a0,TABLE+$49,31
	move.l	(TABLE+$40).l,d0
	check	d0,0,32
	move.l	(TABLE+$44).l,d0
	check	d0,$000000FF,33
	move.l	(TABLE+$48).l,d0
	check	d0,$00000012,34
	st	-(a7)			; STACK-2
	clr.b	-(a7)			; STACK-4
	move.l	(a7)+,d0
	and.l	#$FF00FF00,d0
	check	d0,$0000FF00,35
	move.l	a7,d2
	check	d2,STACK,36

;------------------------------------------- 37-38: EXG A0,A1, then both
	lea	(TABLE).l,a0
	lea	(TABLE+$10).l,a1
	exg	a0,a1
	move.l	(a0),d0
	move.l	(a1),d1
	check	d0,$10000004,37
	check	d1,$10000000,38

;---------------------------------- 39-42: LINK, then (A6) and (A7); UNLK
	move.l	#$A1A1A1A1,d3
	move.l	#$B2B2B2B2,d4
	movea.l	#$66666666,a6
	link	a6,#-8			; saved at STACK-4; A6 = STACK-4, A7 = STACK-12
	move.l	(a6),d0
	check	d0,$66666666,39
	move.l	d3,(a7)			; STACK-12
	move.l	(STACK-12).l,d1
	check	d1,$A1A1A1A1,40
	unlk	a6
	move.l	d4,-(a7)
	move.l	(a7)+,d2
	check	d2,$B2B2B2B2,41
	move.l	a6,d0
	check	d0,$66666666,42

;----------------------- 43-45: MOVEM.L two pointers, then both at once
	move.l	#TABLE+$30,(SCR+$50).l
	move.l	#TABLE+$34,(SCR+$54).l
	lea	(SCR+$50).l,a0
	movem.l	(a0),a1-a2
	move.l	(a1),d0
	move.l	(a2),d1
	check	d0,$1000000C,43
	check	d1,$1000000D,44
	move.l	#TABLE+$3C,(SCR+$58).l
	movem.l	(a0)+,a1-a2		; A0 = SCR+$58
	movea.l	(a0),a3
	move.l	(a3),d2
	check	d2,$1000000F,45

;------------------ 46-47: an (An)+ step two ahead, behind a register-only one
	lea	(TABLE).l,a0
	move.l	(a0)+,d0
	moveq	#1,d3
	move.l	(a0),d1
	check	d1,$10000001,46
	move.l	d0,(a0)+
	moveq	#2,d3
	move.l	(a0),d1
	check	d1,$10000002,47
	move.l	#$10000001,(TABLE+4).l

;------------------------ 48-49: MOVEA.L (A0)+,A0 two ahead, then (A0)
	move.l	#TABLE+$28,(SCR+$60).l
	lea	(SCR+$60).l,a0
	movea.l	(a0)+,a0
	moveq	#2,d3
	move.l	(a0),d0
	check	a0,TABLE+$28,48
	check	d0,$1000000A,49

;------------------------- 50-52: read-modify-writes through (An)+ and -(An)
	move.l	#100,(SCR+$70).l
	move.l	#200,(SCR+$74).l
	lea	(SCR+$70).l,a0
	moveq	#5,d0
	add.l	d0,(a0)+
	add.l	d0,(a0)+
	check	a0,SCR+$78,50
	addq.l	#1,-(a0)
	addq.l	#1,-(a0)
	move.l	(SCR+$70).l,d1
	check	d1,106,51
	move.l	(SCR+$74).l,d1
	check	d1,206,52

;--------------------------------- 53: absolute store, then absolute load
	move.l	#$31415926,d0
	move.l	d0,(SCR+$80).l
	move.l	(SCR+$80).l,d1
	check	d1,$31415926,53

;------------------------------------------ 54-57: (An)+ loops under DBRA
	lea	(TABLE).l,a0
	moveq	#0,d1
	moveq	#15,d2
sum:	add.l	(a0)+,d1
	dbra	d2,sum
	check	d1,120,54		; 16 x $10000000 carries out
	check	a0,TABLE+64,55
	lea	(SCR+$90).l,a0
	moveq	#7,d2
	moveq	#0,d0
stl:	move.l	d0,(a0)+
	addq.l	#1,d0
	dbra	d2,stl
	check	a0,SCR+$B0,56
	move.l	(SCR+$AC).l,d0
	check	d0,7,57

;------------------------------ 58-61: displacement stores behind their base
	lea	(SCR+$C0).l,a0
	move.l	#$0BADF00D,(a0)
	move.l	(a0)+,d0		; A0 = SCR+$C4
	move.l	d0,4(a0)		; SCR+$C8
	move.l	(SCR+$C8).l,d1
	check	d1,$0BADF00D,58
	lea	(SCR+$D0).l,a1
	addq.l	#8,a1			; SCR+$D8
	move.l	d6,-4(a1)		; SCR+$D4
	move.l	(SCR+$D4).l,d1
	check	d1,$5A5A5A5A,59
	move.l	#SCR+$E0,(SCR+$DC).l
	movea.l	(SCR+$DC).l,a2
	move.w	d6,2(a2)		; SCR+$E2
	moveq	#0,d1
	move.w	(SCR+$E2).l,d1
	check	d1,$5A5A,60
	move.b	d0,-1(a2)		; SCR+$DF, the pointer's low byte
	move.l	(SCR+$DC).l,d1
	check	d1,SCR+$0D,61		; SCR+$E0 with its low byte now $0D

;---------------------------------------------- 62-64: (d16,PC) loads in a row
	move.l	pctab(pc),d0
	move.l	pctab+4(pc),d1
	move.w	pctab+2(pc),d2
	check	d0,$C0DECAFE,62
	check	d1,$FEEDFACE,63
	and.l	#$FFFF,d2
	check	d2,$CAFE,64

;------------------------- 65-68: MULL/DIVL (An)+ with a 64-bit result
	lea	(TABLE+$50).l,a0	; $10000014, then $10000015
	moveq	#16,d1
	mulu.l	(a0)+,d2:d1		; 16 x $10000014 = $1_00000140
	move.l	(a0),d3
	check	d3,$10000015,65
	check	d2,1,66
	lea	(TABLE+$60).l,a0	; $10000018, then $10000019
	move.l	#$20000031,d1
	moveq	#0,d2
	divu.l	(a0)+,d2:d1		; 2, remainder 1
	move.l	(a0),d3
	check	d3,$10000019,67
	check	d1,2,68

;------------------------------------------ 69-70: MOVEC to ISP, then (A7)
	move.l	#$600DF00D,(SCR+$100).l
	lea	(SCR+$100).l,a1
	movec	a1,isp			; A7 is ISP here
	move.l	(a7),d0
	check	d0,$600DF00D,69
	lea	(STACK).l,a2
	movec	a2,isp
	move.l	a7,d0
	check	d0,STACK,70

	move.w	#$600D,(DONEREG).l
	stop	#$2700

	cnop	0,4
pctab:	dc.l	$C0DECAFE,$FEEDFACE

fail:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt1:
	bra.s	halt1

unexpected:
	move.w	#$00FF,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
halt2:
	bra.s	halt2
